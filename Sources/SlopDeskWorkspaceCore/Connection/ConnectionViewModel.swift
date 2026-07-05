import Foundation
import SlopDeskClient
import SlopDeskProtocol

/// Orchestrates a ``SlopDeskClient`` + ``ReconnectManager`` for the UI: host/port entry,
/// connect/disconnect, and a live status the chrome renders.
///
/// It owns the connect lifecycle so the views stay declarative:
/// - ``connect()`` stands up the client, starts the reconnect supervisor, kicks off the
///   ``TerminalViewModel`` stream observation, and flips status to `.connecting` → (on first
///   byte) `.connected`.
/// - ``disconnect()`` is a *deliberate* close (distinct from a network drop): it closes the
///   client and stops the supervisor so no reconnect is attempted.
///
/// `@MainActor @Observable`: bound directly to ``ConnectionView``. The terminal byte handling
/// is delegated to the injected ``TerminalViewModel`` (one source of truth for live state).
@preconcurrency
@MainActor
@Observable
public final class ConnectionViewModel {
    /// The CHANNEL-level status this pane's dot/recovery-banner show. The app-wide connect-gate uses
    /// ``AppConnection/status`` instead; this is the per-pane channel on the shared mux. Hoisted to the
    /// shared ``ConnectionStatus`` so one enum drives both (docs/31).
    public typealias Status = ConnectionStatus

    // MARK: Target (app-global)

    /// Resolves the CURRENT app-global ``ConnectionTarget`` at connect-time. The pane no longer carries
    /// its own host/port (docs/31): every channel rides the one shared mux at the app target, read fresh
    /// here so changing the host + reconnecting re-targets every pane. Injected (not stored host/port) so
    /// a later host change is picked up without rebuilding the session.
    private let target: @MainActor () -> ConnectionTarget
    private let initialCwd: String?

    // MARK: Observable status

    public private(set) var status: Status = .disconnected

    /// Smoothed app-layer RTT to this pane's host in milliseconds (`nil` until the first
    /// ping/pong completes). Fed by the client's 3s control-channel probe — the latency
    /// badge / typing-lag attribution datum (docs/26 D1/D10).
    public private(set) var latencyMS: Double?
    public private(set) var sessionID: UUID?

    // MARK: Detach/resume identity mirror (SLOPDESK_DETACH_ENABLED)

    /// The session UUID the client is currently using (the one it presented to the host in the
    /// channelOpen preamble). Mirrors ``SlopDeskClient/sessionID`` after a successful connect so
    /// the store can snapshot it into ``PaneSpec/resumeSessionID`` for the next launch.
    /// `nil` until the client completes its first handshake. Named to avoid shadowing `sessionID`
    /// (which carries the value learned from the last `helloAck`, same thing on this path).
    public private(set) var effectiveSessionID: UUID?

    /// The highest contiguous output seq the client has received from the host, snapshotted
    /// periodically so the store can persist it into ``PaneSpec/resumeLastReceivedSeq``. Driven
    /// by the `.rtt` probe tick (every ~3 s) so the snapshot is fresh without a dedicated timer.
    /// `0` until the client receives its first output chunk.
    public private(set) var snapshotedContiguousSeq: Int64 = 0

    /// Last log line from the reconnect supervisor (surfaced in the UI for diagnostics).
    public private(set) var lastLog: String?

    // MARK: Collaborators

    private let terminal: TerminalViewModel
    private let makeClient: @Sendable () -> SlopDeskClient
    private let backoff: ReconnectManager.Backoff

    /// An EXPLICIT desktop notification the child requested (OSC 9 / OSC 777). The store wires this to
    /// its pane-notification hook (so the click can focus + centre this pane). `nil` ⇒ no observer (the
    /// notification is dropped). Carries the live pane title so the poster can fall back to it when an
    /// OSC 9 omits a title.
    public var onExplicitNotification: ((_ paneTitle: String, _ title: String, _ body: String) -> Void)?

    /// A live OSC title change (wire type `.title`). The store wires this to persist the new title into
    /// ``PaneSpec/lastKnownTitle`` so a relaunch can restore the shell's last-known tab title even when
    /// the user has not manually renamed the pane. Empty strings are suppressed (the host emits an empty
    /// title on connect before the shell sets a real one). `nil` ⇒ no observer (the side-effect is dropped).
    public var onTitleChanged: ((String) -> Void)?

    /// A resume-identity snapshot (SLOPDESK_DETACH_ENABLED). Called whenever the effective session UUID
    /// or the snapshotted seq are updated so the store can persist them into ``PaneSpec/resumeSessionID``
    /// / ``PaneSpec/resumeLastReceivedSeq`` for the next launch. `nil` ⇒ no observer.
    public var onResumeIdentitySnapshot: ((_ sessionID: UUID, _ seq: Int64) -> Void)?

    /// A GENUINE reconnect edge (`.reconnected` — distinct from the ~3 s RTT snapshot that also drives
    /// ``onResumeIdentitySnapshot``). Fired once when a dropped link comes back on a fresh host shell, so the
    /// store can unconditionally re-fetch state that may have drifted while away — the sidebar git line (C3
    /// BUG C a: a sibling-pane commit / detached-session drift the pane missed). `nil` ⇒ no observer.
    public var onReconnected: (() -> Void)?

    /// C8 improvement 1: the fresh-vs-resumed verdict for a completed RECONNECT, forwarded from the terminal
    /// model (which alone derives it from the first post-reconnect output seq). The store wires this to a
    /// per-pane toast so a warm reattach ("session preserved") vs a fresh shell ("previous session ended")
    /// is surfaced rather than silent. Fired at most once per drop→reconnect; never on a first-ever connect
    /// or a deliberate ⇧⌘R. `nil` ⇒ no observer (the side-effect is dropped).
    public var onResumeOutcomeResolved: ((_ outcome: SlopDeskClient.SessionResumeOutcome) -> Void)?

    /// A Claude-Code agent-detection signal (wire types 26/27 — `.foregroundProcess` / `.claudeStatus`).
    /// The store wires this to the owning pane's ``LivePaneSession`` so it folds the signal into the
    /// pane's `ClaudeStatusMachine` and pushes the result to ``WorkspaceStore/setAgentStatus(_:for:)``
    /// (W11). `nil` ⇒ no observer (the signal is dropped). Only the two agent-detect events are
    /// forwarded here; all other events still drive the chrome/terminal as before.
    public var onAgentSignal: ((_ event: SlopDeskClient.Event) -> Void)?

