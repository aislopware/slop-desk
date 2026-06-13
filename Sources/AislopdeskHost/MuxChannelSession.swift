import Foundation
import AislopdeskProtocol
import AislopdeskTransport

/// One logical mux channel's host-side PTY relay.
///
/// A ``PTYProcess`` bridged to the client over a channel's data + control ``MuxSubChannel`` pair,
/// with per-channel `output` sequencing via a private ``ReplayBuffer``. MANY of these ride ONE
/// shared ``MuxNWConnection`` — so one TCP connection-pair carries N panes, each with its own
/// shell. The relay is implemented over the ``MessageChannel`` protocol (which ``MuxSubChannel``
/// conforms to), honouring "per-channel PTY from one shared connection".
///
/// Relay shape:
/// - OUTPUT: a no-buffer ``PTYReadLoop`` → an ordered FIFO → one sequential awaiter that assigns a
///   seq via the per-channel `ReplayBuffer` and writes `output` on the channel's DATA sub-channel;
///   `.title`/`.bell` sniffed non-destructively and written on the CONTROL sub-channel after.
/// - INPUT: the DATA sub-channel's inbound `input` → master fd.
/// - RESIZE/BYE/ACK: the CONTROL sub-channel's inbound → `TIOCSWINSZ` / offline / (ack is a no-op
///   beyond release; there is no per-channel reconnect replay so it just keeps the buffer bounded).
/// - EXIT: the reaper enqueues `exit(code:)` on the same FIFO so it follows the final output tail.
///
/// ### Bounded output queue (always on)
/// The DATA sub-channel's send window already SUSPENDS the output drain when a flooding channel
/// runs out of credit — but without an upstream bound that just moves the unboundedness one hop:
/// the `PTYReadLoop` would keep buffering the whole `yes` flood into the FIFO in memory. So the
/// queue is BOUNDED by a ``AislopdeskProtocol/BoundedQueuePolicy`` (byte high-water mark): when
/// enqueued-not-yet-sent bytes cross the bound, the ``PTYReadLoop`` is PAUSED (its `NSCondition`
/// gate stops issuing `read()`, so the kernel PTY buffer fills and backpressures the shell — the
/// real fix for the flood); it RESUMES when the drain brings the queue back under the bound.
///
/// `@unchecked Sendable`: mutable state is touched under `taskLock` / `replayLock` / the
/// ``PausableQueueGate``'s own lock; the PTY/channels are themselves thread-safe.
final class MuxChannelSession: @unchecked Sendable {
    let channelID: UInt32
    let pty: PTYProcess
    private let data: MuxSubChannel
    private let control: MuxSubChannel

    /// The per-session ZDOTDIR shim directory (R8 #3), if the zsh shell-integration shim was installed
    /// for this pane. Deleted in ``shutdown()`` once the child has exited — the shell read its rc files
    /// at exec time, so the dir is safe to remove on teardown. Without this, every opened pane leaked one
    /// `aislopdesk-zdotdir-*` dir + 4 files into the temp dir for the host's (long-lived) lifetime.
    private let shimDir: URL?

    private let taskLock = NSLock()
    private var replay: ReplayBuffer
    private let replayLock = NSLock()
    private var inputTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    /// Wake for the output FIFO drain. Read/written ONLY under `fifoLock` (producers run on
    /// the read-loop thread + the exit task; `shutdown()` nils it — an unguarded optional
    /// read would race the teardown).
    private var outputWakeContinuation: AsyncStream<Void>.Continuation?
    private var readLoop: PTYReadLoop?
    private var started = false

    /// The output FIFO: a lock-guarded deque (NOT an AsyncStream of items — iterators
    /// cannot peek, and the drain needs to MERGE adjacent chunks). Producers append under
    /// `fifoLock` then yield the bufferingNewest(1) wake; the single drain pops merged
    /// frames until empty before re-parking (the proven ConnectionViewModel outQueue
    /// discipline — append-then-yield, drain-until-empty, no lost wake, no Task-per-item).
    private let fifoLock = NSLock()
    private var outFIFO: [OutputItem] = []

    /// Sniffed control messages awaiting their own sender. Split from the data drain so a
    /// slow/stalled CONTROL socket (or per-redraw title churn) can never stall data sends —
    /// data waited on control before this split. Per-channel control FIFO is preserved
    /// (running→idle, successive titles); cross-socket order vs data was never guaranteed
    /// (different TCP connections).
    private let controlOutLock = NSLock()
    private var controlOut: [WireMessage] = []
    private var controlSendTask: Task<Void, Never>?
    /// Wake for the control sender. Read/written ONLY under `controlOutLock` (same teardown
    /// race as ``outputWakeContinuation``).
    private var controlWakeContinuation: AsyncStream<Void>.Continuation?

    /// One merged data frame popped off the FIFO by the drain. Internal (not private) so the
    /// drain-merge tests can assert on popped frames via the `_…ForTesting` seams.
    enum MergedFrame {
        case output(bytes: Data, byteCount: Int, control: [WireMessage])
        case exit(code: Int32)
    }

