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

    var node: ServingNode {
        ServingNode(base: URL(string: "http://127.0.0.1:8080")!, authorization: { "Basic cookie" }) { request in
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

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    /// A share on Market is 10/16 of a coin (as in `ServingCreditTests`); at
    /// 16 bytes per coin it buys 10 bytes.
    private func ledger() -> SponsorLedger {
        var ledger = SponsorLedger(shareTarget: (UInt256(1) << 208) - UInt256(1), rangeSize: 100)
        ledger.install(SponsorTemplate(
            workID: "w1",
            prefixHex: "00",
            prices: [market: ChainPrice(target: (UInt256(1) << 204) - UInt256(1), height: 7, reward: 10)],
            submitTarget: .zero,
            expiresAt: 30_000
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
        let a = try ledger.assign(client: "a", on: market, store: root, now: 0)
        for nonce in 0..<shares {
            let value = try ledger.credit(assignment: a.id, nonce: nonce, hash: UInt256(1), now: 1)
            try storage.credit(root: root, value: value, on: market, now: 1)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market), .zero, "storage work is not fee credit")
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: market, balance: 100, holdUntil: 600_000, now: 2)) {
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
}
