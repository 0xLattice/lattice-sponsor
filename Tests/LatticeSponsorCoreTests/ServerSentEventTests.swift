import Foundation
import XCTest
@testable import LatticeSponsorCore

final class ServerSentEventTests: XCTestCase {
    /// Events split anywhere across reads come out whole, keepalive comments
    /// and all, in order.
    func testEventsAcrossReadsWithKeepalives() {
        let stream = ": keepalive\n\nevent: template\ndata: {\"a\":1}\n\n: keepalive\n\nevent: end\r\ndata: busy\r\n\r\n"
        let bytes = Array(stream.utf8)
        for split in 0...bytes.count {
            var parser = ServerSentEventParser()
            let events = parser.feed(Data(bytes[..<split])) + parser.feed(Data(bytes[split...]))
            XCTAssertEqual(events, [
                ServerSentEvent(name: "template", data: Data("{\"a\":1}".utf8)),
                ServerSentEvent(name: "end", data: Data("busy".utf8)),
            ], "split at \(split)")
        }
    }

    func testKeepalivesAreCounted() {
        var parser = ServerSentEventParser()
        XCTAssertEqual(parser.feed(Data(": keepalive\n\n: kee".utf8)), [])
        XCTAssertEqual(parser.comments, 1)
        _ = parser.feed(Data("palive\n\n".utf8))
        XCTAssertEqual(parser.comments, 2)
    }

    func testDataLinesJoinWithNewlines() {
        var parser = ServerSentEventParser()
        XCTAssertEqual(parser.feed(Data("data: a\ndata:b\n\n".utf8)), [ServerSentEvent(data: Data("a\nb".utf8))])
    }
}
