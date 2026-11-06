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
    marketHeight: UInt64 = 7,
    parent: String = "p1"
) -> SponsorTemplate {
    var prices = [nexus: ChainPrice(target: target(200), height: 3, reward: 1_000)]
    if let marketReward {
        prices[market] = ChainPrice(target: target(204), height: marketHeight, reward: marketReward)
    }
    return SponsorTemplate(
        workID: workID,
        prefixHex: "00",
        prices: prices,
        submitTarget: target(204),
        parent: parent
    )
}

/// `units` whole units of a chain's currency, as credit is kept.
private func units(_ units: UInt64) -> UInt256 { UInt256(units) * SponsorLedger.unit }

private func draft(
    signer: String,
    accountActions: [AccountAction] = [],
    actions: [Action] = [],
    nonce: UInt64 = 0,
    chainPath: [String] = ["Nexus"]
) -> TransactionBody {
    TransactionBody(
        accountActions: accountActions,
        actions: actions,
        depositActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [signer],
        nonce: nonce,
        chainPath: chainPath
    )
}

final class SponsorLedgerTests: XCTestCase {
    /// A share target 2^8 easier than Nexus's block (a share is 1/256 of
    /// its 1,000: 1000/256 units) and 2^4 easier than Market's (1/16 of
    /// its 10: 10/16 units).
    private func ledger() -> SponsorLedger {
        var ledger = SponsorLedger(shareTarget: target(208), rangeSize: 100)
        ledger.install(template(), now: 0)
        return ledger
    }

