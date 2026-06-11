import Foundation
import AislopdeskClient
import AislopdeskInspector

// MARK: - LivePaneSession (the production handle)

/// The production ``PaneSessionHandle``: it OWNS the proven per-session objects verbatim and is the
/// only thing in the workspace layer that touches the live byte pipeline (docs/22 §2.3, §7).
///
/// One `LivePaneSession` ⇒ one ``ConnectionViewModel`` ⇒ one ordered-OUT stream, one events
/// consumer, one `ReconnectManager`. Keying the store registry by ``PaneID`` and minting exactly one
/// of these per leaf is what preserves the four byte-pipeline invariants **by construction** — a
/// session is never shared across panes (docs/22 §1.2).
///
/// What it wraps, by kind:
/// - `.terminal`   → `connection` (+ its `terminalModel`) + `inputBar`.
/// - `.claudeCode` → the same, PLUS an `inspector` (a read-only `InspectorViewModel` fed by an
///   `InspectorClient` over NWConnection #2). The terminal|inspector split is per-pane VIEW state
///   (WF5), NOT a tree node — a Claude Code pane is a single leaf.
/// - `.remoteGUI`  → a `remoteWindow` (`RemoteWindowModel`) instead of a connection-backed terminal.
///
/// ### Lazy connect (load-bearing, docs/22 §6 RESTORED-vs-RECONNECTED)
/// ``make(_:makeClient:makeInspector:)`` BUILDS the `ConnectionViewModel` (host/port pre-filled from
/// `spec.endpoint`) but does **not** call `connect()`. The view triggers `connect()` lazily on appear
/// (WF4/WF5) so restoring a 12-pane workspace does not slam 12 sockets at launch.
@MainActor
@Observable
public final class LivePaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    // MARK: Identity

    /// Set at construction to a placeholder, then re-pointed to the leaf's id by the store's
    /// `reconcile()` via ``adopt(id:)`` (the injection seam is spec-only — see
    /// ``PaneSessionIDAdopting``). Stable for the rest of the session's lifetime thereafter.
    public private(set) var id: PaneID
    public let kind: PaneKind

    // MARK: Proven per-session objects (wrapped verbatim)

    /// Owns the ordered-OUT drain + single events loop + `ReconnectManager`. `nil` only for a
    /// `.remoteGUI` pane (which has no PATH-1 terminal connection).
    public let connection: ConnectionViewModel?

    /// The per-pane external input affordance (A / B1 dedup ring). Present whenever there is a
    /// terminal connection (`.terminal` / `.claudeCode`).
    public let inputBar: InputBarModel?

    /// The read-only structured inspector for a `.claudeCode` pane (NWConnection #2). `nil` for other
    /// kinds. The model is durable across pause/resume; the `client` is closed on pause and rebuilt on
    /// resume (see the pause/resume contract below). `model` is `let` (the upsert/dedup keeps a
    /// re-tail safe); `client` is `var` because resume swaps in a fresh one.
    public let inspector: InspectorViewModel?
    /// The live inspector second-channel client. Set when the inspector is subscribed; nilled on
    /// pause/teardown. Private so callers go through the lifecycle methods.
    private var inspectorClient: InspectorClient?
    /// The detached re-subscribe task spawned by ``resume()``. Tracked + cancelled by `pause()` /
    /// `teardown()` so a re-subscribe that loses the race against a same-turn teardown is cancelled and
    /// closes the socket it just built — defusing the "T builds a client after teardown" window. The
    /// detachment is load-bearing: `subscribeInspector()` ends in `await model.consume(...)`, which only
    /// returns when the stream closes, so it can NEVER be awaited inline by `resume()` (that would hang
    /// the scenePhase foreground fan-out). It is tracked + cancellable, not awaited.
    private var inspectorTask: Task<Void, Never>?

    /// The remote-GUI (video) model for a `.remoteGUI` pane. `nil` for other kinds.
    public let remoteWindow: RemoteWindowModel?

    // MARK: Re-open glue for pause/resume

    /// The factory the store handed in, retained so `resume()` can rebuild a fresh ``InspectorClient``
    /// after `pause()` closed the previous one (iOS would otherwise kill the app for stranding a
    /// background socket — docs/22 DECISIONS). `nil` for non-`.claudeCode` panes.
    private let makeInspector: (@MainActor (ConnectionTarget) -> InspectorClient?)?
    /// Resolves the CURRENT app target for the inspector second-channel build/rebuild (the inspector
    /// rides the same host as the terminal, on the terminal port + 1). Read fresh at subscribe-time so a
    /// host change is picked up. `nil` for non-`.claudeCode` panes.
    private let target: (@MainActor () -> ConnectionTarget)?

    // MARK: Video activation

    /// See ``PaneSessionHandle/isVideoActive``. Mirrors whether the `remoteWindow` has an active
    /// descriptor; always `false` for non-`.remoteGUI` panes.
    public private(set) var isVideoActive: Bool = false

    /// Whether this `.remoteGUI` pane's video was active when ``pause()`` suspended it, so ``resume()``
    /// can re-open exactly the set that was admitted before background. Cap-safe WITHOUT consulting the
    /// store: resume re-opens at most what already satisfied `liveVideoCap`, so it cannot exceed it.
    private var wasVideoActiveBeforePause = false

    // MARK: Automation seam (AISLOPDESK_AUTOTYPE)

    /// Whether this session is the `AISLOPDESK_AUTOTYPE` OUT-path-proof target — the first leaf of the
    /// first tab (docs/22 §7). Set by the store's `reconcile()` (the store owns the tree, so it is the
    /// authority on "tab0/pane0"); read by the terminal leaf's `.task` after connect to push the
    /// command bytes through the REAL OUT path so `scripts/check-macos.sh --connect` keeps proving
    /// type→exec→render. Defaults `false`; the seam fires for exactly one session.
    public internal(set) var isAutotypeTarget: Bool = false

    // MARK: Passthrough

    /// The terminal model the leaf view renders, or `nil` for a `.remoteGUI` pane. A convenience over
    /// `connection.terminalModel` so the view never reaches into the connection.
    public var terminalModel: TerminalViewModel? { connection?.terminalModel }

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
        target: (@MainActor () -> ConnectionTarget)?
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
    }

    // MARK: - Factory (the store's makeSession production path)

    /// Builds the live session for `spec`, wiring the proven objects for its kind WITHOUT connecting
    /// (docs/22 §6 lazy connect). This is what the store injects as `makeSession` in production.
    ///
    /// - Parameters:
    ///   - spec: the leaf intent (kind + endpoint(s) + title). Endpoint pre-fills the connection /
    ///     remote-window form fields; an unconfigured spec yields an idle, fillable session.
    ///   - makeClient: the threaded `@Sendable () -> AislopdeskClient` the `ConnectionViewModel` uses to
    ///     stand up the client on `connect()`. Passed through verbatim — the store never fakes the
    ///     client (it fakes the whole session via `makeSession`, docs/22 §0).
    ///   - makeInspector: builds the read-only `InspectorClient` (NWConnection #2) for a `.claudeCode`
    ///     pane's endpoint, or returns `nil` when no second channel is available. Retained for the
    ///     `resume()` rebuild.
    public static func make(
        _ spec: PaneSpec,
        makeClient: @escaping @Sendable () -> AislopdeskClient,
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient?,
        target: @escaping @MainActor () -> ConnectionTarget = { .default }
    ) -> LivePaneSession {
        // `make` is a pure spec→session factory: the spec carries no id (identity lives on the tree's
        // leaf), so the session mints a placeholder ``PaneID`` here and the store's `reconcile()`
        // immediately re-points it to the real leaf id via `adopt(id:)` before registering it.
        switch spec.kind {
        case .terminal:
            return makeTerminal(spec, claudeCode: false, makeClient: makeClient, makeInspector: makeInspector, target: target)
        case .claudeCode:
            return makeTerminal(spec, claudeCode: true, makeClient: makeClient, makeInspector: makeInspector, target: target)
        case .remoteGUI:
            return makeRemoteGUI(spec, target: target)
        }
    }

    /// Builds a `.terminal` / `.claudeCode` session: a `ConnectionViewModel` bound to the app target
    /// (NOT connected) + an `InputBarModel`, plus an inspector model for `.claudeCode`.
    private static func makeTerminal(
        _ spec: PaneSpec,
        claudeCode: Bool,
        makeClient: @escaping @Sendable () -> AislopdeskClient,
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient?,
        target: @escaping @MainActor () -> ConnectionTarget
    ) -> LivePaneSession {
        let terminal = TerminalViewModel()
        let connection = ConnectionViewModel(
            terminal: terminal,
            target: target,
            makeClient: makeClient
        )
        let inputBar = InputBarModel()

        let inspectorModel: InspectorViewModel? = claudeCode ? InspectorViewModel() : nil

        return LivePaneSession(
            id: PaneID(),
            kind: spec.kind,
            connection: connection,
            inputBar: inputBar,
            inspector: inspectorModel,
            inspectorClient: nil,                          // opened lazily by subscribeInspector()
            remoteWindow: nil,
            makeInspector: claudeCode ? makeInspector : nil,
            target: claudeCode ? target : nil
        )
    }

    /// Builds a `.remoteGUI` session: a `RemoteWindowModel` bound to the app target with the per-pane
    /// window pre-filled, NOT opened (UDP is user-initiated — docs/22 §6).
    private static func makeRemoteGUI(
        _ spec: PaneSpec,
        target: @escaping @MainActor () -> ConnectionTarget
    ) -> LivePaneSession {
        let model: RemoteWindowModel
        if let v = spec.video {
            model = RemoteWindowModel(target: target, windowID: String(v.windowID), title: v.title)
        } else {
            model = RemoteWindowModel(target: target)
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
            target: nil
        )
    }

    // MARK: - ID adoption (store-internal)

    /// See ``PaneSessionIDAdopting``. The store re-points a freshly-built session at its leaf id.
    func adopt(id: PaneID) { self.id = id }

    // MARK: - Inspector second channel

    /// Opens + subscribes the inspector second channel (full replay from seq 0), then folds its event
    /// stream into `inspector` until the stream ends. Called by the view's `.task` on appear (WF5) and
    /// by ``resume()``. Idempotent: if a client is already live it does nothing. The fold is
    /// re-tail-safe because the model upserts/dedupes tool cards by id (docs/22 DECISIONS) — so a
    /// resume that replays the whole transcript tail does not duplicate cards.
    public func subscribeInspector() async {
        guard kind == .claudeCode, let model = inspector else { return }
        guard inspectorClient == nil else { return }
        guard let target, let client = makeInspector?(target()) else { return }
        // Cancelled before we stored anything (e.g. pause()/teardown() fired between resume's spawn and
        // here) — close the just-built client so its lazily-opened socket is never stranded.
        if Task.isCancelled { await client.close(); return }
        inspectorClient = client
        try? await client.subscribe(fromSeq: 0)
        // Torn down WHILE we were subscribing: drop our reference (if still ours) and close — this is
        // the window that actually defuses "a re-subscribe builds a live client after teardown".
        if Task.isCancelled {
            if inspectorClient === client { inspectorClient = nil }
            await client.close()
            return
        }
        // Fold the live stream. `consume` returns when the stream finishes (transport closed, e.g. by
        // a `pause()` that closed the client) — at which point we drop the dangling reference so a
        // later `resume()` can rebuild.
        await model.consume(client.events())
        if inspectorClient === client { inspectorClient = nil }
    }

    // MARK: - PaneSessionHandle: video activation

    public func setVideoActive(_ active: Bool) {
        guard kind == .remoteGUI, let model = remoteWindow else { return }
        if active {
            // Open only if configured; mirror the resulting active state.
            if model.active == nil, model.canOpen { model.open() }
            isVideoActive = model.active != nil
        } else {
            model.close()
            isVideoActive = false
        }
    }

    // MARK: - PaneSessionHandle: lifecycle (the single fan-out points)

    /// iOS background. Fans to BOTH halves:
    /// - **connection**: `ConnectionViewModel.pause()` (host retains the tail; byte-exact resume).
    /// - **inspector**: CLOSES the NWConnection #2 (docs/22 DECISIONS) — iOS kills an app that strands
    ///   a background socket, and the inspector is read-only + idempotent so a full re-tail on resume
    ///   is safe and needs no host-side seq buffering. Closing the client finishes the `events()`
    ///   stream, which unblocks the `consume` loop in ``subscribeInspector()`` (it then nils the ref).
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
        // Remember it was active so resume() can re-open at most the set that was already admitted.
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
        // Restore live video for a `.remoteGUI` pane that was active before pause (cap-safe: re-opens
        // at most the set already admitted, so it cannot exceed liveVideoCap — no store consult needed).
        if kind == .remoteGUI, wasVideoActiveBeforePause {
            wasVideoActiveBeforePause = false
            setVideoActive(true)
        }
        if kind == .claudeCode, inspector != nil, inspectorClient == nil {
            // Track + cancel a prior re-subscribe before spawning a fresh one, so a teardown/pause that
            // arrives in the same main-actor turn can cancel this (the subscribeInspector() cancellation
            // re-checks then close the just-built client). NOT awaited — the fold blocks until the
            // stream closes, so awaiting here would hang the scenePhase foreground fan-out.
            inspectorTask?.cancel()
            inspectorTask = Task { [weak self] in await self?.subscribeInspector() }
        }
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
