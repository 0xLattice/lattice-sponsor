import Foundation
import XCTest
@testable import LatticeSponsorCore

/// A record the feed's closures write to.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _connections = 0
    private var _fetches = 0
    private var _installed: [(Int, Bool)] = []
    private var _blind = 0
    private var _waits: [Duration] = []

    func connect() -> Int { lock.withLock { _connections += 1; return _connections } }
    func fetch() -> Int { lock.withLock { _fetches += 1; return _fetches } }
    func install(_ template: Int, _ fresh: Bool) { lock.withLock { _installed.append((template, fresh)) } }
    func blind() { lock.withLock { _blind += 1 } }
    func wait(_ duration: Duration) -> Int { lock.withLock { _waits.append(duration); return _waits.count } }
    var installed: [Int] { lock.withLock { _installed.map(\.0) } }
    var fresh: [Bool] { lock.withLock { _installed.map(\.1) } }
    var blinded: Int { lock.withLock { _blind } }
    var waits: [Duration] { lock.withLock { _waits } }
}

private struct Dropped: Error {}
private struct Stop: Error {}

/// Two events, then the connection ends.
private func twoEvents() -> AsyncThrowingStream<Void, any Error> {
    AsyncThrowingStream { continuation in
        continuation.yield()
        continuation.yield()
        continuation.finish()
    }
}

final class TemplateFeedTests: XCTestCase {
    /// Each event fetches a template and installs it, the first on each
    /// connection fresh; a dropped connection blinds the sponsor and is
    /// dialled again, and its first event fetches again.
    func testEachEventFetchesAndInstallsAndADropReconnects() async {
        let log = Log()
        await followTemplates(
            events: { _ = log.connect(); return twoEvents() },
            fetch: { log.fetch() },
            install: { log.install($0, $1) },
            blind: { log.blind() },
            log: { _ in },
            sleep: { if log.wait($0) == 2 { throw Stop() } }
        )
        XCTAssertEqual(log.installed, [1, 2, 3, 4])
        XCTAssertEqual(log.fresh, [true, false, true, false], "the first on each connection is fresh")
        XCTAssertEqual(log.blinded, 2)
        XCTAssertEqual(log.waits, [.milliseconds(250), .milliseconds(250)], "an install resets the wait")
    }

    /// A fetch that brings no template, or fails, blinds the sponsor and
    /// drops the connection; the next connection's first event fetches again.
    func testAFailedFetchBlindsAndReconnects() async {
        let log = Log()
        await followTemplates(
            events: { _ = log.connect(); return twoEvents() },
            fetch: { () -> Int? in
                let fetch = log.fetch()
                if fetch == 1 { return nil }
                if fetch == 2 { throw Dropped() }
                return fetch
            },
            install: { log.install($0, $1) },
            blind: { log.blind() },
            log: { _ in },
            sleep: { if log.wait($0) == 3 { throw Stop() } }
        )
        XCTAssertEqual(log.installed, [3, 4])
        XCTAssertEqual(log.blinded, 3)
        XCTAssertEqual(log.waits, [.milliseconds(250), .milliseconds(500), .milliseconds(250)])
    }

    /// With nothing installed, the waits between connections double to 5 s.
    func testWaitsDoubleWhileNothingIsInstalled() async {
        let log = Log()
        await followTemplates(
            events: { AsyncThrowingStream<Void, any Error> { $0.finish(throwing: Dropped()) } },
            fetch: { () -> Int? in nil },
            install: { log.install($0, $1) },
            blind: { log.blind() },
            log: { _ in },
            sleep: { if log.wait($0) == 7 { throw Stop() } }
        )
        XCTAssertEqual(log.waits, [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5),
        ])
    }

    /// A burst of changes read late comes as one.
    func testABurstOfChangesComesAsOne() async throws {
        let stream = changes { continuation in
            for _ in 0..<5 { continuation.yield() }
            continuation.finish()
        }
        var count = 0
        for try await _ in stream { count += 1 }
        XCTAssertEqual(count, 1)
    }

    /// Events split anywhere across reads are counted once each; keepalive
    /// comments are not events.
    func testEventsAreCountedAcrossReads() {
        let stream = ": keepalive\n\ndata: abc\n\n: keepalive\n\ndata: def\r\n\r\n"
        let bytes = Array(stream.utf8)
        for split in 0...bytes.count {
            var counter = ServerSentEventCounter()
            let count = counter.feed(Data(bytes[..<split])) + counter.feed(Data(bytes[split...]))
            XCTAssertEqual(count, 2, "split at \(split)")
        }
    }
}
