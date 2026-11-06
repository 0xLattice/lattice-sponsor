// Work-for-fee sponsorship: a client grinds shares of the sponsor's block
// template, and the sponsor co-signs the client's transaction, paying its fee
// from its own account. Nothing here is consensus. The share is real block
// work (a share that clears the block target is a block paying the sponsor),
// so the fee is bought at its expected value. A chain's block at target T
// paying R prices its smallest unit at workForTarget(T) / R work, so a share
// at target S is worth R * workForTarget(S) / workForTarget(T) units there.
//
// A share is a ticket on the blocks of the one template it was ground on, so
// it is valued when it is credited, at that template's price, on the one
// chain its client named: the client earns on that chain alone. The template
// is merged and pays the sponsor on every chain it carries; the share's worth
// on the others, and the template's fees, are the sponsor's.
//
// Work can also earn coin outright: an assignment with a `payTo` address is
// valued here like any share, and its value is owed to that address
// (`PayoutBook`), never to a client's fee credit.

import Foundation
import Lattice
import LatticeMinerCore
import LatticeNodeAPI
import UInt256

/// What one chain's block in a template pays a share: the target a hash
/// must clear to make it (the block's committed target, or the template's
/// search target where that is harder, since the node takes no hash above
/// it), the block's height, and its reward, R(h).
public struct ChainPrice: Sendable, Equatable {
    public let target: UInt256
    public let height: UInt64
    public let reward: UInt64

    public init(target: UInt256, height: UInt64, reward: UInt64) {
        self.target = target
        self.height = height
        self.reward = reward
    }
}

/// One node template, as the sponsor hands it out.
public struct SponsorTemplate: Sendable, Equatable {
    public let workID: String
    /// Consensus PoW preimage prefix (hex): what a client hashes with a nonce.
    public let prefixHex: String
    /// Each chain whose block the template carries and pays the sponsor, by
    /// absolute path.
    public let prices: [[String]: ChainPrice]
    /// The easiest target any block in this work clears (merged children
    /// included). A share at or under it goes to the node as a block.
    public let submitTarget: UInt256
    /// The root block's parent: the tip it builds on.
    public let parent: String

    public init(
        workID: String,
        prefixHex: String,
        prices: [[String]: ChainPrice],
        submitTarget: UInt256,
        parent: String
    ) {
        self.workID = workID
        self.prefixHex = prefixHex
        self.prices = prices
        self.submitTarget = submitTarget
        self.parent = parent
    }
}

/// A disjoint nonce range of one template, held by one client. Shares are
/// credited only inside it, so a client cannot claim another's work.
public struct ShareAssignment: Sendable, Equatable {
    public let id: String
    public let client: String
    /// The chain the client's shares are credited on, and the height of
    /// its block in this template.
    public let chainPath: [String]
    public let height: UInt64
    public let workID: String
    public let prefixHex: String
    public let shareTarget: UInt256
    /// What one share is worth on `chainPath` at this template's price, in
    /// units scaled by 2^64 (`SponsorLedger.unit`).
    public let shareValue: UInt256
    /// The block's whole reward, scaled the same way: the most credit its
    /// height can back.
    public let blockValue: UInt256
    public let startNonce: UInt64
    public let count: UInt64
    /// The upload's root, when its shares pay for storage instead.
    public let store: String?
    /// The peer whose standing its shares raise, when they pay for serving.
    public let peer: String?
    /// The address its shares earn coin for, paid out by the sponsor, when
    /// they are neither fee credit nor storage nor serving.
    public var payTo: String? = nil
}

