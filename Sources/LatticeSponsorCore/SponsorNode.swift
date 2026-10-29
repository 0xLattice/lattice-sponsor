// The node's loopback routes the sponsor reads and writes for storage and coin
// payment, with the RPC cookie.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SponsorNode: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let base: URL
    let authorization: @Sendable () -> String?
    let send: Send

    public init(
        base: URL,
        authorization: @escaping @Sendable () -> String?,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) {
        self.base = base
        self.authorization = authorization
        self.send = send
    }

    public enum Failure: Error, Equatable {
        case status(Int)
    }

    func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let authorization = authorization() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func call(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.status(status) }
        return data
    }
}
