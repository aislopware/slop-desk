import Foundation
import RworkClient

/// Orchestrates a ``RworkClient`` + ``ReconnectManager`` for the UI: host/port entry,
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
    /// What the UI shows for the connection (mirrors + extends the terminal status with the
    /// "deliberately disconnected" distinction the terminal model can't make on its own).
    public enum Status: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        /// A transport drop is being retried by the ``ReconnectManager`` supervisor (WF3 backoff). The
        /// `attempt` is the 1-based campaign attempt and `nextRetry` (when set) is the instant the next
        /// attempt fires, so the UI can render a live "retrying in Ns" countdown via a `TimelineView`
        /// tick — a `Date?` (not a live countdown Int) keeps the case `Equatable`/`Sendable` and the
        /// model free of per-second mutation. A bare drop (before the supervisor reports an attempt)
        /// uses `attempt: 0, nextRetry: nil` ("Reconnecting…").
        case reconnecting(attempt: Int, nextRetry: Date?)
        /// Terminal WF3 give-up: the reconnect campaign exhausted `maxReconnectAttempts` (~58s) without
        /// reaching the host. Distinct from `.failed` (the *initial* connect timeout/refusal) — this is
        /// the *post-connect* host-died-and-stayed-dead state, so "connecting forever" becomes a visible
        /// "Unreachable" instead of a frozen reconnecting dot.
        case unreachable
        case failed(String)

        public var label: String {
            switch self {
            case .disconnected: return "disconnected"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case let .reconnecting(attempt, _):
                return attempt > 0 ? "reconnecting (\(attempt))" : "reconnecting"
            case .unreachable: return "unreachable"
            case .failed(let m): return "failed: \(m)"
            }
        }
    }

    // MARK: Entry fields (bound to the form)

    public var host: String
    public var port: String

    // MARK: Observable status

    public private(set) var status: Status = .disconnected
    public private(set) var sessionID: UUID?
    /// Last log line from the reconnect supervisor (surfaced in the UI for diagnostics).
    public private(set) var lastLog: String?

    // MARK: Collaborators

    private let terminal: TerminalViewModel
    private let makeClient: @Sendable () -> RworkClient
    private let backoff: ReconnectManager.Backoff

    #if os(macOS)
    /// Posts a local notification when a LONG-running command (OSC 133;D, ≥ ~10s) completes.
    /// Best-effort + lazy-auth; macOS-only (iOS still builds). The in-app running indicator is
    /// the primary deliverable and does not depend on this.
    private let commandNotifier = CommandCompletionNotifier()
    #endif

    private var client: RworkClient?
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
    /// tasks race on the reentrant `RworkClient` actor and can deliver B before A.
    ///
    /// `internal` (not `private`) so the pure ``coalesceOut(_:)`` algorithm is headlessly
    /// unit-testable beside the renderer seam; `Equatable` so a test can assert WHICH events
    /// survived a coalesce. The `.resize` payload is the libghostty grid (cols,rows) only —
    /// the wire's px/py path is driven downstream by `RworkClient.sendResize` (px/py = 0),
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

    /// `@MainActor` FIFO of buffered OUT events the single drain task BATCH-pulls (mirrors
    /// `RworkVideoHostSession.InboundQueue.drainAll`). `inputSink`/`resizeSink` append here on the
    /// main actor; `outWake` (a `bufferingNewest(1)` signal) coalesces wakeups so the drain runs
    /// once per backlog. Because the per-event `await` on the reentrant `RworkClient` actor is
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
        host: String = "127.0.0.1",
        port: UInt16 = 7420,
        backoff: ReconnectManager.Backoff = .init(),
        makeClient: @escaping @Sendable () -> RworkClient
    ) {
        self.terminal = terminal
        self.host = host
        self.port = String(port)
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
    public var activeClient: RworkClient? { client }

    /// Whether the host/port form parses to a valid endpoint.
    public var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && parsedPort != nil
    }

    private var parsedPort: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)) }

    // MARK: Lifecycle

    /// Connects to the entered host/port, starts reconnect supervision + stream observation.
    public func connect() async {
        guard let port = parsedPort else {
            status = .failed("invalid port")
            return
        }
        let host = self.host.trimmingCharacters(in: .whitespaces)

        // Tear down any prior session first (re-connect to a new target).
        await teardown()
        deliberatelyClosed = false
        terminal.reset()
        status = .connecting

        let client = makeClient()
        self.client = client

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
        outDrainTask = Task { @MainActor [weak self, weak client] in
            for await _ in outWakeups {
                guard let self else { return }
                // Atomically take + clear the whole backlog (arrival order), then coalesce: a fast
                // drag piles up between drains → collapses to ~1 resize; a slow settle leaves batch
                // size ~1 → byte-identical to forwarding each event. The trailing resize of every
                // batch always survives coalesce, so the final drag size always reaches the PTY.
                let batch = self.outQueue
                self.outQueue.removeAll(keepingCapacity: true)
                for event in Self.coalesceOut(batch) {
                    switch event {
                    case let .input(data):          try? await client?.sendInput(data)
                    case let .resize(cols, rows):   try? await client?.sendResize(cols: cols, rows: rows)
                    }
                }
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
        // `RworkTransportError.timedOut` here in ~`handshakeTimeout` and we surface `.failed` instead
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
            try await client.connect(host: host, port: port)
            sessionID = await client.sessionID
            status = .connected
        } catch {
            supervisor.cancel()
            supervisorTask = nil
            status = .failed(String(describing: error))
        }
    }

    // MARK: - Internal error types

    private enum ConnectionError: Error, CustomStringConvertible {
        case connectTimedOut(host: String, port: UInt16)

        var description: String {
            switch self {
            case let .connectTimedOut(host, port):
                return "timed out connecting to \(host):\(port)"
            }
        }
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
            if wasLive { status = .connected }
        } catch {
            status = .failed(String(describing: error))
        }
    }

    // MARK: Internals

    /// The **single** UI-layer consumer of `client.events`: it folds each event into the
    /// chrome status AND forwards it to the terminal model (one loop, two folds). The terminal
    /// model deliberately does NOT open its own `for await client.events` loop — two
    /// independent loops over the same event source would split the stream nondeterministically
    /// (a `.disconnected`/`.reconnected`/`.title` would reach only one of them, diverging the
    /// chrome and terminal statuses). `RworkClient` multicasts events so the reconnect
    /// supervisor still gets its own copy; here we keep exactly one UI consumer.
    private func observeEvents(_ client: RworkClient) {
        observeTask = Task { @MainActor [weak self] in
            for await event in client.events {
                guard let self else { return }
                // Fold into chrome status first…
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
                    self.sessionID = sessionID
                    self.status = .connected
                case .exit:
                    self.status = .disconnected
                case let .commandStatus(commandStatus):
                    // A finished command (OSC 133;D): best-effort long-command notification
                    // (macOS-only). The running/idle indicator itself is folded by the terminal
                    // model below — this branch only drives the notification side-effect.
                    if case let .idle(exitCode, durationMS) = commandStatus {
                        #if os(macOS)
                        self.commandNotifier.notifyIfLong(
                            paneTitle: self.terminal.title ?? "",
                            exitCode: exitCode,
                            durationMS: durationMS
                        )
                        #endif
                    }
                case .title, .bell:
                    break
                }
                // …then forward EVERY event to the terminal model so its status / title /
                // bell / exit / resume-seq stay consistent with the chrome.
                self.terminal.handle(event)
            }
        }
    }

    /// Folds a ``ReconnectManager`` progress callback into `status` (WF3 backoff → UI). Only enriches
    /// the `.reconnecting`/dropped states — a campaign attempt that arrives after the resume already
    /// flipped the pane back to `.connected` (the supervisor's `onProgress` for the SUCCESSFUL attempt
    /// can race the `.reconnected` event) must NOT drag a live pane back to "reconnecting". So this is a
    /// no-op unless the pane is currently reconnecting-ish (`.reconnecting`/`.disconnected`).
    func applyReconnectProgress(attempt: Int, nextRetry: Date?) {
        switch status {
        case .reconnecting, .disconnected:
            status = .reconnecting(attempt: attempt, nextRetry: nextRetry)
        default:
            break   // already connected / failed / deliberately closed — do not regress
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
        outDrainTask = nil
        // TRAILING-EDGE GUARANTEE at teardown: the async drain may have been cancelled with a
        // settled trailing resize still queued (e.g. the user stopped dragging and immediately
        // disconnected/reconnected — the wake fired but the drain lost the race to cancellation).
        // Flush the residual backlog ONCE here, synchronously on the main actor, through the SAME
        // coalesce so the final size still reaches the PTY before the client closes. This is the
        // only place the queue is drained outside the loop; `coalesceOut` keeps the last resize.
        if let client, !outQueue.isEmpty {
            let residual = outQueue
            outQueue.removeAll(keepingCapacity: true)
            for event in Self.coalesceOut(residual) {
                switch event {
                case let .input(data):          try? await client.sendInput(data)
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
