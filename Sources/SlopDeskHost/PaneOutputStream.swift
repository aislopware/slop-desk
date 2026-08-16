import Foundation
import SlopDeskSupervisor

/// The host **output path**: a subscription to superd's read of the PTY master, handing each chunk
/// **immediately** to a sink — no intermediate ring buffer on this side (`DECISIONS.md`
/// "No-buffer relay"; the only buffer in the system is the transport's `ReplayBuffer`).
///
/// ## What this replaces, and why
/// `PTYReadLoop` was a blocking `read()` loop on the master fd, in this process. It is gone, and
/// what it did now happens in `rust/slopdesk-superd/src/pump.rs`. The move is not a tidy-up; it
/// fixes the last hole in "a running agent survives a hostd restart".
///
/// superd already kept panes alive by holding the master fd, so a restart no longer `SIGHUP`s
/// anything. But **nobody was reading that fd between hostd's exit and the next hostd's `adopt`**,
/// and a PTY's kernel buffer is a few KB. The child's next `write` blocked there. So the agent did
/// not die — the whole point — and instead spent the entire restart frozen at whatever line it had
/// reached. superd's pump drains continuously, whether or not any hostd is attached, and hostd
/// picks the stream back up from a byte offset.
///
/// ## What did NOT move, deliberately
/// Only `read` is superd's. hostd still holds its duplicate of the master and still uses it for
/// `write` (keystrokes), `TIOCSWINSZ` (resizes) and `tcgetpgrp` (the zero-config half of agent
/// detection). Those two were the named reasons the full-relay design was rejected in the first
/// place (`DECISIONS.md` 2026-08-11) — no hop on the input path, no polled IPC for the foreground
/// process group — and both survive intact.
///
/// ## Backpressure / drain-pause gate (the load-bearing contract)
/// The relay asserts a pause when the per-channel output queue crosses the bounded-queue
/// high-water mark (`MuxChannelSession`'s ``PausableQueueGate`` / `BoundedQueuePolicy`). ``setPaused(_:)``
/// forwards that to superd, which stops issuing `read()` on the master. Because nothing drains the
/// master, the kernel PTY buffer fills and **backpressures the shell** — no output is produced that
/// we would have to drop (the never-drop invariant). Same mechanism as before; one process further
/// away.
///
/// The one thing that got stricter: superd's pause also interrupts a reader already parked in
/// `poll`, which `PTYReadLoop` could not do. A pause used to cost one more chunk than it asked for.
///
/// ## EOF, which arrives two ways
/// Usually ``PaneOutputEvent/ended``, from the pane's `exited` notification, and superd guarantees
/// it lands **after** the pane's last byte: its reaper drains the pump to EOF and joins before
/// broadcasting. That ordering is what `MuxChannelSession`'s EOF latch depends on to keep `.exit`
/// behind the final `.chunk` on the wire.
///
/// But a pane can finish before this subscription exists — `spawn` a `ls` and it is reaped while
/// the reply is still travelling — and that `exited` went out to nobody. So the subscribe reply
/// carries ``StreamPosition/ended``, and a stream that arrives already finished ends itself: at
/// once if there is no backlog, otherwise on the last byte of one. ``finish()`` makes the two
/// routes idempotent. superd's side of the same fix is the graveyard in
/// `rust/slopdesk-superd/src/registry.rs`, which is why there are bytes left to read at all.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; the client and pane id are
/// immutable.
public final class PaneOutputStream: @unchecked Sendable {
    /// The chunk size superd reads with, restated here because the number is a joint decision.
    ///
    /// 32 KiB: HALF the (latency-sized) bounded-queue capacity
    /// (`MuxFlowControl.hostQueueCapacityBytes`, 64 KiB), so the gate's worst overshoot is capacity
    /// plus one read (~96 KiB) instead of capacity plus 128 KiB — a 128 KiB read against a 64 KiB
    /// bound would pause on EVERY flood chunk and half-defeat the latency sizing. The value that
    /// actually governs is `pump::READ_CHUNK_BYTES`; changing one without the other re-opens a
    /// problem that was already solved once.
    public static let readChunkSize = 32 * 1024

