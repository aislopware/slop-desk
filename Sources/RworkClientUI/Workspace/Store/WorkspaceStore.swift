import Foundation
import CoreGraphics
import Network
import RworkClient
import RworkInspector

// MARK: - WorkspaceStore (the one @MainActor @Observable owner)

/// The single owner of the workspace: it holds the pure ``Workspace`` tree of intent and reconciles
/// the `[PaneID: any PaneSessionHandle]` table of liveness against it after every mutation
/// (docs/22 §1.1, §2.3).
///
/// ### The shape of every mutation
/// Each public intent method does exactly two things, in order:
/// 1. apply a **pure** tree op from WF2 (returns a new `Workspace`), and
/// 2. call ``reconcile()`` to materialize sessions for new leaves and tear down orphaned ones.
///
/// Because every mutation funnels through `reconcile()`, the load-bearing invariant
/// `Set(registry.keys) == Set(allLeafIDs)` holds after *any* sequence of ops, and there is exactly
/// ONE ``LivePaneSession`` (hence one ordered-OUT stream, one events consumer, one `ReconnectManager`)
/// per ``PaneID`` — the four byte-pipeline invariants by construction (docs/22 §1.2).
///
/// ### The test seam
/// Sessions are built through the injected `makeSession` factory — NOT a fake `RworkClient` (which is
/// impossible) and NEVER a real `HostServer` (forbidden, pool deadlock). Tests inject a
/// `FakePaneSession`; production injects ``LivePaneSession/make(_:makeClient:makeInspector:)``.
@MainActor
@Observable
public final class WorkspaceStore {
    // MARK: State

    /// The pure tree of intent — the single source of truth. `private(set)`: only the mutation
    /// methods change it (each then reconciles), so the registry can never drift from the tree.
    public private(set) var workspace: Workspace

    /// The table of liveness: 1:1 with the leaves of `workspace`. `reconcile()` is the only writer.
    private var registry: [PaneID: any PaneSessionHandle] = [:]

    /// The injection seam (docs/22 §0). Spec-only — the store re-points the built handle at the leaf
    /// id via `adopt(id:)` (see ``PaneSessionIDAdopting``).
    private let makeSession: @MainActor (PaneSpec) -> any PaneSessionHandle

    /// Maximum number of `.remoteGUI` panes that may hold a LIVE video stack at once (docs/22 §7 the
    /// 2N-UDP / N-VTDecompression / N-CVDisplayLink ceiling). Injectable; default 2. The app now resolves
    /// it per device class via ``VideoCapPolicy`` (phone 1 / pad 2 / mac 3, ITEM #5); the store keeps the
    /// plain `Int` shape and is agnostic to how the number was chosen.
    public let liveVideoCap: Int

    /// A monotonic nudge the view layer observes to RE-ATTEMPT video admission for gated panes (ITEM
    /// #2). The store can never flip a pane's liveness itself — admission is **view-driven**: only an
    /// on-screen pane decodes, via ``RemoteGUIPaneView``'s `.onAppear` → ``activateVideo(_:)``. So when
    /// a slot frees (a video pane deactivated, or an active-video pane was closed), there is no one to
    /// promote a queued-but-still-on-screen pane that was previously gated. This counter is bumped on
    /// exactly those slot-freeing events; the gated leaves observe it via `.onChange` and re-call
    /// `activateVideo` — which still flows through the cap, so the ceiling is never breached. Only the
    /// store bumps it (`private(set)`), and the bump is GUARDED to real slot-freeing transitions so a
    /// no-op deactivate / a non-video close never churns the view. Pure MainActor `Int` bookkeeping (no
    /// new concurrency / Sendable surface).
    public private(set) var videoPromotionGeneration: Int = 0

    /// Where the value tree is persisted (docs/22 §6). Injectable so tests point at a temp dir and a
    /// store built with `nil` persistence (the default for the FakePaneSession test seam) never
    /// touches disk. The app passes a real ``WorkspacePersistence``.
    private let persistence: WorkspacePersistence?

    /// How long to coalesce a burst of mutations before writing the tree (docs/22 §6 "debounced on
    /// mutation"). One write per quiet period, not one per keystroke-driven split/resize.
    private let saveDebounce: Duration

    /// The pending debounced-save task. Cancelled + replaced on each mutation so only the last
    /// mutation in a burst actually writes; cancel-safe (a cancelled sleep simply returns).
    private var saveTask: Task<Void, Never>?

    /// A monotonic save-generation guard (mirrors the ``FocusGenerationGuard`` idiom). Each
    /// `scheduleSave()` bumps it and captures the value; the debounced write re-checks it on a MainActor
    /// hop BEFORE writing and skips if superseded (BUG-D), and the trailing `saveTask = nil` clears the
    /// handle ONLY if it is still the current generation — so a superseded (but already-past-sleep) prior
    /// task can neither clobber the file with a stale snapshot NOR nil out the newest handle and strand
    /// it uncancellable. Pure MainActor Int bookkeeping (no new concurrency / Sendable surface).
    /// `internal private(set)` so only the store bumps it, but the generation-guard logic is observable
    /// to the `@testable` BUG-D test via ``isCurrentSaveGeneration(_:)``.
    private(set) var saveGeneration = 0

    /// The pure generation-guard predicate the debounced write consults before writing (BUG-D): a
    /// captured `generation` is still current iff it equals the live ``saveGeneration``. Mirrors
    /// `FocusGenerationGuard.isCurrent(_:)`. Factored out so the production write path and the test
    /// assert the EXACT SAME logic (not a re-implementation). MainActor-isolated; pure read.
    func isCurrentSaveGeneration(_ generation: Int) -> Bool {
        saveGeneration == generation
    }

    /// Suppresses the debounced save during construction (the initial `reconcile()` would otherwise
    /// re-write a just-loaded file with identical bytes). Flipped off once init completes.
    private var savingEnabled = false

