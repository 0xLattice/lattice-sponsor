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
        return Application(router: router)
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
