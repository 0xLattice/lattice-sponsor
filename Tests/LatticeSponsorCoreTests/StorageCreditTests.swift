import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import UInt256
@testable import LatticeSponsorCore

private let market = ["Nexus", "Market"]

/// The node's `POST /pins` and `GET /fetch`, in memory.
private final class FakeNode: @unchecked Sendable {
    private let lock = NSLock()
    private var _pins: [String: [String: String]] = [:]
    /// What `GET /fetch` answers, by CID.
    let served: [String: [String: String]]

    init(served: [String: [String: String]] = [:]) { self.served = served }

    var pins: [String: [String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return _pins
    }

    var node: SponsorNode {
        SponsorNode(base: URL(string: "http://127.0.0.1:8080")!, authorization: { "Basic cookie" }) { request in
            try self.handle(request)
        }
    }

    private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        struct Pin: Codable { let cid: String; let entries: [String: String]? }
        let url = request.url!
        func respond(_ status: Int, _ body: Data = Data()) -> (Data, URLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Basic cookie" else { return respond(401) }
        if request.httpMethod == "POST", url.path == "/pins" {
            let pin = try JSONDecoder().decode(Pin.self, from: request.httpBody ?? Data())
            guard let entries = pin.entries, entries[pin.cid] != nil else { return respond(404) }
            lock.lock()
            _pins[pin.cid] = entries
            lock.unlock()
            return respond(200, Data(#"{"pins":[]}"#.utf8))
        }
        if request.httpMethod == "DELETE", url.path.hasPrefix("/pins/") {
            lock.lock()
            defer { lock.unlock() }
            guard _pins.removeValue(forKey: url.lastPathComponent) != nil else { return respond(404) }
            return respond(200, Data(#"{"pins":[]}"#.utf8))
        }
        if url.path.hasPrefix("/fetch/"), let entries = served[url.lastPathComponent] {
            return respond(200, try JSONEncoder().encode(Pin(cid: url.lastPathComponent, entries: entries)))
        }
        return respond(404)
    }
}

/// `count` bytes, as base64.
private func bytes(_ count: Int) -> String { Data(repeating: 7, count: count).base64EncodedString() }

final class StorageCreditTests: XCTestCase {
    private var file: URL!

    /// Each test's own directory: the blocklist is kept beside the file.
    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("storage.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// A share on Market is 10/16 of a coin (as in `SponsorLedgerTests`); at
    /// 16 bytes per coin it buys 10 bytes.
    private func ledger() -> SponsorLedger {
        var ledger = SponsorLedger(shareTarget: (UInt256(1) << 208) - UInt256(1), rangeSize: 100)
        ledger.install(SponsorTemplate(
            workID: "w1",
            prefixHex: "00",
            prices: [market: ChainPrice(target: (UInt256(1) << 204) - UInt256(1), height: 7, reward: 10)],
            submitTarget: .zero,
            parent: "p"
        ), now: 0)
        return ledger
    }

    private func storage(budget: Int = 100) throws -> StorageLedger {
        try StorageLedger(budget: budget, rates: [market: 16], file: file)
    }

    /// A 15-byte root with entries, and a 10-byte Volume the node fetches.
    private let volumes = [
        StoreVolume(cid: "root", entries: ["root": bytes(5), "leaf": bytes(10)]),
        StoreVolume(cid: "other", bytes: 10),
    ]

    /// Pay `shares` shares of Market work to `root`.
    private func pay(_ shares: UInt64, to root: String, _ storage: inout StorageLedger) throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market, store: root)
        for nonce in 0..<shares {
            let value = try ledger.credit(assignment: a.id, nonce: nonce, hash: UInt256(1), now: 1)
            try storage.credit(root: root, value: value, on: market, now: 1)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market), .zero, "storage work is not fee credit")
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: market, signer: "c", nonce: 0, balance: 100)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit)
        }
    }

