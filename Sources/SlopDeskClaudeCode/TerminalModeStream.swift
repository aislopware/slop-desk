import Foundation
import Synchronization

/// An `AsyncStream` façade over ``TerminalModeTracker``: feed it output chunks and
/// consume ``TerminalModeEvent``s asynchronously. The synchronous `consume(_:) ->
/// [TerminalModeEvent]` on the tracker is the primitive (and is what the tests assert
/// on); this is the convenience shape the spec calls for ("AsyncStream/event list").
///
/// The tracker is not `Sendable` (it holds mutable parser state), so this façade owns it
/// inside a `Mutex` — which IS `Sendable` whatever it guards, because the only way to reach
/// the value is through `withLock`. That is what lets this be a CHECKED `Sendable` rather
/// than an `@unchecked` one over a lock the compiler has to be told about: `feed`/`finish`
/// are safe from any task, and events surface on the single `events` stream in order.
public final class TerminalModeStream: Sendable {
    private let tracker = Mutex(TerminalModeTracker())
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
    public var mode: TerminalMode { tracker.withLock { $0.mode } }

    /// Feeds an output chunk; any resulting events are yielded on ``events`` in order.
    ///
    /// The yield happens OUTSIDE the lock — a continuation's consumer can resume on this
    /// thread, and the parser must not be held while it runs.
    public func feed(_ output: Data) {
        let produced = tracker.withLock { $0.consume(output) }
        for event in produced { continuation.yield(event) }
    }

    public func feed(_ output: [UInt8]) { feed(Data(output)) }

    /// Finishes the event stream (no more output will be fed).
    public func finish() {
        continuation.finish()
    }
}
