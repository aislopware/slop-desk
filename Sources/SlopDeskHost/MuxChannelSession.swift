import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import SlopDeskTransport

/// One logical mux channel's host-side PTY relay.
///
/// A ``PTYProcess`` bridged to the client over a channel's data + control ``MuxSubChannel`` pair,
/// with per-channel `output` sequencing via a private ``ReplayBuffer``. MANY of these ride ONE
/// shared ``MuxNWConnection`` — one TCP connection-pair carries N panes, each with its own shell.
/// Implemented over the ``MessageChannel`` protocol (which ``MuxSubChannel`` conforms to).
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
/// The DATA send window SUSPENDS the drain when a flooding channel runs out of credit — but without
/// an upstream bound that just moves the unboundedness one hop: the `PTYReadLoop` would buffer the
/// whole `yes` flood into the FIFO. So the queue is BOUNDED by a
/// ``SlopDeskProtocol/BoundedQueuePolicy`` (byte high-water mark): when enqueued-not-yet-sent bytes
/// cross the bound the ``PTYReadLoop`` is PAUSED (its `NSCondition` gate stops issuing `read()`, so
/// the kernel PTY buffer fills and backpressures the shell — the real flood fix); it RESUMES when
/// the drain brings the queue back under the bound.
///
/// ### Detach / reattach (tmux-style survival, C1–C4)
/// On client disconnect with `SLOPDESK_DETACH_ENABLED` on, ``detach()`` runs instead of
/// ``shutdown()``: it cancels the relay tasks and engages the ReplayBuffer's offline gate to pause
/// the PTY drain, but does NOT stop/close the ``PTYReadLoop`` — `stop()` is irreversible. The shell
/// (and the paused read loop) survive. On return, ``rebindRelay(data:control:)`` swaps the stale
/// sub-channels, KEEPS the out-FIFO (its chunks were never sequenced into the ReplayBuffer — they
/// are the detached-window output the restarted drain must ship), clears the stateless control-out,
/// rebuilds the wake streams, and restarts the relay tasks.
///
/// `@unchecked Sendable`: mutable state is touched under `taskLock` / `replayLock` / the
/// ``PausableQueueGate``'s own lock; the PTY/channels are themselves thread-safe.
final class MuxChannelSession: @unchecked Sendable {
    let channelID: UInt32
    let pty: PTYProcess

    /// The session identity the client sent in the `channelOpen` preamble. Used by
    /// ``DetachedSessionStore`` and ``HostServer`` to match a returning client to its live
    /// shell. Immutable after init.
    private(set) var sessionID: UUID

    /// Whether this session is currently in the detached state (client gone, shell alive).
    /// Guarded by `taskLock`. A detached session must NOT be `shutdown()`'d — use
    /// ``detach()`` / ``shutdownDetached()`` from ``DetachedSessionStore.evict`` paths.
    private(set) var isDetached: Bool = false

    // data/control are var so rebindRelay can swap in new sub-channels on reattach (C3/C4).
    private var data: MuxSubChannel
    private var control: MuxSubChannel

    /// The per-session ZDOTDIR shim directory (R8 #3), if the zsh shell-integration shim was
    /// installed for this pane. Deleted in ``shutdown()`` once the child has exited — safe because
    /// the shell read its rc files at exec time. Without this, every opened pane leaked one
    /// `slopdesk-zdotdir-*` dir + 4 files into temp for the host's long-lived lifetime.
    private let shimDir: URL?

    /// W10 — whether host-side Claude-Code agent detection (the foreground process-watch) is
    /// enabled for this channel. When true, ``startRelay()`` spins a low-rate poll that resolves
    /// the PTY's foreground basename and drives ``ForegroundProcessDetector`` → type-26/27.
    private let agentDetectEnabled: Bool

    /// The interval between foreground-process samples (~1 Hz; injected so a future test could
    /// drive it, though the poll itself is never run in a unit test — hang-safety).
    private let agentPollInterval: Duration

    /// LIVE probe of the host's agent-hook listener bind state (queue-safety cluster, 2026-07-02),
    /// injected by ``HostServer`` (`{ agentHookListener?.isListening ?? false }`). Read per
    /// `agentHookStatus` (verb 13) request so the reply reports whether hooks are ACTUALLY flowing,
    /// not just installed on disk. Defaults `false` (no listener wired — the honest answer).
    private let agentHookListenerActive: @Sendable () -> Bool

    /// WB1 — whether the additive "Blocks" tap runs for this channel. When false the byte pipeline
    /// + the live ``HostOutputSniffer`` are byte-identical (the segmenter is never instantiated, no
    /// type-28/29 ever emitted). Resolved from `SLOPDESK_BLOCKS` (default-ON) by the owner.
    private let blocksEnabled: Bool

    /// WB1 — the per-channel "Blocks" tracker (the segmenter + bounded output ring + dedup), or
    /// `nil` when ``blocksEnabled`` is false. Touched from TWO contexts — the serial read-loop
    /// thread (`ingest` in `onChunk`) and the control task (`serveOutput` on a `requestBlockOutput`)
    /// — so it is guarded by ``blocksLock``. A pure value type, so it lives behind the lock.
    private let blocksLock = NSLock()
    private var blockTracker: CommandBlockTracker?

    /// P1 — the SINGLE per-pane Claude detector (ONE ``ClaudeStatusMachine``). Fed by ALL detection
    /// inputs — the foreground poll's `processPresent`, the per-poll `tick` (drives the `.done→.idle`
    /// decay), and the hook socket's bytes — so the host is the single source of truth (review #1/#9).
    /// Touched from TWO contexts (the serial `agentWatchTask` and the socket-accept thread when a hook
    /// POSTs), so it is guarded by `agentDetectLock` — replacing the pre-P1 pair of independent machines
    /// (`foregroundDetector` + `agentHookHandler`) that fought over the one type-27 stream.
    private let agentDetectLock = NSLock()
    private var agentDetector = ClaudePaneDetector()

    /// The foreground-watch poll task (cancel on shutdown).
    private var agentWatchTask: Task<Void, Never>?

    /// E17 / I22 — the pure per-pane PTY-echo edge detector (the AUTO Secure-Keyboard-Entry signal).
    /// Driven by ``PTYEchoProbe`` from TWO contexts — the input task (opportunistically right after a
    /// client keystroke is written to the PTY, where `ECHO` flips fastest around a password prompt) and
    /// the foreground-watch poll (a low-rate backstop, when `agentDetectEnabled`) — so it is guarded by
    /// `echoDetectLock`. Anchored at echo-on, so it is SILENT until the child actually clears `ECHO`
    /// (the CONTROL stream stays byte-identical when no no-echo prompt ever appears).
    private let echoDetectLock = NSLock()
    private var echoDetector = EchoModeDetector()

    /// C3 — connect-time warm-up guard for the echo edge (guarded by `echoDetectLock`). A freshly
    /// connected PTY master can read `ECHO`-cleared for a sample or two right after attach — before the
    /// line discipline settles to echo-on — and folding that transient as a real edge would emit a
    /// spurious `inputEcho(false)` that LATCHES the client's Secure-Input pill on a normal prompt. So
    /// ``foldEchoSample(echoOn:)`` HONORS a no-echo edge only AFTER first observing a confirmed echo-ON
    /// sample. The reattach path (``reestablishEchoOnReattach(echoOn:)``) is SEPARATE — it re-asserts
    /// the current echo truth immediately and is NOT gated by this flag.
    private var echoWarmedUp = false

    // MARK: - Agent-control surface state

    /// The last OSC-0/2 title sniffed from the PTY output stream. Updated on the PTY
    /// read-loop thread under `titleLock`; read by the agent-control `list-panes` verb.
    private let titleLock = NSLock()
    private var _currentTitle: String = ""

    /// Observer closures registered by the agent-control `wait` and `subscribe` verbs. Each is
    /// called with the raw PTY chunk immediately after the sniffer pass (non-destructive, never
    /// modifies the byte stream). Guarded by `observersLock`.
    private let observersLock = NSLock()
    private var outputObservers: [UUID: @Sendable (Data) -> Void] = [:]
    /// Close-observer closures registered by the agent-control `subscribe` verb. Called once,
    /// after the PTY read loop has drained to EOF (so all output observers fire before this),
    /// from the exit task. Guarded by `observersLock`.
    private var closeObservers: [UUID: @Sendable () -> Void] = [:]

