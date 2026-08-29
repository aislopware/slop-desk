import Foundation
import SlopDeskClient
import SlopDeskProtocol
import SlopDeskWorkspaceModel

/// Orchestrates a ``SlopDeskClient`` + ``ReconnectManager`` for the UI: host/port entry,
/// connect/disconnect, and a live status the chrome renders. Owns the connect lifecycle so views
/// stay declarative:
/// - ``connect()`` stands up the client, starts the reconnect supervisor + ``TerminalViewModel``
///   stream observation, and flips status `.connecting` → (on first byte) `.connected`.
/// - ``disconnect()`` is a *deliberate* close (distinct from a network drop): closes the client and
///   stops the supervisor so no reconnect is attempted.
///
/// `@MainActor @Observable`, bound directly to `ConnectionView`. Terminal byte handling is
/// delegated to the injected ``TerminalViewModel`` (one source of truth for live state).
@preconcurrency
@MainActor
@Observable
public final class ConnectionViewModel {
    /// The CHANNEL-level status this pane's dot/recovery-banner show — the per-pane channel on the
    /// shared mux (the app-wide connect-gate uses ``AppConnection/status`` instead). Hoisted to the
    /// shared ``ConnectionStatus`` so one enum drives both (docs/31).
    public typealias Status = ConnectionStatus

    // MARK: Target (app-global)

    /// Resolves the CURRENT app-global ``ConnectionTarget`` at connect-time. The pane carries no host/port
    /// of its own (docs/31): every channel rides the one shared mux at the app target, read fresh here so
    /// changing the host + reconnecting re-targets every pane. Injected (not a stored host/port) so a
    /// later host change is picked up without rebuilding the session.
    private let target: @MainActor () -> ConnectionTarget
    private let initialCwd: String?

    // MARK: Observable status

    public private(set) var status: Status = .disconnected

    /// Smoothed app-layer RTT to this pane's host in ms (`nil` until the first ping/pong). Fed by the
    /// client's 3s control-channel probe — the latency-badge / typing-lag datum (docs/26 D1/D10).
    public private(set) var latencyMS: Double?
    public private(set) var sessionID: UUID?

    // MARK: Detach/resume identity mirror

    /// The session UUID the client is currently using (presented to the host in the channelOpen
    /// preamble) — the pane's own ``PaneID``, echoed back by the host. Mirrors
    /// ``SlopDeskClient/sessionID`` after a successful connect. `nil` until the first handshake
    /// completes. Named to avoid shadowing `sessionID` (the value learned from the last `helloAck` —
    /// same thing on this path).
    public private(set) var effectiveSessionID: UUID?

    /// Highest contiguous output seq received from the host, snapshotted on the `.rtt` probe tick
    /// (~3 s) so it stays fresh without a dedicated timer. `0` until the first output chunk.
    public private(set) var snapshotedContiguousSeq: Int64 = 0

    /// Last log line from the reconnect supervisor (surfaced in the UI for diagnostics).
    public private(set) var lastLog: String?

    // MARK: Collaborators

    private let terminal: TerminalViewModel
    private let makeClient: @Sendable () -> SlopDeskClient
    private let backoff: ReconnectManager.Backoff

    /// An EXPLICIT child-requested desktop notification (OSC 9 / OSC 777). The store wires this to its
    /// pane-notification hook (a click can focus + centre this pane). `nil` ⇒ no observer (dropped).
    /// Carries the live pane title so the poster can fall back to it when an OSC 9 omits a title.
    public var onExplicitNotification: ((_ paneTitle: String, _ title: String, _ body: String) -> Void)?

    /// A live OSC title change (wire type `.title`). The store persists it into
    /// `pane/liveTitle` so a relaunch can restore the shell's last-known tab title without a
    /// manual rename. Empty strings suppressed (the host emits "" on connect before the shell sets a
    /// real one). `nil` ⇒ no observer (dropped).
    public var onTitleChanged: ((String) -> Void)?

    /// A resume-identity snapshot (SLOPDESK_DETACH_ENABLED). Fires whenever the effective session UUID
    /// or the snapshotted seq change — the ~3 s recurring post-connect edge the store hangs its
    /// git-line and cwd refreshes off. `nil` ⇒ no observer.
    public var onResumeIdentitySnapshot: ((_ sessionID: UUID, _ seq: Int64) -> Void)?

    /// A GENUINE reconnect edge (`.reconnected` — distinct from the ~3 s RTT snapshot that also drives
    /// ``onResumeIdentitySnapshot``). Fired once when a dropped link comes back on a fresh host shell, so
    /// the store can unconditionally re-fetch drift-prone state — the sidebar git line (C3 BUG C a: a
    /// sibling-pane commit / detached-session drift the pane missed). `nil` ⇒ no observer.
    public var onReconnected: (() -> Void)?

    /// C8 improvement 1: the fresh-vs-resumed verdict for a completed RECONNECT, forwarded from the
    /// terminal model (which alone derives it from the first post-reconnect output seq). The store wires
    /// this to a per-pane toast — warm reattach ("session preserved") vs fresh shell ("previous session
    /// ended"). Fired at most once per drop→reconnect; never on a first-ever connect or a deliberate
    /// ⇧⌘R. `nil` ⇒ no observer (dropped).
    public var onResumeOutcomeResolved: ((_ outcome: SlopDeskClient.SessionResumeOutcome) -> Void)?

