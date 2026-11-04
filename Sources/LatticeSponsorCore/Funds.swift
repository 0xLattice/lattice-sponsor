// Funds: float a payer lends the sponsor, so one operator's coin does not
// bound how many sites it sponsors. A payer deposits coin to the sponsor's
// own account, under a fund named by key prefixes. A sponsored transaction
// that names the fund and writes only keys under its prefixes is held against
// the fund's deposit instead of the operator's own float: the fund's fees
// signed and not yet expired stay within its deposit. Nothing is drawn from
// a deposit. Clients still buy every fee with work, which repays it through
// the template's rewards to the sponsor's key, so on average a deposit stays
// the payer's. Anyone may fund any prefixes. Deposits are kept in one JSON
// file; there is no withdrawal yet.

import Foundation
import Lattice
import LatticeNodeAPI
import UInt256

/// One fund on one chain. Prefixes are compared as bytes, as the chain
/// compares keys: two spellings of one character are two prefixes.
public struct FundID: Hashable, Sendable {
    public let chainPath: [String]
    let prefixes: [Data]

    /// `prefixes` normalized (`FundLedger.normalize`).
    public init(_ prefixes: [String], on chainPath: [String]) {
        self.chainPath = chainPath
        self.prefixes = prefixes.map { Data($0.utf8) }
    }
}

public struct FundLedger: Sendable {
    public static let mostPrefixes = 8
    public static let longestPrefix = 128

    let file: URL
    private var deposits: [FundID: UInt64] = [:]

    private struct Record: Codable {
        let chain: String
        let prefixes: [String]
        @DecimalString var deposit: UInt64
    }

    /// Read the deposits `file` keeps, if it exists.
    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            for record in try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)) {
                let chainPath = record.chain.components(separatedBy: "/")
                deposits[FundID(try Self.normalize(record.prefixes), on: chainPath)] = record.deposit
            }
        }
    }

    /// A fund's prefixes in the one order every party writes them: 1 to 8
    /// non-empty prefixes of at most 128 bytes, sorted by their UTF-8 bytes,
    /// each once. A newline would make the signed claim ambiguous (see
    /// `CoinPayment.message`), so none holds one.
    public static func normalize(_ prefixes: [String]) throws -> [String] {
        guard (1...mostPrefixes).contains(prefixes.count) else {
            throw SponsorRefusal.draft("a fund names 1 to \(mostPrefixes) prefixes")
        }
        for prefix in prefixes {
            guard !prefix.isEmpty, prefix.utf8.count <= longestPrefix, !prefix.utf8.contains(0x0A) else {
                throw SponsorRefusal.draft("a fund's prefix is 1 to \(longestPrefix) bytes, without a newline")
            }
        }
        var unique: [[UInt8]] = []
        for prefix in prefixes.map({ Array($0.utf8) }).sorted(by: { $0.lexicographicallyPrecedes($1) })
        where unique.last != prefix {
            unique.append(prefix)
        }
        return unique.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether a fund of `prefixes` may back `body`: it writes at least one
    /// key, and every key it writes starts with one of them.
    public static func covers(_ body: TransactionBody, prefixes: [String]) -> Bool {
        !body.actions.isEmpty && body.actions.allSatisfy { action in
            prefixes.contains { action.key.utf8.starts(with: $0.utf8) }
        }
    }

    public func deposit(of fund: FundID) -> UInt64 {
        deposits[fund] ?? 0
    }

    /// The fund that holds `total` (the fee and any `pay`) for sponsoring
    /// `draft`, or nil to hold it against the operator's own float:
    /// `fundedOnly` refuses a draft no fund backs. A fund backs a draft it
    /// covers while its unexpired holds and `total` fit in its deposit.
    public func backer(
        for draft: TransactionBody, fund: [String]?, total: UInt64,
        ledger: SponsorLedger, now: Int64, fundedOnly: Bool
    ) throws -> FundID? {
        if let fund {
            let prefixes = try Self.normalize(fund)
            let id = FundID(prefixes, on: draft.chainPath)
            if Self.covers(draft, prefixes: prefixes),
               ledger.held(by: id, now: now) + UInt256(total) <= UInt256(deposit(of: id)) {
                return id
            }
        }
        guard !fundedOnly else { throw SponsorRefusal.notFunded }
        return nil
    }

    /// Add `coins` to `fund`'s deposit, saturating, and return it.
    public mutating func credit(_ fund: FundID, coins: UInt64) throws -> UInt64 {
        let (sum, overflow) = deposit(of: fund).addingReportingOverflow(coins)
        var next = deposits
        next[fund] = overflow ? .max : sum
        let records = next.map { id, deposit in
            Record(
                chain: id.chainPath.joined(separator: "/"),
                prefixes: id.prefixes.map { String(decoding: $0, as: UTF8.self) },
                deposit: deposit
            )
        }.sorted { ($0.chain, $0.prefixes.joined(separator: "\n")) < ($1.chain, $1.prefixes.joined(separator: "\n")) }
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
        deposits = next
        return next[fund]!
    }
}
