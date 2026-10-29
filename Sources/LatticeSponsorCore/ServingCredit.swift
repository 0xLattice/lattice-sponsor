// Serving credit: work or coin that raises a peer's standing on the node, its
// share of serving slots when the node is busy. Each accepted share, and each
// payment, is posted to the node's `POST /serving-credit` at once, at
// --serving-rate bytes per coin; a post that fails loses that credit.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LatticeNodeAPI
import UInt256

public struct ServingCredit: Sendable {
    /// Bytes per coin (the chain's smallest unit) on each chain.
    public let rates: [[String]: Int]

    public init(rates: [[String]: Int]) {
        self.rates = rates
    }

    public func rate(on chainPath: [String]) throws -> Int {
        guard let rate = rates[chainPath], rate > 0 else { throw SponsorRefusal.noServingRate }
        return rate
    }

    /// `value` (units scaled by 2^64) at the chain's rate, in whole bytes,
    /// rounded down and saturating.
    public func bytes(for value: UInt256, on chainPath: [String]) throws -> Int {
        let (product, overflow) = value.multipliedReportingOverflow(by: UInt256(UInt64(try rate(on: chainPath))))
        let bytes = product / SponsorLedger.unit
        return overflow || bytes > UInt256(UInt64(Int.max)) ? .max : Int(bytes.words[0])
    }

    /// A peer is named by its 64 lowercase hex Ed25519 key, and credit goes to
    /// a peer or an upload, not both.
    public static func check(peer: String?, store: String?) throws {
        guard let peer else { return }
        guard store == nil else { throw SponsorRefusal.draft("peer and store are exclusive") }
        guard peer.utf8.count == 64, peer.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SponsorRefusal.draft("peer is not 64 lowercase hex")
        }
    }
}

/// `GET /terms`.
public struct SponsorTerms: Codable, Sendable {
    public let payTo: String?
    @DecimalString public var depth: UInt64
    /// Bytes per coin, by chain path.
    public let storageRates: [String: Int]
    public let servingRates: [String: Int]

    public init(payTo: String?, depth: UInt64, storageRates: [[String]: Int], servingRates: [[String]: Int]) {
        func named(_ rates: [[String]: Int]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: rates.map { ($0.key.joined(separator: "/"), $0.value) })
        }
        self.payTo = payTo
        self.depth = depth
        self.storageRates = named(storageRates)
        self.servingRates = named(servingRates)
    }
}

extension SponsorNode {
    /// Raise `peer`'s standing on the node by `bytes`; nothing for none.
    public func creditServing(peer: String, bytes: Int) async throws {
        guard bytes > 0 else { return }
        struct Credit: Encodable { let peer: String; let bytes: Int }
        var post = request("serving-credit")
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONEncoder().encode(Credit(peer: peer, bytes: bytes))
        do {
            _ = try await call(post)
        } catch {
            throw SponsorRefusal.servingNotCredited
        }
    }
}
