import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import UInt256
@testable import LatticeSponsorCore

/// The node's operator pins, in memory, as the node keeps them: a Volume it
/// holds is pinned by CID and any entries given are ignored; one it does not
/// is stored from the entries given, each checked against its CID. An entry
/// is "the bytes its CID names" when it starts with the CID.
private final class FakeNode: @unchecked Sendable {
    private let lock = NSLock()
    private var _pins: Set<String> = []
    private var _unpinned: [String] = []
    private var _held: [String: [String: Data]] = [:]
    /// What peers serve to `GET /fetch`, by root.
    var served: [String: [String: Data]] = [:]

    /// The Volumes in the node's store, by root.
    var held: [String: [String: Data]] {
        get { locked { _held } }
        set { locked { _held = newValue } }
    }

    var pins: Set<String> {
        get { locked { _pins } }
        set { locked { _pins = newValue } }
    }

    var unpinned: [String] { locked { _unpinned } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var node: StorageNode {
        StorageNode(base: URL(string: "http://127.0.0.1:8080")!, authorization: { "Basic cookie" }) { request in
            try self.handle(request)
        }
    }

    private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        func respond(_ status: Int, _ body: Data = Data()) -> (Data, URLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let path = url.path
        switch request.httpMethod ?? "GET" {
        case "GET" where path == "/pins":
            return respond(200, try JSONEncoder().encode(["pins": pins.sorted()]))
        case "GET" where path.hasPrefix("/fetch/"):
            let cid = String(path.dropFirst("/fetch/".count))
            guard let entries = held[cid] ?? served[cid] else { return respond(404) }
            return respond(200, try JSONEncoder().encode(StorageNode.Volume(cid: cid, entries: entries)))
        case "POST" where path == "/pins":
            let volume = try JSONDecoder().decode(StorageNode.Volume.self, from: request.httpBody ?? Data())
            if held[volume.cid] == nil {
                guard let entries = volume.entries else { return respond(404) }
                guard entries[volume.cid] != nil,
                      entries.allSatisfy({ $0.value.starts(with: Data($0.key.utf8)) }) else { return respond(400) }
                held[volume.cid] = entries
            }
            locked { _ = _pins.insert(volume.cid) }
            return respond(200, try JSONEncoder().encode(["pins": pins.sorted()]))
        case "DELETE" where path.hasPrefix("/pins/"):
            let cid = String(path.dropFirst("/pins/".count))
            locked {
                if _pins.remove(cid) != nil { _held.removeValue(forKey: cid) }
                _unpinned.append(cid)
            }
            return respond(200, try JSONEncoder().encode(["pins": pins.sorted()]))
        default:
            return respond(404)
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64 = 0
    var now: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); defer { lock.unlock() }; _now = newValue }
    }
}

/// A one-entry Volume of `size` bytes whose bytes are what its CID names.
private func volume(_ cid: String, _ size: Int) -> StorageNode.Volume {
    StorageNode.Volume(cid: cid, entries: [cid: Data(cid.utf8) + Data(count: size - cid.utf8.count)])
}

private func coins(_ value: Double) -> UInt256 {
    UInt256(UInt64(value * 1024)) * (SponsorLedger.unit / UInt256(1024))
}

