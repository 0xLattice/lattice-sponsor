import XCTest
@testable import LatticeSponsorCore

final class FeedTests: XCTestCase {
    func testBackoffDoublesToItsMostAcrossFailedConnections() {
        var backoff = Backoff()
        var waits: [Duration] = []
        for _ in 0..<7 {
            backoff.connecting()
            waits.append(backoff.next())
        }
        XCTAssertEqual(waits, [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5)])
    }

    /// A node that pushes once and ends has not proven the connection: it is
    /// not dialled again at the shortest wait.
    func testOnePushThenEndKeepsBackingOff() {
        var backoff = Backoff()
        for _ in 0..<3 {
            backoff.connecting()
            backoff.event()
            _ = backoff.next()
        }
        backoff.connecting()
        backoff.event()
        XCTAssertEqual(backoff.next(), .seconds(2))
    }

    /// A second event (a push, or a keepalive) proves the connection.
    func testASecondEventResetsTheWait() {
        var backoff = Backoff()
        for _ in 0..<3 {
            backoff.connecting()
            _ = backoff.next()
        }
        backoff.connecting()
        backoff.event()
        backoff.event()
        XCTAssertEqual(backoff.next(), .milliseconds(250))
    }

    func testUnsentBlocksKeepTheNewestWithinCapacity() {
        var unsent = UnsentBlocks(capacity: 2)
        XCTAssertNil(unsent.keep(workID: "w", nonce: 1))
        XCTAssertNil(unsent.keep(workID: "w", nonce: 1), "kept once")
        XCTAssertNil(unsent.keep(workID: "w", nonce: 2))
        XCTAssertEqual(unsent.keep(workID: "w", nonce: 3), UnsentBlocks.Block(workID: "w", nonce: 1))
        XCTAssertEqual(unsent.take().map(\.nonce), [2, 3])
        XCTAssertEqual(unsent.take(), [])
    }
}
