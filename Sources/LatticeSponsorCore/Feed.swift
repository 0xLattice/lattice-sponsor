// The sponsor's side of the node's template subscription: how long to wait
// before subscribing again, and the blocks to hand the node once it is heard.
// Neither judges work: whether a block counts is the node's call.

/// How long to wait before subscribing again: 250 ms, doubling to 5 s across
/// connections that fail, and back to 250 ms only once a connection proves
/// itself past its first event (a second push, or a keepalive), so a node
/// that pushes once and ends is not dialled again every 250 ms.
public struct Backoff: Sendable {
    public static let first = Duration.milliseconds(250)
    public static let most = Duration.seconds(5)
    private var wait = first
    private var events = 0

    public init() {}

    /// A new connection is opening.
    public mutating func connecting() { events = 0 }

    /// The connection delivered an event.
    public mutating func event() {
        events += 1
        if events == 2 { wait = Self.first }
    }

    /// The wait before the next connection, doubling the one after.
    public mutating func next() -> Duration {
        defer { wait = min(wait * 2, Self.most) }
        return wait
    }
}

/// Blocks whose submit failed, oldest first: handed to the node again once
/// it is heard. Past `capacity` the oldest is dropped.
public struct UnsentBlocks: Sendable {
    public struct Block: Sendable, Equatable {
        public let workID: String
        public let nonce: UInt64
    }

    public let capacity: Int
    private var blocks: [Block] = []

    public init(capacity: Int = 64) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { blocks.count }

    /// Keep a block; the one dropped to make room, if any.
    @discardableResult
    public mutating func keep(workID: String, nonce: UInt64) -> Block? {
        let block = Block(workID: workID, nonce: nonce)
        guard !blocks.contains(block) else { return nil }
        blocks.append(block)
        return blocks.count > capacity ? blocks.removeFirst() : nil
    }

    /// Every block kept, emptied.
    public mutating func take() -> [Block] {
        defer { blocks.removeAll() }
        return blocks
    }
}
