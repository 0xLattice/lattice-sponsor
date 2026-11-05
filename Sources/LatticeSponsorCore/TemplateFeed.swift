// The sponsor follows its node by event, never by clock: the node says
// something changed (`GET /mining/events`), and the sponsor asks for a
// template then. Proof-of-work arrivals are memoryless, so a quiet chain
// means nothing changed, however long it is quiet.

/// For each change the node reports, fetch a template and install it, one
/// at a time: the node keeps only the newest event per client, so a burst
/// comes as one. The first template on each connection is `fresh`: the node
/// may have restarted on the same tip and lost the work it handed out.
///
/// When the events end or fail, or a fetch brings no template (the change
/// may have been a new tip, and no later event need come), `blind` is told
/// and the feed connects again after a wait of 250 ms, doubling to 5 s, back
/// to 250 ms once a template is installed: a new connection's first event
/// fetches again. Returns when `sleep` throws (cancellation).
public func followTemplates<Template: Sendable>(
    events: @Sendable () async throws -> AsyncThrowingStream<Void, any Error>,
    fetch: @Sendable () async throws -> Template?,
    install: @Sendable (Template, _ fresh: Bool) async -> Void,
    blind: @Sendable () async -> Void,
    log: @Sendable (String) -> Void = { print($0) },
    sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) async {
    let first = Duration.milliseconds(250)
    var wait = first
    while true {
        var fresh = true
        do {
            for try await _ in try await events() {
                guard let template = try await fetch() else { throw FeedError.noTemplate }
                await install(template, fresh)
                fresh = false
                wait = first
            }
            log("the node's events ended")
        } catch {
            log("template feed: \(error)")
        }
        await blind()
        do { try await sleep(wait) } catch { return }
        wait = min(wait * 2, .seconds(5))
    }
}

enum FeedError: Error {
    /// The node had no template to give (busy, or not ready).
    case noTemplate
}

/// A stream of "something changed" that keeps only the newest unread one: a
/// backlog would hold a new tip behind changes it supersedes.
public func changes(
    _ build: (AsyncThrowingStream<Void, any Error>.Continuation) -> Void
) -> AsyncThrowingStream<Void, any Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1), build)
}
