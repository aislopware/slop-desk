import Foundation
import AislopdeskClient
import AislopdeskProtocol

/// Orchestrates a ``AislopdeskClient`` + ``ReconnectManager`` for the UI: host/port entry,
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

    // MARK: Observable status

    public private(set) var status: Status = .disconnected

    /// Smoothed app-layer RTT to this pane's host in milliseconds (`nil` until the first
    /// ping/pong completes). Fed by the client's 3s control-channel probe — the latency
    /// badge / typing-lag attribution datum (docs/26 D1/D10).
    public private(set) var latencyMS: Double?
    public private(set) var sessionID: UUID?
    /// Last log line from the reconnect supervisor (surfaced in the UI for diagnostics).
    public private(set) var lastLog: String?

    // MARK: Collaborators

    private let terminal: TerminalViewModel
    private let makeClient: @Sendable () -> AislopdeskClient
    private let backoff: ReconnectManager.Backoff

    #if os(macOS)
    /// Posts a local notification when a LONG-running command (OSC 133;D, ≥ ~10s) completes.
    /// Best-effort + lazy-auth; macOS-only (iOS still builds). The in-app running indicator is
    /// the primary deliverable and does not depend on this.
    private let commandNotifier = CommandCompletionNotifier()
    #endif

    private var client: AislopdeskClient?
    /// Monotonic connect-attempt counter (R6 #1 — the VM analogue of `AislopdeskClient.connectGeneration`).
    /// `connect()`/`resume()` capture it before the long handshake `await`; a teardown / reconnect /
    /// second connect that lands during that suspension means the post-await `status`/`sessionID` writes
    /// belong to a SUPERSEDED attempt and must be discarded. Without it, because `AislopdeskClient.connect`
    /// now RETURNS (not throws) when it was closed/paused/superseded mid-handshake, the VM's `do` branch
    /// would whitewash an already-torn-down pane to `.connected` (and overwrite `sessionID`).
    private var connectGeneration = 0
    private var reconnect: ReconnectManager?
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
    /// tasks race on the reentrant `AislopdeskClient` actor and can deliver B before A.
    ///
    /// `internal` (not `private`) so the pure ``coalesceOut(_:)`` algorithm is headlessly
    /// unit-testable beside the renderer seam; `Equatable` so a test can assert WHICH events
    /// survived a coalesce. The `.resize` payload is the libghostty grid (cols,rows) only —
    /// the wire's px/py path is driven downstream by `AislopdeskClient.sendResize` (px/py = 0),
    /// unchanged.
    enum OutEvent: Sendable, Equatable { case input(Data); case resize(cols: UInt16, rows: UInt16) }

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
        var pending: OutEvent?   // the latest buffered `.resize` in the current run (nil ⇔ none)
        for event in batch {
            switch event {
            case .resize:
                pending = event                                  // same run: keep only the latest
            case .input:
                if let p = pending { output.append(p); pending = nil }  // barrier: flush resize FIRST
                output.append(event)                             // then the input (byte order intact)
            }
        }
        if let p = pending { output.append(p) }                  // trailing resize run (line-398 analog)
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
        maxInputFrameBytes: Int = MuxFlowControl.maxDataMessagePayloadBytes
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
                flushBuffer()        // barrier: a resize never crosses input bytes
                output.append(event)
            }
        }
        flushBuffer()
        return output
    }

    /// Sends one coalesced+packed batch over `client`, sequentially (the single-consumer
    /// FIFO leg). Shared by the off-main drain and headless tests. Errors are swallowed
    /// per-event (`try?`) exactly as the old inline drain did — disconnected sends drop.
    nonisolated static func sendBatch(_ batch: [OutEvent], over client: AislopdeskClient) async {
        for event in packInputs(coalesceOut(batch)) {
            switch event {
            case let .input(data):          try? await client.sendInput(data)
            case let .resize(cols, rows):   try? await client.sendResize(cols: cols, rows: rows)
            }
        }
    }

    /// `@MainActor` FIFO of buffered OUT events the single drain task BATCH-pulls (mirrors
    /// `AislopdeskVideoHostSession.InboundQueue.drainAll`). `inputSink`/`resizeSink` append here on the
    /// main actor; `outWake` (a `bufferingNewest(1)` signal) coalesces wakeups so the drain runs
    /// once per backlog. Because the per-event `await` on the reentrant `AislopdeskClient` actor is
    /// slower than the main-actor appends during a drag, the queue naturally accumulates between
    /// drains → a fast drag collapses to ~1 resize via ``coalesceOut(_:)``; a slow settle keeps the
    /// batch size ~1 so it is byte-identical to forwarding each event (same self-regulating property
    /// as the host inbound pump). One ordered consumer, no per-resize Task — satisfies the
    /// documented anti-reorder rule.
    private var outQueue: [OutEvent] = []
    private var outWakeContinuation: AsyncStream<Void>.Continuation?
    private var outDrainTask: Task<Void, Never>?

    public init(
        terminal: TerminalViewModel,
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
        backoff: ReconnectManager.Backoff = .init(),
        makeClient: @escaping @Sendable () -> AislopdeskClient
    ) {
        self.terminal = terminal
        self.target = target
        self.backoff = backoff
        self.makeClient = makeClient
    }

    /// The terminal view-model (so the view can pass it to ``TerminalScreenView``).
    public var terminalModel: TerminalViewModel { terminal }

    /// The pane's SHELL activity (OSC 133): `.running` while a command executes, else `.idle`.
    /// Orthogonal to ``status`` — a pane is `.connected` AND running/idle. Read-through to the
    /// terminal model so the chrome / sidebar / palette can show a running indicator.
    public var shellActivity: TerminalViewModel.ShellActivity { terminal.shellActivity }

    /// The live client (so the input bar can `sendInput`). `nil` while disconnected.
    public var activeClient: AislopdeskClient? { client }

    // MARK: Lifecycle

    /// Opens this pane's CHANNEL on the shared mux at the current app target, starting reconnect
    /// supervision + stream observation. The host/port come from the app-global ``ConnectionTarget``
    /// (the connect-gate dialled them) — the pane no longer has its own form.
    public func connect() async {
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
            self.outQueue.append(.input(data)); self.outWakeContinuation?.yield()
        }
        terminal.resizeSink = { [weak self] cols, rows in
            guard let self else { return }
            self.outQueue.append(.resize(cols: cols, rows: rows)); self.outWakeContinuation?.yield()
        }

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
            }
        )
        self.reconnect = manager

        // DEAD-HOST TIMEOUT: the ~10s ceiling now lives at the TRANSPORT layer
        // (`LiveMuxConnectionFactory.makeConnection` → `withMuxConnectTimeout`), NOT here. Do NOT
        // re-add a `withThrowingTaskGroup` racing `client.connect` against a `Task.sleep` at THIS
        // level: that deadlocked the connect on the Mac Studio (connect() entered and never returned;
        // the host never logged the accept; the sleep never fired → the cooperative pool was jammed).
        // Wrapping only the inner NWConnection establishment (a Network.framework callback, off the
        // cooperative pool) is safe and bounded; an unreachable host now throws
        // `AislopdeskTransportError.timedOut` here in ~`handshakeTimeout` and we surface `.failed` instead
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
            // initial canvas layout settle. `AislopdeskClient.connect()` re-checks `Task.isCancelled` AFTER
            // acquiring its mux channel and, if set, tears that channel back down — closing the shared
            // connection mid-handshake while we still flip to `.connected` below (a live-looking but
            // DEAD socket: the host attaches a shell, the link drops, no `.disconnected` is observed,
            // so no reconnect fires). The connection lives in the store registry, not the view, so it
            // must outlive a view-`.task` cancellation. Establish it in an unstructured `Task` (which
            // does NOT inherit our caller's cancellation); awaiting `.value` still propagates a real
            // connect error/timeout, but `Task.isCancelled` inside is now always false. Our own
            // generation + `self.client === client` guards below remain the authority on supersession.
            try await Task { @MainActor in try await client.connect(host: host, port: port) }.value
            // Read the learned id, THEN re-check we are still the live attempt before writing any state —
            // `AislopdeskClient.connect` RETURNS (not throws) when it was closed/paused/superseded mid-handshake,
            // so without this guard a torn-down or superseded pane would be whitewashed to `.connected`.
            // `self.client === client` catches a racing teardown (it nils `self.client`); the generation
            // catches a second connect (it bumped `connectGeneration`). No `await` between guard and writes.
            let learnedID = await client.sessionID
            guard myGeneration == connectGeneration, self.client === client else { return }
            sessionID = learnedID
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
                self.terminal.resendCurrentSize()
            }
        } catch {
            guard myGeneration == connectGeneration, self.client === client else { return }
            supervisor.cancel()
            supervisorTask = nil
            status = .failed(Self.failureReason(for: error))
        }
    }

    /// The user-facing `.failed` reason for a thrown error. A `LocalizedError` (e.g.
    /// ``AislopdeskTransportError``) yields its clean `errorDescription` ("Connection timed out — host
    /// unreachable?"); ANY OTHER error falls back to `String(describing:)`, which preserves the readable
    /// Swift payload (`invalidState("resume before first connect")`) rather than Foundation's bridged
    /// "The operation couldn't be completed. (… error N.)" dump that bare `.localizedDescription` would
    /// produce for a plain `Error` enum like `AislopdeskClient.ClientError` or `CancellationError`.
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
        let wasLive: Bool
        switch status {
        case .connected, .reconnecting: wasLive = true
        default: wasLive = false
        }
        do {
            try await client.resume()
            // Same supersede guard as connect() (R6 #1): a teardown/reconnect during resume's handshake
            // nils/replaces `self.client`, so don't whitewash a torn-down pane back to `.connected`.
            guard self.client === client else { return }
            if wasLive { status = .connected }
        } catch {
            guard self.client === client else { return }
            status = .failed(Self.failureReason(for: error))   // humanized + payload-safe (see connect()'s catch)
        }
    }

    // MARK: Internals

    /// The **single** UI-layer consumer of `client.events`: it folds each event into the
    /// chrome status AND forwards it to the terminal model (one loop, two folds). The terminal
    /// model deliberately does NOT open its own `for await client.events` loop — two
    /// independent loops over the same event source would split the stream nondeterministically
    /// (a `.disconnected`/`.reconnected`/`.title` would reach only one of them, diverging the
    /// chrome and terminal statuses). `AislopdeskClient` multicasts events so the reconnect
    /// supervisor still gets its own copy; here we keep exactly one UI consumer.
    private func observeEvents(_ client: AislopdeskClient) {
        observeTask = Task { @MainActor [weak self] in
            for await event in client.events {
                guard let self else { return }
                self.foldEvent(event)
            }
        }
    }

    /// Folds one client event into the chrome `status`, then forwards EVERY event to the terminal model
    /// so its status / title / bell / exit / resume-seq stay consistent with the chrome. Extracted from
    /// `observeEvents` so the deliberate-close guards are unit-testable synchronously (R13 #3).
    private func foldEvent(_ event: AislopdeskClient.Event) {
        switch event {
        case .disconnected:
            if self.deliberatelyClosed {
                self.status = .disconnected
            } else {
                // A fresh drop: enter reconnecting with no attempt info yet (the supervisor's
                // `onProgress` enriches it with the attempt count + countdown as it retries).
                self.status = .reconnecting(attempt: 0, nextRetry: nil)
                self.terminal.markReconnecting()
            }
        case let .reconnected(sessionID, _):
            // A late .reconnected can be drained from the broadcaster buffer AFTER a deliberate
            // disconnect() (a buffered AsyncStream element is delivered even post-cancel/finish).
            // Mirror the .disconnected + applyReconnect* guards so it cannot whitewash a
            // deliberately-closed pane back to green .connected with a stale sessionID + dead transport.
            // `return` (not break) also skips the terminal.handle(event) forward below, which would
            // otherwise wedge the terminal model's connectionStatus to .connected past disconnect()'s
            // terminal.reset() (R13 #3).
            if self.deliberatelyClosed { return }
            self.sessionID = sessionID
            self.status = .connected
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
            self.terminal.resendCurrentSize()
            let reconnectedClient = self.client
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.client === reconnectedClient else { return }
                self.terminal.resendCurrentSize()
            }
        case .exit:
            self.status = .disconnected
        case let .commandStatus(commandStatus):
            // A finished command (OSC 133;D): best-effort long-command notification (macOS-only). The
            // running/idle indicator itself is folded by the terminal model below — this branch only
            // drives the notification side-effect.
            if case let .idle(exitCode, durationMS) = commandStatus {
                #if os(macOS)
                self.commandNotifier.notifyIfLong(
                    paneTitle: self.terminal.title ?? "",
                    exitCode: exitCode,
                    durationMS: durationMS
                )
                #endif
            }
        case let .rtt(milliseconds):
            self.latencyMS = milliseconds
        case .title, .bell:
            break
        }
        self.terminal.handle(event)
    }

    #if DEBUG
    /// Test hook (no production caller): fold one event synchronously through the SAME path
    /// `observeEvents` uses, so a unit test can assert the deliberate-close guards without driving the
    /// async event stream (R13 #3). `internal` + `DEBUG`-gated so it never leaks into release API.
    func foldEventForTesting(_ event: AislopdeskClient.Event) { foldEvent(event) }
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
        case .reconnecting, .disconnected:
            status = .reconnecting(attempt: attempt, nextRetry: nextRetry)
        default:
            break   // already connected / failed — do not regress
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
        case .reconnecting, .disconnected:
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
                case .input:                    break
                case let .resize(cols, rows):   try? await client.sendResize(cols: cols, rows: rows)
                }
            }
        }
        outQueue.removeAll(keepingCapacity: true)
        await client?.close()
        client = nil
        reconnect = nil
    }
}
