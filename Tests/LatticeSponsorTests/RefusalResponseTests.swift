import Foundation
import Hummingbird
import HummingbirdTesting
@testable import LatticeSponsor
import LatticeSponsorCore
import XCTest

/// What a web page sees when the sponsor refuses it.
final class RefusalResponseTests: XCTestCase {
    private func app() -> some ApplicationProtocol {
        let router = Router()
        router.add(middleware: sponsorCORS())
        router.post("busy") { _, _ -> String in try await refusing { throw SponsorRefusal.busy } }
        router.post("unknown") { _, _ -> String in try await refusing { throw SponsorRefusal.unknownAssignment } }
        router.post("notDeepEnough") { _, _ -> String in try await refusing { throw SponsorRefusal.notDeepEnough } }
        router.post("insufficientFloat") { _, _ -> String in try await refusing { throw SponsorRefusal.insufficientFloat } }
        router.post("unpriceable") { _, _ -> String in try await refusing { throw SponsorRefusal.unpriceable } }
        router.post("blocked") { _, _ -> String in try await refusing { throw SponsorRefusal.blocked } }
        router.post("operator") { request, _ -> String in
            try requireOperator(request, cookie: Self.cookie)
            return "ok"
        }
        return Application(router: router)
    }

    private static let cookie = FileManager.default.temporaryDirectory.appendingPathComponent("sponsor-cookie-\(UUID().uuidString)")

    func testATakenDownCIDIsRefusedAsUnavailableForLegalReasons() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/blocked", method: .post, headers: Self.origin) { response in
                XCTAssertEqual(response.status.code, 451)
                XCTAssertEqual(String(buffer: response.body), #"{"error":{"message":"blocked"}}"#)
                XCTAssertNil(response.headers[.retryAfter], "it never clears")
            }
        }
    }

    func testAnOperatorRouteTakesOnlyTheNodesCookie() async throws {
        try Data("__cookie__:secret\n".utf8).write(to: Self.cookie)
        defer { try? FileManager.default.removeItem(at: Self.cookie) }
        let good = "Basic " + Data("__cookie__:secret".utf8).base64EncodedString()
        let bad = "Basic " + Data("__cookie__:guess".utf8).base64EncodedString()
        try await app().test(.router) { client in
            try await client.execute(uri: "/operator", method: .post) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/operator", method: .post, headers: [.authorization: bad]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await client.execute(uri: "/operator", method: .post, headers: [.authorization: good]) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    private static let origin: HTTPFields = [.origin: "https://app.example"]

    func testARefusalCarriesTheOriginHeaderAndItsNameAsJSON() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/unknown", method: .post, headers: Self.origin) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "*")
                XCTAssertEqual(String(buffer: response.body), #"{"error":{"message":"unknownAssignment"}}"#)
                XCTAssertNil(response.headers[.retryAfter], "fetching new work, not waiting, clears it")
            }
        }
    }

    func testABusyRefusalSaysWhenToRetryAndLetsThePageReadIt() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/busy", method: .post, headers: Self.origin) { response in
                XCTAssertEqual(response.status, .serviceUnavailable)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "*")
                XCTAssertEqual(response.headers[.retryAfter], "\(retryAfterSeconds)")
                XCTAssertEqual(response.headers[.accessControlExposeHeaders], "Retry-After")
                XCTAssertEqual(String(buffer: response.body), #"{"error":{"message":"busy"}}"#)
            }
        }
    }

    func testATooEarlyRefusalSaysWhenToRetry() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/notDeepEnough", method: .post, headers: Self.origin) { response in
                XCTAssertEqual(response.status.code, 425)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "*")
                XCTAssertEqual(response.headers[.retryAfter], "\(retryAfterSeconds)")
                XCTAssertEqual(response.headers[.accessControlExposeHeaders], "Retry-After")
            }
        }
    }

    func testARefusalThatMayNeverClearSaysNoRetry() async throws {
        try await app().test(.router) { client in
            for uri in ["/insufficientFloat", "/unpriceable"] {
                try await client.execute(uri: uri, method: .post, headers: Self.origin) { response in
                    XCTAssertEqual(response.status, .serviceUnavailable, uri)
                    XCTAssertEqual(response.headers[.accessControlAllowOrigin], "*", uri)
                    XCTAssertNil(response.headers[.retryAfter], uri)
                }
            }
        }
    }

    func testAPreflightIsAnswered() async throws {
        var preflight = Self.origin
        preflight[.accessControlRequestMethod] = "POST"
        let headers = preflight
        try await app().test(.router) { client in
            try await client.execute(uri: "/busy", method: .options, headers: headers) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "*")
                XCTAssertEqual(response.headers[.accessControlAllowMethods], "GET, POST, OPTIONS")
            }
        }
    }
}
