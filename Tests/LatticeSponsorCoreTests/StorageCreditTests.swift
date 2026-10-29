import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import Lattice
import UInt256
@testable import LatticeSponsorCore

/// The node's operator pins, in memory, as the node keeps them: a Volume it
/// holds is pinned by CID and any entries given are ignored; one it does not
/// is stored from the entries given, each checked against its CID. An entry
/// is "the bytes its CID names" when it starts with a 1 byte. A CID that is
/// not canonical is refused (400), as by the node.
private final class FakeNode: @unchecked Sendable {
    private let lock = NSLock()
    private var _pins: Set<String> = []
    private var _unpinned: [String] = []
    private var _held: [String: [String: Data]] = [:]
    /// What peers serve to `GET /fetch`, by root.
    var served: [String: [String: Data]] = [:]
    /// Whether `GET /fetch` answers at all: a node under serving load
    /// answers 404 even for what it holds.
    var fetching = true
    /// CIDs whose unpin the node fails (503).
    var failingUnpins: Set<String> = []

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
        let named = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        if path.hasPrefix("/pins/") || path.hasPrefix("/fetch/"), !CIDIdentity.isCanonical(named) {
            return respond(400)
        }
        switch request.httpMethod ?? "GET" {
        case "GET" where path == "/pins":
            return respond(200, try JSONEncoder().encode(["pins": pins.sorted()]))
        case "GET" where path.hasPrefix("/fetch/"):
            let cid = named
            guard fetching, let entries = held[cid] ?? served[cid] else { return respond(404) }
            return respond(200, try JSONEncoder().encode(StorageNode.Volume(cid: cid, entries: entries)))
        case "POST" where path == "/pins":
            let volume = try JSONDecoder().decode(StorageNode.Volume.self, from: request.httpBody ?? Data())
            guard CIDIdentity.isCanonical(volume.cid) else { return respond(400) }
            if held[volume.cid] == nil {
                guard let entries = volume.entries else { return respond(404) }
                guard entries[volume.cid] != nil,
                      entries.allSatisfy({ $0.value.first == 1 }) else { return respond(400) }
                held[volume.cid] = entries
            }
            locked { _ = _pins.insert(volume.cid) }
            return respond(200, try JSONEncoder().encode(["pins": pins.sorted()]))
        case "DELETE" where path.hasPrefix("/pins/"):
            let cid = named
            if failingUnpins.contains(cid) { return respond(503) }
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

private let base32 = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

/// A canonical CID (v1, raw, sha2-256) whose digest spells `name`.
private func cidOf(_ name: String) -> String {
    let bytes = [0x01, 0x55, 0x12, 0x20] + Array(name.utf8) + [UInt8](repeating: 0, count: 32 - name.utf8.count)
    var text = "b"
    var buffer = 0, bits = 0
    for byte in bytes {
        buffer = (buffer << 8 | Int(byte)) & 0xffff
        bits += 8
        while bits >= 5 {
            bits -= 5
            text.append(Character(Unicode.Scalar(base32[buffer >> bits & 31])))
        }
    }
    if bits > 0 { text.append(Character(Unicode.Scalar(base32[buffer << (5 - bits) & 31]))) }
    return text
}

/// The name `cidOf(_:)` spelled into `cid`.
private func nameOf(_ cid: String) -> String {
    var bytes: [UInt8] = []
    var buffer = 0, bits = 0
    for char in cid.utf8.dropFirst() {
        buffer = (buffer << 5 | base32.firstIndex(of: char)!) & 0xffff
        bits += 5
        if bits >= 8 {
            bits -= 8
            bytes.append(UInt8(buffer >> bits & 0xff))
        }
    }
    return String(decoding: bytes.dropFirst(4).prefix { $0 != 0 }, as: UTF8.self)
}

private func names(_ cids: Set<String>) -> Set<String> {
    Set(cids.map(nameOf))
}

/// A one-entry Volume of `size` bytes, named `name`, whose bytes are what
/// its CID names.
private func volume(_ name: String, _ size: Int) -> StorageNode.Volume {
    StorageNode.Volume(cid: cidOf(name), entries: [cidOf(name): Data(repeating: 1, count: size)])
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
                budget: budget, largestGroup: largestGroup, halfLife: 1000, smallestVolume: 1,
                state: try StorageLedger.load(from: file)
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
        await seller.pay(root: cidOf("a"), value: coins(1))
        await seller.pay(root: cidOf("b"), value: coins(3))
        await seller.pay(root: cidOf("c"), value: coins(2))
        await seller.pay(root: cidOf("d"), value: coins(1))
        _ = try await seller.store(root: cidOf("a"), volumes: [volume("a", 50)])
        _ = try await seller.store(root: cidOf("b"), volumes: [volume("b", 50)])
        let c = try await seller.store(root: cidOf("c"), volumes: [volume("c", 50)])
        XCTAssertTrue(c.held)
        XCTAssertEqual(c.bytes, 50)
        XCTAssertEqual(c.credit, 2)
        XCTAssertEqual(names(fake.pins), ["b", "c"], "a ranked lowest")
        XCTAssertEqual(fake.unpinned.map(nameOf), ["a"])
        let a = await seller.status(cidOf("a"))
        XCTAssertFalse(a.held)

        do {
            _ = try await seller.store(root: cidOf("d"), volumes: [volume("d", 50)])
            XCTFail("d ranks below everything held")
        } catch {
            XCTAssertEqual(error as? SponsorRefusal, .outranked)
        }
        XCTAssertEqual(names(fake.pins), ["b", "c"])

        // Paying again raises a held group's rank: a smaller group with less
        // credit still ranks by credit per byte.
        await seller.pay(root: cidOf("b"), value: coins(1))
        await seller.pay(root: cidOf("e"), value: coins(1.5))
        _ = try await seller.store(root: cidOf("e"), volumes: [volume("e", 30)])
        XCTAssertEqual(names(fake.pins), ["b", "e"], "e (0.05 a byte) outranks c (0.04)")
    }

    /// A Volume two groups use is unpinned only once neither is held.
    func testASharedVolumeIsUnpinnedOnlyWhenNoGroupUsesIt() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let seller = try await seller(fake, clock)
        for (root, credit) in [("a", 1.0), ("b", 2.0), ("c", 8.0), ("d", 9.0)] {
            await seller.pay(root: cidOf(root), value: coins(credit))
        }
        _ = try await seller.store(root: cidOf("a"), volumes: [volume("a", 10), volume("shared", 30)])
        // The shared Volume by CID only: the sponsor already holds it.
        _ = try await seller.store(root: cidOf("b"), volumes: [volume("b", 10), StorageNode.Volume(cid: cidOf("shared"))])
        XCTAssertEqual(names(fake.pins), ["a", "b", "shared"])

        _ = try await seller.store(root: cidOf("c"), volumes: [volume("c", 60)])
        XCTAssertEqual(names(fake.pins), ["b", "c", "shared"], "a went; b still uses shared")
        XCTAssertEqual(fake.unpinned.map(nameOf), ["a"])

        _ = try await seller.store(root: cidOf("d"), volumes: [volume("d", 10)])
        XCTAssertEqual(names(fake.pins), ["c", "d"])
        XCTAssertEqual(fake.unpinned.map(nameOf), ["a", "b", "shared"])
    }