    /// Pops the next merged frame under `fifoLock`. `.exit` is a merge BARRIER (it must
    /// stay strictly after the final tail chunks — the R5-rank-5 EOF-latch ordering).
    /// Single-chunk fast path returns the chunk's `Data` UNCHANGED (zero added copy — the
    /// interactive steady state stays byte-identical work); only a multi-chunk backlog
    /// pays one concatenation, amortized by skipping N−1 seq/encode/envelope/send rounds.
    ///
    /// FRAME BOUND (credit progress invariant): every emitted `.output` payload is capped
    /// at ``MuxFlowControl/maxOutputFramePayloadBytes`` — window/2 minus the frame-header
    /// margin, cross-clamped against the merge cap. An over-cap HEAD chunk (a raw read
    /// chunk, or env-tuned extremes) is SPLIT: the prefix ships now, the remainder is
    /// reinserted at the FIFO head (byte order preserved; the gate accounting still sums
    /// to the producer's enqueued total because each emitted frame dequeues exactly its
    /// own byteCount). Without this, a max-size frame's 13-byte encode overhead could park
    /// the sender permanently just below the receiver's grant threshold (the 13-byte
    /// dead-zone stall the night review caught).
    func takeMergedFrame() -> MergedFrame? {
        fifoLock.lock()
        defer { fifoLock.unlock() }
        let cap = MuxFlowControl.maxOutputFramePayloadBytes
        guard let head = outFIFO.first else { return nil }
        if case let .exit(code) = head {
            outFIFO.removeFirst()
            return .exit(code: code)
        }
        // Head is a chunk: pop it, then greedily absorb following chunks up to the cap.
        guard case var .chunk(bytes, control) = head else { return nil }
        outFIFO.removeFirst()
        if bytes.count > cap {
            // SPLIT an over-cap head chunk: ship the prefix (with the chunk's sniffed
            // control — per-channel control FIFO holds), reinsert the remainder at the
            // head so the byte stream order is untouched.
            let prefix = Data(bytes.prefix(cap))
            let remainder = Data(bytes.dropFirst(cap))
            outFIFO.insert(.chunk(bytes: remainder, control: []), at: 0)
            return .output(bytes: prefix, byteCount: prefix.count, control: control)
        }
        var byteCount = bytes.count
        if case .chunk(let nextBytes, _)? = outFIFO.first,
           byteCount + nextBytes.count <= cap {
            // Multi-chunk merge: one mutable accumulator, reserve once.
            var merged = Data(capacity: min(cap, byteCount + nextBytes.count))
            merged.append(bytes)
            while case .chunk(let more, let moreControl)? = outFIFO.first,
                  byteCount + more.count <= cap {
                outFIFO.removeFirst()
                merged.append(more)
                byteCount += more.count
                control.append(contentsOf: moreControl)
            }
            bytes = merged
        }
        return .output(bytes: bytes, byteCount: byteCount, control: control)
    }

    /// EOF latch (R5 rank 5): set true by ``PTYReadLoop``'s `onEOF` once the read loop has drained the
    /// master to EOF — which, per the read-loop contract, happens only AFTER every buffered output chunk
    /// has been yielded into the FIFO. The exit task awaits this before yielding `.exit`, so the
    /// reaper-driven exit can never overtake the final output tail on the shared FIFO (which would
    /// truncate the client's last screen). Guarded by `eofLock`.
    private let eofLock = NSLock()
    private var eofReached = false

    /// Set true once the drain has actually SENT the `.exit(code:)` frame on the DATA channel (R13 #7).
    /// The exit task awaits this between yielding `.exit` and calling `onExit` (which triggers teardown),
    /// so `shutdown()` can never cancel the drain before the buffered exit code reaches the wire. Guarded
    /// by `exitSentLock`.
    private let exitSentLock = NSLock()
    private var exitSent = false

    /// Bounded-queue backpressure GATE: fuses the ``BoundedQueuePolicy`` accounting with the
    /// read-loop pause/resume action ATOMICALLY under one lock (FIX #3 — see ``PausableQueueGate``).
    /// Built in ``startRelay()`` once the `readLoop` exists (so the gate can drive it). `nil` until then.
    private var outputGate: PausableQueueGate?

    // MARK: - Resize micro-debounce (latest-wins backstop)

