import Foundation

/// Counts the events in a `text/event-stream`: a blank line ends an event
/// that carried a `data:` line, and a line starting with `:` is a comment
/// (the node's keepalive). What an event says is not read: any event means
/// "something changed".
public struct ServerSentEventCounter: Sendable {
    private var buffer = Data()
    private var hasData = false

    public init() {}

    /// How many events `bytes` completes.
    public mutating func feed(_ bytes: Data) -> Int {
        buffer.append(bytes)
        var events = 0
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if line.isEmpty {
                if hasData { events += 1 }
                hasData = false
            } else if line.starts(with: Data("data".utf8)) {
                hasData = true
            }
        }
        return events
    }
}
