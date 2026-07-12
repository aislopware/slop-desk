import Foundation
import Observation
import SlopDeskAgentDetect
import SlopDeskClient
import SlopDeskInspector
import SlopDeskVideoProtocol // EnvConfig — the behaviour-preserving config resolver (env → overlay → default)

// MARK: - LivePaneSession (the production handle)

/// The production ``PaneSessionHandle``: OWNS the per-session objects and is the only workspace-layer
/// thing that touches the live byte pipeline (docs/22 §2.3, §7).
///
/// One `LivePaneSession` ⇒ one ``ConnectionViewModel`` ⇒ one ordered-OUT stream, one events
/// consumer, one `ReconnectManager`. Keying the registry by ``PaneID`` and minting exactly one per
/// leaf preserves the four byte-pipeline invariants **by construction** — a session is never shared
/// across panes (docs/22 §1.2).
///
/// What it wraps, by kind:
/// - `.terminal`   → `connection` (+ its `terminalModel`) + `inputBar`, PLUS a latent `inspector`
///   (read-only `InspectorViewModel` over `InspectorClient` on NWConnection #2). Claude Code is not a
///   stored `PaneKind` (docs/42): ANY `.terminal` running `claude` is auto-detected (wire
///   types 26/27 fold into ``claudeStatus``), and the inspector second channel opens/closes
///   DYNAMICALLY on that runtime status (≠ `.none` opens it). The terminal|inspector split is per-pane
///   VIEW state, NOT a tree node — one leaf.
/// - `.remoteGUI`  → a `remoteWindow` (`RemoteWindowModel`) instead of a connection-backed terminal.
///
/// ### Lazy connect (load-bearing, docs/22 §6 RESTORED-vs-RECONNECTED)
/// ``make(_:makeClient:makeInspector:)`` BUILDS the `ConnectionViewModel` (host/port pre-filled from
/// `spec.endpoint`) but does **not** `connect()`. The view triggers `connect()` lazily on appear
/// so restoring a 12-pane workspace doesn't slam 12 sockets at launch.
@preconcurrency
@MainActor
@Observable
public final class LivePaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting,
    TerminalModelProviding
{
    // MARK: Identity

    /// Placeholder at construction, then re-pointed to the leaf's id by the store's `reconcile()` via
    /// ``adopt(id:)`` (injection seam is spec-only — see ``PaneSessionIDAdopting``). Stable thereafter.
    public private(set) var id: PaneID
    public let kind: PaneKind

    // MARK: Proven per-session objects (wrapped verbatim)

    /// Owns the ordered-OUT drain + single events loop + `ReconnectManager`. `nil` only for a
    /// `.remoteGUI` pane (no PATH-1 terminal connection).
    public let connection: ConnectionViewModel?

    /// The per-pane external input affordance (A / B1 dedup ring). Present for the `.terminal` kind.
    public let inputBar: InputBarModel?

    /// The read-only structured inspector for a terminal pane (NWConnection #2). `nil` for non-terminal
    /// kinds (`.remoteGUI` / `.systemDialog`); present for EVERY `.terminal` pane (any terminal can
    /// become a Claude session), but the second channel is SUBSCRIBED only while ``claudeStatus`` `≠ .none`.
    /// The model is durable across pause/resume; the client is closed on pause, rebuilt on resume. `model`
    /// is `let` (upsert/dedup keeps a re-tail safe); `client` is `var` because resume swaps in a fresh one.
    public let inspector: InspectorViewModel?

    // MARK: Claude-Code auto-detection (client TRUSTS the host's type-27)

    /// The CLIENT is a passive display — the HOST owns the one ``ClaudeStatusMachine`` and is the
    /// single source of truth. The client does NOT run its own machine or re-derive presence from type-26
    /// (re-deriving from it fights the host's type-27 and causes inspector flap); it maps the host's type-27
    /// `state` byte → ``ClaudeStatus`` (forward-tolerant) and trusts it. Whether a terminal can ever host
    /// a claude is a build-time fact (only `.terminal` panes), kept as this flag.
    private let isAgentDetectable: Bool

    /// The current Claude status — the HOST's type-27 verdict, trusted verbatim. Drives the
    /// sidebar/tab/chrome ``AgentStatusDot`` (via ``WorkspaceStore/setAgentStatus(_:for:)``) AND the
    /// dynamic open/close of the inspector second channel. `.none` until the host reports a `claude`.
    /// Observed so the leaf chrome re-renders.
    public private(set) var claudeStatus: ClaudeStatus = .none

    /// The last foreground process basename the host reported (type 26) — a COARSE display-only hint, NOT
    /// a status source: a transient child process taking the PTY must never wipe a
    /// `.needsPermission` the host set via a hook, so type-26 updates THIS string only. `nil` until the
    /// host reports one. Observed so chrome that shows it re-renders.
    public private(set) var foregroundProcessName: String?

    /// The live inspector second-channel client. Set when the inspector is subscribed; nilled on
    /// pause/teardown. Private so callers go through the lifecycle methods.
    private var inspectorClient: InspectorClient?
    /// The detached re-subscribe task spawned by ``resume()``. Tracked + cancelled by `pause()` /
    /// `teardown()` so a re-subscribe that loses the race against a same-turn teardown is cancelled and
    /// closes the socket it just built — defusing the "T builds a client after teardown" window. The
    /// detachment is load-bearing: `subscribeInspector()` ends in `await model.consume(...)`, which returns
    /// only when the stream closes, so it can NEVER be awaited inline by `resume()` (that would hang the
    /// scenePhase foreground fan-out). Tracked + cancellable, not awaited.
    private var inspectorTask: Task<Void, Never>?

    /// The remote-GUI (video) model for a `.remoteGUI` pane. `nil` for other kinds.
    public let remoteWindow: RemoteWindowModel?

    // MARK: Re-open glue for pause/resume

    /// The store's factory, retained so `resume()` can rebuild a fresh ``InspectorClient`` after `pause()`
    /// closed the previous one (iOS kills an app that strands a background socket — docs/22 DECISIONS).
    /// Set for every `.terminal` pane; `nil` for the video kinds (`.remoteGUI` / `.systemDialog`).
    private let makeInspector: (@MainActor (ConnectionTarget) -> InspectorClient?)?
    /// Resolves the CURRENT app target for the inspector build/rebuild (inspector rides the same host as
    /// the terminal, on terminal port + 1). Read fresh at subscribe-time to pick up a host change. Set
    /// for every `.terminal` pane; `nil` for the video kinds.
    private let target: (@MainActor () -> ConnectionTarget)?

    // MARK: Video activation

    /// See ``PaneSessionHandle/isVideoActive``. Mirrors whether the `remoteWindow` has an active
    /// descriptor; always `false` for non-`.remoteGUI` panes.
    public private(set) var isVideoActive: Bool = false

    /// Whether this `.remoteGUI` pane's video was active when ``pause()`` suspended it, so ``resume()``
    /// re-opens exactly the set admitted before background. Cap-safe WITHOUT consulting the store: resume
    /// re-opens at most what already satisfied `liveVideoCap`, so it cannot exceed it.
    private var wasVideoActiveBeforePause = false

    /// SYSTEM-DIALOG: `true` when this ``PaneKind/systemDialog`` pane streams a Secure-Event-Input
    /// (password/auth) prompt — the pane shows a "view-only — type on the host" hint. A pure-live property
    /// the store sets via ``markSystemDialog(isSecure:)`` (never persisted).
    public private(set) var isSecureDialog = false

    /// PANE REBIND: whether the one-shot stale-binding revalidation already ran for this session
    /// (only the RESTORED binding is suspect — see ``maybeRevalidateBinding(_:)``).
    private var didRevalidateBinding = false
    /// PANE REBIND: the in-flight revalidation, cancelled by ``teardown()`` so a discovery
    /// round-trip racing a pane close can never re-open the model.
    private var rebindTask: Task<Void, Never>?

    // MARK: Automation seam (SLOPDESK_AUTOTYPE)

    /// Whether this session is the `SLOPDESK_AUTOTYPE` OUT-path-proof target — the first leaf of the first
    /// tab (docs/22 §7). Set by the store's `reconcile()` (the store owns the tree); read by the terminal
    /// leaf's `.task` after connect to push command bytes through the REAL OUT path so
    /// `scripts/check-macos.sh --connect` keeps proving type→exec→render. Defaults `false`; fires for
    /// exactly one session.
    public internal(set) var isAutotypeTarget: Bool = false

    // MARK: Passthrough

    /// The terminal model the leaf view renders, or `nil` for a `.remoteGUI` pane. A convenience over
    /// `connection.terminalModel` so the view never reaches into the connection.
    public var terminalModel: TerminalViewModel? { connection?.terminalModel }

    /// BOOKMARKS persistence scope (``TerminalModelProviding/bookmarkScopeKey``): a token minted FRESH
    /// per materialization (so a relaunch — which re-numbers blocks from 0 in a new segmenter — starts with
    /// NO stars instead of grafting a prior run's block indices onto unrelated commands). Stable across a
    /// transport reconnect within one launch (the same instance survives; only the host shell +
    /// block-index space restart). Keyed by THIS not the stable pane id to make the persisted index set
    /// per-SESSION, matching the ``PreferencesStore`` contract (a `sessionUUID → [block index]` map).
    public let bookmarkScopeKey = UUID().uuidString

    /// Whether an OSC 133 command is currently executing in this pane's shell — the
    /// ``PaneSessionHandle/isShellBusy`` close-guard signal and the pill's "running…" cue. `false`
    /// for panes with no terminal (`.remoteGUI` / `.systemDialog`).
    public var isShellBusy: Bool { terminalModel?.shellActivity == .running }

    /// Broadcast / synchronized-input target primitive: types `text` into this pane's shell by routing
    /// to the per-pane ``InputBarModel`` (the same recorded-for-echo-dedup path a normal submit uses).
    /// A no-op when there is no input bar (a `.remoteGUI` / `.systemDialog` pane).
    public func sendText(_ text: String) { inputBar?.sendText(text) }

    /// Snippet / send-keys primitive: feeds raw bytes (incl. control codes) into the shell via the input
    /// bar, NOT recorded for echo-dedup (a programmatic send has no local pre-echo to suppress).
    public func sendBytes(_ bytes: [UInt8]) { inputBar?.sendRaw(bytes, record: false) }

    /// RELEASE STUCK INPUT: route the palette escape hatch to the `.remoteGUI` pane's
    /// ``RemoteWindowModel`` (whose live sink the video view publishes; withheld while read-only /
    /// not streaming). A no-op for every other kind (`remoteWindow == nil`).
    public func releaseStuckInput() { remoteWindow?.releaseStuckInput() }

    /// PASTE AS KEYSTROKES: route the pane's clipboard-paste to the `.remoteGUI` pane's
    /// ``RemoteWindowModel`` (whose live key sink the video view publishes; withheld while read-only /
    /// not streaming, so the model no-ops). A no-op for every other kind (`remoteWindow == nil`) — a
    /// terminal pane has its own paste pipeline.
    public func pasteAsKeystrokes(_ text: String) { remoteWindow?.pasteAsKeystrokes(text) }

    /// Reflects the live connection: `.terminal`/Claude panes are ready only once the handshake completes
    /// (``ConnectionViewModel/status`` `== .connected`) — before that, `InputBarModel.sendSink` is wired but
    /// `TerminalViewModel.inputSink` is not, so a send would silently drop. A `.remoteGUI` / `.systemDialog`
    /// pane has no `connection` and is always "ready" (no text funnel to gate).
    public var isReadyForInput: Bool { connection.map { $0.status == .connected } ?? true }

    /// `slopdesk pane capture --lines N`: the last `count` lines of this pane's scrollback, read through
    /// the same `TerminalSurfaceActions` seam find/copy-mode use (``TerminalViewModel/searchScrollbackLines()``
    /// → `[]` on a headless / preview surface, hang-safety). `nil` terminal (a `.remoteGUI` pane) ⇒ `[]`.
    public func captureScrollback(lines count: Int) -> [String] {
        guard count > 0, let lines = terminalModel?.searchScrollbackLines() else { return [] }
        return Array(lines.suffix(count))
    }

    /// GENERIC resize-scrim signal: TRUE while this pane's content has been resized but the fresh
    /// (reflowed / re-captured) pixels have not yet rendered — so ``PaneContainer`` holds its resize
    /// overlay instead of clearing on a geometry settle timer. Kind-agnostic: a terminal pane reports its
    /// host-reflow wait (``TerminalViewModel/awaitingResizeReflow``), a remote-GUI pane its host-re-capture
    /// wait (``RemoteWindowModel/awaitingResizeReflow``); `false` when neither model is live. Observed, so
    /// the scrim re-renders on a change.
    public var awaitingResizeReflow: Bool {
        terminalModel?.awaitingResizeReflow ?? remoteWindow?.awaitingResizeReflow ?? false
    }

    /// Whether the remote rang the bell since last cleared (drives the unfocused-pane attention badge).
    public var bellPending: Bool { terminalModel?.bellPending ?? false }

    /// Clears the pending bell (the store calls this when this pane is focused).
    public func clearBell() { terminalModel?.clearBell() }

    // MARK: Init

    /// The designated initializer is private — production builds a `LivePaneSession` only through
    /// ``make(_:makeClient:makeInspector:)`` so the wiring stays in one audited place.
    private init(
        id: PaneID,
        kind: PaneKind,
        connection: ConnectionViewModel?,
        inputBar: InputBarModel?,
        inspector: InspectorViewModel?,
        inspectorClient: InspectorClient?,
        remoteWindow: RemoteWindowModel?,
        makeInspector: (@MainActor (ConnectionTarget) -> InspectorClient?)?,
        target: (@MainActor () -> ConnectionTarget)?,
        isAgentDetectable: Bool,
    ) {
        self.id = id
        self.kind = kind
        self.connection = connection
        self.inputBar = inputBar
        self.inspector = inspector
        self.inspectorClient = inspectorClient
        self.remoteWindow = remoteWindow
        self.makeInspector = makeInspector
        self.target = target
        self.isAgentDetectable = isAgentDetectable
    }

    // MARK: - Factory (the store's makeSession production path)

    /// Builds the live session for `spec`, wiring the proven objects for its kind WITHOUT connecting
    /// (docs/22 §6 lazy connect). What the store injects as `makeSession` in production.
    ///
    /// - Parameters:
    ///   - spec: the leaf intent (kind + endpoint(s) + title). Endpoint pre-fills the connection /
    ///     remote-window form fields; an unconfigured spec yields an idle, fillable session.
    ///   - makeClient: the `@Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient` factory used to
    ///     stand up the client on `connect()`. Takes the resume seed (non-`nil` only for a restored
    ///     `.terminal` pane, see ``makeTerminal(_:makeClient:makeInspector:target:)``) so the
    ///     PRODUCTION factory (`WorkspaceStore.muxBackedClientFactory`) can pass it straight into
    ///     `SlopDeskClient.init(resumeSeed:)` — set synchronously at construction, closing the
    ///     seed-resume-identity-race (docs/DECISIONS). A test factory that has no restored
    ///     identity to seed can ignore the argument (`{ _ in ... }`).
    ///   - makeInspector: builds the read-only `InspectorClient` (NWConnection #2) for a `.terminal`
    ///     pane's endpoint (subscribed dynamically once `claude` is detected), or `nil` when no
    ///     second channel is available. Retained for the `resume()` rebuild.
    @preconcurrency
    public static func make(
        _ spec: PaneSpec,
        makeClient: @escaping @Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient,
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient?,
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
    ) -> LivePaneSession {
        // `make` is a pure spec→session factory: the spec carries no id (identity lives on the tree
        // leaf), so the session mints a placeholder ``PaneID`` here; the store's `reconcile()` re-points
        // it to the real leaf id via `adopt(id:)` before registering.
        switch spec.kind {
        case .terminal:
            makeTerminal(spec, makeClient: makeClient, makeInspector: makeInspector, target: target)
        case .remoteGUI,
             .systemDialog:
            // A system-dialog pane uses the SAME video stack as a remote-GUI pane (streams one host
            // window by id); the differences — auto-management, no picker, skip revalidation, not
            // persisted — live in the store/monitor and `setVideoActive`, not the session shape.
            makeRemoteGUI(spec, target: target)
        case .chooser:
            // A `.chooser` (in-pane kind picker) pane materializes NO live session — the store's
            // reconcile SKIPS it. This arm only satisfies exhaustiveness; if reached it degrades to a
            // terminal rather than trapping.
            makeTerminal(spec, makeClient: makeClient, makeInspector: makeInspector, target: target)
        }
    }

    /// Builds a `.terminal` session: a `ConnectionViewModel` bound to the app target (NOT connected) +
    /// an `InputBarModel`, plus the LATENT Claude-detection seam — an inspector model + the status
    /// machine — wired for EVERY terminal. The inspector second channel is not opened here; it's
    /// subscribed dynamically once ``claudeStatus`` lifts off `.none`.
    private static func makeTerminal(
        _ spec: PaneSpec,
        makeClient: @escaping @Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient,
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient?,
        target: @escaping @MainActor () -> ConnectionTarget,
    ) -> LivePaneSession {
        let terminal = TerminalViewModel()
        // SLOPDESK_DETACH_ENABLED (default ON — env != "0"): when the restored spec carries a saved
        // session UUID (set by Stage 2's capture path), pre-seed the client's resume identity BEFORE the
        // first connect() so the channelOpen preamble presents the saved UUID + last-received seq,
        // enabling a RETURNING_CLIENT reattach. A nil resumeSessionID (brand-new/never-connected pane)
        // takes the fresh-shell path. Routes through `EnvConfig` (env → overlay → default); the
        // default-ON (`!= "0"`) idiom is preserved exactly via `boolDefaultOn`, an EMPTY overlay
        // byte-identical.
        let detachEnabled = EnvConfig.boolDefaultOn("SLOPDESK_DETACH_ENABLED")
        let savedResumeID = detachEnabled ? spec.resumeSessionID : nil
        // A persisted `lastKnownCwd` poisoned in a prior session (a plugin manager's transient turbo `cd`
        // captured via the host `cwd` RPC — see ``PaneSpec/looksLikeTransientPluginCwd(_:)``) would re-spawn
        // this PTY in the plugin cache dir via `channelOpen`. Sanitize it to `nil` so the host falls back to
        // its default (home) instead — the poison self-heals on the next launch.
        let initialCwd = spec.lastKnownCwd.flatMap { PaneSpec.looksLikeTransientPluginCwd($0) ? nil : $0 }
        // COLD LAUNCH: always seed seq=0 even when spec.resumeLastReceivedSeq is non-nil. This is a COLD
        // path — the client actor is brand-new (process relaunch), so highestContiguousSeq starts at 0
        // regardless. Seeding a non-zero seq would present lastReceivedSeq=N to the host, replaying only
        // seq > N — skipping the whole scrollback ring (history with seq ≤ N). Seeding seq=0 sends
        // lastReceivedSeq=0, triggering full ring replay (entries 1..ackedSeq) then the un-acked tail —
        // like `tmux attach-session` (host SLOPDESK_SCROLLBACK_PERSIST gate).
        //
        // WARM in-process reconnect (iOS bg/fg, transport drop without process exit): no resume seed is
        // built here at all — the actor's live highestContiguousSeq is presented directly in
        // SlopDeskClient.connect() (`let lastSeq = highestContiguousSeq`). That path is unaffected.
        //
        // SEED-AT-CONSTRUCTION (closes seed-resume-identity-race, docs/DECISIONS): calling the zero-arg
        // `makeClient()` and then firing an UNAWAITED `Task { await c.seedResumeIdentity(...) }` afterward
        // would order nothing — that seed job could lose the race against
        // `ConnectionViewModel.performConnect()`'s own separately-scheduled connect Task and the actor's
        // mailbox, so `connect()` would read a nil `sessionID` (fresh shell) instead of the restored one.
        // Instead `makeClient` takes the seed directly and the production factory
        // (`WorkspaceStore.muxBackedClientFactory`) threads it into `SlopDeskClient.init(resumeSeed:)`,
        // which sets `sessionID` / `highestContiguousSeq` / `highestSeqFed` synchronously — no Task, no
        // actor hop, no race window.
        let resumeSeed: SlopDeskClient.ResumeSeed? = savedResumeID.map { (sessionID: $0, lastSeq: 0) }
        let makeClientSeeded: @Sendable () -> SlopDeskClient = { makeClient(resumeSeed) }
        let connection = ConnectionViewModel(
            terminal: terminal,
            target: target,
            initialCwd: initialCwd,
            makeClient: makeClientSeeded,
        )
        let inputBar = InputBarModel()
        // SINGLE OUT FUNNEL: input-bar bytes ride the pane's ONE ordered OUT FIFO (terminal.sendInput →
        // inputSink → ConnectionViewModel outQueue/drain), same path as renderer keystrokes — never a
        // separate drain racing the client actor (docs/29 dual-OUT-drain reorder fix). Weak: the sink
        // must not retain the model.
        inputBar.sendSink = { [weak terminal] data in terminal?.sendInput(data) }

        return LivePaneSession(
            id: PaneID(),
            kind: spec.kind,
            connection: connection,
            inputBar: inputBar,
            inspector: InspectorViewModel(),
            inspectorClient: nil, // opened lazily by subscribeInspector() once claudeStatus ≠ .none
            remoteWindow: nil,
            makeInspector: makeInspector,
            target: target,
            // Every terminal can host an auto-detected claude — the host's type-27 verdict (folded via
            // `feedAgentSignal`) lifts `claudeStatus` off `.none`. The client TRUSTS that verdict.
            isAgentDetectable: true,
        )
    }

    /// Builds a `.remoteGUI` session: a `RemoteWindowModel` bound to the app target with the per-pane
    /// window pre-filled, NOT opened (UDP is user-initiated — docs/22 §6).
    private static func makeRemoteGUI(
        _ spec: PaneSpec,
        target: @escaping @MainActor () -> ConnectionTarget,
    ) -> LivePaneSession {
        let model =
            if let v = spec.video {
                RemoteWindowModel(
                    target: target,
                    windowID: String(v.windowID),
                    title: v.title,
                    appName: v.appName,
                )
            } else {
                RemoteWindowModel(target: target)
            }
        return LivePaneSession(
            id: PaneID(),
            kind: spec.kind,
            connection: nil,
            inputBar: nil,
            inspector: nil,
            inspectorClient: nil,
            remoteWindow: model,
            makeInspector: nil,
            target: nil,
            isAgentDetectable: false, // a video pane has no PTY → no claude to detect
        )
    }

    // MARK: - ID adoption (store-internal)

    /// See ``PaneSessionIDAdopting``. The store re-points a freshly-built session at its leaf id.
    func adopt(id: PaneID) {
        self.id = id
    }

    /// SYSTEM-DIALOG: flag a just-spawned ``PaneKind/systemDialog`` session as a secure (password/auth)
    /// prompt so the pane view shows the "view-only — type on the host" hint. Set by the store right after
    /// materialization (the flag is pure-live, not carried in the persisted spec).
    func markSystemDialog(isSecure: Bool) { isSecureDialog = isSecure }

    // MARK: - Inspector second channel

    /// Opens + subscribes the inspector second channel (full replay from seq 0), then folds its event
    /// stream into `inspector` until the stream ends. Called by the view's `.task` on appear and
    /// by ``resume()``. Idempotent: does nothing if a client is already live. The fold is re-tail-safe
    /// because the model upserts/dedupes tool cards by id (docs/22 DECISIONS) — a resume replaying the
    /// whole transcript tail does not duplicate cards.
    public func subscribeInspector() async {
        // Gated on the RUNTIME Claude status, not a stored kind — a plain terminal opens NO
        // inspector socket until a `claude` is detected (`claudeStatus` ≠ `.none`). Re-driven on that
        // transition (see feedAgentSignal).
        guard claudeStatus != .none, let model = inspector else { return }
        guard inspectorClient == nil else { return }
        guard let target, let client = makeInspector?(target()) else { return }
        // Cancelled before we stored anything (pause()/teardown() fired between resume's spawn and here)
        // — close the just-built client so its lazily-opened socket is never stranded.
        if Task.isCancelled { await client.close()
            return
        }
        inspectorClient = client
        try? await client.subscribe(fromSeq: 0)
        // Torn down WHILE we were subscribing: drop our reference (if still ours) and close — this is
        // the window that actually defuses "a re-subscribe builds a live client after teardown".
        if Task.isCancelled {
            if inspectorClient === client { inspectorClient = nil }
            await client.close()
            return
        }
        // Fold the live stream. `consume` returns when the stream finishes (transport closed, e.g. by a
        // `pause()` that closed the client) — then drop the dangling reference so a later `resume()` can
        // rebuild.
        await model.consume(client.events())
        if inspectorClient === client { inspectorClient = nil }
    }

    // MARK: - Claude-Code agent signal fold (client TRUSTS the host's type-27)

    /// Folds one wire agent-detection event (type 26 `foregroundProcess` / type 27 `claudeStatus`) into
    /// this pane's DISPLAY state. The client is a passive display — it does NOT run a state machine
    /// or re-derive presence:
    /// - **type 27 `claudeStatus`** is the SINGLE source of truth: the `state` byte maps directly to a
    ///   ``ClaudeStatus`` (forward-tolerant — an unknown/future byte degrades to `.none`), trusted
    ///   verbatim. Drives the dot AND the dynamic inspector open/close.
    /// - **type 26 `foregroundProcess`** is a COARSE display-only process-name hint: it
    ///   updates ``foregroundProcessName`` and NOTHING else — it can NEVER override the type-27 status,
    ///   so a transient child process taking the PTY can't wipe a host-set `.needsPermission`.
    ///
    /// Returns the current status so the store can mirror it into ``WorkspaceStore/setAgentStatus(_:for:)``.
    /// A no-op (returns `.none`) for a non-detectable pane (a video pane — no PTY).
    @discardableResult
    func feedAgentSignal(
        _ event: SlopDeskClient.Event,
        now _: TimeInterval = Date().timeIntervalSinceReferenceDate,
    ) -> ClaudeStatus {
        guard isAgentDetectable else { return claudeStatus }
        switch event {
        case let .foregroundProcess(name):
            // DISPLAY-ONLY: a coarse process-name hint. Never touches `claudeStatus` (the type-27 verdict
            // is authoritative) — so a child process briefly taking the PTY can't clobber a hook status.
            let trimmed = name.isEmpty ? nil : name
            if foregroundProcessName != trimmed { foregroundProcessName = trimmed }
            return claudeStatus
        case let .claudeStatus(state, _, _):
            // TRUST the host's verdict: map the raw urgency byte → ClaudeStatus directly (forward-tolerant
            // — an unknown/future byte degrades to `.none`; a hostile datagram can never trap the client).
            applyDetectedStatus(ClaudeStatus(urgency: Int(state)))
            return claudeStatus
        default:
            // Not an agent-detect event — ignore (the store only forwards 26/27 here).
            return claudeStatus
        }
    }

    /// Applies the host's freshly-trusted status: dedupes no-op updates, then opens/closes the inspector
    /// second channel on the `.none` boundary. `.none → non-none` spawns a subscribe; `non-none → .none`
    /// tears the client down (the pane is back to a plain terminal — hold no inspector socket).
    private func applyDetectedStatus(_ newStatus: ClaudeStatus) {
        let wasActive = claudeStatus != .none
        let isActive = newStatus != .none
        guard claudeStatus != newStatus else { return } // dedupe identical updates (no churn)
        claudeStatus = newStatus
        if !wasActive, isActive {
            // A claude just appeared in this terminal → open the read-only inspector second channel.
            inspectorTask?.cancel()
            inspectorTask = Task { [weak self] in await self?.subscribeInspector() }
        } else if wasActive, !isActive {
            // The claude is gone → close the inspector socket (idempotent).
            inspectorTask?.cancel()
            inspectorTask = nil
            if let client = inspectorClient {
                let toClose = client
                inspectorClient = nil
                Task { await toClose.close() }
            }
        }
    }

    // MARK: - PaneSessionHandle: video activation

    public func setVideoActive(_ active: Bool) {
        guard kind.isVideo, let model = remoteWindow else { return }
        if active {
            // Open only if configured; mirror the resulting active state.
            if model.active == nil, model.canOpen {
                model.open()
                // A `.systemDialog` pane SKIPS stale-binding revalidation: its windowID is always fresh
                // from the live poll, and revalidation re-resolves against the picker list — which
                // EXCLUDES system apps — so it would wrongly unbind the dialog back to the picker form.
                if !kind.isEphemeral { maybeRevalidateBinding(model) }
            }
            isVideoActive = model.active != nil
        } else {
            model.close()
            isVideoActive = false
        }
    }

    /// PANE REBIND: ONE-SHOT stale-binding revalidation after the first optimistic
    /// `open()`. CGWindowIDs die with the window and get recycled across host restarts, and the host
    /// rejects a dead id SILENTLY (`helloAck(accepted:false)` → zero client effects → a permanent black
    /// pane). The model checks the live window list and re-binds by app+title (`WindowRebind`);
    /// `.unbound` closed back to the picker form, so the cap mirror must follow. One-shot per session:
    /// only the RESTORED binding is suspect — endpoints the user just picked came from a live list.
    private func maybeRevalidateBinding(_ model: RemoteWindowModel) {
        guard !didRevalidateBinding else { return }
        didRevalidateBinding = true
        rebindTask = Task { @MainActor [weak self, weak model] in
            guard let model else { return }
            let outcome = await model.revalidateBinding()
            guard let self, !Task.isCancelled else { return }
            if outcome == .unbound { isVideoActive = model.active != nil }
        }
    }

    // MARK: - PaneSessionHandle: lifecycle (the single fan-out points)

    /// iOS background. Fans to BOTH halves:
    /// - **connection**: `ConnectionViewModel.pause()` (host retains the tail; byte-exact resume).
    /// - **inspector**: CLOSES NWConnection #2 (docs/22 DECISIONS) — iOS kills an app that strands a
    ///   background socket, and the inspector is read-only + idempotent so a full re-tail on resume is
    ///   safe and needs no host-side seq buffering. Closing the client finishes the `events()` stream,
    ///   unblocking the `consume` loop in ``subscribeInspector()`` (which then nils the ref).
    public func pause() async {
        await connection?.pause()
        // Cancel any in-flight re-subscribe BEFORE closing the client so a re-check sees cancellation.
        inspectorTask?.cancel()
        inspectorTask = nil
        if let client = inspectorClient {
            await client.close()
            inspectorClient = nil
        }
        // Suspend live video too (docs/22 §4 fan-out): iOS would kill the app for stranding the
        // 2-UDP / VTDecompression / CADisplayLink stack across background. setVideoActive(false) closes
        // the remote window (RemoteWindowPanel reacts to model.active == nil → pipeline.deactivate()).
        // Remember it was active so resume() re-opens at most the set already admitted.
        if isVideoActive {
            wasVideoActiveBeforePause = true
            setVideoActive(false)
        }
    }

    /// iOS foreground. Fans to BOTH halves:
    /// - **connection**: `ConnectionViewModel.resume()` (byte-exact resume).
    /// - **inspector**: RE-OPENS a fresh client and re-subscribes from seq 0 (full re-tail). The
    ///   re-subscribe runs detached so `resume()` returns promptly for the scenePhase fan-out; the
    ///   fold then proceeds in the background `subscribeInspector()` loop.
    public func resume() async {
        await connection?.resume()
        // Restore live video for a video pane that was active before pause (cap-safe: re-opens
        // at most the set already admitted, so it cannot exceed liveVideoCap — no store consult needed).
        if kind.isVideo, wasVideoActiveBeforePause {
            wasVideoActiveBeforePause = false
            setVideoActive(true)
        }
        if claudeStatus != .none, inspector != nil, inspectorClient == nil {
            // Re-subscribe only when a claude is still detected (runtime status, not a stored kind).
            // Track + cancel a prior re-subscribe before spawning a fresh one, so a teardown/pause in the
            // same main-actor turn can cancel this (subscribeInspector() re-checks then closes the
            // just-built client). NOT awaited — the fold blocks until the stream closes, so awaiting here
            // would hang the foreground fan-out.
            inspectorTask?.cancel()
            inspectorTask = Task { [weak self] in await self?.subscribeInspector() }
        }
    }

    /// TRANSPORT RECONNECT edge (wifi flap; macOS — where `pause()`/`resume()` never run). The inspector
    /// second channel (terminal port + 1) died with the same link drop, but nothing re-armed it: the
    /// host's reattach re-assert re-emits the SAME type-27 status verbatim, so ``applyDetectedStatus``'s
    /// dedupe guard eats it and the `.none → active` transition that opens the channel never fires again —
    /// the Inspector pane stayed dead until the agent's status happened to change. Called from the store's
    /// once-per-reconnect `onReconnected` hook: while a claude is still detected, unconditionally tear
    /// down any stale client (mirroring ``resume()``'s cancel-then-rebuild shape — the fire-and-forget
    /// close is the same idiom as `applyDetectedStatus`'s close arm; this runs in the sync reconnect
    /// closure, so the close cannot be awaited inline) and re-subscribe a FRESH one from seq 0. The full
    /// re-tail is safe — the model upserts/dedupes by id. A `.none` pane holds no inspector socket and is
    /// a no-op.
    public func reestablishInspectorOnReconnect() {
        guard claudeStatus != .none, inspector != nil else { return }
        // Cancel the in-flight subscribe FIRST (its cancellation re-checks close the client it built),
        // then drop + close the stale client so the fresh `subscribeInspector()` below passes its
        // `inspectorClient == nil` idempotence gate instead of early-outing on the dead socket.
        inspectorTask?.cancel()
        if let client = inspectorClient {
            let toClose = client
            inspectorClient = nil
            Task { await toClose.close() }
        }
        inspectorTask = Task { [weak self] in await self?.subscribeInspector() }
    }

    /// The pane is closing for good. Delegates to the proven teardown order:
    /// - `ConnectionViewModel.disconnect()` (deliberate close: stops the supervisor, tears down the
    ///   ordered drain + events loop, closes the client — no reconnect).
    /// - closes the inspector second channel.
    /// - closes any live video window (stops the orchestrator).
    public func teardown() async {
        await connection?.disconnect()
        // Cancel any in-flight re-subscribe BEFORE closing the client so a re-check sees cancellation
        // and closes the just-built client itself — this closes the "T builds a client after teardown"
        // window.
        inspectorTask?.cancel()
        inspectorTask = nil
        if let client = inspectorClient {
            await client.close()
            inspectorClient = nil
        }
        // PANE REBIND: a revalidation racing teardown must not reopen a closed pane.
        rebindTask?.cancel()
        rebindTask = nil
        if isVideoActive || remoteWindow?.active != nil {
            remoteWindow?.close()
            isVideoActive = false
        }
    }
}
