// The sponsor follows its node by event, never by clock: the node says
// something changed (`GET /mining/events`), and the sponsor asks for a
// template then. Proof-of-work arrivals are memoryless, so a quiet chain
// means nothing changed, however long it is quiet.

/// For each change the node reports, fetch a template and install it, one
/// at a time: the node keeps only the newest event per client, so a burst
/// comes as one. When the events end or fail, connect again after a wait of
/// 250 ms, doubling to 5 s, back to 250 ms once a template is installed.
/// Returns when `sleep` throws (cancellation).
public func followTemplates<Template: Sendable>(
    events: @Sendable () async throws -> AsyncThrowingStream<String, any Error>,
    fetch: @Sendable () async throws -> Template?,
    install: @Sendable (Template) async -> Void,
    log: @Sendable (String) -> Void = { print($0) },
    sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
) async {
    let first = Duration.milliseconds(250)
    var wait = first
    while true {
        do {
            for try await _ in try await events() {
                do {
                    guard let template = try await fetch() else { continue }
                    await install(template)
                    wait = first
                } catch {
                    log("template fetch failed: \(error)")
                }
            }
            log("the node's events ended")
        } catch {
            log("the node's events failed: \(error)")
        }
        do { try await sleep(wait) } catch { return }
        wait = min(wait * 2, .seconds(5))
    }
}
