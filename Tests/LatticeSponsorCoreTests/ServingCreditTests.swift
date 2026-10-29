import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import UInt256
@testable import LatticeSponsorCore

private let market = ["Nexus", "Market"]

/// The node's operator route `/serving-balance`, in memory.
private final class FakeNode: @unchecked Sendable {
    private let lock = NSLock()
    private var _down = false
    private var _posts: [(peer: String, bytes: Int, authorization: String?)] = []
    /// Peers the node answers with a status other than 200.
    var failing: [String: Int] = [:]

    var down: Bool {
        get { locked { _down } }
        set { locked { _down = newValue } }
    }

    var posts: [(peer: String, bytes: Int, authorization: String?)] { locked { _posts } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var node: ServingNode {
        ServingNode(base: URL(string: "http://127.0.0.1:8080")!, authorization: { "Basic cookie" }) { request in
            try self.handle(request)
        }
    }

    private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        if down { throw URLError(.cannotConnectToHost) }
        let url = request.url!
        func respond(_ status: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        switch (request.httpMethod ?? "GET", url.path) {
        case ("POST", "/serving-balance"):
            struct Body: Decodable { let peer: String; let bytes: Int }
            let body = try JSONDecoder().decode(Body.self, from: request.httpBody ?? Data())
            guard body.bytes > 0 else { return respond(400, "bad bytes") }
            if let status = failing[body.peer] { return respond(status, "") }
            locked {
                _posts.append((body.peer, body.bytes, request.value(forHTTPHeaderField: "Authorization")))
            }
            return respond(200, #"{"peer":"\#(body.peer)","balance":\#(body.bytes)}"#)
        default:
            return respond(404, "")
        }
    }
}

final class ServingCreditTests: XCTestCase {
    /// A share on Market is 10/16 of a coin (as in `SponsorLedgerTests`);
    /// at 3 bytes per coin it buys 1.875 bytes.
    private let marketShare = UInt256(10) << 60

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

    /// A share's value converts at the chain's rate and rounds down to whole
    /// bytes; what is under a byte stays owed, and is never fee credit.
    func testWorkBuysBytesAtTheChainsRateRoundedDown() throws {
        var ledger = ledger()
        var serving = ServingLedger()
        serving.install(rates: [market: 3])
        let a = try ledger.assign(client: "a", on: market, peer: "peer-a", now: 0)
        XCTAssertEqual(a.peer, "peer-a")

        let value = try ledger.credit(assignment: a.id, nonce: 0, hash: UInt256(1), now: 1)
        XCTAssertEqual(value, marketShare)
        try serving.credit(peer: "peer-a", value: value, on: market, now: 1)
        XCTAssertEqual(serving.owed(to: "peer-a"), 1, "1.875 bytes, rounded down")
        XCTAssertEqual(serving.take(now: 2), ["peer-a": 1])
        XCTAssertEqual(serving.take(now: 2), [:], "0.875 of a byte stays owed")

        try serving.credit(peer: "peer-a", value: ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 1), on: market, now: 1)
        XCTAssertEqual(serving.take(now: 2), ["peer-a": 2], "0.875 + 1.875")

        XCTAssertEqual(ledger.credit(of: "a", on: market), .zero, "serving work is not fee credit")
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: market, balance: 100, holdUntil: 600_000, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit)
        }
    }

    func testBytesSaturateAndTheRestStaysOwed() throws {
        var serving = ServingLedger()
        serving.install(rates: [market: Int.max])
        try serving.credit(peer: "p", value: UInt256(4) * SponsorLedger.unit, on: market, now: 1)
        XCTAssertEqual(serving.take(now: 2), ["p": .max])
        XCTAssertEqual(serving.take(now: 2), ["p": .max], "one post saturates; the rest is not lost")

        try serving.credit(peer: "q", value: .max, on: market, now: 1)
        XCTAssertEqual(serving.owed(to: "q"), .max, "the product saturates")
    }

    func testAChainWithoutARateIsRefused() throws {
        var serving = ServingLedger()
        serving.install(rates: [market: 3, ["Nexus"]: 0])
        for chain in [["Nexus"], ["Nexus", "Absent"]] {
            XCTAssertThrowsError(try serving.rate(on: chain)) {
                XCTAssertEqual($0 as? SponsorRefusal, .noServingRate)
            }
            XCTAssertThrowsError(try serving.credit(peer: "p", value: SponsorLedger.unit, on: chain, now: 1)) {
                XCTAssertEqual($0 as? SponsorRefusal, .noServingRate)
            }
        }
        XCTAssertEqual(serving.take(now: 2), [:])
    }

    /// Bytes the node does not take while it is down stay owed and are posted
    /// once it is back; a peer the node refuses is dropped.
    func testBytesAreRetriedWhileTheNodeIsDown() async throws {
        let fake = FakeNode()
        var serving = ServingLedger()
        serving.install(rates: [market: 3])
        for peer in ["a", "b"] {
            try serving.credit(peer: peer, value: UInt256(10) * SponsorLedger.unit, on: market, now: 1)
        }

        fake.down = true
        for (peer, bytes) in await fake.node.post(serving.take(now: 2)) {
            serving.restore(peer: peer, bytes: bytes, now: 2)
        }
        XCTAssertTrue(fake.posts.isEmpty)
        XCTAssertEqual(serving.owed(to: "a"), 30)

        fake.down = false
        try serving.credit(peer: "a", value: SponsorLedger.unit, on: market, now: 1)
        let unposted = await fake.node.post(serving.take(now: 2))
        XCTAssertEqual(unposted, [:])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: fake.posts.map { ($0.peer, $0.bytes) }), ["a": 33, "b": 30])
        XCTAssertEqual(fake.posts.first?.authorization, "Basic cookie")
        XCTAssertEqual(serving.take(now: 2), [:])
    }

    /// A peer the node refuses (422) is dropped and one it fails on (5xx) is
    /// kept, and neither holds up the others.
    func testOnePeersFailureHoldsUpNoOther() async throws {
        let fake = FakeNode()
        fake.failing = ["refused": 422, "failing": 500]
        let unposted = await fake.node.post(["refused": 5, "failing": 6, "a": 7])
        XCTAssertEqual(unposted, ["failing": 6])
        XCTAssertEqual(fake.posts.map(\.peer), ["a"])
    }

    /// An answer about the sponsor, not the peer (here 401), drops nothing.
    func testAnUnauthorizedPostKeepsEveryPeer() async throws {
        let fake = FakeNode()
        fake.failing = ["a": 401, "b": 401]
        let unposted = await fake.node.post(["a": 5, "b": 6])
        XCTAssertEqual(unposted, ["a": 5, "b": 6])
        XCTAssertTrue(fake.posts.isEmpty)
    }

    /// What is under a byte is dropped once the peer has been idle a lifetime.
    func testUnderAByteExpires() throws {
        var serving = ServingLedger(lifetime: 100)
        serving.install(rates: [market: 1])
        try serving.credit(peer: "p", value: SponsorLedger.unit / UInt256(2), on: market, now: 0)
        XCTAssertEqual(serving.take(now: 99), [:])
        try serving.credit(peer: "p", value: SponsorLedger.unit / UInt256(2), on: market, now: 99)
        XCTAssertEqual(serving.take(now: 150), ["p": 1], "half a byte twice")

        try serving.credit(peer: "q", value: SponsorLedger.unit / UInt256(2), on: market, now: 200)
        XCTAssertEqual(serving.take(now: 300), [:])
        try serving.credit(peer: "q", value: SponsorLedger.unit / UInt256(2), on: market, now: 301)
        XCTAssertEqual(serving.take(now: 302), [:], "the first half expired")
    }
}