    /// A ledger whose client "a" has ample credit on Nexus.
    private func fundedLedger() -> SponsorLedger {
        var ledger = ledger()
        let a = try! ledger.assign(client: "a", on: nexus)
        for nonce in 0..<20 {
            _ = try! ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        return ledger
    }

    private func comment(_ signer: String, nonce: UInt64 = 0) -> TransactionBody {
        draft(signer: signer, actions: [Action(key: "comment/1", oldValue: nil, newValue: "hi")], nonce: nonce)
    }

    private var files: [URL] = []

    private func temporary(_ name: String) -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
        files.append(file)
        return file
    }

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
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
        ledger.install(template(workID: "w2", marketHeight: 8), now: 1)
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
        ledger.install(template(workID: "w2", marketReward: 20), now: 2)
        let late = try ledger.assign(client: "a", on: market)
        _ = try ledger.credit(assignment: early.id, nonce: 8, hash: UInt256(1), now: 3)
        for nonce in 0..<8 {
            _ = try ledger.credit(assignment: late.id, nonce: UInt64(nonce), hash: UInt256(1), now: 3)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market), units(15) + marketShare)

        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: nexus, signer: "c", nonce: 0, balance: 100)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit, "market credit pays no Nexus fee")
        }
        try ledger.commit(client: "a", fee: 15, on: market, signer: "c", nonce: 0, balance: 100)
        XCTAssertEqual(ledger.credit(of: "a", on: market), marketShare)

        ledger.install(template(workID: "w3", marketReward: nil), now: 5)
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
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 8, on: nexus, signer: "c", nonce: 0, balance: 100)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit, "two shares are 7.8 units")
        }
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 4, on: nexus, signer: "c", nonce: 0, balance: 3)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat)
        }
        try ledger.commit(client: "a", fee: 4, on: nexus, signer: "c", nonce: 0, balance: 7)
        XCTAssertEqual(ledger.credit(of: "a", on: nexus), nexusShare * UInt256(2) - units(4))

        let b = try ledger.assign(client: "b", on: nexus)
        for nonce in 100..<102 {
            _ = try ledger.credit(assignment: b.id, nonce: UInt64(nonce), hash: UInt256(1), now: 3)
        }
        XCTAssertThrowsError(try ledger.commit(client: "b", fee: 4, on: nexus, signer: "d", nonce: 0, balance: 7)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat, "a's fee is still held")
        }
        try ledger.commit(client: "b", fee: 4, on: nexus, signer: "d", nonce: 0, balance: 8)
    }

    /// A fund's deposit backs holds up to its size, and is never drawn:
    /// room comes back as the chain moves past the holds.
    func testAFundBacksHoldsUpToItsDeposit() throws {
        var funds = try FundLedger(file: temporary("funds"))
        let fund = FundID(["comment/"], on: nexus)
        _ = try funds.credit(fund, coins: 5)

        var ledger = fundedLedger()
        func backer(_ signer: String, _ total: UInt64, fundedOnly: Bool = false) throws -> FundID? {
            try funds.backer(
                for: comment(signer), fund: ["comment/"], total: total, ledger: ledger, fundedOnly: fundedOnly
            )
        }

        let backed = try XCTUnwrap(try backer("c", 3))
        try ledger.commit(client: "a", fee: 3, on: nexus, signer: "c", nonce: 0, balance: 100, fund: backed)
        XCTAssertEqual(ledger.held(by: fund), UInt256(3))
        // The cap: what the fund holds and this total over its deposit.
        XCTAssertNil(try backer("d", 3), "3 held and 3 more is over the 5 deposited")
        XCTAssertThrowsError(try backer("d", 3, fundedOnly: true)) { XCTAssertEqual($0 as? SponsorRefusal, .notFunded) }
        XCTAssertEqual(try backer("d", 2), fund, "exactly the deposit")

        // An unbacked hold is the operator's, not the fund's.
        try ledger.commit(client: "a", fee: 1, on: nexus, signer: "c", nonce: 0, balance: 100)
        XCTAssertEqual(ledger.held(by: fund), UInt256(3))
        // The whole key's float still bounds everything.
        XCTAssertThrowsError(
            try ledger.commit(client: "a", fee: 2, on: nexus, signer: "d", nonce: 0, balance: 5, fund: fund)
        ) { XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat) }
        XCTAssertEqual(funds.deposit(of: fund), 5, "sponsoring draws nothing")
    }

    /// A hold ends when its signer's nonce passes it, however that came
    /// about, and never with time.
    func testAHoldIsReleasedOnlyWhenItsSignersNoncePassesIt() throws {
        let fund = FundID(["comment/"], on: nexus)
        var ledger = fundedLedger()
        // c's transaction at nonce 4 lands: c's next nonce is 5. d's at
        // nonce 2 is passed by another of d's at 2 (or 3, ...): d's next is
        // 4. e's at 7 was dropped by the host: e's next nonce is still 7.
        // f's chain reads no account for it at all.
        for (signer, nonce) in [("c", 4), ("d", 2), ("e", 7), ("f", 0)] as [(String, UInt64)] {
            try ledger.commit(client: "a", fee: 1, on: nexus, signer: signer, nonce: nonce, balance: 100, fund: fund)
        }
        XCTAssertEqual(ledger.held(by: fund), UInt256(4))
        XCTAssertEqual(
            ledger.holders, Set(["c", "d", "e", "f"].map { SponsorLedger.Holder(chainPath: nexus, signer: $0) })
        )
        ledger.install(template(workID: "w2", parent: "p2"), now: 100_000_000)
        XCTAssertEqual(ledger.held(by: fund), UInt256(4), "a new tip, however late, releases nothing by itself")

        try ledger.release(nextNonces: [
            SponsorLedger.Holder(chainPath: nexus, signer: "c"): 5,
            SponsorLedger.Holder(chainPath: nexus, signer: "d"): 4,
            SponsorLedger.Holder(chainPath: nexus, signer: "e"): 7,
            SponsorLedger.Holder(chainPath: market, signer: "f"): 9,
        ])
        XCTAssertNil(ledger.hold(of: "c", under: fund), "landed")
        XCTAssertNil(ledger.hold(of: "d", under: fund), "passed: it can never land")
        XCTAssertEqual(ledger.hold(of: "e", under: fund)?.nonce, 7, "dropped but not passed: it can still be resubmitted")
        XCTAssertEqual(ledger.hold(of: "f", under: fund)?.nonce, 0, "another chain's nonce says nothing here")
        XCTAssertEqual(ledger.held(by: fund), UInt256(2))
    }

    /// A signer holds one transaction at a time under a fund, so one that
    /// never lands keeps at most one fee of it. A redraft at the same nonce
    /// replaces it, since only one of the two can land.
    func testASignerHoldsOneTransactionAtATimeUnderAFund() throws {
        var funds = try FundLedger(file: temporary("funds"))
        let fund = FundID(["comment/"], on: nexus)
        _ = try funds.credit(fund, coins: 10)
        var ledger = fundedLedger()
        func backer(_ nonce: UInt64, _ total: UInt64, fundedOnly: Bool = false) throws -> FundID? {
            try funds.backer(
                for: comment("c", nonce: nonce), fund: ["comment/"], total: total, ledger: ledger,
                fundedOnly: fundedOnly
            )
        }

        try ledger.commit(client: "a", fee: 3, on: nexus, signer: "c", nonce: 4, balance: 100, fund: try backer(4, 3))
        XCTAssertNil(try backer(5, 1), "another in flight: the operator's float, if anyone's")
        XCTAssertThrowsError(try backer(5, 1, fundedOnly: true)) { XCTAssertEqual($0 as? SponsorRefusal, .inFlight) }
        XCTAssertEqual(try backer(4, 2), fund, "a redraft at its nonce")
        XCTAssertNil(try backer(4, 11), "a redraft still fits the deposit: 3 replaced by 11 is over the 10")

        try ledger.commit(client: "a", fee: 3, on: nexus, signer: "d", nonce: 0, balance: 100, fund: fund)
        try ledger.commit(client: "a", fee: 2, on: nexus, signer: "c", nonce: 4, balance: 100, fund: try backer(4, 2))
        XCTAssertEqual(ledger.held(by: fund), UInt256(6), "replaced, keeping the larger fee")
        XCTAssertEqual(ledger.hold(of: "c", under: fund)?.fee, 3)

        try ledger.release(nextNonces: [SponsorLedger.Holder(chainPath: nexus, signer: "c"): 5])
        XCTAssertEqual(try backer(5, 1, fundedOnly: true), fund, "landed: the next may go")
    }

    /// Holds kept in a file survive a restart, as deposits and claims do.
    func testDepositsClaimsAndHoldsSurviveARestart() throws {
        let fundsFile = temporary("funds"), paymentsFile = temporary("payments"), holdsFile = temporary("holds")
        let fund = FundID(["comment/", "profile/"], on: market)
        var funds = try FundLedger(file: fundsFile)
        _ = try funds.credit(fund, coins: 9)
        var payments = try PaymentLedger(file: paymentsFile)
        try payments.claim("tx1")
        try payments.release("tx1", credit: true)

        var ledger = fundedLedger()
        try ledger.keepHolds(in: holdsFile)
        let assignment = try ledger.assign(client: "a", on: market)
        for nonce in 0..<8 {
            _ = try ledger.credit(assignment: assignment.id, nonce: assignment.startNonce + UInt64(nonce), hash: UInt256(1), now: 1)
        }
        try ledger.commit(client: "a", fee: 4, on: market, signer: "c", nonce: UInt64.max, balance: 100, fund: fund)
        try ledger.commit(client: "a", fee: 1, on: nexus, signer: "c", nonce: 2, balance: 100)
        try ledger.commit(client: "a", fee: 2, on: nexus, signer: "d", nonce: 0, balance: 100)
        try ledger.release(nextNonces: [SponsorLedger.Holder(chainPath: nexus, signer: "d"): 1])

        var restarted = SponsorLedger(shareTarget: target(208), rangeSize: 100)
        try restarted.keepHolds(in: holdsFile)
        XCTAssertEqual(restarted.held(by: fund), UInt256(4))
        XCTAssertEqual(restarted.hold(of: "c", under: fund)?.nonce, UInt64.max)
        XCTAssertEqual(
            restarted.holders, Set([SponsorLedger.Holder(chainPath: market, signer: "c"), SponsorLedger.Holder(chainPath: nexus, signer: "c")])
        )
        XCTAssertEqual(try FundLedger(file: fundsFile).deposit(of: fund), 9)
        XCTAssertEqual(try PaymentLedger(file: paymentsFile).credited, ["tx1"])
        // The float still counts the operator's hold after the restart: 1
        // held, and 100 more is over the 100.
        restarted.install(template(), now: 0)
        let b = try restarted.assign(client: "b", on: nexus)
        for nonce in 0..<30 {
            _ = try restarted.credit(assignment: b.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        XCTAssertThrowsError(try restarted.commit(client: "b", fee: 100, on: nexus, signer: "e", nonce: 0, balance: 100)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat)
        }
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
        ledger.install(template(workID: "w2", marketHeight: 8), now: 2)
        XCTAssertNoThrow(try ledger.assign(client: "c", on: market), "the next height backs credit anew")
    }

    /// Once the chain moves past the block a template carries, work on that
    /// template can no longer win it and earns nothing.
    func testWorkOnAHeightTheChainHasPassedEarnsNothing() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market)
        ledger.install(template(workID: "w2", marketHeight: 8), now: 1)
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
        ledger.install(template(workID: "w2", marketReward: nil), now: 2)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 16, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut, "the height's reward is still spent")
        }
        ledger.install(template(workID: "w3", marketHeight: 7), now: 3)
        XCTAssertThrowsError(try ledger.assign(client: "b", on: market)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut)
        }

        var moved = self.ledger()
        let b = try moved.assign(client: "b", on: market)
        moved.install(template(workID: "w2", marketHeight: 8), now: 1)
        moved.install(template(workID: "w3", marketReward: nil), now: 2)
        XCTAssertThrowsError(try moved.credit(assignment: b.id, nonce: 0, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .expired, "a live template still shows the chain at 8")
        }
    }

    /// After a reorg to a lower height, no range is handed out that a held
    /// template's higher height would refuse.
    func testNoWorkIsAssignedBelowAHeldTemplatesHeight() throws {
        var ledger = ledger()
        ledger.install(template(workID: "w0", marketHeight: 8), now: 0)
        ledger.install(template(workID: "w2", marketHeight: 7), now: 1)
        XCTAssertThrowsError(try ledger.assign(client: "a", on: market)) {
            XCTAssertEqual($0 as? SponsorRefusal, .busy)
        }
        ledger.install(template(workID: "w3", marketHeight: 7, parent: "p2"), now: 2)
        XCTAssertNoThrow(try ledger.assign(client: "a", on: market), "once a new tip retires the higher one")
    }

    /// Proof-of-work arrivals are memoryless: however long a template has
    /// been the newest, its work, its price and its blocks stand.
    func testWorkAndPriceStandHoweverLongItIsQuiet() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        let late: Int64 = 1_000_000_000_000
        XCTAssertEqual(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: late), nexusShare)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1")
        XCTAssertNoThrow(try ledger.assign(client: "b", on: nexus))
        XCTAssertEqual(ledger.sharesFor(fee: 1_000, on: nexus), UInt256(256))
    }

    /// On the same tip only the pool or a hosted chain moved: earlier work
    /// stays valid, and new work goes on the newest template.
    func testATemplateOnTheSameTipKeepsEarlierWork() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(workID: "w2"), now: 1)
        XCTAssertEqual(try ledger.assign(client: "b", on: nexus).workID, "w2")
        XCTAssertEqual(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2), nexusShare)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1")
    }

    /// A template on a new tip retires every earlier one and its work;
    /// credit already earned stays.
    func testATemplateOnANewTipRetiresEarlierWork() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        _ = try ledger.credit(assignment: a.id, nonce: 0, hash: UInt256(1), now: 1)
        ledger.install(template(workID: "w2", parent: "p2"), now: 2)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unknownAssignment)
        }
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 2, hash: target(203)))
        XCTAssertEqual(ledger.credit(of: "a", on: nexus), nexusShare)
    }

    /// The first template since connecting retires earlier work even on the
    /// same tip: the node may have restarted and lost it.
    func testAFreshTemplateRetiresEarlierWork() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(workID: "w2"), fresh: true, now: 1)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unknownAssignment)
        }
    }

    /// Blind (a fetch failed, or the node's events ended), the sponsor hands
    /// out no work and prices nothing; work handed out keeps its credit and
    /// its blocks, and the next template ends it.
    func testBlindHandsOutNothingButKeepsWorkHandedOut() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.blind()
        XCTAssertThrowsError(try ledger.assign(client: "b", on: nexus)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unpriceable)
        }
        XCTAssertNil(ledger.sharesFor(fee: 1, on: nexus))
        XCTAssertEqual(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 1), nexusShare)
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1")
        ledger.install(template(workID: "w2"), now: 2)
        XCTAssertEqual(try ledger.assign(client: "b", on: nexus).workID, "w2")
        XCTAssertNoThrow(try ledger.credit(assignment: a.id, nonce: 3, hash: UInt256(1), now: 3), "same tip, still valid")
    }

    /// A block refused as work the node no longer holds retires that work;
    /// the newest waits for the node's event to replace it.
    func testWorkTheNodeNoLongerHoldsIsRetired() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(workID: "w2"), now: 1)
        ledger.retire(workID: "w1")
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unknownAssignment)
        }
        ledger.retire(workID: "w2")
        XCTAssertEqual(try ledger.assign(client: "b", on: nexus).workID, "w2")
    }

    /// On one tip, the templates held are bounded: the oldest go first.
    func testTemplatesPastTheCapDropOldestFirst() throws {
        var ledger = SponsorLedger(shareTarget: target(208), rangeSize: 100, maxTemplates: 2)
        ledger.install(template(), now: 0)
        let a = try ledger.assign(client: "a", on: nexus)
        ledger.install(template(workID: "w2"), now: 1)
        let b = try ledger.assign(client: "b", on: nexus)
        ledger.install(template(workID: "w3"), now: 2)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 1, hash: UInt256(1), now: 3)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unknownAssignment)
        }
        XCTAssertNoThrow(try ledger.credit(assignment: b.id, nonce: 1, hash: UInt256(1), now: 3))
    }

    // MARK: payout work

    func testPayoutWorkIsOwedElsewhereAndBacksAtMostHalfAHeight() throws {
        var ledger = ledger()
        // Nexus's block is 1,000: payout work may back 500 of it.
        // 128 shares of 1000/256: more than one range of 100.
        var owed = UInt256.zero
        var work = try ledger.assign(client: "t", on: nexus, payTo: "alice")
        var nonce = work.startNonce
        while true {
            if nonce == work.startNonce + work.count {
                work = try ledger.assign(client: "t", on: nexus, payTo: "alice")
                nonce = work.startNonce
            }
            do { owed = owed + (try ledger.credit(assignment: work.id, nonce: nonce, hash: UInt256(1), now: 1)) }
            catch { XCTAssertEqual(error as? SponsorRefusal, .soldOut); break }
            nonce += 1
        }
        XCTAssertEqual(owed, units(500), "payout work stops at half the block")
        XCTAssertEqual(ledger.credit(of: "t", on: nexus), .zero, "no fee credit for payout work")
        XCTAssertThrowsError(try ledger.assign(client: "t", on: nexus, payTo: "bob")) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut)
        }
        // Fee work still has the other half.
        let fee = try ledger.assign(client: "a", on: nexus)
        XCTAssertEqual(try ledger.credit(assignment: fee.id, nonce: fee.startNonce, hash: UInt256(1), now: 1), nexusShare)
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
