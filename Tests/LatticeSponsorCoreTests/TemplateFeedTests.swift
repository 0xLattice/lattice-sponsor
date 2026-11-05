import Foundation
import XCTest
@testable import LatticeSponsorCore

/// A record the feed's closures write to.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _connections = 0
    private var _fetches = 0
    private var _installed: [Int] = []
    private var _waits: [Duration] = []

    func connect() -> Int { lock.withLock { _connections += 1; return _connections } }
    func fetch() -> Int { lock.withLock { _fetches += 1; return _fetches } }
    func install(_ template: Int) { lock.withLock { _installed.append(template) } }
    func wait(_ duration: Duration) -> Int { lock.withLock { _waits.append(duration); return _waits.count } }
    var installed: [Int] { lock.withLock { _installed } }
    var waits: [Duration] { lock.withLock { _waits } }
}

private struct Dropped: Error {}
private struct Stop: Error {}

final class TemplateFeedTests: XCTestCase {
    /// Each event fetches a template and installs it; a dropped connection
    /// is dialled again, and its event fetches again.
    func testEachEventFetchesAndInstallsAndADropReconnects() async {
        let log = Log()
        await followTemplates(
            events: {
                let connection = log.connect()
                return AsyncThrowingStream { continuation in
                    continuation.yield("d\(connection)a")
                    if connection == 1 { continuation.yield("d1b") }
                    continuation.finish(throwing: Dropped())
                }
            },
            fetch: { log.fetch() },
            install: { log.install($0) },
            log: { _ in },
            sleep: { if log.wait($0) == 2 { throw Stop() } }
        )
        XCTAssertEqual(log.installed, [1, 2, 3], "two events, a drop, then one more")
        XCTAssertEqual(log.waits, [.milliseconds(250), .milliseconds(250)], "an install resets the wait")
    }

    /// With nothing installed, the waits between connections double to 5 s.
    func testWaitsDoubleWhileNothingIsInstalled() async {
        let log = Log()
        await followTemplates(
            events: { AsyncThrowingStream<String, any Error> { $0.finish(throwing: Dropped()) } },
            fetch: { () -> Int? in nil },
            install: { log.install($0) },
            log: { _ in },
            sleep: { if log.wait($0) == 7 { throw Stop() } }
        )
        XCTAssertEqual(log.waits, [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5),
        ])
        XCTAssertEqual(log.installed, [])
    }

    func testEventsSplitAcrossReadsComeOutWhole() {
        let stream = ": keepalive\n\ndata: abc\n\n: keepalive\n\ndata: def\r\n\r\n"
        let bytes = Array(stream.utf8)
        for split in 0...bytes.count {
            var parser = ServerSentEventParser()
            let events = parser.feed(Data(bytes[..<split])) + parser.feed(Data(bytes[split...]))
            XCTAssertEqual(events.map { String(decoding: $0.data, as: UTF8.self) }, ["abc", "def"], "split at \(split)")
        }
    }
}
