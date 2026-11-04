// Funds: coin a payer prepays so the sponsor's service on some transactions
// is paid for. A fund is named by its key prefixes, and only a transaction
// whose every action key starts with one of them draws from it: a payer pays
// for its own keys' transactions and no one else's. Clients still buy the fee
// with work; a fund pays the operator --fund-price per transaction on top, as
// its income for the service. Anyone may fund any prefixes. The balances are
// kept in one JSON file.

import Foundation
import Lattice
import LatticeNodeAPI

public struct FundLedger: Sendable {
    public static let mostPrefixes = 8
    public static let longestPrefix = 128

    /// Coins drawn per funded transaction, on each chain that prices funds.
    public let prices: [[String]: UInt64]
    let file: URL
    private var balances: [Key: UInt64] = [:]

    /// Prefixes are compared as bytes, as the chain compares keys: two
    /// spellings of one character are two prefixes.
    private struct Key: Hashable {
        let chainPath: [String]
        let prefixes: [Data]

        init(_ prefixes: [String], on chainPath: [String]) {
            self.chainPath = chainPath
            self.prefixes = prefixes.map { Data($0.utf8) }
        }
    }

    private struct Record: Codable {
        let chain: String
        let prefixes: [String]
        @DecimalString var balance: UInt64
    }

    /// Read the balances `file` keeps, if it exists.
    public init(prices: [[String]: UInt64], file: URL) throws {
        self.prices = prices
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            for record in try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)) {
                let chainPath = record.chain.components(separatedBy: "/")
                balances[Key(try Self.normalize(record.prefixes), on: chainPath)] = record.balance
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

    /// Whether a fund of `prefixes` pays for `body`: it writes at least one
    /// key, and every key it writes starts with one of them.
    public static func covers(_ body: TransactionBody, prefixes: [String]) -> Bool {
        !body.actions.isEmpty && body.actions.allSatisfy { action in
            prefixes.contains { action.key.utf8.starts(with: $0.utf8) }
        }
    }

    public func price(on chainPath: [String]) throws -> UInt64 {
        guard let price = prices[chainPath] else { throw SponsorRefusal.noFundPrice }
        return price
    }

    /// The coins left in the fund of normalized `prefixes` on `chainPath`.
    public func balance(of prefixes: [String], on chainPath: [String]) -> UInt64 {
        balances[Key(prefixes, on: chainPath)] ?? 0
    }

    /// The fund that pays for sponsoring `draft`, normalized, or nil to
    /// sponsor it as before, unpaid. A chain without a price ignores `fund`;
    /// on one with a price, `fundedOnly` refuses a draft no fund pays for.
    public func payer(for draft: TransactionBody, fund: [String]?, fundedOnly: Bool) throws -> [String]? {
        guard let price = prices[draft.chainPath] else { return nil }
        if let fund {
            let prefixes = try Self.normalize(fund)
            if Self.covers(draft, prefixes: prefixes), balance(of: prefixes, on: draft.chainPath) >= price {
                return prefixes
            }
        }
        guard !fundedOnly else { throw SponsorRefusal.notFunded }
        return nil
    }

    /// Draw the chain's price from the fund of normalized `prefixes`.
    public mutating func draw(_ prefixes: [String], on chainPath: [String]) throws {
        let key = Key(prefixes, on: chainPath)
        let price = try price(on: chainPath)
        guard let balance = balances[key], balance >= price else { throw SponsorRefusal.notFunded }
        var next = balances
        next[key] = balance - price
        try save(next)
        balances = next
    }

    /// Add `coins` to the fund of normalized `prefixes`, saturating, and
    /// return its balance.
    public mutating func credit(_ prefixes: [String], coins: UInt64, on chainPath: [String]) throws -> UInt64 {
        _ = try price(on: chainPath)
        let key = Key(prefixes, on: chainPath)
        let (sum, overflow) = (balances[key] ?? 0).addingReportingOverflow(coins)
        var next = balances
        next[key] = overflow ? .max : sum
        try save(next)
        balances = next
        return next[key]!
    }

    private func save(_ balances: [Key: UInt64]) throws {
        let records = balances.filter { $0.value > 0 }.map { key, balance in
            Record(
                chain: key.chainPath.joined(separator: "/"),
                prefixes: key.prefixes.map { String(decoding: $0, as: UTF8.self) },
                balance: balance
            )
        }.sorted { ($0.chain, $0.prefixes.joined(separator: "\n")) < ($1.chain, $1.prefixes.joined(separator: "\n")) }
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }
}