    /// In-flight teardown tasks spawned by ``reconcile()`` (teardown is `async`; reconcile is called
    /// inline by synchronous mutations). Tracked so tests — and a deliberate shutdown — can `await`
    /// every orphaned session's `teardown()` to actually complete via ``quiesce()``. The registry
    /// invariant (`keys == leafIDs`) holds the instant reconcile returns (orphans are removed
    /// synchronously); `quiesce()` only waits for the *cleanup* of those already-removed sessions.
    ///
    /// Keyed by a monotonic id (not an array) so each task can self-prune its own entry on completion
    /// without the task-captures-itself chicken-and-egg — freeing the handle promptly rather than only
    /// on the next orphaning reconcile. Every site (the reconcile insert, the self-remove, the
    /// `quiesce()` drain) runs on `@MainActor`, so the bookkeeping is serialized with no data race.
    private var teardownTasks: [Int: Task<Void, Never>] = [:]
    /// The next teardown-task id (monotonic, wraps harmlessly).
    private var nextTeardownID = 0

    /// The ids of `.remoteGUI` panes whose video stack is STILL tearing down (orphaned by a reconcile,
    /// removed from the registry, but their async `teardown()` — which stops the UDP / VTDecompression /
    /// CVDisplayLink stack — has not yet completed). This is what protects the ``liveVideoCap`` ceiling
    /// across a same-tick close+reopen (docs/22 §7, ITEM #3): a pane that is gone from the registry but
    /// still holding its video resources must keep counting against the cap until those resources are
    /// actually released. `reconcile()` inserts an orphan's id here (reading `isVideoActive` BEFORE
    /// teardown nils it); the orphan's teardown task removes it after the `await`. ``activateVideo(_:)``
    /// adds `tearingDownVideo.count` to the live count, and ``quiesce()`` defensively clears it. Every
    /// site runs on `@MainActor`, serialized with the `teardownTasks` self-prune — no data race.
    private var tearingDownVideo: Set<PaneID> = []

    /// The last layout the view solved, cached so geometric ``move(_:)`` can resolve a neighbour
    /// without the store knowing the view's size. `nil` until the view reports one (compact mode never
    /// solves a multi-pane layout — `.next`/`.previous` still work via the pre-order cycle fallback).
    private var lastSolvedLayout: SolvedLayout?

    /// The single-focus arbiter for the iOS multi-visible (iPad-regular) input path (docs/22 §7). One
    /// per workspace, created alongside the store. The regular `PaneTreeView` leaves route their
    /// ``TerminalInputHost`` first-responder through this so a stale async `becomeFirstResponder`
    /// callback can never win (resign-before-become + generation reject). Compact mode mounts exactly
    /// one host and skips it. Cross-platform-compilable (the UIKit calls inside are `#if os(iOS)`), so
    /// the macOS build is unaffected. Exposed so the view layer can drive `focus(_:)` on a focus
    /// change.
    public let focusCoordinator = PaneFocusCoordinator()

    // MARK: Init

    /// - Parameters:
    ///   - restoring: a decoded workspace to restore (SHAPE + INTENT only — sessions start idle,
    ///     docs/22 §6). `nil` ⇒ ``Workspace/defaultWorkspace()`` (one terminal tab).
    ///   - makeSession: the session factory seam (production: `LivePaneSession.make`; tests:
    ///     `{ FakePaneSession($0) }`).
    ///   - liveVideoCap: concurrent live-video ceiling (default 2).
    ///   - persistence: where to debounce-save the tree after mutations (docs/22 §6). `nil` (the
    ///     default) ⇒ no disk writes, so the pure/fake test seam never touches the filesystem; the app
    ///     passes a real ``WorkspacePersistence``.
    ///   - saveDebounce: the mutation-coalescing window before a write (default 600ms).
    public init(
        restoring: Workspace? = nil,
        makeSession: @escaping @MainActor (PaneSpec) -> any PaneSessionHandle,
        liveVideoCap: Int = 2,
        persistence: WorkspacePersistence? = nil,
        saveDebounce: Duration = .milliseconds(600)
    ) {
        self.workspace = restoring ?? .defaultWorkspace()
        self.makeSession = makeSession
        self.liveVideoCap = liveVideoCap
        self.persistence = persistence
        self.saveDebounce = saveDebounce
        reconcile()   // materialize idle sessions for the restored/default leaves
        savingEnabled = true   // arm debounced saves only AFTER the restore reconcile
    }

    // MARK: - Accessors

    /// The live handle for `id`, or `nil` if no such leaf is materialized.
    public func handle(for id: PaneID) -> (any PaneSessionHandle)? { registry[id] }

    /// All live sessions (registry values). Order is unspecified — callers that need a stable order
    /// derive it from the tree's `allLeafIDs()`.
    public var allSessions: [any PaneSessionHandle] { Array(registry.values) }

    /// The active tab, or `nil` (a pure passthrough to the tree).
    public var activeTab: Tab? { workspace.activeTab }

    /// Whether `id` is the focused pane of the active tab (the view's focus-ring decision).
    public func isFocused(_ id: PaneID) -> Bool { workspace.activeTab?.focusedPane == id }

    /// Whether `id` is a leaf of the ACTIVE tab — i.e. genuinely on-screen (any pane of the active
    /// tab is visible; a non-active tab's panes are not). A reliable visibility signal for the video
    /// teardown decision, unlike SwiftUI's `.onDisappear`, which fires spuriously during the initial
    /// NavigationSplitView layout settle even though the pane stays on screen (the autoconnect
    /// connect bug). The debounced teardown re-checks this so a spurious disappear (still on the
    /// active tab) is ignored and only a real tab switch (pane left the active tab) deactivates.
    public func isPaneOnActiveTab(_ id: PaneID) -> Bool { workspace.activeTab?.root.contains(id) ?? false }

    /// All leaf ids across every tab (the reconcile diff domain). Pre-order within each tab.
    private func allLeafIDs() -> [PaneID] {
        workspace.tabs.flatMap { $0.root.allLeafIDs() }
    }

    // MARK: - Layout reporting (for geometric focus move)

