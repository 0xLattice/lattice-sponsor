import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import Lattice
import cashew
import LatticeNodeAPI
import UInt256
@testable import LatticeSponsorCore

private let market = ["Nexus", "Market"]
private let payer = CryptoUtils.generateKeyPair()
private let payerAddress = CryptoUtils.createAddress(from: payer.publicKey)
private let payTo = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)

/// One Market transfer carried at height 10, as the node's explorer and
/// transaction routes answer it, and its pins, in memory.
private final class FakeChain: @unchecked Sendable {
    private let lock = NSLock()
    private var _pins: Set<String> = []
    let tip: UInt64
    let actions: [ExplorerAccountAction]

    init(tip: UInt64 = 16, actions: [ExplorerAccountAction] = [
        ExplorerAccountAction(owner: payerAddress, delta: -5), ExplorerAccountAction(owner: payTo, delta: 4),
    ]) {
        self.tip = tip
        self.actions = actions
    }

    var pins: Set<String> { lock.withLock { _pins } }

    var node: SponsorNode {
        SponsorNode(base: URL(string: "http://127.0.0.1:8080")!, authorization: { "Basic cookie" }) { request in
            try self.handle(request)
        }
    }

    private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        func respond(_ status: Int, _ body: Data = Data()) -> (Data, URLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/api/transaction/tx1"):
            XCTAssertEqual(query, [URLQueryItem(name: "chainPath", value: "Nexus/Market")])
            return respond(200, try JSONEncoder().encode(ExplorerTransaction(
                txCID: "tx1", blockHeight: 10, blockHash: "block10", nonce: 0, signers: [payerAddress],
                chainPath: market, chain: market, accountActions: actions,
                depositActions: [], receiptActions: [], withdrawalActions: []
            )))
        case ("GET", "/api/block/latest"):
            return respond(200, try JSONEncoder().encode(ExplorerLatestBlock(
                height: tip, hash: "block\(tip)", transactionCount: 0, timestamp: 0, previousBlock: nil, rewardRecipient: nil
            )))
        case ("GET", "/api/block/10"):
            return respond(200, Data(#"{"hash":"block10"}"#.utf8))
        case ("GET", "/transactions/tx1"):
            let body = TransactionBody(
                accountActions: [], actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
                signers: [payerAddress], nonce: 0, chainPath: market
            )
            struct Raw: Encodable { let cid: String; let transaction: Transaction }
            let transaction = Transaction(signatures: [payer.publicKey: "00"], body: try HeaderImpl(node: body))
            return respond(200, try JSONEncoder().encode(Raw(cid: "tx1", transaction: transaction)))
        case ("POST", "/pins"):
            struct Pin: Decodable { let cid: String }
            let pin = try JSONDecoder().decode(Pin.self, from: request.httpBody ?? Data())
            lock.withLock { _ = _pins.insert(pin.cid) }
            return respond(200, Data(#"{"pins":[]}"#.utf8))
        default:
            return respond(404)
        }
    }
}

/// `tx1` claimed by `key` for `store`.
private func claim(store: String = "root", key: String = payer.privateKey, signer: String = payerAddress) -> CoinPayment {
    let unsigned = CoinPayment(chain: "Nexus/Market", txCID: "tx1", signer: signer, signature: "", store: store)
    return CoinPayment(
        chain: "Nexus/Market", txCID: "tx1", signer: signer,
        signature: CryptoUtils.sign(message: unsigned.message, privateKeyHex: key)!, store: store
    )
}

final class CoinPaymentTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("payments-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    private func refusal(_ chain: FakeChain, _ payment: CoinPayment) async -> SponsorRefusal? {
        do {
            _ = try await chain.node.verify(payment, payTo: payTo, depth: 6)
            return nil
        } catch {
            return error as? SponsorRefusal
        }
    }

    func testATransferIsCreditedOnceAndAReplayIsRefused() async throws {
        let coins = try await FakeChain().node.verify(claim(), payTo: payTo, depth: 6)
        XCTAssertEqual(coins, 4, "what it pays payTo, net")

        var payments = try PaymentLedger(file: file)
        try payments.claim("tx1")
        XCTAssertThrowsError(try payments.claim("tx1"), "held while it is checked") {
            XCTAssertEqual($0 as? SponsorRefusal, .alreadyCredited)
        }
        try payments.release("tx1", credit: true)
        XCTAssertThrowsError(try payments.claim("tx1")) { XCTAssertEqual($0 as? SponsorRefusal, .alreadyCredited) }
        var restarted = try PaymentLedger(file: file)
        XCTAssertThrowsError(try restarted.claim("tx1"), "across a restart") {
            XCTAssertEqual($0 as? SponsorRefusal, .alreadyCredited)
        }

        try payments.claim("tx2")
        try payments.release("tx2", credit: false)
        XCTAssertNoThrow(try payments.claim("tx2"), "one refused is not credited")
    }

    func testATransferNotDeepEnoughIsRefusedUntilItIs() async throws {
        let shallow = await refusal(FakeChain(tip: 15), claim())
        XCTAssertEqual(shallow, .notDeepEnough, "5 blocks on top of 10")
        let deep = await refusal(FakeChain(tip: 16), claim())
        XCTAssertNil(deep)
    }

    func testOnlyASignerClaimsIt() async throws {
        let other = CryptoUtils.generateKeyPair()
        let wrong = await refusal(FakeChain(), claim(key: other.privateKey, signer: CryptoUtils.createAddress(from: other.publicKey)))
        XCTAssertEqual(wrong, .notSigner)
    }

    func testTheSignatureBindsTheUpload() async throws {
        let signed = claim()
        let moved = CoinPayment(chain: "Nexus/Market", txCID: "tx1", signer: payerAddress, signature: signed.signature, store: "other")
        let refused = await refusal(FakeChain(), moved)
        XCTAssertEqual(refused, .invalidSignature)
    }

    func testATransferPayingPayToNothingIsRefused() async throws {
        for actions in [
            [ExplorerAccountAction(owner: payerAddress, delta: 0)],
            [ExplorerAccountAction(owner: payTo, delta: 4), ExplorerAccountAction(owner: payTo, delta: -4)],
        ] {
            let refused = await refusal(FakeChain(actions: actions), claim())
            XCTAssertEqual(refused, .noPayment)
        }
    }

    /// 4 coins at 16 bytes per coin pay for a 60-byte upload, which is pinned.
    func testStorageCreditPinsAnUpload() async throws {
        let chain = FakeChain()
        let storageFile = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageFile) }
        var storage = try StorageLedger(budget: 100, rates: [market: 16], file: storageFile)
        let root = StoreVolume(cid: "root", entries: ["root": Data(repeating: 7, count: 60).base64EncodedString()])
        _ = try storage.upload(root: "root", volumes: [root], now: 0)

        let coins = try await chain.node.verify(claim(store: "root"), payTo: payTo, depth: 6)
        try storage.credit(root: "root", value: UInt256(coins) * SponsorLedger.unit, on: market, now: 1)
        let upload = try XCTUnwrap(storage.takePaid("root"))
        try await chain.node.pin(upload)
        try storage.finish("root", pinned: true)
        XCTAssertEqual(chain.pins, ["root"])
        XCTAssertEqual(storage.status(of: "root")?.stored, true)
    }
}
