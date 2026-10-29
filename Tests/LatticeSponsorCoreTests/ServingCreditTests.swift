import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import UInt256
@testable import LatticeSponsorCore

private let market = ["Nexus", "Market"]

/// The node's serving routes, in memory: `/serving-terms` and the
/// operator's `/serving-balance`.
private final class FakeNode: @unchecked Sendable {
    private let lock = NSLock()
    private var _down = false
    private var _posts: [(peer: String, bytes: Int, authorization: String?)] = []
    var refused: Set<String> = []
    let terms: String

    init(terms: String) { self.terms = terms }

    var down: Bool {
        get { lock.withLock { _down } }
        set { lock.withLock { _down = newValue } }
    }

    var posts: [(peer: String, bytes: Int, authorization: String?)] { lock.withLock { _posts } }

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
        case ("GET", "/serving-terms"):
            return respond(200, terms)
        case ("POST", "/serving-balance"):
            struct Body: Decodable { let peer: String; let bytes: Int }
            let body = try JSONDecoder().decode(Body.self, from: request.httpBody ?? Data())
            guard body.bytes > 0, !refused.contains(body.peer) else { return respond(400, "bad peer") }
            lock.withLock {
                _posts.append((body.peer, body.bytes, request.value(forHTTPHeaderField: "Authorization")))
            }
            return respond(200, #"{"peer":"\#(body.peer)","balance":\#(body.bytes)}"#)
        default:
            return respond(404, "")
        }
    }
}

private let terms = """
    {"payTo":null,"rates":{"Nexus/Market":{"bytesPerCoin":3},"Nexus":{"bytesPerCoin":0}},"depth":2,"workURL":null}
    """

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

    func testTheNodesTermsAreBytesPerCoinByChainPath() async throws {
        let rates = try await FakeNode(terms: terms).node.rates()
        XCTAssertEqual(rates, [market: 3, ["Nexus"]: 0])
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
        try serving.credit(peer: "peer-a", value: value, on: market)
        XCTAssertEqual(serving.owed(to: "peer-a"), 1, "1.875 bytes, rounded down")
        XCTAssertEqual(serving.take(), ["peer-a": 1])
        XCTAssertEqual(serving.take(), [:], "0.875 of a byte stays owed")

        try serving.credit(peer: "peer-a", value: ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 1), on: market)
        XCTAssertEqual(serving.take(), ["peer-a": 2], "0.875 + 1.875")

        XCTAssertEqual(ledger.credit(of: "a", on: market), .zero, "serving work is not fee credit")
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: market, balance: 100, holdUntil: 600_000, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit)
        }
    }

    func testBytesSaturateAndTheRestStaysOwed() throws {
        var serving = ServingLedger()
        serving.install(rates: [market: Int.max])
        try serving.credit(peer: "p", value: UInt256(4) * SponsorLedger.unit, on: market)
        XCTAssertEqual(serving.take(), ["p": .max])
        XCTAssertEqual(serving.take(), ["p": .max], "one post saturates; the rest is not lost")

        try serving.credit(peer: "q", value: .max, on: market)
        XCTAssertEqual(serving.owed(to: "q"), .max, "the product saturates")
    }

    func testAChainWithoutARateIsRefused() throws {
        var serving = ServingLedger()
        serving.install(rates: [market: 3, ["Nexus"]: 0])
        for chain in [["Nexus"], ["Nexus", "Absent"]] {
            XCTAssertThrowsError(try serving.rate(on: chain)) {
                XCTAssertEqual($0 as? SponsorRefusal, .noServingRate)
            }
            XCTAssertThrowsError(try serving.credit(peer: "p", value: SponsorLedger.unit, on: chain)) {
                XCTAssertEqual($0 as? SponsorRefusal, .noServingRate)
            }
        }
        XCTAssertEqual(serving.take(), [:])
    }

    /// Bytes the node does not take while it is down stay owed and are posted
    /// once it is back; a peer the node refuses is dropped.
    func testBytesAreRetriedWhileTheNodeIsDown() async throws {
        let fake = FakeNode(terms: terms)
        var serving = ServingLedger()
        serving.install(rates: [market: 3])
        for peer in ["a", "b"] {
            try serving.credit(peer: peer, value: UInt256(10) * SponsorLedger.unit, on: market)
        }

        fake.down = true
        for (peer, bytes) in await fake.node.post(serving.take()) {
            serving.restore(peer: peer, bytes: bytes)
        }
        XCTAssertTrue(fake.posts.isEmpty)
        XCTAssertEqual(serving.owed(to: "a"), 30)

        fake.down = false
        try serving.credit(peer: "a", value: SponsorLedger.unit, on: market)
        fake.refused = ["b"]
        let unposted = await fake.node.post(serving.take())
        XCTAssertEqual(unposted, [:])
        XCTAssertEqual(fake.posts.map(\.peer), ["a"], "b is refused and dropped")
        XCTAssertEqual(fake.posts.first?.bytes, 33)
        XCTAssertEqual(fake.posts.first?.authorization, "Basic cookie")
        XCTAssertEqual(serving.take(), [:])
    }
}