public enum SponsorRefusal: Error, Sendable, Equatable {
    case unknownAssignment
    /// The chain has moved past the block the assignment's template
    /// carries: the work can no longer win it.
    case expired
    case outsideRange
    case duplicateShare
    case missesShareTarget
    /// No work can be handed out right now (too many live assignments, or
    /// a template held still carries the chain higher after a reorg);
    /// retry shortly.
    case busy
    /// Credit backed by the chain's block at this height has reached its
    /// reward; retry once the chain moves on.
    case soldOut
    /// The client's credit on the fee's chain does not cover the fee yet.
    case insufficientCredit
    /// The sponsor's balance, less the fees it already signed, does not
    /// cover this fee.
    case insufficientFloat
    /// No price for a share on the chain: the newest template does not
    /// carry a block paying the sponsor there, its emission has ended, or
    /// there is no template yet.
    case unpriceable
    /// The draft is not one the sponsor signs; the reason names why.
    case draft(String)
    /// The sponsor sets no storage rate on the chain.
    case noStorageRate
    /// The sponsor sets no serving rate on the chain.
    case noServingRate
    /// The node did not take the serving credit; the share or payment is
    /// spent and its credit lost.
    case servingNotCredited
    /// The upload does not fit in what is left of the storage budget.
    case overBudget
    /// No upload is held under that root: it expired, or was never made.
    case unknownUpload
    /// The transaction is not in the node's canonical chain.
    case notIncluded
    /// Too few blocks are built on the transaction's block yet; retry later.
    case notDeepEnough
    /// The claimed signer did not sign the transaction.
    case notSigner
    /// The signature is not the signer's over the claim.
    case invalidSignature
    /// The transaction pays the sponsor's account nothing, net.
    case noPayment
    /// The transaction is already credited, or being checked.
    case alreadyCredited
    /// The sponsor takes no funds.
    case noFunds
    /// With --funded-only, no fund named pays for the transaction: it writes
    /// a key outside the fund's prefixes, or the fund is short of the fee.
    case notFunded
    /// With --funded-only, the fund named already holds a transaction of
    /// this signer at another nonce, which has neither landed nor been passed
    /// by the signer's nonce: submit that one, or redraft at its nonce.
    case inFlight
    /// The sponsor pays out no earnings (it runs without --payout-at).
    case noPayouts
}

public struct SponsorLedger: Sendable {
    /// Credit is kept in units of a chain's currency scaled by 2^64, since a
    /// share is usually a small fraction of one unit.
    public static let unit = UInt256(1) << 64

    public let shareTarget: UInt256
    public let rangeSize: UInt64
    public let maxAssignments: Int
    /// The most templates on one tip held for shares, oldest dropped first:
    /// well under the node's own bound, so none is work the node dropped.
    public let maxTemplates: Int
    /// How long a client's credit outlives its last share.
    public let creditLifetime: Int64

    private var templates: [String: SponsorTemplate] = [:]
    /// `templates`' work IDs, oldest first.
    private var order: [String] = []
    private var nextStart: [String: UInt64] = [:]
    private var assignments: [String: ShareAssignment] = [:]
    private var shares: Set<ShareKey> = []
    /// Nonces already handed to the node as blocks, so a replay never is.
    private var submitted: Set<ShareKey> = []
    private var credits: [CreditKey: (value: UInt256, lastShare: Int64)] = [:]
    private var sold: [BlockKey: UInt256] = [:]
    /// The part of `sold` that payout work took, at most half a height's
    /// block (`payoutValue`).
    private var soldToPayouts: [BlockKey: UInt256] = [:]
    /// Fees signed and held against the balance, each with the fund whose
    /// deposit backs it, if one does, until its chain moves past it.
    private var holds: [Hold] = []
    /// Where `holds` are kept, if anywhere (`keepHolds(in:)`).
    private var holdsFile: URL?
    private var lastID: UInt64 = 0

    private struct ShareKey: Hashable {
        let workID: String
        let nonce: UInt64
    }

    private struct CreditKey: Hashable {
        let client: String
        let chainPath: [String]
    }

    private struct BlockKey: Hashable {
        let chainPath: [String]
        let height: UInt64
    }

    /// One signed fee and pay, held until its signer's next nonce on its
    /// chain passes `nonce`: the transaction landed, or another took its
    /// nonce and it never can. Only the first signer's nonce is consensus,
    /// and the client always signs first, so it is the client's nonce.
    private struct Hold: Equatable {
        let chainPath: [String]
        let signer: String
        let nonce: UInt64
        let fee: UInt64
        let fund: FundID?
    }

    /// A hold as `holdsFile` keeps it.
    private struct HoldRecord: Codable {
        let chain: String
        let signer: String
        @DecimalString var nonce: UInt64
        @DecimalString var fee: UInt64
        let fund: [String]?
    }

    /// An account whose nonce on a chain would release holds.
    public struct Holder: Hashable, Sendable {
        public let chainPath: [String]
        public let signer: String
    }