    /// One-frame (default) settle window for the inline resize micro-debounce. Injected so a test
    /// drives the deadline deterministically (the `StaticIDRDecider` `now`-injection discipline) —
    /// `.zero` in tests applies the LATEST size on the next runloop turn with no wall-clock sleep.
    private let resizeDebounce: Duration
    /// Guards the resize-debounce state below. The state is touched from THREE contexts — the serial
    /// `controlTask`, the debounce `Task` when it fires, and `shutdown()` — so unlike the
    /// single-writer `controlTask`-only fields it needs a lock (the codebase's `taskLock`/`replayLock`
    /// discipline). Held only around O(1) field reads/writes + the inline `setWindowSize` ioctl.
    private let resizeLock = NSLock()
    /// The latest pending winsize awaiting a debounced apply; `nil` when nothing is pending.
    private var pendingResize: (cols: UInt16, rows: UInt16, px: UInt16, py: UInt16)?
    /// The in-flight debounce task (cancel-replace, à la `WorkspaceStore.scheduleSave`).
    private var resizeDebounceTask: Task<Void, Never>?
    /// Generation guard: `scheduleResize` bumps it; a debounce task PAST its sleep re-checks it and
    /// bails if a newer resize superseded it. `Task.cancel()` cannot interrupt a task already past
    /// its `sleep`, so the generation — not cancellation alone — is what makes the LATEST size win.
    private var resizeGeneration: UInt64 = 0

    /// Called once when the child exits so the owner can drop this channel from its map.
    var onExit: (@Sendable (UInt32) -> Void)?

    private enum OutputItem: Sendable {
        case chunk(bytes: Data, control: [WireMessage])
        case exit(code: Int32)
    }

    /// - Parameter resizeDebounce: the latest-wins settle window for `TIOCSWINSZ` applies (default
    ///   ~one frame). See ``scheduleResize(cols:rows:px:py:)`` for WHY a host-side debounce exists.
    init(
        channelID: UInt32,
        pty: PTYProcess,
        data: MuxSubChannel,
        control: MuxSubChannel,
        resizeDebounce: Duration = .milliseconds(16),
        replay: ReplayBuffer = ReplayBuffer(),
        shimDir: URL? = nil
    ) {
        self.channelID = channelID
        self.pty = pty
        self.data = data
        self.control = control
        self.resizeDebounce = resizeDebounce
        self.replay = replay
        self.shimDir = shimDir
    }

    func startRelay() {
        taskLock.lock()
        guard !started else { taskLock.unlock(); return }
        started = true
        taskLock.unlock()

        let pty = self.pty
        let data = self.data
        let control = self.control
        let masterFD = pty.masterFD

        let (outputWakeups, outputWake) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        fifoLock.lock()
        self.outputWakeContinuation = outputWake
        fifoLock.unlock()
        outputTask = Task { [weak self] in
            for await _ in outputWakeups {
                // Drain until empty BEFORE re-parking (bufferingNewest(1) holds at most one
                // pending wake — a one-frame-per-wake drain would strand backlog).
                while let frame = self?.takeMergedFrame() {
                    guard let self else { return }
                    switch frame {
                    case let .output(bytes, byteCount, controlMessages):
                        let seq = self.nextSeq(for: bytes)
                        // `data.send` SUSPENDS on the per-channel credit window, so a flooding
                        // channel naturally slows here. After the write is accepted we dequeue
                        // the bytes and resume the read loop if the FIFO drained below the
                        // bound — dequeue MUST stay post-send (the gate bounds
                        // enqueued-not-yet-SENT; moving it to take-time would let the read
                        // loop refill while a merged frame is still unsent).
                        try? await data.send(.output(seq: seq, bytes: bytes))
                        self.dequeueOutput(byteCount)
                        // Hand sniffed control to its OWN sender: the data drain never awaits
                        // the control socket (a stalled control link froze data before this).
                        if !controlMessages.isEmpty { self.enqueueControl(controlMessages) }
                    case let .exit(code):
                        try? await data.send(.exit(code: code))
                        self.signalExitSent()   // R13 #7: release the exit task's await so onExit can run
                    }
                }
            }
        }

        // CONTROL OUT: one serial sender for sniffed title/bell/commandStatus, FIFO per
        // channel (the only ordering consumers rely on — they fold each type independently
        // and cross-socket order vs data was already non-deterministic).
        let (controlWakeups, controlWake) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        controlOutLock.lock()
        self.controlWakeContinuation = controlWake
        controlOutLock.unlock()
        controlSendTask = Task { [weak self] in
            for await _ in controlWakeups {
                while let batch = self?.takeControlBatch() {
                    for message in batch {
                        try? await control.send(message)
                    }
                }
            }
        }

        let sniffer = HostOutputSniffer()
        let readLoop = PTYReadLoop(
            fd: masterFD,
            onChunk: { [weak self] chunk in
                guard let self else { return }
                // ONE fused non-destructive sniffer pass over the chunk (title/bell + OSC 133
                // command status — formerly two copy-derived per-byte machines scanning every
                // byte twice on this hot thread). It only OBSERVES; the bytes are forwarded
                // unchanged below. Emission order is byte-faithful interleaved (the old
                // grouped-per-sniffer order was already chunk-boundary-dependent; consumers
                // fold each type independently).
                let controlMsgs = sniffer.observe(chunk)
                // Account the chunk in the bounded queue BEFORE enqueueing; if it pushes the FIFO
                // to/over the bound, PAUSE the read loop so the kernel PTY buffer fills and
                // backpressures the shell (the real flood fix).
                self.enqueueOutput(chunk.count)
                // Append-then-yield (no lost wake): the pending bufferingNewest(1) wake always
                // observes a complete FIFO. The continuation is read under fifoLock (teardown
                // nils it); yield happens OUTSIDE the lock (it may resume the drain inline).
                self.fifoLock.lock()
                self.outFIFO.append(.chunk(bytes: chunk, control: controlMsgs))
                let wake = self.outputWakeContinuation
                self.fifoLock.unlock()
                wake?.yield(())
            },
            onEOF: { [weak self] in self?.signalEOFReached() }
        )
        self.readLoop = readLoop
        // FIX #3: build the bounded-queue gate now that the read loop exists, so pause/resume is
        // applied ATOMICALLY with the accounting (no lost-wakeup freeze).
        self.outputGate = PausableQueueGate(capacity: MuxFlowControl.hostQueueCapacityBytes) { paused in
            readLoop.setPaused(paused)
        }
        readLoop.start()

        // INPUT: the DATA sub-channel carries `input`. The blocking `write(2)` runs on a
        // DEDICATED serial queue (mirroring PTYReadLoop's dedicated read thread): the PTY
        // master fd is deliberately blocking, so a paste into a non-reading foreground
        // program used to park a width-limited COOPERATIVE-POOL thread — a few wedged
        // writers degraded every other pane's drains. Credit is granted only AFTER the
        // write returns (credit-at-consumption), so a stalled PTY transitively parks the
        // CLIENT's sender at one window instead of buffering the paste in host RAM.
        let inputQueue = DispatchQueue(label: "aislopdesk.host.pty-input.\(channelID)", qos: .userInitiated)
        inputTask = Task.detached { [weak self] in
            do {
                for try await message in data.inbound {
                    if case let .input(bytes) = message {
                        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                            inputQueue.async {
                                Self.writeAll(fd: masterFD, data: bytes)
                                done.resume()
                            }
                        }
                    }
                    // Consumed (written to the PTY / processed): grant the window back.
                    await data.noteConsumed(message.wireByteCount)
                }
            } catch { /* channel gone — the daemon keeps the shell alive (keep-alive) */ }
            // The DATA channel ended (clean close or drop): the client is no longer reachable on this
            // channel, so engage the ReplayBuffer's 4 MiB offline gate for the window before teardown
            // (R5 rank 2). Harmless if the session is already being shut down (gate-pause is idempotent).
            self?.setClientOnline(false)
        }

