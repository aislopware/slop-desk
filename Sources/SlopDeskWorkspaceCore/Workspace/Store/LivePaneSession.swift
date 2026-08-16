import Foundation
import Observation
import SlopDeskAgentDetect
import SlopDeskClient
import SlopDeskInspector
import SlopDeskVideoProtocol // EnvConfig — the behaviour-preserving config resolver (env → overlay → default)
import SlopDeskWorkspaceModel

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
/// - the video `.desktop` → a `remoteWindow` (`RemoteWindowModel`) instead of a
///   connection-backed terminal.
///
/// ### Lazy connect (load-bearing, docs/22 §6 RESTORED-vs-RECONNECTED)
/// ``make(paneID:spec:spawnCwd:makeClient:makeInspector:target:)`` BUILDS the `ConnectionViewModel` (host/port pre-filled from
/// `spec.endpoint`) but does **not** `connect()`. The view triggers `connect()` lazily on appear
/// so restoring a 12-pane workspace doesn't slam 12 sockets at launch.
@preconcurrency
@MainActor
@Observable
public final class LivePaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting,
    TerminalModelProviding
{
    // MARK: Identity

    /// The leaf's identity, handed to the factory at construction and stable for the session's life.
    /// ``adopt(id:)`` survives for the handles that are built without one (the test doubles).
    public private(set) var id: PaneID
    public let kind: PaneKind

    // MARK: Proven per-session objects (wrapped verbatim)

    /// Owns the ordered-OUT drain + single events loop + `ReconnectManager`. `nil` only for a
    /// video pane (no PATH-1 terminal connection).
    public let connection: ConnectionViewModel?

    /// The per-pane external input affordance (A / B1 dedup ring). Present for the `.terminal` kind.
    public let inputBar: InputBarModel?

    /// The read-only structured inspector for a terminal pane (NWConnection #2). `nil` for non-terminal
    /// `.desktop`; present for EVERY `.terminal` pane (any terminal can
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
    /// sidebar/tab/chrome agent mark (`StatusDotView`, via ``WorkspaceStore/setAgentStatus(_:for:)``) AND the
    /// dynamic open/close of the inspector second channel. `.none` until the host reports a `claude`.
    /// Observed so the leaf chrome re-renders.
    public private(set) var claudeStatus: ClaudeStatus = .none

    /// The `kind` qualifier of the LAST type-27 the host sent (`.none` before the first one) — read by
    /// ``WorkspaceStore`` right after the fold to decide whether the transition may be ANNOUNCED.
    /// ``AgentStatusKind/quiet`` means the host already knows what this edge looks like and has ruled
    /// it bookkeeping (the `/compact` boundary), so the dots move but nothing rings.
    ///
    /// Not observed: it qualifies a status change rather than being drawn, and it is always read in
    /// the same turn the status it belongs to is committed.
    public private(set) var lastStatusKind: AgentStatusKind = .none

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

    /// The video model for a `.desktop` pane. `nil` for a terminal.
    public let remoteWindow: RemoteWindowModel?

    // MARK: Re-open glue for pause/resume

    /// The store's factory, retained so `resume()` can rebuild a fresh ``InspectorClient`` after `pause()`
    /// closed the previous one (iOS kills an app that strands a background socket — docs/22 DECISIONS).
    /// Set for every `.terminal` pane; `nil` for the video `.desktop`.
    private let makeInspector: (@MainActor (ConnectionTarget) -> InspectorClient?)?
    /// Resolves the CURRENT app target for the inspector build/rebuild (inspector rides the same host as
    /// the terminal, on terminal port + 1). Read fresh at subscribe-time to pick up a host change. Set
    /// for every `.terminal` pane; `nil` for the video kinds.
    private let target: (@MainActor () -> ConnectionTarget)?

    // MARK: Video activation

    /// See ``PaneSessionHandle/isVideoActive``. Mirrors whether the `remoteWindow` has an active
    /// descriptor; always `false` for non-video panes.
    public private(set) var isVideoActive: Bool = false

    /// Whether this video pane's stream was active when ``pause()`` suspended it, so ``resume()``
    /// re-opens exactly the set admitted before background. Cap-safe WITHOUT consulting the store: resume
    /// re-opens at most what already satisfied `liveVideoCap`, so it cannot exceed it.
    private var wasVideoActiveBeforePause = false

    // MARK: Automation seam (SLOPDESK_AUTOTYPE)

    /// Whether this session is the `SLOPDESK_AUTOTYPE` OUT-path-proof target — the first leaf of the first
    /// tab (docs/22 §7). Set by the store's `reconcile()` (the store owns the tree); read by the terminal
    /// leaf's `.task` after connect to push command bytes through the REAL OUT path so
    /// `scripts/check-macos.sh --connect` keeps proving type→exec→render. Defaults `false`; fires for
    /// exactly one session.
    public internal(set) var isAutotypeTarget: Bool = false

    // MARK: Passthrough

    /// The terminal model the leaf view renders, or `nil` for a video pane. A convenience over
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
    /// for panes with no terminal (`.desktop`).
    public var isShellBusy: Bool { terminalModel?.shellActivity == .running }

    /// Broadcast / synchronized-input target primitive: types `text` into this pane's shell by routing
    /// to the per-pane ``InputBarModel`` (the same recorded-for-echo-dedup path a normal submit uses).
    /// A no-op when there is no input bar (a `.desktop` pane).
    public func sendText(_ text: String) { inputBar?.sendText(text) }

    /// Snippet / send-keys primitive: feeds raw bytes (incl. control codes) into the shell via the input
    /// bar, NOT recorded for echo-dedup (a programmatic send has no local pre-echo to suppress).
    public func sendBytes(_ bytes: [UInt8]) { inputBar?.sendRaw(bytes, record: false) }

    /// RELEASE STUCK INPUT: route the palette escape hatch to the video pane's
    /// ``RemoteWindowModel`` (whose live sink the video view publishes; withheld while read-only /
    /// not streaming). A no-op for every other kind (`remoteWindow == nil`).
    public func releaseStuckInput() { remoteWindow?.releaseStuckInput() }

    /// LOCK VIEWPORT POSITION: route the ⌥⌘L / palette toggle to the video pane's
    /// ``RemoteWindowModel`` (which gates on its live viewport sink — a no-op off-stream). A no-op for
    /// every other kind (`remoteWindow == nil`).
    public func toggleViewportLock() { remoteWindow?.toggleViewportLock() }

    /// FULLSCREEN PRESENTATION: route the satellite window's fullscreen enter/exit report to the
    /// video pane's ``RemoteWindowModel`` (fullscreen auto-arms immersive capture). A no-op for
    /// every other kind (`remoteWindow == nil`).
    public func noteFullscreenPresentation(_ isFullscreen: Bool) {
        remoteWindow?.noteFullscreenPresentation(isFullscreen)
    }

    /// FIT VIEWPORT TO PANE: route the palette verb to the video pane's footer [fit] command
    /// (the model itself gates re-anchoring while locked / off-stream). A no-op for every other kind
    /// (`remoteWindow == nil`).
    public func fitViewportToPane() { remoteWindow?.sendViewport(.fitToPane) }

    /// ACTUAL SIZE: route the palette verb to the video pane's footer [1×] command. Same no-op
    /// family as ``fitViewportToPane()``.
    public func resetViewportZoom() { remoteWindow?.sendViewport(.reset) }

    /// PASTE AS KEYSTROKES: route the pane's clipboard-paste to the video pane's
    /// ``RemoteWindowModel`` (whose live key sink the video view publishes; withheld while read-only /
    /// not streaming, so the model no-ops). A no-op for every other kind (`remoteWindow == nil`) — a
    /// terminal pane has its own paste pipeline.
    public func pasteAsKeystrokes(_ text: String) { remoteWindow?.pasteAsKeystrokes(text) }

    /// Reflects the live connection: `.terminal`/Claude panes are ready only once the handshake completes
    /// (``ConnectionViewModel/status`` `== .connected`) — before that, `InputBarModel.sendSink` is wired but
    /// `TerminalViewModel.inputSink` is not, so a send would silently drop. A `.desktop`
    /// pane has no `connection` and is always "ready" (no text funnel to gate).
    public var isReadyForInput: Bool { connection.map { $0.status == .connected } ?? true }

    /// `slopdesk pane capture --lines N`: the last `count` lines of this pane's scrollback, read through
    /// the same `TerminalSurfaceActions` seam find/copy-mode use (``TerminalViewModel/searchScrollbackLines()``
    /// → `[]` on a headless / preview surface, hang-safety). `nil` terminal (a video pane) ⇒ `[]`.
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
    /// ``make(paneID:spec:spawnCwd:makeClient:makeInspector:target:)`` so the wiring stays in one audited place.
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
    ///   - paneID: the LEAF's identity. It is also the session id this pane presents to the host on
    ///     `channelOpen`, so the host's liveness records land under the very id the layout uses — one
    ///     namespace, no translation table (DECISIONS, Multi-client Phase 5 ruling 1).
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
        paneID: PaneID,
        spec: PaneSpec,
        spawnCwd: String? = nil,
        makeClient: @escaping @Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient,
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient?,
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
    ) -> LivePaneSession {
        switch spec.kind {
        case .terminal:
            makeTerminal(
                paneID: paneID, spec: spec, spawnCwd: spawnCwd,
                makeClient: makeClient, makeInspector: makeInspector, target: target,
            )
        case .desktop:
            makeVideo(paneID: paneID, spec: spec, target: target)
        }
    }

    /// Builds a `.terminal` session: a `ConnectionViewModel` bound to the app target (NOT connected) +
    /// an `InputBarModel`, plus the LATENT Claude-detection seam — an inspector model + the status
    /// machine — wired for EVERY terminal. The inspector second channel is not opened here; it's
    /// subscribed dynamically once ``claudeStatus`` lifts off `.none`.
    private static func makeTerminal(
        paneID: PaneID,
        spec: PaneSpec,
        spawnCwd: String?,
        makeClient: @escaping @Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient,
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient?,
        target: @escaping @MainActor () -> ConnectionTarget,
    ) -> LivePaneSession {
        let terminal = TerminalViewModel()
        // SLOPDESK_DETACH_ENABLED (default ON — env != "0"): the pane presents its OWN id as the session
        // id in the channelOpen preamble, so a pane that has run before reattaches to the very PTY the
        // host filed under it (RETURNING_CLIENT), and a brand-new pane spawns a fresh shell under that
        // same id — `HostServer.spawnFreshShell` branches only on the zero id, never on whether it has
        // seen this one. One namespace for the layout and for liveness. Routes through `EnvConfig`
        // (env → overlay → default); the default-ON (`!= "0"`) idiom is `boolDefaultOn`.
        let detachEnabled = EnvConfig.boolDefaultOn("SLOPDESK_DETACH_ENABLED")
        let savedResumeID = detachEnabled ? paneID.raw : nil
        // A spawn cwd poisoned in a prior session (a plugin manager's transient turbo `cd` captured via
        // the host `cwd` RPC — see ``PaneSpec/looksLikeTransientPluginCwd(_:)``) would re-spawn this PTY
        // in the plugin cache dir via `channelOpen`. Sanitize it to `nil` so the host falls back to its
        // default (home) instead — the poison self-heals on the next launch.
        let initialCwd = spawnCwd.flatMap { PaneSpec.looksLikeTransientPluginCwd($0) ? nil : $0 }
        // COLD LAUNCH: the seq is always 0. This is a COLD path — the client actor is brand-new (process
        // relaunch), so highestContiguousSeq starts at 0
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
            id: paneID,
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

    /// Builds a VIDEO session (`.desktop`): a `RemoteWindowModel` bound to the app
    /// target with the per-pane target pre-filled, NOT opened (UDP is user-initiated — docs/22 §6).
    private static func makeVideo(
        paneID: PaneID,
        spec: PaneSpec,
        target: @escaping @MainActor () -> ConnectionTarget,
    ) -> LivePaneSession {
        let model =
            if let v = spec.video, v.displayID == nil, v.windowID != 0 {
                // Window-shaped endpoint — the AUTOMATION seam only (`check-video.sh` serves one
                // window; docs/DECISIONS.md 2026-07-23): the classic window `hello`.
                RemoteWindowModel(
                    target: target,
                    windowID: String(v.windowID),
                    title: v.title,
                    appName: v.appName,
                )
            } else {
                // FULL-DESKTOP pane: the model carries the display target (0 = main) — no window id.
                // `setVideoActive` opens it like any configured video pane.
                RemoteWindowModel(
                    target: target,
                    title: spec.video?.title ?? spec.title,
                    desktopDisplayID: spec.video?.displayID ?? 0,
                )
            }
        // LATCHED-MODE RESTORE is NOT seeded here: the modes are TARGET-keyed in the device preferences
        // (`DevicePreferences.videoModesByTarget`), which this pure spec→session factory can't see — the
        // store seeds the model at wiring time (`wireMaterializedLeaf`) and on every endpoint commit.
        return LivePaneSession(
            id: paneID,
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
        case let .claudeStatus(state, kind, _):
            // TRUST the host's verdict: map the raw urgency byte → ClaudeStatus directly (forward-tolerant
            // — an unknown/future byte degrades to `.none`; a hostile datagram can never trap the client).
            // The `kind` qualifier rides alongside (same forward-tolerance) so the store can tell an
            // ANNOUNCEABLE transition from a bookkeeping one — see ``lastStatusKind``.
            lastStatusKind = AgentStatusKind(wireByte: kind)
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
            }
            isVideoActive = model.active != nil
        } else {
            model.close()
            isVideoActive = false
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
        if isVideoActive || remoteWindow?.active != nil {
            remoteWindow?.close()
            isVideoActive = false
        }
    }
}

/// The first connected pane's metadata façade, for the host-GLOBAL asks that have no pane of their
/// own.
///
/// `MetadataClient` is one-per-pane, but several things routed through it are machine-wide — the
/// agent-hooks install/uninstall card, the editor font push. They have no pane to name, so they take
/// whichever pane is currently carrying a live channel.
///
/// Resolved at CALL time, never cached: a reconnect transparently re-points the seam, and `nil` here
/// is a real answer (no connected pane) that the caller renders as `.disconnected` rather than a dead
/// button. Two callers had their own copy of this walk; the store owns the pane handles, so it owns
/// the walk.
public extension WorkspaceStore {
    var firstConnectedMetadataClient: MetadataClient? {
        for id in tree.activeSession?.allPaneIDs() ?? [] {
            if let client = (handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient {
                return client
            }
        }
        return nil
    }
}
