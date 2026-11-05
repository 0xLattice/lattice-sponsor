import Foundation

/// One server-sent event: its `event:` name and its `data:` lines joined.
public struct ServerSentEvent: Sendable, Equatable {
    public var name = "message"
    public var data = Data()

    public init(name: String = "message", data: Data = Data()) {
        self.name = name
        self.data = data
    }
}

/// The `text/event-stream` framing: lines, a blank line ends an event, and a
/// line starting with `:` is a comment (the node's keepalive).
public struct ServerSentEventParser: Sendable {
    private var buffer = Data()
    private var event = ServerSentEvent()
    private var hasData = false
    /// Comment lines read so far: the node's keepalives.
    public private(set) var comments = 0

    public init() {}

    /// The events `bytes` completes, in order.
    public mutating func feed(_ bytes: Data) -> [ServerSentEvent] {
        buffer.append(bytes)
        var events: [ServerSentEvent] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if line.isEmpty {
                if hasData { events.append(event) }
                event = ServerSentEvent()
                hasData = false
                continue
            }
            guard line.first != UInt8(ascii: ":") else {
                comments += 1
                continue
            }
            let text = String(decoding: line, as: UTF8.self)
            let (field, value) = text.firstIndex(of: ":").map { colon in
                let rest = text[text.index(after: colon)...]
                return (String(text[..<colon]), String(rest.hasPrefix(" ") ? rest.dropFirst() : rest))
            } ?? (text, "")
            switch field {
            case "event":
                event.name = value
            case "data":
                if hasData { event.data.append(UInt8(ascii: "\n")) }
                event.data.append(contentsOf: Data(value.utf8))
                hasData = true
            default:
                break
            }
        }
        return events
    }
}