        // CONTROL: resize / bye / ack on the CONTROL sub-channel.
        //
        // RESIZE backstop (defense-in-depth): a fast client drag can deliver ~100 distinct `.resize`
        // (the client coalescer is the PRIMARY converger, but an older/replayed/slow client may not
        // coalesce). Applying each `TIOCSWINSZ` immediately fires zsh's SIGWINCH handler at every
        // INTERMEDIATE size; its incremental prompt-redraw math then desyncs against a size that keeps
        // changing → orphaned cursor / misaligned prompt that only a fresh prompt heals. A LOCAL
        // terminal never hits this because the KERNEL coalesces SIGWINCH (the app reads the latest
        // size once). So we restore that: latest-wins micro-debounce on this SERIAL loop — overwrite
        // `pendingResize`, cancel+re-arm ONE debounce task that applies the LATEST size once after a
        // one-frame settle. INLINE on the serial loop (no Task-per-resize → no reorder hazard); the
        // ioctl itself (microseconds) stays inline — only the FREQUENCY of distinct applies is bounded.
        controlTask = Task {
            do {
                for try await message in control.inbound {
                    switch message {
                    case let .resize(cols, rows, px, py):
                        self.scheduleResize(cols: cols, rows: rows, px: px, py: py)
                    case let .ack(seq):
                        // A non-resize control message: FLUSH any pending size FIRST so the serial
                        // loop's ordering contract holds (a size that arrived before this ack lands
                        // before the ack's effects) and no settled size is stranded.
                        self.flushPendingResize()
                        self.acknowledge(upTo: seq)
                    case .bye:
                        self.flushPendingResize() // client leaving cleanly: never strand a size at teardown.
                    case let .ping(timestampMS):
                        // Stateless RTT probe: echo the client's timestamp back on the
                        // control sender (FIFO, never blocks behind data). Deliberately NO
                        // flushPendingResize — a periodic ping must not defeat the resize
                        // micro-debounce, and a ping orders against nothing.
                        self.enqueueControl([.pong(timestampMS: timestampMS)])
                    default:
                        self.flushPendingResize()
                    }
                }
            } catch { /* control gone */ }
            // Channel closed: apply any settled-but-undebounced final size before the loop ends.
            self.flushPendingResize()
        }