    /// A finished command (OSC 133;D, wire type 23) — the lighter idle/completion signal carrying its
    /// exit code + C→D duration. The store wires this to ``WorkspaceStore/handleCommandCompleted(id:exitCode:durationMS:paneTitle:)``
    /// so the FOCUS GATE applies: a background completion badges the pane, and a backgrounded LONG command
    /// fires the desktop notification (a foreground one does not). `nil` ⇒ no observer (the side-effect is
    /// dropped). Cross-platform (the store owns the macOS-only poster behind its `onLongCommandNotify` sink).
    public var onCommandCompleted: ((_ exitCode: Int32?, _ durationMS: UInt32) -> Void)?

    /// A command-START edge (OSC 133;C / `.commandStatus(.running)`). The store wires this to
    /// ``WorkspaceStore/handleCommandStarted(id:)`` so a new run CLEARS the pane's stale completion badge before
    /// its running spinner resolves (a busy background pane must not show the previous run's ✓/✗). `nil` ⇒ no
    /// observer. The running/idle indicator itself is still folded by the terminal model via `terminal.handle`.
    public var onCommandStarted: (() -> Void)?

    /// An OSC 9;4 taskbar-style PROGRESS update (E14/K1, wire type 32). The store wires this to
    /// ``WorkspaceStore/handleProgress(_:for:)`` so the validated state lands in the per-pane `paneProgress`
    /// mirror (→ the sidebar tab badge + the macOS Dock aggregate). A ``ProgressState/clear`` arrives as `nil`
    /// (remove the indicator). `nil` ⇒ no observer (the side-effect is dropped); the terminal model still folds
    /// its own observable `progress` mirror via `terminal.handle` regardless.
    public var onProgressUpdate: ((_ progress: PaneProgress?) -> Void)?

    /// A shell-reported cwd edge (OSC 7, wire type 33). The store persists this into
    /// ``PaneSpec/lastKnownCwd`` so cwd inheritance uses the live prompt cwd immediately.
    public var onWorkingDirectoryChanged: ((_ cwd: String) -> Void)?

    /// Whether a command has started (OSC 133;C) in this pane yet. Gates ``routeWorkingDirectory``:
    /// startup zsh/plugin code transiently `cd`s into a plugin cache directory while sourcing `.zshrc`
    /// and emits an OSC 7 from there BEFORE the first prompt — those pre-command edges must not overwrite
    /// the inheritance source (`lastKnownCwd`), or a later new-tab / split spawns its PTY in the plugin dir.
    private var commandStartSeen = false

    private var client: SlopDeskClient?
    /// The pane's typed metadata façade (E4), created on connect bound to the live ``client`` and torn
    /// down on disconnect. Drives the sidebar git line + Open-Quickly/path actions; this VM folds the
    /// inbound `.metadataResponse` events into its pending-request registry. `nil` while disconnected.
    private var metadataClient: MetadataClient?
    /// Monotonic connect-attempt counter (R6 #1 — the VM analogue of `SlopDeskClient.connectGeneration`).
    /// `connect()`/`resume()` capture it before the long handshake `await`; a teardown / reconnect /
    /// second connect that lands during that suspension means the post-await `status`/`sessionID` writes
    /// belong to a SUPERSEDED attempt and must be discarded. Without it, because `SlopDeskClient.connect`
    /// now RETURNS (not throws) when it was closed/paused/superseded mid-handshake, the VM's `do` branch
    /// would whitewash an already-torn-down pane to `.connected` (and overwrite `sessionID`).
    private var connectGeneration = 0
    private var reconnect: ReconnectManager?
    /// Single-flight guard for ``connect()`` (R-lifecycle #4). `connect()` is `@MainActor`, but its body
    /// SUSPENDS at `await teardown()` (which itself awaits `outDrainTask?.value` / `client?.close()`), so two
    /// overlapping `connect()` calls — a double / key-repeated "Reconnect Pane" — could interleave: the second
    /// call's teardown cancel-prefix would run BEFORE the first built its client/observe/output/supervisor
    /// tasks, leaving the first attempt's client alive with nothing left to cancel or close it (a supervised
    /// zombie whose output keeps painting into the pane). Chaining each attempt after the prior one SERIALIZES
    /// them: the second call's teardown then closes+cancels the first's fully-built client, so no zombie leaks.
    private var connectTask: Task<Void, Never>?
    private var supervisorTask: Task<Void, Never>?
    /// The single events loop (chrome status + forward to the terminal model).
    private var observeTask: Task<Void, Never>?
    /// The terminal model's `output` byte-pump loop (separate from events).
    private var outputTask: Task<Void, Never>?
    /// True between a deliberate ``disconnect()`` and the next ``connect()`` so a trailing
    /// `.disconnected` event is not mis-read as a drop to reconnect.
    private var deliberatelyClosed = false

    /// Serial OUT path (renderer → host). Keystrokes + resizes funnel through ONE ordered
    /// FIFO drained by ONE task, so a fast burst (typing / multi-segment paste / an escape
    /// sequence split across writes) reaches the host PTY IN ORDER. A per-event
    /// `Task { await client.sendInput }` does NOT preserve order — independent unstructured
    /// tasks race on the reentrant `SlopDeskClient` actor and can deliver B before A.
    ///
    /// `internal` (not `private`) so the pure ``coalesceOut(_:)`` algorithm is headlessly
    /// unit-testable beside the renderer seam; `Equatable` so a test can assert WHICH events
    /// survived a coalesce. The `.resize` payload is the libghostty grid (cols,rows) only —
    /// the wire's px/py path is driven downstream by `SlopDeskClient.sendResize` (px/py = 0),
    /// unchanged.
    enum OutEvent: Equatable { case input(Data)
        case resize(cols: UInt16, rows: UInt16)
    }

