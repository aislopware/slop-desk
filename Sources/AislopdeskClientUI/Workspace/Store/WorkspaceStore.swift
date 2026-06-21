import AislopdeskAgentDetect
import AislopdeskClient
import AislopdeskInspector
import AislopdeskTransport
import CoreGraphics
import Foundation
import Network

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
/// Sessions are built through the injected `makeSession` factory — NOT a fake `AislopdeskClient` (which is
/// impossible) and NEVER a real `HostServer` (forbidden, pool deadlock). Tests inject a
/// `FakePaneSession`; production injects ``LivePaneSession/make(_:makeClient:makeInspector:)``.
@preconcurrency
@MainActor
@Observable
public final class WorkspaceStore {
    // MARK: Live model (W5 — which tree of intent drives the live loop)

    /// W5 (docs/42 §"W5 — IDE shell CUTOVER"): which model is the LIVE source of truth — the one `init`
    /// reconciles, the one a debounced save persists, the one the views bind. The cutover flips the app
    /// to ``tree``; the retained-but-dead canvas tests keep ``canvas`` so they are byte-identical.
    public enum LiveModel: Sendable, Equatable {
        /// The retained-but-dead infinite ``Canvas`` path: `init` reconciles `workspace`, a save persists
        /// `workspace`. The DEFAULT so every pre-cutover test (the canvas `WorkspaceStoreReconcileTests`
        /// + the dormant-tree `WorkspaceStoreTreeReconcileTests`) is unchanged.
        case canvas
        /// The LIVE IDE-shell path: `init` reconciles ``tree``, a save persists ``tree``, and the
        /// `SplitWorkspaceView` shell binds it. The production app passes this.
        case tree
    }

    /// Which model drives the live loop (W5). Default ``LiveModel/canvas`` keeps the retained-but-dead
    /// canvas path and every existing test untouched; the app constructs with ``LiveModel/tree``.
    public let liveModel: LiveModel

    // MARK: State

    /// The pure tree of intent — the single source of truth. `private(set)`: only the mutation
    /// methods change it (each then reconciles), so the registry can never drift from the tree.
    public private(set) var workspace: Workspace

    /// W4 (docs/42 §"W4 — Store retarget"): the **DORMANT** tree-of-intent the store gains alongside the
    /// live canvas `workspace`. The `Session → Tab → Pane` split-tree replacement (``TreeWorkspace``). It
    /// is mutated by the tree-mutation methods below (each delegating to ``WorkspaceTreeOps`` then calling
    /// ``reconcileTree()``), but it is NOT the live path yet: `init` does NOT reconcile it, and the live
    /// update loop keeps using the canvas `reconcile()` (the still-canvas Views bind `workspace`). The W5
    /// cutover promotes it to the live source of truth and retires the canvas. `private(set)`: only the
    /// tree-mutation methods change it (each then `reconcileTree()`s), so the registry can never drift.
    public private(set) var tree: TreeWorkspace

    /// The table of liveness: 1:1 with the leaves of `workspace` on the live canvas path (and 1:1 with
    /// ``tree``'s leaves on the dormant tree path — both paths diff the SAME registry, but only one drives
    /// a given store: the live app uses the canvas `reconcile()`, the W4 tests drive ``reconcileTree()``).
    private var registry: [PaneID: any PaneSessionHandle] = [:]

    /// The injection seam (docs/22 §0). Spec-only — the store re-points the built handle at the leaf
    /// id via `adopt(id:)` (see ``PaneSessionIDAdopting``).
    private let makeSession: @MainActor (PaneSpec) -> any PaneSessionHandle

    /// Maximum number of `.remoteGUI` panes that may hold a LIVE video stack at once (docs/22 §7 the
    /// 2N-UDP / N-VTDecompression / N-CVDisplayLink ceiling). Injectable; default 2. The app now resolves
    /// it per device class via ``VideoCapPolicy`` (phone 1 / pad 2 / mac 3, ITEM #5); the store keeps the
    /// plain `Int` shape and is agnostic to how the number was chosen.
    ///
    /// ### UDP-mux interaction — cap is intentionally per-pane
    /// Same-host video panes SHARE one UDP flow (2 sockets/host instead of 2N), but each pane STILL owns
    /// its own `VTDecompressionSession` + `CVDisplayLink` + Metal renderer — those are NOT shared, only
    /// the UDP socket is. The dominant, scarce resources the cap exists to bound (decode + composite, the
    /// "N-VTDecompression / N-CVDisplayLink" part of the ceiling) remain strictly per-pane, so the
    /// per-pane cap stays CORRECT (it can never under-count live decoders). The only term that weakens
    /// under mux is "2N-UDP" → "2-per-host", which only makes the cap more conservative, never wrong. So
    /// the cap is kept per-pane (a per-host socket count would loosen admission for no decode/composite
    /// headroom gain).
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

    /// The pane whose sidebar row should open its inline rename field — set by the ⌘R / menu /
    /// palette "Rename" entry points, CONSUMED by the sidebar (``clearRenameRequest()``) once the
    /// field is open. A pending ID rather than a counter nudge: when the sidebar column is collapsed
    /// (the old ⌘R-silent-no-op), the root view observes this to REVEAL the column first, and the
    /// just-mounted sidebar acts on the still-pending value — a fired-and-missed counter could not
    /// be replayed safely.
    public private(set) var pendingRename: PaneID?

    /// Requests the sidebar open the inline rename on the focused pane (the command-layer entry point
    /// for "Rename"). No-op when no pane is focused. See ``pendingRename``.
    public func requestRenameFocusedPane() {
        guard let focused = workspace.focusedPane else { return }
        pendingRename = focused
    }

    /// The TAB whose strip pill should open its inline rename field — set by the ⌘⇧R / menu "Rename Tab"
    /// entry point on the LIVE tree shell, CONSUMED by ``TabBarView`` (``clearTabRenameRequest()``) once
    /// the field is open. A pending ID (mirrors ``pendingRename``) so a not-yet-mounted tab strip acts on
    /// the still-pending value rather than a fired-and-missed counter.
    public private(set) var pendingTabRename: TabID?

    /// Requests the inline rename on the ACTIVE entity in whichever live model is current (W6, ITEM B1):
    /// under ``LiveModel/tree`` the ⌘⇧R chord renames the active TAB (the tabs model + the existing
    /// ``TabBarView`` inline-rename field, set via ``pendingTabRename``); under ``LiveModel/canvas`` it
    /// keeps the sidebar pane rename (``pendingRename``, the field the `PaneSidebarView` row opens). No-op
    /// without an active tab / pane. This is the command-layer "Rename" entry the binding registry routes to.
    public func requestRenameActivePane() {
        switch liveModel {
        case .tree:
            guard let tabID = tree.activeSession?.activeTab?.id else { return }
            pendingTabRename = tabID
        case .canvas:
            requestRenameFocusedPane()
        }
    }

    /// The sidebar consumed the rename request (its inline field is open) — or the request became
    /// moot (pane gone).
    public func clearRenameRequest() {
        pendingRename = nil
    }

    /// The tab strip consumed the tab-rename request (its inline field is open) — or it became moot.
    public func clearTabRenameRequest() {
        pendingTabRename = nil
    }

    /// Where the value tree is persisted (docs/22 §6). Injectable so tests point at a temp dir and a
    /// store built with `nil` persistence (the default for the FakePaneSession test seam) never
    /// touches disk. The app passes a real ``WorkspacePersistence``.
    private let persistence: WorkspacePersistence?

    /// How long to coalesce a burst of mutations before writing the tree (docs/22 §6 "debounced on
    /// mutation"). One write per quiet period, not one per keystroke-driven split/resize.
    private let saveDebounce: Duration

    /// FIX #4: how long to let a closed `.remoteGUI` pane's video stack ACTUALLY release before the
    /// store frees its ``liveVideoCap`` slot. `teardown()` for a `.remoteGUI` pane sets
    /// `RemoteWindowModel.active = nil`, which only triggers the SwiftUI dismantle of the
    /// `VideoWindowView` → `VideoWindowPipeline.deactivate()` → a detached `session.stop()` that
    /// closes the two UDP `NWConnection`s + `VTDecompressionSession` + display link. That real
    /// release completes a few runloop turns AFTER `teardown()` returns, so freeing the slot the
    /// instant `teardown()` returns can transiently admit a sibling while the old stack is still up
    /// (cap+1 — no crash/leak, just a momentary over-commit). The pipeline now runs `stop()` as one
    /// ordered task (`VideoWindowPipeline.awaitStopped()`), but it lives inside the SwiftUI-owned
    /// AppKit view and is not reachable from the store for a direct `await`; so the store holds the
    /// slot for this bounded settle past `teardown()` to cover the dismantle→stop lag. Injectable so
    /// a test can set it to `.zero` for deterministic, sleep-free assertions. DEFAULT `.zero` = the
    /// old free-immediately behaviour, so EVERY existing test + the OFF/terminal-only paths are
    /// byte-identical (they never enter this gate); the PRODUCTION app opts in with a small window
    /// (``AislopdeskClientApp``). [MS-confirm] the real dismantle→stop lag on hardware.
    private let videoTeardownSettle: Duration

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

    /// The full `SplitTreeView` container bounds (origin .zero, `geo.size`) the active tab last reported via
    /// ``updateFloatingBounds(_:)`` — the TRUE float viewport. The render model (`SplitTreeView`) clamps a
    /// float's placement against this same rect, so the store's commit-clamp and the view's place-clamp
    /// share one coordinate space (no edge-discrepancy from the leaf-union approximation). `nil` until the
    /// view reports one → ``floatingViewportBounds`` falls back to the leaf-union, then a sane default.
    private var lastFloatingBounds: CGRect?

    /// The last viewport size the canvas view reported (docs/30 §5.3). Used by new-pane placement, the
    /// in-view guarantee, and the centre/tidy camera ops so the store can position panes without the
    /// view passing a size into every mutation. A nominal desktop default until the view reports one.
    private var lastViewport: CGSize = .init(width: 1280, height: 800)

    /// The set of pane ids the canvas view currently reports as INSIDE the viewport (no margin). Pure
    /// view-derived state; never reconciles. Drives ``isPaneVisible(_:)`` (the video-cap "on screen"
    /// signal).
    private var paneIDsInViewport: Set<PaneID> = []

    /// Whether the canvas view has reported viewport membership at least once since it last appeared.
    /// Distinguishes "no report yet" (compact carousel / pre-first-layout → fall back to
    /// ``isPaneOnActiveTab(_:)``) from "reported, and it is genuinely empty" (panned into the void →
    /// nothing is visible, so an off-screen video pane SHOULD release its slot). Reset by
    /// ``clearViewportMembership()`` when the canvas disappears (a regular→compact flip) so the compact
    /// path falls back correctly instead of inheriting a stale set.
    private var hasReportedViewport = false

    /// VISUAL-ONLY live scroll-pan offset (screen-space) — the scroll counterpart of ``CanvasView``'s
    /// `livePan` @State for a background DRAG. A trackpad/wheel scroll, over the empty background OR over a
    /// pane (via ``scrollPan(by:)``), accumulates here and the camera is committed ONCE, ~110 ms after the
    /// scroll settles (``commitScrollPan()``). THIS IS THE BUG-2/BUG-1 FREEZE FIX (2026-06-08, proven
    /// on-device): the old path called ``commitCamera(_:)`` on EVERY scroll step, and each call mutates
    /// `workspace.canvas` → fires the `.onChange(of: canvas)` → `report()` cascade (viewport / membership /
    /// solved-layout writes) → a full-canvas SwiftUI re-render that BLOCKS the main thread, starving the
    /// Metal video render + cursor overlay (all measured freeze gaps were main-actor; cursor RX was clean).
    /// Accumulating here touches ONLY ``CanvasView`` (panes diff unchanged, NO `report()`), so the pan
    /// stays smooth and the stream never freezes. Not persisted; folded into the real camera on commit with
    /// NO visual jump (the committed offset equals the live offset).
    public private(set) var liveCameraOffset: CGSize = .zero
    /// Debounce handle: cancelled + rescheduled on each ``scrollPan(by:)`` so the single commit fires only
    /// after the scroll (incl. trackpad momentum) settles.
    private var scrollCommitTask: Task<Void, Never>?

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
    ///   - restoringTree: a decoded ``TreeWorkspace`` to seed the tree path. `nil` ⇒
    ///     ``TreeWorkspace/defaultWorkspace()`` (one terminal pane). With ``LiveModel/canvas`` (the
    ///     default) the tree stays DORMANT (init reconciles the canvas, so seeding it is behavior-neutral);
    ///     with ``LiveModel/tree`` (the app, W5 cutover) the tree IS the live source — init reconciles it.
    ///   - liveModel: which model drives the live loop (W5). Default ``LiveModel/canvas`` keeps every
    ///     pre-cutover test untouched; the production app passes ``LiveModel/tree``.
    ///   - makeSession: the session factory seam (production: `LivePaneSession.make`; tests:
    ///     `{ FakePaneSession($0) }`).
    ///   - liveVideoCap: concurrent live-video ceiling (default 2).
    ///   - persistence: where to debounce-save the live model after mutations (docs/22 §6). `nil` (the
    ///     default) ⇒ no disk writes, so the pure/fake test seam never touches the filesystem; the app
    ///     passes a real ``WorkspacePersistence``.
    ///   - saveDebounce: the mutation-coalescing window before a write (default 600ms).
    @preconcurrency
    public init(
        restoring: Workspace? = nil,
        restoringTree: TreeWorkspace? = nil,
        liveModel: LiveModel = .canvas,
        makeSession: @escaping @MainActor (PaneSpec) -> any PaneSessionHandle,
        liveVideoCap: Int = 2,
        persistence: WorkspacePersistence? = nil,
        saveDebounce: Duration = .milliseconds(600),
        videoTeardownSettle: Duration = .zero,
    ) {
        self.liveModel = liveModel
        workspace = restoring ?? .defaultWorkspace()
        tree = (restoringTree ?? .defaultWorkspace()).normalized()
        self.makeSession = makeSession
        self.liveVideoCap = liveVideoCap
        self.persistence = persistence
        self.saveDebounce = saveDebounce
        self.videoTeardownSettle = videoTeardownSettle
        // W5: the live model picks the init reconcile. `.canvas` (default) materializes the canvas panes
        // (the retained-but-dead path + every existing test); `.tree` (the app) materializes the tree's
        // leaves through the SAME registry diff — exactly one of the two trees ever drives a given store.
        switch liveModel {
        case .canvas: reconcile()
        case .tree: reconcileTree()
        }
        savingEnabled = true // arm debounced saves only AFTER the restore reconcile
    }

    // MARK: - Accessors

    /// The live handle for `id`, or `nil` if no such leaf is materialized.
    public func handle(for id: PaneID) -> (any PaneSessionHandle)? { registry[id] }

    /// All live sessions (registry values). Order is unspecified — callers that need a stable order
    /// derive it from the tree's `allLeafIDs()`.
    public var allSessions: [any PaneSessionHandle] { Array(registry.values) }

    /// The focused pane id, or `nil` when the canvas is empty (a pure passthrough).
    public var focusedPane: PaneID? { workspace.focusedPane }

    /// Whether `id` is the focused pane (the view's focus-ring decision).
    public func isFocused(_ id: PaneID) -> Bool { workspace.focusedPane == id }

    /// Whether `id` is a pane on the single canvas — i.e. genuinely on-screen (all panes live on the
    /// one always-mounted canvas now). A reliable visibility signal for the video teardown decision,
    /// unlike SwiftUI's `.onDisappear`, which fires spuriously during the initial NavigationSplitView
    /// layout settle even though the pane stays on screen (the autoconnect connect bug). The debounced
    /// teardown re-checks this so a spurious disappear (pane still on the canvas) is ignored.
    public func isPaneOnCanvas(_ id: PaneID) -> Bool { workspace.canvas.contains(id) }

    /// All pane ids on the canvas (the reconcile diff domain), in canonical z-order.
    private func allLeafIDs() -> [PaneID] {
        workspace.canvas.allIDs()
    }

    // MARK: - Layout reporting (for geometric focus move)

    /// The view reports the layout it just solved for the active tab so the store can resolve
    /// geometric focus moves (``move(_:)``) against the exact rects the user sees (docs/22 §2.1).
    /// View-only state — does NOT touch the tree or registry, so reporting it never reconciles.
    public func updateSolvedLayout(_ solved: SolvedLayout) {
        lastSolvedLayout = solved
    }