    private let supervisor: SupervisorClient
    /// `nil` for a pane that was never spawned or adopted — see
    /// ``PTYProcess/makeOutputStream(onChunk:onEOF:)``. Such a stream is EOF from the start.
    private let paneID: String?
    /// Where the FIRST subscribe asks from. A resubscribe uses ``expectedOffset`` instead.
    private let initialOffset: UInt64
    private let onChunk: @Sendable (Data, UInt64, [SniffedEvent], [BlockEvent]) -> Void
    private let onEOF: @Sendable () -> Void

    private let lock = NSLock()
    private var started = false
    private var stopped = false
    /// The offset the next byte is expected at, for gap detection. `nil` until the first chunk.
    private var expectedOffset: UInt64?
    /// The offset the stream is known to end at, when superd said so at subscribe time. `nil` for
    /// the ordinary case of a pane still running — see the EOF discussion in the type documentation.
    private var endsAtOffset: UInt64?
    /// Whether ``onEOF`` has been called. The end can be learned two ways and must be told once.
    private var reportedEOF = false
    /// The gate's latest decision, kept so ``stop()`` can tell whether it is leaving one behind.
    private var paused = false
    /// Whether the subscribe was answered from further along than it asked for.
    private var lossyResume = false
    /// The sniffed events waiting for the chunk they were found in.
    ///
    /// Not under ``lock``, and it does not need to be: superd writes the sniff frame and the output
    /// frame it precedes under one hold of its own wire lock, and both are decoded by the supervisor
    /// client's single read-loop thread, which is the only thread that ever touches this. The lock
    /// here exists for the fields ``stop()`` and ``setPaused(_:)`` reach from other threads; nothing
    /// outside the read loop can see this one.
    private var pendingSniffed: [SniffedEvent] = []
    /// The block changes waiting for the chunk that produced them — same frame ordering, same
    /// thread, same reasoning as ``pendingSniffed``.
    private var pendingBlocks: [BlockEvent] = []

    /// Called with a human-readable line when something worth knowing happens — a lossy resume, a
    /// gap. Wired to hostd's log by the session that builds this.
    public var onLog: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - supervisor: the connected client. A disconnected one makes ``start()`` a no-op that logs.
    ///   - paneID: superd's identity for this pane, as recorded at spawn or recovered at adopt, or
    ///     `nil` for a pane that has neither.
    ///   - fromOffset: where in the pane's life to resume. `0` — the whole ring — for a pane whose
    ///     history hostd does not otherwise have. An ADOPTED pane's history comes off the disk
    ///     journal as well, and the two overlap byte for byte, so that caller passes the offset its
    ///     predecessor stopped ingesting at (or ``PaneOutputStream/fromNowOn`` when it never
    ///     recorded one). See ``HostServer`` for the whole argument.
    ///   - onChunk: called on the supervisor client's read-loop thread with each non-empty chunk,
    ///     the offset in the pane's life the chunk ENDS at, and what superd's two readers — the
    ///     sniffer and the command-block tap — found IN those bytes. The callback must hand the bytes to the transport without retaining a copy past
    ///     its return (no-buffer relay). Bridging into an actor is the caller's job.
    ///
    ///     The OFFSET has no consumer in hostd and is passed for completeness — it is what superd
    ///     sent, and this stream's own gap detection is computed from it. It used to be the number
    ///     hostd wrote to a resume sidecar, back when it journaled a stream it did not number
    ///     (`docs/51` §6.8).
    ///
    ///     The events arrive paired with their own chunk rather than on a channel of their own,
    ///     which is what lets a title latch and the bytes that carried it stay in step — the same
    ///     guarantee hostd had when it ran the sniffer itself, on the same thread, over the same
    ///     chunk. An empty chunk with a non-empty batch is possible and is still delivered: it is
    ///     the backlog a resubscribe replays, whose events belong to bytes this stream already saw.
    ///
    ///     Called SYNCHRONOUSLY on that one thread, shared by every pane, and deliberately so: it
    ///     is what makes the backpressure gate real. Hopping to a per-pane queue would isolate the
    ///     panes from each other and turn the queue itself into the unbounded buffer the gate
    ///     exists to prevent, because the reader would never stop reading.
    ///   - onEOF: called once when the pane's master is finished.
    @preconcurrency
    public init(
        supervisor: SupervisorClient,
        paneID: String?,
        fromOffset: UInt64 = 0,
        onChunk: @escaping @Sendable (Data, UInt64, [SniffedEvent], [BlockEvent]) -> Void,
        onEOF: @escaping @Sendable () -> Void,
    ) {
        self.supervisor = supervisor
        self.paneID = paneID
        initialOffset = fromOffset
        self.onChunk = onChunk
        self.onEOF = onEOF
    }