    /// The view reports the layout it just solved for the active tab so the store can resolve
    /// geometric focus moves (``move(_:)``) against the exact rects the user sees (docs/22 §2.1).
    /// View-only state — does NOT touch the tree or registry, so reporting it never reconciles.
    public func updateSolvedLayout(_ solved: SolvedLayout) {
        lastSolvedLayout = solved
    }

    // MARK: - Tab mutations (pure op → reconcile)

    /// Appends a fresh single-leaf tab of `kind` and activates it.
    public func addTab(kind: PaneKind) {
        workspace = workspace.adding(kind: kind, title: defaultTitle(for: kind))
        reconcile()
    }

    /// Closes tab `id` (reselecting a neighbour if it was active); reconcile tears down its leaves.
    public func closeTab(_ id: TabID) {
        workspace = workspace.closing(id)
        reconcile()
    }

    /// Activates tab `id`. Pure focus change — but still reconciles (idempotent; a no-op for the
    /// registry since the leaf set is unchanged) to keep every mutation uniform.
    public func selectTab(_ id: TabID) {
        workspace = workspace.selecting(id)
        reconcile()
    }

    /// Reorders tabs (SwiftUI `onMove` semantics). Pure reorder; leaf set unchanged.
    public func moveTab(from source: IndexSet, to destination: Int) {
        workspace = workspace.moving(from: source, to: destination)
        reconcile()
    }

    /// Renames tab `id`. Pure; leaf set unchanged.
    public func renameTab(_ id: TabID, _ name: String) {
        workspace = workspace.renaming(id, to: name)
        reconcile()
    }

    // MARK: - Pane mutations (pure op → reconcile)

    /// Splits leaf `id` along `axis`, adding a new leaf of `kind` as a sibling, and focuses the new
    /// leaf. Applies to whichever tab owns `id` (almost always the active tab). Reconcile materializes
    /// the one new session.
    public func split(_ id: PaneID, axis: SplitAxis, kind: PaneKind) {
        guard let tabID = tabID(owning: id) else { return }
        let newLeafID = PaneID()
        let spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        workspace = workspace.updatingTab(tabID) { tab in
            tab.root = tab.root.splitting(id, axis: axis, newLeaf: (newLeafID, spec))
            // Focus the new leaf if the split actually created it (it exists in the new tree).
            if tab.root.contains(newLeafID) {
                tab.focusedPane = newLeafID
            }
            // A split invalidates any zoom on this tab (the layout changed).
            if tab.zoomedPane != nil { tab.zoomedPane = nil }
        }
        reconcile()
    }

    /// Closes pane `id`. If it was the last leaf in its tab, the tab is closed. Otherwise focus
    /// re-points to a surviving neighbour. Reconcile tears down the removed session.
    public func closePane(_ id: PaneID) {
        guard let tabID = tabID(owning: id) else { return }
        // Capture a geometric neighbour BEFORE the close (so refocus follows what the user saw).
        let refocus = neighbourForRefocus(of: id, inTab: tabID)

        var closedTab = false
        workspace = workspace.updatingTab(tabID) { tab in
            guard let newRoot = tab.root.closing(id) else {
                closedTab = true       // the tab emptied
                return
            }
            tab.root = newRoot
            if tab.focusedPane == id {
                tab.focusedPane = refocus ?? newRoot.allLeafIDs().first ?? tab.focusedPane
            }
            if tab.zoomedPane == id { tab.zoomedPane = nil }
        }
        if closedTab {
            workspace = workspace.closing(tabID)
        }
        reconcile()
    }

    /// Focuses pane `id` in its owning tab (a pure focus change; leaf set unchanged).
    public func focus(_ id: PaneID) {
        guard let tabID = tabID(owning: id) else { return }
        workspace = workspace.updatingTab(tabID) { tab in
            if tab.root.contains(id) { tab.focusedPane = id }
        }
        reconcile()
    }

    /// Moves focus in `dir` within the active tab, resolved geometrically against the last solved
    /// layout (docs/22 §2.1). `.next`/`.previous` fall back to the pre-order leaf cycle when no layout
    /// has been reported yet (e.g. compact mode), so cycling always works.
    public func move(_ dir: FocusDirection) {
        guard let tab = workspace.activeTab else { return }
        let target: PaneID?
        switch dir {
        case .next, .previous:
            // Prefer the geometric reading-order cycle if a layout is known; else the tree's
            // canonical pre-order cycle.
            if let solved = lastSolvedLayout, solved.frames[tab.focusedPane] != nil {
                target = FocusResolver.neighbor(of: tab.focusedPane, dir, in: solved)
            } else {
                target = FocusResolver.cycle(tab.root.allLeafIDs(), from: tab.focusedPane, forward: dir == .next)
            }
        case .left, .right, .up, .down:
            guard let solved = lastSolvedLayout else { return }
            target = FocusResolver.neighbor(of: tab.focusedPane, dir, in: solved)
        }
        guard let target, target != tab.focusedPane else { return }
        focus(target)
    }

    /// Toggles zoom on the active tab's focused pane (a presentation flag — no tree surgery, so the
    /// registry is untouched, docs/22 §3). Reconcile is still called for uniformity (it is a no-op:
    /// the leaf set did not change).
    public func toggleZoom() {
        guard let tabID = workspace.activeTabID else { return }
        workspace = workspace.updatingTab(tabID) { tab in
            tab.zoomedPane = (tab.zoomedPane == tab.focusedPane) ? nil : tab.focusedPane
        }
        reconcile()
    }

    /// Sets the `fractions` of the split addressed by `path` in `tab` (e.g. after a divider drag).
    /// Pure geometry change; leaf set unchanged so reconcile is a no-op.
    public func setFractions(tab: TabID, path: [Int], to fractions: [Double]) {
        workspace = workspace.updatingTab(tab) { t in
            t.root = t.root.settingFractions(at: path, to: fractions)
        }
        reconcile()
    }

    // MARK: - Spec mutation (rename / fill endpoint)