    /// E4 — a dedicated serial queue for the host metadata RPC's BLOCKING probe work (git/lsof/proc/
    /// FileManager). Kept OFF the serial control loop so a slow `lsof` / `git` can never stall this
    /// pane's resize/ack/ping; ``enqueueControl`` (lock-guarded) carries the response back. Serial so
    /// concurrent metadata requests for one pane don't pile up subprocesses.
    private let metadataQueue = DispatchQueue(label: "slopdesk.host.metadata", qos: .userInitiated)

    /// ONE fused non-destructive sniffer for the PTY chunk path (title/bell + OSC 133 command
    /// status — one pass, not two per-byte machines scanning the hot thread twice). Touched only
    /// on the read-loop thread via ``ingestPTYChunk(_:)``.
    private let sniffer = HostOutputSniffer()

    /// Disk scrollback journal for this session (nil = disk persistence off). Fed ONLY by
    /// ``ingestPTYChunk(_:)`` — genuine PTY output — so a restored preamble (which enters via the
    /// out-FIFO) is never re-journaled and transcripts don't double across daemon restarts.
    private let scrollbackJournal: ScrollbackJournal?

    /// The prior life's distilled transcript (fresh-spawn restore, `HostServer.spawnFreshShell`).
    /// Enqueued as the FIRST output frame(s) by ``startRelay()`` — before the read loop starts —
    /// so it precedes every live shell byte. `nil`/empty = nothing to restore.
    private let restoredScrollback: Data?

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
        if case let .chunk(nextBytes, _)? = outFIFO.first,
           byteCount + nextBytes.count <= cap
        {
            // Multi-chunk merge: one mutable accumulator, reserve once.
            var merged = Data(capacity: min(cap, byteCount + nextBytes.count))
            merged.append(bytes)
            while case let .chunk(more, moreControl)? = outFIFO.first,
                  byteCount + more.count <= cap
            {
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
    /// LOST-PROMPT FIX: a one-shot, cancel-replace task that re-sends `SIGWINCH` (`pty.nudgeRedraw`) a
    /// short delay AFTER a resize settles. `TIOCSWINSZ` already delivers one SIGWINCH, but that fires
    /// WHILE the client grid is still mid-reflow, so the shell's `zle reset-prompt` redraws into a
    /// transient grid that the final reflow then clears — leaving the prompt line blank with only a bare
    /// cursor. A second nudge once the grid is stable forces the shell/TUI to repaint the prompt at the
    /// final size. Owned by `resizeLock` (same discipline as `resizeDebounceTask`).
    private var redrawNudgeTask: Task<Void, Never>?

    /// Called once when the child exits so the owner can drop this channel from its map.
    var onExit: (@Sendable (UInt32) -> Void)?

    /// P1 supervision hook — fired whenever this pane's detected Claude status TRANSITIONS to a
    /// new value (foreground poll, hook POST, or a self-report). The ``HostServer`` sets it (like
    /// ``onExit``) to fan the cross-pane `agent_status_changed` event to top-level subscribers.
    /// `nil` by default → no fan-out (the headless smoke daemon never sets it). The closure is
    /// invoked OUTSIDE `agentDetectLock` to avoid holding the detector lock across the server's
    /// observer fan-out. Deduping consecutive identical states is the server's responsibility.
    var onAgentStatusChanged: (@Sendable (ClaudeStatus) -> Void)?

    /// Invokes ``onAgentStatusChanged`` (if set) with `status`. Called from the detector-folding
    /// sites AFTER `agentDetectLock` is released, only on a real status transition.
    private func notifyAgentStatusChanged(_ status: ClaudeStatus) {
        onAgentStatusChanged?(status)
    }

    private enum OutputItem {
        case chunk(bytes: Data, control: [WireMessage])
        case exit(code: Int32)
    }

    /// - Parameter resizeDebounce: the latest-wins settle window for `TIOCSWINSZ` applies (default
    ///   ~one frame). See ``scheduleResize(cols:rows:px:py:)`` for WHY a host-side debounce exists.
    /// - Parameter sessionID: the UUID the client included in the `channelOpen` preamble; used by
    ///   ``DetachedSessionStore`` to match a returning client to its detached shell.
    init(
        channelID: UInt32,
        pty: PTYProcess,
        data: MuxSubChannel,
        control: MuxSubChannel,
        sessionID: UUID = UUID(),
        resizeDebounce: Duration = .milliseconds(16),
        replay: ReplayBuffer = MuxChannelSession.makeReplayBuffer(),
        shimDir: URL? = nil,
        agentDetectEnabled: Bool = false,
        agentPollInterval: Duration = .seconds(1),
        agentHookListenerActive: @escaping @Sendable () -> Bool = { false },
        blocksEnabled: Bool = true,
        scrollbackJournal: ScrollbackJournal? = nil,
        restoredScrollback: Data? = nil,
    ) {
        self.channelID = channelID
        self.pty = pty
        self.data = data
        self.control = control
        self.sessionID = sessionID
        self.resizeDebounce = resizeDebounce
        self.replay = replay
        self.shimDir = shimDir
        self.agentDetectEnabled = agentDetectEnabled
        self.agentPollInterval = agentPollInterval
        self.agentHookListenerActive = agentHookListenerActive
        self.blocksEnabled = blocksEnabled
        self.scrollbackJournal = scrollbackJournal
        self.restoredScrollback = restoredScrollback
        // WB1: instantiate the per-channel Blocks tracker only when enabled — otherwise the byte
        // pipeline + sniffer stay byte-identical (no segmenter touches the stream, no emit). E14/K2:
        // the tracker's segmenter carries the resolved auto-progress prefix list (from
        // `SLOPDESK_AUTO_PROGRESS_COMMANDS`, default the built-in slow-command list) so a matched
        // slow command auto-drives a synthetic OSC-9;4 spinner alongside the type-28 block metadata.
        blockTracker = blocksEnabled
            ? CommandBlockTracker(autoProgressPrefixes: HostEnvironment.autoProgressPrefixes())
            : nil
    }

    func startRelay() {
        taskLock.lock()
        guard !started else { taskLock.unlock()
            return
        }
        started = true
        taskLock.unlock()

        let pty = pty
        let data = data
        let control = control
        let masterFD = pty.masterFD

        let (outputWakeups, outputWake) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        fifoLock.lock()
        outputWakeContinuation = outputWake
        fifoLock.unlock()
        outputTask = Task { [weak self] in
            for await _ in outputWakeups {
                // Drain until empty BEFORE re-parking (bufferingNewest(1) holds at most one
                // pending wake — a one-frame-per-wake drain would strand backlog).
                while let frame = self?.takeMergedFrame() {
                    guard let self else { return }
                    switch frame {
                    case let .output(bytes, byteCount, controlMessages):
                        let seq = nextSeq(for: bytes)
                        // `data.send` SUSPENDS on the per-channel credit window, so a flooding
                        // channel naturally slows here. After the write is accepted we dequeue
                        // the bytes and resume the read loop if the FIFO drained below the
                        // bound — dequeue MUST stay post-send (the gate bounds
                        // enqueued-not-yet-SENT; moving it to take-time would let the read
                        // loop refill while a merged frame is still unsent).
                        try? await data.send(.output(seq: seq, bytes: bytes))
                        dequeueOutput(byteCount)
                        // Hand sniffed control to its OWN sender: the data drain never awaits
                        // the control socket (a stalled control link froze data before this).
                        if !controlMessages.isEmpty { enqueueControl(controlMessages) }
                    case let .exit(code):
                        try? await data.send(.exit(code: code))
                        signalExitSent() // R13 #7: release the exit task's await so onExit can run
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
        controlWakeContinuation = controlWake
        controlOutLock.unlock()
        controlSendTask = Task { [weak self] in
            for await _ in controlWakeups {
                while let batch = self?.takeControlBatch() {
                    guard let self else { break }
                    for message in batch {
                        try? await self.control.send(message)
                    }
                }
            }
        }

        let readLoop = PTYReadLoop(
            fd: masterFD,
            onChunk: { [weak self] chunk in self?.ingestPTYChunk(chunk) },
            onEOF: { [weak self] in self?.signalEOFReached() },
        )
        self.readLoop = readLoop
        // FIX #3: build the bounded-queue gate now that the read loop exists, so pause/resume is
        // applied ATOMICALLY with the accounting (no lost-wakeup freeze).
        outputGate = PausableQueueGate(capacity: MuxFlowControl.hostQueueCapacityBytes) { paused in
            readLoop.setPaused(paused)
        }
        // Fresh-spawn history restore MUST land between the gate build (so its bytes are
        // accounted) and the read-loop start (so it precedes every live shell byte).
        enqueueRestoredScrollback()
        readLoop.start()

        // INPUT: the DATA sub-channel carries `input`. The blocking `write(2)` runs on a
        // DEDICATED serial queue (mirroring PTYReadLoop's dedicated read thread): the PTY
        // master fd is deliberately blocking, so a paste into a non-reading foreground
        // program used to park a width-limited COOPERATIVE-POOL thread — a few wedged
        // writers degraded every other pane's drains. Credit is granted only AFTER the
        // write returns (credit-at-consumption), so a stalled PTY transitively parks the
        // CLIENT's sender at one window instead of buffering the paste in host RAM.
        let inputQueue = DispatchQueue(label: "slopdesk.host.pty-input.\(channelID)", qos: .userInitiated)
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
                        // E17/I22: termios ECHO flips fastest around a password prompt — re-probe right
                        // after writing this keystroke so AUTO Secure Keyboard Entry engages with minimal
                        // lag. The detector dedupes, so the steady (echo-on) state emits nothing.
                        self?.sampleEcho(masterFD: masterFD)
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
        // (the client coalescer is the PRIMARY converger, but an old/replayed/slow client may not
        // coalesce). Applying each `TIOCSWINSZ` immediately fires zsh's SIGWINCH handler at every
        // INTERMEDIATE size; its incremental prompt-redraw math desyncs against a size that keeps
        // changing → orphaned cursor / misaligned prompt that only a fresh prompt heals. A LOCAL
        // terminal never hits this because the KERNEL coalesces SIGWINCH. So we restore that:
        // latest-wins micro-debounce on this SERIAL loop — overwrite `pendingResize`, cancel+re-arm
        // ONE debounce task that applies the LATEST size once after a one-frame settle. INLINE on the
        // serial loop (no Task-per-resize → no reorder hazard); only the FREQUENCY of distinct
        // applies is bounded (the ioctl itself, microseconds, stays inline).
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
                    case let .requestBlockOutput(index):
                        // WB1: serve the block's retained output (type 29) from the ring, or an
                        // empty response if evicted / blocks disabled. Orders against nothing — like
                        // a ping, deliberately NO flushPendingResize so it can't defeat the debounce.
                        self.serveBlockOutput(index: index)
                    case let .metadataRequest(requestID, verb, payload):
                        // E4: serve the Details-Panel metadata RPC (type 30) off the metadata queue.
                        // Orders against nothing — like blockOutput, NO flushPendingResize.
                        self.serveMetadata(requestID: requestID, verb: verb, payload: payload)
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
            // Notify close observers (subscribe verb) AFTER the read loop has drained all output
            // to the output observers, so subscribers see a complete output stream before the
            // {"event":"closed"} line. Called here, before enqueueExit, so the ordering matches
            // the output-observer → close-observer → wire-exit sequence.
            self?.notifyCloseObservers()
            self?.enqueueExit(code: code)
            // R13 #7: wait until the drain actually SENT `.exit` on the wire before firing onExit (which
            // triggers shutdown → outputTask.cancel()). Otherwise teardown can cancel the drain before
            // the buffered exit code is flushed, dropping the clean exit status. Bounded + cancellation-
            // aware (shutdown cancels this task), so a dead client / torn-down pane never hangs. Ordering
            // is preserved: `.exit` still follows the tail chunks on the FIFO (the EOF latch above).
            await self?.awaitExitSentOrTimeout()
            self?.onExit?(id)
        }

        // W10: foreground-process watch (Decision #5 PRIMARY signal). A low-rate poll resolves
        // the PTY's foreground basename and folds it through the pure ``ForegroundProcessDetector``,
        // enqueueing the resulting type-26/27 CONTROL messages on a basename edge / status change
        // (the detector dedupes — an idle `claude` does not spam identical frames). The OS probe
        // (`tcgetpgrp`/`proc_pidpath`) is the thin shim; the decision logic is the pure detector.
        // Gated by `agentDetectEnabled` so the headless byte pipeline is byte-identical when off.
        if agentDetectEnabled {
            let interval = agentPollInterval
            agentWatchTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    sampleForeground(masterFD: masterFD)
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
        }
    }

    /// Resolves the PTY's foreground basename via the OS probe, folds it (plus a clock TICK) through the
    /// single ``ClaudePaneDetector``, and enqueues any resulting type-26/27 CONTROL messages. The clock
    /// is the monotonic uptime — a plain `Double` seconds, honouring the no-wall-clock-in-logic
    /// convention (the pure detector takes the time as a parameter; only this driver reads it).
    ///
    /// The per-poll `tick(at:)` is what drives the `.done → .idle` decay (review #4: nobody ticked the
    /// host machine before P1, so a finished turn stayed 🔵 forever). Both folds share the one machine
    /// under `agentDetectLock` (the hook socket-accept thread also folds into it).
    private func sampleForeground(masterFD: Int32) {
        let name = PTYForegroundProbe.foregroundName(masterFD: masterFD)
        let now = ProcessInfo.processInfo.systemUptime
        agentDetectLock.lock()
        // Tick FIRST so the decay is evaluated at this `now`, then the presence sample; both emit
        // type-27 only on a real triple change (the detector dedupes), so at most one status frame ships.
        let tickEmission = agentDetector.tick(at: now)
        let sampleEmission = agentDetector.sample(name: name, at: now)
        // A status transition (from EITHER fold) → notify the cross-pane supervision observer.
        // Both folds share the one machine, so the final `status` is the post-fold value.
        let statusChanged = (tickEmission.status != nil || sampleEmission.status != nil)
        let newStatus = statusChanged ? agentDetector.status : nil
        agentDetectLock.unlock()
        if !tickEmission.isEmpty { enqueueControl(tickEmission.messages) }
        if !sampleEmission.isEmpty { enqueueControl(sampleEmission.messages) }
        if let newStatus { notifyAgentStatusChanged(newStatus) }
        // E17 / I22: ride the same low-rate poll as a BACKSTOP for the PTY-echo edge (a no-echo
        // prompt that appears without a fresh keystroke). The PRIMARY driver is the post-input probe.
        sampleEcho(masterFD: masterFD)
    }

    /// E17 / I22 — probes the PTY master's termios `ECHO` flag via the thin ``PTYEchoProbe`` shim,
    /// folds it through the pure ``EchoModeDetector``, and enqueues a type-31 ``WireMessage/inputEcho``
    /// on the CONTROL sender on an edge (the detector dedupes — an unchanged echo state emits nothing).
    /// Called opportunistically right after writing client input to the PTY (where `ECHO` flips fastest
    /// around a password prompt) and from the foreground poll backstop. Cheap (one `tcgetattr` syscall).
    private func sampleEcho(masterFD: Int32) {
        foldEchoSample(echoOn: PTYEchoProbe.echoEnabled(masterFD: masterFD))
    }

    /// Folds one already-resolved `echoOn` bool through the detector and enqueues a type-31 on an edge
    /// (the detector dedupes — unchanged echo emits nothing). Split out from ``sampleEcho(masterFD:)`` so the
    /// OS probe and the pure fold are separable (the fold is exercised directly by tests via a seam).
    private func foldEchoSample(echoOn: Bool) {
        echoDetectLock.lock()
        // C3: until a confirmed echo-ON sample has been seen on THIS connection, suppress a no-echo
        // reading entirely (don't fold, don't emit) — a transient startup no-echo (termios not yet
        // settled to echo-on) must not latch the client's Secure-Input pill. The first echo-on sample
        // warms the path up; thereafter a genuine echo→no-echo edge folds normally. (Reattach has its
        // own un-gated re-assert path.)
        if !echoWarmedUp {
            guard echoOn else {
                echoDetectLock.unlock()
                return
            }
            echoWarmedUp = true
        }
        let message = echoDetector.sample(echoOn: echoOn)
        echoDetectLock.unlock()
        if let message { enqueueControl([message]) }
    }

    /// E17 / ES-E17-4 — on a client (re)attach, RE-ESTABLISH the client's echo truth. The detector is
    /// edge-triggered against `lastEmitted`, and the client resets `hostNoEcho = false` on reconnect, so if a
    /// no-echo prompt (sudo / ssh / `read -s`) is up ACROSS the reattach the host would see no edge and emit
    /// nothing — leaving the client's AUTO Secure Keyboard Entry disengaged for the rest of the password entry
    /// (keystrokes UNPROTECTED). Echo state is, BY DESIGN, NOT in the replayed output byte stream (it is a host
    /// termios `ECHO` line-discipline attribute carried ONLY as a type-31), so it can be re-established for a
    /// returning client ONLY by a fresh type-31. Re-anchoring the detector to the canonical echo-on baseline
    /// then folding the CURRENT probed echo forces a fresh type-31 iff the live echo still deviates — re-sending
    /// no-echo truth to the freshly-attached client. The re-anchor is the load-bearing step: without it the
    /// re-fold of an unchanged state is a no-op (the ES-E17-4 bug).
    private func reestablishEchoOnReattach(echoOn: Bool) {
        echoDetectLock.lock()
        echoDetector = EchoModeDetector(initialEcho: true)
        let message = echoDetector.sample(echoOn: echoOn)
        echoDetectLock.unlock()
        if let message { enqueueControl([message]) }
    }

    // MARK: - Detach / reattach (tmux-style survival — C1–C4)

    /// Non-destructively detaches the relay from its current client connection.
    ///
    /// **C1 — read loop is NOT stopped.** `PTYReadLoop.stop()` sets a PERMANENT `stopped`
    /// flag (irreversible) and would prevent rebinding. Instead, `setClientOnline(false)`
    /// engages the ReplayBuffer's 4 MiB offline gate which causes `PausableQueueGate` to
    /// pause the read loop via its replay-pause source. The shell stays alive; the loop
    /// parks on the `NSCondition` gate consuming zero syscalls.
    ///
    /// **C2 — onExit is rewired before detach completes** so a shell that exits WHILE IN
    /// THE STORE fires `onDetachedExit` (provided by the caller) instead of the old
    /// `onExit`, which may already have been replaced by the HostServer on a previous
    /// connection. Pass a closure that calls `store.remove(sessionID)` +
    /// `session.shutdownDetached()`.
    func detach(onDetachedExit: @escaping @Sendable (UUID) -> Void) {
        taskLock.lock()
        isDetached = true
        // Rewire onExit (C2): if the child exits while we are in the store, fire the
        // detached-exit handler instead of whatever the previous connection wired.
        let id = sessionID
        onExit = { _ in onDetachedExit(id) }
        // Cancel the relay tasks (input/output/control/controlSend). The exit task is NOT
        // cancelled — it must keep watching the child so onExit fires if the shell dies.
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
        inputTask = nil
        controlTask?.cancel()
        controlTask = nil
        outputTask?.cancel()
        outputTask = nil
        taskLock.unlock()
        // Engage the offline gate so the PTY drain pauses (C1): the read loop parks on its
        // NSCondition and the kernel PTY buffer backpressures the shell.
        setClientOnline(false)
        // Re-size the queue bound for detached life: 64 KiB is a LATENCY bound (head-of-line
        // delay to a consuming client) — with no client it would stall a still-working agent at
        // 64 KiB + one kernel buffer. The detached bound is the "output while away" budget
        // (``MuxFlowControl/detachedHostQueueCapacityBytes``, default 64 MiB); rebindRelay
        // restores the attached sizing.
        outputGate?.setCapacity(MuxFlowControl.detachedHostQueueCapacityBytes)
    }

    /// Rebinds the relay to a fresh pair of sub-channels from a returning client.
    ///
    /// **C3 (revised) — keeps the out-FIFO, clears only control-out.** FIFO chunks are never in
    /// the ReplayBuffer (seq assignment happens at drain time, AFTER the pop), so the FIFO holds
    /// exactly the output produced WHILE DETACHED — the restarted drain ships it after the
    /// caller's `replayTail` (fresh seqs above every replayed seq → byte order preserved) and
    /// dequeues its ``PausableQueueGate`` accounting as it sends, un-pausing a read loop the
    /// detached backlog parked. Control-out IS cleared: control is stateless/re-derived (the
    /// echo truth and block metadata are re-asserted below).
    ///
    /// **onExit atomicity**: `onExit` is assigned INSIDE `taskLock`, BEFORE the new `exitTask`
    /// is started, so the handler installed by `detach()` (which routes to `shutdownDetached`)
    /// can never be the one a reattached exit task fires. The caller MUST pass the new handler
    /// here and must NOT reassign `session.onExit` after this call returns — doing so reopens
    /// the very window this parameter closes.
    ///
    /// - Parameters:
    ///   - newData: The new data sub-channel from the returning client.
    ///   - newControl: The new control sub-channel from the returning client.
    ///   - onExit: The handler the reattached session's exit task must fire. Assigned under
    ///     `taskLock` before `exitTask` is (re)started, making the assignment atomic with the
    ///     task launch and eliminating the race between a racing exit and a post-call assignment.
    ///
    /// - Precondition: `isDetached == true`. A no-op (safe) if called on a live session.
    func rebindRelay(
        data newData: MuxSubChannel,
        control newControl: MuxSubChannel,
        onExit newOnExit: (@Sendable (UInt32) -> Void)?,
    ) {
        taskLock.lock()
        guard isDetached else { taskLock.unlock()
            return
        }
        // Swap the sub-channels.
        data = newData
        control = newControl
        isDetached = false

        // CRITICAL — assign onExit FIRST, while taskLock is still held and BEFORE exitTask is
        // (re)started below. This atomically replaces the detached-exit handler that detach()
        // installed (which calls store.remove + shutdownDetached) with the new reattach handler
        // (which calls removeMuxSession → the new connection's teardown). Without this, a shell
        // that exits between rebindRelay returning and the caller's post-call `session.onExit =`
        // assignment could fire the stale detached-exit handler and kill the just-reattached PTY.
        onExit = newOnExit

        // C3 (revised): the out-FIFO is KEPT, not cleared. Seq assignment / ReplayBuffer retention
        // happens at DRAIN time (`takeMergedFrame` POPS a frame BEFORE `nextSeq` appends it), so no
        // FIFO byte is ever in the ReplayBuffer — the FIFO holds exactly the DETACHED-WINDOW output
        // the read loop produced after detach() cancelled the drain. `replayTail` cannot replay those
        // bytes; clearing them here dropped them permanently (silent transcript gap) AND leaked their
        // PausableQueueGate accounting (no matching dequeue → a ≥64 KiB detached burst left the read
        // loop paused FOREVER — a frozen pane). The restarted drain below ships them with fresh seqs
        // (> every replayed seq → byte order preserved: replay tail first, then detached bytes) and
        // dequeues their gate accounting as it sends, rebalancing a gate-paused read loop. Only
        // `controlOut` is cleared — control is stateless/re-derived (echo truth + block metadata
        // re-asserted below).
        controlOutLock.lock()
        controlOut.removeAll(keepingCapacity: false)
        controlOutLock.unlock()

        // Restore the ATTACHED queue sizing (detach() raised it to the detached budget). With a
        // >64 KiB detached backlog outstanding this immediately re-pauses the read loop; the
        // restarted drain ships the backlog, dequeues its accounting, and resumes it — the exact
        // rebalance the C3 note above describes.
        outputGate?.setCapacity(MuxFlowControl.hostQueueCapacityBytes)

        // Rebuild the output wake stream and restart the output drain task.
        let (outputWakeups, outputWake) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        fifoLock.lock()
        outputWakeContinuation = outputWake
        fifoLock.unlock()
        outputTask = Task { [weak self] in
            for await _ in outputWakeups {
                while let frame = self?.takeMergedFrame() {
                    guard let self else { return }
                    switch frame {
                    case let .output(bytes, byteCount, controlMessages):
                        let seq = nextSeq(for: bytes)
                        try? await data.send(.output(seq: seq, bytes: bytes))
                        dequeueOutput(byteCount)
                        if !controlMessages.isEmpty { enqueueControl(controlMessages) }
                    case let .exit(code):
                        try? await data.send(.exit(code: code))
                        signalExitSent()
                    }
                }
            }
        }

        // Kick the restarted drain ONCE if detached-window chunks are already waiting: their
        // producer-side wakes landed on the FINISHED old continuation (detach() nil'd it), and a
        // shell that has gone idle since produces no future chunk to re-wake the drain — without
        // this the retained backlog (and its gate accounting) would sit undelivered until the next
        // PTY read. bufferingNewest(1) holds the yield until the drain task starts its for-await.
        fifoLock.lock()
        let hasDetachedBacklog = !outFIFO.isEmpty
        let backlogWake = outputWakeContinuation
        fifoLock.unlock()
        if hasDetachedBacklog { backlogWake?.yield(()) }

        // Rebuild the control wake stream and restart the control sender.
        let (controlWakeups, controlWake) =
            AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        controlOutLock.lock()
        controlWakeContinuation = controlWake
        controlOutLock.unlock()
        controlSendTask = Task { [weak self] in
            for await _ in controlWakeups {
                while let batch = self?.takeControlBatch() {
                    guard let self else { break }
                    for message in batch {
                        try? await control.send(message)
                    }
                }
            }
        }

        // E17 / ES-E17-4 — RE-ESTABLISH the client's echo truth on reattach (mirrors how the PTY size is
        // re-asserted on reconnect): re-anchor the edge-triggered detector and re-emit a fresh type-31 for the
        // CURRENT probed echo so a no-echo prompt that is up across this reattach re-engages the client's AUTO
        // Secure Keyboard Entry (which reset to echo-on on reconnect). Done AFTER the `controlOut.removeAll()`
        // above (so the fresh type-31 is not wiped) and AFTER the control sender + its wake continuation are
        // rebuilt above (so the `enqueueControl` wake is delivered and drained, not dropped onto a nil
        // continuation). See ``reestablishEchoOnReattach(echoOn:)`` for the full rationale.
        reestablishEchoOnReattach(echoOn: PTYEchoProbe.echoEnabled(masterFD: pty.masterFD))

        // WB / reattach — RE-SEND the held blocks' metadata so the returning client rebuilds its
        // Commands/Outline navigator (block metadata rides the control channel and is not in the replayed
        // output byte stream). Done AFTER the `controlOut.removeAll()` and control-sender rebuild above so
        // the backfill is enqueued onto the live wake continuation, mirroring the echo re-assert.
        resendBlocksOnReattach()

        // Restart the input task (reads from the NEW data sub-channel).
        let masterFD = pty.masterFD
        let localChannelID = channelID
        let inputQueue = DispatchQueue(
            label: "slopdesk.host.pty-input.\(localChannelID).rebind", qos: .userInitiated,
        )
        inputTask = Task.detached { [weak self] in
            do {
                for try await message in newData.inbound {
                    if case let .input(bytes) = message {
                        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                            inputQueue.async {
                                Self.writeAll(fd: masterFD, data: bytes)
                                done.resume()
                            }
                        }
                        // E17/I22: re-probe termios ECHO right after writing input on the reattached
                        // channel too (same rationale as the live relay) — AUTO Secure Keyboard Entry
                        // must keep working after a reconnect. The detector dedupes the steady state.
                        self?.sampleEcho(masterFD: masterFD)
                    }
                    await newData.noteConsumed(message.wireByteCount)
                }
            } catch {}
            self?.setClientOnline(false)
        }

        // Restart the control task (reads from the NEW control sub-channel).
        controlTask = Task { [weak self] in
            do {
                for try await message in newControl.inbound {
                    switch message {
                    case let .resize(cols, rows, px, py):
                        self?.scheduleResize(cols: cols, rows: rows, px: px, py: py)
                    case let .ack(seq):
                        self?.flushPendingResize()
                        self?.acknowledge(upTo: seq)
                    case .bye:
                        self?.flushPendingResize()
                    case let .ping(timestampMS):
                        self?.enqueueControl([.pong(timestampMS: timestampMS)])
                    case let .requestBlockOutput(index):
                        self?.serveBlockOutput(index: index)
                    case let .metadataRequest(requestID, verb, payload):
                        // E4: serve the metadata RPC on the rebind (reattach) loop too — without this
                        // the Details Panel silently dies after a reconnect (the type-26/27 + blockOutput
                        // duplicated-case shape). Orders against nothing — NO flushPendingResize.
                        self?.serveMetadata(requestID: requestID, verb: verb, payload: payload)
                    default:
                        self?.flushPendingResize()
                    }
                }
            } catch {}
            self?.flushPendingResize()
        }

        // Restart the exit task ONLY if the child is still alive (C2: if it exited while
        // detached, onExit was already rewired to fire the detached-exit handler; we must
        // not start a second exit task that double-fires onExit on the SAME channel ID).
        //
        // onExit was assigned above (under taskLock) BEFORE this task is started, so the
        // reattach handler is atomically in place when the exit task can first fire. The task
        // captures `rebindChannelID` (not `self.channelID`) to avoid retaining `self` strongly
        // through the channel property.
        if !isChildExited() {
            let rebindChannelID = channelID
            let rebindPTY = pty // local capture so the task does not capture `self` strongly
            exitTask?.cancel()
            exitTask = Task { [weak self] in
                let code = await rebindPTY.waitForExit()
                await self?.awaitEOFOrTimeout()
                self?.enqueueExit(code: code)
                await self?.awaitExitSentOrTimeout()
                self?.onExit?(rebindChannelID)
            }
        }

        // R2 (benign): agentWatchTask was NOT cancelled by detach() — it survives the detached
        // window so the poll keeps running. But its control wake continuation was finished by
        // detach(), so any agent-status update emitted WHILE DETACHED is dropped (nil continuation).
        // The new continuation rebuilt above carries future updates; a brief stale status until the
        // next poll tick (~1 s) is acceptable. A nudge here would need sampleForeground exported to
        // run after unlock — not worth the risk vs. the natural 1-s poll cadence.

        taskLock.unlock()

        // R1 (safe): setClientOnline(true) is called just AFTER taskLock is released so it can
        // acquire replayLock without nesting locks. The wake it triggers goes to the new
        // outputWakeContinuation (rebuilt inside taskLock above with bufferingNewest(1)), so the
        // wake is retained even if the drain task hasn't started its `for await` loop yet —
        // bufferingNewest(1) holds one pending yield. No output is lost.
        setClientOnline(true)
    }

    /// Pumps the ReplayBuffer tail (`seq > lastReceivedSeq`) into `channel` as sequential
    /// `output` wire messages — the reconnect replay that brings the returning client up to date.
    ///
    /// Called BEFORE ``rebindRelay`` starts the live drain so the tail is delivered in order
    /// without interleaving live output. Non-blocking: iterates the already-retained entries
    /// (O(N) over the retained tail) without any timer or suspension point between frames.
    func replayTail(after lastReceivedSeq: Int64, on channel: MuxSubChannel) async {
        let messages = snapshotReplayTail(after: lastReceivedSeq)
        for message in messages {
            try? await channel.send(message)
        }
    }

    /// Synchronously snapshots the ReplayBuffer tail under `replayLock` (NSLock is unavailable
    /// from the async ``replayTail(after:on:)`` directly — same discipline as ``rebindRelay``).
    private func snapshotReplayTail(after lastReceivedSeq: Int64) -> [WireMessage] {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replay.replay(after: lastReceivedSeq)
    }

    /// Non-blocking check: returns `true` if the child shell has already exited (been reaped
    /// by `PTYProcess.startReaper`). Used by ``DetachedSessionStore/lookup(_:)`` and
    /// ``rebindRelay`` to avoid reattaching to a dead shell (PATH C → spawn fresh).
    func isChildExited() -> Bool {
        pty.waitExitCode() != nil
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
        agentWatchTask?.cancel() // W10: stop the foreground-process poll
        agentWatchTask = nil
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
        let nudgeTask = redrawNudgeTask
        redrawNudgeTask = nil
        resizeLock.unlock()
        resizeTask?.cancel()
        nudgeTask?.cancel()
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
        // host's temp dir does not accumulate one `slopdesk-zdotdir-*` dir per opened pane forever.
        if let shimDir { try? FileManager.default.removeItem(at: shimDir) }
    }

    /// A serial-safe BACKGROUND queue for the blocking ``shutdown()`` work, kept OFF the cooperative
    /// thread pool / the mux connection's receive loop. `concurrent` so simultaneous channel teardowns
    /// (a multi-pane link drop) tear down in parallel rather than ~0.5s × N serially.
    static let teardownQueue = DispatchQueue(
        label: "slopdesk.host.session-shutdown", qos: .utility, attributes: .concurrent,
    )

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
        Self.teardownQueue.async { [self] in
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
            flushPendingResize(ifGeneration: generation)
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
        if let generation, resizeGeneration != generation { resizeLock.unlock()
            return
        }
        guard let r = pendingResize else { resizeLock.unlock()
            return
        }
        pendingResize = nil
        resizeLock.unlock()
        pty.setWindowSize(cols: r.cols, rows: r.rows, pxWidth: r.px, pxHeight: r.py)
        scheduleRedrawNudge()
    }

    /// Schedules a single delayed `SIGWINCH` (cancel-replace) so the shell repaints its prompt AFTER the
    /// client grid has settled at the new size (see `redrawNudgeTask`). Each resize cancels the prior
    /// pending nudge, so a drag emits exactly one nudge — at the final size. Same lock discipline as
    /// `scheduleResize`; `nudgeRedraw` is internally fd-locked and a no-op on a closed PTY.
    private func scheduleRedrawNudge() {
        resizeLock.lock()
        redrawNudgeTask?.cancel()
        redrawNudgeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(90))
            } catch {
                return // superseded by a newer resize before firing — that resize schedules its own nudge.
            }
            self?.pty.nudgeRedraw()
        }
        resizeLock.unlock()
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

    /// The PTY read-loop chunk handler (runs on the read-loop thread, serial). Factored out of
    /// the `onChunk` closure so the disk-journal + sniffer + FIFO path is drivable headlessly
    /// (no PTY) via ``ingestPTYChunkForTesting(_:)``.
    private func ingestPTYChunk(_ chunk: Data) {
        // Disk journal FIRST (fire-and-forget onto the journal's serial queue — no file I/O on
        // this hot thread). Only genuine PTY output lands here, so the restored preamble (which
        // enters via ``enqueueRestoredScrollback()``) is never re-journaled.
        scrollbackJournal?.append(chunk)
        // ONE fused non-destructive sniffer pass over the chunk (title/bell + OSC 133
        // command status — one pass, not two per-byte machines scanning this hot thread
        // twice). It only OBSERVES; the bytes are forwarded unchanged below. Emission
        // order is byte-faithful interleaved (consumers fold each type independently).
        let controlMsgs = sniffer.observe(chunk)
        // Agent-control: cache the latest title from any sniffed title message so
        // `list-panes` can return it without an extra sniffer pass. Runs on the PTY
        // read-loop thread (serial) — update under titleLock (read from control socket
        // handler threads). O(N) over the tiny `controlMsgs` list; happens at most once
        // per chunk (title dedup is inside HostOutputSniffer).
        for msg in controlMsgs {
            if case let .title(t) = msg {
                titleLock.lock()
                _currentTitle = t
                titleLock.unlock()
            }
        }
        // Agent-control: fire output observers for the `wait` verb AFTER the sniffer
        // (so a wait-observer sees the same stream order as the client) and BEFORE the
        // FIFO append (non-destructive — observers only READ the chunk).
        notifyOutputObservers(chunk)
        // WB1: ADDITIVE PARALLEL tap — feed the SAME chunk to the per-channel Blocks
        // segmenter and enqueue any type-28 `commandBlock` metadata on the CONTROL sender.
        // Only OBSERVES; the bytes below are forwarded unchanged. `nil` when SLOPDESK_BLOCKS
        // is off, so the pipeline stays byte-identical. Kept OFF the data drain (its own
        // CONTROL FIFO) so block metadata never stalls data sends.
        feedBlocks(chunk)
        // Account the chunk in the bounded queue BEFORE enqueueing; if it pushes the FIFO
        // to/over the bound, PAUSE the read loop so the kernel PTY buffer fills and
        // backpressures the shell (the real flood fix).
        enqueueOutput(chunk.count)
        // Append-then-yield (no lost wake): the pending bufferingNewest(1) wake always
        // observes a complete FIFO. The continuation is read under fifoLock (teardown
        // nils it); yield happens OUTSIDE the lock (it may resume the drain inline).
        fifoLock.lock()
        outFIFO.append(.chunk(bytes: chunk, control: controlMsgs))
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

    /// Fresh-spawn history restore: enqueues the prior life's transcript as the FIRST output
    /// frame, through the normal drain (so it is sequenced into the new ReplayBuffer and rides
    /// ordinary `.output` messages — no wire change). Called by ``startRelay()`` AFTER the
    /// bounded-queue gate exists (the bytes are accounted like any chunk; a >64 KiB preamble
    /// simply starts the read loop paused until the drain ships it) and BEFORE the read loop
    /// starts, so it precedes every live shell byte.
    private func enqueueRestoredScrollback() {
        guard let restored = restoredScrollback, !restored.isEmpty else { return }
        enqueueOutput(restored.count)
        fifoLock.lock()
        outFIFO.append(.chunk(bytes: restored, control: []))
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

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

    /// W10 — ingests one received Claude-hook record (raw POST body bytes) for THIS pane and, if it
    /// produced a status change, enqueues the resulting type-27 on the CONTROL sender. Folds through the
    /// SAME ``ClaudePaneDetector`` the foreground poll drives (P1 single source of truth — no second
    /// machine), under `agentDetectLock` because the socket-accept thread is a different context than the
    /// watch task. Validate-then-drop: malformed bytes are silently ignored. The clock is monotonic
    /// uptime (a plain `Double`; the decision logic is in the pure detector, which takes the time).
    func ingestAgentHookRecord(_ bytes: Data) {
        agentDetectLock.lock()
        let emission = agentDetector.hook(bytes: bytes, at: ProcessInfo.processInfo.systemUptime)
        let changed = emission.status != nil ? agentDetector.status : nil
        agentDetectLock.unlock()
        if !emission.isEmpty { enqueueControl(emission.messages) }
        if let changed { notifyAgentStatusChanged(changed) }
    }

    /// Folds an AGENT SELF-REPORT (the P1 `report` ctl verb) into the ONE ``ClaudePaneDetector``
    /// under `agentDetectLock`. The state string has already been validated by the caller; an
    /// unrecognised string is a no-op inside the detector (validate-then-drop). Any resulting
    /// type-27 is enqueued to the (possibly absent) client AND fans the cross-pane
    /// `agent_status_changed` observer (P1 supervision stream) on a real transition.
    func reportAgentStatusForControl(state: String, message: String?) {
        agentDetectLock.lock()
        let emission = agentDetector.report(
            state: state, message: message, at: ProcessInfo.processInfo.systemUptime,
        )
        let changed = emission.status != nil ? agentDetector.status : nil
        agentDetectLock.unlock()
        if !emission.isEmpty { enqueueControl(emission.messages) }
        if let changed { notifyAgentStatusChanged(changed) }
    }

    // MARK: - Agent-control surface (public primitives used by AgentControlListener)

    /// Writes `bytes` to the PTY master fd (control-plane input injection).
    ///
    /// Fire-and-forget on a background queue: the blocking `write(2)` on a stalled PTY must
    /// NOT park the control socket's per-connection handler thread (it serves other verbs).
    /// Uses the same `writeAll` helper the regular input task uses (handles `EINTR`, partial writes).
    /// Validate-then-drop: an empty slice or a closed PTY master fd is silently ignored.
    func writeRawForControl(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let masterFD = pty.masterFD
        guard masterFD >= 0 else { return }
        // Hop off the caller's thread: `write(2)` on a blocking master fd may park when the PTY
        // kernel buffer is full (shell not reading), so a stalled shell must not block the listener.
        DispatchQueue.global(qos: .utility).async {
            Self.writeAll(fd: masterFD, data: bytes)
        }
    }

    /// Resizes the PTY for the agent-control `resize` verb.
    ///
    /// Delegates directly to ``PTYProcess/setWindowSize(cols:rows:pxWidth:pxHeight:)`` which
    /// performs `TIOCSWINSZ` under `exitLock` (TOCTOU-safe, non-blocking O(1) ioctl). The
    /// kernel delivers `SIGWINCH` to the PTY's foreground process group automatically as part
    /// of the `TIOCSWINSZ` call on macOS — no separate `kill`/`killpg` call is needed.
    ///
    /// Called on the control socket's per-connection handler thread. Safe to call there:
    /// `setWindowSize` is documented non-blocking and the lock held (``PTYProcess/exitLock``)
    /// is never contended from this path (it guards PTY-fd lifetime, not application state).
    func resizeForControl(rows: UInt16, cols: UInt16) {
        pty.setWindowSize(cols: cols, rows: rows)
    }

    /// Returns a plain-text snapshot of the ReplayBuffer scrollback (all acked + live tail).
    ///
    /// Joins every stored output chunk in sequence order, converts to UTF-8 (replacing invalid
    /// sequences with `?`), then optionally strips ANSI escape codes via ``ANSIStripper``.
    /// The snapshot is taken under `replayLock` (same discipline as `snapshotReplayTail`).
    func scrollbackTextForControl(ansiStrip: Bool = true) -> String {
        replayLock.lock()
        let messages = replay.messages(after: 0)
        replayLock.unlock()
        var data = Data()
        for m in messages { data.append(m.bytes) }
        let text: String =
            if let utf8 = String(bytes: data, encoding: .utf8) {
                utf8
            } else {
                String(data.map { $0 < 0x80 ? $0 : UInt8(0x3F) }.map { Character(UnicodeScalar($0)) })
            }
        return ansiStrip ? ANSIStripper.strip(text) : text
    }

    /// Returns the pane's scrollback as an array of LOGICAL lines (P1 `read --unwrapped`).
    ///
    /// The host keeps NO screen buffer and the scrollback ring stores RAW PTY read-chunk byte
    /// slices (NOT terminal-width-aware lines), so TRUE reverse-of-terminal-wrapping is impossible
    /// host-side — a soft-wrapped visual row carries no marker to un-wrap. What this DOES give an
    /// agent regex is robustness to arbitrary read-CHUNK / transport boundaries: it joins every
    /// stored chunk in seq order (so a hard line split across two chunks is one string),
    /// ANSI-strips (same as ``scrollbackTextForControl(ansiStrip:)``), then splits on the hard
    /// `\n` into logical lines. A partial (no trailing newline) last line is DROPPED so a regex
    /// never matches a half-written prompt. When `lines` is non-nil, only the last N are returned.
    func recentUnwrappedTextForControl(lines limit: Int? = nil) -> [String] {
        let text = scrollbackTextForControl(ansiStrip: true)
        return Self.unwrapLogicalLines(text, lines: limit)
    }

    /// Pure logical-line split (P1 `read --unwrapped`): split `text` on hard `\n`, keep blank
    /// lines, and optionally keep only the last `limit`. Extracted as a `static` so it is
    /// unit-testable with no PTY/ReplayBuffer.
    ///
    /// Trailing-element handling (review finding): only DROP the final element when the text ended
    /// in `\n` (so the split's trailing `""` is a separator artifact, not content). When the text
    /// does NOT end in `\n`, the final element is a complete-but-unterminated logical line — which
    /// host-side is INDISTINGUISHABLE from the very signal an orchestrator scrapes (a live shell
    /// prompt or a Claude "awaiting input" line that carries no trailing newline). Dropping it
    /// unconditionally silently swallowed the freshest line, so we KEEP it. (A genuine half-written
    /// partial is rare and harmless to include; losing the prompt is the worse failure.)
    static func unwrapLogicalLines(_ text: String, lines limit: Int? = nil) -> [String] {
        guard !text.isEmpty else { return [] }
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop ONLY the empty trailing artifact of a terminating newline; keep an unterminated
        // final logical line (the prompt / awaiting-input cue).
        if text.hasSuffix("\n"), !rows.isEmpty, rows[rows.count - 1].isEmpty {
            rows.removeLast()
        }
        if let limit, limit > 0, rows.count > limit { rows = Array(rows.suffix(limit)) }
        return rows
    }

    /// The last OSC-sniffed window title for this pane (empty string if none has arrived yet).
    var currentTitle: String {
        titleLock.lock()
        defer { titleLock.unlock() }
        return _currentTitle
    }

    /// The current rolled-up Claude detection status for this pane (P1 supervision API).
    ///
    /// Read under `agentDetectLock` because `agentDetector` is folded from TWO contexts (the
    /// serial `agentWatchTask` foreground poll and the hook socket-accept thread); a bare read
    /// of the private detector would race. Used by ``HostServer/listPanesForControl()`` to surface
    /// per-pane agent state in the `list-panes` verb. A pane whose detector never saw `claude`
    /// returns ``ClaudeStatus/none``.
    var agentStatusForControl: ClaudeStatus {
        agentDetectLock.lock()
        defer { agentDetectLock.unlock() }
        return agentDetector.status
    }

    /// Registers an output observer for the `wait` verb. The closure is called from the PTY
    /// read-loop thread with each raw output chunk immediately after sniffer processing. The
    /// observer must be non-blocking and short-running (it runs on the read-loop thread).
    /// Replaces any prior observer for the same `id` (idempotent).
    func registerOutputObserver(id: UUID, _ observer: @escaping @Sendable (Data) -> Void) {
        observersLock.lock()
        outputObservers[id] = observer
        observersLock.unlock()
    }

    /// Removes the observer registered under `id`. Idempotent (a missing id is a no-op).
    func removeOutputObserver(id: UUID) {
        observersLock.lock()
        outputObservers[id] = nil
        observersLock.unlock()
    }

    /// Registers a close observer for the `subscribe` verb. Called once when the PTY exits
    /// (after EOF has been drained through the output observers). Replaces any prior observer
    /// for the same `id` (idempotent).
    func registerCloseObserver(id: UUID, _ observer: @escaping @Sendable () -> Void) {
        observersLock.lock()
        closeObservers[id] = observer
        observersLock.unlock()
    }

    /// Removes the close observer registered under `id`. Idempotent.
    func removeCloseObserver(id: UUID) {
        observersLock.lock()
        closeObservers[id] = nil
        observersLock.unlock()
    }

    /// Calls all registered close observers. Called from the exit task after EOF drains.
    private func notifyCloseObservers() {
        observersLock.lock()
        let observers = closeObservers
        observersLock.unlock()
        for (_, observer) in observers { observer() }
    }

    /// Calls all registered output observers with `chunk`. Called from `onChunk` on the
    /// PTY read-loop thread (serial) — snapshot the dict under lock, then call outside.
    private func notifyOutputObservers(_ chunk: Data) {
        observersLock.lock()
        let observers = outputObservers
        observersLock.unlock()
        for (_, observer) in observers { observer(chunk) }
    }

    /// WB1 — feeds one outbound chunk to the per-channel Blocks tracker (under ``blocksLock``) and
    /// enqueues any resulting type-28 `commandBlock` metadata on the CONTROL sender. A no-op when
    /// blocks are disabled (`blockTracker == nil`), so the byte pipeline stays byte-identical.
    private func feedBlocks(_ chunk: Data) {
        guard blocksEnabled else { return }
        blocksLock.lock()
        let messages = blockTracker?.ingest(chunk) ?? []
        blocksLock.unlock()
        if !messages.isEmpty { enqueueControl(messages) }
    }

    /// WB / reattach — RE-SENDS every block the tracker still holds (its metadata) as a burst of type-28
    /// `commandBlock` messages on the CONTROL channel, so a client that (re)attaches to an already-running
    /// session rebuilds its Commands/Outline navigator. Block metadata rides the control channel and is
    /// NEVER replayed by the ReplayBuffer (only raw `.output` is sequenced), so a returning client would
    /// otherwise show an EMPTY navigator even though the host still holds every block. Mirrors
    /// ``reestablishEchoOnReattach`` (echo truth is likewise control-only and re-anchored on reattach).
    /// A no-op when blocks are disabled. Output bytes are fetched on demand (type 15 → 29); this restores
    /// the list only.
    private func resendBlocksOnReattach() {
        guard blocksEnabled else { return }
        blocksLock.lock()
        let messages = blockTracker?.snapshotForResync() ?? []
        blocksLock.unlock()
        if !messages.isEmpty { enqueueControl(messages) }
    }

    /// WB1 — serves a `requestBlockOutput(index)` by enqueueing the block's retained output (type
    /// 29) from the ring on the CONTROL sender. Always replies (an EMPTY `blockOutput` when the
    /// block was evicted / never existed / blocks are disabled) so the client never hangs waiting.
    private func serveBlockOutput(index: UInt32) {
        blocksLock.lock()
        let message = blockTracker?.serveOutput(index: index) ?? .blockOutput(index: index, output: Data())
        blocksLock.unlock()
        enqueueControl([message])
    }

    /// E4 — serves a `metadataRequest(requestID:verb:payload:)` by running the PURE
    /// ``MetadataResponseBuilder`` over THIS pane's ``HostMetadataProbe`` (its `masterFD` + shell pid)
    /// and enqueueing the resulting type-30 `metadataResponse` on the CONTROL sender. The probe's
    /// git/lsof/proc work is BLOCKING, so it runs on ``metadataQueue`` (OFF the serial control loop) —
    /// a slow query must never stall this pane's resize/ack/ping. ALWAYS replies (the builder maps any
    /// failure — unknown verb / confinement rejection / missing cwd / query-nil — to a status byte +
    /// empty payload), so the client's ``MetadataRequestRegistry`` never hangs waiting. Orders against
    /// nothing (like a ping / blockOutput) — deliberately NO `flushPendingResize`.
    private func serveMetadata(requestID: UInt32, verb: UInt8, payload: Data) {
        let masterFD = pty.masterFD
        let shellPID = pty.pid
        metadataQueue.async { [weak self] in
            guard let self else { return }
            // E10 WI-7: the side-effecting path verbs (openPath = 9 / revealPath = 10) actuate on the
            // HOST's own Finder / Launch Services via `HostPathActionPerformer` and reply with an
            // empty-payload status. They are handled HERE — BEFORE, and never reach, the read-only
            // `MetadataResponseBuilder` (which performs NO side effects). `response` returns nil for
            // every OTHER verb, so the read verbs fall through to the pure builder unchanged.
            if let response = HostPathActionPerformer.response(requestID: requestID, verb: verb, payload: payload) {
                enqueueControl([response])
                return
            }
            // E13 WI-1: the agent-hooks verbs (installAgentHooks = 11 / uninstallAgentHooks = 12 write or
            // strip our entries in ~/.claude/settings.json via `AgentInstaller`; agentHookStatus = 13 is a
            // pure read returning the 2-byte `[installed][listenerActive]` flags — the second byte is the
            // LIVE hook-listener bind state so the client can show installed-but-inactive, queue-safety
            // cluster 2026-07-02). Handled HERE — BEFORE, and never reaching, the read-only
            // `MetadataResponseBuilder`. `response` returns nil for every OTHER verb, so the read verbs
            // fall through to the pure builder unchanged.
            if let response = HostAgentActionPerformer.response(
                requestID: requestID, verb: verb, payload: payload,
                hookListenerActive: agentHookListenerActive(),
            ) {
                enqueueControl([response])
                return
            }
            let probe = HostMetadataProbe(masterFD: masterFD, shellPID: shellPID)
            let response = MetadataResponseBuilder(query: probe)
                .response(requestID: requestID, verb: verb, payload: payload)
            enqueueControl([response])
        }
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
    private func signalEOFReached() { eofLock.lock()
        eofReached = true
        eofLock.unlock()
    }

    private func isEOFReached() -> Bool { eofLock.lock()
        defer { eofLock.unlock() }
        return eofReached
    }

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

    private func signalExitSent() { exitSentLock.lock()
        exitSent = true
        exitSentLock.unlock()
    }

    private func isExitSent() -> Bool { exitSentLock.lock()
        defer { exitSentLock.unlock() }
        return exitSent
    }

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

    // MARK: - Scrollback env resolution

    /// Resolves a `ReplayBuffer` from the scrollback env vars, called once at channel-open time.
    ///
    /// - `SLOPDESK_SCROLLBACK_PERSIST` — default-ON (`env != "0"`). When `"0"`, the scrollback
    ///   ring is disabled (cap = 0), disabling cold-reattach scrollback replay.
    /// - `SLOPDESK_SCROLLBACK_BYTES` — integer byte cap for the ring. Defaults to
    ///   `ReplayBuffer.defaultScrollbackBytes` (4 MiB). Ignored when scrollback persist is off.
    /// - `SLOPDESK_SCROLLBACK_DISTILL` — default-ON (`env != "0"`). When ON, a ``ScrollbackDistiller``
    ///   is injected so a COLD-reattach scrollback replay collapses the transient B→C line-editor churn
    ///   (tab-completion menus, autosuggestions, per-keystroke redraws) to the committed OSC-133 command
    ///   line — the fresh terminal then re-renders a clean transcript instead of raw editing artifacts.
    ///   Set `"0"` to replay the raw scrollback bytes (the pre-distiller behaviour).
    /// - `SLOPDESK_SCROLLBACK_STRIP_QUERIES` — default-ON (`env != "0"`). When ON, a
    ///   ``TerminalQueryStripper`` pass removes terminal queries / echoed responses / stale color
    ///   state from the replayed history, so the client terminal never re-answers a prior life's
    ///   DA/XTVERSION/OSC-color probes into the shell's stdin (the reattach "garbage input" bug).
    static func makeReplayBuffer() -> ReplayBuffer {
        let env = ProcessInfo.processInfo.environment
        let persist = env["SLOPDESK_SCROLLBACK_PERSIST"] != "0"
        let scrollbackCap: Int =
            if !persist {
                0
            } else if let raw = env["SLOPDESK_SCROLLBACK_BYTES"], let parsed = Int(raw), parsed >= 0 {
                parsed
            } else {
                ReplayBuffer.defaultScrollbackBytes
            }
        // Distill + query-strip composition — shared with the disk journal's restore so both
        // replay paths stay behaviour-identical (see ``ScrollbackReplayTransform``).
        return ReplayBuffer(
            scrollbackBytes: scrollbackCap,
            scrollbackDistiller: ScrollbackReplayTransform.make(environment: env),
        )
    }

    // MARK: - Test seams (replay-backpressure wiring, R5 rank 2)

    // These drive the append/ack/online glue against a real ``PausableQueueGate`` WITHOUT a PTY or
    // read loop, so the "retained ≥ cap → pause; ack → resume" wiring is provable headlessly. Reached
    // via `@testable import`; never used in production.

    /// Installs a gate to receive the replay-pause signal (production builds it in ``startRelay()``).
    func installGateForTesting(_ gate: PausableQueueGate) { outputGate = gate }
    /// Drives the real ``nextSeq(for:)`` glue (append + recompute + gate). Returns the assigned seq.
    @discardableResult
    func appendForTesting(_ bytes: Data) -> Int64 { nextSeq(for: bytes) }
    /// Drives the real ``acknowledge(upTo:)`` glue (ack + recompute + gate).
    func ackForTesting(upTo seq: Int64) { acknowledge(upTo: seq) }
    /// Drives the real ``setClientOnline(_:)`` glue (offline-gate side).
    func setClientOnlineForTesting(_ online: Bool) { setClientOnline(online) }

    /// Exit-ordering EOF latch seams (R5 rank 5).
    func signalEOFForTesting() { signalEOFReached() }
    func isEOFReachedForTesting() -> Bool { isEOFReached() }
    func awaitEOFForTesting(timeout: Duration) async { await awaitEOFOrTimeout(timeout) }

    /// Exit-sent latch seams (R13 #7) — the drain signals once `.exit` is on the wire; the exit task
    /// awaits it before firing onExit so teardown can't cancel the drain before the exit code is sent.
    func signalExitSentForTesting() { signalExitSent() }
    func isExitSentForTesting() -> Bool { isExitSent() }
    func awaitExitSentForTesting(timeout: Duration) async { await awaitExitSentOrTimeout(timeout) }

    /// Drain-merge seams: drive the output FIFO + ``takeMergedFrame()`` (and the control-out
    /// queue) WITHOUT a PTY or running drain, so merge/barrier/cap semantics are provable
    /// headlessly. The enqueue paths mirror the production producers exactly (append under
    /// the lock; the wake yield is a no-op pre-`startRelay` since the continuation is nil).
    /// Drives the REAL PTY chunk handler (disk-journal hook + sniffer + FIFO append) without a
    /// PTY or read loop — the production `onChunk` closure is exactly this call.
    func ingestPTYChunkForTesting(_ chunk: Data) { ingestPTYChunk(chunk) }

    /// Drives the REAL fresh-spawn restore enqueue (the exact call ``startRelay()`` makes)
    /// without needing a spawned PTY's master fd.
    func enqueueRestoredScrollbackForTesting() { enqueueRestoredScrollback() }

    func enqueueChunkForTesting(bytes: Data, control: [WireMessage] = []) {
        enqueueOutput(bytes.count)
        fifoLock.lock()
        outFIFO.append(.chunk(bytes: bytes, control: control))
        let wake = outputWakeContinuation
        fifoLock.unlock()
        wake?.yield(())
    }

    func enqueueExitForTesting(code: Int32) { enqueueExit(code: code) }
    func enqueueControlForTesting(_ messages: [WireMessage]) { enqueueControl(messages) }
    func takeControlBatchForTesting() -> [WireMessage]? { takeControlBatch() }
    static var maxControlOutQueuedForTesting: Int { maxControlOutQueued }

    /// E17 / ES-E17-4 echo seams — drive the pure echo fold and the reattach re-establishment with an
    /// INJECTED `echoOn` (no PTY probe), so the edge-trigger dedupe AND the reattach re-emit are provable
    /// headlessly via ``takeControlBatchForTesting()``. ``reestablishEchoOnReattachForTesting`` exercises the
    /// EXACT production method ``rebindRelay`` calls, so reverting its re-anchor breaks both together.
    func foldEchoSampleForTesting(echoOn: Bool) { foldEchoSample(echoOn: echoOn) }
    func reestablishEchoOnReattachForTesting(echoOn: Bool) { reestablishEchoOnReattach(echoOn: echoOn) }

    /// WB1 — drive the real `feedBlocks` glue (segmenter tap → enqueueControl) WITHOUT a PTY/read
    /// loop, so the type-28 emission + the byte-identical-when-off contract are provable headlessly.
    func feedBlocksForTesting(_ chunk: Data) { feedBlocks(chunk) }
    /// WB1 — drive the real `serveBlockOutput` glue (ring lookup → enqueueControl).
    func serveBlockOutputForTesting(index: UInt32) { serveBlockOutput(index: index) }
    /// WB1 — whether the Blocks tap is active for this channel (the tracker was instantiated).
    var blocksEnabledForTesting: Bool { blocksEnabled }

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