    /// "Whatever happens from here" — an offset past any ring's head, which superd clamps to the
    /// head and answers with an empty backlog.
    ///
    /// For a pane whose history hostd already holds and cannot align with the ring: replaying the
    /// backlog would double the transcript, and re-feed the sniffer, the block ledger and the
    /// screen engine with it.
    public static let fromNowOn = UInt64.max

    /// Subscribes. Idempotent, and safe to call after ``stop()`` (it does nothing).
    ///
    /// Where it asks FROM is the caller's decision, made at init — offsets belong to a pane LIFE and
    /// live in superd's memory, and the hostd that knew where this pane's stream had got to is
    /// usually the one that just died. See the `fromOffset` parameter.
    public func start() {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        let from = expectedOffset ?? initialOffset
        lock.unlock()
        open(from: from, reopening: false)
    }

    /// Re-opens the subscription after the supervisor connection dropped and came back.
    ///
    /// The pane and its shell are untouched by a control-socket drop — superd holds the master
    /// either way — but the client's handler table went with the connection, so without this the
    /// terminal renders nothing ever again while keystrokes still travel: a window the user types
    /// into that never answers. Resumes at the offset the last chunk left off, so the bytes
    /// produced during the gap arrive rather than being skipped, and a ring that evicted them says
    /// so (``StreamPosition/lossy``).
    ///
    /// A no-op for a stream that never started or has stopped. Returns whether a subscription is
    /// live afterwards — `false` means superd no longer knows this pane, and the caller must end
    /// the session rather than wait for output that is never coming.
    @discardableResult
    public func resubscribe() -> Bool {
        lock.lock()
        let eligible = started && !stopped && !reportedEOF
        let from = expectedOffset ?? initialOffset
        lock.unlock()
        guard eligible, paneID != nil else { return false }
        return open(from: from, reopening: true)
    }