    /// Transforms the spec of leaf `id` in place (rename, fill in an endpoint, …). The leaf set is
    /// unchanged so reconcile is a no-op — but the session already exists; re-materialization is NOT
    /// triggered by a spec edit (a live session is not rebuilt under the user). To re-point a live
    /// connection at a new endpoint, the view drives the session's connect form directly.
    public func updateSpec(_ id: PaneID, _ transform: @escaping (inout PaneSpec) -> Void) {
        guard let tabID = tabID(owning: id) else { return }
        workspace = workspace.updatingTab(tabID) { tab in
            tab.root = tab.root.updatingSpec(id, transform)
        }
        reconcile()
    }

    // MARK: - Video activation (cap-enforced)

    /// Requests live-video activation for `.remoteGUI` pane `id`, enforcing ``liveVideoCap`` (docs/22
    /// §7). Returns `true` if the pane is now active, `false` if the cap is already saturated by OTHER
    /// active video panes (the caller then shows the gated placeholder until a slot frees). A no-op
    /// `true` if it is already active. Non-video panes return `false`.
    @discardableResult
    public func activateVideo(_ id: PaneID) -> Bool {
        guard let handle = registry[id], handle.kind == .remoteGUI else { return false }
        if handle.isVideoActive { return true }
        guard hasFreeVideoSlot(for: id) else { return false }
        handle.setVideoActive(true)
        return handle.isVideoActive
    }

    /// Whether a live-video slot is currently free FOR pane `id` — a pure READ that mirrors the exact
    /// admission guard ``activateVideo(_:)`` uses, with NO mutation (BUG-A). The view layer consults
    /// this to tell the two false-activation reasons apart: a `.remoteGUI` pane whose `activateVideo`
    /// would refuse because the cap is **saturated** (→ the gated placeholder) versus one that is merely
    /// **unconfigured** (→ the entry form so the user can still dial in). It self-excludes `id` exactly
    /// as `activateVideo` does (an already-active pane sees its own slot as free), and counts the
    /// in-flight `tearingDownVideo` stacks against the cap so the answer agrees with what an admission
    /// attempt this same tick would actually decide.
    ///
    /// `@Observable` reads of `registry` make this reactive — but the view layer ALSO re-attempts via
    /// the explicit ``videoPromotionGeneration`` nudge on slot-freeing events, so this read need not be
    /// the only liveness trigger; it is the cap-vs-config discriminator for the display decision.
    public func hasFreeVideoSlot(for id: PaneID) -> Bool {
        let activeOthers = registry.values.filter { $0.kind == .remoteGUI && $0.isVideoActive && $0.id != id }.count
        // Count panes whose video stack is still TEARING DOWN against the cap too (ITEM #3): an orphan
        // closed this same tick is already gone from the registry but its UDP / VTDecompression /
        // CVDisplayLink stack is not released until its async teardown completes, so admitting a new
        // pane before then would transiently overlap two live stacks and breach the resource ceiling.
        // `tearingDownVideo` excludes `id` by construction (an in-flight-teardown id is not in the
        // registry, so it can never equal a live pane's id).
        let inFlight = tearingDownVideo.count
        return activeOthers + inFlight < liveVideoCap
    }

    /// Deactivates live video for pane `id` (the view's `.onDisappear`), freeing a cap slot.
    ///
    /// If this actually freed a LIVE slot (the pane was video-active), nudge ``videoPromotionGeneration``
    /// so an on-screen pane that was previously gated re-attempts admission (ITEM #2). The `wasActive`
    /// guard is load-bearing: a no-op deactivate (an already-idle / unknown / non-video pane) freed
    /// nothing, so it must NOT churn the generation — otherwise an `.onDisappear` of a never-admitted
    /// pane would spuriously re-trigger every gated sibling's retry for no gained slot.
    public func deactivateVideo(_ id: PaneID) {
        let wasActive = registry[id]?.isVideoActive == true
        registry[id]?.setVideoActive(false)
        if wasActive { videoPromotionGeneration &+= 1 }
    }

    // MARK: - Lifecycle fan-out (one site, AWAITED)