    /// A Claude-Code agent-detection signal (wire types 26/27 — `.foregroundProcess` / `.claudeStatus`).
    /// The store wires this to the owning pane's ``LivePaneSession`` so it folds the signal into the
    /// pane's `ClaudeStatusMachine` and pushes the result to ``WorkspaceStore/setAgentStatus(_:for:)``.
    /// `nil` ⇒ no observer (dropped). Only these two agent-detect events are forwarded here;
    /// all others still drive the chrome/terminal.
    public var onAgentSignal: ((_ event: SlopDeskClient.Event) -> Void)?

    /// A finished command (OSC 133;D, wire type 23) — the lighter idle/completion signal carrying its
    /// exit code + C→D duration. The store wires this to ``WorkspaceStore/handleCommandCompleted(id:exitCode:durationMS:paneTitle:)``
    /// so the FOCUS GATE applies: a background completion badges the pane; a backgrounded LONG command
    /// fires the desktop notification (a foreground one does not). `nil` ⇒ no observer (dropped).
    /// Cross-platform (the store owns the macOS-only poster behind its `onLongCommandNotify` sink).
    public var onCommandCompleted: ((_ exitCode: Int32?, _ durationMS: UInt32) -> Void)?

    /// A command-START edge (OSC 133;C / `.commandStatus(.running)`). The store wires this to
    /// ``WorkspaceStore/handleCommandStarted(id:)`` so a new run CLEARS the pane's stale completion badge
    /// before its spinner resolves (a busy background pane must not show the previous run's ✓/✗). `nil` ⇒
    /// no observer. The running/idle indicator itself is still folded by the terminal model via `terminal.handle`.
    public var onCommandStarted: (() -> Void)?

    /// An OSC 9;4 taskbar-style PROGRESS update (wire type 32). The store wires this to
    /// ``WorkspaceStore/handleProgress(_:for:)`` so the validated state lands in the per-pane `paneProgress`
    /// mirror (→ the sidebar tab badge + the macOS Dock aggregate). A ``ProgressState/clear`` arrives as
    /// `nil` (remove the indicator). `nil` ⇒ no observer (dropped); the terminal model still folds its own
    /// observable `progress` mirror via `terminal.handle` regardless.
    public var onProgressUpdate: ((_ progress: PaneProgress?) -> Void)?

    /// A HOST-derived cwd edge (wire type 33). The store persists this into
    /// `pane/cwd` so the tab's cwd line + cwd inheritance follow the live cwd
    /// immediately. Host-gated single-source (``MuxChannelSession.deriveProjectKey``): the host
    /// emits only warm-up-gated, dedupe-anchored, probe-preferred change edges (plus the reattach
    /// re-assert), so — like `.projectKey` — it is applied UNGATED here; the plugin-dir poison
    /// backstop stays at the store's write sink (``WorkspaceStore/setLastKnownCwd(_:for:)``).
    public var onWorkingDirectoryChanged: ((_ cwd: String) -> Void)?

    /// A HOST-computed By-Project key edge (wire type 34): the git worktree toplevel containing the
    /// pane's cwd, else the cwd. The store persists it into `pane/projectKey` (the sidebar's
    /// By-Project sectioning key). Applied ungated, like `.cwd` — the host re-asserts the latched key
    /// on reattach BEFORE any command runs, and that re-assert is exactly what makes a reconnect
    /// render the final sections without a flicker; transient plugin-dir poison is dropped at the
    /// store's write sink instead (``WorkspaceStore/setProjectKey(_:for:)``).
    public var onProjectKeyChanged: ((_ key: String) -> Void)?

    /// A HOST-PUSHED project git summary (wire type 35): the FSEvents watcher's event-driven
    /// `git status` fold for one repo toplevel, already reduced to counts host-side. The store books
    /// it per PROJECT (``WorkspaceStore/applyPushedProjectGitSummary(_:repoRoot:at:)``) — the section
    /// header updates without any client RPC, and the poll cadence backs off while pushes stay
    /// fresh. Applied ungated like `.projectKey`; the plugin-dir poison backstop lives at the store
    /// sink.
    public var onProjectGitStatusChanged: ((_ summary: PaneGitSummary, _ repoRoot: String) -> Void)?

    /// A HOST-latched agent-session intent edge (wire type 36): the session's first titleable
    /// prompt, sticky per session. The store mirrors it per pane (the sidebar's agent-row title).
    /// Every edge forwards — empty is the CLEAR (session ended), which must reach the store.
    public var onAgentIntentChanged: ((_ intent: String) -> Void)?

    private var client: SlopDeskClient?
    /// The pane's typed metadata façade, created on connect bound to the live ``client``, torn down
    /// on disconnect. Drives the sidebar git line + Open-Quickly/path actions; this VM folds inbound
    /// `.metadataResponse` events into its pending-request registry. `nil` while disconnected.
    private var metadataClient: MetadataClient?
    /// The connect ladder: the generation this pane's attempts are numbered by, and the three
    /// latches that say what a `.disconnected` MEANT.
    ///
    /// `connect()`/`resume()` quote the generation before the long handshake `await`; a teardown /
    /// reconnect / second connect landing during that suspension means the post-await
    /// `status`/`sessionID` writes belong to a SUPERSEDED attempt and must be discarded. Needed
    /// because `SlopDeskClient.connect` RETURNS (not throws) when closed/paused/superseded
    /// mid-handshake — else the `do` branch whitewashes an already-torn-down pane to `.connected`.
    /// Every decision on those four scalars is `rust/slopdesk-workspace`'s `connect_run`, including
    /// the reap/eviction asymmetry; this side performs what it answers. See ``ConnectRun``.
    private let connectRun = ConnectRun()
    private var reconnect: ReconnectManager?
    /// Single-flight guard for ``connect()``. `connect()` is `@MainActor`, but its body
    /// SUSPENDS at `await teardown()` (which awaits `outDrainTask?.value` / `client?.close()`), so two
    /// overlapping calls — a double / key-repeated "Reconnect Pane" — could interleave: the second call's
    /// teardown cancel-prefix runs BEFORE the first built its client/observe/output/supervisor tasks,
    /// leaving the first attempt's client alive with nothing to cancel or close it (a supervised zombie
    /// whose output keeps painting into the pane). Chaining each attempt after the prior one SERIALIZES
    /// them: the second's teardown then closes+cancels the first's fully-built client, so no zombie leaks.
    private var connectTask: Task<Void, Never>?
    private var supervisorTask: Task<Void, Never>?
    /// The single events loop (chrome status + forward to the terminal model).
    private var observeTask: Task<Void, Never>?
    /// The terminal model's `output` byte-pump loop (separate from events).
    private var outputTask: Task<Void, Never>?

