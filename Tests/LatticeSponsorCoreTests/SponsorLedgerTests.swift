import Foundation
import XCTest
import Lattice
import UInt256
import cashew
import LatticeMinerCore
@testable import LatticeSponsorCore

/// `2^k - 1`: its work, `floor(2^256 / (target + 1))`, is exactly 2^(256-k).
private func target(_ k: Int) -> UInt256 { (UInt256(1) << k) - UInt256(1) }

private let sponsor = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)

private let nexus = ["Nexus"]
private let market = ["Nexus", "Market"]

/// Nexus's block at 2^200 - 1 paying 1,000, and Market's, 2^4 easier,
/// paying `marketReward`.
private func template(
    workID: String = "w1",
    marketReward: UInt64? = 10,
    marketHeight: UInt64 = 7
) -> SponsorTemplate {
    var prices = [nexus: ChainPrice(target: target(200), height: 3, reward: 1_000)]
    if let marketReward {
        prices[market] = ChainPrice(target: target(204), height: marketHeight, reward: marketReward)
    }
    return SponsorTemplate(
        workID: workID,
        prefixHex: "00",
        prices: prices,
        submitTarget: target(204)
    )
}

/// `units` whole units of a chain's currency, as credit is kept.
private func units(_ units: UInt64) -> UInt256 { UInt256(units) * SponsorLedger.unit }

private func draft(
    signer: String,
    accountActions: [AccountAction] = [],
    actions: [Action] = [],
    chainPath: [String] = ["Nexus"]
) -> TransactionBody {
    TransactionBody(
        accountActions: accountActions,
        actions: actions,
        depositActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [signer],
        nonce: 0,
        chainPath: chainPath
    )
}

final class SponsorLedgerTests: XCTestCase {
    /// A share target 2^8 easier than Nexus's block (a share is 1/256 of
    /// its 1,000: 1000/256 units) and 2^4 easier than Market's (1/16 of
    /// its 10: 10/16 units).
    private func ledger() -> SponsorLedger {
        var ledger = SponsorLedger(shareTarget: target(208), rangeSize: 100)
        ledger.install(template(), clean: false, now: 0)
        return ledger
    }

    private let nexusShare = UInt256(1_000) << 56
    private let marketShare = UInt256(10) << 60

    func testSharesCreditOnlyInsideTheirOwnRangeOnce() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        let b = try ledger.assign(client: "b", on: nexus)
        XCTAssertEqual(a.startNonce, 0)
        XCTAssertEqual(b.startNonce, 100, "ranges are disjoint")