    /// iOS background: pause EVERY session, AWAITED. The single fan-out point — a `TaskGroup` whose
    /// child tasks hop onto the main actor and pause each session, but the WHOLE group is awaited
    /// before the app suspends (no fire-and-forget — docs/22 §4, §11.4).
    ///
    /// The child tasks capture only the Sendable ``PaneID`` and re-resolve the (main-actor-isolated,
    /// non-`Sendable`) handle inside the `@MainActor` body, so nothing non-`Sendable` crosses an actor
    /// boundary. The sessions are themselves `@MainActor`, so their `pause()` bodies serialize on the
    /// main actor; the `TaskGroup` is what guarantees every one is awaited.
    public func pauseAll() async {
        let ids = Array(registry.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.pauseSession(id) }
            }
        }
    }

    /// iOS foreground: resume EVERY session, AWAITED (mirror of ``pauseAll()``).
    public func resumeAll() async {
        let ids = Array(registry.keys)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.resumeSession(id) }
            }
        }
    }

    /// Pauses one session by id on the main actor (the `TaskGroup` child-task body — only the Sendable
    /// `PaneID` crosses; the handle is re-resolved here, never sent across the boundary).
    private func pauseSession(_ id: PaneID) async {
        await registry[id]?.pause()
    }

    private func resumeSession(_ id: PaneID) async {
        await registry[id]?.resume()
    }

    /// Awaits every in-flight orphan ``PaneSessionHandle/teardown()`` spawned by ``reconcile()`` to
    /// complete. The registry invariant already holds the moment a mutation returns (orphans are
    /// removed synchronously); this is for callers that must observe the *cleanup* having finished —
    /// app shutdown, and the reconcile/teardown-ordering tests (docs/22 §8). Idempotent; after it
    /// returns, no teardown is pending.
    ///
    /// LOOPS to a fixpoint (BUG-J): a teardown task awaits on the main actor, so a `reconcile()` that
    /// runs DURING one of these awaits (e.g. a mutation interleaved by the awaiting suspension) can
    /// insert a brand-new teardown task into `teardownTasks` after we snapshot it. A single
    /// snapshot-clear-await pass would drop that newcomer; instead we re-snapshot until the dict is
    /// empty, so every task — including ones spawned mid-drain — is awaited. Each pass clears its own
    /// snapshot's keys; a task that self-prunes after we cleared is a harmless no-op removeValue.
    public func quiesce() async {
        while !teardownTasks.isEmpty {
            let tasks = teardownTasks
            teardownTasks.removeAll()
            for task in tasks.values {
                await task.value
            }
        }
        // Defensive: after every teardown has completed, no `.remoteGUI` stack can still be tearing
        // down, so the in-flight video accounting must be empty. Clear it so a dropped self-remove (a
        // task whose `tearingDownVideo.remove` somehow did not run) can never strand a phantom slot
        // against the cap (ITEM #3).
        tearingDownVideo.removeAll()
    }

    // MARK: - Bootstrap from environment (automation seams)

    /// Builds the INITIAL workspace from the automation env vars (docs/22 §7), replacing the current
    /// `workspace` and reconciling. It only sets up SHAPE + INTENT (endpoints pre-filled) — it does
    /// **not** connect or open video; the connect / autotype / video-open TRIGGER stays in the view
    /// layer (WF4/WF5), so the env-var names stay unchanged and `check-macos.sh`/`check-video.sh`
    /// keep working.
    ///
    /// - `RWORK_AUTOCONNECT_HOST` + `RWORK_AUTOCONNECT_PORT` ⇒ pane 0 is a terminal with that
    ///   ``Endpoint`` pre-filled.
    /// - `RWORK_VIDEO_AUTOCONNECT_HOST` + media/cursor ports + window id ⇒ pane 0 is instead a
    ///   `.remoteGUI` with that ``VideoEndpoint`` pre-filled (video takes precedence — it is a
    ///   distinct check). Title from `RWORK_VIDEO_AUTOCONNECT_TITLE` if set.
    /// - neither set ⇒ the plain default single-terminal workspace.
    public func bootstrapFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) {
        if let video = Self.videoEndpoint(from: env) {
            let spec = PaneSpec(kind: .remoteGUI, title: video.title, video: video)
            workspace = Self.singleLeafWorkspace(spec: spec)
        } else if let endpoint = Self.terminalEndpoint(from: env) {
            let spec = PaneSpec(kind: .terminal, title: "Terminal", endpoint: endpoint)
            workspace = Self.singleLeafWorkspace(spec: spec)
        } else {
            workspace = .defaultWorkspace()
        }
        reconcile()
    }

    private static func terminalEndpoint(from env: [String: String]) -> Endpoint? {
        guard let host = env["RWORK_AUTOCONNECT_HOST"], !host.isEmpty,
              let portStr = env["RWORK_AUTOCONNECT_PORT"], let port = UInt16(portStr) else { return nil }
        return Endpoint(host: host, port: port)
    }

    private static func videoEndpoint(from env: [String: String]) -> VideoEndpoint? {
        guard let host = env["RWORK_VIDEO_AUTOCONNECT_HOST"], !host.isEmpty,
              let mediaStr = env["RWORK_VIDEO_AUTOCONNECT_MEDIA_PORT"], let media = UInt16(mediaStr),
              let cursorStr = env["RWORK_VIDEO_AUTOCONNECT_CURSOR_PORT"], let cursor = UInt16(cursorStr),
              let widStr = env["RWORK_VIDEO_AUTOCONNECT_WINDOW_ID"], let wid = UInt32(widStr) else { return nil }
        let title = env["RWORK_VIDEO_AUTOCONNECT_TITLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "Remote window"
        return VideoEndpoint(host: host, mediaPort: media, cursorPort: cursor, windowID: wid, title: title)
    }

    /// A one-tab, one-leaf workspace from `spec` (the bootstrap shape). The leaf id is minted fresh.
    private static func singleLeafWorkspace(spec: PaneSpec) -> Workspace {
        let paneID = PaneID()
        let tab = Tab(name: spec.title, root: .leaf(paneID, spec), focusedPane: paneID)
        return Workspace(tabs: [tab], activeTabID: tab.id)
    }

    // MARK: - reconcile (the single audited seam)

    /// The load-bearing diff (docs/22 §2.3). Idempotent. After it runs:
    ///
    ///   `Set(registry.keys) == Set(workspace.tabs.flatMap { $0.root.allLeafIDs() })`
    ///
    /// Steps, in order:
    /// 1. **Orphan removal (synchronous) + teardown (async, launched not awaited)** — for every
    ///    registry key NOT in the current leaf set, the entry is removed from the registry
    ///    SYNCHRONOUSLY (so the invariant `keys == leafIDs` holds the instant reconcile returns), and
    ///    its `teardown()` (proven `ConnectionViewModel` disconnect order + inspector close + video
    ///    stop) is LAUNCHED in an ordered, tracked `Task` that completes shortly AFTER materialize — it
    ///    is **not** awaited before materialization. The task is awaitable via ``quiesce()`` but never
    ///    awaited inline (reconcile is synchronous; see below).
    /// 2. **Materialize new leaves** — for every leaf id NOT yet in the registry, build the session
    ///    via `makeSession(spec)`, `adopt(id:)` so its identity is the leaf's, and register it. New
    ///    sessions are IDLE (lazy connect; video not activated — the cap is enforced at activation).
    ///
    /// A projection flip (compact ↔ regular) does NOT call this — it is a view-only change; the tree
    /// (hence the leaf set) is unchanged, so even if called it would be a no-op (docs/22 §4, §9.9).
    ///
    /// NOTE — same-tick close+reopen and the video ceiling (ITEM #3): because step-1 teardown is
    /// launched (not awaited) before step-2 materialize, a same-tick close of one `.remoteGUI` pane and
    /// open of another would transiently overlap their live video stacks while the first is still
    /// tearing down. The ceiling IS now protected without making reconcile `async`: step-1 records an
    /// orphan whose `isVideoActive` was true into `tearingDownVideo` (reading the flag BEFORE teardown
    /// nils it), the orphan's teardown task removes it after the `await`, and ``activateVideo(_:)``
    /// counts `tearingDownVideo.count` as occupied slots — so a new pane cannot be admitted until the
    /// orphan's UDP / VTDecompression / CVDisplayLink stack is actually released. reconcile staying
    /// synchronous is deliberate — it is called inline by every mutation method and from `init` — so
    /// awaiting teardown before materialize would ripple `async` through the whole mutation surface.
    private func reconcile() {
        let leafIDs = allLeafIDs()
        let leafSet = Set(leafIDs)

        // 1. Orphans: remove from the registry synchronously (the registry is the source of truth for
        //    "what is live"), then drive teardown. Removing first guarantees the invariant holds the
        //    instant reconcile returns, even though teardown's async cleanup completes slightly after.
        let orphans = registry.filter { !leafSet.contains($0.key) }.map(\.value)
        for orphan in orphans {
            registry.removeValue(forKey: orphan.id)
            // Hold the cap slot for an orphan that is STILL holding a live video stack (ITEM #3). Read
            // `isVideoActive` NOW, before the async teardown nils it, and record the id so
            // `activateVideo` keeps counting it until its teardown task actually releases the resources.
            if orphan.kind == .remoteGUI && orphan.isVideoActive {
                tearingDownVideo.insert(orphan.id)
                // Closing an ACTIVE video pane is a slot-freeing event (ITEM #2): once this orphan's
                // teardown releases its stack, a previously-gated on-screen sibling should re-attempt
                // admission. Nudge here (the close path) so gated leaves observe it and retry; the
                // retry still flows through `activateVideo`, which keeps counting `tearingDownVideo`
                // until the real release — so the ceiling holds even though the nudge fires now.
                videoPromotionGeneration &+= 1
            }
        }
        if !orphans.isEmpty {
            // Teardown in a dedicated task, in registry-removal order, each awaited inside the task (no
            // fire-and-forget races: this single task serializes the disconnect order across the
            // orphaned sessions). The task is tracked in `teardownTasks` so `quiesce()` can await the
            // cleanup to finish, and self-prunes its own entry on completion (id-keyed) so a completed
            // teardown frees its handle promptly. NOTE: the task is launched here, NOT awaited inline —
            // reconcile is synchronous (see the doc-comment's same-tick ceiling note).
            let id = nextTeardownID
            nextTeardownID &+= 1
            teardownTasks[id] = Task { @MainActor in
                for orphan in orphans {
                    await orphan.teardown()
                    // The orphan's video resources are now released — stop counting it against the cap
                    // (ITEM #3). Serialized on the main actor with `activateVideo`'s read, so a
                    // same-tick reopen sees the slot freed only after the real release.
                    self.tearingDownVideo.remove(orphan.id)
                }
                self.teardownTasks.removeValue(forKey: id)
            }
        }

        // 2. New leaves: materialize an idle session for each, binding its identity to the leaf id.
        for id in leafIDs where registry[id] == nil {
            guard let spec = spec(for: id) else { continue }
            let handle = makeSession(spec)
            (handle as? PaneSessionIDAdopting)?.adopt(id: id)
            registry[id] = handle
        }

        // 3. Mark the `RWORK_AUTOTYPE` target (docs/22 §7): the first leaf of the first tab. The store
        //    owns the tree, so it is the authority on "tab0/pane0"; the terminal leaf reads this flag
        //    after connect to fire the OUT-path proof. Recomputed every reconcile so the flag follows
        //    the tree (a reshape never strands it on a stale pane).
        let autotypeTarget = workspace.tabs.first?.root.allLeafIDs().first
        for (id, handle) in registry {
            (handle as? LivePaneSession)?.isAutotypeTarget = (id == autotypeTarget)
        }

        // 4. Keep the iOS first-responder arbiter's intent tracking the active tab's focused pane
        //    (docs/22 §7). Every mutation funnels through reconcile, so this is the single site that
        //    drives `focus(_:)`. The coordinator resolves it against whatever host is currently
        //    registered (a not-yet-mounted host re-claims itself in `register`), and rejects stale
        //    async callbacks by generation. A no-op on the compact single-host path / macOS.
        syncFocusCoordinator()

        // 5. Debounced persistence of the value tree (docs/22 §6). Every mutation funnels through
        //    reconcile, so this single site coalesces a burst of mutations into one write.
        scheduleSave()
    }

    /// The active tab the last ``syncFocusCoordinator()`` resolved against. Lets that sync detect a TAB
    /// SWITCH (BUG-K) — distinct from a same-tab focus change — so it can FORCE a re-claim of the new
    /// tab's focused terminal even when the coordinator's bookkeeping already names that pane.
    private var lastSyncedActiveTab: TabID?

    /// Points the ``focusCoordinator`` at the active tab's focused pane. Called at the end of every
    /// reconcile so the iPad-regular input focus follows the tree's intent.
    ///
    /// Two paths:
    /// - **Same tab, focus moved** → guarded `focus(_:)`: only re-mints a generation when the target
    ///   actually changed, so a no-op reconcile (selectTab-of-active / setFractions) does not churn.
    /// - **Tab switched** (BUG-K) → `reassertFocus(_:)`: forces a fresh generation + re-claim of the new
    ///   tab's focused terminal REGARDLESS of the coordinator's `focusedPane` bookkeeping. On a tab
    ///   switch the new tab's host can register while `focusedPane` still names that same pane from a
    ///   prior life, so the guarded path would skip the claim and the new tab's terminal would never
    ///   take the keyboard. The guard is the wrong tool across a tab boundary, so we bypass it there.
    private func syncFocusCoordinator() {
        let activeTab = workspace.activeTabID
        let tabSwitched = activeTab != lastSyncedActiveTab
        lastSyncedActiveTab = activeTab
        guard let focused = workspace.activeTab?.focusedPane else { return }
        if tabSwitched {
            focusCoordinator.reassertFocus(focused)
        } else if focusCoordinator.focusedPane != focused {
            focusCoordinator.focus(focused)
        }
    }

    // MARK: - Persistence (debounced; cancel-safe)

    /// Schedules a debounced save of the value tree (docs/22 §6). Cancels any pending save and starts
    /// a fresh one, so a burst of mutations writes exactly once after the quiet period. Cancel-safe: a
    /// superseded task's `Task.sleep` throws `CancellationError`, which the `try?` swallows before any
    /// write. A no-op until `savingEnabled` (set after the init reconcile) and when no `persistence`
    /// is configured (the fake/test seam never touches disk).
    ///
    /// BUG-D / F5 — the supersession re-check AND the atomic write happen together inside ONE
    /// `await MainActor.run` (see the body), never releasing the actor between the guard and the rename.
    /// `Task.cancel()` does not interrupt a task already PAST its sleep, so without this single critical
    /// section a debounced write could race `saveImmediately()` (or a newer debounced write) and let a
    /// stale snapshot win the last atomic rename. Deciding supersession AND writing on the main actor —
    /// where every `saveGeneration` bump and `saveImmediately()`'s own write happen — serializes the
    /// renames so `saveImmediately()` (which bumps the generation under cancel) reliably wins: any
    /// in-flight debounced task whose generation no longer matches simply returns without writing.
    private func scheduleSave() {
        guard savingEnabled, let persistence else { return }
        saveTask?.cancel()
        // Snapshot the (Sendable, value-typed) workspace now so the write reflects this mutation.
        let snapshot = workspace
        let debounce = saveDebounce
        saveGeneration &+= 1
        let generation = saveGeneration
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return   // superseded by a newer mutation (cancelled) — that one will write.
            }
            // BUG-D / F5 — the supersession re-check AND the atomic write are ONE main-actor critical
            // section: re-check `saveGeneration` and, only if still current, write the snapshot — all
            // inside a single `await MainActor.run` that never releases the actor between the guard and
            // the rename. This matches `saveImmediately()` (which also writes on the main actor under a
            // bumped generation), so the two RENAMES serialize on the main actor and a stale snapshot's
            // rename can never interleave between a newer write's guard and rename. `Task.cancel()`
            // cannot stop a task already past its sleep, so the generation guard — decided on the actor
            // where every `saveGeneration` mutation happens — is what makes `saveImmediately()` / a newer
            // debounced write reliably win. Encoding the small layout tree on the main actor is
            // acceptable; the clear of the (now-current) handle happens in the same block.
            await MainActor.run { [weak self] in
                guard let self, self.isCurrentSaveGeneration(generation) else { return }
                // A failed save keeps the previous good file (best-effort).
                try? persistence.save(snapshot)
                self.saveTask = nil
            }
        }
    }

    /// Writes `workspace` synchronously NOW (the scenePhase-background path — docs/22 §6), cancelling
    /// any in-flight debounced save first so the two never race. Best-effort: a thrown error is
    /// swallowed (the previous good file is kept). A no-op when no `persistence` is configured.
    public func saveImmediately() {
        guard let persistence else { return }
        // Bump the generation so any in-flight (already-past-sleep) debounced task reliably loses the
        // trailing-clear guard and cannot resurrect/nil the handle after this explicit save.
        saveGeneration &+= 1
        saveTask?.cancel()
        saveTask = nil
        try? persistence.save(workspace)
    }

    // MARK: - Tree lookups

    /// The spec for leaf `id` across all tabs, or `nil`.
    private func spec(for id: PaneID) -> PaneSpec? {
        for tab in workspace.tabs {
            if let spec = tab.root.spec(for: id) { return spec }
        }
        return nil
    }

    /// The id of the tab whose root contains leaf `id`, or `nil`.
    private func tabID(owning id: PaneID) -> TabID? {
        workspace.tabs.first { $0.root.contains(id) }?.id
    }

    /// A neighbour to refocus on after closing `id`, resolved geometrically against the last solved
    /// layout if available, else the pre-order predecessor/successor in the tab. Best-effort.
    private func neighbourForRefocus(of id: PaneID, inTab tabID: TabID) -> PaneID? {
        if let solved = lastSolvedLayout, solved.frames[id] != nil {
            // Prefer a real geometric neighbour (right, then left, then any reading-order sibling).
            for dir in [FocusDirection.right, .left, .down, .up] {
                if let n = FocusResolver.neighbor(of: id, dir, in: solved), n != id { return n }
            }
        }
        guard let tab = workspace.tabs.first(where: { $0.id == tabID }) else { return nil }
        let leaves = tab.root.allLeafIDs()
        guard let i = leaves.firstIndex(of: id) else { return nil }
        if i + 1 < leaves.count { return leaves[i + 1] }
        if i - 1 >= 0 { return leaves[i - 1] }
        return nil
    }

    // MARK: - Titles

    private func defaultTitle(for kind: PaneKind) -> String {
        switch kind {
        case .terminal:   return "Terminal"
        case .claudeCode: return "Claude Code"
        case .remoteGUI:  return "Remote window"
        }
    }
}