        let id = channelID
        exitTask = Task { [weak self] in
            let code = await pty.waitForExit()
            // R5 rank 5: gate the exit yield on the read loop having drained the master to EOF, so the
            // FINAL output tail is enqueued AHEAD of `.exit` on the shared FIFO. `onEOF` is called by
            // PTYReadLoop only AFTER it has yielded every buffered chunk, so awaiting the EOF latch here
            // guarantees `.exit` follows the last `.chunk` (the FIFO + single sequential drain preserve
            // that order on the wire). Bounded so a wedged/paused read never hangs exit delivery forever.
            await self?.awaitEOFOrTimeout()
            self?.enqueueExit(code: code)
            // R13 #7: wait until the drain actually SENT `.exit` on the wire before firing onExit (which
            // triggers shutdown → outputTask.cancel()). Otherwise teardown can cancel the drain before
            // the buffered exit code is flushed, dropping the clean exit status. Bounded + cancellation-
            // aware (shutdown cancels this task), so a dead client / torn-down pane never hangs. Ordering
            // is preserved: `.exit` still follows the tail chunks on the FIFO (the EOF latch above).
            await self?.awaitExitSentOrTimeout()
            self?.onExit?(id)
        }
    }

    /// Tears this channel down FOR GOOD and releases its PTY + master fd.
    ///
    /// ⚠️ DESTROY-ONLY. At S1 every caller of `shutdown()` is a genuine end-of-session:
    /// `HostServer.stop()` (daemon stopping) and `HostServer.removeMuxSession()` — itself
    /// reached only from the child's own exit, a peer `channelClose`, or a whole-link drop
    /// (peer crash / TCP reset). S1 has NO per-channel reconnect/resume, so none of those is
    /// keep-alive: the shell MUST die here, or the PTY + master fd leak on every disconnect.
    /// WHEN PER-CHANNEL RESUME LANDS, a resume-able disconnect must route to a NEW `detach()`
    /// that stops the read loop + closes the master WITHOUT killing the child — it must NOT
    /// come through here (this path SIGKILLs the shell).
    ///
    /// ### Why the child is killed BEFORE `closeMaster()` (the latent-hang fix)
    /// `closeMaster()` → `close(masterFD)` BLOCKS on macOS while the `PTYReadLoop` is parked
    /// inside an in-flight kernel `read()` on that same fd. `readLoop?.stop()` signals the
    /// loop's `NSCondition` gate but CANNOT interrupt a `read()` already in the kernel — that
    /// read only returns when the slave closes, i.e. when the child dies. For a self-exiting
    /// child the reader is already at EOF, but an INTERACTIVE shell (`/bin/sh` awaiting input)
    /// never exits on its own, so without killing it `close()` hangs FOREVER. So: `terminate()`
    /// (SIGTERM) → bounded wait for the reaper → `forceTerminate()` (SIGKILL) if it did not
    /// take → short re-wait. Once the child is dead the slave closes, the parked `read()`
    /// returns EOF/EIO, the loop exits, and `closeMaster()` is non-blocking.
    func shutdown() {
        taskLock.lock()
        readLoop?.stop()
        // Wake continuations are owned by their queue locks (producers on other threads read
        // them under the same lock — see the property docs), NOT by taskLock.
        fifoLock.lock()
        outputWakeContinuation?.finish()
        outputWakeContinuation = nil
        fifoLock.unlock()
        controlOutLock.lock()
        controlWakeContinuation?.finish()
        controlWakeContinuation = nil
        controlOutLock.unlock()
        controlSendTask?.cancel()
        controlSendTask = nil
        inputTask?.cancel()
        controlTask?.cancel()
        exitTask?.cancel()
        // `outputTask.cancel()` now GENUINELY unblocks a drain parked on an exhausted DATA credit
        // window: `MuxSubChannel.awaitChunkCredit`'s park is cancellation-aware, so a cancelled sender
        // wakes + throws and the task completes. Without that, the `HostServer.stop()` teardown — which
        // does NOT route through `MuxNWConnection` (the only path that `finish()`es the sub-channels) —
        // would leak the parked `outputTask` + its retained sub-channel actors (the long-lived menu-bar
        // host accumulating one per affected channel on every Start/Stop).
        outputTask?.cancel()
        taskLock.unlock()
        // R13 #1: `resizeDebounceTask` is owned by `resizeLock` (scheduleResize / flushPendingResize),
        // NOT `taskLock`. Cancelling it under taskLock (the old code) raced scheduleResize's store under
        // resizeLock — two disjoint mutexes guarding one ARC `Task` reference = a data race (torn read /
        // ARC over-release / missed cancel). Read+nil under its own lock, then cancel outside the lock,
        // matching flushPendingResize's discipline (locks are never nested in this file → no deadlock).
        resizeLock.lock()
        let resizeTask = resizeDebounceTask
        resizeDebounceTask = nil
        resizeLock.unlock()
        resizeTask?.cancel()
        // R5 rank 5: release the exit task's EOF gate (it is also cancelled above, but signalling makes
        // it return promptly rather than polling to its timeout) so teardown never lingers on the latch.
        signalEOFReached()
        // R13 #7: likewise release the exit-sent latch so a torn-down exit task returns at once instead
        // of polling to its timeout (mirrors the EOF latch above; the cancel above also unblocks it).
        signalExitSent()
        // DESTROY-path child termination (see the doc comment): SIGTERM, then a bounded wait
        // for the reaper to observe the exit; if the child blocked/ignored SIGTERM (or a
        // foreground job kept the slave open), escalate to SIGKILL and re-wait briefly. This
        // GUARANTEES the parked read() returns before close(masterFD), so close() never hangs.
        pty.terminate()
        if !pty.waitUntilExited(timeout: 0.25) {
            pty.forceTerminate()
            pty.waitUntilExited(timeout: 0.25)
        }
        pty.closeMaster()
        // R8 #3: the child has exited, so its ZDOTDIR shim dir is no longer needed — delete it so the
        // host's temp dir does not accumulate one `aislopdesk-zdotdir-*` dir per opened pane forever.
        if let shimDir { try? FileManager.default.removeItem(at: shimDir) }
    }

    /// A serial-safe BACKGROUND queue for the blocking ``shutdown()`` work, kept OFF the cooperative
    /// thread pool / the mux connection's receive loop. `concurrent` so simultaneous channel teardowns
    /// (a multi-pane link drop) tear down in parallel rather than ~0.5s × N serially.
    static let teardownQueue = DispatchQueue(
        label: "aislopdesk.host.session-shutdown", qos: .utility, attributes: .concurrent)

    /// NON-BLOCKING teardown: dispatches ``shutdown()`` to a background queue and returns IMMEDIATELY.
    ///
    /// ``shutdown()`` blocks the caller for up to ~0.5s (`SIGTERM` → bounded `Thread.sleep` wait →
    /// `SIGKILL` → re-wait → `closeMaster`) — and for an INTERACTIVE shell, which IGNORES `SIGTERM`,
    /// the common path is the full ~250ms `SIGKILL` escalation. The host reaches a channel teardown
    /// SYNCHRONOUSLY from the mux connection's receive loop (a peer `channelClose` / link drop routes
    /// `MuxNWConnection.route`/`finishLink` → `hostCloseHandler` → `HostServer.removeMuxSession`), so
    /// blocking there would (a) stall EVERY OTHER pane riding the same shared connection for that whole
    /// window — closing one pane freezes its siblings — and (b) park a cooperative-pool thread on
    /// `Thread.sleep`. Offloading keeps the receive loop free; the caller has already removed the
    /// session from its map (the cross-shut/double-shut guard), so the PTY kill + fd close are safe to
    /// finish asynchronously. `shutdown()` is itself idempotent, so a detached double-call is harmless.
    ///
    /// `completion` fires on the teardown queue after `shutdown()` returns — used by
    /// ``HostServer/stop()`` to await every detached teardown before the daemon exits.
    func shutdownDetached(completion: (@Sendable () -> Void)? = nil) {
        MuxChannelSession.teardownQueue.async { [self] in
            shutdown()
            completion?()
        }
    }

    // MARK: - Resize micro-debounce (latest-wins; restores kernel SIGWINCH-coalescing for any client)

    /// Buffers `pendingResize` to the LATEST size and (cancel-)re-arms a single debounce task that
    /// applies it once after `resizeDebounce`. Because each `.resize` RE-ARMS (never blocks) the task,
    /// the debounce ALWAYS fires after the LAST resize → the latest size always lands (trailing-edge
    /// guarantee). A generation guard makes a task already past its sleep bail if superseded — the
    /// exact `WorkspaceStore.scheduleSave` cancel-replace+generation pattern.
    private func scheduleResize(cols: UInt16, rows: UInt16, px: UInt16, py: UInt16) {
        resizeLock.lock()
        pendingResize = (cols, rows, px, py)
        resizeGeneration &+= 1
        let generation = resizeGeneration
        resizeDebounceTask?.cancel()
        let debounce = resizeDebounce
        resizeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return // superseded (cancelled) before firing — the re-armed task applies the latest.
            }
            guard let self else { return }
            // Past the sleep: `Task.cancel()` no longer helps, so the generation guard decides. Apply
            // only if still the latest scheduled resize (checked under the lock, atomic with the ioctl).
            self.flushPendingResize(ifGeneration: generation)
        }
        resizeLock.unlock()
    }

    /// Applies the buffered `pendingResize` (if any) via `TIOCSWINSZ` exactly once and clears it. The
    /// single inline `setWindowSize` (microseconds) under `resizeLock`. Idempotent: a no-op when
    /// nothing is pending, so the flush-on-ack / flush-on-bye / flush-on-close paths can all call it.
    ///
    /// - Parameter ifGeneration: when non-nil (the debounce-fire path), apply only if it still matches
    ///   `resizeGeneration` — a stale already-past-sleep task must not apply an old size. The flush
    ///   paths (ack/bye/close) pass `nil` to apply UNCONDITIONALLY (they must never strand a size).
    private func flushPendingResize(ifGeneration generation: UInt64? = nil) {
        resizeLock.lock()
        if let generation, resizeGeneration != generation { resizeLock.unlock(); return }
        guard let r = pendingResize else { resizeLock.unlock(); return }
        pendingResize = nil
        resizeLock.unlock()
        pty.setWindowSize(cols: r.cols, rows: r.rows, pxWidth: r.px, pxHeight: r.py)
    }

    // MARK: - Bounded-output-queue backpressure (lock-guarded; the value type is not Sendable)

    /// Accounts `count` enqueued output bytes; pauses the read loop if the FIFO crossed the bound.
    /// FIX #3: the accounting + the pause action are applied ATOMICALLY inside ``PausableQueueGate``
    /// (under one lock) so a concurrent ``dequeueOutput(_:)`` can never interleave a stale resume
    /// after this pause and leave the loop frozen below capacity.
    private func enqueueOutput(_ count: Int) {
        outputGate?.enqueue(count)
    }

    /// Accounts `count` sent output bytes; resumes a paused read loop if the FIFO drained below the
    /// bound. FIX #3: atomic with the accounting (see ``PausableQueueGate``).
    private func dequeueOutput(_ count: Int) {
        outputGate?.dequeue(count)
    }

    // MARK: - Output FIFO / control-out producers (append-then-yield; no lost wake)

    /// Enqueues `.exit` on the output FIFO (the reaper path). `.exit` is a merge BARRIER in
    /// ``takeMergedFrame()`` — it never coalesces with chunks, so it stays strictly after the
    /// final output tail (the R5-rank-5 EOF-latch ordering).
    private func enqueueExit(code: Int32) {
        fifoLock.lock()
        outFIFO.append(.exit(code: code))
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

    /// Bound on the pending control-out queue. Control consumers are latest-state folds
    /// (title/activity) or droppable samples (pong), so shedding under a flood is safe —
    /// without a bound, a hostile client spamming `.ping` against its own non-read control
    /// socket (the sender blocks on TCP backpressure) grows `controlOut` without limit.
    private static let maxControlOutQueued = 1024

    /// Hands sniffed control messages to the dedicated control sender (FIFO per channel).
    /// Sheds NEW messages past the bound (the queued ones are older but already ordered;
    /// a shed title/pong is replaced/refreshed by the next one naturally).
    private func enqueueControl(_ messages: [WireMessage]) {
        controlOutLock.lock()
        // Slot-limited append: a merged frame can carry MULTIPLE sniffed control messages, so a bulk
        // `append(contentsOf:)` guarded only by `count < cap` would land at `cap + (K-1)` — overshooting
        // the bound the comment promises. Take only the free slots so the queue never exceeds the cap.
        let free = Self.maxControlOutQueued - controlOut.count
        if free > 0 {
            controlOut.append(contentsOf: messages.prefix(free))
        }
        let wake = controlWakeContinuation
        controlOutLock.unlock()
        wake?.yield(())
    }

    /// Atomically takes the whole pending control batch; `nil` when empty (drain re-parks).
    private func takeControlBatch() -> [WireMessage]? {
        controlOutLock.lock()
        defer { controlOutLock.unlock() }
        guard !controlOut.isEmpty else { return nil }
        let batch = controlOut
        controlOut.removeAll(keepingCapacity: true)
        return batch
    }

    // MARK: - Per-channel replay bookkeeping (lock-guarded; the value type is not Sendable)

    private func nextSeq(for bytes: Data) -> Int64 {
        replayLock.lock()
        let seq = replay.append(bytes: bytes)
        let shouldPause = replay.shouldPauseDrain
        replayLock.unlock()
        // R5 rank 2: the retained-byte cap is no longer dead. Appending may push retained bytes over
        // the 64 MiB cap (or the 4 MiB offline gate); feed that into the read-loop pause so the kernel
        // PTY buffer backpressures the shell instead of the host buffering the un-acked stream
        // unboundedly. OR-composed with the bounded-queue source inside the gate (resume only when both
        // clear). The lock is released BEFORE touching the gate to keep the lock order replayLock→gate.
        updateReplayBackpressure(shouldPause)
        return seq
    }

    private func acknowledge(upTo seq: Int64) {
        replayLock.lock()
        replay.ack(upTo: seq)
        let shouldPause = replay.shouldPauseDrain
        replayLock.unlock()
        // An ack releases retained entries → retained bytes drop → the replay-pause may clear, resuming
        // the read loop (if the bounded queue is also below bound). This is the drain side of the cap.
        updateReplayBackpressure(shouldPause)
    }

    /// Marks the client online/offline for the offline (4 MiB) gate, then recomputes backpressure. In
    /// S1 a channel-gone usually tears the whole session down moments later, but wiring this keeps the
    /// offline gate honest for the brief window and for when per-channel resume lands.
    private func setClientOnline(_ online: Bool) {
        replayLock.lock()
        replay.isClientOnline = online
        let shouldPause = replay.shouldPauseDrain
        replayLock.unlock()
        updateReplayBackpressure(shouldPause)
    }

    /// Forwards the ReplayBuffer's drain signal to the output gate's replay-pause source. `nil` gate
    /// (flow control off / before `startRelay`) is a no-op.
    private func updateReplayBackpressure(_ shouldPause: Bool) {
        outputGate?.setReplayPause(shouldPause)
    }

    // MARK: - Exit ordering: EOF latch (R5 rank 5)

    /// Marks the read loop as having drained the master to EOF (called from `onEOF`, and from
    /// ``shutdown()`` so a torn-down exit task never waits the full timeout).
    private func signalEOFReached() { eofLock.lock(); eofReached = true; eofLock.unlock() }

    private func isEOFReached() -> Bool { eofLock.lock(); defer { eofLock.unlock() }; return eofReached }

    /// Awaits the read loop reaching EOF (so the final tail is fully enqueued) OR a bounded timeout —
    /// whichever first — before the exit task yields `.exit`. Polling (2 ms granularity): the exit task
    /// runs once per pane, so the cost is negligible, and polling avoids a cancellation-leaked
    /// continuation. Returns promptly on cancellation (``shutdown()`` cancels the exit task).
    private func awaitEOFOrTimeout(_ timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isEOFReached() || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func signalExitSent() { exitSentLock.lock(); exitSent = true; exitSentLock.unlock() }

    private func isExitSent() -> Bool { exitSentLock.lock(); defer { exitSentLock.unlock() }; return exitSent }

    /// Awaits the drain having SENT `.exit` on the wire (or a bounded timeout / cancellation) before the
    /// exit task fires `onExit` (R13 #7). Mirrors ``awaitEOFOrTimeout`` (2 ms poll, runs once per pane).
    /// A dead client whose credit never arrives times out — the code can't be delivered to it anyway —
    /// and ``shutdown()`` cancels the exit task so a torn-down pane returns at once.
    ///
    /// 10s (was 2s): with credit-at-consumption the send window tracks the client's RENDER
    /// drain, so a transiently-stalled client (window drag, brief main-thread stall) can
    /// legitimately park the `.exit` send for a few seconds — a 2s window made dropping a
    /// clean exit code routine instead of exceptional. Still bounded + cancellation-aware,
    /// so teardown never hangs on it.
    private func awaitExitSentOrTimeout(_ timeout: Duration = .seconds(10)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isExitSent() || Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - Test seams (replay-backpressure wiring, R5 rank 2)
    // These drive the append/ack/online glue against a real ``PausableQueueGate`` WITHOUT a PTY or
    // read loop, so the "retained ≥ cap → pause; ack → resume" wiring is provable headlessly. Reached
    // via `@testable import`; never used in production.

    /// Installs a gate to receive the replay-pause signal (production builds it in ``startRelay()``).
    func _installGateForTesting(_ gate: PausableQueueGate) { outputGate = gate }
    /// Drives the real ``nextSeq(for:)`` glue (append + recompute + gate). Returns the assigned seq.
    @discardableResult func _appendForTesting(_ bytes: Data) -> Int64 { nextSeq(for: bytes) }
    /// Drives the real ``acknowledge(upTo:)`` glue (ack + recompute + gate).
    func _ackForTesting(upTo seq: Int64) { acknowledge(upTo: seq) }
    /// Drives the real ``setClientOnline(_:)`` glue (offline-gate side).
    func _setClientOnlineForTesting(_ online: Bool) { setClientOnline(online) }

    /// Exit-ordering EOF latch seams (R5 rank 5).
    func _signalEOFForTesting() { signalEOFReached() }
    func _isEOFReachedForTesting() -> Bool { isEOFReached() }
    func _awaitEOFForTesting(timeout: Duration) async { await awaitEOFOrTimeout(timeout) }

    /// Exit-sent latch seams (R13 #7) — the drain signals once `.exit` is on the wire; the exit task
    /// awaits it before firing onExit so teardown can't cancel the drain before the exit code is sent.
    func _signalExitSentForTesting() { signalExitSent() }
    func _isExitSentForTesting() -> Bool { isExitSent() }
    func _awaitExitSentForTesting(timeout: Duration) async { await awaitExitSentOrTimeout(timeout) }

    /// Drain-merge seams: drive the output FIFO + ``takeMergedFrame()`` (and the control-out
    /// queue) WITHOUT a PTY or running drain, so merge/barrier/cap semantics are provable
    /// headlessly. The enqueue paths mirror the production producers exactly (append under
    /// the lock; the wake yield is a no-op pre-`startRelay` since the continuation is nil).
    func _enqueueChunkForTesting(bytes: Data, control: [WireMessage] = []) {
        enqueueOutput(bytes.count)
        fifoLock.lock()
        outFIFO.append(.chunk(bytes: bytes, control: control))
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }
    func _enqueueExitForTesting(code: Int32) { enqueueExit(code: code) }
    func _enqueueControlForTesting(_ messages: [WireMessage]) { enqueueControl(messages) }
    func _takeControlBatchForTesting() -> [WireMessage]? { takeControlBatch() }
    static var maxControlOutQueuedForTesting: Int { maxControlOutQueued }

    private static func writeAll(fd: Int32, data: Data) {
        #if canImport(Darwin)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 {
                    if errno == EINTR { continue }
                    return
                } else {
                    return
                }
            }
        }
        #endif
    }
}