    /// Serial OUT path (renderer → host). Keystrokes + resizes funnel through ONE ordered FIFO drained
    /// by ONE task, so a fast burst (typing / multi-segment paste / an escape sequence split across
    /// writes) reaches the host PTY IN ORDER. A per-event `Task { await client.sendInput }` does NOT
    /// preserve order — independent unstructured tasks race on the reentrant `SlopDeskClient` actor and
    /// can deliver B before A.
    ///
    /// `internal` (not `private`) so ``ConnectGate/plan(_:maxInputFrameBytes:)`` — which is what
    /// decides how this FIFO leaves — is headlessly testable; `Equatable` so a test can assert WHICH
    /// events survived. The `.resize` payload is the libghostty grid (cols,rows) only — the wire's
    /// px/py path is driven downstream by `SlopDeskClient.sendResize` (px/py = 0), unchanged.
    enum OutEvent: Equatable { case input(Data)
        case resize(cols: UInt16, rows: UInt16)
    }

    /// Sends one planned batch over `client`, sequentially (the single-consumer FIFO leg).
    ///
    /// The plan — resizes coalesced latest-wins with input as a hard barrier, input payloads merged
    /// and oversized ones split at the data sub-channel's ceiling — is
    /// ``ConnectGate/plan(_:maxInputFrameBytes:)``, which crosses lengths rather than bytes; see its
    /// doc for why the boundary sits there. Shared by the off-main drain and headless tests. Errors
    /// are swallowed per-event (`try?`) as the old inline drain did — disconnected sends drop.
    nonisolated static func sendBatch(_ batch: [OutEvent], over client: SlopDeskClient) async {
        for event in ConnectGate.plan(batch) {
            switch event {
            case let .input(data): try? await client.sendInput(data)
            case let .resize(cols, rows): try? await client.sendResize(cols: cols, rows: rows)
            }
        }
    }

    /// `@MainActor` FIFO of buffered OUT events the single drain task BATCH-pulls (mirrors
    /// the video daemon's own inbound queue drain). `inputSink`/`resizeSink` append here on the
    /// main actor; `outWake` (a `bufferingNewest(1)` signal) coalesces wakeups so the drain runs once per
    /// backlog. Because the per-event `await` on the reentrant `SlopDeskClient` actor is slower than the
    /// main-actor appends during a drag, the queue accumulates between drains → a fast drag collapses to
    /// ~1 resize via ``ConnectGate/plan(_:maxInputFrameBytes:)``; a slow settle keeps batch size ~1 so
    /// it is byte-identical to
    /// forwarding each event (same self-regulating property as the host inbound pump). One ordered
    /// consumer, no per-resize Task — satisfies the anti-reorder rule.
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

    /// The terminal view-model (so the view can pass it to ``TerminalLeafView``).
    public var terminalModel: TerminalViewModel { terminal }

    /// The pane's SHELL activity (OSC 133): `.running` while a command executes, else `.idle`.
    /// Orthogonal to ``status`` — a pane is `.connected` AND running/idle. Read-through to the terminal
    /// model so the chrome / sidebar / palette can show a running indicator.
    public var shellActivity: TerminalViewModel.ShellActivity { terminal.shellActivity }

    /// The live client (so the input bar can `sendInput`). `nil` while disconnected.
    public var activeClient: SlopDeskClient? { client }

    /// The pane's typed metadata façade, or `nil` while disconnected. The sidebar git line,
    /// Open-Quickly, and host-path actions bind to this to fetch cwd/git status over the wire.
    public var activeMetadataClient: MetadataClient? { metadataClient }

    // MARK: Lifecycle

    /// Opens this pane's CHANNEL on the shared mux at the current app target, starting reconnect
    /// supervision + stream observation. Host/port come from the app-global ``ConnectionTarget`` (the
    /// connect-gate dialled them) — the pane has no host/port form of its own.
    ///
    /// SINGLE-FLIGHT: the real work is ``performConnect()``; this wrapper CHAINS each
    /// attempt after any in-flight one so two overlapping calls (a double / held ⇧⌘R "Reconnect Pane")
    /// can't interleave their teardown/build and leak a live zombie client into the pane. The synchronous
    /// `status = .connecting` lands BEFORE the first `await` so a re-entrant ``connectIfNeeded()`` sees
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
        // caller observes `.connecting` and does NOT double-dial a second client onto this pane while it
        // is still standing up its mux channel. The re-entrant caller is real: the leaf's dial is a
        // cancel-and-restart `Task` keyed by `TerminalLeafPolicy.dialTaskKey`, and the leaf's own
        // detach/attach (a split re-parent) plus a key move can both restart it while the first dial is
        // still in flight.
        status = .connecting
        // Tear down any prior session first (re-connect to a new target).
        await teardown()
        terminal.reset()