// MARK: - Production session factory

public extension WorkspaceStore {
    /// The production `makeSession` factory: wires ``LivePaneSession`` with the threaded `makeClient`
    /// and an inspector builder. The app passes `WorkspaceStore.liveMakeSession(...)` as `makeSession`
    /// so tests can substitute `{ FakePaneSession($0) }` instead (docs/22 §0).
    ///
    /// - Parameters:
    ///   - makeClient: the `@Sendable () -> RworkClient` the proven `ConnectionViewModel` uses.
    ///   - makeInspector: builds the read-only `InspectorClient` for a `.claudeCode` endpoint, or
    ///     `nil` when no second channel is available (e.g. the descriptor cannot be built headless).
    ///     Defaults to ``liveMakeInspector(_:)`` — a lazily-connecting NWConnection #2 client (see
    ///     that function for the unproven-host guardrail).
    static func liveMakeSession(
        makeClient: @escaping @Sendable () -> RworkClient = { RworkClient() },
        makeInspector: @escaping @MainActor (Endpoint) -> InspectorClient? = liveMakeInspector
    ) -> @MainActor (PaneSpec) -> any PaneSessionHandle {
        { spec in
            LivePaneSession.make(spec, makeClient: makeClient, makeInspector: makeInspector)
        }
    }