    /// A Volume the operator pinned first is used, read from the node for its
    /// size, costs the budget nothing, and is never unpinned.
    func testTheOperatorsPinIsNeverUnpinned() async throws {
        let fake = FakeNode()
        fake.pins = [cidOf("mine")]
        fake.held = [cidOf("mine"): volume("mine", 40).entries!]
        let clock = Clock()
        let seller = try await seller(fake, clock, budget: 50)
        await seller.pay(root: cidOf("a"), value: coins(1))
        await seller.pay(root: cidOf("b"), value: coins(5))
        // The uploader's bytes for the operator's Volume are not taken at
        // their word: its size is read from the node.
        let a = try await seller.store(root: cidOf("a"), volumes: [volume("a", 10), volume("mine", 5)])
        XCTAssertEqual(a.bytes, 50)
        XCTAssertEqual(names(fake.pins), ["a", "mine"])

        _ = try await seller.store(root: cidOf("b"), volumes: [volume("b", 50)])
        XCTAssertEqual(names(fake.pins), ["b", "mine"])
        XCTAssertEqual(fake.unpinned.map(nameOf), ["a"], "the operator's pin stays")
        let claimed = await seller.ledger.state.claimed
        XCTAssertEqual(names(claimed), ["b"])
    }

    /// A CID spelled other than canonically (here with a slash the node's
    /// router would drop) is refused before anything is claimed, so it can
    /// never reach the operator's pin of the canonical spelling.
    func testANonCanonicalCIDIsRefused() async throws {
        let fake = FakeNode()
        fake.pins = [cidOf("mine")]
        fake.held = [cidOf("mine"): volume("mine", 20).entries!]
        let clock = Clock()
        let seller = try await seller(fake, clock)
        await seller.pay(root: cidOf("a"), value: coins(1))
        for spelling in [cidOf("mine") + "/", "/" + cidOf("mine"), "!"] {
            do {
                _ = try await seller.store(root: cidOf("a"), volumes: [volume("a", 10), StorageNode.Volume(cid: spelling)])
                XCTFail("\(spelling) is not canonical")
            } catch {
                XCTAssertEqual(error as? SponsorRefusal, .draft("a Volume's CID is not canonical"))
            }
        }
        XCTAssertEqual(names(fake.pins), ["mine"])
        XCTAssertEqual(fake.unpinned, [])
    }