    /// The active-tab `SplitTreeView` reports its FULL container bounds (origin .zero, `geo.size`) so the
    /// floating layer's commit-clamp matches the view's place-clamp exactly (the float coordinate space).
    /// View-only state — never touches the tree, so reporting it never reconciles.
    public func updateFloatingBounds(_ bounds: CGRect) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        lastFloatingBounds = bounds
    }

    // MARK: - Group mutations (pure op → reconcile; groups are metadata, so reconcile only persists)

    /// Creates a new empty group named `name`, returning its id so the caller can immediately assign
    /// panes. Groups are pure sidebar/box metadata — the leaf set is unchanged, so reconcile is a
    /// registry no-op (it only persists).
    @discardableResult
    public func addGroup(name: String) -> PaneGroupID {
        let (next, id) = workspace.addingGroup(name: name)
        workspace = next
        reconcile()
        return id
    }

    /// Renames group `id`. No-op if absent.
    public func renameGroup(_ id: PaneGroupID, _ name: String) {
        workspace = workspace.renamingGroup(id, to: name)
        reconcile()
    }

    /// Deletes group `id`: its member panes survive as UNGROUPED (a group is metadata — deleting it
    /// never closes a pane).
    public func removeGroup(_ id: PaneGroupID) {
        workspace = workspace.removingGroup(id)
        reconcile()
    }

    /// Assigns pane `paneID` to group `groupID` (or ungroups it when `groupID` is `nil`). Disjoint:
    /// a pane is in at most one group, so this MOVES it between groups.
    public func assignPane(_ paneID: PaneID, toGroup groupID: PaneGroupID?) {
        workspace = workspace.assigning(pane: paneID, toGroup: groupID)
        reconcile()
    }

    /// Turns the current multi-selection into a NEW group in one mutation — the "Group Selected Panes"
    /// action (⌥⌘G, and ⌃⌘G when ≥1 pane is selected). Until this existed the only group-creation path
    /// made an EMPTY group (no bounding box, invisible on the canvas), so grouping N panes meant
    /// create-empty + Move-to-Group N times. Members are assigned in deterministic canvas order; the
    /// transient pane-selection is cleared (the panes now read as a group). Returns the new group id, or
    /// `nil` when nothing is selected (a no-op — the caller falls back to an empty group if it wants one).
    @discardableResult
    public func groupSelection(name: String = "Group") -> PaneGroupID? {
        let ids = workspace.canvas.allIDs().filter { selectedPanes.contains($0) }
        guard !ids.isEmpty else { return nil }
        var next = workspace
        let (afterAdd, gid) = next.addingGroup(name: name)
        next = afterAdd
        for id in ids { next = next.assigning(pane: id, toGroup: gid) }
        workspace = next
        clearSelection()
        reconcile()
        return gid
    }

    /// Reorders groups (sidebar `onMove`). Pure reorder; leaf set unchanged.
    public func moveGroup(from source: IndexSet, to destination: Int) {
        workspace = workspace.movingGroup(from: source, to: destination)
        reconcile()
    }

    // MARK: - Pane mutations (pure op → reconcile)

    /// Adds a new pane of `kind` to the canvas, placed near (cascaded off) the focused pane — or, when
    /// `group` is given, near that group's panes so it lands inside the cluster — then focuses + raises
    /// it, assigns it to `group` (if any), and guarantees it is in view. Reconcile materializes the one
    /// new session.
    ///
    /// All terminal/Claude panes open a channel on the ONE app-global connection (docs/31), so a new
    /// pane carries no per-pane endpoint — it just rides the app target. A `.remoteGUI` pane is created
    /// without a window yet (the user picks one in the pane).
    public func addPane(kind: PaneKind, inGroup group: PaneGroupID? = nil) {
        let newSpec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        let viewport = lastViewport
        // Cascade off the group's last pane when adding into a group (so it appears within the cluster),
        // else off the focused pane.
        let near = group.flatMap { workspace.canvas.ids(inGroup: $0).last } ?? workspace.focusedPane
        let (canvas, id) = workspace.canvas.adding(newSpec, near: near, viewport: viewport)
        workspace.canvas = canvas
        focusOnPlacement(id)
        // A new pane exits any maximize (the canvas layout changed).
        if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
        if let group { workspace.canvas = workspace.canvas.assigning(id, toGroup: group) }
        // In-view guarantee: a new pane that lands off (or barely clipping) the current viewport would be
        // invisible — pan the camera to centre it unless its CENTRE is already inside the viewport.
        recenterIfOffscreen(id, viewport: viewport)
        reconcile()
    }

    /// Adds a `.remoteGUI` pane PRE-BOUND to host window `windowID` (the ⌘K palette host-window result):
    /// the spec carries the video endpoint, so the pane streams immediately — skipping the
    /// create-then-pick two-step. Placed/focused/in-view exactly like ``addPane(kind:inGroup:)``; the
    /// video cap is still enforced at activation (the pane shows the gated placeholder if saturated).
    /// Returns the new pane id.
    @discardableResult
    public func addRemoteWindowPane(windowID: UInt32, title: String, appName: String) -> PaneID {
        let label = title.isEmpty ? (appName.isEmpty ? "Remote window" : appName) : title
        let spec = PaneSpec(
            kind: .remoteGUI,
            title: label,
            video: VideoEndpoint(windowID: windowID, title: label, appName: appName),
        )
        let viewport = lastViewport
        let (canvas, id) = workspace.canvas.adding(spec, near: workspace.focusedPane, viewport: viewport)
        workspace.canvas = canvas
        focusOnPlacement(id)
        if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
        recenterIfOffscreen(id, viewport: viewport)
        reconcile()
        return id
    }

    /// Closes pane `id`. Focus re-points to a surviving neighbour; closing the LAST pane leaves an empty
    /// canvas (the "Add a pane" empty state). Reconcile tears down the removed session.
    public func closePane(_ id: PaneID) {
        guard workspace.canvas.contains(id) else { return }
        // Record the close for "Reopen Closed Pane" — spec + exact frame + group, but NOT the id (a
        // reopen mints a fresh pane; the session is necessarily new). Ephemeral auto-managed panes
        // (system dialogs) are skipped: the monitor owns their lifecycle, so "reopening" one would
        // resurrect a dead window stream.
        if let item = workspace.canvas.item(id), !item.spec.kind.isEphemeral {
            recentlyClosed = RecentlyClosedPane(spec: item.spec, frame: item.frame, group: item.groupID)
        }
        if pendingClose == id { pendingClose = nil }
        pruneFocusHistory(id) // a closed pane must never be a quick-switch target
        // Capture a geometric neighbour BEFORE the close (so refocus follows what the user saw).
        let refocus = neighbourForRefocus(of: id)
        if let newCanvas = workspace.canvas.removing(id) {
            workspace.canvas = newCanvas
            if workspace.focusedPane == id {
                workspace.focusedPane = refocus ?? newCanvas.allIDs().first
            }
        } else {
            // Removed the last pane → empty canvas, no focus (keep the camera so a re-add lands in place).
            workspace.canvas = Canvas(items: [], camera: workspace.canvas.camera)
            workspace.focusedPane = nil
        }
        if workspace.maximizedPane == id { workspace.maximizedPane = nil }
        reconcile()
    }

    /// Duplicates pane `id`: a NEW pane with a COPY of its spec — title, kind, and a committed video
    /// endpoint all come along, so duplicating a bound remote-window pane yields a second pane
    /// pre-bound to the same host window (admission still flows through ``liveVideoCap`` at
    /// activation) — cascaded beside the original at the SAME size, in the same group, focused.
    /// Ephemeral (auto-managed) panes don't duplicate. Returns the new id.
    @discardableResult
    public func duplicatePane(_ id: PaneID) -> PaneID? {
        guard let item = workspace.canvas.item(id), !item.spec.kind.isEphemeral else { return nil }
        let (canvas, newID) = workspace.canvas.adding(
            item.spec, near: id, viewport: lastViewport, size: item.frame.size,
        )
        workspace.canvas = canvas
        focusOnPlacement(newID)
        if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
        if let group = item.groupID {
            workspace.canvas = workspace.canvas.assigning(newID, toGroup: group)
        }
        // In-view guarantee, mirroring addPane.
        recenterIfOffscreen(newID, viewport: lastViewport)
        reconcile()
        return newID
    }

    // MARK: - Close undo (single slot) + busy-shell close guard

    /// Everything needed to bring the most recently closed pane back as it was: its spec (incl. a
    /// committed video endpoint, so a reopened remote-window pane re-streams), its exact frame, and
    /// its group. Deliberately NOT the ``PaneID`` — reopen mints a fresh pane (see
    /// ``Canvas/restoring(_:frame:group:)``).
    public struct RecentlyClosedPane: Equatable, Sendable {
        public let spec: PaneSpec
        public let frame: CGRect
        public let group: PaneGroupID?
    }

    /// The single-slot "Reopen Closed Pane" record — the last non-ephemeral close. In-memory only
    /// (deliberately not persisted: across a relaunch the layout file already restores every pane
    /// that mattered). Single-slot is the honest scope: the menu item says "Reopen Closed Pane",
    /// not "Undo History".
    public private(set) var recentlyClosed: RecentlyClosedPane?

    /// The pane awaiting close CONFIRMATION because its shell reported a running command (⌘W on a
    /// busy shell — killing the session would kill the command). The view observes this and shows a
    /// confirmation dialog; ``confirmPendingClose()`` / ``cancelPendingClose()`` resolve it.
    public private(set) var pendingClose: PaneID?

    /// The close entry point for every user-facing close affordance (⌘W, the pill menu, the sidebar
    /// context menu): closes immediately when the pane's shell is idle, parks the close behind a
    /// confirmation (``pendingClose``) when ``PaneSessionHandle/isShellBusy`` says a command is still
    /// running. Direct ``closePane(_:)`` stays public for the auto-managed paths (the system-dialog
    /// monitor) and tests — the guard is a UX gate, not an invariant.
    public func requestClosePane(_ id: PaneID) {
        guard workspace.canvas.contains(id) else { return }
        if registry[id]?.isShellBusy == true {
            pendingClose = id
        } else {
            closePane(id)
        }
    }

    /// The TREE busy-shell close guard (W5, ITEM A3): the IDE-shell counterpart of ``requestClosePane(_:)``
    /// — an idle leaf closes immediately (cascading the tab/session), a leaf mid-command parks behind the
    /// ``pendingClose`` confirmation. The chrome close button and ⌘W on a SPECIFIC leaf both route through
    /// here so the busy-guard is honoured uniformly (the `closePaneTree(_:)` direct call stays for tests /
    /// the active-pane convenience). No-op if `id` is not a live tree leaf.
    public func requestClosePaneTree(_ id: PaneID) {
        guard tree.contains(id) else { return }
        if registry[id]?.isShellBusy == true {
            pendingClose = id
        } else {
            closePaneTree(id)
        }
    }

    /// Confirms the parked busy-shell close in whichever live model is current (W5, ITEM A1): under
    /// ``LiveModel/tree`` the parked id is a live tree leaf, so it is closed via ``closePaneTree(_:)`` (the
    /// canvas ``closePane(_:)`` would early-return on a tree id, silently dropping the close); under
    /// ``LiveModel/canvas`` it stays the canvas path. No-op when nothing is pending (the pane was already
    /// closed by another path — a close clears a matching `pendingClose`).
    public func confirmPendingClose() {
        guard let id = pendingClose else { return }
        pendingClose = nil
        switch liveModel {
        case .tree: closePaneTree(id)
        case .canvas: closePane(id)
        }
    }

    /// Dismisses the busy-shell close confirmation without closing.
    public func cancelPendingClose() {
        pendingClose = nil
    }

    /// The ``PaneSpec`` of the pane awaiting a busy-close confirmation, resolved from whichever live model
    /// is current (W5, ITEM A1) — the tree's side table under ``LiveModel/tree``, else the canvas. Lets the
    /// confirmation dialog name the leaf it would close on EITHER shell (the old canvas-only lookup showed a
    /// generic title under `.tree`). `nil` when nothing is pending or the pane vanished.
    public var pendingCloseSpec: PaneSpec? {
        guard let id = pendingClose else { return nil }
        switch liveModel {
        case .tree: return tree.spec(for: id)
        case .canvas: return workspace.canvas.spec(for: id)
        }
    }

    /// Reopens the most recently closed pane at its exact former frame (frontmost, focused, back in
    /// its group when that group still exists), guaranteed in view. The session is NEW by
    /// construction — scrollback does not survive a close; the spec (incl. a committed video
    /// endpoint) is what comes back. Single-shot: consumes the slot. Returns the new id, or `nil`
    /// when there is nothing to reopen.
    @discardableResult
    public func reopenClosedPane() -> PaneID? {
        guard let record = recentlyClosed else { return nil }
        recentlyClosed = nil
        // Rejoin the group only if it still exists — restoring a dangling groupID would strand the
        // pane outside both the group views and the "ungrouped" listing.
        let group = record.group.flatMap { gid in
            workspace.groups.contains { $0.id == gid } ? gid : nil
        }
        let (canvas, id) = workspace.canvas.restoring(record.spec, frame: record.frame, group: group)
        workspace.canvas = canvas
        focusOnPlacement(id)
        if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
        // In-view guarantee, mirroring addPane: the pane may have been closed far off-viewport.
        recenterIfOffscreen(id, viewport: lastViewport)
        reconcile()
        return id
    }

    // MARK: - System-dialog panes (ephemeral, auto-managed by the client monitor)

    /// Spawns an EPHEMERAL ``PaneKind/systemDialog`` pane streaming host window `windowID` (a SecurityAgent
    /// login/password prompt etc.) and returns its id so the monitor can ``closePane(_:)`` it when the
    /// dialog goes away. Auto-streams (the spec carries the windowID, so no picker) and is NEVER persisted
    /// (``persistableWorkspace()`` strips it). `isSecure` flags a password/auth dialog — the pane shows a
    /// "view-only — type on the host" hint, the HW-proven truth (synthetic keystrokes are OS-dropped).
    @discardableResult
    public func addSystemDialogPane(windowID: UInt32, owner: String, title: String, isSecure: Bool) -> PaneID {
        let label = title.isEmpty ? owner : "\(owner) — \(title)"
        let spec = PaneSpec(
            kind: .systemDialog,
            title: label,
            video: VideoEndpoint(windowID: windowID, title: label, appName: owner),
        )
        // W5 (ITEM A2): on the LIVE tree shell the canvas is dead, so an ephemeral dialog pane must be
        // inserted into the TREE — a NEW TAB of the active session (the least-disruptive transient shape:
        // a tab the monitor closes again the moment the dialog leaves, without resplitting the user's
        // current layout). The `.canvas` path keeps the old behaviour byte-identical.
        // W5 (ITEM A2): on the LIVE tree shell the canvas is dead, so an ephemeral dialog pane must be
        // inserted into the TREE — a NEW TAB of the active session (the least-disruptive transient shape:
        // a tab the monitor closes again the moment the dialog leaves, without resplitting the user's
        // current layout). The `.canvas` path keeps the old behaviour byte-identical.
        let id: PaneID
        switch liveModel {
        case .tree:
            let (next, newID) = WorkspaceTreeOps.newTab(in: tree, spec: spec)
            tree = next
            id = newID
            reconcileTree()
        case .canvas:
            let viewport = lastViewport
            let (canvas, newID) = workspace.canvas.adding(spec, near: workspace.focusedPane, viewport: viewport)
            workspace.canvas = canvas
            workspace.focusedPane = newID
            id = newID
            // A surfacing prompt exits maximize and is panned into view (it demands attention).
            if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
            recenterIfOffscreen(id, viewport: viewport)
            reconcile()
        }
        // isSecure is a pure-live property (never persisted), so set it on the just-materialized session
        // directly rather than threading it through the Codable spec.
        (registry[id] as? LivePaneSession)?.markSystemDialog(isSecure: isSecure)
        return id
    }

    /// Closes a pane the auto-managed monitor owns (a system-dialog overlay) in whichever live model is
    /// current (W5, ITEM A2): under ``LiveModel/tree`` the leaf lives in the tree (its transient tab is
    /// dropped, cascading), else the canvas close. The monitor calls this directly (it is not subject to
    /// the busy-shell guard — a dialog leaving host-side must always dismiss its pane).
    public func closeSystemDialogPane(_ id: PaneID) {
        switch liveModel {
        case .tree: closePaneTree(id)
        case .canvas: closePane(id)
        }
    }

    /// Whether `id` is a LIVE leaf in whichever model is current (W5, ITEM A2) — the tree under
    /// ``LiveModel/tree``, else the canvas. The auto-managed monitor uses this to detect a manual close
    /// (a spawned pane no longer present) on EITHER shell.
    public func isSystemDialogPaneLive(_ id: PaneID) -> Bool {
        switch liveModel {
        case .tree: tree.contains(id)
        case .canvas: workspace.canvas.contains(id)
        }
    }

    /// Focuses pane `id` (a pure focus change; leaf set unchanged). Maximize follows focus.
    ///
    /// BUG-1 (cursor freezes "khi click vào pane"): a click on a GUI pane runs `mouseDown → onActivate →
    /// focus(id)`. Without the guard below, clicking the ALREADY-focused pane STILL reassigned the whole
    /// `@Observable workspace` (struct assignment notifies regardless of equality) → a full-canvas SwiftUI
    /// re-render that blocks the main thread → the Metal video + cursor overlay freeze for that span on
    /// EVERY click. Re-focusing the pane that is already focused (and already maximized-or-not the same) is
    /// a genuine no-op, so skip it entirely — no reassignment, no re-render, no freeze.
    public func focus(_ id: PaneID) {
        focus(id, recordVisit: true)
    }

    /// Focuses `id`. `recordVisit` distinguishes a USER focus (click / directional move / palette jump —
    /// moves the pane to the front of the focus-history MRU) from a quick-switch WALK
    /// (``switchToRecentPane(forward:)``), which must NOT reorder the ring (browser back/forward).
    private func focus(_ id: PaneID, recordVisit: Bool) {
        guard workspace.focusedPane != id else { return }
        if recordVisit { recordFocusVisit(id) }
        workspace = workspace.focusing(id)
        // Seeing a pane dismisses its attention bell badge (the badge only shows on unfocused panes).
        registry[id]?.clearBell()
        reconcile()
    }

    // MARK: - Recent-pane MRU (quick-switch to the previously-focused pane)

    /// Panes in most-recently-FOCUSED order (front = current), deduped, capped at ``focusHistoryCap``,
    /// pruned when a pane closes. Session state (not persisted). Backs ``switchToRecentPane(forward:)`` —
    /// the "go to last pane" idiom. Mirrors the ``recentCommands`` ring discipline.
    public private(set) var focusHistory: [PaneID] = []
    public static let focusHistoryCap = 16

    /// Records a user focus visit. The pane we're LEAVING is fronted first, THEN the incoming pane — so
    /// "go to last pane" returns to where you actually were, even when a quick-switch walk (which does not
    /// record) had left the focus on the outgoing pane. Dedups + caps. (Also seeds the ring after a
    /// restore, where the outgoing pane was never recorded via a `focus()` call.)
    private func recordFocusVisit(_ id: PaneID) {
        if let outgoing = workspace.focusedPane, outgoing != id { frontFocusHistory(outgoing) }
        frontFocusHistory(id)
        if focusHistory.count > Self.focusHistoryCap {
            focusHistory.removeLast(focusHistory.count - Self.focusHistoryCap)
        }
    }

    private func frontFocusHistory(_ id: PaneID) {
        focusHistory.removeAll { $0 == id }
        focusHistory.insert(id, at: 0)
    }

    /// Makes `id` the focused pane via a CREATION/RAISE path (which set the focus DIRECTLY rather than
    /// through `focus(_:)`, the existing-pane re-render path) AND records the visit in the quick-switch
    /// MRU ring. Without recording here, opening/raising panes never populated `focusHistory`, so
    /// quick-switch (⌥⌘;) stayed dead until the user happened to CLICK between panes (the only `focus()`
    /// caller). Records OUTGOING-then-incoming so "go to last pane" returns to where you actually were.
    /// Ephemeral system-dialog panes deliberately do NOT use this (they must not pollute the ring).
    private func focusOnPlacement(_ id: PaneID) {
        recordFocusVisit(id)
        workspace.focusedPane = id
    }

    /// The pane a quick-switch step would land on, or `nil` when the step is a no-op (fewer than two panes
    /// in the ring, or already at the end in that direction). Pure (no focus side-effect) so the
    /// no-op guard is unit-testable in isolation. Position is DERIVED from the focused pane's index in the
    /// ring each call (no persistent cursor); a focused pane absent from the ring (e.g. just after a
    /// close-refocus) starts the walk at the front.
    func recentPaneTarget(forward: Bool) -> PaneID? {
        guard focusHistory.count > 1 else { return nil }
        let current = workspace.focusedPane.flatMap { focusHistory.firstIndex(of: $0) } ?? 0
        let next = forward ? current - 1 : current + 1
        guard next >= 0, next < focusHistory.count else { return nil }
        return focusHistory[next]
    }

    /// Quick-switch through the focus-history MRU WITHOUT reordering it (browser back/forward): `forward:
    /// false` steps toward an OLDER pane (the "go to the previous pane" primary action), `forward: true`
    /// steps back toward newer. Walks without recording, so a sequence of steps walks the ring. A whole-
    /// canvas swap re-seeds the ring (``reseedFocusHistory()``) so a walk never targets a re-minted id.
    public func switchToRecentPane(forward: Bool) {
        if let target = recentPaneTarget(forward: forward) { focus(target, recordVisit: false) }
    }

    /// Drops `id` from the focus-history MRU (a pane closed) so it can never be a quick-switch target.
    private func pruneFocusHistory(_ id: PaneID) {
        focusHistory.removeAll { $0 == id }
    }

    /// Resets the focus-history MRU to just the current focused pane — for a WHOLE-CANVAS SWAP (layout-
    /// preset switch / replace-import) that re-mints every pane id, leaving every prior ring entry a dead
    /// id. Without this the quick-switch (⌥⌘;) would silently no-op post-swap (every walked-to id fails the
    /// `canvas.contains` guard in `focusing`). Seeding with the new focused pane (not emptying) keeps the
    /// ring honest as the user starts navigating the new layout.
    private func reseedFocusHistory() {
        focusHistory = workspace.focusedPane.map { [$0] } ?? []
    }

    /// Moves focus in `dir`, resolved geometrically against the last solved layout (docs/22 §2.1).
    /// `.next`/`.previous` fall back to the canonical ``Canvas/allIDs()`` cycle when no layout has been
    /// reported yet (e.g. compact mode), so cycling always works.
    public func move(_ dir: FocusDirection) {
        guard let focused = workspace.focusedPane else { return }
        let target: PaneID?
        switch dir {
        case .next,
             .previous:
            if let solved = lastSolvedLayout, solved.frames[focused] != nil {
                target = FocusResolver.neighbor(of: focused, dir, in: solved)
            } else {
                target = FocusResolver.cycle(workspace.canvas.allIDs(), from: focused, forward: dir == .next)
            }
        case .left,
             .right,
             .up,
             .down:
            guard let solved = lastSolvedLayout else { return }
            target = FocusResolver.neighbor(of: focused, dir, in: solved)
        }
        guard let target, target != focused else { return }
        focus(target)
    }

    /// Cycles focus through ONLY the panes in the focused pane's group (the companion to the whole-canvas
    /// ``move(_:)`` cycle), so a cluster is navigable in isolation. An ungrouped focused pane cycles the
    /// ungrouped "bucket" (`groupID == nil`). A no-op when the bucket has fewer than two panes. Members are
    /// taken in the canonical ``Canvas/ids(inGroup:)`` reading order, fed to the same ``FocusResolver/cycle``.
    public func cycleFocusInGroup(forward: Bool) {
        if let target = inGroupCycleTarget(forward: forward) { focus(target) }
    }

    /// The pane an in-group cycle would focus, or `nil` when it is a no-op (no focused pane, or the
    /// focused pane's group/ungrouped-bucket has fewer than two members). Pure so the `count > 1` guard is
    /// unit-testable in isolation (the cycle itself returns the SAME pane for a singleton, so only this
    /// guard distinguishes "cycle" from "stay put").
    func inGroupCycleTarget(forward: Bool) -> PaneID? {
        guard let focused = workspace.focusedPane else { return nil }
        let members = workspace.canvas.ids(inGroup: workspace.canvas.item(focused)?.groupID)
        guard members.count > 1 else { return nil }
        return FocusResolver.cycle(members, from: focused, forward: forward)
    }

    /// Toggles maximize on the focused pane (a presentation flag — no model surgery, registry untouched,
    /// docs/30 §1). Renders the one pane full-viewport (ignoring the camera / other panes).
    public func toggleZoom() {
        guard let focused = workspace.focusedPane else { return }
        workspace.maximizedPane = (workspace.maximizedPane == focused) ? nil : focused
        reconcile()
    }

    // MARK: - Canvas mutations (move / resize / raise / camera / arrange)

    /// Translates pane `id` by `delta` (the chrome drag-to-move commit), raising it to front and
    /// focusing it. Item SET unchanged → reconcile is a registry no-op (it only persists).
    public func movePane(_ id: PaneID, by delta: CGSize) {
        guard workspace.canvas.contains(id) else { return }
        workspace.canvas = workspace.canvas.moving(id, by: delta).raising(id)
        focusOnPlacement(id)
        reconcile()
    }

    /// Sets pane `id`'s frame (the corner/edge resize commit). The VIEW frame change drives the
    /// terminal host's `layout()` → reflow (the existing path; no new resize API). Item set unchanged.
    public func resizePane(_ id: PaneID, to frame: CGRect) {
        guard workspace.canvas.contains(id) else { return }
        workspace.canvas = workspace.canvas.resizing(id, to: frame)
        reconcile()
    }

    /// The canvas-space region the non-overlap solver gathers collision bodies from: the visible
    /// viewport (committed camera less any uncommitted live scroll, matching the view's solve-time
    /// reading) expanded by the snap margin so almost-visible neighbours still participate.
    private var collisionRegion: CGRect {
        let camera = workspace.canvas.camera
        let origin = CGPoint(
            x: camera.origin.x - liveCameraOffset.width,
            y: camera.origin.y - liveCameraOffset.height,
        )
        return CGRect(origin: origin, size: lastViewport).insetBy(dx: -200, dy: -200)
    }

    /// Drag-to-move commit under the non-overlap layout (``CanvasNonOverlap``): the dragged pane slides
    /// flush to `snapped` (never overlapping a neighbour / group box), and if the drop shows insert-intent
    /// the surrounded neighbours part to admit it — both committed in ONE canvas mutation (one persistence
    /// write, one reconcile). `snapped` is the CanvasSnap output (the gesture's snapped target). A disabled
    /// `config` (⌘ / setting off) degrades to a plain move-to, so the call site stays uniform.
    public func movePaneNonOverlapping(_ id: PaneID, snapped: CGRect, config: CanvasNonOverlap.Config) {
        guard let current = workspace.canvas.frame(of: id) else { return }
        guard config.enabled else {
            workspace.canvas = workspace.canvas.moving(id, to: snapped.origin).raising(id)
            focusOnPlacement(id)
            reconcile()
            return
        }
        let groupID = workspace.canvas.item(id)?.groupID
        let bodies = workspace.canvas.collisionBodies(
            excludingPane: id, excludingGroup: groupID, region: collisionRegion, groups: workspace.groups,
        )
        if let result = CanvasNonOverlap.makeSpace(
            target: snapped,
            draggedID: .pane(id),
            bodies: bodies,
            config: config,
        ) {
            // Insert-intent: pin the pane at the drop and part the surrounded neighbours around it.
            workspace.canvas = workspace.canvas.applying(result, groups: workspace.groups).raising(id)
        } else {
            // Rest flush: slide the pane to its non-overlapping position; nobody else moves.
            let slid = CanvasNonOverlap.slide(snapped, from: current.origin, bodies: bodies, config: config).frame
            workspace.canvas = workspace.canvas.moving(id, to: slid.origin).raising(id)
        }
        // Keep the pane's own group members non-overlapping (the top-level solve treated the dragged
        // pane's group as one excluded body, so a sibling overlap is resolved here).
        if let groupID { workspace.canvas = reflowedWithinGroup(
            workspace.canvas,
            movedPane: id,
            groupID: groupID,
            config: config,
        ) }
        focusOnPlacement(id)
        reconcile()
    }

    /// Keeps the members of `groupID` non-overlapping after one of them moved/resized: pins the changed
    /// pane and separates its siblings around it (the within-group reflow — members shouldn't overlap each
    /// other any more than top-level windows do).
    private func reflowedWithinGroup(
        _ canvas: Canvas,
        movedPane: PaneID,
        groupID: PaneGroupID,
        config: CanvasNonOverlap.Config,
    ) -> Canvas {
        guard config.enabled, let pinned = canvas.frame(of: movedPane) else { return canvas }
        let siblings = canvas.items
            .filter { $0.groupID == groupID && $0.id != movedPane }
            .map { CanvasNonOverlap.Body(id: .pane($0.id), rect: $0.frame) }
        guard !siblings.isEmpty else { return canvas }
        let result = CanvasNonOverlap.separate(
            pinnedID: .pane(movedPane),
            pinnedRect: pinned,
            bodies: siblings,
            config: config,
        )
        return canvas.applying(result, groups: workspace.groups)
    }

    /// Group-handle drag-to-move commit: the whole group slides as one rigid body to `snappedBox` (never
    /// overlapping another group / ungrouped pane), and if the drop shows insert-intent the surrounded
    /// bodies part to admit it — its members move rigidly to follow. A disabled config degrades to a plain
    /// rigid move. `snappedBox` is the group's (unpadded) bounding-box target.
    public func moveGroupNonOverlapping(_ groupID: PaneGroupID, snappedBox: CGRect, config: CanvasNonOverlap.Config) {
        guard let oldBox = workspace.canvas.groupBoundingBox(groupID) else { return }
        guard config.enabled else {
            workspace.canvas = workspace.canvas.movingGroup(
                groupID, by: CGSize(width: snappedBox.minX - oldBox.minX, height: snappedBox.minY - oldBox.minY),
            )
            reconcile()
            return
        }
        let bodies = workspace.canvas.collisionBodies(
            excludingPane: nil, excludingGroup: groupID, region: collisionRegion, groups: workspace.groups,
        )
        if let result = CanvasNonOverlap.makeSpace(
            target: snappedBox,
            draggedID: .group(groupID),
            bodies: bodies,
            config: config,
        ) {
            workspace.canvas = workspace.canvas.applying(result, groups: workspace.groups)
        } else {
            let slid = CanvasNonOverlap.slide(snappedBox, from: oldBox.origin, bodies: bodies, config: config).frame
            workspace.canvas = workspace.canvas.movingGroup(
                groupID, by: CGSize(width: slid.minX - oldBox.minX, height: slid.minY - oldBox.minY),
            )
        }
        reconcile()
    }

    /// The slid (non-overlapping) offset for a group-handle LIVE move preview: where the group's box would
    /// glide to under `rawDelta`, as a delta from its current origin — so the members + box preview glide
    /// FLUSH along neighbours exactly as the rest-flush commit lands them (preview ≡ commit, the same slide
    /// the pane drag uses). Returns the raw delta when disabled or the group is gone.
    public func groupSlideOffset(_ groupID: PaneGroupID, rawDelta: CGSize, config: CanvasNonOverlap.Config) -> CGSize {
        guard config.enabled, let oldBox = workspace.canvas.groupBoundingBox(groupID) else { return rawDelta }
        let bodies = workspace.canvas.collisionBodies(
            excludingPane: nil, excludingGroup: groupID, region: collisionRegion, groups: workspace.groups,
        )
        let target = oldBox.offsetBy(dx: rawDelta.width, dy: rawDelta.height)
        let slid = CanvasNonOverlap.slide(target, from: oldBox.origin, bodies: bodies, config: config).frame
        return CGSize(width: slid.minX - oldBox.minX, height: slid.minY - oldBox.minY)
    }

    /// Group-handle resize commit: the group's members are affinely remapped into `newBox` (its new
    /// footprint), then any OTHER group / ungrouped pane the grown box now overlaps is shoved clear
    /// (gate-free separation — a resize must never leave an overlap). `newBox` is the group's new
    /// (unpadded) bounding box.
    public func resizeGroupNonOverlapping(_ groupID: PaneGroupID, newBox: CGRect, config: CanvasNonOverlap.Config) {
        var canvas = workspace.canvas.resizingGroup(groupID, toBox: newBox)
        // A heavy SHRINK floors several members at minItemSize while their origins were placed for the
        // smaller scaled sizes → internal overlap. Reflow the members (pinning the top-leading one) so
        // they spread back out gutter-clear before the box is used to push other groups.
        if config.enabled, let anchor = topLeadingMember(of: groupID, in: canvas) {
            canvas = reflowedWithinGroup(canvas, movedPane: anchor, groupID: groupID, config: config)
        }
        if config.enabled, let grown = canvas.groupBoundingBox(groupID) {
            let bodies = canvas.collisionBodies(
                excludingPane: nil, excludingGroup: groupID, region: collisionRegion, groups: workspace.groups,
            )
            let result = CanvasNonOverlap.separate(
                pinnedID: .group(groupID),
                pinnedRect: grown,
                bodies: bodies,
                config: config,
            )
            canvas = canvas.applying(result, groups: workspace.groups)
        }
        workspace.canvas = canvas
        reconcile()
    }

    /// The spatial top-leading member of `groupID` (min Y, ties by min X) — the stable pin for a
    /// within-group reflow where every member moved (a group resize).
    private func topLeadingMember(of groupID: PaneGroupID, in canvas: Canvas) -> PaneID? {
        canvas.items
            .filter { $0.groupID == groupID }
            .min { a, b in a.frame.minY != b.frame.minY ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX }?
            .id
    }

    /// 1:1 SNAP (remote-GUI panes): resizes pane `id` by the VIDEO-CONTENT delta `target −
    /// current` so its stream renders pixel-for-pixel — the pane chrome (header + divider) is a
    /// constant additive inset around the content, so adjusting the FRAME by the CONTENT delta
    /// needs no chrome-height constant and stays correct if the chrome ever changes. The origin
    /// stays pinned (the pane grows right/down, no jump under the cursor). Skipped while the pane
    /// is maximized (its on-screen size is the viewport override — mutating the underlying frame
    /// would surprise the restore) and for sub-half-point deltas (layout noise; not worth a
    /// canvas mutation + persistence write).
    public func snapPaneToContentSize(_ id: PaneID, target: CGSize, current: CGSize) {
        guard workspace.maximizedPane != id,
              let frame = workspace.canvas.frame(of: id) else { return }
        let dw = target.width - current.width
        let dh = target.height - current.height
        // Cache the FRAME size at which this pane renders the stream 1:1, so "Resize to Native Stream
        // Size" can restore it after the user has manually resized away. nativeFrame = currentFrame +
        // (nativeContent − currentContent); the chrome inset rides along (constant), no constant needed.
        nativeFrameSize[id] = CGSize(width: frame.width + dw, height: frame.height + dh)
        guard abs(dw) >= 0.5 || abs(dh) >= 0.5 else { return }
        let snapped = CGRect(
            origin: frame.origin,
            size: CGSize(width: frame.width + dw, height: frame.height + dh),
        )
        workspace.canvas = workspace.canvas.resizing(id, to: snapped)
        reconcile()
    }

    /// WB3: the per-pane block-bookmark persistence seam + the per-pane jump-to-failed cursor, bundled into
    /// one stored holder (``BlockBookmarkSeam``) so the store body stays under the lint ceiling. The seam's
    /// `load`/`save` are wired by the app to the ``PreferencesStore`` (`settings.blockBookmarks.v1`), keyed
    /// by the pane's STABLE id (`PaneID.raw`, persisted with the tree so it survives reconnect / relaunch);
    /// left default (tests / previews) bookmarks are in-memory only. The `jumpCursor` records the block
    /// index the last jump-to-failed landed on so a repeated ⌃⌘⇧[ / ⌃⌘⇧] walks every failure in order.
    /// `@ObservationIgnored`: wiring, not view state. `internal` so the WorkspaceStore+Blocks extension
    /// reaches it (extensions can't add stored state).
    @ObservationIgnored var blockBookmarks = BlockBookmarkSeam()

    /// The pane frame size at which each `.remoteGUI` pane renders its stream pixel-for-pixel, cached
    /// from the last ``snapPaneToContentSize`` report. Drives "Resize to Native Stream Size".
    private var nativeFrameSize: [PaneID: CGSize] = [:]

    /// Whether a native stream size is known for pane `id` (the menu item's enabled state).
    public func hasNativeSize(_ id: PaneID) -> Bool { nativeFrameSize[id] != nil }

    /// Resizes pane `id` to the cached native stream frame size (origin pinned), so a manually-resized
    /// remote pane snaps back to a crisp 1:1 render. No-op if no native size is known or it's maximized.
    public func resizeToNativeSize(_ id: PaneID) {
        guard workspace.maximizedPane != id,
              let size = nativeFrameSize[id],
              let frame = workspace.canvas.frame(of: id) else { return }
        workspace.canvas = workspace.canvas.resizing(id, to: CGRect(origin: frame.origin, size: size))
        reconcile()
    }

    /// Brings pane `id` to the front and focuses it (on focus / drag-start). Item set unchanged.
    public func raisePane(_ id: PaneID) {
        guard workspace.canvas.contains(id) else { return }
        workspace.canvas = workspace.canvas.raising(id)
        focusOnPlacement(id)
        reconcile()
    }

    /// Commits a pan (the `.onEnded` of a canvas drag / a scroll-wheel step). Per-frame *live* pan is
    /// view `@State` and never touches the store (mirrors the `@GestureState` discipline); only the
    /// committed camera lands here and rides the existing save debounce.
    public func commitCamera(_ camera: CanvasCamera) {
        workspace.canvas = workspace.canvas.camera(camera)
        reconcile()
    }

    /// Live scroll-pan step (macOS trackpad/wheel — over the background OR over a pane). Accumulates the
    /// camera `delta` as a VISUAL-only offset (``liveCameraOffset``) and debounces a SINGLE
    /// ``commitScrollPan()`` once scrolling settles — instead of a per-step ``commitCamera(_:)`` that
    /// thrashes the canvas re-render + `report()` cascade and freezes the video/cursor (BUG-2/BUG-1,
    /// 2026-06-08). `delta` is the camera delta the old call passed to `camera.translated(by:)`; the visual
    /// offset moves OPPOSITE it (the content follows the camera), matching the committed `.offset` math in
    /// ``CanvasView``. Only ``CanvasView`` reads ``liveCameraOffset``, so a step re-renders nothing else.
    public func scrollPan(by delta: CGSize) {
        liveCameraOffset.width -= delta.width
        liveCameraOffset.height -= delta.height
        if Self.wsDbgEnabled {
            FileHandle.standardError
                .write(
                    Data(
                        "Aislopdesk[workspace]: scrollPan d=(\(Int(delta.width)),\(Int(delta.height))) liveOff=(\(Int(liveCameraOffset.width)),\(Int(liveCameraOffset.height))) camOrigin=(\(Int(workspace.canvas.camera.origin.x)),\(Int(workspace.canvas.camera.origin.y)))\n"
                            .utf8,
                    ),
                )
        }
        scrollCommitTask?.cancel()
        scrollCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard let self, !Task.isCancelled else { return }
            commitScrollPan()
        }
    }

    /// Env-gated (`AISLOPDESK_VIDEO_DEBUG`) stderr probe for the scroll-pan path (BUG-2 "pan stops at the GUI
    /// edge"): shows whether a scroll over a GUI pane actually moves the camera, vs the visual offset not
    /// being applied / the events not reaching here.
    static let wsDbgEnabled = ProcessInfo.processInfo.environment["AISLOPDESK_VIDEO_DEBUG"] != nil

    /// Folds the accumulated live scroll offset into the real camera in ONE ``commitCamera(_:)`` (so the
    /// pan persists + viewport membership / solved-layout refresh exactly once), then clears the visual
    /// offset. The committed camera equals the live state, so there is NO visual jump (Observation batches
    /// the two synchronous mutations into one render). No-op when nothing is pending. Public so an explicit
    /// camera op or a quit-save can flush a still-pending pan first.
    public func commitScrollPan() {
        scrollCommitTask?.cancel()
        scrollCommitTask = nil
        let off = liveCameraOffset
        guard off != .zero else { return }
        let before = workspace.canvas.camera.origin
        liveCameraOffset = .zero
        // cameraDelta = sum of all scroll steps = -(accumulated visual offset).
        commitCamera(workspace.canvas.camera.translated(by: CGSize(width: -off.width, height: -off.height)))
        if Self.wsDbgEnabled {
            let after = workspace.canvas.camera.origin
            FileHandle.standardError
                .write(
                    Data(
                        "Aislopdesk[workspace]: commitScrollPan camOrigin (\(Int(before.x)),\(Int(before.y)))→(\(Int(after.x)),\(Int(after.y))) foldedOff=(\(Int(off.width)),\(Int(off.height)))\n"
                            .utf8,
                    ),
                )
        }
    }

    /// Drops any pending live scroll offset WITHOUT committing — used by an ABSOLUTE camera op (recenter /
    /// center-on / tidy) that sets the camera outright, so a late ``commitScrollPan()`` can't add a stale
    /// relative delta on top of the new absolute position.
    private func discardLiveScroll() {
        scrollCommitTask?.cancel()
        scrollCommitTask = nil
        liveCameraOffset = .zero
    }

    /// In-view guarantee shared by every placement path (add / remote-window / duplicate / reopen /
    /// system-dialog): if the just-placed pane's CENTRE falls outside the current viewport, pan the camera
    /// to centre it. ``centered(on:viewport:)`` is an ABSOLUTE camera set, so it first discards any pending
    /// live scroll (mirroring ``centerOnPane(_:)`` / ``centerOnAll()``) — else a late ``commitScrollPan()``
    /// would fold a stale relative scroll delta on top of the freshly-centred camera, nudging the new pane
    /// back off-centre and persisting the wrong camera.
    private func recenterIfOffscreen(_ id: PaneID, viewport: CGSize) {
        let visible = CGRect(origin: workspace.canvas.camera.origin, size: viewport)
        guard let f = workspace.canvas.frame(of: id),
              !visible.contains(CGPoint(x: f.midX, y: f.midY)) else { return }
        discardLiveScroll()
        workspace.canvas = workspace.canvas.centered(on: id, viewport: viewport)
    }

    /// Centres the camera on pane `id` ("Center on Pane" + the off-screen-focus reveal).
    public func centerOnPane(_ id: PaneID) {
        guard workspace.canvas.contains(id) else { return }
        discardLiveScroll()
        workspace.canvas = workspace.canvas.centered(on: id, viewport: lastViewport)
        reconcile()
    }

    /// Centres the camera on the bounding box of group `id`'s panes (the sidebar "jump to group" / a tap
    /// on the group header). No-op if the group has no members.
    public func centerOnGroup(_ id: PaneGroupID) {
        guard let box = workspace.canvas.groupBoundingBox(id) else { return }
        let camera = CanvasCamera(origin: CGPoint(
            x: box.midX - lastViewport.width / 2,
            y: box.midY - lastViewport.height / 2,
        ))
        discardLiveScroll()
        workspace.canvas = workspace.canvas.camera(camera)
        reconcile()
    }

    /// Centres the camera on the bounding box of ALL panes ("Center on All" — NOT "Fit"; there is no
    /// scale, so it centres but cannot shrink).
    public func centerOnAll() {
        discardLiveScroll()
        workspace.canvas = workspace.canvas.centeredOnAll(viewport: lastViewport)
        reconcile()
    }

    /// Packs every pane into a uniform grid and recentres ("Tidy").
    public func tidyCanvas() {
        discardLiveScroll()
        workspace.canvas = workspace.canvas.tidied(viewport: lastViewport)
        reconcile()
    }

    /// The panes an Arrange (align / distribute) op targets: the multi-selection when ≥2 are selected,
    /// else every pane on the canvas (so "Align Left" with no selection tidies the whole canvas edge).
    func arrangeTargets() -> [PaneID] {
        if selectedPanes.count >= 2 { return workspace.canvas.allIDs().filter { selectedPanes.contains($0) } }
        return workspace.canvas.allIDs()
    }

    /// Aligns the Arrange targets to a shared edge/centre (the Pane ▸ Arrange menu).
    public func alignPanes(to edge: AlignEdge) {
        workspace.canvas = workspace.canvas.aligning(arrangeTargets(), to: edge)
        reconcile()
    }

    /// Distributes the Arrange targets with equal gaps along an axis.
    public func distributePanes(horizontal: Bool) {
        workspace.canvas = workspace.canvas.distributing(arrangeTargets(), horizontal: horizontal)
        reconcile()
    }

    // MARK: - Broadcast / synchronized input (tmux synchronize-panes)

    /// Whether broadcast input is ARMED: a submit in the focused pane's input bar is fanned to every
    /// ``broadcastTargets()`` pane instead of only the focused one. Transient view state — never persisted
    /// (a synchronized-typing mode should not survive a relaunch and surprise you).
    public private(set) var broadcastActive: Bool = false

    /// The set of tab IDs for which per-tab synchronized input is ON (Zellij `ToggleActiveSyncTab`): every
    /// keystroke typed in the focused pane of a sync-armed tab is ALSO sent to every OTHER pane in that
    /// same tab. Transient — never persisted (the same rationale as ``broadcastActive``).
    public private(set) var syncInputTabs: Set<TabID> = []

    /// Arms / disarms broadcast input (⇧⌘B / Pane ▸ Broadcast Input).
    public func toggleBroadcast() { broadcastActive.toggle() }

    /// Sets broadcast mode explicitly (e.g. auto-disarm). Idempotent.
    public func setBroadcast(_ active: Bool) { broadcastActive = active }

    /// The panes a broadcast targets — resolved like ``arrangeTargets()`` but restricted to the kinds with
    /// a text funnel (``PaneKind/canReceiveText``; the video panes have no input bar and are skipped): the
    /// multi-selection when ≥2 are selected, else the focused pane's GROUP when it is grouped, else just
    /// the focused pane. Deterministic canvas order. Pure — no mutation.
    public func broadcastTargets() -> [PaneID] {
        func textCapable(_ id: PaneID) -> Bool { workspace.canvas.spec(for: id)?.kind.canReceiveText == true }
        if selectedPanes.count >= 2 {
            return workspace.canvas.allIDs().filter { selectedPanes.contains($0) && textCapable($0) }
        }
        if let focused = workspace.focusedPane, let group = workspace.canvas.item(focused)?.groupID {
            return workspace.canvas.ids(inGroup: group).filter(textCapable)
        }
        return workspace.focusedPane.flatMap { textCapable($0) ? [$0] : [] } ?? []
    }

    /// Types `text` into every broadcast target's shell (the synchronized-input fan-out — type a command
    /// once, run it on every pane in the group). Returns how many panes it reached. Pure routing over the
    /// live registry: no canvas mutation, no reconcile.
    @discardableResult
    public func broadcastText(_ text: String) -> Int {
        let targets = broadcastTargets()
        for id in targets { registry[id]?.sendText(text) }
        return targets.count
    }

    /// Reentrancy guard for ``fanBroadcastInput(from:_:)``: when a fan-out mirrors bytes into a SIBLING
    /// target, that sibling's own `TerminalViewModel.sendInput` re-fires the broadcast tap — without this
    /// guard each keystroke would cross-multiply across the group (N panes → N² sends → a feedback storm).
    /// Set only for the synchronous duration of one fan-out (all on the main actor, so a flag suffices).
    private var isFanningBroadcast = false

    /// The live synchronized-input fan-out (tmux `synchronize-panes`): the SOURCE pane's terminal calls
    /// this from ``TerminalViewModel/sendInput(_:)`` with the bytes it just sent to its own shell; when
    /// broadcast is armed AND the source is part of the current target group, the SAME bytes are mirrored
    /// into every OTHER target's shell — so a keystroke (macOS surface) or a composed line (iOS input bar),
    /// both of which funnel through `sendInput`, types on every grouped pane at once.
    ///
    /// The source pane is intentionally skipped (it already delivered the bytes locally via its own
    /// `inputSink`); siblings receive via ``PaneSessionHandle/sendBytes(_:)`` (→ their input funnel → their
    /// `sendInput`), and the reentrancy guard keeps that re-entry from re-fanning. A no-op when disarmed,
    /// when the source is not a target (you are typing in a non-broadcast pane), or when re-entered.
    /// Returns the number of SIBLINGS reached (0 when it did nothing). Pure registry routing — no mutation.
    @discardableResult
    public func fanBroadcastInput(from sourceID: PaneID, _ data: Data) -> Int {
        guard broadcastActive, !isFanningBroadcast, !data.isEmpty else { return 0 }
        let targets = broadcastTargets()
        guard targets.contains(sourceID), targets.count > 1 else { return 0 }
        isFanningBroadcast = true
        defer { isFanningBroadcast = false }
        let bytes = Array(data)
        var reached = 0
        for id in targets where id != sourceID {
            registry[id]?.sendBytes(bytes)
            reached += 1
        }
        return reached
    }

    /// Toggles per-tab synchronized input for `tabID` (Zellij `ToggleActiveSyncTab`). When ON, every
    /// keystroke typed in any pane of the tab is also mirrored into the tab's other panes via
    /// ``fanSyncInput(from:_:)``. Idempotent when called on the same tab twice (insert → remove cycle).
    public func toggleSyncInput(tabID: TabID) {
        if syncInputTabs.contains(tabID) {
            syncInputTabs.remove(tabID)
        } else {
            syncInputTabs.insert(tabID)
        }
    }

    /// The per-tab synchronized-input fan-out (Zellij `ToggleActiveSyncTab`): mirrors the bytes that the
    /// source pane just sent to its own shell into every OTHER pane in the same tab, when sync is armed for
    /// that tab. The source pane is intentionally SKIPPED (it already delivered locally via `inputSink`);
    /// sibling delivery is through ``PaneSessionHandle/sendBytes(_:)`` (→ their input funnel). The existing
    /// ``isFanningBroadcast`` guard doubles as the sync-input re-entry guard (both run on the same
    /// `@MainActor` flat flag): a sibling's `sendInput` re-fires `broadcastTap`, which would call
    /// `fanSyncInput` again — the guard collapses the re-entrant call to a no-op, preventing a fan-storm.
    /// Returns the number of siblings reached (0 when disarmed, single-pane tab, or re-entrant).
    @discardableResult
    public func fanSyncInput(from sourceID: PaneID, _ data: Data) -> Int {
        guard !data.isEmpty, !isFanningBroadcast else { return 0 }
        // Resolve the containing tab by scanning sessions (tree-only; no canvas analogue).
        guard let (_, tabID) = tree.tab(containing: sourceID) else { return 0 }
        guard syncInputTabs.contains(tabID) else { return 0 }
        // Find the Tab value to enumerate siblings.
        var tab: Tab?
        for session in tree.sessions {
            if let found = session.tabs.first(where: { $0.id == tabID }) { tab = found
                break
            }
        }
        guard let tab else { return 0 }
        let siblings = tab.allPaneIDs().filter { $0 != sourceID }
        guard !siblings.isEmpty else { return 0 }
        isFanningBroadcast = true
        defer { isFanningBroadcast = false }
        let bytes = Array(data)
        var reached = 0
        for id in siblings {
            registry[id]?.sendBytes(bytes)
            reached += 1
        }
        return reached
    }

    // MARK: - Snippets (saved command macros, run from ⌘K)

    /// The saved snippets, persisted on the workspace (read-only view; mutate via the CRUD below).
    public var snippets: [Snippet] { workspace.snippets }

    /// A non-blank snippet display name (trimmed; an empty/whitespace name falls back to "Snippet" so the
    /// palette never shows a blank "Run …" row — reachable from CRUD and from a merge-imported file).
    static func snippetName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Snippet" : t
    }

    /// Saves a new snippet and returns it. Metadata-only mutation (leaf set unchanged) → reconcile persists.
    @discardableResult
    public func addSnippet(name: String, body: String) -> Snippet {
        let snippet = Snippet(name: Self.snippetName(name), body: body)
        workspace.snippets.append(snippet)
        reconcile()
        return snippet
    }

    /// Edits an existing snippet's name + body. No-op for an unknown id.
    public func updateSnippet(_ id: UUID, name: String, body: String) {
        guard let i = workspace.snippets.firstIndex(where: { $0.id == id }) else { return }
        // Store the name VERBATIM here — this is the live-editing path, so a per-keystroke trim/substitute
        // would fight the typist (a trailing space gets deleted; clearing the field snaps to "Snippet").
        // The empty→"Snippet" fallback is applied at DISPLAY time (palette/manager) and re-normalized once
        // on add + import/load, where a one-shot clean-up is correct.
        workspace.snippets[i].name = name
        workspace.snippets[i].body = body
        reconcile()
    }

    /// Deletes a snippet. No-op for an unknown id.
    public func deleteSnippet(_ id: UUID) {
        workspace.snippets.removeAll { $0.id == id }
        if lastRanSnippetID == id { lastRanSnippetID = nil } // don't leave ⌥⌘R pointing at a dead snippet
        reconcile()
    }

    // MARK: - Workspace export / import (portable backup / share)

    /// Encodes the current workspace to a portable document (host connection stripped, ephemeral panes
    /// stripped) — what the `.fileExporter` writes to disk.
    public func exportWorkspaceData() -> Data {
        WorkspaceTransfer.export(persistableWorkspace())
    }

    /// How an import lands: REPLACE the live canvas (backup-restore) or MERGE the document's panes in
    /// ADDITIVELY beside the current ones (combine two setups).
    public enum WorkspaceImportMode: Sendable { case replace, mergeAppend }

    /// Imports a workspace document. `.replace` swaps the whole canvas (backup-restore / load-a-shared
    /// setup); `.mergeAppend` adds the document's panes/groups/snippets/presets beside the current ones.
    /// In BOTH modes the local host connection is KEPT (never adopt the file's) and every imported pane id
    /// is re-minted. Returns whether the bytes were a valid document; a hostile / foreign / future file
    /// leaves the live workspace untouched and returns `false`.
    @discardableResult
    public func importWorkspace(_ data: Data, mode: WorkspaceImportMode = .replace) -> Bool {
        guard let imported = WorkspaceTransfer.decode(data) else { return false }
        // COMMIT (not discard) any in-flight scroll pan: a later path here can still bail (e.g. the
        // mergeAppend cap rejects the document), and discarding would silently snap the canvas back to the
        // pre-scroll origin even though "the live workspace is left untouched". Committing folds the pan
        // into the camera so a rejected import truly leaves the view as the user had it; on the replace
        // path the camera is overwritten by the imported one anyway, so committing is harmless there.
        commitScrollPan()
        switch mode {
        case .replace:
            // Re-mint EVERY imported pane id through an explicit idMap (exactly as switchToLayoutPreset
            // does): (1) a re-import into the SAME running session would otherwise collide a fresh pane
            // with a still-tearing-down live session of the same id (the async-teardown race), and (2) —
            // the reason a bare dedupingItemIDs was WRONG here — focus + bookmark anchors must FOLLOW the
            // re-mint. With the map we remap `focusedPane` and every `bookmarks[].pane`.
            var idMap: [PaneID: PaneID] = [:]
            let reminted = imported.canvas.items.map { item -> CanvasItem in
                let fresh = PaneID()
                idMap[item.id] = fresh
                return CanvasItem(id: fresh, spec: item.spec, frame: item.frame, z: item.z, groupID: item.groupID)
            }
            var ws = imported
            ws.canvas = Canvas(items: reminted, camera: imported.canvas.camera)
            ws.focusedPane = imported.focusedPane.flatMap { idMap[$0] } ?? reminted.first?.id
            ws.bookmarks = imported.bookmarks.mapValues { bm in
                CanvasBookmark(pane: bm.pane.flatMap { idMap[$0] }, cameraOrigin: bm.cameraOrigin, name: bm.name)
            }
            ws.connection = workspace.connection // keep the local host; never adopt the imported one
            ws.maximizedPane = nil
            workspace = ws.normalizingGroups()
            pendingClose = nil
            pendingRename = nil
            overviewActive = false
            // A whole-canvas swap invalidates the close-undo (it points at the OLD workspace) and should
            // not leave synchronized-input armed against the freshly-imported panes (its contract is "must
            // not survive and surprise you") — clear both, matching switchToLayoutPreset.
            recentlyClosed = nil
            setBroadcast(false)
            reseedFocusHistory() // re-minted ids → the quick-switch ring would otherwise be all-dead
            clearSelection()
        case .mergeAppend:
            // The MERGED canvas must obey the same size cap a single imported document does: decode()
            // bounds the import to maxItems, but a live workspace already near the cap plus a max-size
            // import would assemble ~2× maxItems items and make reconcile() materialize that many sessions
            // on the main actor (the UI-freeze / OOM this cap exists to prevent). Reject the merge if the
            // combined canvas would exceed maxItems; the live workspace is left untouched.
            guard workspace.canvas.items.count + imported.canvas.items.count <= WorkspaceTransfer.maxItems else {
                return false
            }
            // The SAME per-collection bound applies to groups / snippets / presets. decode() and the on-disk
            // load() both reject — and resetToDefault() — a workspace whose groups, snippets, or layoutPresets
            // exceed maxItems. So a merge that pushes any of those collections over the cap WORKS this session
            // but makes the next launch's load() discard the ENTIRE workspace (every pane, group, bookmark,
            // snippet, preset) back to the one-terminal default — surprising total data loss the user never
            // caused by hand-editing. Reject symmetrically (groups are never deduped here, so the sum is the
            // exact post-merge count; snippets/presets dedup, so the sum is a safe upper bound). Live untouched.
            guard workspace.groups.count + imported.groups.count <= WorkspaceTransfer.maxItems,
                  workspace.snippets.count + imported.snippets.count <= WorkspaceTransfer.maxItems,
                  workspace.layoutPresets.count + imported.layoutPresets.count <= WorkspaceTransfer.maxItems
            else {
                return false
            }
            // Re-mint imported pane ids AND group ids (the imported groups are brand-new here), offset the
            // frames by a cascade so the additions don't stack on top of the originals, then append the
            // items + groups and union snippets/presets by name (collisions get a "… copy" suffix). Empty
            // bookmark slots are filled (never clobber an existing bookmark). Focus is left on the current
            // pane (a merge shouldn't yank focus to an import). reconcile() materializes the new sessions.
            var idMap: [PaneID: PaneID] = [:]
            var groupMap: [PaneGroupID: PaneGroupID] = [:]
            for g in imported.groups { groupMap[g.id] = PaneGroupID() }
            let cascade = CGSize(width: 64, height: 64)
            let appended = imported.canvas.items.map { item -> CanvasItem in
                let fresh = PaneID()
                idMap[item.id] = fresh
                let group = item.groupID.flatMap { groupMap[$0] }
                return CanvasItem(
                    id: fresh,
                    spec: item.spec,
                    frame: item.frame.offsetBy(dx: cascade.width, dy: cascade.height),
                    z: item.z,
                    groupID: group,
                )
            }
            workspace.canvas = Canvas(items: workspace.canvas.items + appended, camera: workspace.canvas.camera)
            workspace.groups += imported.groups.map { PaneGroup(id: groupMap[$0.id] ?? PaneGroupID(), name: $0.name) }
            // Union by name, but CONTENT-dedup first so re-merging the SAME document N times can't grow the
            // library (a snippet whose body already exists, or a preset whose canvas+groups already exist,
            // is a re-import — skip it). Without this, repeated identical merges accrued "X copy copy …".
            for s in imported.snippets where !workspace.snippets.contains(where: { $0.body == s.body }) {
                let name = Self.uniqueName(
                    base: Self.snippetName(s.name),
                    existing: Set(workspace.snippets.map(\.name)),
                )
                workspace.snippets.append(Snippet(name: name, body: s.body))
            }
            for p in imported.layoutPresets
                where !workspace.layoutPresets.contains(where: { $0.canvas == p.canvas && $0.groups == p.groups })
            {
                let name = Self.uniqueName(base: p.name, existing: Set(workspace.layoutPresets.map(\.name)))
                // Clear the trigger on a merged preset — two presets must not both auto-switch on one app.
                workspace.layoutPresets.append(LayoutPreset(
                    name: name,
                    canvas: p.canvas,
                    groups: p.groups,
                    focusedPane: p.focusedPane,
                    triggerAppName: nil,
                ))
            }
            // Adopt an imported bookmark into an empty slot ONLY when its anchor pane SURVIVES the id remap.
            // recallBookmark FOLLOWS a live anchor (re-deriving the camera from the pane's current position),
            // so an anchored bookmark stays correct. But a bookmark with NO surviving anchor (pane == nil — a
            // pure-camera bookmark — or a pane id absent from the imported canvas) would fall back to its saved
            // cameraOrigin, which is in the IMPORTED document's coordinate frame while the merged canvas lives
            // in the live frame: recalling it (⌘<n>) would pan into empty space. There is no correct cross-frame
            // translation (the two canvases are independent spaces), so drop it — exactly as switchToLayoutPreset
            // clears all bookmarks for the same cross-frame reason.
            for (slot, bm) in imported.bookmarks where workspace.bookmarks[slot] == nil {
                guard let pane = bm.pane.flatMap({ idMap[$0] }) else { continue }
                workspace.bookmarks[slot] = CanvasBookmark(pane: pane, cameraOrigin: bm.cameraOrigin, name: bm.name)
            }
        }
        reconcile()
        return true
    }

    /// A name not already in `existing`: `base`, else `base copy`, `base copy 2`, … (the Finder idiom).
    /// Pure — shared by the import merge's union-by-name.
    static func uniqueName(base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        let copy = "\(base) copy"
        if !existing.contains(copy) { return copy }
        var n = 2
        while existing.contains("\(copy) \(n)") { n += 1 }
        return "\(copy) \(n)"
    }

    /// Runs snippet `id`: resolves its `{{placeholders}}` from `values`, parses `<Token>` control keys to
    /// bytes, and feeds the result into the BROADCAST targets when broadcast is armed, else the focused
    /// pane. Returns how many panes it reached (0 = unknown id / empty body / no text-capable target).
    /// Unresolved placeholders are left literal (visible) rather than blanked.
    @discardableResult
    public func runSnippet(_ id: UUID, values: [String: String] = [:]) -> Int {
        guard let snippet = workspace.snippets.first(where: { $0.id == id }) else { return 0 }
        let (text, _) = SnippetExpander.expand(snippet.body, values: values)
        let bytes = SendKeysParser.encode(text)
        guard !bytes.isEmpty else { return 0 }
        let candidates = broadcastActive ? broadcastTargets() : (workspace.focusedPane.map { [$0] } ?? [])
        var count = 0
        for pid in candidates where workspace.canvas.spec(for: pid)?.kind.canReceiveText == true {
            registry[pid]?.sendBytes(bytes)
            count += 1
        }
        return count
    }

    /// The snippet whose `{{placeholder}}` values the UI is currently asking for (the value-entry sheet's
    /// presentation binding), or `nil`. Transient — never persisted.
    public private(set) var pendingSnippetRun: UUID?

    /// What ``beginRunSnippet(_:)`` decided to do — so the call (palette / menu) and the tests can branch
    /// without poking view state.
    public enum SnippetRunOutcome: Equatable {
        /// Ran immediately (no placeholders), reaching N text-capable panes.
        case ran(Int)
        /// Has unresolved `{{placeholders}}` — the value-entry sheet was armed for these names.
        case needsValues([String])
        /// No snippet with that id.
        case unknown
    }

    /// The single entry point for "run this snippet" from the palette/menu. A snippet with NO placeholders
    /// runs straight away (the prior behaviour); a PARAMETERIZED one arms ``pendingSnippetRun`` so the UI
    /// can collect values first — fixing the bug where `ssh {{user}}@{{host}}` was injected verbatim
    /// because the palette always called `runSnippet(id, values: [:])`. Pure decision over the snippet's
    /// placeholders; the sheet finishes by calling ``runSnippet(_:values:)`` + ``clearSnippetRunRequest()``.
    @discardableResult
    public func beginRunSnippet(_ id: UUID) -> SnippetRunOutcome {
        guard let snippet = workspace.snippets.first(where: { $0.id == id }) else { return .unknown }
        lastRanSnippetID = id // remember the launch so ⌥⌘R can re-fire it without ⌘K
        let slots = snippet.placeholders
        guard !slots.isEmpty else { return .ran(runSnippet(id)) }
        pendingSnippetRun = id
        return .needsValues(slots)
    }

    /// The most-recently-launched snippet (via ``beginRunSnippet(_:)``), so ⌥⌘R can re-fire it. Session
    /// state (not persisted). Cleared if that snippet is deleted.
    public private(set) var lastRanSnippetID: UUID?

    /// Re-runs the most-recently-launched snippet (⌥⌘R) — the "repeat my last macro" power chord, so a
    /// `deploy` / `tmux attach` you fire all day costs one keystroke after the first ⌘K launch. Routes
    /// through ``beginRunSnippet(_:)`` so a parameterized snippet re-prompts for values. A graceful no-op
    /// (`.unknown`) when nothing has been run yet or the last snippet was since deleted.
    @discardableResult
    public func runLastSnippet() -> SnippetRunOutcome {
        guard let id = lastRanSnippetID else { return .unknown }
        return beginRunSnippet(id)
    }

    /// Dismisses the placeholder value-entry sheet (Cancel, or after a successful run).
    public func clearSnippetRunRequest() { pendingSnippetRun = nil }

    /// Whether the snippet manager (create / edit / delete) is presented. Until this existed, the snippet
    /// CRUD (``addSnippet``/``updateSnippet``/``deleteSnippet``) had NO in-app caller — a user could only
    /// get a snippet by hand-editing the workspace JSON. Transient — never persisted.
    public private(set) var snippetManagerPresented = false

    /// Opens the snippet manager (⌘K "Manage Snippets…" / Pane ▸ Manage Snippets…). Clears any stranded
    /// `pendingSnippetRun` first so a value-entry sheet that a prior transition failed to present can
    /// never sit armed-but-invisible behind the manager.
    public func requestSnippetManager() {
        pendingSnippetRun = nil
        snippetManagerPresented = true
    }

    /// Closes the snippet manager.
    public func dismissSnippetManager() { snippetManagerPresented = false }

    // MARK: - Command palette recents

    /// The most-recently-run palette COMMANDS, most-recent-first (non-persisted session state). The
    /// ⌘K palette surfaces these at the top when the query is empty, so the verbs you use most are one
    /// keystroke away. Only true command verbs are tracked (not pane/group/window jumps — those are
    /// covered by their own always-present sections).
    public private(set) var recentCommands: [WorkspaceCommand] = []
    /// How many recents to keep.
    public static let recentCommandsCap = 5

    /// Records a run command at the front of the recents ring (dedup-to-front, capped).
    public func recordRecentCommand(_ command: WorkspaceCommand) {
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
        if recentCommands.count > Self.recentCommandsCap {
            recentCommands.removeLast(recentCommands.count - Self.recentCommandsCap)
        }
    }

    // MARK: - Clipboard history ring

    /// Recent clipboard texts, most-recent-first (non-persisted session state — clipboard history is
    /// transient and often sensitive). Fed by the macOS clipboard monitor and by every paste-as-
    /// keystrokes; the pill's "Paste Recent" submenu replays any entry into a remote pane.
    public private(set) var clipboardRing: [String] = []
    /// How many clips to keep.
    public static let clipboardRingCap = 20

    /// Records `text` at the front of the ring (deduped — a repeat moves to front), capped at
    /// ``clipboardRingCap``. Skips empty/whitespace, and skips everything when the user has turned OFF
    /// clipboard-history recording (Settings ▸ Advanced ▸ Privacy) — the single chokepoint, so a copied
    /// secret is never retained when recording is disabled. Read at fire-time so the toggle applies live.
    public func recordClip(_ text: String) {
        guard SettingsKey.recordClipboardHistoryEnabled else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clipboardRing.removeAll { $0 == text }
        clipboardRing.insert(text, at: 0)
        if clipboardRing.count > Self.clipboardRingCap {
            clipboardRing.removeLast(clipboardRing.count - Self.clipboardRingCap)
        }
    }

    /// Clears the clipboard history (a privacy affordance).
    public func clearClipboardRing() { clipboardRing = [] }

    // MARK: - Multi-selection (shift-click to select several panes)

    /// The set of panes in the multi-selection (besides the single focused pane) — pure view state,
    /// never reconciles or persists. Drives the Arrange ops' target set and a group move-together drag.
    /// Empty = single-focus mode. Always a subset of the live canvas.
    public private(set) var selectedPanes: Set<PaneID> = []

    /// Toggles `id` in the multi-selection (shift-click on a pill). Toggling the SOLE selected pane off
    /// clears the set. Ignores ids not on the canvas.
    public func toggleSelection(_ id: PaneID) {
        guard workspace.canvas.contains(id) else { return }
        if selectedPanes.contains(id) { selectedPanes.remove(id) } else { selectedPanes.insert(id) }
    }

    /// Replaces the selection with exactly `ids` (clamped to live panes). `[]` clears it.
    public func setSelection(_ ids: Set<PaneID>) {
        selectedPanes = ids.filter { workspace.canvas.contains($0) }
    }

    /// Clears the multi-selection (a background click / Esc).
    public func clearSelection() {
        if !selectedPanes.isEmpty { selectedPanes = [] }
    }

    /// Selects EVERY pane on the canvas (⌥⌘A) — the standard "select all" for then aligning /
    /// distributing / grouping / broadcasting to the whole set at once. A no-op visual when the canvas
    /// is empty (selects nothing).
    public func selectAllPanes() {
        setSelection(Set(workspace.canvas.allIDs()))
    }

    /// Whether `id` is in the multi-selection (the pill's selected cue).
    public func isSelected(_ id: PaneID) -> Bool { selectedPanes.contains(id) }

    /// The LIVE group-drag offset broadcast by the dragged anchor so the OTHER selected panes follow it
    /// in real time (view-only state, like ``liveCameraOffset`` — never reconciles/persists). `nil`
    /// between drags. Only selected panes read it, so a group drag re-renders just the cohort.
    public struct GroupDragState: Equatable, Sendable { public let anchor: PaneID
        public let delta: CGSize
    }

    public private(set) var groupDragLive: GroupDragState?

    /// The anchor broadcasts its live raw translation each gesture frame. Cleared (and ignored) unless
    /// the anchor is in a multi-selection of ≥2.
    public func updateGroupDrag(anchor: PaneID, delta: CGSize) {
        guard selectedPanes.contains(anchor), selectedPanes.count > 1 else { groupDragLive = nil
            return
        }
        groupDragLive = GroupDragState(anchor: anchor, delta: delta)
    }

    /// Ends the live group drag (the gesture committed or cancelled).
    public func endGroupDragLive() { groupDragLive = nil }

    /// The live screen offset a NON-anchor selected pane should render at during a group drag (`.zero`
    /// when no group drag, or for the anchor itself — its own gesture preview already moves it).
    public func groupDragOffset(for id: PaneID) -> CGSize {
        guard let gd = groupDragLive, gd.anchor != id, selectedPanes.contains(id) else { return .zero }
        return gd.delta
    }

    /// Moves EVERY selected pane by `delta` (a group drag-to-move-together commit), raising the dragged
    /// `anchor`. No-op when the selection is empty or `anchor` isn't selected (fall back to a single move).
    public func moveSelection(by delta: CGSize, anchor: PaneID) {
        guard selectedPanes.contains(anchor), selectedPanes.count > 1 else { return }
        var canvas = workspace.canvas
        for id in selectedPanes where canvas.contains(id) {
            canvas = canvas.moving(id, by: delta)
        }
        workspace.canvas = canvas.raising(anchor)
        focusOnPlacement(anchor)
        reconcile()
    }

    // MARK: - Group-handle live drag (move the whole PaneGroup as a unit)

    /// The LIVE group-handle drag: the group being moved + its raw translation, broadcast so its member
    /// panes (and the drawn group box) follow in real time — view-only, like ``groupDragLive`` but keyed
    /// to a PaneGroup (not the ad-hoc multi-selection). `nil` between drags.
    public struct GroupHandleDragState: Equatable, Sendable { public let group: PaneGroupID
        public let delta: CGSize
    }

    public private(set) var groupHandleDragLive: GroupHandleDragState?

    /// The handle broadcasts its live raw translation each gesture frame.
    public func updateGroupHandleDrag(_ groupID: PaneGroupID, delta: CGSize) {
        groupHandleDragLive = GroupHandleDragState(group: groupID, delta: delta)
    }

    /// Ends the live group-handle drag (committed or cancelled).
    public func endGroupHandleDrag() { groupHandleDragLive = nil }

    /// The live screen offset a pane should render at during a group-handle move (`.zero` unless it is a
    /// member of the group currently being handle-dragged). Read by ``CanvasItemView`` like
    /// ``groupDragOffset(for:)``.
    public func groupHandleOffset(for id: PaneID) -> CGSize {
        guard let gh = groupHandleDragLive, workspace.canvas.item(id)?.groupID == gh.group else { return .zero }
        return gh.delta
    }

    /// The live offset the DRAWN group box of `groupID` should render at during its own handle move.
    public func groupBoxOffset(for groupID: PaneGroupID) -> CGSize {
        guard let gh = groupHandleDragLive, gh.group == groupID else { return .zero }
        return gh.delta
    }

    // MARK: - Overview (fit-all peek)

    /// Whether the temporary "see every pane at once" overview is showing (⌘\). Pure view-presentation
    /// state — never reconciles, never persisted. Renders static pane cards over the dimmed canvas;
    /// clicking a card jumps to that pane and exits.
    public private(set) var overviewActive = false

    /// Toggles the overview. A no-op (stays off) on an empty canvas — nothing to overview. Exiting a
    /// maximize first if one is active (the two full-canvas modes are mutually exclusive).
    public func toggleOverview() {
        if overviewActive {
            overviewActive = false
        } else {
            guard !workspace.canvas.items.isEmpty else { return }
            if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
            overviewActive = true
        }
    }

    /// Exits the overview (Esc / a card tap routes through here). No-op when already off.
    public func exitOverview() {
        overviewActive = false
    }

    /// A card tap in the overview: jump to that pane (focus + centre) and exit the overview.
    public func selectFromOverview(_ id: PaneID) {
        overviewActive = false
        revealPane(id)
    }

    // MARK: - Explicit pane notifications (OSC 9 / OSC 777)

    /// The app's notification poster, wired after construction (the store is cross-platform headless;
    /// the `UNUserNotificationCenter` poster is macOS-app-side). Called when a pane's child requests an
    /// explicit notification (OSC 9 / OSC 777); the app posts it carrying the pane id so a click can
    /// ``revealPane(_:)``. `nil` in tests / headless ⇒ the notification is dropped (no UN dependency).
    public var onPaneNotification: ((_ paneID: PaneID, _ paneTitle: String, _ title: String, _ body: String) -> Void)?

    /// Routes a child-requested notification from pane `id` to the app poster. Internal seam — wired
    /// onto each terminal pane's connection in ``reconcile()``.
    func handlePaneNotification(id: PaneID, paneTitle: String, title: String, body: String) {
        onPaneNotification?(id, paneTitle, title, body)
    }

    /// Focuses + centres pane `id` (the notification-click reveal, and any "jump to this pane" caller).
    /// A no-op if the pane is gone (it was closed before the click).
    public func revealPane(_ id: PaneID) {
        guard workspace.canvas.contains(id) else { return }
        focus(id)
        centerOnPane(id)
    }

    /// Reveals the pane whose id string (`PaneID.raw.uuidString`) matches — the entry point for the
    /// notification-click handler, which only carries the string from `userInfo`. No-op on an
    /// unparseable / unknown id (the pane was closed).
    ///
    /// LIVE-MODEL aware (P3 fix): the canvas ``revealPane(_:)`` guards `canvas.contains` + centres, which
    /// is a NO-OP on the live TREE shell — so a clicked notification (long-command / OSC / agent-attention)
    /// would silently do nothing. Route to the tree focus path when ``liveModel`` is ``LiveModel/tree`` so
    /// the click actually switches session+tab+pane to the originating pane.
    public func revealPane(byIDString idString: String) {
        guard let uuid = UUID(uuidString: idString) else { return }
        let id = PaneID(raw: uuid)
        switch liveModel {
        case .tree: focusPaneTree(id)
        case .canvas: revealPane(id)
        }
    }

    // MARK: - Named layout presets (save / switch canvas contexts)

    /// The saved layout presets in whichever live model is current (W5, ITEM A2): the tree's under
    /// ``LiveModel/tree`` (where they are carried verbatim from v9), else the canvas's. The app-launch
    /// monitor reads THIS so its trigger scan resolves against the live model — on the tree shell the
    /// canvas presets are dead (and empty), so the monitor must not read them.
    public var liveLayoutPresets: [LayoutPreset] {
        switch liveModel {
        case .tree: tree.layoutPresets
        case .canvas: workspace.layoutPresets
        }
    }

    /// The saved layout names, in saved order — for the palette / menu listing.
    public var layoutPresetNames: [String] { workspace.layoutPresets.map(\.name) }

    /// Set when the user picks "Save Current Layout…"; the root view observes it to present a
    /// name-entry alert, then calls ``saveLayoutPreset(name:)`` and ``clearSaveLayoutRequest()``.
    public private(set) var pendingSaveLayout = false
    /// Requests the save-layout name prompt (the command-layer entry point).
    public func requestSaveLayout() { pendingSaveLayout = true }
    /// The root view consumed the request (presented / dismissed the prompt).
    public func clearSaveLayoutRequest() { pendingSaveLayout = false }

    /// Snapshots the CURRENT canvas (panes + groups + focus, ephemeral dialog panes stripped) under
    /// `name`. A re-save of an existing name OVERWRITES it (so "save monitoring" updates the layout you
    /// already have). The video bindings travel in each pane's spec, so a restored remote pane
    /// re-streams (or degrades to the picker if its window is gone). Metadata-only mutation → reconcile
    /// just persists.
    public func saveLayoutPreset(name: String, triggerAppName: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trigger = (triggerAppName?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
        // Strip ephemeral (auto-managed) panes from the snapshot — a saved layout must not resurrect a
        // dead system-dialog windowID.
        let snapshotCanvas = strippingEphemeral(workspace.canvas)
        let focus = snapshotCanvas.contains(workspace.focusedPane ?? PaneID()) ? workspace.focusedPane : snapshotCanvas
            .allIDs().first
        if let i = workspace.layoutPresets.firstIndex(where: { $0.name == trimmed }) {
            workspace.layoutPresets[i] = LayoutPreset(
                id: workspace.layoutPresets[i].id, name: trimmed,
                canvas: snapshotCanvas, groups: workspace.groups, focusedPane: focus, triggerAppName: trigger,
            )
        } else {
            workspace.layoutPresets.append(LayoutPreset(
                name: trimmed, canvas: snapshotCanvas, groups: workspace.groups,
                focusedPane: focus, triggerAppName: trigger,
            ))
        }
        reconcile() // metadata-only — persists the new preset list
    }

    /// The preset whose `triggerAppName` matches `appName` (case-insensitive), or `nil`. Pure — the
    /// app-launch matcher. Resolves from the LIVE model's presets (W5, ITEM A2).
    func presetForLaunchedApp(_ appName: String) -> LayoutPreset? {
        let lower = appName.lowercased()
        return liveLayoutPresets.first { $0.triggerAppName?.lowercased() == lower }
    }

    /// The app name whose trigger last auto-switched a layout, so the same launch (still present in the
    /// host window list across polls) doesn't re-switch every tick.
    private var lastAutoSwitchedApp: String?

    /// Auto-switches to the layout triggered by `appName` if one exists and we didn't already switch for
    /// it. Returns whether a switch happened. The monitor calls this for each NEWLY-appeared host app.
    @discardableResult
    public func autoSwitchForLaunchedApp(_ appName: String) -> Bool {
        guard lastAutoSwitchedApp?.lowercased() != appName.lowercased(),
              let preset = presetForLaunchedApp(appName) else { return false }
        lastAutoSwitchedApp = appName
        switchToLayoutPreset(name: preset.name)
        return true
    }

    /// Clears the auto-switch latch (e.g. when the triggering app's windows all close host-side), so a
    /// later relaunch can auto-switch again.
    public func clearAutoSwitchLatch(forAbsentApps absent: Set<String>) {
        if let last = lastAutoSwitchedApp, absent.contains(where: { $0.lowercased() == last.lowercased() }) {
            lastAutoSwitchedApp = nil
        }
    }

    /// Switches the live canvas to saved layout `name`: replaces the panes + groups + focus with the
    /// snapshot (KEEPING the app connection + the saved presets themselves), then reconciles — which
    /// tears down every current session and materializes the snapshot's. The pane ids are re-minted on
    /// save's `strippingEphemeral`? No — the snapshot keeps the original ids; but a switch back-and-forth
    /// would re-use ids across teardown, so the snapshot's items get FRESH ids here to avoid colliding
    /// with the live registry mid-teardown (the same rule as reopen/restore). No-op for an unknown name.
    public func switchToLayoutPreset(name: String) {
        guard let preset = workspace.layoutPresets.first(where: { $0.name == name }) else { return }
        // The preset's camera is set ABSOLUTELY below, so drop any in-flight live scroll first — else a
        // late commitScrollPan() would fold a stale relative delta onto the restored camera, jumping the
        // viewport away from the saved layout (mirrors the centerOnPane/centerOnAll/recenterIfOffscreen
        // contract; pinned by LayoutPresetTests).
        discardLiveScroll()
        // Re-mint pane ids so a switch can't collide a snapshot id with a still-tearing-down live
        // session of the same id (the async-teardown race). Group ids are kept (groups carry no session).
        var idMap: [PaneID: PaneID] = [:]
        let remintedItems = preset.canvas.items.map { item -> CanvasItem in
            let fresh = PaneID()
            idMap[item.id] = fresh
            return CanvasItem(id: fresh, spec: item.spec, frame: item.frame, z: item.z, groupID: item.groupID)
        }
        workspace.canvas = Canvas(items: remintedItems, camera: preset.canvas.camera)
        workspace.groups = preset.groups
        workspace.focusedPane = preset.focusedPane.flatMap { idMap[$0] } ?? remintedItems.first?.id
        workspace.maximizedPane = nil
        // Viewport bookmarks (⇧⌘1–9) are workspace-GLOBAL and anchor to the PREVIOUS layout's panes +
        // coordinate frame — the preset carries none. After a context swap they all dangle (their pane
        // ids are gone AND their saved camera origins are in the old frame), so recall would jump to a
        // stale coordinate. Clear them rather than mis-jump (cross-cutting hunt 2026-06-13 #1).
        workspace.bookmarks = [:]
        overviewActive = false
        // Disarm broadcast and forget the close-undo across a whole-canvas swap — a synchronized-typing
        // mode and a "reopen the pane from the OLD workspace" both make no sense in the new layout.
        setBroadcast(false)
        recentlyClosed = nil
        reseedFocusHistory() // every old pane id is re-minted — drop the now-dead quick-switch ring
        // Every old pane id is now orphaned — clear any pending request keyed to one (else a busy-close
        // confirmation or rename targeting a now-gone pane lingers as a phantom dialog, the closePane
        // contract at the top of this type). Reconcile tears the old sessions down.
        pendingClose = nil
        pendingRename = nil
        reconcile()
    }

    /// Deletes saved layout `name`. No-op if absent.
    public func deleteLayoutPreset(name: String) {
        guard workspace.layoutPresets.contains(where: { $0.name == name }) else { return }
        workspace.layoutPresets.removeAll { $0.name == name }
        reconcile()
    }

    /// A copy of `canvas` with every ephemeral (auto-managed) pane removed — the snapshot must not
    /// carry a system-dialog windowID that would stream a dead window on restore.
    private func strippingEphemeral(_ canvas: Canvas) -> Canvas {
        let ephemeral = canvas.allIDs().filter { canvas.spec(for: $0)?.kind.isEphemeral == true }
        guard !ephemeral.isEmpty else { return canvas }
        var c = canvas
        for id in ephemeral {
            c = c.removing(id) ?? Canvas(items: [], camera: canvas.camera)
        }
        return c
    }

    // MARK: - Viewport bookmarks (⇧⌘1–9 save, ⌘1–9 recall)

    /// Saves the current viewport into bookmark `slot` (1–9), named after the focused pane. The
    /// in-flight scroll pan is committed FIRST so the saved camera is what the user actually sees,
    /// not the last committed position. Records the focused pane as the recall anchor (see
    /// ``CanvasBookmark``).
    public func saveBookmark(_ slot: Int) {
        guard (1...9).contains(slot) else { return }
        commitScrollPan()
        // The LIVE shell title (OSC 0/2 when set) names the bookmark — the same source the pill and
        // sidebar show; the static spec.title is stale the moment the shell speaks.
        let name = workspace.focusedPane
            .flatMap { id -> String? in
                guard let spec = workspace.canvas.spec(for: id) else { return nil }
                return PanePresentation.displayTitle(handle(for: id), spec: spec)
            }
            ?? "Bookmark \(slot)"
        workspace.bookmarks[slot] = CanvasBookmark(
            pane: workspace.focusedPane,
            cameraOrigin: workspace.canvas.camera.origin,
            name: name,
        )
        reconcile() // metadata-only (leaf set unchanged) — reconcile just persists
    }

    /// Recalls bookmark `slot`: when its anchor pane is still on the canvas, FOLLOW it (focus +
    /// centre — live panes relocate; the raw coordinate goes stale); otherwise restore the saved
    /// camera origin. No-op for an empty slot.
    public func recallBookmark(_ slot: Int) {
        guard let bookmark = workspace.bookmarks[slot] else { return }
        if let pane = bookmark.pane, workspace.canvas.contains(pane) {
            focus(pane)
            centerOnPane(pane)
        } else {
            discardLiveScroll()
            workspace.canvas = workspace.canvas.camera(CanvasCamera(origin: bookmark.cameraOrigin))
            reconcile()
        }
    }

    // MARK: - Viewport reporting (for placement / centring / video-cap visibility)

    /// The canvas view reports its current viewport size so the store can place / centre / tidy panes
    /// without the view threading a size into every mutation. View-only state — never reconciles.
    public func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastViewport = size
    }

    /// The canvas view reports which panes currently intersect the viewport (no margin). View-only
    /// state — never reconciles. Feeds ``isPaneVisible(_:)`` (the video-cap "on screen" signal). Marks
    /// membership as reported, so a subsequently EMPTY set means "panned to the void" (release), not
    /// "no report yet" (keep).
    public func updateViewportMembership(_ ids: Set<PaneID>) {
        paneIDsInViewport = ids
        hasReportedViewport = true
    }

    /// Clears viewport membership and the reported flag — called when the canvas view DISAPPEARS (a
    /// regular→compact projection flip). Without this the compact carousel would inherit the canvas's
    /// last (stale) membership set and make wrong video-teardown decisions; clearing the flag restores
    /// the documented compact fallback to ``isPaneOnActiveTab(_:)``.
    public func clearViewportMembership() {
        paneIDsInViewport = []
        hasReportedViewport = false
    }

    /// Whether pane `id` is on the active tab AND currently inside the reported viewport — the signal
    /// the video-teardown / activation decision uses INSTEAD of ``isPaneOnCanvas(_:)`` (docs/30 §5.3).
    /// On a canvas an off-viewport pane is still "on the canvas", so the bare on-canvas guard would never
    /// free its `liveVideoCap` slot; this one does. When membership has NOT been reported (the compact
    /// carousel / pre-first-layout paths) it falls back to ``isPaneOnCanvas(_:)`` so those paths are
    /// byte-identical; once reported, an empty set means genuinely-nothing-on-screen (release).
    public func isPaneVisible(_ id: PaneID) -> Bool {
        guard isPaneOnCanvas(id) else { return false }
        return hasReportedViewport ? paneIDsInViewport.contains(id) : true
    }

    // MARK: - Reconnect (palette / recovery)

    /// Re-dials pane `id`'s connection — the recovery path for a `.failed` / `.unreachable` / dropped
    /// terminal pane (the command palette's "Reconnect Pane"). `ConnectionViewModel.connect()` already
    /// tears down the prior session and re-dials the stored `host`/`port`, so it is correct from ANY
    /// non-connected state; a no-op for a pane with no live connection (a `.remoteGUI` / faked handle).
    /// The connect runs in a detached `Task` (the store mutation surface stays synchronous), exactly as
    /// the leaf's connect-on-appear does.
    public func reconnect(_ id: PaneID) {
        // Gate on the app-global connection (docs/31): a pane channel must NOT build the shared mux while
        // the connect-gate is still up (it would come up un-pinned, leaving the gate stuck at
        // `.disconnected` with a live connection + orphan host shell behind it). The scene-level ⇧⌘R /
        // "Reconnect Pane" command is enabled before first connect, so this is the one un-gated mux-build
        // side door — close it. `nil` (tests / no app connection) ⇒ allowed, preserving headless behavior.
        if let isAppConnected, !isAppConnected() { return }
        guard let handle = registry[id], let connection = (handle as? LivePaneSession)?.connection else { return }
        // R16 WS-1: re-check on the MainActor, right before dialing, that the pane is STILL backed by the
        // SAME handle. The guard above resolves synchronously, but the dial runs in a detached Task; if
        // `closePane(id)` runs in the interim, reconcile() removes the handle and tears its
        // connection down (deliberatelyClosed = true). Without this re-check the captured `connection`'s
        // `connect()` would CLEAR deliberatelyClosed and open a fresh socket for a pane that no longer
        // exists — a live, supervised, reconnecting zombie connection stranded for a closed pane.
        Task { @MainActor [weak self] in
            guard let self, paneStillRegistered(id, as: handle) else { return }
            await connection.connect()
        }
    }

    /// Whether pane `id` is STILL backed by `handle` in the registry (reference identity). The re-check
    /// the detached ``reconnect(_:)`` Task does before dialing, so a pane removed from the registry
    /// (by a `closePane` reconcile) between the synchronous resolve and the Task running is
    /// not revived. Internal — a test seam, not part of the public store API.
    func paneStillRegistered(_ id: PaneID, as handle: any PaneSessionHandle) -> Bool {
        guard let current = registry[id] else { return false }
        return current === handle
    }

    // MARK: - Spec mutation (rename / fill endpoint)

    /// Transforms the spec of leaf `id` in place (rename, fill in an endpoint, …). The leaf set is
    /// unchanged so reconcile is a no-op — but the session already exists; re-materialization is NOT
    /// triggered by a spec edit (a live session is not rebuilt under the user). To re-point a live
    /// connection at a new endpoint, the view drives the session's connect form directly.
    public func updateSpec(_ id: PaneID, _ transform: @escaping (inout PaneSpec) -> Void) {
        guard workspace.canvas.contains(id) else { return }
        workspace.canvas = workspace.canvas.updatingSpec(id, transform)
        reconcile()
    }

    // MARK: - Video activation (cap-enforced)

    /// Requests live-video activation for `.remoteGUI` pane `id`, enforcing ``liveVideoCap`` (docs/22
    /// §7). Returns `true` if the pane is now active, `false` if the cap is already saturated by OTHER
    /// active video panes (the caller then shows the gated placeholder until a slot frees). A no-op
    /// `true` if it is already active. Non-video panes return `false`.
    @discardableResult
    public func activateVideo(_ id: PaneID) -> Bool {
        guard let handle = registry[id], handle.kind.isVideo else { return false }
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
        let activeOthers = registry.values.count(where: { $0.kind.isVideo && $0.isVideoActive && $0.id != id })
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
    /// - `AISLOPDESK_AUTOCONNECT_HOST` + `AISLOPDESK_AUTOCONNECT_PORT` ⇒ the app ``Workspace/connection`` target is
    ///   that host:port and pane 0 is a plain terminal (it rides the app connection).
    /// - `AISLOPDESK_VIDEO_AUTOCONNECT_HOST` + media/cursor ports + window id ⇒ the app target is that host
    ///   (+ video ports) and pane 0 is a `.remoteGUI` for that window (video takes precedence). Title
    ///   from `AISLOPDESK_VIDEO_AUTOCONNECT_TITLE` if set.
    /// - neither set ⇒ the plain default single-terminal workspace.
    ///
    /// The actual connect TRIGGER stays out of the store (the app auto-connects ``AppConnection`` in
    /// automation), so the env-var names stay unchanged and `check-macos.sh`/`check-video.sh` keep working.
    /// The automation inputs: the process environment overlaid with any `KEY=VALUE` launch
    /// arguments whose key begins with `AISLOPDESK_`.
    ///
    /// The env vars are the canonical seam, but a GUI-session launch cannot always inject env
    /// (e.g. `open --args …` over SSH, where there is no way to set the child's environment
    /// without root). Passing the same `AISLOPDESK_…=value` tokens as launch arguments is the
    /// equivalent; a matching argument overrides the inherited env.
    public static func automationInputs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
    ) -> [String: String] {
        var inputs = environment
        // Skip argv[0] (the executable path); a matching `AISLOPDESK_…=value` argument overrides env.
        for arg in arguments.dropFirst() {
            guard arg.hasPrefix("AISLOPDESK_"), let eq = arg.firstIndex(of: "=") else { continue }
            inputs[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
        }
        return inputs
    }

    public func bootstrapFromEnvironment(_ env: [String: String] = WorkspaceStore.automationInputs()) {
        // Resolve the single bootstrap pane spec + the app target from the autoconnect env (video first).
        let bootstrap: (spec: PaneSpec, target: ConnectionTarget)? =
            if let (target, video) = Self
                .videoTarget(from: env)
            {
                (PaneSpec(kind: .remoteGUI, title: video.title, video: video), target)
            } else if let target = Self.terminalTarget(from: env) {
                (PaneSpec(kind: .terminal, title: "Terminal"), target)
            } else {
                nil
            }
        switch liveModel {
        case .tree:
            // W5: the live tree is what the IDE shell binds, so the automation bootstrap reshapes the TREE
            // (one session/tab/leaf carrying the spec + per-session connection) and reconciles it.
            if let bootstrap {
                var session = Session.singlePane(name: bootstrap.target.host, spec: bootstrap.spec)
                session.connection = bootstrap.target
                tree = TreeWorkspace(sessions: [session], activeSessionID: session.id).normalized()
            } else {
                tree = .defaultWorkspace()
            }
            reconcileTree()
        case .canvas:
            if let bootstrap {
                workspace = Self.singleLeafWorkspace(spec: bootstrap.spec, connection: bootstrap.target)
            } else {
                workspace = .defaultWorkspace()
            }
            reconcile()
        }
    }

    /// The app target from the terminal-autoconnect env vars, or `nil`.
    static func terminalTarget(from env: [String: String]) -> ConnectionTarget? {
        guard let host = env["AISLOPDESK_AUTOCONNECT_HOST"], !host.isEmpty,
              let portStr = env["AISLOPDESK_AUTOCONNECT_PORT"], let port = UInt16(portStr) else { return nil }
        return ConnectionTarget(host: host, port: port)
    }

    /// The app target + the per-pane window from the video-autoconnect env vars, or `nil`. The terminal
    /// port defaults (the video automation only specifies UDP ports); the app target carries the host +
    /// both UDP ports so the `.remoteGUI` pane rides the shared flow.
    static func videoTarget(from env: [String: String]) -> (ConnectionTarget, VideoEndpoint)? {
        guard let host = env["AISLOPDESK_VIDEO_AUTOCONNECT_HOST"], !host.isEmpty,
              let mediaStr = env["AISLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT"], let media = UInt16(mediaStr),
              let cursorStr = env["AISLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT"], let cursor = UInt16(cursorStr),
              let widStr = env["AISLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID"], let wid = UInt32(widStr) else { return nil }
        let title = env["AISLOPDESK_VIDEO_AUTOCONNECT_TITLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "Remote window"
        let port = env["AISLOPDESK_AUTOCONNECT_PORT"].flatMap { UInt16($0) } ?? 7420
        let target = ConnectionTarget(host: host, port: port, mediaPort: media, cursorPort: cursor)
        return (target, VideoEndpoint(windowID: wid, title: title))
    }

    /// A one-pane workspace from `spec` (the bootstrap shape) with the app `connection` target. The pane
    /// id is minted fresh; the item sits at the canvas origin at the default size, focused, ungrouped.
    private static func singleLeafWorkspace(spec: PaneSpec, connection: ConnectionTarget? = nil) -> Workspace {
        let paneID = PaneID()
        let item = CanvasItem(
            id: paneID,
            spec: spec,
            frame: CGRect(origin: .zero, size: Canvas.defaultItemSize),
            z: 0,
        )
        return Workspace(canvas: Canvas(items: [item]), focusedPane: paneID, connection: connection)
    }

    // MARK: - Tree-path mutations (W4 — DORMANT; delegate to WorkspaceTreeOps, then reconcileTree)

    /// W4 (docs/42): the tree-of-intent mutation surface the store gains alongside the canvas methods.
    /// Each method applies a **pure** ``WorkspaceTreeOps`` transform (returns a new ``TreeWorkspace``) and
    /// then calls ``reconcileTree()`` to materialize/orphan the registry — the exact shape of the canvas
    /// mutations, but driven by the new model. They keep the **specs == leafIDs invariant** (the ops do)
    /// and are DORMANT: the live update loop still uses the canvas `reconcile()`, so calling these on a
    /// canvas-driven store would orphan its canvas panes — they exist for the W4 unit tests and the W5
    /// cutover. The kind is taken EXPLICITLY (`kind:`) — these methods do NOT resolve
    /// ``SettingsKey/defaultPaneKind``; it is the CALLER (the W6 command routing, as for `addPane`) that
    /// resolves the user's default before invoking them.

    /// Splits the active pane along `axis`, inserting a new leaf of `kind` (focused). Tree no-op when there
    /// is no active pane.
    public func splitActivePane(axis: SplitAxis, kind: PaneKind) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        let spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        let (next, _) = WorkspaceTreeOps.splitPane(active, axis: axis, newSpec: spec, in: tree)
        tree = next
        reconcileTree()
    }

    /// Splits the specific pane `target` along `axis`, inserting a new leaf of `kind` (focused).
    public func splitPaneTree(_ target: PaneID, axis: SplitAxis, kind: PaneKind) {
        let spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        let (next, _) = WorkspaceTreeOps.splitPane(target, axis: axis, newSpec: spec, in: tree)
        tree = next
        reconcileTree()
    }

    /// Closes pane `target` with the full cascade (collapse + rebalance; empty tab → close tab; empty
    /// session → close session unless last; last pane → re-seed a default). Reconcile tears down the
    /// removed leaves and materializes any re-seeded one.
    public func closePaneTree(_ target: PaneID) {
        // Clear a matching parked busy-close so confirming/closing the same leaf twice cannot strand a
        // phantom confirmation dialog (mirrors the canvas `closePane(_:)` `pendingClose` clear).
        if pendingClose == target { pendingClose = nil }
        tree = WorkspaceTreeOps.closePane(target, in: tree)
        reconcileTree()
    }

    /// Toggles render-only zoom on the active tab's active pane (the tree is untouched). Tree no-op when
    /// there is no active pane.
    public func toggleZoomTree() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        tree = WorkspaceTreeOps.toggleZoom(active, in: tree)
        reconcileTree()
    }

    /// Moves focus in `direction` from the active pane, resolved geometrically against the active tab
    /// solved into `bounds` (the store passes the live viewport; tests pass any finite rect).
    public func moveFocusTree(_ direction: FocusDirection, bounds: CGRect) {
        tree = WorkspaceTreeOps.moveFocus(direction, bounds: bounds, in: tree)
        reconcileTree()
    }

    /// Moves tree focus in `direction` using the bounds the active-tab view last reported via
    /// ``updateSolvedLayout(_:)`` — the keyboard / menu / command-palette entry point that has no
    /// `GeometryReader` of its own. The bounds are the union of the reported frames (the exact rect the
    /// `SplitTreeView` solved into), so a chord-driven focus move resolves against the geometry the user
    /// sees. A no-op until the view has reported a layout (the first frame), mirroring the canvas
    /// ``move(_:)`` directional no-op.
    public func moveFocusTreeUsingReportedLayout(_ direction: FocusDirection) {
        guard let solved = lastSolvedLayout, !solved.frames.isEmpty else { return }
        var bounds = CGRect.null
        for rect in solved.frames.values { bounds = bounds.union(rect) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        moveFocusTree(direction, bounds: bounds)
    }

    /// Adds a new tab (single leaf of `kind`) to the active session and selects it; materializes its leaf.
    public func newTab(kind: PaneKind) {
        let spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        let (next, _) = WorkspaceTreeOps.newTab(in: tree, spec: spec)
        tree = next
        reconcileTree()
    }

    /// Closes tab `tabID` (dropping its panes) and cascades like ``closePaneTree(_:)``.
    public func closeTab(_ tabID: TabID) {
        tree = WorkspaceTreeOps.closeTab(tabID, in: tree)
        reconcileTree()
    }

    /// Close the active tab of the active session (the ⌘⇧W "Close Tab" routing target). A no-op when
    /// there is no active tab. The tree ops cascade an emptied session / re-seed a default like
    /// `closeTab(_:)` does.
    public func closeActiveTab() {
        guard let id = tree.activeSession?.activeTab?.id else { return }
        closeTab(id)
    }

    /// Whether the sessions sidebar is collapsed (hidden). Toggled by ⌘B (Muxy parity). In-memory only —
    /// a fresh launch shows the sidebar. Observed by `SplitWorkspaceView` which drops the rail + divider
    /// when true.
    public var sidebarCollapsed: Bool = false

    /// Flip the sessions-sidebar collapsed state (the ⌘B "Toggle Sidebar" routing target).
    public func toggleSidebarCollapsed() { sidebarCollapsed.toggle() }

    /// Selects tab at `index` in the active session — a pure active-state change (the FULL leaf set stays
    /// registered; only focus follows). Reconcile is a registry no-op.
    public func selectTab(_ index: Int) {
        tree = WorkspaceTreeOps.selectTab(index, in: tree)
        reconcileTree()
    }

    /// Adds a new session (one tab, one leaf of `kind`) and selects it; materializes its leaf.
    public func newSession(name: String, kind: PaneKind) {
        let spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        let (next, _) = WorkspaceTreeOps.newSession(in: tree, name: name, spec: spec)
        tree = next
        reconcileTree()
    }

    /// Closes session `sessionID` (dropping all its tabs/panes) and selects another (or re-seeds a default
    /// when it was the last). Reconcile tears down its leaves.
    public func closeSession(_ sessionID: SessionID) {
        tree = WorkspaceTreeOps.closeSession(sessionID, in: tree)
        reconcileTree()
    }

    /// Selects session `sessionID` — a pure active-state change (the full leaf set stays registered).
    public func selectSession(_ sessionID: SessionID) {
        tree = WorkspaceTreeOps.selectSession(sessionID, in: tree)
        reconcileTree()
    }

    // MARK: - Tree mutations (W5 — the additional shell wrappers the IDE views drive)

    /// Focuses leaf `id` in the tree (sets its tab's `activePane` + selects that session/tab). The full
    /// leaf set stays registered — a pure active-state change. The IDE shell calls this on a leaf tap.
    public func focusPaneTree(_ id: PaneID) {
        guard tree.contains(id) else { return }
        let alreadyActive = tree.activeSession?.activeTab?.activePane == id
        // A focused float raises to the front of its tab's z-order (zellij/any WM raises the active float),
        // so grabbing a card that overlaps a neighbour brings it above. `raiseFloating` is a no-op for a
        // tiled / already-topmost pane, so this never churns a reconcile when nothing moves.
        let raised = WorkspaceTreeOps.raiseFloating(id, in: tree)
        let changedZOrder = raised != tree
        guard !alreadyActive || changedZOrder else { return }
        tree = WorkspaceTreeOps.focusPane(id, in: raised)
        reconcileTree()
    }

    /// Drag-resizes the divider between children `leadingChildIndex` and `leadingChildIndex + 1` of split
    /// `splitID` by `delta` (in flex-weight units, sum-preserving + clamped). The leaf set is unchanged, so
    /// the reconcile only persists. The `DividerHandle` view converts a pixel drag → a weight delta and
    /// calls this on the active tab's split.
    public func resizeDividerTree(splitID: SplitNodeID, leadingChildIndex: Int, delta: Double) {
        tree = WorkspaceTreeOps.resizeDivider(
            splitID: splitID, leadingChildIndex: leadingChildIndex, delta: delta, in: tree,
        )
        reconcileTree()
    }

    /// Ejects leaf `id` into a NEW tab of its session (Zellij/Herdr "break pane"); the source tab
    /// collapses/rebalances. No-op if it is its tab's only leaf.
    public func breakPaneToTab(_ id: PaneID) {
        tree = WorkspaceTreeOps.breakPaneToTab(id, in: tree)
        reconcileTree()
    }

    /// Renames tab `tabID`. Pure metadata — the leaf set is unchanged, so the reconcile only persists.
    public func renameTab(_ tabID: TabID, to title: String) {
        tree = WorkspaceTreeOps.renameTab(tabID, to: title, in: tree)
        reconcileTree()
    }

    /// Renames session `sessionID`. Pure metadata — the leaf set is unchanged.
    public func renameSession(_ sessionID: SessionID, to name: String) {
        tree = WorkspaceTreeOps.renameSession(sessionID, to: name, in: tree)
        reconcileTree()
    }

    // MARK: - Floating panes (P5a — zellij-style overlay scratch panes)

    /// The live viewport rect the floating layer is placed/clamped into — the union of the frames the
    /// active-tab `SplitTreeView` last reported via ``updateSolvedLayout(_:)``. Falls back to a sane default
    /// before the first layout report (so a chord fired before the view laid out still clamps sanely). The
    /// floating-frame coordinate space IS this rect (top-left origin), matching the render model.
    private var floatingViewportBounds: CGRect {
        // Prefer the TRUE container bounds the view reported (shared coordinate space with the render
        // model's place-clamp). Fall back to the leaf-union (a couple-points smaller at the gutter) then a
        // sane default before the first report.
        if let reported = lastFloatingBounds, reported.width > 0, reported.height > 0 {
            return reported
        }
        guard let solved = lastSolvedLayout, !solved.frames.isEmpty else {
            return CGRect(x: 0, y: 0, width: 1280, height: 800)
        }
        var bounds = CGRect.null
        for rect in solved.frames.values { bounds = bounds.union(rect) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1280, height: 800)
        }
        return bounds
    }

    /// Toggles the active tab's active pane between tiled and floating (the ⌘⇧F "Float Pane" entry). A
    /// no-op when there is no active pane, or when it is its tab's only tiled leaf (floating it would empty
    /// the tree — the op guards this). Reconcile keeps every leaf mounted (a float is just placed by its
    /// frame instead of a solver rect — no teardown).
    public func toggleFloatActivePane(embedAnchor: PaneID? = nil) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        let bounds = floatingViewportBounds
        // Re-use a remembered frame if the pane has floated before, else a centered default.
        let frame = tree.spec(for: active)?.floatingFrame ?? WorkspaceTreeOps.defaultFloatingFrame(in: bounds)
        tree = WorkspaceTreeOps.toggleFloating(
            active, defaultFrame: frame, bounds: bounds, embedAnchor: embedAnchor, in: tree,
        )
        reconcileTree()
    }

    /// The command/menu entry for "Float Pane" (resolves nothing extra — the toggle reads the active pane).
    public func toggleFloatActivePaneCommand() { toggleFloatActivePane() }

    /// Spawns a BRAND-NEW floating scratch pane of `kind` into the active tab (the ⌃⌘F "New Floating Pane"
    /// entry). Materialized by reconcile like any new leaf; it overlays the tiled layout centered.
    public func spawnFloatingPane(kind: PaneKind) {
        let spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        let bounds = floatingViewportBounds
        let frame = WorkspaceTreeOps.defaultFloatingFrame(in: bounds)
        let (next, _) = WorkspaceTreeOps.spawnFloating(spec, defaultFrame: frame, bounds: bounds, in: tree)
        tree = next
        reconcileTree()
    }

    /// The command/menu entry for "New Floating Pane" — resolves the user's default pane kind (Settings).
    public func spawnFloatingPaneDefault() { spawnFloatingPane(kind: SettingsKey.defaultPaneKind) }

    /// Commits a floating pane's MOVE (gesture `.onEnded`): writes the new origin (size kept), clamped into
    /// the viewport. ONE reconcile — the live drag preview is held in the view's `@GestureState`, so this
    /// never fires per-frame (keystroke/render-path safe).
    public func moveFloating(_ id: PaneID, to origin: CGPoint) {
        // A moved float raises to the front + takes focus (you grabbed it), then commits the new origin.
        let raised = WorkspaceTreeOps.focusPane(id, in: WorkspaceTreeOps.raiseFloating(id, in: tree))
        tree = WorkspaceTreeOps.moveFloating(id, to: origin, bounds: floatingViewportBounds, in: raised)
        reconcileTree()
    }

    /// Commits a floating pane's RESIZE (gesture `.onEnded`): writes the new frame, clamped + min-size
    /// floored. ONE reconcile (the live resize preview lives in the view's `@GestureState`).
    public func resizeFloating(_ id: PaneID, to frame: CGRect) {
        tree = WorkspaceTreeOps.resizeFloating(id, to: frame, bounds: floatingViewportBounds, in: tree)
        reconcileTree()
    }

    /// Closes floating pane `id` (its close/embed control's close action) — routes through the shared
    /// close path, which now drops the float from BOTH the floating layer and the spec table.
    public func closeFloating(_ id: PaneID) { closePaneTree(id) }

    /// Embeds floating pane `id` back into the tiled tree (the float's "embed" control): focuses it then
    /// toggles it back. A no-op if it is not floating.
    public func embedFloating(_ id: PaneID) {
        guard tree.spec(for: id)?.floatingFrame != nil else { return }
        // Remember the pane the user was last on (a TILED leaf) BEFORE focus moves to the float, so the
        // embedded card re-inserts next to where focus was rather than always next to the first leaf.
        let prior = tree.activeSession?.activeTab?.activePane
        let anchor = prior.flatMap { tree.spec(for: $0)?.floatingFrame == nil ? $0 : nil }
        tree = WorkspaceTreeOps.focusPane(id, in: tree)
        toggleFloatActivePane(embedAnchor: anchor)
    }

    // MARK: - Tree command-routing conveniences (W6 — the keyboard/menu/palette entry points)

    /// Splits the active pane along `axis`, inserting a leaf of the user's default kind (Settings ▸
    /// Canvas). The command/menu/palette "split right/down" entry — it resolves the default kind here, as
    /// the W4 doc notes the caller (not the dormant ops) owns the default-kind resolution.
    public func splitActivePaneDefault(axis: SplitAxis) {
        splitActivePane(axis: axis, kind: SettingsKey.defaultPaneKind)
    }

    /// Adds a tab to the active session carrying the user's default-kind leaf. The "new tab" command entry.
    public func newTabDefault() {
        newTab(kind: SettingsKey.defaultPaneKind)
    }

    /// Adds a session carrying the user's default-kind leaf, named for the next free "Session N" slot.
    /// The "new session" command entry.
    public func newSessionDefault() {
        newSession(name: defaultSessionName, kind: SettingsKey.defaultPaneKind)
    }

    /// The SINGLE source of the default new-session name (ITEM B3) — "Session N" where N is one past the
    /// current session count, so a created session is never blank. BOTH the keyboard path
    /// (``newSessionDefault()``) and the sidebar's manual "add session" footer name through THIS, so the
    /// two paths can never drift.
    public var defaultSessionName: String {
        "Session \(tree.sessions.count + 1)"
    }

    // MARK: - Launch presets (W14 #9 — Warp launch-configuration parity)

    /// The user's launch presets (built-ins + any they created), in display order. The settings / palette
    /// read this; ``applyLaunchPreset(_:)`` opens one.
    public var launchPresets: [LaunchPreset] { tree.launchPresets }

    /// Adds (or replaces, by id) a launch preset, then persists. The settings "save preset" path.
    public func upsertLaunchPreset(_ preset: LaunchPreset) {
        if let idx = tree.launchPresets.firstIndex(where: { $0.id == preset.id }) {
            tree.launchPresets[idx] = preset
        } else {
            tree.launchPresets.append(preset)
        }
        scheduleSave()
    }

    /// Removes a launch preset by id, then persists. The settings "delete preset" path.
    public func removeLaunchPreset(_ id: UUID) {
        tree.launchPresets.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Resets the launch-preset list back to the shipped built-ins (settings "reset to defaults").
    public func resetLaunchPresetsToBuiltIns() {
        tree.launchPresets = LaunchPreset.builtIns
        scheduleSave()
    }

    // MARK: - Tree-mutation seams for store extensions

    /// Replaces the live ``tree`` with `next` — the in-file mutation seam the `WorkspaceStore+Templates`
    /// extension calls (the `private(set)` setter + `private` `scheduleSave()` are not reachable from a
    /// cross-file extension, so the feature's logic lives there but touches the tree through this one
    /// internal hook). The caller is responsible for the following `reconcileTree()` / `mutateTree { … }`.
    func replaceTree(_ next: TreeWorkspace) {
        tree = next
    }

    /// Mutates the live ``tree`` in place via `transform` and schedules the debounced save — the
    /// side-collection (snippets / presets / templates) edit seam for cross-file store extensions, mirroring
    /// the launch-preset CRUD's `tree.launchPresets … ; scheduleSave()` shape so the two paths can't drift.
    func mutateTree(_ transform: (inout TreeWorkspace) -> Void) {
        transform(&tree)
        scheduleSave()
    }

    /// Applies a launch preset by id: opens a NEW TAB whose first pane runs the preset's command (and, for
    /// a two-pane preset, splits it and runs the secondary command), then types each pane's keystrokes once
    /// its PTY is live. Returns the created pane ids (for tests / the caller), or `[]` for an unknown id.
    ///
    /// The keystroke send is deferred ~1.4s after materialize (the same "let the remote prompt come up"
    /// grace the autotype path uses) — the PTY shell must be ready before the `cd`/command lands. Pure
    /// expansion is done by ``LaunchPresetEngine`` (unit-tested); the store only materializes + sends.
    @discardableResult
    public func applyLaunchPreset(_ id: UUID) -> [PaneID] {
        guard let preset = tree.launchPresets.first(where: { $0.id == id }) else { return [] }
        return applyLaunchPreset(preset)
    }

    /// Applies an explicit ``LaunchPreset`` value (used by the apply-by-id path and directly by the palette
    /// for a transient preset). See ``applyLaunchPreset(_:)`` by id for the contract.
    @discardableResult
    public func applyLaunchPreset(_ preset: LaunchPreset) -> [PaneID] {
        let plan = LaunchPresetEngine.plan(for: preset)
        guard let first = plan.panes.first else { return [] }

        // Pane 0: a new tab carrying the preset's first pane.
        let (afterTab, firstID) = WorkspaceTreeOps.newTab(in: tree, spec: first.spec)
        tree = afterTab
        var createdIDs = [firstID]

        // Pane 1 (optional): split pane 0 along the preset's axis.
        if let axis = plan.splitAxis, plan.panes.count > 1 {
            let (afterSplit, secondID) = WorkspaceTreeOps.splitPane(
                firstID, axis: axis, newSpec: plan.panes[1].spec, in: tree,
            )
            tree = afterSplit
            createdIDs.append(secondID)
        }
        reconcileTree()

        // Send each pane's keystrokes once its PTY is live (deferred — the shell prompt must come up first).
        let sends: [(PaneID, [UInt8])] = zip(createdIDs, plan.panes.map(\.keystrokes)).map { ($0, $1) }
        for (paneID, bytes) in sends where !bytes.isEmpty {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1400))
                self?.registry[paneID]?.sendBytes(bytes)
            }
        }
        return createdIDs
    }

    // MARK: - Find-in-terminal (W14 #5)

    /// Opens the ⌘F find bar over the active pane (the keyboard / menu / right-click "Find…" entry). Routes
    /// to the active terminal's ``TerminalViewModel/onRequestFind`` (set by ``TerminalScreenView``); a no-op
    /// for a non-terminal active pane or an empty shell. The find bar's PURE engine is
    /// ``TerminalSearchController`` (unit-tested).
    public func requestFindInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let live = registry[active] as? LivePaneSession else { return }
        live.terminalModel?.onRequestFind?()
    }

    /// Closes the active pane through the busy-shell guard (W6): an idle pane closes immediately (cascading
    /// the tab/session), a pane mid-command parks behind the `pendingClose` confirmation the root view
    /// hosts — mirroring the canvas ``requestClosePane(_:)``. No-op without an active pane.
    public func requestCloseActivePaneTree() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        if registry[active]?.isShellBusy == true {
            pendingClose = active
        } else {
            closePaneTree(active)
        }
    }

    /// Breaks the active pane out into a new tab of its session (the "break pane to tab" command entry).
    /// No-op without an active pane.
    public func breakActivePaneToTab() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        breakPaneToTab(active)
    }

    /// Toggles render-only zoom on the active pane (the "zoom/maximize" command entry).
    public func toggleZoomActivePane() { toggleZoomTree() }

    /// Moves (swaps) the active pane with its geometric neighbour in `direction` (Zellij "move pane"),
    /// resolved against the bounds the active-tab view last reported via ``updateSolvedLayout(_:)`` — the
    /// keyboard/menu/palette entry point that has no `GeometryReader` of its own. Mirrors
    /// ``moveFocusTreeUsingReportedLayout(_:)``: a no-op until the view has reported a layout, and a no-op
    /// when there is no neighbour on the requested side. The moved pane keeps focus (its `PaneID` is
    /// unchanged, so reconcile is a registry no-op). No-op without an active pane.
    public func swapActivePaneInDirection(_ direction: FocusDirection) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        guard let solved = lastSolvedLayout, !solved.frames.isEmpty else { return }
        var bounds = CGRect.null
        for rect in solved.frames.values { bounds = bounds.union(rect) }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        tree = WorkspaceTreeOps.movePaneInDirection(active, direction, bounds: bounds, in: tree)
        reconcileTree()
    }

    /// Resizes the active pane along `direction` by nudging the nearest enclosing split's divider
    /// (`.right`/`.down` grow it, `.left`/`.up` shrink it) — the keyboard counterpart to a drag-resize.
    /// STRUCTURAL (no geometry / solved layout needed): `.left`/`.right` act on the enclosing horizontal
    /// split, `.up`/`.down` on the enclosing vertical split. The leaf set is unchanged, so reconcile is a
    /// registry no-op. No-op without an active pane / no enclosing split. The op is sum-preserving + clamped
    /// at the min-weight floor.
    public func resizeActivePane(_ direction: FocusDirection, step: Double = 0.1) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        tree = WorkspaceTreeOps.resizeActivePane(active, direction, step: step, in: tree)
        reconcileTree()
    }

    /// Resets the active tab's split weights to an EQUAL share (tmux "select-layout even-*"), leaving any
    /// `.fixed` bands untouched. STRUCTURAL — the tree shape + leaf set are unchanged, so reconcile is a
    /// registry no-op. No-op without an active pane.
    public func balanceActivePaneSplits() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        tree = WorkspaceTreeOps.balanceSplits(activeTabContaining: active, in: tree)
        reconcileTree()
    }

    /// The cycle cursor for ``cycleLayout()`` — the last preset applied via the layout commands. UI-only
    /// (not persisted, like the palette/cheat-sheet overlay state); after a manual split/close it may no
    /// longer match the actual shape, but ``cycleLayout()`` just advances the enum deterministically, so it
    /// self-heals on the next press.
    private var lastAppliedLayout: WorkspaceTreeOps.LayoutPreset?

    /// Re-tiles the active tab's tiled tree into `preset` (tmux/zellij `select-layout`), preserving every
    /// pane `PaneID`. Un-zooms first (a re-tile under a full-screen zoom is meaningless). STRUCTURAL — the
    /// leaf set is unchanged, so reconcile materializes/tears down nothing (the no-teardown invariant; every
    /// surface stays mounted). No-op (a 0/1-leaf tab, or no active pane) leaves the tree unchanged.
    public func applyLayout(_ preset: WorkspaceTreeOps.LayoutPreset) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        tree = WorkspaceTreeOps.applyLayout(preset, activeTabContaining: active, in: tree)
        lastAppliedLayout = preset
        reconcileTree()
    }

    /// Steps the active tab through the ``WorkspaceTreeOps/LayoutPreset`` presets (the "Cycle Layout"
    /// command, ⌃⌘L), re-tiling into the next one each press. Un-zooms first. STRUCTURAL — the leaf set is
    /// unchanged (no teardown). No-op without an active pane.
    public func cycleLayout() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        let (next, applied) = WorkspaceTreeOps.cycleLayout(
            activeTabContaining: active, from: lastAppliedLayout, in: tree,
        )
        tree = next
        lastAppliedLayout = applied
        reconcileTree()
    }

    /// Selects the tab `delta` away from the active tab in the active session, clamped to the tab range
    /// (no wrap — a list stops at its ends, like the palette). The "next/prev tab" command entry. No-op
    /// without an active session.
    public func cycleTab(by delta: Int) {
        guard let session = tree.activeSession else { return }
        let count = session.tabs.count
        guard count > 1 else { return }
        let next = min(max(session.activeTabIndex + delta, 0), count - 1)
        guard next != session.activeTabIndex else { return }
        selectTab(next)
    }

    /// Selects the `number`-th tab (1-based) of the active session, if it exists. The ⌘1…⌘9 command entry;
    /// a number past the tab count is a no-op (clamps to nothing rather than the last tab — a missing tab
    /// number simply does nothing, the native ⌘N tab idiom).
    public func selectTabNumber(_ number: Int) {
        guard let session = tree.activeSession else { return }
        let index = number - 1
        guard session.tabs.indices.contains(index) else { return }
        selectTab(index)
    }

    // MARK: - Rolled-up agent status (W5 — sidebar/tab dots; W10/W11 feed it real data)

    /// The per-pane Claude status the detection signals reduce to. Defaults ``ClaudeStatus/none`` for every
    /// leaf; the W10/W11 wiring (foreground-process watch + hooks + manifest fallback) feeds real verdicts
    /// in from the `LivePaneSession`. Stored on the store so the sidebar/chrome dots have a single
    /// observable source. PRUNED to the live leaf set on every reconcile (review #10/#13) — in the same
    /// shared diff core as the `selectedPanes` / `nativeFrameSize` caches — so a closed pane's entry drops
    /// out (no unbounded growth, no dead-pane status surfacing in a rollup).
    public internal(set) var paneAgentStatus: [PaneID: ClaudeStatus] = [:]

    /// The per-pane host-provided agent LABEL (the type-27 `label`: the blocking prompt / last assistant
    /// line) — the genuinely cheap, host-trusted activity summary the sidebar shows under the session name
    /// (P3 piece 5). No scrollback access, no LLM, no round-trip; it is carried verbatim on the wire and
    /// captured here. PRUNED to the live leaf set alongside ``paneAgentStatus`` (reconcileRegistry) so a
    /// closed pane's label drops out. An empty / whitespace label is treated as absent (no key).
    public internal(set) var paneAgentLabel: [PaneID: String] = [:]

    /// The COALESCING memory for the attention notification (P3 piece 3): the last status we fired an
    /// attention edge for, per pane. So a flap that re-enters the same attention state (`done → working →
    /// done`) does not re-notify — only a transition INTO `needsPermission`/`done` from the last-notified
    /// state fires. PRUNED with `paneAgentStatus` so a recycled / closed pane id can't leak or mis-flap.
    var lastNotifiedStatus: [PaneID: ClaudeStatus] = [:]

    /// The THIN attention-notification sink (P3 piece 3 — the same seam shape as ``onLongCommandNotify`` /
    /// ``onPaneNotification``): the app shell sets it to call `explicitNotifier.notifyExplicit(...)` on a
    /// needsPermission/done EDGE. Kept off the store so `UNUserNotificationCenter` never enters the store
    /// (→ the edge logic stays headless-testable with a spy). `nil` in tests / headless / iOS ⇒ dropped.
    /// `needsInput == true` for `.needsPermission` (blocked), `false` for `.done`. `detail` is the cheap
    /// host label (the blocking line) when present.
    public var onAgentAttention: ((_ paneIDKey: String, _ name: String, _ needsInput: Bool, _ detail: String?) -> Void)?

    // setAgentStatus + the agent-status reads/rollups/edge live in `WorkspaceStore+Attention.swift`
    // (keeping this class under the type-body-length ceiling). The stored `paneAgentStatus` /
    // `paneAgentLabel` / `lastNotifiedStatus` / `onAgentAttention` stay here because `@Observable`
    // synthesises on them.

    // MARK: - Background-pane command-completion awareness (B3 — badge + focus-gated notify)

    /// The per-pane "a command finished while you were elsewhere" badge: a green ✓ / red ✗ a BACKGROUND
    /// pane carries until you look at it (mirrors ``paneAgentStatus``). Set only for an UNFOCUSED pane,
    /// cleared when the pane gains focus (or the app returns active). PRUNED to the live leaf set on every
    /// reconcile alongside ``paneAgentStatus`` so a closed pane's entry drops out (no unbounded growth).
    /// `internal(set)` (not `private(set)`) so the badge mutators in `WorkspaceStore+Completion.swift` (a
    /// same-module extension in another file) can write it; still read-only to other modules.
    public internal(set) var panePendingCompletion: [PaneID: PaneCompletionBadge] = [:]

    /// Whether the app is foregrounded/active — fed from the SwiftUI `scenePhase` by the app shell
    /// (`.active → true`, else `false`). Defaults `true` so a headless store (tests) treats the active
    /// leaf as focused. Combined with the active-leaf identity it forms the "is this pane focused" gate
    /// used by both the badge and the long-command notification.
    public var isAppActive: Bool = true {
        didSet {
            // Returning to active means you are now looking at the focused leaf — clear its pending badge.
            if isAppActive, !oldValue { clearActiveLeafCompletionBadge() }
        }
    }

    /// The THIN long-command notification sink (the B3 delivery seam): the app sets it to call
    /// `notifier.notifyIfLong(...)`. Kept off the store so `UNUserNotificationCenter` never enters the
    /// store (→ the focus-gated handler stays unit-testable with a spy). `nil` in tests / headless ⇒ the
    /// notification is dropped (the badge still updates). Carries the pane id STRING so a click reveals it.
    public var onLongCommandNotify: ((
        _ paneIDKey: String,
        _ paneTitle: String,
        _ exitCode: Int32?,
        _ durationMS: UInt32,
    ) -> Void)?

    // The badge query/setter/rollup methods + the focus-gated `handleCommandCompleted` handler live in
    // `WorkspaceStore+Completion.swift` (keeping this class under the type-body-length ceiling, like the
    // WB2/WB3 block ops). The stored properties stay here because `@Observable` synthesises on them.

    // MARK: - reconcileTree (W4 seam → W5 LIVE path)

    /// The tree-driven counterpart of ``reconcile()`` (W4 seam, promoted to the LIVE path in W5), diffing
    /// the desired leaf set `tree.allPaneIDs()` against the `[PaneID: any PaneSessionHandle]` registry. It
    /// delegates the whole load-bearing diff to the shared ``reconcileRegistry(desiredLeafIDs:spec:onMaterialize:)``
    /// — the exact same orphan-remove-then-teardown, `tearingDownVideo` ceiling-accounting, per-pane cache
    /// pruning, and `makeSession`/`adopt(id:)` materialize the canvas path uses — but sourced from ``tree``
    /// and resolving each spec via `tree.spec(for:)`.
    ///
    /// W5: it now wires the SAME per-leaf side effects the canvas `reconcile()` does (pane-rebind /
    /// `onEndpointCommitted`, OSC-9 `onExplicitNotification`), marks the autotype target, syncs the focus
    /// coordinator to the TREE's active pane, and schedules the debounced save — so the tree is a complete
    /// live reconcile. These are all inert for the dormant-tree unit tests (`FakePaneSession` is not a
    /// `LivePaneSession`, and those stores carry no `persistence`), so the W4 tree-reconcile suite still
    /// pins the bare diff. Idempotent.
    public func reconcileTree() {
        reconcileRegistry(
            desiredLeafIDs: tree.allPaneIDs(),
            spec: { tree.spec(for: $0) },
            onMaterialize: { [weak self] id, handle in
                self?.wireMaterializedLeaf(id: id, handle: handle)
            },
        )
        // Mark the AISLOPDESK_AUTOTYPE target (the first leaf in DFS order) + sync the focus coordinator to
        // the tree's active pane (the iPad-regular first-responder arbiter), then debounce-save. Mirrors the
        // canvas `reconcile()` tail; the model-aware save persists the tree (see `scheduleSave`).
        let autotypeTarget = tree.allPaneIDs().first
        for (id, handle) in registry {
            (handle as? LivePaneSession)?.isAutotypeTarget = (id == autotypeTarget)
        }
        if let focused = tree.activeSession?.activeTab?.activePane, focusCoordinator.focusedPane != focused {
            focusCoordinator.focus(focused)
        }
        // B3: a pane that just gained focus (selectTab / selectSession / focusPaneTree all route here)
        // is now being watched — clear its pending command-completion badge.
        clearActiveLeafCompletionBadge()
        scheduleSave()
    }

    /// The per-new-leaf wiring the live reconcile runs for a materialized ``LivePaneSession`` — factored
    /// out of the canvas `reconcile()`'s `onMaterialize` closure so the tree path (W5) and the canvas path
    /// run the IDENTICAL pane-rebind + OSC-9 wiring (no second copy to drift). A no-op for a fake handle.
    private func wireMaterializedLeaf(id: PaneID, handle: any PaneSessionHandle) {
        // PANE REBIND: persist every committed video endpoint into the pane's spec so a relaunch
        // re-streams the bound window instead of re-showing the picker. The leaf set is unchanged by the
        // spec update, so the nested reconcile is a no-op + save. The title follows the binding only
        // while it was tracking the previous binding (a user rename survives re-picks).
        if let model = (handle as? LivePaneSession)?.remoteWindow {
            model.onEndpointCommitted = { [weak self] endpoint in
                self?.updateSpecLive(id) { spec in
                    if spec.video == nil || spec.title == spec.video?.title {
                        spec.title = endpoint.title
                    }
                    spec.video = endpoint
                }
            }
        }
        // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777): route a terminal pane's child-requested notification
        // to the app poster, tagged with this pane id so a click reveals it.
        let connection = (handle as? LivePaneSession)?.connection
        connection?.onExplicitNotification = { [weak self] paneTitle, title, body in
            self?.handlePaneNotification(id: id, paneTitle: paneTitle, title: title, body: body)
        }
        // CLAUDE AUTO-DETECT (W11): fold the agent-detection wire signals (types 26/27) into this pane's
        // ClaudeStatusMachine and mirror the result into `paneAgentStatus` (→ the sidebar/tab/chrome dots).
        connection?.onAgentSignal = { [weak self] event in
            self?.handleAgentSignal(id: id, event: event)
        }
        // B3 BACKGROUND-PANE COMMAND-COMPLETION: route a finished command (OSC 133;D, type 23) to the
        // focus-gated store handler — badges an UNFOCUSED pane (✓/✗) and fires the long-command
        // notification only when backgrounded (replaces the old direct notifier.notifyIfLong in the VM).
        connection?.onCommandCompleted = { [weak self] exitCode, durationMS in
            guard let self else { return }
            let title = tree.spec(for: id)?.title ?? ""
            handleCommandCompleted(id: id, exitCode: exitCode, durationMS: durationMS, paneTitle: title)
        }
        // LIVE TITLE PERSISTENCE (Goal A): persist the shell's live OSC title into lastKnownTitle so a
        // relaunch can restore the tab title for untouched (default-titled) panes. The dirty guard avoids
        // a needless reconcile + save when the title didn't actually change.
        connection?.onTitleChanged = { [weak self] title in
            self?.updateSpecLive(id) { spec in
                guard spec.lastKnownTitle != title else { return }
                spec.lastKnownTitle = title
            }
        }
        // RESUME IDENTITY CAPTURE (AISLOPDESK_DETACH_ENABLED): persist the live session UUID +
        // highest-contiguous-seq into the spec on each RTT snapshot (~3 s cadence) and on reconnect
        // so the next launch can feed them into seedResumeIdentity → RETURNING_CLIENT reattach.
        connection?.onResumeIdentitySnapshot = { [weak self] sessionID, seq in
            self?.updateSpecLive(id) { spec in
                guard spec.resumeSessionID != sessionID || spec.resumeLastReceivedSeq != seq else { return }
                spec.resumeSessionID = sessionID
                spec.resumeLastReceivedSeq = seq
            }
        }
        // SYNC-INPUT (tree path, Zellij ToggleActiveSyncTab): when the per-tab sync flag is on, mirror this
        // pane's keystrokes into every other pane in its tab via the same broadcastTap seam the canvas
        // broadcast path uses. The `fanSyncInput` guard (shared `isFanningBroadcast` flag) prevents a
        // sibling's re-entrant sendInput from looping back into another fan-out. A no-op while disarmed.
        let terminal = (handle as? LivePaneSession)?.terminalModel
        terminal?.broadcastTap = { [weak self] data in self?.fanSyncInput(from: id, data) }
        // WB3 BOOKMARKS: seed the pane's block model from persistence + wire its change closure to persist
        // back (the helper lives in WorkspaceStore+Blocks so this body stays under the lint ceiling).
        seedBlockBookmarks(id: id, handle: handle)
    }

    /// Folds one Claude-Code agent-detection event (wire types 26/27) for pane `id` into the owning
    /// ``LivePaneSession``'s state machine, then mirrors the new ``ClaudeStatus`` into ``paneAgentStatus``
    /// so the sidebar/tab/chrome ``AgentStatusDot``s light up live (the auto-detect payoff, W11). The
    /// session owns the dedupe + the dynamic inspector open/close; `setAgentStatus` is itself idempotent.
    private func handleAgentSignal(id: PaneID, event: AislopdeskClient.Event) {
        guard let session = registry[id] as? LivePaneSession else { return }
        let status = session.feedAgentSignal(event)
        // CAPTURE the cheap host-provided label (the type-27 blocking prompt / last line) for the sidebar
        // activity summary (P3 piece 5) — set BEFORE setAgentStatus so an attention edge's notification
        // detail reads the fresh label. type 26 carries no label, so only type 27 updates it.
        if case let .claudeStatus(_, _, label) = event {
            setAgentLabel(label, for: id)
        }
        setAgentStatus(status, for: id)
    }

    /// Updates the spec for `id` in whichever live model is active (W5): the tree's side table when
    /// ``liveModel`` is ``LiveModel/tree``, else the canvas. Used by the shared pane-rebind wiring so a
    /// committed endpoint persists into the right model.
    private func updateSpecLive(_ id: PaneID, _ transform: @escaping (inout PaneSpec) -> Void) {
        switch liveModel {
        case .tree:
            tree = WorkspaceTreeOps.updatingSpec(id, in: tree, transform)
            reconcileTree()
        case .canvas:
            updateSpec(id, transform)
        }
    }

    // MARK: - reconcileRegistry (the shared, leaf-source-agnostic diff core)

    /// The leaf-source-agnostic core BOTH ``reconcile()`` (canvas) and ``reconcileTree()`` (tree) share, so
    /// the subtlest store logic — orphan detection/removal, the ``liveVideoCap`` ceiling-accounting
    /// (`tearingDownVideo` / `videoPromotionGeneration` / the `videoTeardownSettle` teardown `Task`), the
    /// per-pane cache pruning (`selectedPanes` / `nativeFrameSize`), and materialize-via-`makeSession` +
    /// `adopt(id:)` — exists ONCE rather than in two hand-synced copies (the W4 review's maintenance
    /// hazard). The caller supplies the desired leaf id list (`desiredLeafIDs`, in canonical order) and a
    /// `spec(for:)` lookup; an optional `onMaterialize` runs the caller's per-new-leaf side wiring (the
    /// canvas path's pane-rebind / OSC-9 closures). After it returns:
    ///
    ///   `Set(registry.keys) == Set(desiredLeafIDs)`
    ///
    /// Steps, in the exact order the canvas path historically ran them (see ``reconcile()``'s doc for the
    /// full rationale — prune caches, then orphan-remove synchronously + launch the tracked teardown,
    /// then materialize):
    /// 1. **Prune per-pane caches** to the live leaf set (so a closed/switched-away pane drops out of the
    ///    multi-selection and the native-size cache cannot grow unbounded).
    /// 2. **Orphan removal (synchronous) + teardown (async, launched not awaited)** — removing the
    ///    registry entry synchronously so the `keys == leafIDs` invariant holds the instant this returns;
    ///    the ceiling-accounting for an orphan that was holding a live video stack (`tearingDownVideo` +
    ///    the close-time / completion-site `videoPromotionGeneration` nudges + the `videoTeardownSettle`
    ///    hold) is identical to before.
    /// 3. **Materialize new leaves** — `makeSession(spec)` + `adopt(id:)` per new leaf, then run
    ///    `onMaterialize` so the caller can wire that handle.
    private func reconcileRegistry(
        desiredLeafIDs: [PaneID],
        spec: (PaneID) -> PaneSpec?,
        onMaterialize: ((PaneID, any PaneSessionHandle) -> Void)? = nil,
    ) {
        let leafSet = Set(desiredLeafIDs)

        // 1. Prune the multi-selection to live panes (a closed/switched-away pane drops out) so the Arrange
        //    ops and the group drag never reference a ghost. Cheap small-set intersection.
        if !selectedPanes.isEmpty, !selectedPanes.isSubset(of: leafSet) {
            selectedPanes.formIntersection(leafSet)
        }
        // Evict cached native sizes for panes that are gone (else the dict grows unbounded across a
        // long session of open/close — the round-2 review's leak).
        if !nativeFrameSize.isEmpty {
            nativeFrameSize = nativeFrameSize.filter { leafSet.contains($0.key) }
        }
        // Prune the per-pane agent status for orphaned panes (review #10/#13): like the sibling caches
        // above, a closed pane's `paneAgentStatus` entry must drop out — an absent key reads `.none`, but
        // without this the dict grew unbounded across a long session of open/close AND a recycled-id-free
        // stale entry could surface a dead pane's status in a rollup. Prune in the same place the other
        // per-pane caches are pruned (the shared diff core).
        if !paneAgentStatus.isEmpty {
            paneAgentStatus = paneAgentStatus.filter { leafSet.contains($0.key) }
        }
        // Prune the per-pane agent label + the attention-notify coalescing memory in lockstep with the
        // status above (P3): a closed pane must not keep a stale sidebar summary, and a recycled pane id
        // must re-arm cleanly so the next genuine edge notifies (no leak, no mis-flap on a reused id).
        if !paneAgentLabel.isEmpty {
            paneAgentLabel = paneAgentLabel.filter { leafSet.contains($0.key) }
        }
        if !lastNotifiedStatus.isEmpty {
            lastNotifiedStatus = lastNotifiedStatus.filter { leafSet.contains($0.key) }
        }
        // Prune the per-pane completion badge for orphaned panes (same leak/stale-rollup hazard as the
        // agent status above — a closed pane must not keep a ✓/✗ in a rollup).
        if !panePendingCompletion.isEmpty {
            panePendingCompletion = panePendingCompletion.filter { leafSet.contains($0.key) }
        }

        // 2. Orphans: remove from the registry synchronously (the registry is the source of truth for
        //    "what is live"), then drive teardown. Removing first guarantees the invariant holds the
        //    instant reconcile returns, even though teardown's async cleanup completes slightly after.
        let orphans = registry.filter { !leafSet.contains($0.key) }.map(\.value)
        for orphan in orphans {
            registry.removeValue(forKey: orphan.id)
            // Hold the cap slot for an orphan that is STILL holding a live video stack (ITEM #3). Read
            // `isVideoActive` NOW, before the async teardown nils it, and record the id so
            // `activateVideo` keeps counting it until its teardown task actually releases the resources.
            if orphan.kind.isVideo, orphan.isVideoActive {
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
                    // FIX #4: for a `.remoteGUI` orphan that was holding a live stack, `teardown()`
                    // only KICKS OFF the release — it sets `RemoteWindowModel.active = nil`, and the
                    // actual UDP/VTDecompression/display-link teardown happens a few runloop turns
                    // later inside the SwiftUI dismantle → `VideoWindowPipeline.deactivate()` →
                    // detached `session.stop()`. Hold the cap slot for `videoTeardownSettle` past
                    // `teardown()` so a same-tick sibling cannot be admitted while the old stack is
                    // still up (transient cap+1). Only entered for an id actually IN `tearingDownVideo`
                    // (a `.remoteGUI` pane that was live) and only when a settle is configured, so the
                    // terminal-only / `.zero`-settle paths are unaffected. The sleep is cancel-safe.
                    if self.tearingDownVideo.contains(orphan.id), self.videoTeardownSettle > .zero {
                        try? await Task.sleep(for: self.videoTeardownSettle)
                    }
                    // The orphan's video resources are now released — stop counting it against the cap
                    // (ITEM #3). Serialized on the main actor with `activateVideo`'s read, so a
                    // same-tick reopen sees the slot freed only after the real release.
                    if self.tearingDownVideo.remove(orphan.id) != nil {
                        // COMPLETION-SITE nudge (VIDEO-UI-1): the close-time bump (above) fired while
                        // this slot was STILL counted against the cap, so a same-tick gated reopen was
                        // refused and is now parked on the "Video paused" placeholder. Removing the id
                        // here is the instant the slot ACTUALLY frees — nudge again so that gated
                        // on-screen pane re-attempts admission now, instead of waiting for an unrelated
                        // event (another deactivate / re-appear) to happen to nudge it.
                        self.videoPromotionGeneration &+= 1
                    }
                }
                self.teardownTasks.removeValue(forKey: id)
            }
        }

        // 3. New leaves: materialize an idle session for each, binding its identity to the leaf id, then
        //    let the caller wire it (the canvas path's pane-rebind / OSC-9 closures).
        for id in desiredLeafIDs where registry[id] == nil {
            guard let spec = spec(id) else { continue }
            let handle = makeSession(spec)
            (handle as? PaneSessionIDAdopting)?.adopt(id: id)
            registry[id] = handle
            onMaterialize?(id, handle)
        }
    }

    // MARK: - reconcile (the single audited seam)

    /// The load-bearing diff (docs/22 §2.3). Idempotent. After it runs:
    ///
    ///   `Set(registry.keys) == Set(workspace.canvas.allIDs())`
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
        // W5 SAFETY: when the LIVE model is the tree, the canvas is retained-but-dead and its `reconcile()`
        // must NEVER run — it diffs the SAME registry against the (default, dead) canvas leaf set, which
        // would orphan + tear down every TREE-materialized handle. The remaining live callers of the
        // canvas mutations (the system-dialog monitor / notification reveal, deferred to a later item) thus
        // become no-ops on the tree shell rather than corrupting the live registry. The tree path uses
        // `reconcileTree()`. (On a `.canvas` store this is a pure passthrough.)
        guard liveModel == .canvas else { return }
        // Steps 1+2 (cache pruning, orphan-remove-then-teardown, materialize) are the shared, leaf-source
        // agnostic core. The canvas path supplies its leaf source + spec lookup, and wires every NEW leaf
        // via `onMaterialize` (pane-rebind + OSC-9). The canvas-ONLY side effects (autotype target / focus
        // coordinator / debounced save) stay below, so reconcile's observable behavior is unchanged.
        reconcileRegistry(
            desiredLeafIDs: allLeafIDs(),
            spec: { spec(for: $0) },
            onMaterialize: { [weak self] id, handle in
                guard let self else { return }
                // PANE REBIND (2026-06-12): persist every committed video endpoint into the pane's
                // spec. Until now a picked window lived only in the RemoteWindowModel — the spec kept
                // `video: nil`, so a relaunch always re-showed the picker; and a REBOUND endpoint
                // (stale CGWindowID re-resolved by app+title) must overwrite the stale id. The leaf
                // set is unchanged by `updateSpec`, so the nested reconcile is a no-op + save. The
                // pane TITLE follows the binding only while it was tracking the previous binding
                // (or was never bound) — a user rename survives re-picks.
                if let model = (handle as? LivePaneSession)?.remoteWindow {
                    model.onEndpointCommitted = { [weak self] endpoint in
                        self?.updateSpec(id) { spec in
                            if spec.video == nil || spec.title == spec.video?.title {
                                spec.title = endpoint.title
                            }
                            spec.video = endpoint
                        }
                    }
                }
                // EXPLICIT NOTIFICATIONS (OSC 9 / OSC 777): route a terminal pane's child-requested
                // notification to the app poster, tagged with this pane id so a click reveals it.
                let connection = (handle as? LivePaneSession)?.connection
                connection?.onExplicitNotification = { [weak self] paneTitle, title, body in
                    self?.handlePaneNotification(id: id, paneTitle: paneTitle, title: title, body: body)
                }
                // CLAUDE AUTO-DETECT (W11): same agent-signal fold as the tree path's `wireMaterializedLeaf`.
                connection?.onAgentSignal = { [weak self] event in
                    self?.handleAgentSignal(id: id, event: event)
                }
                // B3 BACKGROUND-PANE COMMAND-COMPLETION: same focus-gated completion route as the tree path.
                connection?.onCommandCompleted = { [weak self] exitCode, durationMS in
                    guard let self else { return }
                    let title = spec(for: id)?.title ?? ""
                    handleCommandCompleted(id: id, exitCode: exitCode, durationMS: durationMS, paneTitle: title)
                }
                // LIVE TITLE PERSISTENCE (Goal A, canvas path): same lastKnownTitle wire as wireMaterializedLeaf.
                connection?.onTitleChanged = { [weak self] title in
                    self?.updateSpecLive(id) { spec in
                        guard spec.lastKnownTitle != title else { return }
                        spec.lastKnownTitle = title
                    }
                }
                // RESUME IDENTITY CAPTURE (canvas path): same wire as wireMaterializedLeaf.
                connection?.onResumeIdentitySnapshot = { [weak self] sessionID, seq in
                    self?.updateSpecLive(id) { spec in
                        guard spec.resumeSessionID != sessionID || spec.resumeLastReceivedSeq != seq else { return }
                        spec.resumeSessionID = sessionID
                        spec.resumeLastReceivedSeq = seq
                    }
                }
            },
        )

        // 3. Mark the `AISLOPDESK_AUTOTYPE` target (docs/22 §7): the first pane on the canvas. The store owns
        //    the tree, so it is the authority on "pane0"; the terminal leaf reads this flag after connect
        //    to fire the OUT-path proof. Recomputed every reconcile so the flag follows the canvas (a
        //    reshape never strands it on a stale pane).
        let autotypeTarget = workspace.canvas.allIDs().first
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

    /// Points the ``focusCoordinator`` at the focused pane. Called at the end of every reconcile so the
    /// iPad-regular input focus follows the tree's intent. Guarded — only re-mints a generation when the
    /// target actually changed, so a no-op reconcile (resize / move) does not churn. On a single
    /// always-mounted canvas a pane's host never unmounts/re-registers, so the old tab-switch
    /// `reassertFocus` path (BUG-K) is no longer needed.
    private func syncFocusCoordinator() {
        guard let focused = workspace.focusedPane else { return }
        if focusCoordinator.focusedPane != focused {
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
    /// The workspace as it should be PERSISTED: ephemeral (auto-managed) panes — the system-dialog
    /// overlays — are stripped so they never survive a relaunch (the monitor re-spawns the live ones on
    /// reconnect). A stale dialog windowID restored next launch would otherwise stream a dead window.
    /// Focus is re-normalized in case it pointed at a stripped pane. Identity passthrough when there are
    /// none (the common case), so a normal save pays nothing.
    private func persistableWorkspace() -> Workspace {
        let ephemeral = workspace.canvas.allIDs().filter { workspace.canvas.spec(for: $0)?.kind.isEphemeral == true }
        guard !ephemeral.isEmpty else { return workspace }
        var w = workspace
        for id in ephemeral {
            w.canvas = w.canvas.removing(id) ?? Canvas(items: [], camera: w.canvas.camera)
        }
        return w.normalizingFocus()
    }

    /// W5: the value snapshot the debounced/immediate save writes — the v10 ``TreeWorkspace`` when
    /// ``liveModel`` is ``LiveModel/tree`` (the live app), else the retained-but-dead canvas
    /// ``persistableWorkspace()``. Captured as an enum so the one off-main write path stays a single
    /// `persistence.save(...)` (an overload resolves the type). Both are value types (Sendable).
    private enum SaveSnapshot {
        case canvas(Workspace)
        case tree(TreeWorkspace)
    }

    /// The PERSISTABLE snapshot of the live model right now (ephemeral dialog panes are a canvas-only
    /// concept, stripped there; the tree never holds ephemeral system-dialog leaves in the MVP).
    private func persistableSnapshot() -> SaveSnapshot {
        switch liveModel {
        case .tree: .tree(tree)
        case .canvas: .canvas(persistableWorkspace())
        }
    }

    /// Writes a snapshot through the model-appropriate ``WorkspacePersistence`` overload.
    private static func write(_ snapshot: SaveSnapshot, to persistence: WorkspacePersistence) throws {
        switch snapshot {
        case let .canvas(w): try persistence.save(w)
        case let .tree(t): try persistence.save(t)
        }
    }

    private func scheduleSave() {
        guard savingEnabled, let persistence else { return }
        saveTask?.cancel()
        // Snapshot the (Sendable, value-typed) PERSISTABLE live model now (ephemeral dialog panes stripped
        // on the canvas path) so the write reflects this mutation.
        let snapshot = persistableSnapshot()
        let debounce = saveDebounce
        saveGeneration &+= 1
        let generation = saveGeneration
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return // superseded by a newer mutation (cancelled) — that one will write.
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
                guard let self, isCurrentSaveGeneration(generation) else { return }
                // A failed save keeps the previous good file (best-effort).
                try? Self.write(snapshot, to: persistence)
                saveTask = nil
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
        try? Self.write(persistableSnapshot(), to: persistence)
    }

    // MARK: - Tree lookups

    /// The spec for pane `id` on the canvas, or `nil`.
    private func spec(for id: PaneID) -> PaneSpec? {
        workspace.canvas.spec(for: id)
    }

    /// Whether the app-global connection is up — set by the app shell after construction so the store can
    /// gate the scene-level "Reconnect Pane" command before the first connect (else ⇧⌘R would build the
    /// shared mux behind the connect-gate). `nil` in tests / headless ⇒ no gating (the prior behavior).
    public var isAppConnected: (@MainActor () -> Bool)?

    /// Commits the app-global connection ``ConnectionTarget`` into the persisted ``Workspace/connection``
    /// (called by ``AppConnection/onTargetCommitted`` on a successful connect) so the connect-gate
    /// prefills the last-used host next launch. Debounced-saves like any other mutation.
    public func commitConnectionTarget(_ target: ConnectionTarget) {
        switch liveModel {
        case .canvas:
            guard workspace.connection != target else { return }
            workspace.connection = target
        case .tree:
            // W5: stamp the target onto the active session (the per-session host seam; MVP all sessions
            // share the one AppConnection, so this is the prefill source for the gate next launch).
            guard let sIdx = tree.activeSessionIndex, tree.sessions[sIdx].connection != target else { return }
            tree.sessions[sIdx].connection = target
        }
        scheduleSave()
    }

    /// Whether `id` is the SOLE pane on the canvas — so closing it empties the workspace (the "Add a
    /// pane" empty state). Lets the pane chrome label the close button honestly.
    public func isOnlyLeaf(_ id: PaneID) -> Bool {
        workspace.canvas.contains(id) && workspace.canvas.itemCount == 1
    }

    /// A neighbour to refocus on after closing `id`, resolved geometrically against the last solved
    /// layout if available, else the predecessor/successor in canonical ``Canvas/allIDs()`` order.
    /// Best-effort.
    private func neighbourForRefocus(of id: PaneID) -> PaneID? {
        if let solved = lastSolvedLayout, solved.frames[id] != nil {
            // Prefer a real geometric neighbour (right, then left, then any reading-order sibling).
            for dir in [FocusDirection.right, .left, .down, .up] {
                if let n = FocusResolver.neighbor(of: id, dir, in: solved), n != id { return n }
            }
        }
        let ids = workspace.canvas.allIDs()
        guard let i = ids.firstIndex(of: id) else { return nil }
        if i + 1 < ids.count { return ids[i + 1] }
        if i - 1 >= 0 { return ids[i - 1] }
        return nil
    }

    // MARK: - Titles

    private func defaultTitle(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: "Terminal"
        case .remoteGUI: "Remote window"
        case .systemDialog: "System dialog"
        }
    }
}

