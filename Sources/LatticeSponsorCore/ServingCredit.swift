// Serving credit: work that buys a reader priority on the node's serving
// instead of fee credit. The node sells serving by the byte, per peer, at a
// rate in bytes per coin (the chain's smallest unit) of each chain it names. A reader's share is
// valued as for a fee (its chance of that chain's block, times its reward),
// converted at the chain's rate, and posted to the node as the peer's serving
// balance, a batch per peer at each refresh.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import UInt256

/// The serving bytes the sponsor owes each peer, not yet posted to the node.
public struct ServingLedger: Sendable {
    /// Bytes per coin (the chain's smallest unit) on each chain, from the
    /// node's `/serving-terms`.
    public private(set) var rates: [[String]: Int] = [:]
    /// How long what is under a byte outlives the peer's last share.
    public let lifetime: Int64
    /// Each peer's bytes, scaled by 2^64 as fee credit is, so a share worth
    /// less than a byte still counts.
    private var pending: [String: (bytes: UInt256, lastShare: Int64)] = [:]

    public init(lifetime: Int64 = 3_600_000) {
        self.lifetime = lifetime
    }

    public mutating func install(rates: [[String]: Int]) {
        self.rates = rates
    }

    /// The chain's bytes per coin.
    public func rate(on chainPath: [String]) throws -> Int {
        guard let rate = rates[chainPath], rate > 0 else { throw SponsorRefusal.noServingRate }
        return rate
    }

    /// Owe `peer` a share's `value` on `chainPath` (units scaled by 2^64),
    /// at the chain's rate, saturating.
    public mutating func credit(peer: String, value: UInt256, on chainPath: [String], now: Int64) throws {
        let rate = try rate(on: chainPath)
        let (bytes, overflow) = value.multipliedReportingOverflow(by: UInt256(UInt64(rate)))
        let (sum, overflowed) = (pending[peer]?.bytes ?? .zero).addingReportingOverflow(overflow ? .max : bytes)
        pending[peer] = (overflowed ? .max : sum, now)
    }

    /// The whole bytes owed `peer`, rounded down and saturating.
    public func owed(to peer: String) -> Int {
        Self.whole(pending[peer]?.bytes ?? .zero)
    }

    /// Each peer's whole bytes, at most `Int.max` a post, taken off what it
    /// is owed; what is under a byte stays owed until `lifetime` after the
    /// peer's last share.
    public mutating func take(now: Int64) -> [String: Int] {
        var taken: [String: Int] = [:]
        for (peer, held) in pending {
            let bytes = Self.whole(held.bytes)
            let rest = held.bytes - UInt256(UInt64(bytes)) * SponsorLedger.unit
            if bytes > 0 { taken[peer] = bytes }
            pending[peer] = rest == .zero || (bytes == 0 && now - held.lastShare >= lifetime)
                ? nil : (rest, held.lastShare)
        }
        return taken
    }

    /// Owe `bytes` back to `peer`: a post that did not reach the node.
    public mutating func restore(peer: String, bytes: Int, now: Int64) {
        let held = pending[peer]
        let (sum, overflow) = (held?.bytes ?? .zero)
            .addingReportingOverflow(UInt256(UInt64(bytes)) * SponsorLedger.unit)
        pending[peer] = (overflow ? .max : sum, held?.lastShare ?? now)
    }

    private static func whole(_ scaled: UInt256) -> Int {
        let bytes = scaled / SponsorLedger.unit
        return bytes > UInt256(UInt64(Int.max)) ? .max : Int(bytes.words[0])
    }
}

/// The node's serving routes: its terms, a public read, and the peer's
/// serving balance, written on the cookie-authenticated operator surface.
public struct ServingNode: Sendable {
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

    /// Bytes per coin on each chain the node sells serving on.
    public func rates() async throws -> [[String]: Int] {
        struct Terms: Decodable {
            struct Rate: Decodable { let bytesPerCoin: Int }
            let rates: [String: Rate]
        }
        let terms = try JSONDecoder().decode(Terms.self, from: try await call(request("serving-terms")))
        return Dictionary(
            terms.rates.map { ($0.key.components(separatedBy: "/"), $0.value.bytesPerCoin) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Add `bytes` to `peer`'s serving balance.
    public func add(peer: String, bytes: Int) async throws {
        struct Body: Encodable {
            let peer: String
            let bytes: Int
        }
        var request = request("serving-balance")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(peer: peer, bytes: bytes))
        _ = try await call(request)
    }

    /// Post each peer's bytes, and return what is still owed. A peer the
    /// node refuses (4xx) is dropped, and one it fails on (5xx) is kept; once
    /// the node cannot be reached, the rest waits for the next post.
    public func post(_ owed: [String: Int]) async -> [String: Int] {
        var unposted: [String: Int] = [:]
        var reachable = true
        for (peer, bytes) in owed {
            guard reachable else {
                unposted[peer] = bytes
                continue
            }
            do {
                try await add(peer: peer, bytes: bytes)
            } catch Failure.status(let status) where (400..<500).contains(status) {
                print("the node refused serving balance for \(peer) (\(status)); dropped \(bytes) bytes")
            } catch Failure.status(let status) {
                print("serving balance post for \(peer) failed (\(status))")
                unposted[peer] = bytes
            } catch {
                print("serving balance post failed: \(error)")
                reachable = false
                unposted[peer] = bytes
            }
        }
        return unposted
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let authorization = authorization() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func call(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.status(status) }
        return data
    }
}
