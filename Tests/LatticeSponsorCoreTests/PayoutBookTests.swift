import Foundation
import XCTest
import Lattice
import LatticeNodeAPI
import UInt256
@testable import LatticeSponsorCore

private let chain = ["Nexus", "Market"]
private func coins(_ n: UInt64) -> UInt256 { UInt256(n) * SponsorLedger.unit }
private let half = SponsorLedger.unit >> 1

/// A stand-in version: the book never reads the transaction, only keeps it.
private func payoutVersion(_ cid: String, fee: UInt64 = 1) -> PayoutBook.Version {
    let body = payoutBody(recipients: [], sponsor: "s", fee: fee, nonce: 0, chainPath: chain)
    return PayoutBook.Version(cid: cid, fee: fee, transaction: ContentBoundTransaction(signatures: [:], body: body))
}

final class PayoutBookTests: XCTestCase {
    private var files: [URL] = []

    private func temporary() -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("payouts-\(UUID().uuidString).json")
        files.append(file)
        return file
    }

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        files = []
    }

    /// alice owed 78.5 coins, bob 7.5, on `chain`.
    private func book(_ file: URL? = nil) throws -> PayoutBook {
        var book = try PayoutBook(file: file)
        book.earn(coins(78) + half, to: "alice", on: chain)
        book.earn(coins(7) + half, to: "bob", on: chain)
        return book
    }

    func testDuePaysWholeCoinsOverTheThresholdLargestFirstWithinRoom() throws {
        let book = try book()
        XCTAssertEqual(book.dueChains(threshold: 10), [chain])
        XCTAssertEqual(book.due(on: chain, threshold: 10, maxRecipients: 8, room: 1_000), [.init(address: "alice", amount: 78)])
        XCTAssertEqual(book.due(on: chain, threshold: 5, maxRecipients: 1, room: 1_000).map(\.address), ["alice"])
        XCTAssertEqual(book.due(on: chain, threshold: 5, maxRecipients: 8, room: 50), [.init(address: "bob", amount: 7)],
                       "alice doesn't fit the room; bob does")
        XCTAssertEqual(book.dueChains(threshold: 100), [])
    }

    func testBeginTakesTheCoinsOffAndReservesThemBeforeAnySend() throws {
        var book = try book()
        try book.begin(on: chain, nonce: 4, recipients: [.init(address: "alice", amount: 78)], version: payoutVersion("v1", fee: 2))
        XCTAssertEqual(book.earnings(of: "alice", on: chain), half, "the fraction stays owed")
        XCTAssertEqual(book.reserved(on: chain), 80)
        XCTAssertEqual(book.due(on: chain, threshold: 1, maxRecipients: 8, room: 1_000), [], "one payout pending at a time")
        XCTAssertEqual(book.dueChains(threshold: 1), [])
        XCTAssertThrowsError(try book.begin(on: ["Nexus"], nonce: 0, recipients: [.init(address: "alice", amount: 1)], version: payoutVersion("v2"))) {
            XCTAssertEqual($0 as? SponsorRefusal, .draft("a payout pays more than is owed"))
        }
    }

    /// A send that failed, or a crash after begin: the payout is still on
    /// disk, pending, and the coins stay off the earnings, so nothing is paid twice.
    func testAPendingPayoutAndEarningsSurviveARestart() throws {
        let file = temporary()
        var book = try book(file)
        try book.save()
        try book.begin(on: chain, nonce: 4, recipients: [.init(address: "alice", amount: 78)], version: payoutVersion("v1"))
        book.earn(coins(3), to: "bob", on: chain)
        try book.save()

        let restarted = try PayoutBook(file: file)
        XCTAssertEqual(restarted.pending(on: chain)?.nonce, 4)
        XCTAssertEqual(restarted.pending(on: chain)?.versions.map(\.cid), ["v1"])
        XCTAssertEqual(restarted.earnings(of: "alice", on: chain), half)
        XCTAssertEqual(restarted.earnings(of: "bob", on: chain), coins(10) + half)
    }

    func testAPayoutSettlesOnlyOnceAVersionIsDeep() throws {
        var book = try book()
        try book.begin(on: chain, nonce: 4, recipients: [.init(address: "alice", amount: 78)], version: payoutVersion("v1"))
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 4, tipHeight: 100, included: nil, depth: 6), .pending)
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 101, included: ("v1", 1), depth: 6), .pending,
                       "shallow: a reorg could still drop it")
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 106, included: ("v1", 6), depth: 6), .settled(cid: "v1"))
        XCTAssertNil(book.pending(on: chain))
        XCTAssertEqual(book.earnings(of: "alice", on: chain), half, "paid: not owed again")
    }

    /// The nonce passing proves a version landed even when the node can't
    /// show one: settled, never owed again on the book's own judgement.
    func testAPassedNonceWithNoVersionFoundSettlesAndOwesNothingAgain() throws {
        let file = temporary()
        var book = try book(file)
        try book.begin(on: chain, nonce: 4, recipients: [.init(address: "alice", amount: 78)], version: payoutVersion("v1"))
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 200, included: nil, depth: 6), .pending)
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 205, included: nil, depth: 6), .pending)
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 206, included: nil, depth: 6), .settledByNonce)
        XCTAssertNil(book.pending(on: chain))
        XCTAssertEqual(book.earnings(of: "alice", on: chain), half, "not owed again: it may well have been paid")
        XCTAssertEqual(try PayoutBook(file: file).unconfirmed.map(\.nonce), [4], "kept for the operator")
    }

    /// Only the operator, who knows they signed another transaction at the
    /// nonce, gives an unconfirmed payout's coins back, and only once.
    func testTheOperatorReleasesAnUnconfirmedPayoutOnce() throws {
        let file = temporary()
        var book = try book(file)
        try book.begin(on: chain, nonce: 4, recipients: [.init(address: "alice", amount: 78)], version: payoutVersion("v1"))
        _ = try book.observe(on: chain, nextNonce: 5, tipHeight: 200, included: nil, depth: 6)
        _ = try book.observe(on: chain, nextNonce: 5, tipHeight: 206, included: nil, depth: 6)
        var restarted = try PayoutBook(file: file)
        XCTAssertFalse(try restarted.release(on: chain, nonce: 3))
        XCTAssertTrue(try restarted.release(on: chain, nonce: 4))
        XCTAssertEqual(restarted.earnings(of: "alice", on: chain), coins(78) + half)
        XCTAssertFalse(try restarted.release(on: chain, nonce: 4), "once")
        XCTAssertEqual(try PayoutBook(file: file).unconfirmed.count, 0)
    }

    func testAReorgThatUndoesThePassStartsTheCountAgain() throws {
        var book = try book()
        try book.begin(on: chain, nonce: 4, recipients: [.init(address: "alice", amount: 78)], version: payoutVersion("v1"))
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 200, included: nil, depth: 6), .pending)
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 4, tipHeight: 203, included: nil, depth: 6), .pending,
                       "the nonce is free again")
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 206, included: nil, depth: 6), .pending,
                       "counted from the new pass, not the first")
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 212, included: nil, depth: 6), .settledByNonce)
    }

    func testAReplacementKeepsTheRecipientsAndReservesItsLargerFee() throws {
        let file = temporary()
        var book = try book(file)
        try book.begin(on: chain, nonce: 4, recipients: [.init(address: "alice", amount: 78)], version: payoutVersion("v1", fee: 1))
        try book.replace(on: chain, with: payoutVersion("v2", fee: 3))
        XCTAssertEqual(book.reserved(on: chain), 81)
        XCTAssertEqual(try PayoutBook(file: file).pending(on: chain)?.versions.map(\.cid), ["v1", "v2"])
        // The older version landing settles it just the same.
        XCTAssertEqual(try book.observe(on: chain, nextNonce: 5, tipHeight: 50, included: ("v1", 6), depth: 6), .settled(cid: "v1"))
    }

    func testSaveWritesOnlyWhenEarningsChanged() throws {
        let file = temporary()
        var book = try PayoutBook(file: file)
        try book.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        book.earn(coins(1), to: "alice", on: chain)
        XCTAssertTrue(book.dirty)
        try book.save()
        XCTAssertFalse(book.dirty)
        XCTAssertEqual(try PayoutBook(file: file).earnings(of: "alice", on: chain), coins(1))
    }
}
