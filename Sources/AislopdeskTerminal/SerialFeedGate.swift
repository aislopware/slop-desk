import Foundation

/// The off-main feed mechanism behind `GhosttySurface.feed`/`feedBatch` (docs/31
/// follow-up #5), extracted into the headless package so the ordering / teardown /
/// backpressure logic is testable without linking libghostty (the GUI binding file is
/// outside the `swift test` build graph).
///
/// ## What it provides
/// 1. **Per-surface serialization** — one serial `DispatchQueue` runs every enqueued
///    feed block in FIFO order. libghostty's `ghostty_surface_write_output` is NOT safe
///    to call concurrently on one surface but is explicitly fine from a single non-main
///    I/O thread (the fork's own documented embedder topology); the queue IS that
///    thread, moving the VT parse off the main actor.
/// 2. **Teardown** — two flavors:
///    - ``close(onDrained:)`` (the PRODUCTION path): marks the gate closed, resumes all
///      parked waiters immediately, and runs `onDrained` on the queue strictly after
///      every previously-enqueued block has completed. NON-BLOCKING by design: a feed
///      block can transitively wait on the MAIN thread (libghostty's `write_output` can
///      park on its 64-slot app mailbox, whose only consumer is `ghostty_app_tick` on
///      main — review finding), so a `queue.sync` from main here could deadlock the app
///      forever. The caller defers the resource free into `onDrained` instead.
///    - ``closeBarrier()`` (SYNCHRONOUS): same guarantees, but blocks the caller until
///      the drain. Safe ONLY when the caller can tolerate waiting on a possibly
///      main-dependent block — kept for the deinit safety net (which cannot defer; see
///      `GhosttySurface.deinit`) and tests.
/// 3. **Backpressure** — without it, credit-at-consumption (the mux grants window
///    credit when the client TAKES a batch) would decouple wire flow control from
///    actual parse progress: under a flood the queue becomes an unbounded buffer and
///    Ctrl-C freshness regresses (the prompt's bytes queue behind megabytes of un-parsed
///    flood — exactly the latency the 256 KiB ingest budget was added to kill).
///    ``waitUntilBelowHighWater()`` lets the ingest pump await before each pass; the
///    producer stops taking batches → no credit issued → the wire window holds the flood
///    at the host. High/low water gives hysteresis.
///
/// ## The no-deadlock rule (encoded here, enforced by review + tests)
/// ``closeBarrier()`` runs `queue.sync` from the MAIN actor. Therefore an enqueued work
/// closure must NEVER block on the main thread — no `DispatchQueue.main.sync`, no
/// semaphore signaled from main, no synchronous actor hop. `GhosttySurface`'s block only
/// `DispatchQueue.main.async`s its present-arming signal, which is safe (the async block
/// simply lands after the barrier).
///
/// `@unchecked Sendable`: all mutable state is guarded by ``lock``; the queue itself is
/// thread-safe. Waiter continuations are resumed OUTSIDE the lock.
public final class SerialFeedGate: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()

    /// Bytes accepted by ``enqueue(byteCount:_:)`` whose work has not finished yet.
    private var pendingBytes = 0
    /// Set (under ``lock``) by ``closeBarrier()``; once true, no new work is accepted.
    private var closed = false
    /// Set (under ``lock``) INSIDE the barrier's `queue.sync` block — the serial-FIFO
    /// point past which the owner's resources may be freed. A work block enqueued
    /// before the close runs BEFORE this flips (FIFO) and completes normally; a
    /// straggler that lost the enqueue/close race and landed AFTER the sync block sees
    /// it and skips its work (the resources are gone).
    private var drained = false
    /// Producers parked in ``waitUntilBelowHighWater()``.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private let highWaterBytes: Int
    private let lowWaterBytes: Int

    /// - Parameters:
    ///   - label: the dispatch-queue label (one gate per surface).
    ///   - highWaterBytes: ``waitUntilBelowHighWater()`` parks while the un-finished
    ///     backlog is at or above this. Default 512 KiB = 2× the ingest pass budget —
    ///     a few ms of parse, so the wait bounds memory without adding felt latency.
    ///   - lowWaterBytes: parked waiters resume once the backlog drains to or below
    ///     this (hysteresis so the producer doesn't thrash at the boundary).
    public init(
        label: String,
        highWaterBytes: Int = 512 * 1024,
        lowWaterBytes: Int = 256 * 1024,
    ) {
        precondition(highWaterBytes > 0)
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.highWaterBytes = highWaterBytes
        self.lowWaterBytes = max(0, min(lowWaterBytes, highWaterBytes - 1))
    }

    /// The current un-finished backlog in bytes (tests/telemetry).
    public var pendingFeedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingBytes
    }

    /// Whether ``closeBarrier()`` has run (tests/telemetry).
    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Enqueues one feed block. `byteCount` is the payload size used for backpressure
    /// accounting; `work` runs on the serial queue, strictly after every previously
    /// enqueued block. After ``closeBarrier()`` this is a no-op (nothing runs, nothing
    /// is counted).
    @preconcurrency
    public func enqueue(byteCount: Int, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        pendingBytes += byteCount
        lock.unlock()

        queue.async { [self] in
            // Skip only PAST the barrier (`drained`), never merely on `closed`: a block
            // enqueued before the close is FIFO-ordered ahead of the barrier's sync and
            // MUST complete before the barrier returns — that completion is the whole
            // contract ("previously-enqueued work finishes, then it's safe to free").
            lock.lock()
            let skip = drained
            lock.unlock()
            if !skip { work() }
            finish(byteCount: byteCount)
        }
    }

    /// NON-BLOCKING close (the production teardown): marks the gate closed, resumes
    /// every parked waiter NOW (they observe `closed` semantics), and schedules
    /// `onDrained` on the queue — serial FIFO guarantees it runs strictly after every
    /// previously-enqueued block has fully completed, so the caller frees its resources
    /// inside `onDrained` with no in-flight-work race and WITHOUT blocking the calling
    /// thread (see the class doc for why blocking main here can deadlock). Calling it
    /// again schedules another `onDrained` after the drain — the caller guards against
    /// double-free (GhosttySurface nils its pointer before closing).
    @preconcurrency
    public func close(onDrained: @escaping @Sendable () -> Void) {
        lock.lock()
        closed = true
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in toResume { waiter.resume() }

        queue.async { [self] in
            lock.lock()
            drained = true
            pendingBytes = 0
            lock.unlock()
            onDrained()
        }
    }

    /// Marks the gate closed, then synchronously drains the queue. On return:
    /// every previously-enqueued block has fully completed, no future block will run
    /// its work, and all parked waiters have been resumed. Idempotent. Must NOT be
    /// called from the gate's own queue (it would deadlock on itself), and — unlike
    /// ``close(onDrained:)`` — it BLOCKS the caller for as long as an in-flight block
    /// runs, including a block transitively waiting on main. Deinit safety net + tests.
    public func closeBarrier() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        // Serial FIFO: every block enqueued before the close runs to completion ahead
        // of this sync block. A straggler that lost the enqueue/close race (none in
        // production — producer and closer are both the main actor) lands AFTER it,
        // sees `drained`, and skips its work.
        queue.sync {
            lock.lock()
            drained = true
            lock.unlock()
        }

        // Flush any parked producers — pendingBytes from skipped stragglers still
        // drains via their finish(), but a waiter must not outlive the gate's purpose.
        lock.lock()
        let toResume = waiters
        waiters.removeAll()
        pendingBytes = 0
        lock.unlock()
        for waiter in toResume { waiter.resume() }
    }

    /// Parks until the un-finished backlog is below the high-water mark (resuming at
    /// the LOW-water mark — hysteresis), or returns immediately if it already is, or
    /// if the gate is closed. Resolution: the queue drains whenever the process's main
    /// loop is live (a feed block can transiently wait on a main-serviced resource —
    /// see the class doc), and ``close(onDrained:)``/``closeBarrier()`` resume all
    /// parked waiters immediately, so a waiter never outlives its gate.
    public func waitUntilBelowHighWater() async {
        if belowHighWaterOrClosed() { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            // Re-check under the lock: the queue may have drained (or the gate closed)
            // between the fast-path check and registration.
            if closed || pendingBytes <= lowWaterBytes {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Synchronous fast-path check for ``waitUntilBelowHighWater()`` (NSLock is not
    /// directly usable in an async context; the lock never spans a suspension).
    private func belowHighWaterOrClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || pendingBytes < highWaterBytes
    }

    /// Work completion: decrement the backlog and resume parked producers once it
    /// drains to the low-water mark.
    private func finish(byteCount: Int) {
        lock.lock()
        pendingBytes = max(0, pendingBytes - byteCount)
        var toResume: [CheckedContinuation<Void, Never>] = []
        if pendingBytes <= lowWaterBytes, !waiters.isEmpty {
            toResume = waiters
            waiters.removeAll()
        }
        lock.unlock()
        for waiter in toResume { waiter.resume() }
    }
}
