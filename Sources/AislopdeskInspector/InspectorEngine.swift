import Foundation

/// Combines the host-side sources — main transcript tail, subagent dir-watch, and
/// hook ingest — into one ordered `AsyncStream<InspectorEvent>`.
///
/// This is the host's event producer: it owns one ``EventBuilder`` (the cross-line
/// pairing/dedup state) and serialises every source through it on a single actor, so
/// the emitted order is well-defined (a source can never race the builder's mutable
/// state). The result is what the host's ``InspectorSource`` serialises onto
/// NWConnection #2.
///
/// Read-only by construction: the only inputs are observations (file bytes + hook
/// payloads); there is no path back to the agent.
public actor InspectorEngine {
    private var builder = EventBuilder()
    private let continuation: AsyncStream<InspectorEvent>.Continuation
    private let stream: AsyncStream<InspectorEvent>

    public init() {
        var cont: AsyncStream<InspectorEvent>.Continuation?
        stream = AsyncStream { cont = $0 }
        guard let cont else { preconditionFailure("AsyncStream build closure runs synchronously during init") }
        continuation = cont
    }

    /// The combined, ordered event stream the host serialises to the client.
    public nonisolated var events: AsyncStream<InspectorEvent> { stream }

    /// Folds one main-session line and emits its events in order.
    public func handle(line: TranscriptLine) {
        for event in builder.ingest(line: line) {
            continuation.yield(event)
        }
    }

    /// Folds one subagent line (from a `subagents/agent-<hash>.jsonl` file).
    public func handle(subagentLine line: TranscriptLine, agentID: String) {
        // Ensure the node exists (a line can arrive before the SubagentStop hook).
        for event in builder.updateSubagent(SubagentNode(id: agentID, status: .running)) {
            continuation.yield(event)
        }
        for event in builder.ingestSubagent(line: line, agentID: agentID) {
            continuation.yield(event)
        }
    }

    /// Folds one hook payload.
    public func handle(hook: HookPayload) {
        for event in builder.ingest(hook: hook) {
            continuation.yield(event)
        }
    }

    /// Drives the engine from the given tailer + watcher until the streams finish.
    /// Hook payloads are folded in concurrently via ``handle(hook:)``.
    ///
    /// `nonisolated`: the two driver tasks run off the actor so each `await
    /// self.handle(...)` is a genuine actor hop. Because `EventBuilder` mutation is
    /// confined to the actor, the tailer and subagent feeds are still serialised
    /// through it (no concurrent fold) and the emitted order is deterministic.
    public nonisolated func run(tailer: TranscriptTailer, subagents: SubagentWatcher?) {
        Task {
            for await line in tailer.lines() {
                await self.handle(line: line)
            }
        }
        if let subagents {
            Task {
                for await item in subagents.lines() {
                    await self.handle(subagentLine: item.line, agentID: item.agentID)
                }
            }
        }
    }

    /// Finishes the event stream (host shutdown).
    public func finish() {
        continuation.finish()
    }
}
