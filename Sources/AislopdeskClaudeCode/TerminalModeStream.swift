import Foundation

/// An `AsyncStream` façade over ``TerminalModeTracker``: feed it output chunks and
/// consume ``TerminalModeEvent``s asynchronously. The synchronous `consume(_:) ->
/// [TerminalModeEvent]` on the tracker is the primitive (and is what the tests assert
/// on); this is the convenience shape the spec calls for ("AsyncStream/event list").
///
/// The tracker is not `Sendable` (it holds mutable parser state), so this façade owns it
/// behind a serial lock and is itself `@unchecked Sendable`: `feed`/`finish` are safe to
/// call from any task; events surface on the single `events` stream in order.
public final class TerminalModeStream: @unchecked Sendable {
    private let tracker = TerminalModeTracker()
    private let lock = NSLock()
    private let continuation: AsyncStream<TerminalModeEvent>.Continuation

    /// The ordered stream of mode/command events.
    public let events: AsyncStream<TerminalModeEvent>

    public init() {
        var cont: AsyncStream<TerminalModeEvent>.Continuation?
        events = AsyncStream { cont = $0 }
        guard let cont else { preconditionFailure("AsyncStream build closure runs synchronously during init") }
        continuation = cont
    }

    /// The current terminal mode snapshot.
    public var mode: TerminalMode {
        lock.lock()
        defer { lock.unlock() }
        return tracker.mode
    }

    /// Feeds an output chunk; any resulting events are yielded on ``events`` in order.
    public func feed(_ output: Data) {
        lock.lock()
        let produced = tracker.consume(output)
        lock.unlock()
        for event in produced { continuation.yield(event) }
    }

    public func feed(_ output: [UInt8]) { feed(Data(output)) }

    /// Finishes the event stream (no more output will be fed).
    public func finish() {
        continuation.finish()
    }
}