    public init(
        shareTarget: UInt256,
        rangeSize: UInt64 = 1 << 32,
        maxAssignments: Int = 100_000,
        maxTemplates: Int = 64,
        creditLifetime: Int64 = 3_600_000
    ) {
        precondition(shareTarget > .zero && rangeSize > 0 && maxAssignments > 0 && maxTemplates > 0)
        self.shareTarget = shareTarget
        self.rangeSize = rangeSize
        self.maxAssignments = maxAssignments
        self.maxTemplates = maxTemplates
        self.creditLifetime = creditLifetime
    }

    /// The newest template, the one new work is handed out from; nil while
    /// the sponsor cannot tell what the node holds.
    public private(set) var latest: SponsorTemplate?

    /// The node's work is unknown (a fetch failed, or its events ended):
    /// no new work or price until a template is installed. Work handed out
    /// keeps its credit, and its blocks still go to the node, which judges.
    public mutating func blind() {
        latest = nil
    }

    /// The node no longer holds `workID` (it refused a block on it as
    /// unknown): retire it and its work. Not the newest: a refusal on it
    /// means the tip moved, and the node's event brings its replacement.
    public mutating func retire(workID: String) {
        guard workID != latest?.workID else { return }
        retire([workID])
    }

    /// Take `template` as the newest work. On a new tip (another parent),
    /// or `fresh` (the first since connecting: the node may have restarted
    /// and lost what it handed out), work on every earlier template is gone;
    /// otherwise only the pool or a hosted chain moved, and earlier work
    /// stays valid. Time never retires work: proof-of-work arrivals are
    /// memoryless. This runs as templates arrive, so requests never pay for
    /// the sweep.
    public mutating func install(_ template: SponsorTemplate, fresh: Bool = false, now: Int64) {
        if fresh || order.last.flatMap({ templates[$0] })?.parent != template.parent {
            retire(order.filter { $0 != template.workID })
        }
        if templates[template.workID] == nil {
            templates[template.workID] = template
            order.append(template.workID)
        }
        if order.count > maxTemplates { retire(Array(order.prefix(order.count - maxTemplates))) }
        latest = template
        prune(now: now)
    }

    /// A fresh nonce range of the newest template for `client`, its shares
    /// credited on `chainPath` at this template's price: as fee credit, or
    /// with a `store`, to that upload, or with a `peer`, to its standing.
    public mutating func assign(
        client: String, on chainPath: [String], store: String? = nil, peer: String? = nil, payTo: String? = nil
    ) throws -> ShareAssignment {
        precondition(payTo == nil || (store == nil && peer == nil))
        guard let template = latest,
              let price = template.prices[chainPath],
              let value = Self.shareValue(shareTarget: shareTarget, at: price), value > .zero else {
            throw SponsorRefusal.unpriceable
        }
        // After a reorg to a lower height, a template held still shows the
        // chain higher; work here could not earn until a new tip retires it.
        guard (liveHeight(of: chainPath) ?? price.height) <= price.height else { throw SponsorRefusal.busy }
        let blockValue = UInt256(price.reward) * Self.unit
        let block = BlockKey(chainPath: chainPath, height: price.height)
        guard sold[block] ?? .zero < blockValue else { throw SponsorRefusal.soldOut }
        if payTo != nil, soldToPayouts[block] ?? .zero >= Self.payoutValue(of: blockValue) {
            throw SponsorRefusal.soldOut
        }
        guard assignments.count < maxAssignments else { throw SponsorRefusal.busy }
        let start = nextStart[template.workID] ?? 0
        let (end, overflow) = start.addingReportingOverflow(rangeSize)
        guard !overflow else { throw SponsorRefusal.busy }
        nextStart[template.workID] = end
        lastID &+= 1
        let assignment = ShareAssignment(
            id: "\(template.workID).\(lastID)",
            client: client,
            chainPath: chainPath,
            height: price.height,
            workID: template.workID,
            prefixHex: template.prefixHex,
            shareTarget: shareTarget,
            shareValue: value,
            blockValue: blockValue,
            startNonce: start,
            count: rangeSize,
            store: store,
            peer: peer,
            payTo: payTo
        )
        assignments[assignment.id] = assignment
        return assignment
    }