    func testPayingEnoughPinsEveryVolume() async throws {
        var storage = try storage()
        let status = try storage.upload(root: "root", volumes: volumes, now: 0)
        XCTAssertEqual(status.bytes, 25)
        XCTAssertEqual(status.needed, ["Nexus/Market": 2], "25 bytes at 16 per coin")

        try pay(3, to: "root", &storage)
        XCTAssertEqual(storage.status(of: "root")?.credit, 30)
        let upload = try XCTUnwrap(storage.takePaid("root"))
        XCTAssertNil(storage.takePaid("root"), "pinned once at a time")
        let fake = FakeNode(served: ["other": ["other": bytes(10)]])
        try await fake.node.pin(upload)
        try storage.finish("root", pinned: true)

        XCTAssertEqual(Set(fake.pins.keys), ["root", "other"])
        XCTAssertEqual(storage.status(of: "root")?.stored, true)
    }

    func testPayingTooLittlePinsNothing() throws {
        var storage = try storage()
        _ = try storage.upload(root: "root", volumes: volumes, now: 0)
        try pay(2, to: "root", &storage)
        XCTAssertNil(storage.takePaid("root"), "20 of 25 bytes")
        XCTAssertEqual(storage.status(of: "root")?.needed, ["Nexus/Market": 1])
        XCTAssertEqual(storage.status(of: "root")?.stored, false)
    }

    func testAnUploadOverBudgetIsRefused() throws {
        var storage = try storage(budget: 40)
        _ = try storage.upload(root: "root", volumes: volumes, now: 0)
        let next = [StoreVolume(cid: "b", entries: ["b": bytes(20)])]
        XCTAssertThrowsError(try storage.upload(root: "b", volumes: next, now: 0)) {
            XCTAssertEqual($0 as? SponsorRefusal, .overBudget, "25 held of 40")
        }
        XCTAssertNoThrow(try storage.upload(root: "b", volumes: next, now: 3_600_000), "the first expired")
    }

    func testAChainWithoutARateIsRefused() throws {
        var storage = try storage()
        _ = try storage.upload(root: "root", volumes: volumes, now: 0)
        XCTAssertThrowsError(try storage.check(root: "root", on: ["Nexus"], now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .noStorageRate)
        }
        XCTAssertThrowsError(try storage.credit(root: "root", value: SponsorLedger.unit, on: ["Nexus"], now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .noStorageRate)
        }
    }

    func testTheStoredListSurvivesARestart() throws {
        var storage = try storage(budget: 40)
        _ = try storage.upload(root: "root", volumes: volumes, now: 0)
        try pay(3, to: "root", &storage)
        _ = storage.takePaid("root")
        try storage.finish("root", pinned: true)

        var restarted = try self.storage(budget: 40)
        XCTAssertEqual(restarted.stored, ["root": 25])
        XCTAssertEqual(restarted.status(of: "root")?.stored, true)
        XCTAssertThrowsError(try restarted.upload(root: "b", volumes: [StoreVolume(cid: "b", bytes: 20)], now: 0)) {
            XCTAssertEqual($0 as? SponsorRefusal, .overBudget, "25 of 40 is stored")
        }
    }

    /// lattice-storage's chunk Volume is one DAG-CBOR block `{bytes}` of
    /// 1 MiB: 12 bytes of framing past 1 MiB, which an upload must take.
    func testAFullFileChunkFits() throws {
        var storage = try StorageLedger(budget: 4 << 20, rates: [market: 16], file: file)
        let chunk = [StoreVolume(cid: "chunk", entries: ["chunk": bytes((1 << 20) + 12)])]
        XCTAssertEqual(try storage.upload(root: "chunk", volumes: chunk, now: 0).bytes, (1 << 20) + 12)
        let over = [StoreVolume(cid: "over", entries: ["over": bytes(StorageLedger.largestVolume + 1)])]
        XCTAssertThrowsError(try storage.upload(root: "over", volumes: over, now: 0))
    }