    /// The wire-protocol convention for a pane's inspector second channel (docs/16, docs/20 §0): the
    /// inspector's NWConnection #2 rides the **same NetBird tunnel** beside the terminal PTY, on the
    /// terminal port **+ 1**. Documented + isolated here so it is the single place to revise if the
    /// host ever advertises a distinct inspector port. Saturates at `UInt16.max` (a terminal on the
    /// top port has no room above it — the inspector is then unavailable, handled by the `nil` path).
    static let inspectorPortOffset: UInt16 = 1

    /// The inspector port for a terminal ``Endpoint`` (the `+ inspectorPortOffset` convention above),
    /// or `nil` when there is no room above the terminal port.
    static func inspectorPort(for endpoint: Endpoint) -> UInt16? {
        let (sum, overflow) = endpoint.port.addingReportingOverflow(inspectorPortOffset)
        return overflow ? nil : sum
    }

    /// Builds the production read-only ``InspectorClient`` for a `.claudeCode` pane's `endpoint`.
    ///
    /// ### Guardrail (docs/22 §7 + the WF5 brief): the LIVE network inspector path is NOT runtime-proven
    /// The terminal byte-pipeline (PATH 1) is proven; the structured inspector second channel
    /// (NWConnection #2) is wired here cleanly but **no host-side inspector serving / port is
    /// established yet** — there is no `rwork-hostd` inspector daemon to invent. So this returns a
    /// *ready, lazily-connecting* client rather than eagerly dialing: it stands up an
    /// ``NWByteChannel`` over a fresh `NWConnection` to `host:inspectorPort` (the
    /// ``inspectorPort(for:)`` convention) but does NOT `start()` it here — the channel connects on the
    /// first `send`/`subscribe`, which is driven by ``LivePaneSession/subscribeInspector()`` (the
    /// leaf's `.task` on appear, WF5). Against a host that does not yet serve the inspector port the
    /// connection simply never completes its handshake and the fold yields no cards — the terminal is
    /// unaffected. The FOLD logic itself is fully unit-testable in-process via
    /// `LoopbackByteChannel.pair()` + ``InspectorClient/init(channel:)`` (docs/22 §8), independent of
    /// this network builder. Real-network inspector serving is recorded as a hardware followup.
    ///
    /// Returns `nil` only when no inspector port can be derived (terminal on the top port).
    @MainActor
    static func liveMakeInspector(_ endpoint: Endpoint) -> InspectorClient? {
        guard let port = inspectorPort(for: endpoint),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: nwPort,
            using: NWByteChannel.parameters()
        )
        // The channel connects lazily: NWByteChannel.start() is idempotent and is triggered by the
        // first send (the `subscribe(fromSeq:)` in LivePaneSession.subscribeInspector). We do not
        // start it here so an idle / never-appeared claudeCode pane opens no socket.
        let channel = NWByteChannel(connection: connection)
        return InspectorClient(channel: channel)
    }
}

