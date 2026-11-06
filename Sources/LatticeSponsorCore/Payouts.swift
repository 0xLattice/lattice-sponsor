// Payouts: work naming a `payTo` address earns it coin, which the sponsor pays
// out in transactions it signs alone (pay per share). This is the book of what
// is owed and what is being paid, with no I/O but its one file.
//
// A payout moves coin that can be paid only once, so its life follows from
// what the chain can prove, never from what a send answered:
//
// - The sponsor is the first signer of nothing but payouts, so its nonce on a
//   chain counts its payouts there. A payout is signed at the sponsor's next
//   nonce N, and nothing else is ever signed at N but a replacement of it
//   that pays the same recipients the same coins (a higher fee, say).
//   Whichever version lands, the recipients are paid exactly once.
// - Before any version is sent, it is written here with the earnings it pays
//   already taken off (`begin`). A crash or a failed send after that loses
//   nothing: the payout is still pending and is sent again.
// - It is settled once one of its versions is `depth` blocks deep in the
//   canonical chain (`observe`).
// - Its coins go back to the earnings only once no version can ever land:
//   the sponsor's nonce has passed N with none of them included, and stayed
//   so for `depth` blocks, so another transaction holds N for good. Only a
//   transaction the operator signed with the sponsor's key can do that.
//
// One payout is pending per chain at a time. What it pays, at its largest
// fee, is reserved against the sponsor's float (`reserved`).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Lattice
import LatticeNodeAPI
import UInt256

public struct PayoutBook: Sendable {
    public struct Recipient: Codable, Sendable, Equatable {
        public let address: String
        @DecimalString public var amount: UInt64

        public init(address: String, amount: UInt64) {
            self.address = address
            self.amount = amount
        }
    }

    /// One signed version of a payout: its content address and fee, and the
    /// transaction to send.
    public struct Version: Codable, Sendable {
        public let cid: String
        @DecimalString public var fee: UInt64
        public let transaction: ContentBoundTransaction

        public init(cid: String, fee: UInt64, transaction: ContentBoundTransaction) {
            self.cid = cid
            self.fee = fee
            self.transaction = transaction
        }
    }

    public struct Pending: Codable, Sendable {
        public let chain: String
        @DecimalString public var nonce: UInt64
        public let recipients: [Recipient]
        /// Oldest first; the last is the one sent.
        public var versions: [Version]
        /// The tip height at which the sponsor's nonce was first seen past
        /// `nonce` with no version included, if it is now.
        @OptionalDecimalString public var passedAt: UInt64?

        public var coins: UInt64 { recipients.reduce(0) { $0 + $1.amount } }
        /// What it can debit the sponsor: its coins and its largest fee.
        public var total: UInt64 { coins + (versions.map(\.fee).max() ?? 0) }
        public var chainPath: [String] { chain.components(separatedBy: "/") }
    }

    /// How a check of a pending payout came out.
    public enum Outcome: Equatable, Sendable {
        case pending
        /// A version is deep in the chain: the recipients are paid.
        case settled(cid: String)
        /// No version can land: its coins are owed again.
        case givenBack
    }

    private struct Stored: Codable {
        var earnings: [String: [String: String]] = [:]
        var pending: [Pending] = []
    }

    /// Each chain's earnings by address, scaled by 2^64 (`SponsorLedger.unit`).
    private var earnings: [[String]: [String: UInt256]] = [:]
    private var pending: [[String]: Pending] = [:]
    private let file: URL?
    /// Earnings changed since the file was last written.
    public private(set) var dirty = false

    /// The book kept in `file`, starting from what it holds, if it exists.
    public init(file: URL?) throws {
        self.file = file
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
        for (chain, owed) in stored.earnings {
            earnings[chain.components(separatedBy: "/")] = owed.compactMapValues(Self.parse)
        }
        for payout in stored.pending { pending[payout.chainPath] = payout }
    }

    // MARK: earning

    /// Owe `address` `value` more on `chainPath`. Written with the next `save`.
    public mutating func earn(_ value: UInt256, to address: String, on chainPath: [String]) {
        guard value > .zero else { return }
        let (sum, overflow) = (earnings[chainPath]?[address] ?? .zero).addingReportingOverflow(value)
        earnings[chainPath, default: [:]][address] = overflow ? .max : sum
        dirty = true
    }