    /// The one subscribe path, shared by ``start()`` and ``resubscribe()``.
    @discardableResult
    private func open(from offset: UInt64, reopening: Bool) -> Bool {
        // No identity means no child was ever spawned, so there is nothing to subscribe to and
        // nothing wrong. EOF at once, quietly — the loud path below is for a pane that DOES exist
        // and whose stream could not be opened, which is a real fault.
        guard let paneID else {
            finish()
            return false
        }

        do {
            let position = try supervisor.subscribe(paneID: paneID, fromOffset: offset) { [weak self] event in
                self?.handle(event)
            }
            // The backlog frames may already have been delivered: superd writes them straight after
            // the reply, and the client's read loop is a different thread from this one. So this
            // must not REWIND `expectedOffset` past a chunk already accounted for (which would log
            // a gap that never happened), and it must notice an end that has already been reached.
            lock.lock()
            let reached = expectedOffset ?? position.start
            expectedOffset = reached
            endsAtOffset = position.ended ? position.head : nil
            let finishedAlready = position.ended && reached >= position.head
            lock.unlock()
            if position.lossy {
                lock.lock()
                lossyResume = true
                lock.unlock()
                // `head &- start`, not `head - start`: both numbers are decoded off the wire, and
                // `head < start` is a shape superd should never send but this process must not DIE
                // of. Swift traps on unsigned overflow, and the trap is in a log line — a version
                // skew, or the poisoned-ring `map_or(0, …)` fallback in `pump.rs` reporting head 0
                // against a non-zero base, would take the whole daemon down and every terminal in
                // every connected client with it. Everything else decoded from superd in this file
                // is validate-then-drop; the arithmetic is too.
                let retained = position.head >= position.start ? position.head - position.start : 0
                onLog?(
                    "pane \(paneID): superd had already evicted the start of the stream — "
                        + "resumed at \(position.start), \(retained) bytes retained",
                )
            }
            // A pane that finished before we got here was announced dead before this subscription
            // existed, so no `exited` notice is coming. With a backlog still to arrive the end is
            // declared once the last byte of it lands (see ``handle(_:)``); with nothing left to
            // wait for — no backlog at all, or one already delivered — now.
            if finishedAlready {
                finish()
            }
            if reopening {
                onLog?("pane \(paneID): output stream re-opened at \(position.start) after a supervisor reconnect")
                // The gate's last decision has to be re-stated: it lives in superd, and this is a
                // different superd (or at least a different connection) from the one that heard it.
                lock.lock()
                let stillPaused = paused
                lock.unlock()
                if stillPaused { supervisor.setPaused(paneID: paneID, paused: true) }
            }
            return true
        } catch {
            // A pane whose output never arrives is visibly broken, so this must be loud. It is not
            // recoverable here either: the alternative used to be reading the fd ourselves, and
            // that implementation is deliberately gone.
            onLog?("pane \(paneID): could not subscribe to superd's output stream — \(error)")
            // On a REOPEN the caller decides: superd may simply have restarted, in which case this
            // pane's shell died with the old one and the session is over — but that is a fact about
            // the pane, checked against superd's own list, not something to infer from one error.
            if !reopening { finish() }
            return false
        }
    }

