import Foundation
import XCTest
import Lattice
import UInt256
@testable import LatticeSponsorCore

private let site = ["Nexus", "Riposte"]

private func body(_ keys: [String], chainPath: [String] = site) -> TransactionBody {
    TransactionBody(
        accountActions: [],
        actions: keys.map { Action(key: $0, oldValue: nil, newValue: "x") },
        depositActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: ["client"],
        nonce: 0,
        chainPath: chainPath
    )
}

final class FundsTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("funds-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    func testPrefixesAreSortedByBytesAndDeduplicated() throws {
        XCTAssertEqual(try FundLedger.normalize(["b/", "a/", "b/", "B/"]), ["B/", "a/", "b/"])
        for bad in [[], Array(repeating: "a", count: 9), [""], [String(repeating: "a", count: 129)], ["a\nb"]] {
            XCTAssertThrowsError(try FundLedger.normalize(bad), "\(bad)")
        }
        XCTAssertNoThrow(try FundLedger.normalize([String(repeating: "a", count: 128)]))
        XCTAssertNoThrow(try FundLedger.normalize(["a", "b", "c", "d", "e", "f", "g", "a"]), "eight, one repeated")
        // Bytes, not characters: a composed and a decomposed é are two prefixes.
        XCTAssertEqual(try FundLedger.normalize(["\u{E9}", "e\u{301}"]).count, 2)
    }

    func testAFundCoversOnlyTransactionsEntirelyUnderItsPrefixes() {
        let prefixes = ["comment/example.com/", "profile/"]
        XCTAssertTrue(FundLedger.covers(body(["comment/example.com/1"]), prefixes: prefixes))
        XCTAssertTrue(FundLedger.covers(body(["comment/example.com/1", "profile/me"]), prefixes: prefixes))
        XCTAssertFalse(FundLedger.covers(body([]), prefixes: prefixes), "writes no key")
        XCTAssertFalse(FundLedger.covers(body(["comment/example.com/1", "comment/other.org/1"]), prefixes: prefixes),
                       "one key outside")
        XCTAssertFalse(FundLedger.covers(body(["comment/example.co"]), prefixes: prefixes), "shorter than the prefix")
        XCTAssertFalse(FundLedger.covers(body(["e\u{301}/1"]), prefixes: ["\u{E9}/"]), "compared as bytes")
    }

    func testFundedOnlyRefusesWhatNoFundBacks() throws {
        var funds = try FundLedger(file: file)
        let fund = try FundLedger.normalize(["comment/"])
        _ = try funds.credit(FundID(fund, on: site), coins: 10)
        let ledger = SponsorLedger(shareTarget: UInt256(1))

        XCTAssertEqual(
            try funds.backer(for: body(["comment/1"]), fund: ["comment/", "comment/"], total: 10, ledger: ledger, now: 0, fundedOnly: true),
            FundID(fund, on: site), "covered, and fits the deposit"
        )
        for (draft, named, total) in [
            (body(["comment/1"]), nil, 1),
            (body(["other/1"]), fund, 1),
            (body(["comment/1", "other/1"]), fund, 1),
            (body([]), fund, 1),
            (body(["comment/1"]), ["another/"], 1),
            (body(["comment/1"], chainPath: ["Nexus"]), fund, 1),
            (body(["comment/1"]), fund, 11),
        ] as [(TransactionBody, [String]?, UInt64)] {
            XCTAssertThrowsError(try funds.backer(for: draft, fund: named, total: total, ledger: ledger, now: 0, fundedOnly: true)) {
                XCTAssertEqual($0 as? SponsorRefusal, .notFunded)
            }
            XCTAssertNil(
                try funds.backer(for: draft, fund: named, total: total, ledger: ledger, now: 0, fundedOnly: false),
                "held against the operator's float, as before"
            )
        }
        XCTAssertEqual(funds.deposit(of: FundID(fund, on: ["Nexus"])), 0, "a fund is kept per chain")
    }

    func testDepositsSurviveARestart() throws {
        var funds = try FundLedger(file: file)
        let one = FundID(try FundLedger.normalize(["comment/"]), on: site)
        let two = FundID(try FundLedger.normalize(["profile/", "comment/"]), on: site)
        XCTAssertEqual(try funds.credit(one, coins: 5), 5)
        _ = try funds.credit(two, coins: UInt64.max)
        XCTAssertEqual(try funds.credit(two, coins: 1), .max, "saturating")
        XCTAssertEqual(try funds.credit(one, coins: 2), 7)

        let restarted = try FundLedger(file: file)
        XCTAssertEqual(restarted.deposit(of: one), 7)
        XCTAssertEqual(restarted.deposit(of: two), .max)
        XCTAssertEqual(restarted.deposit(of: FundID(["profile/"], on: site)), 0)
    }
}