final class StorageCreditTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func seller(
        _ fake: FakeNode, _ clock: Clock, budget: Int = 100, largestGroup: Int = 60
    ) async throws -> StorageSeller {
        let seller = StorageSeller(
            ledger: StorageLedger(
                budget: budget, largestGroup: largestGroup, halfLife: 1000, state: try StorageLedger.load(from: file)
            ),
            node: fake.node, file: file, now: { clock.now }
        )
        await seller.maintain()
        return seller
    }

    /// Credit is a share's value in coins, halving every half-life; another
    /// payment adds to what is left.
    func testCreditDecaysWithTheHalfLife() {
        var ledger = StorageLedger(budget: 100, largestGroup: 100, halfLife: 1000)
        ledger.pay(root: "r", value: SponsorLedger.unit, now: 0)
        XCTAssertEqual(ledger.credit(of: "r", now: 0), 1)
        XCTAssertEqual(ledger.credit(of: "r", now: 1000), 0.5, accuracy: 1e-12)
        ledger.pay(root: "r", value: SponsorLedger.unit, now: 1000)
        XCTAssertEqual(ledger.credit(of: "r", now: 2000), 0.75, accuracy: 1e-12)
        XCTAssertEqual(StorageLedger.coins(UInt256(3) << 63), 1.5)
    }

    /// A group that does not fit evicts the lowest credit per byte first, and
    /// one that would evict a group ranked above it is refused.
    func testEvictionTakesTheLowestCreditPerByte() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let seller = try await seller(fake, clock)
        await seller.pay(root: "a", value: coins(1))
        await seller.pay(root: "b", value: coins(3))
        await seller.pay(root: "c", value: coins(2))
        await seller.pay(root: "d", value: coins(1))
        _ = try await seller.store(root: "a", volumes: [volume("a", 50)])
        _ = try await seller.store(root: "b", volumes: [volume("b", 50)])
        let c = try await seller.store(root: "c", volumes: [volume("c", 50)])
        XCTAssertTrue(c.held)
        XCTAssertEqual(c.bytes, 50)
        XCTAssertEqual(c.credit, 2)
        XCTAssertEqual(fake.pins, ["b", "c"], "a ranked lowest")
        XCTAssertEqual(fake.unpinned, ["a"])
        let a = await seller.status("a")
        XCTAssertFalse(a.held)

        do {
            _ = try await seller.store(root: "d", volumes: [volume("d", 50)])
            XCTFail("d ranks below everything held")
        } catch {
            XCTAssertEqual(error as? SponsorRefusal, .outranked)
        }
        XCTAssertEqual(fake.pins, ["b", "c"])

        // Paying again raises a held group's rank: a smaller group with less
        // credit still ranks by credit per byte.
        await seller.pay(root: "b", value: coins(1))
        await seller.pay(root: "e", value: coins(1.5))
        _ = try await seller.store(root: "e", volumes: [volume("e", 30)])
        XCTAssertEqual(fake.pins, ["b", "e"], "e (0.05 a byte) outranks c (0.04)")
    }

    /// A Volume two groups use is unpinned only once neither is held.
    func testASharedVolumeIsUnpinnedOnlyWhenNoGroupUsesIt() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let seller = try await seller(fake, clock)
        for (root, credit) in [("a", 1.0), ("b", 2.0), ("c", 8.0), ("d", 9.0)] {
            await seller.pay(root: root, value: coins(credit))
        }
        _ = try await seller.store(root: "a", volumes: [volume("a", 10), volume("shared", 30)])
        // The shared Volume by CID only: the sponsor already holds it.
        _ = try await seller.store(root: "b", volumes: [volume("b", 10), StorageNode.Volume(cid: "shared")])
        XCTAssertEqual(fake.pins, ["a", "b", "shared"])

        _ = try await seller.store(root: "c", volumes: [volume("c", 60)])
        XCTAssertEqual(fake.pins, ["b", "c", "shared"], "a went; b still uses shared")
        XCTAssertEqual(fake.unpinned, ["a"])

        _ = try await seller.store(root: "d", volumes: [volume("d", 10)])
        XCTAssertEqual(fake.pins, ["c", "d"])
        XCTAssertEqual(fake.unpinned, ["a", "b", "shared"])
    }

    /// A Volume the operator pinned first is used, read from the node for its
    /// size, costs the budget nothing, and is never unpinned.
    func testTheOperatorsPinIsNeverUnpinned() async throws {
        let fake = FakeNode()
        fake.pins = ["mine"]
        fake.held = ["mine": volume("mine", 40).entries!]
        let clock = Clock()
        let seller = try await seller(fake, clock, budget: 50)
        await seller.pay(root: "a", value: coins(1))
        await seller.pay(root: "b", value: coins(5))
        // The uploader's bytes for the operator's Volume are not taken at
        // their word: its size is read from the node.
        let a = try await seller.store(root: "a", volumes: [volume("a", 10), volume("mine", 5)])
        XCTAssertEqual(a.bytes, 50)
        XCTAssertEqual(fake.pins, ["a", "mine"])

        _ = try await seller.store(root: "b", volumes: [volume("b", 50)])
        XCTAssertEqual(fake.pins, ["b", "mine"])
        XCTAssertEqual(fake.unpinned, ["a"], "the operator's pin stays")
        let claimed = await seller.ledger.state.claimed
        XCTAssertEqual(claimed, ["b"])
    }

    /// A Volume the node already holds is sized by the node's bytes, not
    /// the uploader's: the node ignores entries given for it.
    func testAHeldVolumeIsSizedByTheNodesBytes() async throws {
        let fake = FakeNode()
        fake.held = ["big": volume("big", 90).entries!]
        let clock = Clock()
        let seller = try await seller(fake, clock, budget: 100, largestGroup: 100)
        await seller.pay(root: "a", value: coins(1))
        let a = try await seller.store(
            root: "a", volumes: [volume("a", 10), StorageNode.Volume(cid: "big", entries: ["big": Data()])]
        )
        XCTAssertEqual(a.bytes, 100)
        XCTAssertEqual(fake.pins, ["a", "big"])

        await seller.pay(root: "b", value: coins(0.5))
        do {
            let b = [StorageNode.Volume(cid: "b", entries: ["b": Data("b".utf8)]), StorageNode.Volume(cid: "big")]
            _ = try await seller.store(root: "b", volumes: b)
            XCTFail("b's 91 bytes at half a coin rank below a's 100 at one")
        } catch {
            XCTAssertEqual(error as? SponsorRefusal, .outranked)
        }
        XCTAssertEqual(fake.pins, ["a", "big"], "b's own pin is undone; big stays a's")
    }

    /// A Volume a held group uses as the operator's, which the operator then
    /// unpinned, is pinned and claimed by the next group that lists it.
    func testAnOperatorVolumeTheOperatorDroppedIsPinnedAgain() async throws {
        let fake = FakeNode()
        fake.pins = ["mine"]
        fake.held = ["mine": volume("mine", 20).entries!]
        let clock = Clock()
        let seller = try await seller(fake, clock)
        await seller.pay(root: "a", value: coins(1))
        await seller.pay(root: "b", value: coins(1))
        _ = try await seller.store(root: "a", volumes: [volume("a", 10), StorageNode.Volume(cid: "mine")])
        fake.pins.remove("mine")
        _ = try await seller.store(root: "b", volumes: [volume("b", 10), StorageNode.Volume(cid: "mine")])
        XCTAssertEqual(fake.pins, ["a", "b", "mine"])
        let claimed = await seller.ledger.state.claimed
        XCTAssertEqual(claimed, ["a", "b", "mine"])
    }

    /// Stores wait their turn instead of being refused.
    func testConcurrentStoresBothLand() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let seller = try await seller(fake, clock)
        await seller.pay(root: "a", value: coins(1))
        await seller.pay(root: "b", value: coins(1))
        async let a = seller.store(root: "a", volumes: [volume("a", 10)])
        async let b = seller.store(root: "b", volumes: [volume("b", 10)])
        let (heldA, heldB) = try await (a.held, b.held)
        XCTAssertTrue(heldA && heldB)
    }

    func testRefusals() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let seller = try await seller(fake, clock, budget: 100, largestGroup: 200)

        func refusal(_ root: String, _ volumes: [StorageNode.Volume]) async -> SponsorRefusal? {
            do {
                _ = try await seller.store(root: root, volumes: volumes)
                return nil
            } catch {
                return error as? SponsorRefusal
            }
        }
        let unfunded = await refusal("a", [volume("a", 10)])
        XCTAssertEqual(unfunded, .unfunded, "nothing is pinned before work pays for it")
        await seller.pay(root: "a", value: coins(1))
        let tooBig = await refusal("a", [volume("a", 201)])
        XCTAssertEqual(tooBig, .groupTooBig)
        let neverFits = await refusal("a", [volume("a", 101)])
        XCTAssertEqual(neverFits, .neverFits)
        let missing = await refusal("a", [volume("a", 10), StorageNode.Volume(cid: "gone")])
        XCTAssertEqual(missing, .volumeUnavailable)
        let huge = StorageNode.Volume(cid: "a", entries: ["a": Data(count: StorageNode.largestBody)])
        let tooBigToPin = await refusal("a", [huge])
        XCTAssertEqual(tooBigToPin, .volumeTooBig, "past the node's body limit")
        let rootless = await refusal("a", [volume("b", 10)])
        XCTAssertEqual(rootless, .draft("volumes lists each Volume once, the root among them"))

        // The node refuses the second Volume's bytes: the first is unpinned
        // again, and the group is not held.
        let bad = StorageNode.Volume(cid: "bad", entries: ["bad": Data(count: 10)])
        let badBytes = await refusal("a", [volume("a", 10), bad])
        XCTAssertEqual(badBytes, .badVolume)
        XCTAssertEqual(fake.pins, [])
        XCTAssertEqual(fake.unpinned.suffix(2), ["a", "bad"])
        let a = await seller.status("a")
        XCTAssertFalse(a.held)
        let claimed = await seller.ledger.state.claimed
        XCTAssertEqual(claimed, [])
    }

    /// The ledger survives a restart, and on boot is matched to the node: a
    /// group missing a Volume is dropped and what only it used is unpinned.
    func testStateSurvivesARestartAndIsReconciled() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let first = try await seller(fake, clock)
        await first.pay(root: "a", value: coins(1))
        await first.pay(root: "b", value: coins(2))
        _ = try await first.store(root: "a", volumes: [volume("a", 10), volume("shared", 10)])
        _ = try await first.store(root: "b", volumes: [volume("b", 10), volume("shared", 10)])
        await first.pay(root: "b", value: coins(1))
        await first.pay(root: "unheld", value: coins(1))
        clock.now = 10
        await first.maintain()
        let saved = await first.ledger.state

        let restarted = try await seller(fake, clock)
        let state = await restarted.ledger.state
        XCTAssertEqual(state, saved)
        let b = await restarted.status("b")
        XCTAssertEqual(b.credit, 3 * exp2(-0.01), accuracy: 1e-9)
        XCTAssertTrue(b.held)

        // b's own Volume went from the node while the sponsor was down.
        fake.pins.remove("b")
        let reconciled = try await seller(fake, clock)
        let held = await reconciled.ledger.state.groups.keys.sorted()
        XCTAssertEqual(held, ["a"])
        XCTAssertEqual(fake.pins, ["a", "shared"], "a still uses shared")
        await reconciled.pay(root: "c", value: coins(1))
        let c = try await reconciled.store(root: "c", volumes: [volume("c", 10)])
        XCTAssertTrue(c.held)
        let reloaded = try StorageLedger.load(from: file)
        XCTAssertEqual(reloaded.groups.keys.sorted(), ["a", "c"])
        XCTAssertEqual(reloaded.claimed, ["a", "c", "shared"])
    }

    /// Credit for a root not held expires as fee credit does; a held one's
    /// only decays.
    func testUnheldCreditExpires() {
        var ledger = StorageLedger(budget: 100, largestGroup: 100, halfLife: 1000, creditLifetime: 100)
        ledger.pay(root: "r", value: SponsorLedger.unit, now: 0)
        ledger.prune(now: 99)
        XCTAssertGreaterThan(ledger.credit(of: "r", now: 99), 0)
        ledger.prune(now: 100)
        XCTAssertEqual(ledger.credit(of: "r", now: 100), 0)
    }

    /// Storage work's shares are the group's, never fee credit.
    func testStorageCreditIsNotFeeCredit() throws {
        var ledger = SponsorLedger(shareTarget: (UInt256(1) << 208) - UInt256(1), rangeSize: 100)
        ledger.install(SponsorTemplate(
            workID: "w1",
            prefixHex: "00",
            prices: [["Nexus"]: ChainPrice(target: (UInt256(1) << 204) - UInt256(1), height: 7, reward: 10)],
            submitTarget: .zero,
            expiresAt: 30_000
        ), now: 0)
        let a = try ledger.assign(client: "a", on: ["Nexus"], store: "root", now: 0)
        XCTAssertEqual(a.store, "root")
        let value = try ledger.credit(assignment: a.id, nonce: 0, hash: UInt256(1), now: 1)
        XCTAssertEqual(value, UInt256(10) << 60)
        XCTAssertEqual(ledger.credit(of: "a", on: ["Nexus"]), .zero)
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: ["Nexus"], balance: 100, holdUntil: 600_000, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit)
        }
    }
}