    /// Whether superd had already evicted the bytes this stream asked for — the ring moved past
    /// them while nobody was subscribed.
    ///
    /// Set during ``start()``, so it is readable the moment that call returns. A caller that
    /// subscribed from `0` specifically to READ something out of the backlog (a panel backend
    /// re-learning its port from its own announce line) has to know that the backlog no longer
    /// reaches the start, because there is nothing in the bytes themselves to say so.
    public var resumedLossily: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lossyResume
    }

    /// Forwards the bounded-queue gate's decision to superd. Cheap and non-throwing by design —
    /// see ``SupervisorClient/setPaused(paneID:paused:)``.
    ///
    /// **Deliberately not gated on ``start()`` having happened.** The gate asserts its first pause
    /// while a restore preamble is being enqueued, which `MuxChannelSession` does BEFORE it starts
    /// the stream — every adopted pane, and any cold reattach with a journal over
    /// `MuxFlowControl.hostQueueCapacityBytes`. Dropping that call (which this did until review
    /// caught it) is worse than a missed pause, because ``PausableQueueGate`` latches the decision
    /// as applied and only re-sends it on a CHANGE: the gate then believes the pane is paused, the
    /// subscription opens wide, and the whole ring backlog arrives with no backpressure asserted.
    ///
    /// superd's pause is a property of the pane's pump, not of a subscription, so it is meaningful
    /// before one exists — and it survives the `subscribe` that follows, because `subscribed()`
    /// only counts. What lifts it is the last unsubscribe, or the gate's own resume.
    public func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        let deliverable = !stopped
        lock.unlock()
        guard deliverable, let paneID else { return }
        supervisor.setPaused(paneID: paneID, paused: value)
    }

    /// Unsubscribes permanently. Idempotent, and safe to call before ``start()``.
    ///
    /// It does NOT need the child to die first, and it does not stop superd reading the pane. That
    /// distinction is the one this whole change turns on: a hostd relinquishing a pane wants its
    /// reader back without signalling anything, and the pane must keep being drained after it goes.
    public func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let wasStarted = started
        let leftPaused = paused
        lock.unlock()
        guard !wasStopped, let paneID else { return }
        if wasStarted {
            // superd lifts any pause when the last subscriber leaves, so this covers both jobs.
            supervisor.unsubscribe(paneID: paneID)
        } else if leftPaused {
            // A pause applied before a subscription that never came. Nobody else will lift it —
            // the un-pause rides the last unsubscribe, and there was never a subscribe — and a
            // paused pane with no reader is the frozen agent superd exists to prevent.
            supervisor.setPaused(paneID: paneID, paused: false)
        }
    }

    // MARK: Events

    private func handle(_ event: PaneOutputEvent) {
        switch event {
        case let .bytes(offset, payload):
            lock.lock()
            let expected = expectedOffset
            let next = offset &+ UInt64(payload.count)
            let dropped = stopped
            let lastOfABacklog = endsAtOffset.map { next >= $0 } ?? false
            // The boundary moves inside the SAME lock hold that read the end against it, so this
            // handler and `open()` cannot both conclude the other one will declare the stream over.
            // Advancing it further down — after the chunk was handed on — left a window exactly one
            // instruction wide where a backlog frame was delivered before `open()` recorded the end:
            // the handler saw no `endsAtOffset` yet, `open()` then read the not-yet-advanced offset
            // and judged the backlog unfinished, and NEITHER called `finish()`. A pane that ran to
            // completion before anyone subscribed hung there waiting for an end that had already
            // happened. (The old ordering was written to guard a cross-thread read by `relinquish()`,
            // which no longer exists; a chunk dropped after `stop()` still never counts as seen,
            // because that is what the `dropped` guard below is.)
            if !dropped { expectedOffset = next }
            lock.unlock()
            // A late frame for a pane we already let go of is ordinary — `unsubscribe` drops the
            // local handler before its verb reaches superd — and must not reach a torn-down session.
            guard !dropped else { return }
            if let expected, offset != expected {
                // Not recoverable, only reportable: the bytes are gone from superd's ring. Passing
                // the chunk on anyway is still the best available answer — a terminal missing a
                // region redraws on the next full frame, whereas dropping the rest of the stream
                // never recovers at all.
                onLog?(
                    "pane \(paneID ?? "-"): output gap — expected offset \(expected), got \(offset) "
                        + "(\(offset > expected ? offset - expected : 0) bytes lost)",
                )
            }
            // The events found IN this chunk, handed on WITH it. Taken unconditionally, so a batch
            // can never outlive the chunk it describes and attach itself to the next one.
            let sniffed = pendingSniffed
            let blocks = pendingBlocks
            pendingSniffed = []
            pendingBlocks = []
            if !payload.isEmpty || !sniffed.isEmpty || !blocks.isEmpty {
                onChunk(payload, next, sniffed, blocks)
            }
            // The end goes out AFTER the bytes it follows, on this same thread, so the EOF latch in
            // `MuxChannelSession` still sees `.exit` behind the final `.chunk`.
            if lastOfABacklog {
                finish()
            }
        case let .sniffed(events):
            // Held, not delivered: superd sends these immediately BEFORE the chunk they were found
            // in, and the pairing is what the caller needs. See `pendingSniffed` on the threading.
            pendingSniffed.append(contentsOf: events)
        case let .blocks(events):
            // Held for the same reason, and released by the same line: the chunk that closed a
            // command and the metadata saying it closed must reach the session together.
            pendingBlocks.append(contentsOf: events)
        case .ended:
            finish()
        }
    }

    /// Declares the stream over, at most once.
    ///
    /// Two things can declare it — the pane's `exited` notice, and a subscribe that already knew
    /// where the stream stopped — and for a pane that dies at just the wrong moment both can fire.
    /// Downstream, `onEOF` closes a session; calling it twice is a use-after-teardown.
    private func finish() {
        lock.lock()
        let already = reportedEOF
        reportedEOF = true
        lock.unlock()
        guard !already else { return }
        onEOF()
    }
}