    /// A Volume the node holds for itself is refused: the node ignores the
    /// entries given for it, and a read of it may come from any peer.
    func testAVolumeTheNodeHoldsForItselfIsRefused() async throws {
        let fake = FakeNode()
        fake.held = [cidOf("big"): volume("big", 90).entries!]
        let clock = Clock()
        let seller = try await seller(fake, clock, budget: 100, largestGroup: 100)
        await seller.pay(root: cidOf("a"), value: coins(1))
        do {
            _ = try await seller.store(
                root: cidOf("a"),
                volumes: [volume("a", 10), StorageNode.Volume(cid: cidOf("big"), entries: [cidOf("big"): Data([1])])]
            )
            XCTFail("big is the node's")
        } catch {
            XCTAssertEqual(error as? SponsorRefusal, .heldByNode)
        }
        XCTAssertEqual(names(fake.pins), [])
        let claimed = await seller.ledger.state.claimed
        XCTAssertEqual(claimed, [])
    }

    /// A rollback forgets only the claims its own store made: an orphan
    /// claimed before, whose unpin failed, stays claimed and is unpinned later.
    func testARollbackKeepsAnOlderOrphansClaim() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let seller = try await seller(fake, clock, budget: 20)
        await seller.pay(root: cidOf("a"), value: coins(1))
        await seller.pay(root: cidOf("b"), value: coins(5))
        await seller.pay(root: cidOf("c"), value: coins(9))
        _ = try await seller.store(root: cidOf("a"), volumes: [volume("a", 10), volume("o", 10)])
        fake.failingUnpins = [cidOf("o")]
        _ = try await seller.store(root: cidOf("b"), volumes: [volume("b", 20)])
        XCTAssertEqual(names(fake.pins), ["b", "o"], "o's unpin failed")

