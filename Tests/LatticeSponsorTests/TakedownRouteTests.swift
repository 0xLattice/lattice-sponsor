import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import Lattice
@testable import LatticeSponsor
import LatticeSponsorCore
import XCTest

/// `POST /takedown`, as the operator (or anyone else) sees it.
final class TakedownRouteTests: XCTestCase {
    /// The node's pins, in memory; it refuses every unpin while `refusing`.
    private final class FakeNode: @unchecked Sendable {
        private let lock = NSLock()
        private var _pins: Set<String>
        private var _refusing = false

        init(pins: Set<String>) { _pins = pins }

        var pins: Set<String> { lock.withLock { _pins } }
        var refusing: Bool {
            get { lock.withLock { _refusing } }
            set { lock.withLock { _refusing = newValue } }
        }

        var node: SponsorNode {
            SponsorNode(base: URL(string: "http://127.0.0.1:8080")!, authorization: { nil }) { request in
                let url = request.url!
                let status = self.lock.withLock { () -> Int in
                    guard request.httpMethod == "DELETE", url.path.hasPrefix("/pins/") else { return 404 }
                    if self._refusing { return 503 }
                    return self._pins.remove(url.lastPathComponent) == nil ? 404 : 200
                }
                return (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private var directory: URL!
    private var cookie: URL { directory.appendingPathComponent(".cookie") }
    private static let operatorHeaders: HTTPFields = [
        .authorization: "Basic " + Data("__cookie__:secret".utf8).base64EncodedString(), .contentType: "application/json",
    ]
    private static let body = ByteBuffer(string: #"{"cid":"root"}"#)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("takedown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("__cookie__:secret\n".utf8).write(to: cookie)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A storage ledger holding `root`, pinned, with Volumes `root` and `leaf`.
    private func storage() throws -> StorageLedger {
        let file = directory.appendingPathComponent("storage.json")
        try Data(#"[{"root":"root","bytes":10,"volumes":["leaf","root"]}]"#.utf8).write(to: file)
        return try StorageLedger(budget: 100, rates: [["Nexus"]: 16], file: file)
    }

    private func app(storage: StorageLedger?, node: SponsorNode) throws -> some ApplicationProtocol {
        let pair = CryptoUtils.generateKeyPair()
        let keyFile = directory.appendingPathComponent("key.json")
        try JSONEncoder().encode(["privateKey": pair.privateKey, "publicKey": pair.publicKey]).write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        let sponsor = Sponsor(
            ledger: SponsorLedger(shareTarget: .max), rpc: SponsorRPC(base: URL(string: "http://127.0.0.1:8080")!, cookieFile: cookie),
            key: try SponsorKey(file: keyFile.path), minimumFee: 0, mostPay: nil, tokenKey: SymmetricKey(size: .bits256),
            storage: storage, serving: ServingCredit(rates: [:]), pinNode: node, payTo: nil, coinDepth: 6,
            payments: nil, funds: nil, fundedOnly: false
        )
        let router = Router()
        router.add(middleware: sponsorCORS())
        addOperatorRoutes(to: router, sponsor: sponsor, cookie: cookie)
        return Application(router: router)
    }

    func testWithoutTheCookieNothingIsTakenDown() async throws {
        let fake = FakeNode(pins: ["root", "leaf"])
        try await app(storage: try storage(), node: fake.node).test(.router) { client in
            try await client.execute(uri: "/takedown", method: .post, headers: [.contentType: "application/json"], body: Self.body) {
                XCTAssertEqual($0.status, .unauthorized)
            }
        }
        XCTAssertEqual(fake.pins, ["root", "leaf"])
    }

    func testWithoutSellStorageItIsNotFound() async throws {
        try await app(storage: nil, node: FakeNode(pins: []).node).test(.router) { client in
            try await client.execute(uri: "/takedown", method: .post, headers: Self.operatorHeaders, body: Self.body) {
                XCTAssertEqual($0.status, .notFound)
            }
        }
    }

    func testARefusedUnpinKeepsTheCIDBlockedAndARetryReleasesIt() async throws {
        let fake = FakeNode(pins: ["root", "leaf", "mine"])
        fake.refusing = true
        try await app(storage: try storage(), node: fake.node).test(.router) { client in
            try await client.execute(uri: "/takedown", method: .post, headers: Self.operatorHeaders, body: Self.body) {
                XCTAssertEqual($0.status, .badGateway)
                XCTAssertEqual(String(buffer: $0.body), #"{"error":{"message":"notUnpinned"}}"#)
            }
            fake.refusing = false
            try await client.execute(uri: "/takedown", method: .post, headers: Self.operatorHeaders, body: Self.body) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(String(buffer: $0.body), #"{"cid":"root","unpinned":["leaf","root"]}"#)
            }
        }
        XCTAssertEqual(fake.pins, ["mine"], "a pin the sponsor did not make is left alone")
        let restarted = try StorageLedger(budget: 100, rates: [["Nexus"]: 16], file: directory.appendingPathComponent("storage.json"))
        XCTAssertEqual(restarted.blocked, ["root", "leaf"])
        XCTAssertEqual(restarted.stored, [:])
    }
}
