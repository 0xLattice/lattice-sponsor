import Foundation
import XCTest
import Lattice
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

    func testACoveredFundedDraftDrawsThePrice() throws {
        var funds = try FundLedger(prices: [site: 3], file: file)
        let fund = try FundLedger.normalize(["comment/"])
        XCTAssertEqual(try funds.credit(fund, coins: 7, on: site), 7)

        let draft = body(["comment/1"])
        let payer = try XCTUnwrap(try funds.payer(for: draft, fund: ["comment/", "comment/"], fundedOnly: true))
        try funds.draw(payer, on: site)
        XCTAssertEqual(funds.balance(of: fund, on: site), 4)
        try funds.draw(payer, on: site)
        XCTAssertEqual(funds.balance(of: fund, on: site), 1)

        // Underfunded: refused with --funded-only, sponsored undrawn without.
        XCTAssertThrowsError(try funds.payer(for: draft, fund: fund, fundedOnly: true)) {
            XCTAssertEqual($0 as? SponsorRefusal, .notFunded)
        }
        XCTAssertNil(try funds.payer(for: draft, fund: fund, fundedOnly: false))
        XCTAssertThrowsError(try funds.draw(fund, on: site)) { XCTAssertEqual($0 as? SponsorRefusal, .notFunded) }
        XCTAssertEqual(funds.balance(of: fund, on: site), 1)
    }

    func testFundedOnlyRefusesWhatNoFundPaysForOnAPricedChain() throws {
        var funds = try FundLedger(prices: [site: 3], file: file)
        let fund = try FundLedger.normalize(["comment/"])
        _ = try funds.credit(fund, coins: 10, on: site)

        for (draft, named) in [
            (body(["comment/1"]), nil),
            (body(["other/1"]), fund),
            (body(["comment/1", "other/1"]), fund),
            (body([]), fund),
            (body(["comment/1"]), ["another/"]),
        ] as [(TransactionBody, [String]?)] {
            XCTAssertThrowsError(try funds.payer(for: draft, fund: named, fundedOnly: true)) {
                XCTAssertEqual($0 as? SponsorRefusal, .notFunded)
            }
            XCTAssertNil(try funds.payer(for: draft, fund: named, fundedOnly: false), "sponsored as before")
        }
        // A chain without a price ignores funds, --funded-only included.
        XCTAssertNil(try funds.payer(for: body(["other/1"], chainPath: ["Nexus"]), fund: fund, fundedOnly: true))
        XCTAssertNil(try funds.payer(for: body(["x"], chainPath: ["Nexus"]), fund: [], fundedOnly: true))
        XCTAssertThrowsError(try funds.credit(fund, coins: 1, on: ["Nexus"])) {
            XCTAssertEqual($0 as? SponsorRefusal, .noFundPrice)
        }
        XCTAssertEqual(funds.balance(of: fund, on: site), 10)
    }

    func testBalancesSurviveARestart() throws {
        var funds = try FundLedger(prices: [site: 2], file: file)
        let one = try FundLedger.normalize(["comment/"])
        let two = try FundLedger.normalize(["profile/", "comment/"])
        _ = try funds.credit(one, coins: 5, on: site)
        _ = try funds.credit(two, coins: UInt64.max, on: site)
        XCTAssertEqual(try funds.credit(two, coins: 1, on: site), .max, "saturating")
        try funds.draw(one, on: site)

        let restarted = try FundLedger(prices: [site: 2], file: file)
        XCTAssertEqual(restarted.balance(of: one, on: site), 3)
        XCTAssertEqual(restarted.balance(of: two, on: site), .max)
        XCTAssertEqual(restarted.balance(of: try FundLedger.normalize(["profile/"]), on: site), 0)
    }
}
