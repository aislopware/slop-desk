import Foundation

/// A multicast ("tee") for ``AislopdeskClient/Event``: fans ONE upstream event source out to
/// N independent `AsyncStream<Element>` subscribers, each of which sees **every** event.
///
/// ### Why this exists (the bug it fixes)
/// `AsyncStream` is single-consumer / fan-IN: if two `for await` loops iterate the *same*
/// stream, each yielded element is delivered to exactly ONE of them, nondeterministically.
/// `AislopdeskClient` has multiple legitimate event consumers at once — `ReconnectManager`
/// (watches `.disconnected` to drive reconnect, WF-4) and the WF-8 view-models (chrome +
/// terminal status). Sharing a single `AsyncStream` between them means a `.disconnected` /
/// `.reconnected` / `.title` is stolen by whichever loop happens to win the race, so the
/// reconnect supervisor can miss the drop and the chrome/terminal statuses diverge.
///
/// This broadcaster makes every ``subscribe()`` return a fresh child stream; a single
/// ``yield(_:)`` is delivered to **all** live children. ``finish()`` terminates them all.
///
/// ### Semantics
/// - **Live, not replay:** a subscriber created after some events were yielded sees only
///   events from that point on (matching the previous single-`AsyncStream` behaviour for a
///   late subscriber). Subscribe before driving the events you want to observe.
/// - **Unbounded buffering per child** (same policy as the old single stream), so a slow
///   consumer never drops events.
/// - **Sendable:** all mutable state is guarded by an `NSLock`; safe to `yield`/`subscribe`
///   from any isolation domain (the actor yields; `nonisolated` accessors subscribe).
final class EventBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [Int: AsyncStream<Element>.Continuation] = [:]
    private var nextID = 0
    private var finished = false

    init() {}

    /// Returns a new child stream that will receive every future ``yield(_:)`` until
    /// ``finish()``. If the broadcaster has already finished, the returned stream is
    /// immediately finished (empty).
    func subscribe() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.finish()
                return
            }
            let id = nextID
            nextID += 1
            children[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.children[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// Delivers `element` to every live child subscriber.
    func yield(_ element: Element) {
        lock.lock()
        let conts = Array(children.values)
        lock.unlock()
        for cont in conts { cont.yield(element) }
    }

    /// Finishes every live child and rejects further subscriptions (they get an empty
    /// finished stream). Idempotent.
    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let conts = Array(children.values)
        children.removeAll()
        lock.unlock()
        for cont in conts { cont.finish() }
    }
}