    /// Upload, pay and pin `volumes` under `root` on `fake`.
    private func store(
        _ root: String, _ volumes: [StoreVolume], in storage: inout StorageLedger, on fake: FakeNode
    ) async throws {
        _ = try storage.upload(root: root, volumes: volumes, now: 0)
        try pay(3, to: root, &storage)
        try await fake.node.pin(try XCTUnwrap(storage.takePaid(root)))
        try storage.finish(root, pinned: true)
    }

    func testATakedownUnpinsTheUploadAndFreesItsBytes() async throws {
        var storage = try storage(budget: 40)
        let fake = FakeNode(served: ["other": ["other": bytes(10)]])
        try await store("root", volumes, in: &storage, on: fake)
        XCTAssertEqual(storage.use(now: 0), StorageUse(budget: 40, stored: 25, held: 0))

        let released = try storage.block("root")
        XCTAssertEqual(released, ["other", "root"])
        try await fake.node.unpin(released)
        try storage.release("root")

        XCTAssertEqual(fake.pins, [:], "every Volume is released on the node")
        XCTAssertNil(storage.status(of: "root"))
        XCTAssertEqual(storage.use(now: 0), StorageUse(budget: 40, stored: 0, held: 0))
    }

    func testATakenDownCIDCannotBePinnedAgainEvenAfterARestart() async throws {
        var storage = try storage()
        let fake = FakeNode(served: ["other": ["other": bytes(10)]])
        try await store("root", volumes, in: &storage, on: fake)
        // Named by one Volume: the upload holding it goes with it.
        try await fake.node.unpin(try storage.block("other"))
        try storage.release("other")
        XCTAssertEqual(fake.pins, [:])

        var restarted = try self.storage()
        for (root, upload) in [("root", volumes), ("again", [StoreVolume(cid: "again", bytes: 5), StoreVolume(cid: "other", bytes: 10)])] {
            XCTAssertThrowsError(try restarted.upload(root: root, volumes: upload, now: 0)) {
                XCTAssertEqual($0 as? SponsorRefusal, .blocked, root)
            }
        }
        XCTAssertThrowsError(try restarted.check(root: "root", on: market, now: 0)) {
            XCTAssertEqual($0 as? SponsorRefusal, .blocked, "work and coin for it are refused too")
        }
    }

    func testATakedownRefusesWorkForAnUploadNotYetPinned() throws {
        var storage = try storage()
        _ = try storage.upload(root: "root", volumes: volumes, now: 0)
        try pay(2, to: "root", &storage)
        XCTAssertEqual(try storage.block("root"), [], "nothing of it is pinned")
        XCTAssertThrowsError(try storage.credit(root: "root", value: SponsorLedger.unit, on: market, now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .blocked, "its paid bytes are not refunded")
        }
        XCTAssertNil(storage.takePaid("root"))
        XCTAssertEqual(storage.use(now: 0).held, 0)
    }

    func testATakedownKeepsAVolumeAnotherUploadStillHolds() async throws {
        var storage = try storage()
        let fake = FakeNode(served: ["other": ["other": bytes(10)]])
        try await store("root", volumes, in: &storage, on: fake)
        try await store("b", [StoreVolume(cid: "b", entries: ["b": bytes(5)]), StoreVolume(cid: "other", bytes: 10)], in: &storage, on: fake)
        let released = try storage.block("root")
        XCTAssertEqual(released, ["root"], "b still holds other")
        try await fake.node.unpin(released)
        try storage.release("root")
        XCTAssertEqual(Set(fake.pins.keys), ["b", "other"])
        XCTAssertEqual(storage.status(of: "b")?.stored, true)
    }

    func testTheBudgetCountsHeldAndPinnedBytes() async throws {
        var storage = try storage(budget: 30)
        let fake = FakeNode(served: ["other": ["other": bytes(10)]])
        try await store("root", volumes, in: &storage, on: fake)
        _ = try storage.upload(root: "b", volumes: [StoreVolume(cid: "b", entries: ["b": bytes(5)])], now: 0)
        XCTAssertEqual(storage.use(now: 0), StorageUse(budget: 30, stored: 25, held: 5))
        XCTAssertThrowsError(try storage.upload(root: "c", volumes: [StoreVolume(cid: "c", bytes: 1)], now: 0)) {
            XCTAssertEqual($0 as? SponsorRefusal, .overBudget, "25 pinned and 5 held of 30")
        }
        XCTAssertEqual(storage.use(now: 3_600_000).held, 0, "an unpaid upload's hold ends with it")
    }