    /// LATEST-WINS coalescer for one drained OUT batch — the resize-corruption fix.
    ///
    /// ### Why (the zsh incremental-redraw desync)
    /// A fast/continuous window drag makes libghostty emit a DISTINCT grid size per layout
    /// pass (59→60→…→145 cols), so ``TerminalViewModel/sendResize(cols:rows:)``'s identical-size
    /// dedup never fires and ~100 distinct `.resize` reach this path. Forwarding every one sends
    /// ~100 `TIOCSWINSZ` to the host PTY spread over time (serial drain + network + per-message
    /// await), so the child's `SIGWINCH` handler fires repeatedly at INTERMEDIATE sizes. zsh's
    /// handler does an INCREMENTAL prompt redraw (cursor-up N lines, clear, redraw) with N computed
    /// for a size that keeps changing under it → the redraw math desyncs → an orphaned cursor /
    /// misplaced prompt that only a fresh prompt clears. A LOCAL terminal never hits this: the
    /// kernel COALESCES SIGWINCH, so the app reads the LATEST size once and jumps straight to final.
    /// This restores that property on the wire: collapse a drag to as few `TIOCSWINSZ` as possible
    /// (ideally one after the drag settles) so zsh gets one clean SIGWINCH → one clean redraw.
    ///
    /// ### Algorithm (1:1 with `InputMotionCoalescer.coalesce` — `.input` is the barrier)
    /// Walk the arrival-ordered batch buffering the LATEST `.resize` in a single `pending` slot;
    /// consecutive `.resize` collapse to the last. An `.input(Data)` is a HARD BARRIER: flush
    /// `pending` BEFORE appending the input, so input byte order is never corrupted and a resize
    /// that physically preceded a keystroke is never emitted after it. At end-of-batch the trailing
    /// `pending` is appended (the `InputMotionCoalescer.coalesce` line-398 invariant) — this is the
    /// TRAILING-EDGE GUARANTEE: the last `.resize` in every batch is ALWAYS emitted, so the final
    /// drag size always reaches the PTY, by construction, not by any timer that could be dropped.
    ///
    /// Pure ⇒ no clock, no client, no actor — `nonisolated` so it runs synchronously off the main
    /// actor (the drain task + a headless test call it directly), exactly like the motion coalescer.
    nonisolated static func coalesceOut(_ batch: [OutEvent]) -> [OutEvent] {
        guard batch.count > 1 else { return batch }
        var output: [OutEvent] = []
        output.reserveCapacity(batch.count)
        var pending: OutEvent? // the latest buffered `.resize` in the current run (nil ⇔ none)
        for event in batch {
            switch event {
            case .resize:
                pending = event // same run: keep only the latest
            case .input:
                if let p = pending { output.append(p)
                    pending = nil
                } // barrier: flush resize FIRST
                output.append(event) // then the input (byte order intact)
            }
        }
        if let p = pending { output.append(p) } // trailing resize run (line-398 analog)
        return output
    }