        let easy = UInt256(1)
        let credited = try ledger.credit(assignment: a.id, nonce: 5, hash: easy, now: 1)
        XCTAssertEqual(credited, nexusShare)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 5, hash: easy, now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .duplicateShare)
        }
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 105, hash: easy, now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .outsideRange, "b's nonce is not a's work")
        }
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 6, hash: ledger.shareTarget + UInt256(1), now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .missesShareTarget)
        }
        XCTAssertEqual(ledger.credit(of: "b", on: nexus), .zero)
    }

    func testAShareClearingTheSubmitTargetIsABlock() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 1, hash: target(205)))
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1", "a Market block is a block")
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "a replay is never resubmitted")
    }

    /// A share refused credit is still the sponsor's block when it clears the
    /// submit target.
    func testAShareRefusedCreditIsStillABlock() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market)
        ledger.install(template(workID: "w2", marketHeight: 8), clean: false, now: 1)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 0, hash: target(203), now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .expired)
        }
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 0, hash: target(203)), "w1")
    }

    func testAShareIsWorthItsChanceOfTheChainsBlockTimesItsReward() {
        let price = ChainPrice(target: target(200), height: 3, reward: 1_000)
        XCTAssertEqual(SponsorLedger.shareValue(shareTarget: target(200), at: price), units(1_000), "a block's work is its reward")
        XCTAssertEqual(SponsorLedger.shareValue(shareTarget: target(208), at: price), nexusShare)
        XCTAssertEqual(SponsorLedger.shareValue(shareTarget: target(208), at: ChainPrice(target: target(200), height: 3, reward: 0)), .zero)
        XCTAssertEqual(ledger().sharesFor(fee: 1_000, on: nexus), UInt256(256))
        XCTAssertEqual(ledger().sharesFor(fee: 4, on: nexus), UInt256(2), "4 of 1000/256 a share, rounded up")
        XCTAssertEqual(ledger().sharesFor(fee: 10, on: market), UInt256(16))
        XCTAssertNil(ledger().sharesFor(fee: 1, on: ["Nexus", "Absent"]), "no block in the template, no price")
    }

    /// A share is a ticket on its own template's blocks: it is credited on
    /// the chain its client named, at that template's price, and only there.
    func testCreditIsEarnedOnTheNamedChainAtTheSharesOwnTemplatesPrice() throws {
        var ledger = ledger()
        let early = try ledger.assign(client: "a", on: market)
        for nonce in 0..<8 {
            _ = try ledger.credit(assignment: early.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market), units(5))
        XCTAssertEqual(ledger.credit(of: "a", on: nexus), .zero, "the client earns on one chain")

        // Market's reward doubles: new work is worth twice as much there,
        // and work already done keeps the price it was done at.
        ledger.install(template(workID: "w2", marketReward: 20), clean: false, now: 2)
        let late = try ledger.assign(client: "a", on: market)
        _ = try ledger.credit(assignment: early.id, nonce: 8, hash: UInt256(1), now: 3)
        for nonce in 0..<8 {
            _ = try ledger.credit(assignment: late.id, nonce: UInt64(nonce), hash: UInt256(1), now: 3)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market), units(15) + marketShare)

        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: nexus, balance: 100, holdUntil: 600_000, now: 4)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit, "market credit pays no Nexus fee")
        }
        try ledger.commit(client: "a", fee: 15, on: market, balance: 100, holdUntil: 600_000, now: 4)
        XCTAssertEqual(ledger.credit(of: "a", on: market), marketShare)

        ledger.install(template(workID: "w3", marketReward: nil), clean: false, now: 5)
        XCTAssertThrowsError(try ledger.assign(client: "a", on: market)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unpriceable, "work on a template without Market's block buys nothing there")
        }
    }

    func testCommitSpendsCreditAndHoldsTheFeeAgainstTheFloat() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        for nonce in 0..<2 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 8, on: nexus, balance: 100, holdUntil: 600_000, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit, "two shares are 7.8 units")
        }
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 4, on: nexus, balance: 3, holdUntil: 600_000, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat)
        }
        try ledger.commit(client: "a", fee: 4, on: nexus, balance: 7, holdUntil: 600_000, now: 2)
        XCTAssertEqual(ledger.credit(of: "a", on: nexus), nexusShare * UInt256(2) - units(4))

        let b = try ledger.assign(client: "b", on: nexus)
        for nonce in 100..<102 {
            _ = try ledger.credit(assignment: b.id, nonce: UInt64(nonce), hash: UInt256(1), now: 3)
        }
        XCTAssertThrowsError(try ledger.commit(client: "b", fee: 4, on: nexus, balance: 7, holdUntil: 600_000, now: 3)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat, "a's fee is still held")
        }
        try ledger.commit(client: "b", fee: 4, on: nexus, balance: 8, holdUntil: 600_000, now: 3)
    }

    /// A fund's deposit backs holds up to its size while they last, and is
    /// never drawn: room comes back as holds expire.
    func testAFundBacksHoldsUpToItsDepositUntilTheyExpire() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("funds-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var funds = try FundLedger(file: file)
        let fund = FundID(["comment/"], on: nexus)
        _ = try funds.credit(fund, coins: 5)

        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        for nonce in 0..<2 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        let comment = draft(signer: "c", actions: [Action(key: "comment/1", oldValue: nil, newValue: "hi")])
        func backer(_ total: UInt64, now: Int64 = 2, fundedOnly: Bool = false) throws -> FundID? {
            try funds.backer(for: comment, fund: ["comment/"], total: total, ledger: ledger, now: now, fundedOnly: fundedOnly)
        }

        let backed = try XCTUnwrap(try backer(3))
        try ledger.commit(client: "a", fee: 3, on: nexus, balance: 100, holdUntil: 1_000, now: 2, fund: backed)
        XCTAssertEqual(ledger.held(by: fund, now: 2), UInt256(3))
        XCTAssertNil(try backer(3), "3 held and 3 more is over the 5 deposited")
        XCTAssertThrowsError(try backer(3, fundedOnly: true)) { XCTAssertEqual($0 as? SponsorRefusal, .notFunded) }
        XCTAssertEqual(try backer(2), fund, "exactly the deposit")

        // An unbacked hold is the operator's, not the fund's.
        try ledger.commit(client: "a", fee: 1, on: nexus, balance: 100, holdUntil: 1_000, now: 2)
        XCTAssertEqual(ledger.held(by: fund, now: 2), UInt256(3))
        // The whole key's float still bounds everything.
        XCTAssertThrowsError(
            try ledger.commit(client: "a", fee: 2, on: nexus, balance: 5, holdUntil: 1_000, now: 2, fund: fund)
        ) { XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat) }

        XCTAssertEqual(ledger.held(by: fund, now: 1_000), .zero, "expired")
        XCTAssertEqual(try backer(5, now: 1_000), fund)
        XCTAssertEqual(funds.deposit(of: fund), 5, "sponsoring draws nothing")
    }

    /// Only one block per height can be the chain's: the credit a height
    /// backs, over every client, stops at its reward.
    func testCreditAtAHeightStopsAtItsBlocksReward() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market)
        let b = try ledger.assign(client: "b", on: market)
        for nonce in 0..<10 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        for nonce in 100..<106 {
            _ = try ledger.credit(assignment: b.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market) + ledger.credit(of: "b", on: market), units(10))
        XCTAssertThrowsError(try ledger.credit(assignment: b.id, nonce: 106, hash: UInt256(1), now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut)
        }
        XCTAssertThrowsError(try ledger.assign(client: "c", on: market)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut)
        }
        ledger.install(template(workID: "w2", marketHeight: 8), clean: false, now: 2)
        XCTAssertNoThrow(try ledger.assign(client: "c", on: market), "the next height backs credit anew")
    }

    /// Once the chain moves past the block a template carries, work on that
    /// template can no longer win it and earns nothing.
    func testWorkOnAHeightTheChainHasPassedEarnsNothing() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market)
        ledger.install(template(workID: "w2", marketHeight: 8), clean: false, now: 1)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 0, hash: UInt256(1), now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .expired)
        }
    }

    /// A refresh that leaves the chain out (the node omitted its block, or a
    /// read failed) neither resets a height's backing nor hides that the
    /// chain moved past it.
    func testAChainMissingFromOneRefreshKeepsItsHeightsBackingAndStaleness() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market)
        for nonce in 0..<16 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        ledger.install(template(workID: "w2", marketReward: nil), clean: false, now: 2)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 16, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut, "the height's reward is still spent")
        }
        ledger.install(template(workID: "w3", marketHeight: 7), clean: false, now: 3)
        XCTAssertThrowsError(try ledger.assign(client: "b", on: market)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut)
        }

        var moved = self.ledger()
        let b = try moved.assign(client: "b", on: market)
        moved.install(template(workID: "w2", marketHeight: 8), clean: false, now: 1)
        moved.install(template(workID: "w3", marketReward: nil), clean: false, now: 2)
        XCTAssertThrowsError(try moved.credit(assignment: b.id, nonce: 0, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .expired, "a live template still shows the chain at 8")
        }
    }

    /// After a reorg to a lower height, no range is handed out that a held
    /// template's higher height would refuse.
    func testNoWorkIsAssignedBelowAHeldTemplatesHeight() throws {
        var ledger = ledger()
        ledger.install(template(workID: "w0", marketHeight: 8), clean: false, now: 0)
        ledger.install(template(workID: "w2", marketHeight: 7), clean: false, now: 1)
        XCTAssertThrowsError(try ledger.assign(client: "a", on: market)) {
            XCTAssertEqual($0 as? SponsorRefusal, .busy)
        }
        ledger.install(template(workID: "w3", marketHeight: 7), clean: true, now: 2)
        XCTAssertNoThrow(try ledger.assign(client: "a", on: market), "once a clean template retires the higher one")
    }

    /// Proof-of-work arrivals are memoryless: however long a template has
    /// been the newest, its work, its price and its blocks stand.
    func testWorkNeverExpiresOnAClock() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        let late: Int64 = 1_000_000_000_000
        XCTAssertEqual(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: late), nexusShare)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1")
        XCTAssertEqual(ledger.latest?.workID, "w1")
        XCTAssertNoThrow(try ledger.assign(client: "b", on: nexus))
        XCTAssertEqual(ledger.sharesFor(fee: 1_000, on: nexus), UInt256(256))
    }

    /// Only the pool or a hosted chain moved: earlier work stays valid, and
    /// new work is handed out on the new template.
    func testATemplateThatIsNotCleanKeepsEarlierWork() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(workID: "w2"), clean: false, now: 1)
        let b = try ledger.assign(client: "b", on: nexus)
        XCTAssertEqual(b.workID, "w2")
        XCTAssertEqual(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2), nexusShare)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1")
    }

    /// A clean template is the node's word that earlier work is gone: shares
    /// on it earn nothing, though a block on it is still the node's to judge.
    func testACleanTemplateRetiresEarlierWork() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        _ = try ledger.credit(assignment: a.id, nonce: 0, hash: UInt256(1), now: 1)
        ledger.install(template(workID: "w2"), clean: true, now: 2)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unknownAssignment)
        }
        XCTAssertEqual(
            ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1",
            "a block on retired work still goes to the node, which judges it"
        )
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "once")
        XCTAssertEqual(ledger.credit(of: "a", on: nexus), nexusShare, "credit already earned stays")
        XCTAssertEqual(try ledger.assign(client: "a", on: nexus).workID, "w2")
        ledger.install(template(workID: "w3"), clean: true, now: 3)
        XCTAssertEqual(
            ledger.block(assignment: a.id, nonce: 3, hash: target(203)), "w1",
            "a second clean push keeps earlier retired work too"
        )
    }

    /// Retired work is forgotten only past `maxTemplates` retired, oldest
    /// first, however many clean pushes come.
    func testRetiredWorkIsForgottenOldestFirstPastTheBound() throws {
        var ledger = SponsorLedger(shareTarget: target(208), rangeSize: 100, maxTemplates: 2)
        ledger.install(template(), clean: false, now: 0)
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(workID: "w2"), clean: true, now: 1)
        let b = try ledger.assign(client: "b", on: nexus)
        ledger.install(template(workID: "w3"), clean: true, now: 2)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 1, hash: target(203)), "w1")
        XCTAssertEqual(ledger.block(assignment: b.id, nonce: 1, hash: target(203)), "w2")
        ledger.install(template(workID: "w4"), clean: true, now: 3)
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1 is the oldest retired")
        XCTAssertEqual(ledger.block(assignment: b.id, nonce: 2, hash: target(203)), "w2")
    }

    /// The node refused a block on work it no longer holds: that work
    /// earns nothing more, though a block on it is still the node's to judge.
    /// The newest template stays until the node's next push replaces it, so
    /// the sponsor keeps pricing in between.
    func testWorkTheNodeNoLongerHoldsIsRetired() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(workID: "w2"), clean: false, now: 1)
        ledger.retire(workID: "w1")
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unknownAssignment)
        }
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1")
        ledger.retire(workID: "w2")
        XCTAssertEqual(try ledger.assign(client: "b", on: nexus).workID, "w2", "the newest waits for the push")
    }

    /// Work pushed again after it was retired is the node's again: its ranges
    /// are valid, its shares are not paid twice, and new ranges do not
    /// overlap them.
    func testRetiredWorkPushedAgainIsValidAgain() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        _ = try ledger.credit(assignment: a.id, nonce: 0, hash: UInt256(1), now: 1)
        ledger.install(template(workID: "w2"), clean: true, now: 2)
        ledger.install(template(), clean: true, now: 3)
        XCTAssertEqual(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 4), nexusShare)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 0, hash: UInt256(1), now: 4)) {
            XCTAssertEqual($0 as? SponsorRefusal, .duplicateShare)
        }
        XCTAssertEqual(try ledger.assign(client: "b", on: nexus).startNonce, 100)
    }

    /// A block is handed to the node once while its submit is out, and once
    /// answered, never again; one whose submit failed is not answered, so it
    /// is not marked sent (the sponsor keeps it to hand again).
    func testABlockIsMarkedSentOnlyOnceTheNodeAnswers() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 1, hash: target(203)), "w1")
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 1, hash: target(203)), "its submit is out")
        ledger.answered(workID: "w1", nonce: 1)
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 1, hash: target(203)), "answered")

        var unsent = UnsentBlocks(capacity: 2)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1")
        unsent.keep(workID: "w1", nonce: 2)  // the node could not be reached
        XCTAssertEqual(unsent.take(), [UnsentBlocks.Block(workID: "w1", nonce: 2)], "handed again once heard")
        XCTAssertEqual(unsent.count, 0)
        ledger.answered(workID: "w1", nonce: 2)
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 2, hash: target(203)))
    }


    /// A reconnect's first push is clean; when it repeats the work in hand,
    /// that work is still the node's and stays valid.
    func testACleanTemplateRepeatingHeldWorkKeepsIt() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(), clean: true, now: 1)
        XCTAssertEqual(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2), nexusShare)
    }

    /// Unheard, the sponsor hands out no work and prices nothing; work
    /// already handed out is still credited and its blocks still submitted.
    func testDisconnectedHandsOutNothingButKeepsWorkHandedOut() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.disconnect()
        XCTAssertNil(ledger.latest)
        XCTAssertThrowsError(try ledger.assign(client: "b", on: nexus)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unpriceable)
        }
        XCTAssertNil(ledger.sharesFor(fee: 1, on: nexus))
        XCTAssertEqual(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2), nexusShare)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1")
        ledger.install(template(workID: "w2"), clean: false, now: 3)
        XCTAssertNoThrow(try ledger.assign(client: "b", on: nexus), "heard again")
    }

    /// Between clean templates, the most held is bounded: the oldest go first.
    func testTemplatesPastTheCapDropOldestFirst() throws {
        var ledger = SponsorLedger(shareTarget: target(208), rangeSize: 100, maxTemplates: 2)
        ledger.install(template(), clean: false, now: 0)
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(workID: "w2"), clean: false, now: 1)
        let b = try ledger.assign(client: "b", on: nexus)
        ledger.install(template(workID: "w3"), clean: false, now: 2)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 3)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unknownAssignment)
        }
        XCTAssertNoThrow(try ledger.credit(assignment: b.id, nonce: 1, hash: UInt256(1), now: 3))
    }

    func testSponsoredBodyAddsOnlyTheFeeAndCoSigns() throws {
        let client = CryptoUtils.generateKeyPair()
        let sponsorKey = CryptoUtils.generateKeyPair()
        let clientAddress = CryptoUtils.createAddress(from: client.publicKey)
        let sponsorAddress = CryptoUtils.createAddress(from: sponsorKey.publicKey)
        let body = try sponsoredBody(
            draft: draft(signer: clientAddress, actions: [Action(key: "greeting", oldValue: nil, newValue: "hi")]),
            sponsor: sponsorAddress,
            fee: 7,
            chainPath: ["Nexus"]
        )
        XCTAssertEqual(body.signers, [clientAddress, sponsorAddress], "the client keeps the nonce")
        XCTAssertEqual(body.minerSurplus(), WorkSum(UInt256(7)))

        let header = try HeaderImpl(node: body)
        var signatures: [String: String] = [:]
        for key in [client, sponsorKey] {
            signatures[key.publicKey] = TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey)
        }
        XCTAssertTrue(Transaction(signatures: signatures, body: header).signaturesMatchSigners())
    }

    /// A buyer with no coins buys from a seller: the sponsor's payment nets
    /// the buyer's debit to nothing, so only the sponsor's account is drawn
    /// on, by the price and the fee.
    func testSponsoredBodyPaysWithinTheDraft() throws {
        let buyer = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let seller = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let purchase = draft(signer: buyer, accountActions: [
            AccountAction(owner: buyer, delta: -25), AccountAction(owner: seller, delta: 25),
        ])
        let body = try sponsoredBody(draft: purchase, sponsor: sponsor, fee: 3, pay: 25, chainPath: ["Nexus"])
        XCTAssertEqual(body.signers, [buyer, sponsor])
        XCTAssertTrue(body.accountActionsAreValid())
        XCTAssertEqual(body.minerSurplus(), WorkSum(UInt256(3)), "the fee alone is the surplus")
        XCTAssertEqual(try body.netBalanceDeltas(), [seller: .credit(25), sponsor: .debit(28)])

        XCTAssertEqual(
            try sponsoredBody(draft: purchase, sponsor: sponsor, fee: 3, chainPath: ["Nexus"]).accountActions.count,
            3, "without a pay, only the fee is added"
        )
        XCTAssertThrowsError(try sponsoredBody(
            draft: purchase, sponsor: sponsor, fee: 3, pay: UInt64(Int64.max), chainPath: ["Nexus"]
        ))
    }

    func testSponsoredBodyRefusesDraftsThatReachTheSponsor() {
        let client = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let refused: [TransactionBody] = [
            draft(signer: client, accountActions: [
                AccountAction(owner: sponsor, delta: -5), AccountAction(owner: client, delta: 5),
            ]),
            draft(signer: client, actions: [Action(key: "owner/\(sponsor)", oldValue: nil, newValue: "x")]),
            draft(signer: client, actions: [Action(key: "name/h", oldValue: sponsor, newValue: "\(sponsor)>\(client)")]),
            draft(signer: client, accountActions: [AccountAction(owner: client, delta: 5)]),
            draft(signer: client, chainPath: ["Nexus", "Market"]),
            draft(signer: sponsor),
        ]
        for body in refused {
            XCTAssertThrowsError(try sponsoredBody(draft: body, sponsor: sponsor, fee: 1, chainPath: ["Nexus"]))
        }
        XCTAssertThrowsError(try sponsoredBody(draft: draft(signer: client), sponsor: sponsor, fee: 0, chainPath: ["Nexus"]))
    }
}