// MARK: - Production session factory

public extension WorkspaceStore {
    /// The production `makeSession` factory: wires ``LivePaneSession`` with a mux-backed client
    /// factory and an inspector builder. The app passes `WorkspaceStore.liveMakeSession(...)` as
    /// `makeSession` so tests can substitute `{ FakePaneSession($0) }` instead (docs/22 §0).
    ///
    /// - Parameters:
    ///   - makeInspector: builds the read-only `InspectorClient` for a terminal endpoint (subscribed
    ///     dynamically once a `claude` is detected, W11), or `nil` when no second channel is available.
    ///     Defaults to ``liveMakeInspector(_:)`` — a lazily-connecting NWConnection #2 client (see
    ///     that function for the unproven-host guardrail).
    ///   - muxRegistry: the per-host shared-connection pool. Every `AislopdeskClient` is backed by a
    ///     logical channel over the per-host shared `MuxNWConnection` (refcounted by the registry).
    static func liveMakeSession(
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient? = liveMakeInspector,
        muxRegistry: ConnectionRegistry,
        target: @escaping @MainActor () -> ConnectionTarget = { .default },
    ) -> @MainActor (PaneSpec) -> any PaneSessionHandle {
        // Every pane is backed by a logical channel over the per-host shared `MuxNWConnection`
        // (refcounted by the registry), connecting to the ONE app-global `target`. This is the SOLE
        // client-side construction site; nothing on the per-message path is touched.
        let effectiveMakeClient = muxBackedClientFactory(registry: muxRegistry)
        return { spec in
            LivePaneSession.make(spec, makeClient: effectiveMakeClient, makeInspector: makeInspector, target: target)
        }
    }