    func testATakedownBlocksEveryVolumeSoANewManifestCannotRepinThem() async throws {
        var storage = try storage()
        let fake = FakeNode(served: ["other": ["other": bytes(10)]])
        try await store("root", volumes, in: &storage, on: fake)
        try await fake.node.unpin(try storage.block("root"))
        try storage.release("root")
        let manifest = [StoreVolume(cid: "R2", entries: ["R2": bytes(5)]), StoreVolume(cid: "other", bytes: 10)]
        XCTAssertThrowsError(try storage.upload(root: "R2", volumes: manifest, now: 0)) {
            XCTAssertEqual($0 as? SponsorRefusal, .blocked, "R's chunk is blocked under any manifest")
        }
    }

    func testATakedownKeepsAVolumeAnUploadBeingPinnedShares() async throws {
        var storage = try storage()
        let fake = FakeNode(served: ["other": ["other": bytes(10)]])
        try await store("root", volumes, in: &storage, on: fake)
        let b = [StoreVolume(cid: "b", entries: ["b": bytes(5)]), StoreVolume(cid: "other", bytes: 10)]
        _ = try storage.upload(root: "b", volumes: b, now: 0)
        try pay(3, to: "b", &storage)
        let pinning = try XCTUnwrap(storage.takePaid("b"))

        XCTAssertEqual(try storage.block("root"), ["root"], "b, being pinned, keeps other")
        XCTAssertEqual(storage.unreferenced(["root", "other", "b"]), [], "root stays counted until released")
        try storage.release("root")
        XCTAssertEqual(storage.unreferenced(["root", "other", "b"]), ["root"])
        try await fake.node.pin(pinning)
        XCTAssertTrue(try storage.finish("b", pinned: true))
        XCTAssertEqual(storage.status(of: "b")?.stored, true)
    }

    func testTheBlocklistIsTheOperatorsAlone() throws {
        var storage = try storage()
        _ = try storage.block("root")
        let blocklist = file.deletingLastPathComponent().appendingPathComponent("lattice-sponsor-blocklist.json")
        let mode = try FileManager.default.attributesOfItem(atPath: blocklist.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testATakedownReleasesWhatAFailedPinLeftPinned() async throws {
        var storage = try storage()
        // `other` cannot be fetched, so the pin stops after `root`.
        let fake = FakeNode()
        _ = try storage.upload(root: "root", volumes: volumes, now: 0)
        try pay(3, to: "root", &storage)
        let upload = try XCTUnwrap(storage.takePaid("root"))
        do {
            try await fake.node.pin(upload)
            XCTFail("other is not served")
        } catch {}
        XCTAssertTrue(try storage.finish("root", pinned: false), "held, to be pinned again")
        XCTAssertEqual(Set(fake.pins.keys), ["root"])

        let released = try storage.block("root")
        XCTAssertEqual(released, ["other", "root"], "every Volume it tried to pin")
        try await fake.node.unpin(released)
        try storage.release("root")
        XCTAssertEqual(fake.pins, [:], "the partly pinned Volume is released; the unpinned one is not pinned (404)")
    }

    func testAFailedPinOfAnUploadTakenDownMeanwhileIsTheCallersToUnpin() throws {
        var storage = try storage()
        _ = try storage.upload(root: "root", volumes: volumes, now: 0)
        try pay(3, to: "root", &storage)
        _ = try XCTUnwrap(storage.takePaid("root"))
        XCTAssertEqual(try storage.block("root"), [], "being pinned: unpinned when its attempt ends")
        XCTAssertFalse(try storage.finish("root", pinned: false))
        XCTAssertEqual(storage.unreferenced(["root", "other"]), ["root", "other"])
    }
}