    /// What `address` is owed on `chainPath` and not yet in a payout, scaled.
    public func earnings(of address: String, on chainPath: [String]) -> UInt256 {
        earnings[chainPath]?[address] ?? .zero
    }

    // MARK: paying

    public func pending(on chainPath: [String]) -> Pending? {
        pending[chainPath]
    }

    public var pendingChains: [[String]] { Array(pending.keys) }

    /// The chains where no payout is pending and some address is owed at
    /// least `threshold` coins.
    public func dueChains(threshold: UInt64) -> [[String]] {
        let floor = Self.coins(threshold)
        return earnings.compactMap { chain, owed in
            pending[chain] == nil && owed.values.contains { $0 >= floor } ? chain : nil
        }
    }

    /// What the pending payout on `chainPath` can still debit the sponsor.
    public func reserved(on chainPath: [String]) -> UInt64 {
        pending[chainPath]?.total ?? 0
    }

    /// The next payout's recipients on `chainPath`: each address owed at
    /// least `threshold` coins, largest first, up to `maxRecipients`, paid
    /// its whole coins while they fit in `room`. The fraction stays owed.
    public func due(on chainPath: [String], threshold: UInt64, maxRecipients: Int, room: UInt64) -> [Recipient] {
        guard pending[chainPath] == nil, maxRecipients > 0 else { return [] }
        let floor = Self.coins(threshold)
        // Each amount fits Int64 with the others and a fee.
        let most = UInt64(Int64.max) / UInt64(maxRecipients + 1)
        var left = room
        var recipients: [Recipient] = []
        for (address, value) in (earnings[chainPath] ?? [:]).filter({ $0.value >= floor })
            .sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
            guard recipients.count < maxRecipients else { break }
            let whole = value / SponsorLedger.unit
            let amount = whole > UInt256(most) ? most : UInt64(whole.words[0])
            guard amount > 0, amount <= left else { continue }
            left -= amount
            recipients.append(Recipient(address: address, amount: amount))
        }
        return recipients
    }

    /// Record a payout before it is first sent: its recipients' coins come off
    /// their earnings, and it is pending on its chain, written to the file.
    public mutating func begin(on chainPath: [String], nonce: UInt64, recipients: [Recipient], version: Version) throws {
        precondition(pending[chainPath] == nil && !recipients.isEmpty)
        var owed = earnings[chainPath] ?? [:]
        for recipient in recipients {
            let coins = Self.coins(recipient.amount)
            guard let value = owed[recipient.address], value >= coins else {
                throw SponsorRefusal.draft("a payout pays more than is owed")
            }
            owed[recipient.address] = value == coins ? nil : value - coins
        }
        var next = self
        next.earnings[chainPath] = owed.isEmpty ? nil : owed
        next.pending[chainPath] = Pending(
            chain: chainPath.joined(separator: "/"), nonce: nonce, recipients: recipients, versions: [version]
        )
        try next.write()
        self = next
    }

    /// Add `version`, a replacement of the pending payout on `chainPath` (the
    /// same nonce and recipients, another fee), as the one to send.
    public mutating func replace(on chainPath: [String], with version: Version) throws {
        guard var payout = pending[chainPath] else { return }
        payout.versions.append(version)
        var next = self
        next.pending[chainPath] = payout
        try next.write()
        self = next
    }

    /// Check the pending payout on `chainPath` against the chain: the
    /// sponsor's next nonce and the tip height, and the depth of the deepest
    /// version included in the canonical chain (nil: none is). A payout
    /// settles at `depth`, and is given back only after its nonce has been
    /// taken by another transaction for `depth` blocks.
    public mutating func observe(
        on chainPath: [String], nextNonce: UInt64, tipHeight: UInt64, included: (cid: String, depth: UInt64)?, depth: UInt64
    ) throws -> Outcome {
        guard var payout = pending[chainPath] else { return .pending }
        var next = self
        let outcome: Outcome
        if let included, included.depth >= depth {
            next.pending[chainPath] = nil
            outcome = .settled(cid: included.cid)
        } else if included == nil, nextNonce > payout.nonce {
            let since = payout.passedAt ?? tipHeight
            if tipHeight >= since + depth {
                for recipient in payout.recipients {
                    next.earn(Self.coins(recipient.amount), to: recipient.address, on: chainPath)
                }
                next.pending[chainPath] = nil
                outcome = .givenBack
            } else {
                guard payout.passedAt == nil else { return .pending }
                payout.passedAt = since
                next.pending[chainPath] = payout
                outcome = .pending
            }
        } else {
            // Included but shallow, or not yet passed: wait, and forget a pass
            // a reorg undid.
            guard payout.passedAt != nil else { return .pending }
            payout.passedAt = nil
            next.pending[chainPath] = payout
            outcome = .pending
        }
        try next.write()
        self = next
        return outcome
    }

    /// Write the book if earnings changed since it was last written.
    public mutating func save() throws {
        guard dirty else { return }
        try write()
    }

    private mutating func write() throws {
        dirty = false
        guard let file else { return }
        var stored = Stored()
        for (chain, owed) in earnings {
            stored.earnings[chain.joined(separator: "/")] = owed.mapValues { $0.toHexString() }
        }
        stored.pending = pending.values.sorted { $0.chain < $1.chain }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            try encoder.encode(stored).write(to: file, options: .atomic)
        } catch {
            dirty = true
            throw error
        }
    }

    /// `n` whole coins, scaled.
    static func coins(_ n: UInt64) -> UInt256 { UInt256(n) * SponsorLedger.unit }

    /// A 64-digit hex `toHexString()`, back.
    static func parse(_ hex: String) -> UInt256? {
        let digits = Array(hex)
        guard digits.count == 64 else { return nil }
        let parts = stride(from: 0, to: 64, by: 16).compactMap { UInt64(String(digits[$0..<$0 + 16]), radix: 16) }
        return parts.count == 4 ? UInt256(parts) : nil
    }
}