    /// Normalizes the `.input` payloads of an (already-coalesced) batch: MERGES adjacent
    /// tiny inputs (key repeats, mouse-report storms — each used to pay a full actor-hop +
    /// send round trip) and SPLITS oversized ones, emitting `.input` frames of at most
    /// `maxInputFrameBytes`. `.resize` passes through as a HARD BARRIER (input bytes never
    /// cross it — the ``coalesceOut(_:)`` ordering contract). Concatenation byte-identity
    /// holds by construction: the emitted input payloads concatenate to exactly the input
    /// payloads, in order.
    ///
    /// Pure ⇒ `nonisolated` (the off-main drain + headless tests call it directly).
    nonisolated static func packInputs(
        _ events: [OutEvent],
        maxInputFrameBytes: Int = MuxFlowControl.maxDataMessagePayloadBytes,
    ) -> [OutEvent] {
        var output: [OutEvent] = []
        output.reserveCapacity(events.count)
        var buffer = Data()
        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            var offset = buffer.startIndex
            while offset < buffer.endIndex {
                let end = buffer.index(offset, offsetBy: maxInputFrameBytes, limitedBy: buffer.endIndex)
                    ?? buffer.endIndex
                output.append(.input(Data(buffer[offset..<end])))
                offset = end
            }
            buffer.removeAll(keepingCapacity: true)
        }
        for event in events {
            switch event {
            case let .input(data):
                buffer.append(data)
            case .resize:
                flushBuffer() // barrier: a resize never crosses input bytes
                output.append(event)
            }
        }
        flushBuffer()
        return output
    }

    /// Sends one coalesced+packed batch over `client`, sequentially (the single-consumer
    /// FIFO leg). Shared by the off-main drain and headless tests. Errors are swallowed
    /// per-event (`try?`) exactly as the old inline drain did — disconnected sends drop.
    nonisolated static func sendBatch(_ batch: [OutEvent], over client: SlopDeskClient) async {
        for event in packInputs(coalesceOut(batch)) {
            switch event {
            case let .input(data): try? await client.sendInput(data)
            case let .resize(cols, rows): try? await client.sendResize(cols: cols, rows: rows)
            }
        }
    }

    /// `@MainActor` FIFO of buffered OUT events the single drain task BATCH-pulls (mirrors
    /// `SlopDeskVideoHostSession.InboundQueue.drainAll`). `inputSink`/`resizeSink` append here on the
    /// main actor; `outWake` (a `bufferingNewest(1)` signal) coalesces wakeups so the drain runs
    /// once per backlog. Because the per-event `await` on the reentrant `SlopDeskClient` actor is
    /// slower than the main-actor appends during a drag, the queue naturally accumulates between
    /// drains → a fast drag collapses to ~1 resize via ``coalesceOut(_:)``; a slow settle keeps the
    /// batch size ~1 so it is byte-identical to forwarding each event (same self-regulating property
    /// as the host inbound pump). One ordered consumer, no per-resize Task — satisfies the
    /// documented anti-reorder rule.
    private var outQueue: [OutEvent] = []
    private var outWakeContinuation: AsyncStream<Void>.Continuation?
    private var outDrainTask: Task<Void, Never>?

    @preconcurrency
    public init(
        terminal: TerminalViewModel,
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
        backoff: ReconnectManager.Backoff = .init(),
        initialCwd: String? = nil,
        makeClient: @escaping @Sendable () -> SlopDeskClient,
    ) {
        self.terminal = terminal
        self.target = target
        self.backoff = backoff
        let trimmed = initialCwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialCwd = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.makeClient = makeClient
    }

    /// The terminal view-model (so the view can pass it to ``TerminalScreenView``).
    public var terminalModel: TerminalViewModel { terminal }

    /// The pane's SHELL activity (OSC 133): `.running` while a command executes, else `.idle`.
    /// Orthogonal to ``status`` — a pane is `.connected` AND running/idle. Read-through to the
    /// terminal model so the chrome / sidebar / palette can show a running indicator.
    public var shellActivity: TerminalViewModel.ShellActivity { terminal.shellActivity }

    /// The live client (so the input bar can `sendInput`). `nil` while disconnected.
    public var activeClient: SlopDeskClient? { client }

    /// The pane's typed metadata façade (E4), or `nil` while disconnected. The sidebar git line,
    /// Open-Quickly, and the host-path actions bind to this to fetch cwd/git status over the wire.
    public var activeMetadataClient: MetadataClient? { metadataClient }

    // MARK: Lifecycle

    /// Opens this pane's CHANNEL on the shared mux at the current app target, starting reconnect
    /// supervision + stream observation. The host/port come from the app-global ``ConnectionTarget``
    /// (the connect-gate dialled them) — the pane no longer has its own form.
    ///
    /// SINGLE-FLIGHT (R-lifecycle #4): the real work is ``performConnect()``; this wrapper CHAINS each attempt
    /// after any in-flight one so two overlapping calls (a double / held ⇧⌘R "Reconnect Pane") can never
    /// interleave their teardown/build and leak a live zombie client into the pane. The synchronous
    /// `status = .connecting` still lands BEFORE the first `await` so a re-entrant ``connectIfNeeded()`` sees
    /// `.connecting` and no-ops.
    public func connect() async {
        // Flip synchronously (before awaiting the prior attempt) so a re-entrant connectIfNeeded no-ops.
        status = .connecting
        let prior = connectTask
        let task = Task { @MainActor [weak self] in
            await prior?.value
            await self?.performConnect()
        }
        connectTask = task
        await task.value
    }

    private func performConnect() async {
        let t = target()
        let host = t.host
        let port = t.port

        // Flip to `.connecting` SYNCHRONOUSLY — before the first `await` (teardown) — so a re-entrant
        // caller (the lazy connect-on-appear `.task` SwiftUI cancels + restarts during the initial
        // canvas layout settle) observes `.connecting` and does NOT double-dial a second client onto
        // the same pane while this one is still standing up its mux channel.
        status = .connecting
        // Tear down any prior session first (re-connect to a new target).
        await teardown()
        deliberatelyClosed = false
        // Re-arm the OSC-7 startup-noise gate for this fresh session (see `commandStartSeen`): a
        // re-dialed pane spawns a brand-new shell that re-sources `.zshrc`, so its pre-first-command
        // plugin OSC 7 must be dropped again.
        commandStartSeen = false
        terminal.reset()

        let client = makeClient()
        self.client = client
        // Claim a generation for THIS attempt (R6 #1). A teardown/reconnect/second connect during the
        // handshake `await` below supersedes us; the post-await status writes must then be discarded.
        connectGeneration &+= 1
        let myGeneration = connectGeneration

        // OUT path (renderer → host): the terminal model's `sendInput`/`sendResize` (driven by
        // `GhosttyTerminalView`'s onWrite/onResize) append into ONE main-actor FIFO; a single drain
        // task BATCH-pulls it, coalesces (latest-wins resizes, `.input` as a barrier — see
        // ``coalesceOut(_:)``), and awaits the client SEQUENTIALLY so bytes/resizes are never
        // reordered. The wake is a `bufferingNewest(1)` signal so N appends collapse to one drain.
        // Captures `weak client/self` so a torn-down client is never targeted; `teardown()` finishes
        // the wake + cancels the drain + nils the sinks (a final drain flushes a settled trailing
        // resize — TRAILING-EDGE GUARANTEE, see `teardown()`).
        outQueue.removeAll(keepingCapacity: true)
        let (outWakeups, outWake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        outWakeContinuation = outWake
        // OFF-MAIN drain: appends stay on the main actor (true call order) but the consumer
        // runs DETACHED, hopping to main ONLY to atomically swap out the batch array — so a
        // keystroke's send no longer queues behind flood-ingest/render main-actor work
        // (input latency used to track main-thread depth exactly when a flood ran). The
        // ordering invariant needs ONE serial consumer, not main-actor residence: (i)
        // appends are serial on the main actor in call order, (ii) the batch take is atomic
        // on the main actor, (iii) this single task awaits sends sequentially.
        outDrainTask = Task.detached(priority: .userInitiated) { [weak self, weak client] in
            for await _ in outWakeups {
                guard let self, let client else { return }
                // Atomically take + clear the whole backlog (arrival order), then coalesce: a fast
                // drag piles up between drains → collapses to ~1 resize; a slow settle leaves batch
                // size ~1 → byte-identical to forwarding each event. The trailing resize of every
                // batch always survives coalesce, so the final drag size always reaches the PTY.
                let batch: [OutEvent] = await MainActor.run {
                    let b = self.outQueue
                    self.outQueue.removeAll(keepingCapacity: true)
                    return b
                }
                await Self.sendBatch(batch, over: client)
            }
        }
        terminal.inputSink = { [weak self] data in
            guard let self else { return }
            outQueue.append(.input(data))
            outWakeContinuation?.yield()
        }
        terminal.resizeSink = { [weak self] cols, rows in
            guard let self else { return }
            outQueue.append(.resize(cols: cols, rows: rows))
            outWakeContinuation?.yield()
        }
        // WB2: the Block-output request sink (wire type 15). Fired by the terminal model's copy-output flow
        // (``TerminalViewModel/copyBlockOutput(index:onResult:)``). It rides CONTROL, not the windowed OUT
        // FIFO — a request is a single small control frame whose reply (type 29) the inbound pump surfaces;
        // it never needs to order against keystrokes/resizes. Fire-and-forget: a dropped request resolves
        // via the model's timeout (the copy UI never hangs). Captures `weak client` so a torn-down client
        // is never targeted.
        terminal.requestBlockOutputSink = { [weak client] index in
            Task { try? await client?.requestBlockOutput(index: index) }
        }
        // C8 improvement 1: forward the terminal model's fresh-vs-resumed reconnect verdict up to the store
        // (→ a per-pane toast). Set once here alongside the other sinks; a supervisor-driven reconnect does
        // NOT re-run connect(), so this sink stays live to catch the verdict resolved after that reconnect.
        terminal.onResumeOutcomeResolved = { [weak self] outcome in
            self?.onResumeOutcomeResolved?(outcome)
        }

        // E4: the pane's metadata façade. Its `send` seam fires a `requestMetadata` on the CONTROL channel
        // (wire type 16); the reply (type 30) is surfaced as a `.metadataResponse` event and folded into
        // this façade's registry by `foldEvent` below. Captures `weak client` so a torn-down client is
        // never targeted; the registry's timeout + a teardown `cancelAll()` guarantee no await hangs.
        metadataClient = MetadataClient(send: { [weak client] requestID, verb, payload in
            try? await client?.requestMetadata(requestID: requestID, verb: verb, payload: payload)
        })

        // Single UI-layer events loop (chrome status + forward to the terminal model).
        observeEvents(client)
        // Separate output byte-pump for the terminal model (output has a single consumer).
        outputTask = Task { @MainActor [weak self] in
            await self?.terminal.observe(client: client)
        }

        // Reconnect supervisor: drives byte-exact resumes on a drop. Its progress/give-up callbacks
        // publish the WF3 backoff state onto `status` so the chrome surfaces an attempt-aware
        // "reconnecting" (with a countdown) and a terminal "unreachable" instead of a frozen dot. The
        // callbacks are `@Sendable` and hop onto the main actor; they only ENRICH the `.reconnecting`
        // the events loop already set on the drop (`observeEvents`), so a recovery (`onLog "resumed"`
        // → `.reconnected` event → `.connected`) still wins.
        let manager = ReconnectManager(
            client: client,
            backoff: backoff,
            onLog: { [weak self] line in
                Task { @MainActor in self?.lastLog = line }
            },
            onProgress: { [weak self] attempt, nextRetryAt in
                Task { @MainActor in self?.applyReconnectProgress(attempt: attempt, nextRetry: nextRetryAt) }
            },
            onGaveUp: { [weak self] in
                Task { @MainActor in self?.applyReconnectGaveUp() }
            },
        )
        reconnect = manager

        // DEAD-HOST TIMEOUT: the ~10s ceiling now lives at the TRANSPORT layer
        // (`LiveMuxConnectionFactory.makeConnection` → `withMuxConnectTimeout`), NOT here. Do NOT
        // re-add a `withThrowingTaskGroup` racing `client.connect` against a `Task.sleep` at THIS
        // level: that deadlocked the connect on the Mac Studio (connect() entered and never returned;
        // the host never logged the accept; the sleep never fired → the cooperative pool was jammed).
        // Wrapping only the inner NWConnection establishment (a Network.framework callback, off the
        // cooperative pool) is safe and bounded; an unreachable host now throws
        // `SlopDeskTransportError.timedOut` here in ~`handshakeTimeout` and we surface `.failed` instead
        // of hanging at "connecting" forever.
        // Start the reconnect supervisor BEFORE `connect()` so its subscription to `client.events`
        // (registered eagerly in `manager.start`) is live before any drop. Starting it AFTER a
        // successful connect (the old order) left a window in which a fast `.disconnected` was yielded
        // to no subscriber and LOST — the pane then stuck at "reconnecting" with no retry ([6]). The
        // supervisor only ACTS on a `.disconnected`; before/around connect there are none, so this is
        // inert until a real drop. On an initial-connect failure there is no session to resume, so the
        // supervisor is cancelled in the catch.
        let supervisor = manager.start(host: host, port: port)
        supervisorTask = supervisor
        do {
            // CANCELLATION SHIELD (canvas auto-connect bug): the lazy connect-on-appear runs inside
            // SwiftUI's `.task`, which SwiftUI CANCELS + restarts when the leaf view churns during the
            // initial canvas layout settle. `SlopDeskClient.connect()` re-checks `Task.isCancelled` AFTER
            // acquiring its mux channel and, if set, tears that channel back down — closing the shared
            // connection mid-handshake while we still flip to `.connected` below (a live-looking but
            // DEAD socket: the host attaches a shell, the link drops, no `.disconnected` is observed,
            // so no reconnect fires). The connection lives in the store registry, not the view, so it
            // must outlive a view-`.task` cancellation. Establish it in an unstructured `Task` (which
            // does NOT inherit our caller's cancellation); awaiting `.value` still propagates a real
            // connect error/timeout, but `Task.isCancelled` inside is now always false. Our own
            // generation + `self.client === client` guards below remain the authority on supersession.
            try await Task { @MainActor in
                await client.setInitialCwd(initialCwd)
                try await client.connect(host: host, port: port)
            }.value
            // Read the learned id, THEN re-check we are still the live attempt before writing any state —
            // `SlopDeskClient.connect` RETURNS (not throws) when it was closed/paused/superseded mid-handshake,
            // so without this guard a torn-down or superseded pane would be whitewashed to `.connected`.
            // `self.client === client` catches a racing teardown (it nils `self.client`); the generation
            // catches a second connect (it bumped `connectGeneration`). No `await` between guard and writes.
            let learnedID = await client.sessionID
            guard myGeneration == connectGeneration, self.client === client else { return }
            sessionID = learnedID
            effectiveSessionID = learnedID
            if let learnedID { onResumeIdentitySnapshot?(learnedID, 0) }
            status = .connected
            // The host PTY is now ready to accept a resize. Re-send the renderer's current grid: any
            // resize that fired during the handshake threw `sendResize before connect` and was dropped
            // (the OUT drain's `try?`), but the model recorded it as sent — so without this the dedup
            // would pin the host at its 80×24 init grid (overlapping glyphs / fzf at the wrong row).
            terminal.resendCurrentSize()
            // …and again shortly after: the host's CONTROL-channel reader (which applies resize via
            // TIOCSWINSZ) may not be pumping the instant connect returns, so a resize sent right now can
            // be dropped at the mux before it is read (input/output ride the DATA channel and only flow
            // once the user types — well past this window — so they never hit this race). Re-assert when
            // the reader is reliably live; the host debounces duplicates, so the extra send is free.
            Task { @MainActor [weak self, weak client] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.client === client else { return }
                terminal.resendCurrentSize()
            }
        } catch {
            guard myGeneration == connectGeneration, self.client === client else { return }
            supervisor.cancel()
            supervisorTask = nil
            status = .failed(Self.failureReason(for: error))
        }
    }

    /// The LAZY connect-on-appear entry point — a pane's SwiftUI `.task(id:)` action, which SwiftUI
    /// RE-FIRES on every view MOUNT. Crucially that includes a mere pane REMOUNT: switching TABS unmounts
    /// the inactive tab's pane subtree and remounts it on return, so `.task` restarts even though the live
    /// session never changed. Unlike ``connect()`` — which deliberately TEARS DOWN the current session and
    /// wipes the terminal replay ring to dial a (possibly new) target — this MUST be IDEMPOTENT: a healthy
    /// or in-flight channel is left completely untouched, so the retained ``TerminalViewModel/ring``
    /// survives the remount and ``TerminalViewModel/attachSurface(_:)`` can repaint the prior screen. Only a
    /// genuinely idle/dead channel actually dials. `.reconnecting` is owned by the supervisor (its own
    /// backoff campaign is mid-flight), so it is left alone too — a remount must not short-circuit it.
    ///
    /// Regression guard (the "switch tab thì mất toàn bộ history" report): before this, the leaf's `.task`
    /// called ``connect()`` unconditionally on every remount, so a tab switch tore down a perfectly healthy
    /// session and `terminal.reset()` emptied the ring → the pane came back blank + fully re-dialed a fresh
    /// host shell. The explicit reconnect paths (the "Reconnect Pane" command, the connect-gate) still call
    /// ``connect()`` directly, so their force-redial semantics are unaffected.
    public func connectIfNeeded() async {
        switch status {
        case .disconnected,
             .failed,
             .unreachable:
            await connect()
        case .connecting,
             .connected,
             .reconnecting:
            return // already live / in-flight / supervised — a remount must not disturb it
        }
    }

    /// The user-facing `.failed` reason for a thrown error. A `LocalizedError` (e.g.
    /// ``SlopDeskTransportError``) yields its clean `errorDescription` ("Connection timed out — host
    /// unreachable?"); ANY OTHER error falls back to `String(describing:)`, which preserves the readable
    /// Swift payload (`invalidState("resume before first connect")`) rather than Foundation's bridged
    /// "The operation couldn't be completed. (… error N.)" dump that bare `.localizedDescription` would
    /// produce for a plain `Error` enum like `SlopDeskClient.ClientError` or `CancellationError`.
    static func failureReason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// A deliberate disconnect: close the client + stop the supervisor (no reconnect).
    public func disconnect() async {
        deliberatelyClosed = true
        await teardown()
        status = .disconnected
        terminal.reset()
    }

    /// iOS lifecycle: app backgrounded → proactively pause the client (host retains the tail).
    public func pause() async {
        await client?.pause()
    }

    /// iOS lifecycle: app foregrounded → byte-exact resume.
    ///
    /// A no-op for a pane that was never connected. `WorkspaceStore.resumeAll()` fans `resume()`
    /// out to EVERY materialized session on foreground — including idle panes still showing the
    /// connect form (`client == nil`). The old code unconditionally set `status = .connected`
    /// after `try await client?.resume()`, and with `client == nil` the optional chain is a
    /// silent nil (no throw), so an idle pane FALSELY reported `.connected` → `PaneLeafView` hid
    /// the connect form, stranding a dead empty terminal. Guard on a live client, and only
    /// re-assert `.connected` when the pane was actually in a connected-ish state before the
    /// pause (so a `.failed`/`.disconnected` client is not whitewashed to `.connected`).
    public func resume() async {
        guard let client else { return }
        // Capture the pre-resume state: pause() does not change `status`, so a connection that
        // was live (or mid-reconnect) before backgrounding is still `.connected`/`.reconnecting`.
        // Only such a pane should snap back to `.connected`; a never-up client must not.
        let wasLive =
            switch status {
            case .connected,
                 .reconnecting: true
            default: false
            }
        do {
            try await client.resume()
            // Same supersede guard as connect() (R6 #1): a teardown/reconnect during resume's handshake
            // nils/replaces `self.client`, so don't whitewash a torn-down pane back to `.connected`.
            guard self.client === client else { return }
            if wasLive { status = .connected }
        } catch {
            guard self.client === client else { return }
            status = .failed(Self.failureReason(for: error)) // humanized + payload-safe (see connect()'s catch)
        }
    }

    // MARK: Internals

    /// The **single** UI-layer consumer of `client.events`: it folds each event into the
    /// chrome status AND forwards it to the terminal model (one loop, two folds). The terminal
    /// model deliberately does NOT open its own `for await client.events` loop — two
    /// independent loops over the same event source would split the stream nondeterministically
    /// (a `.disconnected`/`.reconnected`/`.title` would reach only one of them, diverging the
    /// chrome and terminal statuses). `SlopDeskClient` multicasts events so the reconnect
    /// supervisor still gets its own copy; here we keep exactly one UI consumer.
    private func observeEvents(_ client: SlopDeskClient) {
        observeTask = Task { @MainActor [weak self] in
            for await event in client.events {
                guard let self else { return }
                foldEvent(event)
            }
        }
    }

    /// Folds one client event into the chrome `status`, then forwards EVERY event to the terminal model
    /// so its status / title / bell / exit / resume-seq stay consistent with the chrome. Extracted from
    /// `observeEvents` so the deliberate-close guards are unit-testable synchronously (R13 #3).
    private func foldEvent(_ event: SlopDeskClient.Event) {
        switch event {
        case .disconnected:
            // A dropped link's last OSC 9;4 is a lie for the reconnect — clear the store's per-pane progress
            // mirror (the badge source) so it agrees with the terminal model, which clears its own `progress`
            // on the same edge (no stuck spinner across a drop/reconnect). The fresh shell re-reports its own.
            onProgressUpdate?(nil)
            if deliberatelyClosed {
                status = .disconnected
            } else {
                // A fresh drop: enter reconnecting with no attempt info yet (the supervisor's
                // `onProgress` enriches it with the attempt count + countdown as it retries).
                status = .reconnecting(attempt: 0, nextRetry: nil)
                terminal.markReconnecting()
            }
        case let .reconnected(sessionID, _):
            // A late .reconnected can be drained from the broadcaster buffer AFTER a deliberate
            // disconnect() (a buffered AsyncStream element is delivered even post-cancel/finish).
            // Mirror the .disconnected + applyReconnect* guards so it cannot whitewash a
            // deliberately-closed pane back to green .connected with a stale sessionID + dead transport.
            // `return` (not break) also skips the terminal.handle(event) forward below, which would
            // otherwise wedge the terminal model's connectionStatus to .connected past disconnect()'s
            // terminal.reset() (R13 #3).
            if deliberatelyClosed { return }
            // A reconnect spawns a BRAND-NEW host shell (the mux path has no server-side resume) that
            // re-sources `.zshrc`, replaying the plugin-manager OSC-7 startup noise. Re-arm the gate
            // (`commandStartSeen`) so that pre-first-command OSC 7 is dropped again — else the stale-true
            // flag admits the plugin cache dir and poisons `lastKnownCwd` (the plugin-cache-poison bug).
            commandStartSeen = false
            self.sessionID = sessionID
            effectiveSessionID = sessionID
            onResumeIdentitySnapshot?(sessionID, snapshotedContiguousSeq)
            status = .connected
            // C3 BUG C a: a genuine reconnect edge — let the store unconditionally refresh drift-prone state
            // (the sidebar git line) that the ~3 s snapshot only re-fetches under a staleness window.
            onReconnected?()
            // RECONNECT GRID RE-ASSERT (the "render bị xô lệch khi reconnect" fix). A reconnect spawns
            // a BRAND-NEW host shell (the mux path has no server-side resume — see
            // `TerminalViewModel.markReconnecting`), whose PTY starts at its 80×24 init size. The grid
            // re-assert that `connect()` does (resendCurrentSize + a +400ms re-assert) runs ONLY on the
            // initial connect, NOT here — the supervisor re-establishes the session internally and only
            // emits this event. Without re-sending the renderer's real grid, the new PTY stays at 80×24
            // while libghostty renders the layout-derived grid (e.g. 79×22), so zsh wraps at the wrong
            // column and TUIs draw at the wrong row (overlapping / skewed glyphs). Mirror connect()'s
            // two-shot re-assert: now, then again after the host control-reader is reliably pumping (it
            // may not be the instant the resume completes, so an immediate-only send can be dropped at
            // the mux before it is read; the host debounces duplicates, so the second send is free).
            terminal.resendCurrentSize()
            let reconnectedClient = client
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, client === reconnectedClient else { return }
                terminal.resendCurrentSize()
            }
        case .exit:
            status = .disconnected
            // A terminated shell reports no progress — clear the store's per-pane mirror to match the terminal
            // model's own `.exit` clear (no stuck OSC 9;4 spinner on a dead pane).
            onProgressUpdate?(nil)
        case let .commandStatus(commandStatus):
            // A finished command (OSC 133;D): route the completion to the store, which owns the FOCUS
            // GATE (badge an unfocused pane; notify only for a backgrounded long command). Moving the
            // notify decision off this VM is what lets a foreground long command stay silent — the VM
            // does not know which leaf is active. The running/idle indicator itself is folded by the
            // terminal model below — this branch only drives the start/completion side-effects.
            switch commandStatus {
            case .running:
                // The command-START edge clears a STALE completion badge in the store (a new run resets the
                // prior exit ✓/✗ before the spinner resolves). The terminal model still sets `.running` below.
                commandStartSeen = true
                onCommandStarted?()
            case let .idle(exitCode, durationMS):
                onCommandCompleted?(exitCode, durationMS)
            }
        case let .notification(title, body):
            // An EXPLICIT child-requested notification (OSC 9 / OSC 777). Hand it to the store's
            // pane-notification hook with the live pane title (the OSC-9 title fallback). The
            // running/idle indicator is unaffected; this is a pure side-effect.
            onExplicitNotification?(terminal.title ?? "", title, body)
        case let .rtt(milliseconds):
            latencyMS = milliseconds
            // Piggyback a seq snapshot on the RTT tick (~3 s cadence) so the store can persist
            // the live highestContiguousSeq without a dedicated timer. Actor-isolated read; safe
            // because we hop onto MainActor inside an already-MainActor foldEvent call.
            let snapClient = client
            Task { @MainActor [weak self] in
                guard let self, let snapClient, client === snapClient else { return }
                let seq = await snapClient.highestContiguousSeq
                snapshotedContiguousSeq = seq
                if let id = effectiveSessionID {
                    onResumeIdentitySnapshot?(id, seq)
                }
            }
        case .foregroundProcess,
             .claudeStatus:
            // Claude-Code detection (wire types 26/27): hand the raw event to the store's per-pane
            // agent-status hook (which folds it into the pane's ClaudeStatusMachine). A pure
            // side-effect — the chrome status is unaffected.
            onAgentSignal?(event)
        case .commandBlock,
             .blockOutput:
            // WB2 Warp-style Blocks (wire types 28/29): folded into the terminal model's per-pane block
            // store below (terminal.handle). The chrome status is unaffected.
            break
        case let .metadataResponse(requestID, status, payload):
            // E4 host metadata reply (wire type 30): correlate it to the pending request in the pane's
            // metadata façade (the typed MetadataClient decodes the payload for the Details Panel). The
            // chrome status is unaffected. A reply for an unknown/already-resolved id is dropped by the
            // registry, so a stale type-30 after a pane switch is harmless.
            metadataClient?.resolve(requestID: requestID, status: status, payload: payload)
        case let .title(text):
            // Persist the live shell title into the pane spec so a relaunch can restore it.
            // Empty strings are suppressed — the host emits "" on connect before the shell sets a real one.
            // M4 (E14/K11) "Title — Shell Controlled" (default ON): when OFF, the SAME fire-time gate the VM
            // applies to `TerminalViewModel.handle(.title)` must ALSO gate this PERSISTENCE path — otherwise a
            // remote OSC 0/2 title still writes `spec.lastKnownTitle` and leaks onto the sidebar rail (which
            // sources its row title from `lastKnownTitle`). Gating here keeps the rail + the relaunch restore
            // consistent with the VM display gate.
            if SettingsKey.titleShellControlledEnabled, !text.isEmpty { onTitleChanged?(text) }
        case .inputEcho:
            // Secure input (E17 ES-E17-4, wire type 31): the host PTY echo edge. The terminal model folds it
            // (`terminal.handle` below) into `hostNoEcho` → the `secureInputActive` pill mirror + the macOS
            // leaf's `SecureKeyboardEntryController`. No connection-layer side effect here.
            break
        case let .progress(state, percent):
            // OSC 9;4 PROGRESS (E14/K1, wire type 32): route the validated taskbar-style progress to the
            // store's per-pane mirror (→ the sidebar tab badge + the macOS Dock aggregate). The terminal model
            // ALSO folds it (`terminal.handle` below) into its observable `progress` mirror for the pane
            // status strip / Dock read. `PaneProgress(state:percent:)` maps a `.clear` to `nil` (remove it).
            onProgressUpdate?(PaneProgress(state: state, percent: percent))
        case let .cwd(path):
            routeWorkingDirectory(path)
        case .bell:
            break
        }
        terminal.handle(event)
    }

    private func routeWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        // OSC-7 STARTUP-NOISE GATE. A zsh plugin manager (zinit / antidote / antigen / …) transiently
        // `cd`s into its plugin CACHE directory while sourcing `.zshrc` and emits an OSC 7 from there —
        // e.g. `…/plugins/zsh-users---zsh-autosuggestions` — BEFORE the shell reaches its first prompt.
        // Accepting that edge overwrites this pane's inherit source (`lastKnownCwd`), so a later
        // new-tab / split then `chdir`s the freshly-spawned PTY into that plugin dir (via `channelOpen`)
        // instead of the real project cwd. That is the whole bug: split/new-tab landing in
        // `zsh-users---zsh-autosuggestions`.
        //
        // Gate on `commandStartSeen` (first OSC 133;C command-START): plugin sourcing never emits a
        // command-START mark, whereas an INTERACTIVE `cd` (itself a command) does — so a genuine user
        // `cd` is still captured live, immediately, from the OSC 7 the shell reports. Before the first
        // command the stamped `lastKnownCwd` (set at pane creation from the inherited cwd) is already the
        // correct inherit source, so dropping pre-command edges is loss-free. The host `cwd` RPC is NOT a
        // useful cross-check here: it re-reads the shell's LIVE cwd, which is the same transient plugin dir
        // the OSC 7 reported — it races the `cd`, it does not authoritatively reject the noise.
        //
        // NOTE: `metadataClient`-independent by design — every production terminal pane has a live
        // `metadataClient`, so any branch keyed on it being nil would never run in production (the exact
        // trap the previous implementation fell into). There is one path, and the unit tests exercise it.
        guard commandStartSeen else { return }
        onWorkingDirectoryChanged?(path)
    }

    #if DEBUG
    /// Test hook (no production caller): fold one event synchronously through the SAME path
    /// `observeEvents` uses, so a unit test can assert the deliberate-close guards without driving the
    /// async event stream (R13 #3). `internal` + `DEBUG`-gated so it never leaks into release API.
    func foldEventForTesting(_ event: SlopDeskClient.Event) { foldEvent(event) }
    #endif

    /// Folds a ``ReconnectManager`` progress callback into `status` (WF3 backoff → UI). Only enriches
    /// the `.reconnecting`/dropped states — a campaign attempt that arrives after the resume already
    /// flipped the pane back to `.connected` (the supervisor's `onProgress` for the SUCCESSFUL attempt
    /// can race the `.reconnected` event) must NOT drag a live pane back to "reconnecting". So this is a
    /// no-op unless the pane is currently reconnecting-ish (`.reconnecting`/`.disconnected`).
    func applyReconnectProgress(attempt: Int, nextRetry: Date?) {
        // R11: a reconnect callback's hop-Task can land AFTER a deliberate `disconnect()` (which sets
        // `status = .disconnected` + `deliberatelyClosed`, cancels the supervisor). Cancelling the
        // supervisor does NOT cancel an already-fired callback's hop-Task, and `.disconnected` is BOTH a
        // transient-drop state AND the deliberate-close terminal state — so without this guard a late
        // callback whitewashes a closed pane to `.reconnecting` (orange "Reconnecting…" that never
        // resolves, since the supervisor is dead). `observeEvents` already guards `.disconnected` this way.
        guard !deliberatelyClosed else { return }
        switch status {
        case .reconnecting,
             .disconnected:
            status = .reconnecting(attempt: attempt, nextRetry: nextRetry)
        default:
            break // already connected / failed — do not regress
        }
    }

    #if DEBUG
    /// Test hook (no production caller): force `.connected` so a unit test can assert that a LATE
    /// reconnect-progress / give-up callback does not regress a pane that already recovered. `internal`
    /// + `DEBUG`-gated so it never leaks into a release build's API surface.
    func forceStatusConnectedForTesting() { status = .connected }
    #endif

    /// Folds the terminal "gave up after maxReconnectAttempts" callback into `status`: a pane stuck
    /// reconnecting flips to `.unreachable` (the visible WF3 give-up state). Guarded so a give-up that
    /// races a late resume cannot whitewash a `.connected` pane.
    func applyReconnectGaveUp() {
        // R11: same deliberate-close guard as `applyReconnectProgress` — a give-up callback racing a
        // `disconnect()` must not whitewash the closed pane to `.unreachable` (red "Unreachable").
        guard !deliberatelyClosed else { return }
        switch status {
        case .reconnecting,
             .disconnected:
            status = .unreachable
        default:
            break
        }
    }

    private func teardown() async {
        supervisorTask?.cancel()
        observeTask?.cancel()
        outputTask?.cancel()
        supervisorTask = nil
        observeTask = nil
        outputTask = nil
        // Drop the OUT-path sinks + tear down the serial drain before releasing the client
        // so the renderer cannot route keystrokes/resizes into a closed client.
        terminal.inputSink = nil
        terminal.resizeSink = nil
        // WB2: drop the Block-output request sink too — a copy-output request after teardown then resolves
        // immediately as "unavailable" (no live client to ask) rather than targeting a closed client.
        terminal.requestBlockOutputSink = nil
        // E4: cancel every in-flight metadata request (each resolves to empty so a Details-Panel fetch
        // mid-teardown unblocks at once, not after the 5 s timeout) and drop the façade.
        metadataClient?.cancelAll()
        metadataClient = nil
        outWakeContinuation?.finish()
        outWakeContinuation = nil
        outDrainTask?.cancel()
        // AWAIT the drain's completion BEFORE the residual flush: a mid-batch drain is not
        // stopped by cancel() alone (its sends `try?`), so without this the residual flush
        // below could interleave with in-flight drain sends (a pre-existing hazard the
        // off-main drain made worth closing). Bounded: cancel unparks a credit-window wait
        // (MuxSubChannel.awaitChunkCredit is cancellation-aware) and a closed channel
        // throws fast into the `try?`.
        await outDrainTask?.value
        outDrainTask = nil
        // TRAILING-EDGE GUARANTEE at teardown: the async drain may have been cancelled with a
        // settled trailing resize still queued (e.g. the user stopped dragging and immediately
        // disconnected/reconnected — the wake fired but the drain lost the race to cancellation).
        // Flush the residual backlog ONCE here, synchronously on the main actor, through the SAME
        // coalesce so the final size still reaches the PTY before the client closes. This is the
        // only place the queue is drained outside the loop; `coalesceOut` keeps the last resize.
        //
        // Residual `.input` is DROPPED, not flushed: input rides the WINDOWED data
        // sub-channel, and under credit-at-consumption an exhausted window would park this
        // await BEFORE `client.close()` (the very call that wakes parked senders) could
        // run → `disconnect()` hangs. Resize rides the unwindowed CONTROL channel (never
        // parks), and dropping keystrokes at deliberate teardown is the designed semantic
        // (they were typed against a session that is going away).
        if let client, !outQueue.isEmpty {
            let residual = outQueue
            outQueue.removeAll(keepingCapacity: true)
            for event in Self.coalesceOut(residual) {
                switch event {
                case .input: break
                case let .resize(cols, rows): try? await client.sendResize(cols: cols, rows: rows)
                }
            }
        }
        outQueue.removeAll(keepingCapacity: true)
        await client?.close()
        client = nil
        reconnect = nil
    }
}