    /// Builds a `@Sendable () -> AislopdeskClient` whose clients route over the shared mux connection
    /// pooled by `registry`. Each `AislopdeskClient` is constructed with an injected `makeTransport` that
    /// vends a fresh `MuxClientTransport` bound to the registry's acquire/release — so the channel is
    /// opened on the shared connection at `connect()` and released (refcount--) at `close()`, with
    /// the shared transport torn down only when the LAST pane's channel goes. The registry is
    /// `@MainActor`; the transport's acquire/release closures hop onto the main actor to call it.
    private static func muxBackedClientFactory(
        registry: ConnectionRegistry,
    ) -> @Sendable () -> AislopdeskClient {
        { @Sendable in
            AislopdeskClient(makeTransport: {
                MuxClientTransport(
                    acquire: { host, port, sessionID, lastReceivedSeq in
                        try await registry.acquire(
                            host: host, port: port, sessionID: sessionID, lastReceivedSeq: lastReceivedSeq,
                        )
                    },
                    release: { host, port, channelID in
                        await registry.release(host: host, port: port, channelID: channelID)
                    },
                )
            })
        }
    }

    /// The wire-protocol convention for a pane's inspector second channel (docs/16, docs/20 §0): the
    /// inspector's NWConnection #2 rides the **same NetBird tunnel** beside the terminal PTY, on the
    /// terminal port **+ 1**. Documented + isolated here so it is the single place to revise if the
    /// host ever advertises a distinct inspector port. Saturates at `UInt16.max` (a terminal on the
    /// top port has no room above it — the inspector is then unavailable, handled by the `nil` path).
    static let inspectorPortOffset: UInt16 = 1