// MARK: - Command application (WF2 deferral, completed here)

/// Dispatches a pure ``WorkspaceCommand`` to the matching store mutation (docs/22 §5). Deferred from
/// WF2 (the store did not exist yet); completed here now that it does. The keyboard layer (macOS
/// `Commands`, iPad `UIKeyCommand`) and the compact on-screen affordances all funnel intent through
/// this one free function, keeping the chord → command → mutation chain in one auditable place.
///
/// Commands that act on "the focused pane" / "the active tab" read those from the store's current
/// `workspace.activeTab`; a command with no valid target (no active tab / no focused pane) is a
/// graceful no-op.
@MainActor
public func apply(_ command: WorkspaceCommand, to store: WorkspaceStore) {
    switch command {
    case .splitHorizontal:
        if let pane = store.activeTab?.focusedPane {
            store.split(pane, axis: .horizontal, kind: .terminal)
        }
    case .splitVertical:
        if let pane = store.activeTab?.focusedPane {
            store.split(pane, axis: .vertical, kind: .terminal)
        }
    case .closePane:
        if let pane = store.activeTab?.focusedPane {
            store.closePane(pane)
        }
    case .closeTab:
        if let tab = store.activeTab {
            store.closeTab(tab.id)
        }
    case .newTab:
        store.addTab(kind: .terminal)
    case .nextTab:
        store.selectAdjacentTab(forward: true)
    case .prevTab:
        store.selectAdjacentTab(forward: false)
    case let .selectTab(position):
        store.selectTab(atPosition: position)
    case let .focus(direction):
        store.move(direction)
    case let .cycleFocus(forward):
        store.move(forward ? .next : .previous)
    case .toggleZoom:
        store.toggleZoom()
    case .renameTab:
        // The rename itself is a UI affordance (an inline text field); the command only marks intent.
        // The store exposes `renameTab(_:_:)` for the committed value; there is nothing to do here
        // until the field commits, so this is a deliberate no-op at the command layer.
        break
    }
}

// MARK: - Command helpers (adjacent / positional tab selection)

public extension WorkspaceStore {
    /// Activates the next/previous tab with wrap (⌃⇥ / ⌃⇧⇥). Leaf set unchanged.
    func selectAdjacentTab(forward: Bool) {
        let next = workspace.selectingAdjacent(forward: forward)
        guard next.activeTabID != workspace.activeTabID, let id = next.activeTabID else { return }
        selectTab(id)
    }

    /// Selects the tab at the 1-based menu position (⌘1…⌘9; ⌘9 = last). No-op if out of range.
    func selectTab(atPosition position: Int) {
        let next = workspace.selecting(position: position)
        guard let id = next.activeTabID else { return }
        selectTab(id)
    }
}
