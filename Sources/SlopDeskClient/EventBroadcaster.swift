import Foundation
import Synchronization

/// A multicast ("tee") for ``SlopDeskClient/Event``: fans ONE upstream event source out to
/// N independent `AsyncStream<Element>` subscribers, each of which sees **every** event.
///
/// ### Why this exists (the bug it fixes)
/// `AsyncStream` is single-consumer / fan-IN: if two `for await` loops iterate the *same*
/// stream, each yielded element is delivered to exactly ONE of them, nondeterministically.
/// `SlopDeskClient` has multiple legitimate event consumers at once — `ReconnectManager`
/// (watches `.disconnected` to drive reconnect) and the view-models (chrome +
/// terminal status). Sharing a single `AsyncStream` between them means a `.disconnected` /
/// `.reconnected` / `.title` is stolen by whichever loop happens to win the race, so the
/// reconnect supervisor can miss the drop and the chrome/terminal statuses diverge.
///
/// This broadcaster makes every ``subscribe()`` return a fresh child stream; a single
/// ``yield(_:)`` is delivered to **all** live children. ``finish()`` terminates them all.
///
/// ### Semantics
/// - **Live, not replay:** a subscriber created after some events were yielded sees only
///   events from that point on — there is no backlog to catch up on. Subscribe before driving
///   the events you want to observe.
/// - **Unbounded buffering per child**, so a slow consumer never drops events.
/// - **Sendable:** every mutable field lives inside the one `Mutex`, so the conformance is
///   CHECKED rather than asserted — safe to `yield`/`subscribe` from any isolation domain
///   (the actor yields; `nonisolated` accessors subscribe). The three fields travel together
///   because they are one fact: which children are live, and whether the roster is closed.
final class EventBroadcaster<Element: Sendable>: Sendable {
    private struct Roster {
        var children: [Int: AsyncStream<Element>.Continuation] = [:]
        var nextID = 0
        var finished = false
    }

    private let roster = Mutex(Roster())

    init() {}

    /// Returns a new child stream that will receive every future ``yield(_:)`` until
    /// ``finish()``. If the broadcaster has already finished, the returned stream is
    /// immediately finished (empty).
    func subscribe() -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id: Int? = roster.withLock { roster in
                guard !roster.finished else { return nil }
                defer { roster.nextID += 1 }
                roster.children[roster.nextID] = continuation
                return roster.nextID
            }
            guard let id else {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                roster.withLock { $0.children[id] = nil }
            }
        }
    }

    /// Delivers `element` to every live child subscriber.
    ///
    /// The children are COPIED out and yielded to outside the lock: a child's consumer can
    /// resume synchronously on this thread and call straight back into ``subscribe()``.
    func yield(_ element: Element) {
        let conts = roster.withLock { Array($0.children.values) }
        for cont in conts { cont.yield(element) }
    }

    /// Finishes every live child and rejects further subscriptions (they get an empty
    /// finished stream). Idempotent.
    func finish() {
        let conts: [AsyncStream<Element>.Continuation] = roster.withLock { roster in
            guard !roster.finished else { return [] }
            roster.finished = true
            defer { roster.children.removeAll() }
            return Array(roster.children.values)
        }
        for cont in conts { cont.finish() }
    }
}
