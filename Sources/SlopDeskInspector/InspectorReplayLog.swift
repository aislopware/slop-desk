import Foundation

/// Host-side replay buffer + live fan-out for the inspector event stream.
///
/// The ``InspectorEngine`` produces ONE `AsyncStream<InspectorEvent>` (a stream can be
/// iterated exactly once). A second inspector connection — or a reconnect — needs the
/// *full* history from the beginning, then the live tail. ``InspectorReplayLog`` is the
/// seam that makes that possible: it consumes the engine's single stream exactly once
/// (via ``ingest(_:)``), appends every event into an ordered `history`, and lets any
/// number of subscribers ask for `subscribe(fromSeq:)` — a full (or resumed) replay
/// followed by the live tail.
///
/// ## Sequence numbering
/// `history` is append-only, so the array index *is* the sequence number: `history[i]`
/// is event `seq == i`. This matches the `InspectorWire` `Int64 fromSeq` semantics —
/// the client subscribes `fromSeq: 0` for a full replay, or `fromSeq: N` to resume after
/// a reconnect (skipping the `0..<N` prefix it already rendered). The decoded `fromSeq`
/// must actually be used to slice the replay — ignoring it would hand a reconnecting
/// client a blank inspector after any drop.
///
/// ## Snapshot-then-attach atomicity
/// ``subscribe(fromSeq:)`` snapshots `history[fromSeq...]` AND attaches a live
/// continuation in ONE atomic actor step (a single non-suspending method body). Because
/// the actor cannot interleave another `ingest` between the snapshot and the attach, no
/// event can slip through the gap: an event appended *before* the call is in the
/// snapshot; one appended *after* lands on the freshly-attached continuation. The
/// returned stream replays the snapshot in order, then forwards live events.
///
/// Per-subscriber continuations live in `[UUID: Continuation]` and are removed on
/// stream termination (cancel / client gone).
///
/// Read-only by construction: the only input is the engine's observation stream; there
/// is no path back to the agent.
public actor InspectorReplayLog {
    /// Retained event window. `history[i]` is `seq == baseSeq + i` (see ``baseSeq``).
    private var history: [InspectorEvent] = []

    /// The absolute seq of `history[0]`. Bumped when the oldest events are dropped to keep `history`
    /// bounded, so a subscriber's `fromSeq` still maps to a stable absolute sequence number. Starts at 0
    /// (no events dropped yet → `history[i]` is seq `i`).
    private var baseSeq: Int = 0

    /// Hard cap on retained events: once `history` exceeds this, the oldest are dropped down to
    /// ``retainTarget`` in ONE batch (amortized O(1) per append vs O(n) `removeFirst` each time). Without
    /// this the host's inspector log grew without bound for the host's lifetime (slow OOM, amplified by
    /// every long session / reconnect). 50k events is generous for a diagnostic inspector session.
    private let maxRetained: Int
    private let retainTarget: Int

    /// Live-tail headroom for one subscriber's stream buffer beyond its replay snapshot:
    /// a healthy consumer stays far below it; a stalled one drops its OLDEST buffered
    /// events once this many queue up unconsumed (it resubscribes `fromSeq:` on the gap).
    static let liveSubscriberBufferSlack = 1024

    /// Live subscribers, keyed by a per-subscription id so termination can detach the
    /// right one.
    private var subscribers: [UUID: AsyncStream<InspectorEvent>.Continuation] = [:]

    /// `true` once the upstream engine stream finished (host shutdown). A subscription
    /// created after this still gets the full replay, then finishes immediately (no live
    /// tail will ever arrive).
    private var finished = false

    /// Production: 50k retained, dropping to 37.5k on overflow (generous for a diagnostic session).
    public init() {
        maxRetained = 50000
        retainTarget = 37500
    }

    /// Test-only seam: a tiny retention window so the retention-drop / truncation-marker path is
    /// deterministically exercisable without appending 50k events. `internal` (kept out of the public
    /// API); the public `init()` above stays as-is so existing callers and their compiled symbols are
    /// untouched.
    init(maxRetained: Int, retainTarget: Int) {
        precondition(retainTarget < maxRetained, "retainTarget must be below maxRetained")
        self.maxRetained = maxRetained
        self.retainTarget = retainTarget
    }

    /// Consumes the engine's single ordered event stream exactly once: appends each
    /// event to `history` and fans it out to every live subscriber. Call this ONCE with
    /// `engine.events` (the engine vends a single-shot `AsyncStream`).
    ///
    /// `nonisolated`: the consume loop runs off the actor so each `await self.append(_:)`
    /// is a genuine actor hop (the append + fan-out stays serialised on the actor).
    public nonisolated func ingest(_ stream: AsyncStream<InspectorEvent>) {
        Task { [weak self] in
            for await event in stream {
                await self?.append(event)
            }
            await self?.markFinished()
        }
    }

    /// Appends one event to the history and pushes it to every live subscriber. One
    /// atomic actor step, so a concurrent ``subscribe(fromSeq:)`` either sees this event
    /// in its snapshot (if it ran first) or receives it live (if it ran after) — never
    /// both, never neither.
    public func append(_ event: InspectorEvent) {
        history.append(event)
        // Bound the retained window. Drop the oldest in ONE batch when over the cap (amortized O(1));
        // `baseSeq` advances so absolute seq numbers stay stable for resuming subscribers.
        if history.count > maxRetained {
            let drop = history.count - retainTarget
            history.removeFirst(drop)
            baseSeq += drop
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// Marks the upstream stream finished and closes every live subscriber. Idempotent.
    public func markFinished() {
        guard !finished else { return }
        finished = true
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    /// The total number of events recorded so far — `baseSeq + history.count`, i.e. the next seq to be
    /// assigned (NOT the retained-window size). Stable across retention drops, so a client may resume
    /// from it to get only the live tail.
    public var historyCount: Int { baseSeq + history.count }

    /// Subscribes from `fromSeq`: replays `history[fromSeq...]` in order, then streams
    /// live events. `fromSeq == 0` = full replay then live; a higher value resumes after a
    /// reconnect, skipping the already-rendered prefix.
    ///
    /// The snapshot + the live-continuation attach happen in this single, non-suspending
    /// actor step, so no event slips between them (see the type doc). A `fromSeq` past the
    /// end of `history` (a future resume point) yields an empty replay then the live tail.
    public func subscribe(fromSeq: Int64) -> AsyncStream<InspectorEvent> {
        // Map the ABSOLUTE `fromSeq` to an index into the retained window: `history[i]` is seq
        // `baseSeq + i`, so the index is `fromSeq - baseSeq`. A `fromSeq` below `baseSeq` (the client
        // wants events already dropped to stay bounded) clamps to index 0 — the oldest retained event;
        // the dropped prefix is unrecoverable, the bounded-retention tradeoff. A `fromSeq` past the end
        // ("I already have everything") clamps to `history.count` → empty replay.
        //
        // The subtraction must be OVERFLOW-SAFE: `fromSeq` is peer-controlled and unauthenticated, so
        // once `baseSeq > 0` a crafted `fromSeq == Int64.min` would underflow `Int(fromSeq) - baseSeq`
        // and TRAP the whole host daemon (a single-frame remote DoS). Saturate on underflow to
        // `Int.min`, which then clamps to index 0 ("give me everything retained") — the correct, safe
        // meaning of a below-base fromSeq.
        let rel = Int(fromSeq).subtractingReportingOverflow(baseSeq)
        let relIndex = rel.overflow ? Int.min : rel.partialValue
        let lowerBound = max(0, min(relIndex, history.count))
        var snapshot = Array(history[lowerBound...])

        // If the requested prefix was BELOW the retained window (relIndex < 0, i.e. `fromSeq < baseSeq`
        // — those events were dropped to keep `history` bounded), the snapshot silently starts
        // mid-transcript. Prepend a truncation marker so the client renders "N earlier steps dropped"
        // rather than believing it received a complete full replay. `droppedCount` is the number of
        // absolute seqs missing ahead of the oldest retained event.
        if relIndex < 0 {
            let droppedCount = baseSeq - max(0, Int(clamping: fromSeq))
            if droppedCount > 0 {
                snapshot.insert(.historyTruncated(droppedCount: droppedCount), at: 0)
            }
        }

        // If the upstream already finished, there will be no live tail: deliver the
        // snapshot and finish.
        if finished {
            return AsyncStream { continuation in
                for event in snapshot {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        let id = UUID()
        // Build the stream and attach the continuation in the SAME atomic actor step as
        // the snapshot above — between `snapshot` being read and `subscribers[id]` being
        // set, the actor does not suspend, so no `append` can interleave.
        //
        // BOUNDED per-subscriber buffer. The shared `history` is capped, but the default
        // AsyncStream policy is `.unbounded`, so a stalled subscriber (backgrounded iOS
        // peer, dead TCP whose FIN never arrived) made every `append`'s `yield` queue in
        // that subscriber's buffer forever — a slow host OOM per dead connection. Events
        // are seq-ordered and clients resubscribe `fromSeq:` on a detected gap (the
        // `frameTooLarge` desync path is precedent), so dropping is safe: keep the NEWEST.
        // The bound is `snapshot.count + slack` so the replay snapshot itself (yielded
        // synchronously below, before the consumer has pulled anything) is NEVER dropped —
        // only a subscriber that stops consuming can lose (old) live-tail events.
        let bufferBound = snapshot.count + Self.liveSubscriberBufferSlack
        return AsyncStream<InspectorEvent>(bufferingPolicy: .bufferingNewest(bufferBound)) { continuation in
            for event in snapshot {
                continuation.yield(event)
            }
            // Detach on termination (cancel / client gone). Hops back onto the actor.
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
            subscribers[id] = continuation
        }
    }

    /// Detaches a subscriber (its stream terminated). No-op if already gone.
    public func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// The number of currently-attached live subscribers (diagnostics / tests).
    public var subscriberCount: Int { subscribers.count }

    /// The number of events currently RETAINED in the bounded window (≤ the retention cap) — distinct
    /// from ``historyCount`` (the absolute total ever appended). Diagnostics / tests.
    public var retainedEventCount: Int { history.count }
}