        let client = makeClient()
        self.client = client
        // Open an EXPLICIT attempt. It claims a generation — a teardown/reconnect/second connect
        // during the handshake `await` below supersedes us, and the post-await status writes are
        // then discarded — and clears all three latches, because an explicit re-dial ("Reconnect
        // Pane", the connect-gate) overrides EITHER host close: the user is asking for a shell on
        // this pane, and `makeClient()` above builds a client carrying none of the old one's state.
        let myGeneration = connectRun.begin()

        // OUT path (renderer → host): the terminal model's `sendInput`/`sendResize` (driven by
        // `GhosttyTerminalView`'s onWrite/onResize) append into ONE main-actor FIFO; a single drain task
        // BATCH-pulls it, PLANS it (latest-wins resizes, `.input` as a barrier — see `ConnectGate.plan`),
        // and awaits the client SEQUENTIALLY so bytes/resizes are never reordered. The wake is a
        // `bufferingNewest(1)` signal so N appends collapse to one drain. Captures `weak client/self` so a
        // torn-down client is never targeted; `teardown()` finishes the wake + cancels the drain + nils
        // the sinks (a final drain flushes a settled trailing resize — TRAILING-EDGE GUARANTEE).
        outQueue.removeAll(keepingCapacity: true)
        let (outWakeups, outWake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        outWakeContinuation = outWake
        // OFF-MAIN drain: appends stay on the main actor (true call order) but the consumer runs DETACHED,
        // hopping to main ONLY to atomically swap out the batch array — so a keystroke's send does not
        // queue behind flood-ingest/render main-actor work (an on-main consumer would tie input latency to
        // main-thread depth during a flood). The ordering invariant needs ONE serial consumer, not main-actor residence:
        // (i) appends are serial on the main actor in call order, (ii) the batch take is atomic on the
        // main actor, (iii) this single task awaits sends sequentially.
        outDrainTask = Task.detached(priority: .userInitiated) { [weak self, weak client] in
            for await _ in outWakeups {
                guard let self, let client else { return }
                // Atomically take + clear the whole backlog (arrival order), then coalesce: a fast drag
                // piles up between drains → collapses to ~1 resize; a slow settle leaves batch size ~1 →
                // byte-identical to forwarding each event. The trailing resize of every batch always
                // survives coalesce, so the final drag size always reaches the PTY.
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
        // The Block-output request sink (wire type 15), fired by the terminal model's copy-output flow
        // (``TerminalViewModel/copyBlockOutput(index:onResult:)``). Rides CONTROL, not the windowed OUT
        // FIFO — a single small control frame whose reply (type 29) the inbound pump surfaces; it never
        // needs to order against keystrokes/resizes. Fire-and-forget: a dropped request resolves via the
        // model's timeout (the copy UI never hangs). Captures `weak client`.
        terminal.requestBlockOutputSink = { [weak client] index in
            Task { try? await client?.requestBlockOutput(index: index) }
        }
        // C8 improvement 1: forward the terminal model's fresh-vs-resumed reconnect verdict up to the store
        // (→ a per-pane toast). Set once here alongside the other sinks; a supervisor-driven reconnect does
        // NOT re-run connect(), so this sink stays live to catch the verdict resolved after it.
        terminal.onResumeOutcomeResolved = { [weak self] outcome in
            self?.onResumeOutcomeResolved?(outcome)
        }

        // The pane's metadata façade. Its `send` seam fires a `requestMetadata` on the CONTROL channel
        // (wire type 16); the reply (type 30) is surfaced as a `.metadataResponse` event and folded into
        // this façade's registry by `foldEvent` below. Captures `weak client`; the registry's timeout + a
        // teardown `cancelAll()` guarantee no await hangs.
        metadataClient = MetadataClient(send: { [weak client] requestID, verb, payload in
            try? await client?.requestMetadata(requestID: requestID, verb: verb, payload: payload)
        })

        // Single UI-layer events loop (chrome status + forward to the terminal model).
        observeEvents(client)
        // Separate output byte-pump for the terminal model (output has a single consumer).
        outputTask = Task { @MainActor [weak self] in
            await self?.terminal.observe(client: client)
        }

        // Reconnect supervisor: drives byte-exact resumes on a drop. Its progress/give-up callbacks publish
        // the WF3 backoff state onto `status` so the chrome surfaces an attempt-aware "reconnecting" (with
        // a countdown) and a terminal "unreachable" instead of a frozen dot. The callbacks are `@Sendable`
        // and hop onto the main actor; they only ENRICH the `.reconnecting` the events loop already set on
        // the drop (`observeEvents`), so a recovery (`onLog "resumed"` → `.reconnected` → `.connected`) wins.
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

        // DEAD-HOST TIMEOUT: the ~10s ceiling lives at the TRANSPORT layer
        // (`LiveMuxConnectionFactory.makeConnection` → `withMuxConnectTimeout`), NOT here. Do NOT re-add a
        // `withThrowingTaskGroup` racing `client.connect` against a `Task.sleep` at THIS level: that
        // deadlocked the connect on the Mac Studio (connect() entered and never returned; the host never
        // logged the accept; the sleep never fired → the cooperative pool jammed). Wrapping only the inner
        // NWConnection establishment (a Network.framework callback, off the cooperative pool) is safe and
        // bounded; an unreachable host throws `SlopDeskTransportError.timedOut` here in ~`handshakeTimeout`
        // and we surface `.failed` instead of hanging at "connecting" forever.
        // Start the reconnect supervisor BEFORE `connect()` so its subscription to `client.events`
        // (registered eagerly in `manager.start`) is live before any drop. Starting it AFTER a successful
        // connect opens a window where a fast `.disconnected` is yielded to no subscriber and LOST — the
        // pane then sticks at "reconnecting" with no retry. The supervisor only ACTS
        // on a `.disconnected`; before/around connect there are none, so this is inert until a real drop.
        // On an initial-connect failure there is no session to resume, so it is cancelled in the catch.
        let supervisor = manager.start(host: host, port: port)
        supervisorTask = supervisor
        do {
            // CANCELLATION SHIELD (canvas auto-connect bug): the lazy connect-on-remount runs inside a
            // Task the LEAF owns, which it CANCELS and restarts whenever its dial key moves or it leaves
            // the view tree — a split re-parent during the initial layout settle does exactly that.
            // `SlopDeskClient.connect()` re-checks `Task.isCancelled` AFTER acquiring its mux channel and,
            // if set, tears that channel back down — closing the shared connection mid-handshake while we
            // still flip to `.connected` below (a live-looking but DEAD socket: the host attaches a shell,
            // the link drops, no `.disconnected` is observed, so no reconnect fires). The connection lives
            // in the store registry, not the leaf, so it must outlive the leaf's cancellation. Establish it
            // in an unstructured `Task` (which does NOT inherit the caller's cancellation); awaiting
            // `.value` still propagates a real connect error/timeout, but `Task.isCancelled` inside is now
            // always false.
            //
            // ⚠️ THE APPKIT/UIKIT REBUILD DID NOT RETIRE THIS. The cancellation used to be SwiftUI's — a
            // `.task(id:)` torn down with the body that declared it — and it is now the leaf's own
            // `dialTask?.cancel()`. Same edge, same hazard, one fewer framework in the story.
            try await Task { @MainActor in
                await client.setInitialCwd(initialCwd)
                try await client.connect(host: host, port: port)
            }.value
            // Read the learned id, THEN re-check we are still the live attempt before writing any state —
            // `SlopDeskClient.connect` RETURNS (not throws) when closed/paused/superseded mid-handshake, so
            // without this guard a torn-down/superseded pane would be whitewashed to `.connected`.
            // `self.client === client` catches a racing teardown (it nils `self.client`); the generation
            // catches a second connect (it opened a newer attempt). No `await` between guard and writes.
            let learnedID = await client.sessionID
            guard connectRun.isCurrent(myGeneration), self.client === client else { return }
            sessionID = learnedID
            effectiveSessionID = learnedID
            if let learnedID { onResumeIdentitySnapshot?(learnedID, 0) }
            status = .connected
            // The host PTY is now ready to accept a resize. Re-send the renderer's current grid: any resize
            // that fired during the handshake threw `sendResize before connect` and was dropped (the OUT
            // drain's `try?`), but the model recorded it as sent — so without this the dedup would pin the
            // host at its 80×24 init grid (overlapping glyphs / fzf at the wrong row).
            terminal.resendCurrentSize()
            // …and again shortly after: the host's CONTROL-channel reader (which applies resize via
            // TIOCSWINSZ) may not be pumping the instant connect returns, so a resize sent now can be
            // dropped at the mux before it is read (input/output ride the DATA channel and only flow once
            // the user types — past this window — so they never hit this race). Re-assert when the reader
            // is reliably live; the host debounces duplicates, so the extra send is free.
            Task { @MainActor [weak self, weak client] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.client === client else { return }
                terminal.resendCurrentSize()
            }
        } catch {
            guard connectRun.isCurrent(myGeneration), self.client === client else { return }
            supervisor.cancel()
            supervisorTask = nil
            status = .failed(ConnectGate.failureReason(for: error))
        }
    }

    /// The LAZY connect-on-remount entry point — the body of the leaf's dial `Task`, which the leaf
    /// cancels and restarts whenever `TerminalLeafPolicy.dialTaskKey` moves or the leaf leaves and rejoins
    /// the view tree. That happens on a split re-parent and on a pane whose session was swapped, with the
    /// live session unchanged. Unlike ``connect()`` — which deliberately TEARS DOWN the session and wipes the terminal
    /// replay ring to dial a (possibly new) target — this MUST be IDEMPOTENT: a healthy or in-flight
    /// channel is left untouched, so the retained ``TerminalViewModel/ring`` survives the remount and
    /// ``TerminalViewModel/attachSurface(_:)`` can repaint the prior screen. Only a genuinely idle/dead
    /// channel dials. `.reconnecting` is owned by the supervisor (its backoff campaign is mid-flight), so
    /// it is left alone too — a remount must not short-circuit it.
    ///
    /// Regression guard: calling ``connect()`` unconditionally from the leaf's dial task on every restart
    /// would tear down a healthy session — `terminal.reset()` empties the ring, so the
    /// pane comes back blank and re-dials a fresh host shell, losing all scrollback history. The explicit
    /// reconnect paths ("Reconnect Pane", the connect-gate) still call ``connect()`` directly, so their
    /// force-redial semantics are unaffected.
    public func connectIfNeeded() async {
        // A pane the HOST REAPED is not an idle channel waiting to be woken. Both AUTOMATIC dial
        // paths land here — the leaf's dial task and
        // ``WorkspaceStore/redialDisconnectedPanes()`` — and the status they would act on is
        // `.disconnected`, which is exactly the arm that dials. Gating on the reason, not on the
        // status, is what keeps a re-dial from slipping in behind the document diff.
        //
        // An EVICTION is deliberately NOT gated here — it leaves the pane running and
        // in the topology, so this is where it comes back: the fan-out fires when the app
        // connection re-establishes and the remount when the user returns to the tab, and both are
        // one-shot events rather than the campaign's immediate retry. Gating it here is what left
        // an evicted client rendering a pane it could never reattach to.
        guard connectRun.mayAutoDial else { return }
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

    /// A deliberate disconnect: close the client + stop the supervisor (no reconnect).
    public func disconnect() async {
        connectRun.closeDeliberately()
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
    /// A no-op for a pane that was never connected. `WorkspaceStore.resumeAll()` fans `resume()` out to
    /// EVERY materialized session on foreground — including idle panes still showing the connect form
    /// (`client == nil`). The old code unconditionally set `status = .connected` after `try await
    /// client?.resume()`, and with `client == nil` the optional chain is a silent nil (no throw), so an
    /// idle pane FALSELY reported `.connected` → `PaneLeafView` hid the connect form, stranding a dead
    /// empty terminal. Guard on a live client, and only re-assert `.connected` when the pane was in a
    /// connected-ish state before the pause (so a `.failed`/`.disconnected` client is not whitewashed).
    public func resume() async {
        guard let client else { return }
        // Capture the pre-resume state: pause() does not change `status`, so a connection live (or
        // mid-reconnect) before backgrounding is still `.connected`/`.reconnecting`. Only such a pane
        // should snap back to `.connected`; a never-up client must not.
        let wasLive =
            switch status {
            case .connected,
                 .reconnecting: true
            default: false
            }
        do {
            try await client.resume()
            // Same supersede guard as connect(): a teardown/reconnect during resume's handshake
            // nils/replaces `self.client`, so don't whitewash a torn-down pane to `.connected`.
            guard self.client === client else { return }
            if wasLive { status = .connected }
        } catch {
            guard self.client === client else { return }
            status = .failed(ConnectGate.failureReason(for: error)) // humanized (see connect()'s catch)
        }
    }

    // MARK: Internals

    /// The **single** UI-layer consumer of `client.events`: folds each event into the chrome status AND
    /// forwards it to the terminal model (one loop, two folds). The terminal model deliberately does NOT
    /// open its own `for await client.events` loop — two independent loops over the same source would
    /// split the stream nondeterministically (a `.disconnected`/`.reconnected`/`.title` reaching only one,
    /// diverging the chrome and terminal statuses). `SlopDeskClient` multicasts events so the reconnect
    /// supervisor still gets its own copy; here we keep exactly one UI consumer.
    private func observeEvents(_ client: SlopDeskClient) {
        observeTask = Task { @MainActor [weak self] in
            for await event in client.events {
                guard let self else { return }
                // WHY a drop is a drop is not knowable from the event: a per-channel `channelClose`
                // ends the stream exactly as a link failure does, and only the client (which asked
                // its transport, which asked the mux) can tell them apart — and tell the two host
                // closes apart from each other. Asked here, ONCE, on the `.disconnected` edge — the
                // fold itself stays synchronous, and every other event skips the hop.
                if case .disconnected = event {
                    switch await client.hostChannelCloseReason {
                    case .retired: connectRun.noteHostClose(.retired)
                    case .subscriberEvicted: connectRun.noteHostClose(.evicted)
                    case nil: connectRun.noteHostClose(.link) // the link died; nothing was said here
                    }
                }
                foldEvent(event)
            }
        }
    }

    /// Folds one client event into the chrome `status`, then forwards EVERY event to the terminal model so
    /// its status / title / bell / exit / resume-seq stay consistent with the chrome. Extracted from
    /// `observeEvents` so the deliberate-close guards are unit-testable synchronously.
    private func foldEvent(_ event: SlopDeskClient.Event) {
        switch event {
        case .disconnected:
            // A dropped link's last OSC 9;4 is a lie for the reconnect — clear the store's per-pane progress
            // mirror (the badge source) so it agrees with the terminal model, which clears its own
            // `progress` on the same edge (no stuck spinner across a drop/reconnect). The fresh shell
            // re-reports its own.
            onProgressUpdate?(nil)
            // Both host closes read as deliberate too — they ARE deliberate, just decided at the
            // other end. No campaign will follow either (``ReconnectManager`` gates on the same
            // fact), so showing "reconnecting" would be a spinner for a retry nobody is making.
            // That the eviction is RECOVERABLE does not make it a retry: what recovers it is the
            // fan-out or the user, and until one of them happens the pane is honestly disconnected.
            if connectRun.disconnectIsQuiet {
                status = .disconnected
            } else {
                // A fresh drop: enter reconnecting with no attempt info yet (the supervisor's `onProgress`
                // enriches it with the attempt count + countdown as it retries).
                status = .reconnecting(attempt: 0, nextRetry: nil)
                terminal.markReconnecting()
            }
        case let .reconnected(sessionID, _):
            // A late .reconnected can be drained from the broadcaster buffer AFTER a deliberate
            // disconnect() (a buffered AsyncStream element is delivered even post-cancel/finish). Mirror
            // the .disconnected + applyReconnect* guards so it cannot whitewash a deliberately-closed pane
            // back to green .connected with a stale sessionID + dead transport. `return` (not break) also
            // skips the terminal.handle(event) forward below, which would otherwise wedge the terminal
            // model's connectionStatus to .connected past disconnect()'s terminal.reset().
            if !connectRun.reconnectIsWelcome { return }
            self.sessionID = sessionID
            effectiveSessionID = sessionID
            onResumeIdentitySnapshot?(sessionID, snapshotedContiguousSeq)
            status = .connected
            // C3 BUG C a: a genuine reconnect edge — let the store unconditionally refresh drift-prone
            // state (the sidebar git line) that the ~3 s snapshot only re-fetches under a staleness window.
            onReconnected?()
            // RECONNECT GRID RE-ASSERT (fixes the misaligned/garbled render on reconnect). A reconnect spawns a
            // BRAND-NEW host shell (the mux path has no server-side resume — see
            // `TerminalViewModel.markReconnecting`), whose PTY starts at its 80×24 init size. connect()'s
            // grid re-assert (resendCurrentSize + a +400ms re-assert) runs ONLY on the initial connect,
            // NOT here — the supervisor re-establishes the session internally and only emits this event.
            // Without re-sending the renderer's real grid, the new PTY stays at 80×24 while libghostty
            // renders the layout-derived grid (e.g. 79×22), so zsh wraps at the wrong column and TUIs draw
            // at the wrong row (overlapping / skewed glyphs). Mirror connect()'s two-shot re-assert: now,
            // then again after the host control-reader is reliably pumping (it may not be the instant the
            // resume completes, so an immediate-only send can be dropped at the mux before it is read; the
            // host debounces duplicates, so the second send is free).
            terminal.resendCurrentSize()
            let reconnectedClient = client
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, client === reconnectedClient else { return }
                terminal.resendCurrentSize()
            }
        case .exit:
            status = .disconnected
            // A terminated shell reports no progress — clear the store's per-pane mirror to match the
            // terminal model's own `.exit` clear (no stuck OSC 9;4 spinner on a dead pane).
            onProgressUpdate?(nil)
        case let .commandStatus(commandStatus):
            // A finished command (OSC 133;D): route the completion to the store, which owns the FOCUS GATE
            // (badge an unfocused pane; notify only for a backgrounded long command). Moving the notify
            // decision off this VM is what lets a foreground long command stay silent — the VM does not
            // know which leaf is active. The running/idle indicator itself is folded by the terminal model
            // below — this branch only drives the start/completion side-effects.
            switch commandStatus {
            case .running:
                // The command-START edge clears a STALE completion badge in the store (a new run resets the
                // prior exit ✓/✗ before the spinner resolves). The terminal model still sets `.running`.
                onCommandStarted?()
            case let .idle(exitCode, durationMS):
                onCommandCompleted?(exitCode, durationMS)
            }
        case let .notification(title, body):
            // An EXPLICIT child-requested notification (OSC 9 / OSC 777). Hand it to the store's
            // pane-notification hook with the live pane title (the OSC-9 title fallback). Pure
            // side-effect; the running/idle indicator is unaffected.
            onExplicitNotification?(terminal.title ?? "", title, body)
        case let .rtt(milliseconds):
            latencyMS = milliseconds
            // Piggyback a seq snapshot on the RTT tick (~3 s) so the store can persist the live
            // highestContiguousSeq without a dedicated timer. Actor-isolated read; safe because we hop
            // onto MainActor inside an already-MainActor foldEvent call.
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
            // agent-status hook (which folds it into the pane's ClaudeStatusMachine). Pure side-effect —
            // the chrome status is unaffected.
            onAgentSignal?(event)
        case .commandBlock,
             .blockOutput:
            // Warp-style Blocks (wire types 28/29): folded into the terminal model's per-pane block
            // store below (terminal.handle). Chrome status unaffected.
            break
        case let .metadataResponse(requestID, status, payload):
            // Host metadata reply (wire type 30): correlate it to the pending request in the pane's
            // metadata façade (the typed MetadataClient decodes the payload for the Details Panel). Chrome
            // status unaffected. A reply for an unknown/already-resolved id is dropped by the registry, so
            // a stale type-30 after a pane switch is harmless.
            metadataClient?.resolve(requestID: requestID, status: status, payload: payload)
        case let .title(text):
            // Fold the live shell title into `pane/liveTitle`. Empty strings suppressed — the host
            // emits "" on connect before the shell sets a real one.
            // "Title — Shell Controlled" (default ON): when OFF, the SAME fire-time gate the VM
            // applies to `TerminalViewModel.handle(.title)` must ALSO gate this path — otherwise a
            // remote OSC 0/2 title still lands in `pane/liveTitle` and leaks onto the sidebar rail
            // (which sources its row title from there). Gating here keeps the rail consistent with
            // the VM display gate.
            if SettingsKey.titleShellControlledEnabled, !text.isEmpty { onTitleChanged?(text) }
        case .inputEcho:
            // Secure input (wire type 31): the host PTY echo edge. The terminal model folds it
            // (`terminal.handle` below) into `hostNoEcho` → the `secureInputActive` pill mirror + the macOS
            // leaf's `SecureKeyboardEntryController`. No connection-layer side effect.
            break
        case let .progress(state, percent):
            // OSC 9;4 PROGRESS (wire type 32): route the validated taskbar-style progress to the
            // store's per-pane mirror (→ the sidebar tab badge + the macOS Dock aggregate). The terminal
            // model ALSO folds it (`terminal.handle` below) into its observable `progress` mirror for the
            // pane status strip / Dock read. `PaneProgress(state:percent:)` maps a `.clear` to `nil`.
            onProgressUpdate?(PaneProgress(state: state, percent: percent))
        case let .cwd(path):
            // Host-derived cwd truth (wire type 33): forward every non-empty edge to the store's guarded
            // write sink, UNGATED — the host is the single type-33 source (warm-up-gated change edges +
            // the reattach re-assert; `MuxChannelSession.deriveProjectKey`), so a client-side
            // first-command gate would only re-drop the re-assert and leave the tab's cwd line stale
            // across a reconnect. Plugin-dir poison is dropped at
            // ``WorkspaceStore/setLastKnownCwd(_:for:)``, mirroring `.projectKey` below.
            guard !path.isEmpty else { break }
            onWorkingDirectoryChanged?(path)
        case let .projectKey(path):
            // Host-computed By-Project key (wire type 34): forward every non-empty edge to the store's
            // guarded write sink — the host's reattach re-assert lands before any command, and dropping
            // it would reintroduce the reconnect section flicker the host-side computation exists to
            // remove.
            guard !path.isEmpty else { break }
            onProjectKeyChanged?(path)
        case let .projectGitStatus(status):
            // Host-pushed project git summary (wire type 35): fold to the domain value here (the
            // store stays wire-free) and forward with the repo identity. An empty root is meaningless
            // (the watcher only watches resolved toplevels) — validate-then-drop.
            guard !status.repoRoot.isEmpty else { break }
            onProjectGitStatusChanged?(PaneGitSummary(pushed: status), status.repoRoot)
        case let .agentSessionIntent(intent):
            // Host-latched agent-session intent (wire type 36): forward EVERY edge — empty is the
            // CLEAR frame (session ended / claude gone), which must reach the store or a dead
            // session's task line would squat on the row title forever.
            onAgentIntentChanged?(intent)
        case .bell:
            break
        }
        terminal.handle(event)
    }

    #if DEBUG
    /// Test hook (no production caller): fold one event synchronously through the SAME path
    /// `observeEvents` uses, so a unit test can assert the deliberate-close guards without driving the
    /// async event stream. `internal` + `DEBUG`-gated so it never leaks into release API.
    func foldEventForTesting(_ event: SlopDeskClient.Event) { foldEvent(event) }
    #endif

    /// Folds a ``ReconnectManager`` progress callback into `status` (WF3 backoff → UI).
    ///
    /// The DECISION is ``ConnectGate/reconnectFold(status:deliberatelyClosed:gaveUp:)``; what is left
    /// here is the mutation, because the `@Observable` property is Swift's. `attempt` and `nextRetry`
    /// never cross — the rule reads neither, so they stay on this side as the payload of the status
    /// it says to adopt.
    func applyReconnectProgress(attempt: Int, nextRetry: Date?) {
        guard case .reconnecting = ConnectGate.reconnectFold(
            status: status, deliberatelyClosed: connectRun.wasClosedDeliberately, gaveUp: false,
        ) else { return }
        status = .reconnecting(attempt: attempt, nextRetry: nextRetry)
    }

    /// Folds the terminal "gave up after maxReconnectAttempts" callback into `status`: a pane stuck
    /// reconnecting flips to `.unreachable` (the visible WF3 give-up state). Same rule, same two
    /// races — see ``ConnectGate/reconnectFold(status:deliberatelyClosed:gaveUp:)``.
    func applyReconnectGaveUp() {
        guard case .unreachable = ConnectGate.reconnectFold(
            status: status, deliberatelyClosed: connectRun.wasClosedDeliberately, gaveUp: true,
        ) else { return }
        status = .unreachable
    }

    private func teardown() async {
        supervisorTask?.cancel()
        observeTask?.cancel()
        outputTask?.cancel()
        supervisorTask = nil
        observeTask = nil
        outputTask = nil
        // Drop the OUT-path sinks + tear down the serial drain before releasing the client so the renderer
        // cannot route keystrokes/resizes into a closed client.
        terminal.inputSink = nil
        terminal.resizeSink = nil
        // Drop the Block-output request sink too — a copy-output request after teardown then resolves
        // immediately as "unavailable" (no live client to ask) rather than targeting a closed client.
        terminal.requestBlockOutputSink = nil
        // Cancel every in-flight metadata request (each resolves to empty so a Details-Panel fetch
        // mid-teardown unblocks at once, not after the 5 s timeout) and drop the façade.
        metadataClient?.cancelAll()
        metadataClient = nil
        outWakeContinuation?.finish()
        outWakeContinuation = nil
        outDrainTask?.cancel()
        // AWAIT the drain's completion BEFORE the residual flush: a mid-batch drain is not stopped by
        // cancel() alone (its sends `try?`), so without this the residual flush below could interleave
        // with in-flight drain sends (a pre-existing hazard the off-main drain made worth closing).
        // Bounded: a send that is parked on the credit window is bounded in Rust (the sub-channel's
        // own wait, `rust/slopdesk-muxnet`) and a closed channel throws fast into the `try?`.
        await outDrainTask?.value
        outDrainTask = nil
        // TRAILING-EDGE GUARANTEE at teardown: the async drain may have been cancelled with a settled
        // trailing resize still queued (e.g. the user stopped dragging and immediately
        // disconnected/reconnected — the wake fired but the drain lost the race to cancellation). Flush
        // the residual backlog ONCE here, synchronously on the main actor, through the SAME coalesce so
        // the final size still reaches the PTY before the client closes. The only place the queue is
        // drained outside the loop; the plan's coalesce keeps the last resize.
        //
        // Residual `.input` is DROPPED, not flushed: input rides the WINDOWED data sub-channel, and under
        // credit-at-consumption an exhausted window would park this await BEFORE `client.close()` (the very
        // call that wakes parked senders) could run → `disconnect()` hangs. Resize rides the unwindowed
        // CONTROL channel (never parks), and dropping keystrokes at deliberate teardown is the designed
        // semantic (they were typed against a session that is going away).
        if let client, !outQueue.isEmpty {
            let residual = outQueue
            outQueue.removeAll(keepingCapacity: true)
            // The SAME plan the drain runs — resizes pass through the packing stage unchanged and in
            // order, so reading its answer and skipping the input frames is the coalesce alone.
            for event in ConnectGate.plan(residual) {
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