    /// The inspector port for the app ``ConnectionTarget`` (the `+ inspectorPortOffset` convention
    /// above), or `nil` when there is no room above the terminal port.
    static func inspectorPort(for target: ConnectionTarget) -> UInt16? {
        let (sum, overflow) = target.port.addingReportingOverflow(inspectorPortOffset)
        return overflow ? nil : sum
    }

    /// Builds the production read-only ``InspectorClient`` for a terminal pane's `endpoint` (subscribed
    /// dynamically once a `claude` is detected in it, W11).
    ///
    /// ### Guardrail (docs/22 §7 + the WF5 brief): the LIVE network inspector path is NOT runtime-proven
    /// The terminal byte-pipeline (PATH 1) is proven; the structured inspector second channel
    /// (NWConnection #2) is wired here cleanly but **no host-side inspector serving / port is
    /// established yet** — there is no `aislopdesk-hostd` inspector daemon to invent. So this returns a
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
    static func liveMakeInspector(_ target: ConnectionTarget) -> InspectorClient? {
        guard let port = inspectorPort(for: target),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: nwPort,
            using: NWByteChannel.parameters(),
        )
        // The channel connects lazily: NWByteChannel.start() is idempotent and is triggered by the
        // first send (the `subscribe(fromSeq:)` in LivePaneSession.subscribeInspector). We do not start
        // it here so a plain terminal (no claude detected, W11) opens no inspector socket.
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
/// Commands that act on "the focused pane" read it from the store's current `workspace.focusedPane`;
/// a command with no valid target (no focused pane) is a graceful no-op.
@preconcurrency
@MainActor
public func apply(_ command: WorkspaceCommand, to store: WorkspaceStore) {
    // Record action verbs into the palette recents from the ONE chokepoint every path funnels through
    // (palette, menu bar, keyboard shortcut) — so a command you run by ⌘-key, not just from the
    // palette, floats to the top next time. Navigation/transient verbs are excluded (isRecentsWorthy).
    //
    // ⌘N (.newPaneDefault) opens a pane of the user's default kind; the catalog has no .newPaneDefault
    // entry (only the explicit .newPane(kind) items), so recording it verbatim silently dropped it from
    // the recents block AND wasted a ring slot. Record the RESOLVED kind instead — it resolves in the
    // catalog and names what was actually created.
    let recordable: WorkspaceCommand = (command == .newPaneDefault) ? .newPane(SettingsKey.defaultPaneKind) : command
    if recordable.isRecentsWorthy { store.recordRecentCommand(recordable) }
    switch command {
    case .newPaneDefault:
        store.addPane(kind: SettingsKey.defaultPaneKind)
    case let .newPane(kind):
        store.addPane(kind: kind)
    case .duplicatePane:
        if let pane = store.focusedPane {
            store.duplicatePane(pane)
        }
    case .tidy:
        store.tidyCanvas()
    case .centerFocusedPane:
        if let pane = store.focusedPane {
            store.centerOnPane(pane)
        }
    case .centerAll:
        store.centerOnAll()
    case .closePane:
        // Routed through the busy-shell guard: an idle pane closes immediately; a pane mid-command
        // parks behind the confirmation dialog (`pendingClose`) the root view hosts.
        if let pane = store.focusedPane {
            store.requestClosePane(pane)
        }
    case .reopenClosedPane:
        store.reopenClosedPane()
    case .newGroup:
        // Context-sensitive: a multi-selection becomes a group (the common intent — no more invisible
        // empty-group dead-end); with nothing selected, make an empty group to populate later.
        if store.selectedPanes.isEmpty {
            store.addGroup(name: "Group")
        } else {
            store.groupSelection(name: "Group")
        }
    case .groupSelection:
        // Explicit "Group Selected Panes" — a no-op when nothing is selected.
        store.groupSelection(name: "Group")
    case let .focus(direction):
        store.move(direction)
    case let .cycleFocus(forward):
        store.move(forward ? .next : .previous)
    case let .switchRecentPane(forward):
        store.switchToRecentPane(forward: forward)
    case let .cycleFocusInGroup(forward):
        store.cycleFocusInGroup(forward: forward)
    case .toggleZoom:
        store.toggleZoom()
    case .toggleOverview:
        store.toggleOverview()
    case .toggleBroadcast:
        store.toggleBroadcast()
    case .renamePane:
        // The rename UI is an inline text field (view `@State` in PaneSidebarView), so the command layer
        // cannot open it directly — it nudges `renameRequest`, which the sidebar observes via `.onChange`
        // to begin renaming the focused pane's row.
        store.requestRenameFocusedPane()
    case .reconnectPane:
        // Re-dial the focused pane (recovers a `.failed` / `.unreachable` / dropped pane). A no-op when
        // there is no focused pane or it has no live connection (e.g. a `.remoteGUI` pane / faked handle).
        if let pane = store.focusedPane {
            store.reconnect(pane)
        }
    case let .saveBookmark(slot):
        store.saveBookmark(slot)
    case let .recallBookmark(slot):
        store.recallBookmark(slot)
    case .manageSnippets:
        store.requestSnippetManager()
    case .runLastSnippet:
        store.runLastSnippet()
    case let .align(edge):
        store.alignPanes(to: edge)
    case let .distribute(horizontal):
        store.distributePanes(horizontal: horizontal)
    case .saveLayout:
        store.requestSaveLayout()
    case .selectAllPanes:
        store.selectAllPanes()
    }
}