    /// Credit one share: `nonce` inside the assignment's range whose hash
    /// clears the share target. `hash` is the template's PoW hash at `nonce`
    /// (`ProofOfWork.hash`), computed by the caller from the prefix. Returns
    /// the share's value; an assignment with a store or a peer is not fee
    /// credit, so the caller owes that value to the upload or peer instead.
    ///
    /// Only one block per height can be the chain's, so the credit a height
    /// backs, across every template and client, stops at its block's
    /// reward: past that, more work at the height earns the sponsor nothing.
    public mutating func credit(
        assignment id: String,
        nonce: UInt64,
        hash: UInt256,
        now: Int64
    ) throws -> UInt256 {
        guard let assignment = assignments[id], templates[assignment.workID] != nil else {
            throw SponsorRefusal.unknownAssignment
        }
        guard (liveHeight(of: assignment.chainPath) ?? assignment.height) <= assignment.height else {
            throw SponsorRefusal.expired
        }
        guard nonce >= assignment.startNonce, nonce - assignment.startNonce < assignment.count else {
            throw SponsorRefusal.outsideRange
        }
        guard hash <= assignment.shareTarget else { throw SponsorRefusal.missesShareTarget }
        guard shares.insert(ShareKey(workID: assignment.workID, nonce: nonce)).inserted else {
            throw SponsorRefusal.duplicateShare
        }
        let block = BlockKey(chainPath: assignment.chainPath, height: assignment.height)
        let backed = sold[block] ?? .zero
        guard backed < assignment.blockValue else { throw SponsorRefusal.soldOut }
        var value = min(assignment.shareValue, assignment.blockValue - backed)
        if assignment.payTo != nil {
            // Payout work waits for no one; fee work has a person waiting on
            // it. So payout work backs at most half a height's block, and the
            // rest stays for fees.
            let taken = soldToPayouts[block] ?? .zero, room = Self.payoutValue(of: assignment.blockValue)
            guard taken < room else { throw SponsorRefusal.soldOut }
            value = min(value, room - taken)
            soldToPayouts[block] = taken + value
        }
        sold[block] = backed + value
        // Storage, serving and payout work: the caller owes the value elsewhere.
        guard assignment.store == nil, assignment.peer == nil, assignment.payTo == nil else { return value }
        let key = CreditKey(client: assignment.client, chainPath: assignment.chainPath)
        let (sum, overflow) = (credits[key]?.value ?? .zero).addingReportingOverflow(value)
        credits[key] = (overflow ? UInt256.max : sum, now)
        return value
    }

    /// The template to submit `nonce` to as a block, when its `hash` clears
    /// the template's submit target, once per nonce. Decided apart from
    /// credit: a share the client is not credited for (its chain sold out or
    /// moved on) can still be the sponsor's block on another chain, and the
    /// node judges it.
    public mutating func block(assignment id: String, nonce: UInt64, hash: UInt256) -> String? {
        guard let assignment = assignments[id], let template = templates[assignment.workID],
              hash <= template.submitTarget,
              submitted.insert(ShareKey(workID: template.workID, nonce: nonce)).inserted else { return nil }
        return template.workID
    }

    /// The highest height of `chainPath`'s block in any template held. An
    /// assignment's own template is held while it is, so one template that
    /// leaves the chain out cannot hide that it moved on.
    private func liveHeight(of chainPath: [String]) -> UInt64? {
        templates.values.compactMap { $0.prices[chainPath]?.height }.max()
    }

    public func assignment(_ id: String) -> ShareAssignment? {
        assignments[id]
    }

    /// `client`'s credit on `chainPath`, in units scaled by 2^64.
    public func credit(of client: String, on chainPath: [String]) -> UInt256 {
        credits[CreditKey(client: client, chainPath: chainPath)]?.value ?? .zero
    }

    /// The fees and pays held against the sponsor's balance on `chainPath`.
    public func held(on chainPath: [String]) -> UInt64 {
        holds.reduce(UInt64(0)) { $1.chainPath == chainPath ? $0 &+ $1.fee : $0 }
    }

    /// The most of a height's block value payout work may back: half.
    public static func payoutValue(of blockValue: UInt256) -> UInt256 {
        blockValue >> 1
    }

    /// What one share at `shareTarget` is worth on a chain at `price`, in
    /// units scaled by 2^64: `R * workForTarget(S) / workForTarget(T)`,
    /// rounded down. Nil when that overflows.
    public static func shareValue(shareTarget: UInt256, at price: ChainPrice) -> UInt256? {
        let (scaled, overflow) = UInt256(price.reward).multipliedReportingOverflow(by: unit)
        guard !overflow else { return nil }
        let (product, overflowed) = scaled.multipliedReportingOverflow(by: workForTarget(shareTarget))
        guard !overflowed else { return nil }
        return product / workForTarget(price.target)
    }

