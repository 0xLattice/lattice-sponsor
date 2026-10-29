import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import UInt256
@testable import LatticeSponsorCore

private let market = ["Nexus", "Market"]
private let peer = String(repeating: "ab", count: 32)

/// The node's `POST /serving-credit`, answering `status`, recording each body.
private final class FakeServing: @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [[String: AnyHashable]] = []
    let status: Int

    init(status: Int = 200) { self.status = status }

    var posts: [[String: AnyHashable]] { lock.withLock { _posts } }

    var node: SponsorNode {
        SponsorNode(base: URL(string: "http://127.0.0.1:8080")!, authorization: { "Basic cookie" }) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/serving-credit")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic cookie")
            let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: AnyHashable]
            self.lock.withLock { self._posts.append(body) }
            let answer = Data(#"{"peer":"\#(peer)","standing":1}"#.utf8)
            return (answer, HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

final class ServingCreditTests: XCTestCase {
    private let serving = ServingCredit(rates: [market: 1024])

    /// A share target 2^4 easier than Market's block paying 10: a share is
    /// worth 10/16 coin, 640 bytes at 1024 per coin.
    func testWorkCreditsTheNodeByValueTimesRateRoundedDown() async throws {
        let price = ChainPrice(target: (UInt256(1) << 204) - UInt256(1), height: 7, reward: 10)
        var ledger = SponsorLedger(shareTarget: (UInt256(1) << 208) - UInt256(1), rangeSize: 100)
        ledger.install(SponsorTemplate(
            workID: "w1", prefixHex: "00", prices: [market: price], submitTarget: .zero, expiresAt: 30_000
        ), now: 0)
        let assignment = try ledger.assign(client: "a", on: market, peer: peer, now: 0)
        let value = try ledger.credit(assignment: assignment.id, nonce: 1, hash: UInt256(1), now: 1)
        XCTAssertEqual(ledger.credit(of: "a", on: market), .zero, "serving work is not fee credit")

        let fake = FakeServing()
        try await fake.node.creditServing(peer: peer, bytes: try serving.bytes(for: value, on: market))
        XCTAssertEqual(fake.posts, [["peer": peer, "bytes": 640]])

        XCTAssertEqual(try serving.bytes(for: SponsorLedger.unit / UInt256(1025), on: market), 0)
        try await fake.node.creditServing(peer: peer, bytes: 0)
        XCTAssertEqual(fake.posts.count, 1, "less than a byte credits nothing")
        XCTAssertEqual(try serving.bytes(for: .max, on: market), .max, "saturating")
    }

    func testPayCreditsTheNode() async throws {
        let fake = FakeServing()
        try await fake.node.creditServing(peer: peer, bytes: try serving.bytes(for: UInt256(4) * SponsorLedger.unit, on: market))
        XCTAssertEqual(fake.posts, [["peer": peer, "bytes": 4096]])

        let store = CoinPayment(chain: "Nexus/Market", txCID: "tx1", signer: "s", signature: "", store: "root")
        let served = CoinPayment(chain: "Nexus/Market", txCID: "tx1", signer: "s", signature: "", peer: peer)
        XCTAssertNotEqual(store.message, served.message, "the signature binds the peer")
        XCTAssertTrue(served.message.hasSuffix(":\(peer)"))
    }

    func testAChainWithoutARateIsRefused() {
        XCTAssertThrowsError(try serving.rate(on: ["Nexus"])) { XCTAssertEqual($0 as? SponsorRefusal, .noServingRate) }
    }

    func testANodeFailureIsReported() async {
        do {
            try await FakeServing(status: 500).node.creditServing(peer: peer, bytes: 1)
            XCTFail("a failed post is reported")
        } catch {
            XCTAssertEqual(error as? SponsorRefusal, .servingNotCredited)
        }
    }

    func testPeerAndStoreAreExclusive() async {
        XCTAssertThrowsError(try ServingCredit.check(peer: peer, store: "root"))
        XCTAssertThrowsError(try ServingCredit.check(peer: peer.uppercased(), store: nil), "lowercase hex only")
        XCTAssertNoThrow(try ServingCredit.check(peer: peer, store: nil))
        let node = FakeServing().node
        for payment in [
            CoinPayment(chain: "Nexus", txCID: "tx1", signer: "s", signature: "", store: "root", peer: peer),
            CoinPayment(chain: "Nexus", txCID: "tx1", signer: "s", signature: ""),
        ] {
            do {
                _ = try await node.verify(payment, payTo: "p", depth: 0)
                XCTFail("one of store and peer")
            } catch {
                guard case .draft = error as? SponsorRefusal else { return XCTFail("\(error)") }
            }
        }
    }

    func testTheTermsListServingRates() throws {
        let terms = SponsorTerms(payTo: nil, depth: 6, storageRates: [:], servingRates: [market: 1024])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(terms)) as! [String: Any]
        XCTAssertEqual(json["servingRates"] as? [String: Int], ["Nexus/Market": 1024])
    }
}