        let bad = StorageNode.Volume(cid: cidOf("bad"), entries: [cidOf("bad"): Data(count: 5)])
        do {
            _ = try await seller.store(root: cidOf("c"), volumes: [volume("c", 5), bad, StorageNode.Volume(cid: cidOf("o"))])
            XCTFail("bad bytes")
        } catch {
            XCTAssertEqual(error as? SponsorRefusal, .badVolume)
        }
        let claimed = await seller.ledger.state.claimed
        XCTAssertEqual(names(claimed), ["b", "o"])
        fake.failingUnpins = []
        await seller.maintain()
        XCTAssertEqual(names(fake.pins), ["b"])
    }

    /// A Volume a held group uses as the operator's, which the operator then
    /// unpinned, is pinned and claimed by the next group that lists it.
    func testAnOperatorVolumeTheOperatorDroppedIsPinnedAgain() async throws {
        let fake = FakeNode()
        fake.pins = [cidOf("mine")]
        fake.held = [cidOf("mine"): volume("mine", 20).entries!]
        let clock = Clock()
        let seller = try await seller(fake, clock)
        await seller.pay(root: cidOf("a"), value: coins(1))
        await seller.pay(root: cidOf("b"), value: coins(1))
        _ = try await seller.store(root: cidOf("a"), volumes: [volume("a", 10), StorageNode.Volume(cid: cidOf("mine"))])
        fake.pins.remove(cidOf("mine"))
        _ = try await seller.store(root: cidOf("b"), volumes: [volume("b", 10), StorageNode.Volume(cid: cidOf("mine"))])
        XCTAssertEqual(names(fake.pins), ["a", "b", "mine"])
        let claimed = await seller.ledger.state.claimed
        XCTAssertEqual(names(claimed), ["a", "b", "mine"])
    }

    /// A Volume pinned with the bytes given is sized by those bytes, which
    /// the node checked and stored, without reading it back; one the node
    /// held and cannot read now is the node's load, not a missing Volume.
    func testBytesTheNodeTookNeedNoReadBack() async throws {
        let fake = FakeNode()
        fake.pins = [cidOf("big")]
        fake.held = [cidOf("big"): volume("big", 30).entries!]
        fake.fetching = false
        let clock = Clock()
        let seller = try await seller(fake, clock)
        await seller.pay(root: cidOf("a"), value: coins(1))
        let a = try await seller.store(root: cidOf("a"), volumes: [volume("a", 10)])
        XCTAssertEqual(a.bytes, 10)
        await seller.pay(root: cidOf("b"), value: coins(1))
        do {
            _ = try await seller.store(root: cidOf("b"), volumes: [volume("b", 10), StorageNode.Volume(cid: cidOf("big"))])
            XCTFail("big cannot be sized now")
        } catch {
            XCTAssertEqual(error as? SponsorRefusal, .busy)
        }
        XCTAssertEqual(names(fake.pins), ["a", "big"])
    }

    /// The node answers an unreadable store as no pins; while the sponsor
    /// claims some, that is the node failing, not every pin gone.
    func testNoPinsWhileClaimingIsTheNodeFailing() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let seller = try await seller(fake, clock)
        await seller.pay(root: cidOf("a"), value: coins(1))
        await seller.pay(root: cidOf("b"), value: coins(1))
        _ = try await seller.store(root: cidOf("a"), volumes: [volume("a", 10)])
        let pins = fake.pins
        fake.pins = []
        do {
            _ = try await seller.store(root: cidOf("b"), volumes: [volume("b", 10)])
            XCTFail("no pins while a is claimed")
        } catch {
            XCTAssertEqual(error as? SponsorRefusal, .busy)
        }
        fake.pins = pins
        let held = await seller.ledger.state
        XCTAssertEqual(names(Set(held.groups.keys)), ["a"])
        XCTAssertEqual(names(held.claimed), ["a"])

        fake.pins = []
        let restarted = try await self.seller(fake, clock)
        let state = await restarted.ledger.state
        XCTAssertEqual(state, held, "the boot reconcile waits for a real answer")
    }

    /// Stores wait their turn instead of being refused.
    func testConcurrentStoresBothLand() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let seller = try await seller(fake, clock)
        await seller.pay(root: cidOf("a"), value: coins(1))
        await seller.pay(root: cidOf("b"), value: coins(1))
        async let a = seller.store(root: cidOf("a"), volumes: [volume("a", 10)])
        async let b = seller.store(root: cidOf("b"), volumes: [volume("b", 10)])
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
        let unfunded = await refusal(cidOf("a"), [volume("a", 10)])
        XCTAssertEqual(unfunded, .unfunded, "nothing is pinned before work pays for it")
        await seller.pay(root: cidOf("a"), value: coins(1))
        let tooBig = await refusal(cidOf("a"), [volume("a", 201)])
        XCTAssertEqual(tooBig, .groupTooBig)
        let neverFits = await refusal(cidOf("a"), [volume("a", 101)])
        XCTAssertEqual(neverFits, .neverFits)
        let missing = await refusal(cidOf("a"), [volume("a", 10), StorageNode.Volume(cid: cidOf("gone"))])
        XCTAssertEqual(missing, .volumeUnavailable)
        let huge = StorageNode.Volume(cid: cidOf("a"), entries: [cidOf("a"): Data(count: StorageNode.largestBody)])
        let tooBigToPin = await refusal(cidOf("a"), [huge])
        XCTAssertEqual(tooBigToPin, .volumeTooBig, "past the node's body limit")
        let rootless = await refusal(cidOf("a"), [volume("b", 10)])
        XCTAssertEqual(rootless, .draft("volumes lists each Volume once, the root among them"))

        // The node refuses the second Volume's bytes: the first is unpinned
        // again, and the group is not held.
        let bad = StorageNode.Volume(cid: cidOf("bad"), entries: [cidOf("bad"): Data(count: 10)])
        let badBytes = await refusal(cidOf("a"), [volume("a", 10), bad])
        XCTAssertEqual(badBytes, .badVolume)
        XCTAssertEqual(names(fake.pins), [])
        XCTAssertEqual(fake.unpinned.suffix(2).map(nameOf), ["a", "bad"])
        let a = await seller.status(cidOf("a"))
        XCTAssertFalse(a.held)
        let claimed = await seller.ledger.state.claimed
        XCTAssertEqual(names(claimed), [])
    }

    /// The ledger survives a restart, and on boot is matched to the node: a
    /// group missing a Volume is dropped and what only it used is unpinned.
    func testStateSurvivesARestartAndIsReconciled() async throws {
        let fake = FakeNode()
        let clock = Clock()
        let first = try await seller(fake, clock)
        await first.pay(root: cidOf("a"), value: coins(1))
        await first.pay(root: cidOf("b"), value: coins(2))
        _ = try await first.store(root: cidOf("a"), volumes: [volume("a", 10), volume("shared", 10)])
        _ = try await first.store(root: cidOf("b"), volumes: [volume("b", 10), volume("shared", 10)])
        await first.pay(root: cidOf("b"), value: coins(1))
        await first.pay(root: cidOf("unheld"), value: coins(1))
        clock.now = 10
        await first.maintain()
        let saved = await first.ledger.state

        let restarted = try await seller(fake, clock)
        let state = await restarted.ledger.state
        XCTAssertEqual(state, saved)
        let b = await restarted.status(cidOf("b"))
        XCTAssertEqual(b.credit, 3 * exp2(-0.01), accuracy: 1e-9)
        XCTAssertTrue(b.held)

        // b's own Volume went from the node while the sponsor was down.
        fake.pins.remove(cidOf("b"))
        let reconciled = try await seller(fake, clock)
        let held = await names(Set(reconciled.ledger.state.groups.keys))
        XCTAssertEqual(held, ["a"])
        XCTAssertEqual(names(fake.pins), ["a", "shared"], "a still uses shared")
        await reconciled.pay(root: cidOf("c"), value: coins(1))
        let c = try await reconciled.store(root: cidOf("c"), volumes: [volume("c", 10)])
        XCTAssertTrue(c.held)
        let reloaded = try StorageLedger.load(from: file)
        XCTAssertEqual(names(Set(reloaded.groups.keys)), ["a", "c"])
        XCTAssertEqual(names(reloaded.claimed), ["a", "c", "shared"])
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