    /// How many shares of the newest template buy `fee` on `chainPath`.
    public func sharesFor(fee: UInt64, on chainPath: [String]) -> UInt256? {
        guard let price = latest?.prices[chainPath],
              let value = Self.shareValue(shareTarget: shareTarget, at: price), value > .zero else {
            return nil
        }
        let (quotient, remainder) = (UInt256(fee) * Self.unit).quotientAndRemainder(dividingBy: value)
        return remainder == .zero ? quotient : quotient + UInt256(1)
    }

    /// Spend `fee` of `client`'s credit on `chainPath` and hold the fee
    /// against the sponsor's `balance` there until `signer`'s nonce passes
    /// `nonce` (`release(nextNonces:)`): a signed fee not yet mined does not
    /// show in the balance. The caller signs only after this returns. `fee`
    /// is everything the body debits the sponsor: the fee and any payment it
    /// makes for the client. With a `fund`, the hold also counts against that
    /// fund's deposit (see `held(by:)`). A hold of `signer` at `nonce` under
    /// the same fund (or none) is replaced, keeping the larger fee: only one
    /// of the two can land.
    public mutating func commit(
        client: String, fee: UInt64, on chainPath: [String], signer: String, nonce: UInt64, balance: UInt64,
        fund: FundID? = nil
    ) throws {
        let key = CreditKey(client: client, chainPath: chainPath)
        let cost = UInt256(fee) * Self.unit
        guard let credit = credits[key], credit.value >= cost else { throw SponsorRefusal.insufficientCredit }
        var next = holds
        var held = fee
        if let replaced = next.firstIndex(where: {
            $0.chainPath == chainPath && $0.signer == signer && $0.nonce == nonce && $0.fund == fund
        }) {
            held = max(fee, next.remove(at: replaced).fee)
        }
        let hold = Hold(chainPath: chainPath, signer: signer, nonce: nonce, fee: held, fund: fund)
        var committed = UInt256(held)
        for other in next where other.chainPath == chainPath {
            committed = committed + UInt256(other.fee)
        }
        guard committed <= UInt256(balance) else { throw SponsorRefusal.insufficientFloat }
        next.append(hold)
        try save(next)
        credits[key] = (credit.value - cost, credit.lastShare)
        holds = next
    }

    /// What `fund` backs now: its holds.
    public func held(by fund: FundID) -> UInt256 {
        holds.reduce(UInt256.zero) { sum, hold in hold.fund == fund ? sum + UInt256(hold.fee) : sum }
    }

    /// `signer`'s hold under `fund`, if it has one.
    public func hold(of signer: String, under fund: FundID) -> (nonce: UInt64, fee: UInt64)? {
        holds.first { $0.signer == signer && $0.fund == fund }.map { ($0.nonce, $0.fee) }
    }

    /// The accounts whose nonces release the holds.
    public var holders: Set<Holder> {
        Set(holds.map { Holder(chainPath: $0.chainPath, signer: $0.signer) })
    }

    /// Each holder's next nonce, as its chain now reads: release every hold
    /// of theirs below it. Its transaction landed, or another took its nonce
    /// and it never can.
    public mutating func release(nextNonces: [Holder: UInt64]) throws {
        let next = holds.filter { hold in
            nextNonces[Holder(chainPath: hold.chainPath, signer: hold.signer)].map { hold.nonce >= $0 } ?? true
        }
        guard next != holds else { return }
        try save(next)
        holds = next
    }