/// The body of a payout: `recipients` paid by `sponsor`, which signs alone,
/// at `nonce`, debiting itself their coins and `fee`.
public func payoutBody(
    recipients: [PayoutBook.Recipient], sponsor: String, fee: UInt64, nonce: UInt64, chainPath: [String]
) -> TransactionBody {
    let coins = recipients.reduce(UInt64(0)) { $0 + $1.amount }
    return TransactionBody(
        accountActions: recipients.map { AccountAction(owner: $0.address, delta: Int64($0.amount)) }
            + [AccountAction(owner: sponsor, delta: -Int64(coins + fee))],
        actions: [], depositActions: [], receiptActions: [], withdrawalActions: [],
        signers: [sponsor], nonce: nonce, chainPath: chainPath
    )
}

extension SponsorNode {
    /// The canonical tip's height on `chainPath`.
    public func tipHeight(on chainPath: [String]) async throws -> UInt64 {
        let tip: ExplorerLatestBlock = try await read("api/block/latest", on: chainPath)
        return tip.height
    }

    /// How many blocks are built on the canonical block that includes
    /// transaction `cid` on `chainPath` (0: it is the tip's), or nil when no
    /// canonical block includes it. Throws when the node can't say.
    public func depth(of cid: String, on chainPath: [String], tipHeight: UInt64) async throws -> UInt64? {
        let described: ExplorerTransaction
        do {
            described = try await read("api/transaction/\(cid)", on: chainPath)
        } catch SponsorRefusal.notIncluded {
            return nil
        }
        guard let height = described.blockHeight, let hash = described.blockHash, height <= tipHeight else { return nil }
        struct Block: Decodable { let hash: String }
        do {
            let block: Block = try await read("api/block/\(height)", on: chainPath)
            return block.hash == hash ? tipHeight - height : nil
        } catch SponsorRefusal.notIncluded {
            return nil
        }
    }

    /// `POST /transactions`: hand the node a transaction. Throws the node's
    /// status when it refuses; a refusal proves nothing about a payout, which
    /// is judged by the chain alone (`PayoutBook.observe`).
    public func submit(_ transaction: ContentBoundTransaction) async throws {
        var request = request("transactions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Submit: Encodable { let transaction: ContentBoundTransaction }
        request.httpBody = try JSONEncoder().encode(Submit(transaction: transaction))
        _ = try await call(request)
    }
}