    /// Keep the holds in `file` from now on, starting from those it keeps,
    /// if it exists: a hold signed before a restart can still land.
    public mutating func keepHolds(in file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            holds = try JSONDecoder().decode([HoldRecord].self, from: Data(contentsOf: file)).map { record in
                let chainPath = record.chain.components(separatedBy: "/")
                return Hold(
                    chainPath: chainPath, signer: record.signer, nonce: record.nonce, fee: record.fee,
                    fund: try record.fund.map { FundID(try FundLedger.normalize($0), on: chainPath) }
                )
            }
        }
        holdsFile = file
    }

    private func save(_ holds: [Hold]) throws {
        guard let holdsFile else { return }
        let records = holds.map { hold in
            HoldRecord(
                chain: hold.chainPath.joined(separator: "/"), signer: hold.signer, nonce: hold.nonce, fee: hold.fee,
                fund: hold.fund?.prefixes.map { String(decoding: $0, as: UTF8.self) }
            )
        }
        try JSONEncoder().encode(records).write(to: holdsFile, options: .atomic)
    }

    /// Drop `workIDs`' templates and the work handed out on them.
    private mutating func retire(_ workIDs: [String]) {
        guard !workIDs.isEmpty else { return }
        let gone = Set(workIDs)
        for workID in gone {
            templates.removeValue(forKey: workID)
            nextStart.removeValue(forKey: workID)
        }
        order.removeAll { gone.contains($0) }
        assignments = assignments.filter { !gone.contains($0.value.workID) }
        shares = shares.filter { !gone.contains($0.workID) }
        submitted = submitted.filter { !gone.contains($0.workID) }
    }

    private mutating func prune(now: Int64) {
        // A height's backing is dropped only once a template held carries the
        // chain higher: a chain missing from every template held keeps it, so
        // the same height cannot back its reward twice.
        sold = sold.filter { key, _ in liveHeight(of: key.chainPath).map { key.height >= $0 } ?? true }
        soldToPayouts = soldToPayouts.filter { sold[$0.key] != nil }
        credits = credits.filter { now - $0.value.lastShare < creditLifetime && $0.value.value > .zero }
    }
}

/// The body the sponsor signs for `draft`: the draft as written plus one
/// debit of `fee` from `sponsor`, with the sponsor appended as a co-signer.
/// With a `pay`, the sponsor also credits the client `pay` and debits itself
/// that much more, so a client with no coins can pay within the draft: a
/// purchase's debit of the client nets against the credit.
///
/// A co-signature authorizes everything the body does, so the draft may not
/// name the sponsor as an account, a demander or a withdrawer, or inside an
/// action's key or values, and must balance without the sponsor, so the
/// sponsor's debit can only ever be the fee and the client's `pay`. A chain's policies may still
/// read the signer list, which no check here can bound: the sponsor's key
/// must hold its fee float and nothing else. The client stays first signer:
/// only the first signer's nonce is consensus, so the sponsor's own nonce is
/// never consumed and it can co-sign any number of drafts at once.
public func sponsoredBody(
    draft: TransactionBody,
    sponsor: String,
    fee: UInt64,
    pay: UInt64 = 0,
    chainPath: [String]
) throws -> TransactionBody {
    guard fee > 0, fee <= UInt64(Int64.max) else { throw SponsorRefusal.draft("fee out of range") }
    let (total, overflow) = fee.addingReportingOverflow(pay)
    guard !overflow, total <= UInt64(Int64.max) else { throw SponsorRefusal.draft("pay out of range") }
    guard draft.chainPath == chainPath else { throw SponsorRefusal.draft("wrong chain") }
    guard draft.signers.count == 1, let client = draft.signers.first, client != sponsor else {
        throw SponsorRefusal.draft("the draft must have exactly one signer, not the sponsor")
    }
    let named = draft.accountActions.map(\.owner)
        + draft.depositActions.map(\.demander)
        + draft.receiptActions.flatMap { [$0.withdrawer, $0.demander] }
        + draft.withdrawalActions.flatMap { [$0.withdrawer, $0.demander] }
    let mentioned = draft.actions.contains {
        [$0.key, $0.oldValue, $0.newValue].contains { $0?.contains(sponsor) == true }
    }
    guard !named.contains(sponsor), !mentioned else {
        throw SponsorRefusal.draft("the draft names the sponsor")
    }
    guard draft.minerSurplus() != nil else {
        throw SponsorRefusal.draft("the draft creates value")
    }
    let paid = pay > 0 ? [AccountAction(owner: client, delta: Int64(pay))] : []
    return TransactionBody(
        accountActions: draft.accountActions + paid + [AccountAction(owner: sponsor, delta: -Int64(total))],
        actions: draft.actions,
        depositActions: draft.depositActions,
        receiptActions: draft.receiptActions,
        withdrawalActions: draft.withdrawalActions,
        signers: [client, sponsor],
        nonce: draft.nonce,
        chainPath: draft.chainPath
    )
}
