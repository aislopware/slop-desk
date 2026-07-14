import CoreGraphics
import Foundation
import Network
import SlopDeskAgentDetect
import SlopDeskClient
import SlopDeskInspector
import SlopDeskTransport

// MARK: - WorkspaceStore (the one @MainActor @Observable owner)

/// The single owner of the workspace: it holds the pure ``Workspace`` tree of intent and reconciles
/// the `[PaneID: any PaneSessionHandle]` table of liveness against it after every mutation
/// (docs/22 §1.1, §2.3).
///
/// ### The shape of every mutation
/// Each public intent method does exactly two things, in order:
/// 1. apply a **pure** tree op (returns a new `Workspace`), and
/// 2. call ``reconcile()`` to materialize sessions for new leaves and tear down orphaned ones.
///
/// Because every mutation funnels through `reconcile()`, the load-bearing invariant
/// `Set(registry.keys) == Set(allLeafIDs)` holds after *any* sequence of ops, and there is exactly
/// ONE ``LivePaneSession`` (hence one ordered-OUT stream, one events consumer, one `ReconnectManager`)
/// per ``PaneID`` — the four byte-pipeline invariants by construction (docs/22 §1.2).
///
/// ### The test seam
/// Sessions are built through the injected `makeSession` factory — NOT a fake `SlopDeskClient` (which is
/// impossible) and NEVER a real `HostServer` (forbidden, pool deadlock). Tests inject a
/// `FakePaneSession`; production injects ``LivePaneSession/make(_:makeClient:makeInspector:)``.
@preconcurrency
@MainActor
@Observable
public final class WorkspaceStore {
    // MARK: Live model (which tree of intent drives the live loop)

    /// Which model is the LIVE source of truth — the one `init` reconciles, the one a debounced save
    /// persists, the one the views bind (docs/42 §"W5 — IDE shell CUTOVER").
    public enum LiveModel: Sendable, Equatable {
        /// The retained-but-dead infinite ``Canvas`` path: `init` reconciles `workspace`, a save persists
        /// `workspace`. The DEFAULT, so the canvas `WorkspaceStoreReconcileTests` + the dormant-tree
        /// `WorkspaceStoreTreeReconcileTests` drive it without opting in.
        case canvas
        /// The LIVE IDE-shell path: `init` reconciles ``tree``, a save persists ``tree``, and the
        /// `SplitWorkspaceView` shell binds it. The production app passes this.
        case tree
    }

    /// Which model drives the live loop. Exactly ONE of the two trees ever drives a given store.
    public let liveModel: LiveModel

    // MARK: State

    /// The pure tree of intent — the single source of truth. `private(set)`: only the mutation
    /// methods change it (each then reconciles), so the registry can never drift from the tree.
    public private(set) var workspace: Workspace

    /// The `Session → Tab → Pane` split tree (``TreeWorkspace``, docs/42 §"W4 — Store retarget") — the live
    /// source of truth under ``LiveModel/tree``, dormant under ``LiveModel/canvas``. Mutated by the
    /// tree-mutation methods below (each delegates to ``WorkspaceTreeOps`` then ``reconcileTree()``s, so the
    /// registry can't drift). `internal(set)`: read-only to the UI (cross-module), settable only by the
    /// store's tree-mutation methods + same-module extensions (e.g. `WorkspaceStore+RemoteWindow`).
    public internal(set) var tree: TreeWorkspace

    /// The table of liveness: 1:1 with the leaves of whichever model is live — `workspace`'s on the canvas
    /// path, ``tree``'s on the tree path. Both paths diff the SAME registry, but only ONE drives a given
    /// store (``liveModel`` decides), so the two reconciles can never fight over it.
    private var registry: [PaneID: any PaneSessionHandle] = [:]

    /// ⌘⇧U's walk memory (visited-set / origin / last-walk-focused) — see
    /// ``jumpToOldestAttentionPane()``. A `let` reference type so the walk's bookkeeping stays out of
    /// Observation: no view reads it, and a step mutating it must never invalidate view bodies.
    let attentionWalk = AttentionWalkBox()

    /// TRUE while an INTERACTIVE divider drag is in progress (a pane-divider OR the sidebar/inspector
    /// `NSSplitView` divider) — bracketed by ``setTerminalResizeSuspended(_:)``'s begin (`true`) / end
    /// (`false`). The pane resize-scrim reads it so the overlay stays up across a PAUSED drag (mouse held,
    /// cursor still): otherwise the per-frame geometry-settle timer clears the scrim mid-drag and it flashes
    /// back on release (the host grid-send is DEFERRED to release, so nothing else holds the scrim during the
    /// pause). ``PaneContainer`` gates it on THIS pane actually changing size, so only resized panes scrim.
    public private(set) var isInteractiveResizeActive = false

    /// The injection seam (docs/22 §0). Spec-only — the store re-points the built handle at the leaf
    /// id via `adopt(id:)` (see ``PaneSessionIDAdopting``).
    private let makeSession: @MainActor (PaneSpec) -> any PaneSessionHandle

    /// Maximum number of `.remoteGUI` panes that may hold a LIVE video stack at once (docs/22 §7 the
    /// 2N-UDP / N-VTDecompression / N-CVDisplayLink ceiling). Injectable; default 2. The app resolves it
    /// per device class via ``VideoCapPolicy`` (phone 1 / pad 2 / mac 3); the store keeps the plain `Int`
    /// shape and is agnostic to how the number was chosen.
    ///
    /// ### UDP-mux interaction — cap is intentionally per-pane
    /// Same-host video panes SHARE one UDP flow (2 sockets/host, not 2N), but each pane STILL owns its own
    /// `VTDecompressionSession` + `CVDisplayLink` + Metal renderer — only the UDP socket is shared. The
    /// scarce resources the cap bounds (decode + composite) stay strictly per-pane, so the per-pane cap can
    /// never under-count live decoders. Mux only weakens the "2N-UDP" term to "2-per-host", making the cap
    /// more conservative, never wrong — a per-host socket count would loosen admission for no headroom gain.
    public let liveVideoCap: Int

    /// A monotonic nudge the view layer observes to RE-ATTEMPT video admission for gated panes.
    /// The store can't flip a pane's liveness itself — admission is **view-driven**: only an on-screen pane
    /// decodes, via ``RemoteGUIPaneView``'s `.onAppear` → ``activateVideo(_:)``. So when a slot frees (a
    /// video pane deactivated, or an active-video pane closed), no one promotes a queued-but-still-on-screen
    /// gated pane. Bumped on exactly those slot-freeing events; gated leaves observe it via `.onChange` and
    /// re-call `activateVideo` (still cap-gated, so the ceiling holds). Only the store bumps it
    /// (`private(set)`), GUARDED to real slot-freeing transitions so a no-op deactivate / non-video close
    /// never churns the view. Pure MainActor `Int` bookkeeping (no new concurrency / Sendable surface).
    public private(set) var videoPromotionGeneration: Int = 0

    /// The pane whose sidebar row should open its inline rename field — set by the ⌘R / menu /
    /// palette "Rename" entry points, CONSUMED by the sidebar (``clearRenameRequest()``) once the
    /// field is open. A pending ID rather than a counter nudge: when the sidebar column is collapsed the
    /// root view observes this to REVEAL the column first, and the just-mounted sidebar acts on the
    /// still-pending value — a fired-and-missed counter could not be replayed safely, so ⌘R would silently
    /// no-op on a collapsed sidebar.
    public private(set) var pendingRename: PaneID?

    /// Requests the sidebar open the inline rename on the focused pane (the command-layer entry point
    /// for "Rename"). No-op when no pane is focused. See ``pendingRename``.
    public func requestRenameFocusedPane() {
        guard let focused = workspace.focusedPane else { return }
        pendingRename = focused
    }

    /// The TAB whose sidebar row should open its inline rename field — set by the ⌘R / palette "Rename Pane"
    /// + the sidebar row context-menu "Rename" entry on the LIVE tree shell, CONSUMED by the rail row
    /// (``RailRowsBuilder`` lights `isEditing` on that tab's representative pane row; the field commits via
    /// ``renamePane(_:to:)`` and clears through ``clearTabRenameRequest()``). A pending ID (mirrors
    /// ``pendingRename``) so a not-yet-mounted row acts on the still-pending value rather than a fired-and-missed
    /// counter.
    public private(set) var pendingTabRename: TabID?

    /// Requests the inline rename on the ACTIVE entity in whichever live model is current:
    /// under ``LiveModel/tree`` the ⌘R chord renames the active TAB (the sidebar rail row's inline-rename
    /// field, set via ``pendingTabRename``); under ``LiveModel/canvas`` it
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

    /// Requests the inline rename on an ARBITRARY tab `tabID` (the sidebar row context-menu "Rename"
    /// entry) — sets ``pendingTabRename`` so THAT tab's representative rail row opens its rename
    /// field, even when it is not the active tab. Twin of ``requestRenameActivePane()`` for a mouse-reachable
    /// target the user right-clicked rather than the keyboard-active one.
    public func requestRenameTab(_ tabID: TabID) {
        pendingTabRename = tabID
    }

    /// Where the value tree is persisted (docs/22 §6). Injectable so tests point at a temp dir and a
    /// store built with `nil` persistence (the default for the FakePaneSession test seam) never
    /// touches disk. The app passes a real ``WorkspacePersistence``.
    private let persistence: WorkspacePersistence?

    /// How long to coalesce a burst of mutations before writing the tree (docs/22 §6 "debounced on
    /// mutation"). One write per quiet period, not one per keystroke-driven split/resize.
    private let saveDebounce: Duration

    /// How long to let a closed `.remoteGUI` pane's video stack ACTUALLY release before the store frees its
    /// ``liveVideoCap`` slot. `teardown()` sets `RemoteWindowModel.active = nil`, which only triggers the
    /// SwiftUI dismantle → `VideoWindowPipeline.deactivate()` → detached `session.stop()` closing the two UDP
    /// `NWConnection`s + `VTDecompressionSession` + display link — completing a few runloop turns AFTER
    /// `teardown()` returns. Freeing the slot immediately could admit a sibling while the outgoing stack is
    /// still up (cap+1 — no crash/leak, just a momentary over-commit). `stop()` is one ordered task
    /// (`VideoWindowPipeline.awaitStopped()`), but it lives in the SwiftUI-owned AppKit view, unreachable for
    /// a direct store `await`; so the store holds the slot for this bounded settle past `teardown()` to cover
    /// the dismantle→stop lag. Injectable; DEFAULT `.zero` frees the slot immediately, so the OFF /
    /// terminal-only paths never enter this gate. The PRODUCTION app opts in with a small window
    /// (``SlopDeskClientApp``). The real dismantle→stop lag is not hardware-measured.
    private let videoTeardownSettle: Duration

    /// The pending debounced-save task. Cancelled + replaced on each mutation so only the last
    /// mutation in a burst actually writes; cancel-safe (a cancelled sleep simply returns).
    private var saveTask: Task<Void, Never>?

    /// A monotonic save-generation guard (mirrors ``FocusGenerationGuard``). Each `scheduleSave()` bumps it
    /// and captures the value; the debounced write re-checks it on a MainActor hop BEFORE writing and skips
    /// if superseded, and the trailing `saveTask = nil` clears the handle ONLY if still current — so
    /// a superseded (already-past-sleep) prior task can neither clobber the file with a stale snapshot NOR
    /// nil out the newest handle and strand it uncancellable. Pure MainActor Int bookkeeping.
    /// `internal private(set)`: only the store bumps it, but the guard is observable to the `@testable`
    /// tests via ``isCurrentSaveGeneration(_:)``.
    private(set) var saveGeneration = 0

    /// The pure generation-guard predicate the debounced write consults before writing: a
    /// captured `generation` is still current iff it equals the live ``saveGeneration``. Mirrors
    /// `FocusGenerationGuard.isCurrent(_:)`. Factored out so the production write path and the test
    /// assert the EXACT SAME logic (not a re-implementation). MainActor-isolated; pure read.
    func isCurrentSaveGeneration(_ generation: Int) -> Bool {
        saveGeneration == generation
    }

    /// Suppresses the debounced save during construction (the initial `reconcile()` would otherwise
    /// re-write a just-loaded file with identical bytes). Flipped off once init completes.
    private var savingEnabled = false

    /// In-flight teardown tasks spawned by ``reconcile()`` (teardown is `async`; reconcile is called inline
    /// by synchronous mutations). Tracked so tests — and a deliberate shutdown — can `await` every orphaned
    /// session's `teardown()` via ``quiesce()``. The registry invariant (`keys == leafIDs`) holds the instant
    /// reconcile returns (orphans removed synchronously); `quiesce()` only waits for the *cleanup*.
    ///
    /// Keyed by a monotonic id (not an array) so each task self-prunes its own entry on completion without
    /// the task-captures-itself chicken-and-egg — freeing the handle promptly rather than on the next
    /// orphaning reconcile. Every site (reconcile insert, self-remove, `quiesce()` drain) runs on
    /// `@MainActor`, so the bookkeeping is serialized with no data race.
    private var teardownTasks: [Int: Task<Void, Never>] = [:]
    /// The next teardown-task id (monotonic, wraps harmlessly).
    private var nextTeardownID = 0

    /// The ids of `.remoteGUI` panes whose video stack is STILL tearing down (orphaned + removed from the
    /// registry, but their async `teardown()` — stopping the UDP / VTDecompression / CVDisplayLink stack —
    /// has not completed). Protects the ``liveVideoCap`` ceiling across a same-tick close+reopen (docs/22
    /// §7): a pane gone from the registry but still holding its video resources must keep counting
    /// against the cap until they release. `reconcile()` inserts an orphan's id (reading `isVideoActive`
    /// BEFORE teardown nils it); the teardown task removes it after the `await`. ``activateVideo(_:)`` adds
    /// `tearingDownVideo.count` to the live count; ``quiesce()`` defensively clears it. Every site runs on
    /// `@MainActor`, serialized with the `teardownTasks` self-prune — no data race.
    private var tearingDownVideo: Set<PaneID> = []

    /// The last layout the view solved, cached so geometric ``move(_:)`` can resolve a neighbour
    /// without the store knowing the view's size. `nil` until the view reports one (compact mode never
    /// solves a multi-pane layout — `.next`/`.previous` still work via the pre-order cycle fallback).
    private var lastSolvedLayout: SolvedLayout?

    /// The full `SplitContainer` container bounds (origin .zero, `geo.size`) the active tab last reported
    /// via ``updateContainerBounds(_:)``. A fallback input to ``treeGeometryBounds`` (directional focus /
    /// move-pane resolution) before the first solved-layout report. `nil` until the view reports one.
    private var lastContainerBounds: CGRect?

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
    /// `livePan` @State for a background DRAG. A trackpad/wheel scroll over background OR a pane (via
    /// ``scrollPan(by:)``) accumulates here; the camera is committed ONCE ~110 ms after the scroll settles
    /// (``commitScrollPan()``). A per-step ``commitCamera(_:)`` is avoided because it mutates
    /// `workspace.canvas` → fires the `.onChange(of: canvas)` → `report()` cascade (viewport / membership /
    /// solved-layout) → a full-canvas SwiftUI re-render that BLOCKS the main thread, starving the Metal video
    /// render + cursor overlay (the freeze gaps are all main-actor; cursor RX stays clean — proven on-device).
    /// Accumulating here touches ONLY ``CanvasView`` (panes diff unchanged, NO `report()`), so the pan stays
    /// smooth. Not persisted; folded into the real camera on commit with NO visual jump (the committed offset
    /// equals the live offset).
    public private(set) var liveCameraOffset: CGSize = .zero
    /// Debounce handle: cancelled + rescheduled on each ``scrollPan(by:)`` so the single commit fires only
    /// after the scroll (incl. trackpad momentum) settles.
    private var scrollCommitTask: Task<Void, Never>?

    /// The single-focus arbiter for the iOS multi-visible (iPad-regular) input path (docs/22 §7). One per
    /// workspace. The regular `PaneTreeView` leaves route their ``TerminalInputHost`` first-responder through
    /// this so a stale async `becomeFirstResponder` callback can never win (resign-before-become + generation
    /// reject). Compact mode mounts one host and skips it. Cross-platform-compilable (the UIKit calls inside
    /// are `#if os(iOS)`). Exposed so the view layer can drive `focus(_:)` on a focus change.
    public let focusCoordinator = PaneFocusCoordinator()

    // MARK: Init

    /// - Parameters:
    ///   - restoring: a decoded workspace to restore (SHAPE + INTENT only — sessions start idle,
    ///     docs/22 §6). `nil` ⇒ ``Workspace/defaultWorkspace()`` (one terminal tab).
    ///   - restoringTree: a decoded ``TreeWorkspace`` to seed the tree path. `nil` ⇒
    ///     ``TreeWorkspace/defaultWorkspace()`` (one terminal pane). With ``LiveModel/canvas`` (the
    ///     default) the tree stays DORMANT (init reconciles the canvas, so seeding it is behavior-neutral);
    ///     with ``LiveModel/tree`` (the app) the tree IS the live source — init reconciles it.
    ///   - liveModel: which model drives the live loop. Default ``LiveModel/canvas``; the production app
    ///     passes ``LiveModel/tree``.
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
        // The live model picks the init reconcile. `.canvas` materializes the canvas panes (the
        // retained-but-dead path); `.tree` (the app) materializes the tree's leaves through the SAME
        // registry diff — exactly one of the two trees ever drives a given store.
        switch liveModel {
        case .canvas: reconcile()
        case .tree: reconcileTree()
        }
        savingEnabled = true // arm debounced saves only AFTER the restore reconcile
    }

    // MARK: - Accessors

    /// The live handle for `id`, or `nil` if no such leaf is materialized.
    public func handle(for id: PaneID) -> (any PaneSessionHandle)? { registry[id] }

    /// Every materialized live handle — the whole-registry sweep ``applyWorkspaceKeyPrefix(_:)`` re-keys
    /// (unordered; a sweep is per-handle idempotent so order can't matter). Internal so the `registry`
    /// stays private to this file.
    var allSessionHandles: [any PaneSessionHandle] { Array(registry.values) }

    /// Whether pane `id`'s shell currently reports a running foreground command (the live
    /// ``PaneSessionHandle/isShellBusy`` bit), or `false` for an unmaterialized pane. Exposes the busy
    /// signal to the ClientUI rail (the ``TabBadgeResolver`` "running" input) WITHOUT leaking the
    /// private `registry` handle — reading it inside a SwiftUI body registers observation on the handle,
    /// exactly like ``PanePresentation/busy(handle:)``.
    public func paneIsBusy(_ id: PaneID) -> Bool { registry[id]?.isShellBusy ?? false }

    /// Whether pane `id`'s plain BUSY DOT (``TabBadgeKind/commandBusy``) should render: the shell is
    /// busy AND the current command has been running at least the configured reveal delay
    /// (``SettingsKey/tabBadgeBusyDelaySecondsValue``, default 3 s) — a fast `ls`/`cd` never flashes
    /// the rail. The `isBusy` input BOTH badge-resolution call sites feed to ``TabBadgeGating/resolve``
    /// (the rail's `chrome(...)` and ``unseenAttentionPanes`` — they must agree). A busy shell with no
    /// start stamp shows immediately (fail-visible — the stamp and the busy bit ride the same OSC-133
    /// `.running` edge, so this is a defensive default, not a path). Everything else (close guards,
    /// broadcast checks) keeps reading the raw ``paneIsBusy(_:)`` — a busy shell must confirm a close
    /// from second zero. `now` is injectable for deterministic threshold tests.
    public func paneShowsBusyDot(_ id: PaneID, now: Date = Date()) -> Bool {
        guard paneIsBusy(id) else { return false }
        guard let startedAt = paneCommandStartedAt[id] else { return true }
        let elapsed = now.timeIntervalSince(startedAt)
        return !elapsed.isLess(than: SettingsKey.tabBadgeBusyDelaySecondsValue)
    }

    /// Folds every live pane's PATH-1 connection status into a compact ``WorkspaceConnectionAlert``
    /// for the collapsed-sidebar connection indicator, or `nil` when all panes are healthy. Iterates the tree
    /// in DFS order (a STABLE worst-pane tie-break) and reads each materialized ``LivePaneSession``'s channel
    /// status; a video pane / faked handle contributes a `nil` status (never an alarm). Reading it inside a
    /// SwiftUI body registers observation on each ``ConnectionViewModel/status``, so the chip re-renders as
    /// panes drop / recover — the same observation seam ``PanePresentation/connectionStatus(_:)`` relies on.
    public func connectionAlert() -> WorkspaceConnectionAlert? {
        let entries: [(pane: PaneID, status: ConnectionStatus?)] = tree.allPaneIDs().map { id in
            (pane: id, status: (registry[id] as? LivePaneSession)?.connection?.status)
        }
        return WorkspaceConnectionAlert.resolve(from: entries)
    }

    /// All live sessions (registry values). Order is unspecified — callers that need a stable order
    /// derive it from the tree's `allLeafIDs()`.
    public var allSessions: [any PaneSessionHandle] { Array(registry.values) }

    /// The focused pane id, or `nil` when the canvas is empty (a pure passthrough).
    public var focusedPane: PaneID? { workspace.focusedPane }

    /// Whether `id` is the focused pane (the view's focus-ring decision).
    public func isFocused(_ id: PaneID) -> Bool { workspace.focusedPane == id }

    /// Whether `id` is a pane on the single canvas — i.e. genuinely on-screen (all panes live on the
    /// one always-mounted canvas). A reliable visibility signal for the video teardown decision,
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

    /// The active-tab `SplitContainer` reports its FULL container bounds (origin .zero, `geo.size`) — a
    /// fallback for the geometric ops before the first solved-layout report (``treeGeometryBounds``).
    /// View-only state — never touches the tree, so reporting it never reconciles.
    public func updateContainerBounds(_ bounds: CGRect) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        lastContainerBounds = bounds
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
    /// action (⌥⌘G, and ⌃⌘G when ≥1 pane is selected). The alternative — create an EMPTY group, then
    /// Move-to-Group N times — leaves an invisible dead-end on the canvas in between (an empty group has no
    /// bounding box). Members are assigned in deterministic canvas order; the transient pane-selection is
    /// cleared (the panes read as a group instead). Returns the new group id, or
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

    /// The most CLOSED-TABS-the-LIFO can hold before the oldest record is dropped — the tree-shell reopen
    /// stack's bound (a long open/close session can never grow this unbounded).
    static let recentlyClosedTabsCap = 25

    /// The TREE shell's "Reopen Closed Tab" LIFO (the ⇧⌘T chord) — a bounded stack of
    /// ``RecentlyClosedTab`` records captured before a tab-removing close, popped in last-in-first-out
    /// order by ``reopenLastClosedPane()``. In-memory only (deliberately not persisted, exactly like the
    /// canvas single-slot ``recentlyClosed``: a relaunch already restores the live layout, so there is no
    /// untrusted-decode surface). Distinct from the canvas slot — the tree shell restores whole TABS (a
    /// split tree + every pane's spec), not a single canvas pane. `internal(set)`: read-only to the UI,
    /// mutated only by the store's close paths + the `WorkspaceStore+PaneCycle` reopen extension.
    public internal(set) var recentlyClosedTabs: [RecentlyClosedTab] = []

    /// The pane awaiting close CONFIRMATION because its shell reported a running command (⌘W on a
    /// busy shell — killing the session would kill the command). The view observes this and shows a
    /// confirmation dialog; ``confirmPendingClose()`` / ``cancelPendingClose()`` resolve it. `internal(set)`
    /// so the `WorkspaceStore+CloseConfirmation` extension's park/resolve helpers can arm/clear it.
    public internal(set) var pendingClose: PaneID?

    /// The whole TAB awaiting close CONFIRMATION (⌘⇧W "Close Tab" on a tab whose policy/busy-shell guard
    /// says confirm). A tab close is NOT a single-leaf close: confirming it must drop EVERY pane
    /// in the tab, so it is parked as the ``TabID`` (not the active leaf) and resolved through
    /// ``closeTab(_:)``. Mutually exclusive with ``pendingClose`` — ``parkPaneClose(_:)`` /
    /// ``parkTabClose(_:)`` keep exactly one armed so only one confirmation dialog is ever up. Resolved by
    /// ``confirmPendingClose()`` / ``cancelPendingClose()``. In-memory only.
    public internal(set) var pendingTabCloseID: TabID?

    /// The ACTIVE session awaiting a WINDOW-close confirmation. A macOS window maps to an
    /// slopdesk ``Session`` (the macOS window hosts the whole ``TreeWorkspace``; closing it confirms
    /// against the active session's tab count — see `docs/DECISIONS.md`). Parked by ``requestCloseWindow()``
    /// when ``SettingsKey/closeConfirmWindow`` says confirm; resolved by ``confirmPendingWindowClose()``
    /// (which closes that session) / ``cancelPendingWindowClose()``. The macOS `windowShouldClose` reads this
    /// to decide whether to block the NSWindow close while the confirmation dialog resolves. In-memory only.
    public private(set) var pendingWindowClose: SessionID?

    /// The close entry point for every user-facing close affordance (⌘W, the pill menu, the sidebar
    /// context menu): closes immediately when the pane's shell is idle, parks the close behind a
    /// confirmation (``pendingClose``) when ``PaneSessionHandle/isShellBusy`` says a command is still
    /// running. Direct ``closePane(_:)`` stays public for the auto-managed paths (the system-dialog
    /// monitor) and tests — the guard is a UX gate, not an invariant.
    public func requestClosePane(_ id: PaneID) {
        guard workspace.canvas.contains(id) else { return }
        if registry[id]?.isShellBusy == true {
            parkPaneClose(id)
        } else {
            closePane(id)
        }
    }

    /// The TREE busy-shell close guard: the IDE-shell counterpart of ``requestClosePane(_:)``
    /// — an idle leaf closes immediately (cascading the tab/session), a leaf mid-command parks behind the
    /// ``pendingClose`` confirmation. The chrome close button and ⌘W on a SPECIFIC leaf both route through
    /// here so the busy-guard is honoured uniformly (the `closePaneTree(_:)` direct call stays for tests /
    /// the active-pane convenience). No-op if `id` is not a live tree leaf.
    public func requestClosePaneTree(_ id: PaneID) {
        guard tree.contains(id) else { return }
        if closeConfirmationNeeded(scope: .pane, pane: id) {
            parkPaneClose(id)
        } else {
            closePaneTree(id)
        }
    }

    /// Whether a close in `scope` must park behind a confirmation prompt, evaluating the scope's
    /// configured ``CloseConfirmationPolicy`` against the live tree state. `.pane` / `.tab` read
    /// ``SettingsKey/closeConfirmTab``; `.window` reads ``SettingsKey/closeConfirmWindow``. The BUSY input is
    /// the busy-shell signal (`pane` for `.pane`; ANY pane in the active tab for `.tab`; ANY pane in the
    /// active session for `.window`); the tab-count input is the active session's `tabs.count`. The pure
    /// truth table lives in ``CloseConfirmationPolicy/shouldConfirm(_:isBusy:tabCount:)``. Under the default
    /// `.process` policy this collapses to "confirm iff busy".
    func closeConfirmationNeeded(scope: CloseScope, pane: PaneID? = nil) -> Bool {
        let tabCount = tree.activeSession?.tabs.count ?? 0
        switch scope {
        case .pane:
            let busy = pane.map { registry[$0]?.isShellBusy == true } ?? false
            // A mid-tab pane close that leaves its tab alive must NOT inherit the Tab/Window
            // close-confirmation policy (a pane close is only confirmed when it drops a tab/window). Gate by the
            // EFFECTIVE pane policy — the Tab/Window policy ONLY when the close cascades a tab/window away, else
            // the `.process` busy-shell guard alone (so a non-cascading idle pane closes immediately even under
            // `.always`/`.multiple_tabs`).
            return CloseConfirmationPolicy.shouldConfirm(
                effectivePanePolicy(for: pane),
                isBusy: busy,
                tabCount: tabCount,
            )
        case .tab:
            let busy = anyShellBusy(tree.activeSession?.activeTab?.allPaneIDs() ?? [])
            return CloseConfirmationPolicy.shouldConfirm(SettingsKey.closeConfirmTab, isBusy: busy, tabCount: tabCount)
        case .window:
            let busy = anyShellBusy(tree.activeSession?.allPaneIDs() ?? [])
            return CloseConfirmationPolicy.shouldConfirm(
                SettingsKey.closeConfirmWindow,
                isBusy: busy,
                tabCount: tabCount,
            )
        }
    }

    /// Whether ANY pane in `ids` reports a running child process (the busy-shell signal). Drives the
    /// tab- / window-scope busy input for ``closeConfirmationNeeded(scope:pane:)``.
    private func anyShellBusy(_ ids: [PaneID]) -> Bool {
        ids.contains { registry[$0]?.isShellBusy == true }
    }

    /// The close-confirmation policy a PANE close is GOVERNED by — the single source the
    /// `.pane` guard AND the in-app panel's subtitle (``pendingCloseReasonPolicy``) read:
    /// - the close does NOT cascade a tab away (a mid-tab leaf with tiled siblings) → ``CloseConfirmationPolicy/process``
    ///   (the busy-shell guard alone — a non-cascading pane close is never confirmed under the Tab policy);
    /// - the close cascades its tab away (``tabRemovedByClosing(_:)`` ≠ nil) → ``SettingsKey/closeConfirmTab``,
    ///   ESCALATED to ``SettingsKey/closeConfirmWindow`` when that tab is its session's LAST (the whole window /
    ///   ``Session`` goes with it).
    /// A `nil` pane (no target) is treated as non-cascading → `.process`.
    func effectivePanePolicy(for pane: PaneID?) -> CloseConfirmationPolicy {
        guard let pane, tabRemovedByClosing(pane) != nil else { return .process }
        // Cascading close. Resolve the OWNING session's tab count (the pane may live in a non-active session)
        // so "last tab → window scope" is keyed on the right session; fall back to the active session.
        let owningTabCount: Int =
            if let (sIdx, _) = WorkspaceTreeOps.locate(pane, in: tree) {
                tree.sessions[sIdx].tabs.count
            } else {
                tree.activeSession?.tabs.count ?? 0
            }
        return owningTabCount <= 1 ? SettingsKey.closeConfirmWindow : SettingsKey.closeConfirmTab
    }

    /// The WINDOW-close GATE (the macOS `windowShouldClose` route). A macOS window maps to an
    /// slopdesk ``Session`` (the macOS NSWindow hosts the whole ``TreeWorkspace``; see `docs/DECISIONS.md`),
    /// so the confirmation is evaluated against the ACTIVE session — ``SettingsKey/closeConfirmWindow`` over
    /// the active session's tab count + any busy pane. A pure gate: when confirmation is needed it parks
    /// ``pendingWindowClose`` (the macOS delegate then BLOCKS the NSWindow close while the dialog resolves);
    /// when it is NOT needed it clears the park and lets the caller proceed (the macOS gate returns `true`,
    /// so the NSWindow closes normally — the persisted layout is preserved, never wiped on a plain close).
    /// The window → ``Session`` close action fires on the explicit ``confirmPendingWindowClose()``. No-op
    /// without an active session.
    public func requestCloseWindow() {
        guard let session = tree.activeSession else {
            pendingWindowClose = nil
            return
        }
        pendingWindowClose = closeConfirmationNeeded(scope: .window) ? session.id : nil
    }

    /// Confirms the parked window close (the confirmation dialog's "Close" button): closes the parked session
    /// (window → ``Session``) and clears ``pendingWindowClose``. No-op when nothing is pending.
    public func confirmPendingWindowClose() {
        guard let id = pendingWindowClose else { return }
        pendingWindowClose = nil
        closeSession(id)
    }

    /// Dismisses the window-close confirmation without closing.
    public func cancelPendingWindowClose() {
        pendingWindowClose = nil
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
        // On the LIVE tree shell the canvas is dead, so an ephemeral dialog pane inserts into the TREE — a
        // NEW TAB of the active session (least-disruptive transient shape: the monitor closes it again when
        // the dialog leaves, without resplitting the layout). `.canvas` inserts onto the canvas.
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
    /// current: under ``LiveModel/tree`` the leaf lives in the tree (its transient tab is dropped,
    /// cascading), else the canvas close. The monitor calls this directly (it is not subject to
    /// the busy-shell guard — a dialog leaving host-side must always dismiss its pane).
    public func closeSystemDialogPane(_ id: PaneID) {
        switch liveModel {
        case .tree: closePaneTree(id)
        case .canvas: closePane(id)
        }
    }

    /// Whether `id` is a LIVE pane in whichever model is current — the tree under ``LiveModel/tree``,
    /// else the canvas. The auto-managed monitor uses this to detect a manual close (a spawned pane
    /// absent from the model) on EITHER shell.
    public func isSystemDialogPaneLive(_ id: PaneID) -> Bool {
        switch liveModel {
        case .tree: tree.contains(id)
        case .canvas: workspace.canvas.contains(id)
        }
    }

    /// Focuses pane `id` (a pure focus change; leaf set unchanged). Maximize follows focus.
    ///
    /// A click on a GUI pane runs `mouseDown → onActivate → focus(id)`. Without the guard below, clicking the
    /// ALREADY-focused pane would still reassign the whole `@Observable workspace` (struct assignment
    /// notifies regardless of equality) → a full-canvas SwiftUI re-render that blocks the main thread → the
    /// Metal video + cursor overlay freeze on EVERY click. Re-focusing the already-focused pane is a genuine
    /// no-op, so skip it entirely — no reassignment, no re-render, no freeze.
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

    /// Makes `id` the focused pane via a CREATION/RAISE path (which sets the focus DIRECTLY rather than
    /// through `focus(_:)`, the existing-pane re-render path) AND records the visit in the quick-switch
    /// MRU ring. Without recording here, opening/raising panes would never populate `focusHistory`, so
    /// quick-switch (⌥⌘;) would stay dead until the user happened to CLICK between panes (the only other
    /// `focus()` caller). Records OUTGOING-then-incoming so "go to last pane" returns to where you actually were.
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

    /// 1:1 SNAP (remote-GUI panes): resizes pane `id` by the VIDEO-CONTENT delta `target − current` so its
    /// stream renders pixel-for-pixel — the pane chrome (header + divider) is a constant additive inset, so
    /// adjusting the FRAME by the CONTENT delta needs no chrome-height constant and survives a chrome change.
    /// The origin stays pinned (grows right/down, no jump under the cursor). Skipped while maximized (its
    /// on-screen size is the viewport override — mutating the frame would surprise the restore) and for
    /// sub-half-point deltas (layout noise; not worth a canvas mutation + persistence write).
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

    /// The per-pane block-bookmark persistence seam + the per-pane jump-to-failed cursor, bundled into
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
    /// ``commitScrollPan()`` once scrolling settles — a per-step ``commitCamera(_:)`` would thrash the canvas
    /// re-render + `report()` cascade and freeze the video/cursor. `delta` is the camera delta
    /// `camera.translated(by:)` takes; the visual offset moves OPPOSITE it (the content follows the camera),
    /// matching the committed `.offset` math in ``CanvasView``. Only ``CanvasView`` reads
    /// ``liveCameraOffset``, so a step re-renders nothing else.
    public func scrollPan(by delta: CGSize) {
        liveCameraOffset.width -= delta.width
        liveCameraOffset.height -= delta.height
        if Self.wsDbgEnabled {
            FileHandle.standardError
                .write(
                    Data(
                        "SlopDesk[workspace]: scrollPan d=(\(Int(delta.width)),\(Int(delta.height))) liveOff=(\(Int(liveCameraOffset.width)),\(Int(liveCameraOffset.height))) camOrigin=(\(Int(workspace.canvas.camera.origin.x)),\(Int(workspace.canvas.camera.origin.y)))\n"
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

    /// Env-gated (`SLOPDESK_VIDEO_DEBUG`) stderr probe for the scroll-pan path (the "pan stops at the GUI
    /// edge" symptom): shows whether a scroll over a GUI pane actually moves the camera, vs the visual offset
    /// not being applied / the events not reaching here.
    static let wsDbgEnabled = ProcessInfo.processInfo.environment["SLOPDESK_VIDEO_DEBUG"] != nil

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
                        "SlopDesk[workspace]: commitScrollPan camOrigin (\(Int(before.x)),\(Int(before.y)))→(\(Int(after.x)),\(Int(after.y))) foldedOff=(\(Int(off.width)),\(Int(off.height)))\n"
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

    /// A LIVE reader of the current local clipboard text, injected by the app (macOS: `NSPasteboard`),
    /// so the pure store/routing stays platform-free + testable. The ⌥⌘V "Paste as Keystrokes" chord +
    /// the pane context menu read the CURRENT clipboard through this (not the up-to-1s-stale ring head),
    /// and it works even when clipboard-history recording is OFF (an empty ring). `nil` (the headless /
    /// test default) ⇒ fall back to ``clipboardRing`` head via ``currentLocalClipboard()``.
    @ObservationIgnored public var clipboardTextProvider: (() -> String?)?

    /// The current local clipboard text: the injected ``clipboardTextProvider`` if wired, else the most
    /// recent recorded clip (``clipboardRing`` head). `nil`/empty ⇒ nothing to paste.
    public func currentLocalClipboard() -> String? {
        clipboardTextProvider?() ?? clipboardRing.first
    }

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

    /// A pane's fresh-vs-resumed verdict after a completed RECONNECT (forwarded from its
    /// ``ConnectionViewModel``). The app wires this to a small transient toast so the user knows whether the
    /// drop reattached the SAME live shell (`.resumedSession` — scrollback/history intact) or spawned a
    /// FRESH shell (`.freshShell` — the previous session ended and its context is gone). Fires at most once
    /// per drop→reconnect; never on a first-ever connect or a deliberate ⇧⌘R. `nil` in tests / headless ⇒
    /// the verdict is dropped. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored
    public var onSessionResumeOutcome: ((_ paneID: PaneID, _ outcome: SlopDeskClient.SessionResumeOutcome) -> Void)?

    /// A NON-pane-scoped client copy just landed on the clipboard (palette "Copy Path", host-window rail
    /// "Copy Window Title" — actions whose trigger surface has no pane to host the transient `COPIED · N`
    /// chip). The app wires this to the overlay coordinator's window-level chip. Pane-scoped copies never
    /// route here — they publish ``TerminalViewModel/copyReceipt`` on their own pane instead. `nil` in
    /// tests / headless ⇒ the confirmation is dropped. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onLocalCopy: ((_ text: String) -> Void)?

    /// Fires ``onLocalCopy`` for a completed non-pane-scoped clipboard write. Empty text is a no-op
    /// (nothing was copied ⇒ nothing to confirm).
    public func noteLocalCopy(_ text: String) {
        guard !text.isEmpty else { return }
        onLocalCopy?(text)
    }

    /// A REOPENABLE tab was just recorded onto the ⇧⌘T LIFO (``recordClosedTab(_:)`` — a close that
    /// removed a tab holding ≥1 real pane). The app wires this to the overlay coordinator's transient
    /// "TAB CLOSED · ⇧⌘T REOPENS" notice — the undo affordance for the workspace's most destructive
    /// routine action. Never fires for an all-ephemeral (system-dialog) tab, which is skipped by the
    /// record itself. `nil` in tests / headless ⇒ the cue is dropped. `@ObservationIgnored`: wiring.
    @ObservationIgnored public var onTabCloseRecorded: (() -> Void)?

    /// A TELEPORT focus (``jumpToPaneTree(_:)``) just CROSSED a tab (or session) boundary — the whole
    /// viewport changed in one frame with no cue of where it landed. Carries the ``JumpBreadcrumb``
    /// destination line ("session ▸ tab" / "tab"); the app wires it to the overlay coordinator's
    /// transient `JUMPED · …` notice. A same-tab focus never fires (absent, never wrong). The breadcrumb
    /// embeds OSC/PTY-settable titles — the app-side wiring masks secrets before display. `nil` in
    /// tests / headless ⇒ the cue is dropped. `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var onCrossTabJump: ((_ breadcrumb: String) -> Void)?

    /// The configured tmux/zellij PREFIX chord. The app-level `WorkspaceKeyDispatcher` and the per-surface
    /// ``TerminalKeyInterceptor``s (wired per pane in `wireMaterializedLeaf`) must read the SAME prefix or
    /// they disagree on what arms the engine — so it lives here, the one place a settings change re-points
    /// it (``applyWorkspaceKeyPrefix(_:)``, which also re-keys every already-materialized pane's
    /// interceptor). Seeded from the override-aware ``WorkspaceBindingRegistry/resolvedPrefixChord`` (the
    /// Settings ▸ Key Bindings ▸ Prefix Key override, else the ⌃B default): the app builds `PreferencesStore`
    /// BEFORE this store, so the persisted prefix is live from the first materialized pane.
    /// `@ObservationIgnored`: wiring, not view state.
    @ObservationIgnored public var workspaceKeyPrefix: KeyChord = WorkspaceBindingRegistry.resolvedPrefixChord

    /// View-injected overlay-toggle closures the per-pane hardware-keyboard ``TerminalKeyInterceptor`` threads
    /// into ``WorkspaceBindingRegistry/route`` (see ``routeInterceptedKey(_:)``). On iOS the per-pane
    /// interceptor is the ONLY hardware-chord path (no app-level NSEvent monitor; macOS's
    /// `WorkspaceKeyDispatcher` PREEMPTS the surface, so these stay all-`nil` there and the dispatcher owns
    /// the overlay chords). `nil` members ⇒ a graceful no-op, so a chord like ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌃↩ from
    /// a focused iPad terminal opens its overlay instead of dying.
    @ObservationIgnored public var overlayKeyToggles = WorkspaceOverlayKeyToggles()

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
    /// LIVE-MODEL aware: the canvas ``revealPane(_:)`` guards `canvas.contains` + centres, which
    /// is a NO-OP on the live TREE shell — so a clicked notification (long-command / OSC / agent-attention)
    /// would silently do nothing. Route to the tree focus path when ``liveModel`` is ``LiveModel/tree`` so
    /// the click actually switches session+tab+pane to the originating pane.
    public func revealPane(byIDString idString: String) {
        guard let uuid = UUID(uuidString: idString) else { return }
        let id = PaneID(raw: uuid)
        switch liveModel {
        case .tree: jumpToPaneTree(id) // a notification click is a teleport — breadcrumb on a crossed tab
        case .canvas: revealPane(id)
        }
    }

    // MARK: - Named layout presets (save / switch canvas contexts)

    /// The saved layout presets in whichever live model is current: the tree's under
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
    /// app-launch matcher. Resolves from the LIVE model's presets.
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
    /// snapshot (KEEPING the app connection + the saved presets), then reconciles — tearing down every
    /// current session and materializing the snapshot's. The snapshot's items get FRESH ids here so a
    /// back-and-forth switch can't collide a re-used id with the live registry mid-teardown (same rule as
    /// reopen/restore). No-op for an unknown name.
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
        // Viewport bookmarks (⇧⌘1–9) are workspace-GLOBAL and anchor to the OUTGOING layout's panes +
        // coordinate frame — the preset carries none. After a context swap they all dangle (their pane
        // ids are gone AND their saved camera origins are in the outgoing frame), so recall would jump to a
        // stale coordinate. Clear them rather than mis-jump.
        workspace.bookmarks = [:]
        overviewActive = false
        // Disarm broadcast and forget the close-undo across a whole-canvas swap — a synchronized-typing
        // mode and a "reopen the pane from the OLD workspace" both make no sense in the new layout.
        setBroadcast(false)
        recentlyClosed = nil
        reseedFocusHistory() // every old pane id is re-minted — drop the now-dead quick-switch ring
        // Every outgoing pane id is orphaned — clear any pending request keyed to one (else a busy-close
        // confirmation or rename targeting a now-gone pane lingers as a phantom dialog, the closePane
        // contract at the top of this type). Reconcile tears the outgoing sessions down.
        pendingClose = nil
        pendingTabCloseID = nil // the parked tab-close id belongs to the OUTGOING workspace
        pendingWindowClose = nil // the parked window-close session id belongs to the OUTGOING workspace
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
        // Re-check on the MainActor, right before dialing, that the pane is STILL backed by the SAME
        // handle. The guard above resolves synchronously, but the dial runs in a detached Task; if
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
    /// admission guard ``activateVideo(_:)`` uses, with NO mutation. The view layer consults
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
        // Count panes whose video stack is still TEARING DOWN against the cap too: an orphan
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
    /// so an on-screen pane sitting gated re-attempts admission. The `wasActive`
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
    /// LOOPS to a fixpoint: a teardown task awaits on the main actor, so a `reconcile()` that
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
        // against the cap.
        tearingDownVideo.removeAll()
    }

    // MARK: - Bootstrap from environment (automation seams)

    /// Builds the INITIAL workspace from the automation env vars (docs/22 §7), replacing the current
    /// `workspace` and reconciling. It only sets up SHAPE + INTENT (endpoints pre-filled) — it does
    /// **not** connect or open video; the connect / autotype / video-open TRIGGER stays in the view
    /// layer, and the env-var names are fixed by `check-macos.sh` / `check-video.sh`.
    ///
    /// - `SLOPDESK_AUTOCONNECT_HOST` + `SLOPDESK_AUTOCONNECT_PORT` ⇒ the app ``Workspace/connection`` target is
    ///   that host:port and pane 0 is a plain terminal (it rides the app connection).
    /// - `SLOPDESK_VIDEO_AUTOCONNECT_HOST` + media/cursor ports + window id ⇒ the app target is that host
    ///   (+ video ports) and pane 0 is a `.remoteGUI` for that window (video takes precedence). Title
    ///   from `SLOPDESK_VIDEO_AUTOCONNECT_TITLE` if set.
    /// - neither set ⇒ the plain default single-terminal workspace.
    ///
    /// `automationInputs`: the process environment overlaid with any `KEY=VALUE` launch argument whose key
    /// begins with `SLOPDESK_`. The env vars are the canonical seam, but a GUI-session launch cannot always
    /// inject env (e.g. `open --args …` over SSH, no way to set the child's env without root); passing the
    /// same `SLOPDESK_…=value` tokens as launch arguments is the equivalent — a matching argument overrides
    /// the inherited env.
    public static func automationInputs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
    ) -> [String: String] {
        var inputs = environment
        // Skip argv[0] (the executable path); a matching `SLOPDESK_…=value` argument overrides env.
        for arg in arguments.dropFirst() {
            guard arg.hasPrefix("SLOPDESK_"), let eq = arg.firstIndex(of: "=") else { continue }
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
            // The live tree is what the IDE shell binds, so the automation bootstrap reshapes the TREE
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
    public static func terminalTarget(from env: [String: String]) -> ConnectionTarget? {
        guard let host = env["SLOPDESK_AUTOCONNECT_HOST"], !host.isEmpty,
              let portStr = env["SLOPDESK_AUTOCONNECT_PORT"], let port = UInt16(portStr) else { return nil }
        return ConnectionTarget(host: host, port: port)
    }

    /// The app target + the per-pane window from the video-autoconnect env vars, or `nil`. The terminal
    /// port defaults (the video automation only specifies UDP ports); the app target carries the host +
    /// both UDP ports so the `.remoteGUI` pane rides the shared flow.
    public static func videoTarget(from env: [String: String]) -> (ConnectionTarget, VideoEndpoint)? {
        guard let host = env["SLOPDESK_VIDEO_AUTOCONNECT_HOST"], !host.isEmpty,
              let mediaStr = env["SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT"], let media = UInt16(mediaStr),
              let cursorStr = env["SLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT"], let cursor = UInt16(cursorStr),
              let widStr = env["SLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID"], let wid = UInt32(widStr) else { return nil }
        let title = env["SLOPDESK_VIDEO_AUTOCONNECT_TITLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "Remote window"
        let port = env["SLOPDESK_AUTOCONNECT_PORT"].flatMap { UInt16($0) } ?? 7420
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

    // MARK: - Tree-path mutations (delegate to WorkspaceTreeOps, then reconcileTree)

    /// The tree-of-intent mutation surface (docs/42), alongside the canvas methods. Each method applies a
    /// **pure** ``WorkspaceTreeOps`` transform (returns a new ``TreeWorkspace``) and then calls
    /// ``reconcileTree()`` to materialize/orphan the registry — the exact shape of the canvas mutations,
    /// driven by the tree model. They keep the **specs == leafIDs invariant** (the ops do). They belong to
    /// the ``LiveModel/tree`` path ONLY: on a canvas-driven store they would orphan its canvas panes. The
    /// kind is taken EXPLICITLY (`kind:`) — these methods do NOT resolve ``SettingsKey/defaultPaneKind``; it
    /// is the CALLER (the command routing, as for `addPane`) that resolves the user's default before
    /// invoking them.

    /// Splits the active pane along `axis`, inserting a new leaf of `kind` (focused). `leading == true`
    /// places the new leaf on the LEADING side of the active pane (left of a `.horizontal` split / above a
    /// `.vertical` split) — the split-left (⌘⌥D) / split-up (⌘⌥⇧D) chords; the default `false` keeps the
    /// natural trailing insert (the ⌘D right / ⌘⇧D down split). Tree no-op when there is no active pane.
    public func splitActivePane(axis: SplitAxis, kind: PaneKind, leading: Bool = false) {
        splitActivePane(axis: axis, kind: kind, leading: leading, launchGrace: .milliseconds(1400))
    }

    /// Core of ``splitActivePane(axis:kind:leading:)``. `launchGrace` is kept for call-site + overload parity
    /// with the paths that still schedule a deferred send, but this path types no startup `cd` — the
    /// inherited cwd rides `channelOpen` (host-side spawn), so the grace is unused here (`_`).
    func splitActivePane(axis: SplitAxis, kind: PaneKind, leading: Bool, launchGrace _: Duration) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        // Resolve the new pane's initial cwd from the NEW-SPLIT working-directory policy against the active
        // pane's last-known cwd and stamp it on the new spec. The live session factory sends that cwd in the
        // mux `channelOpen`, so the host spawns the PTY there directly.
        let activeCwd = inheritableCwd(of: active)
        let inheritedCwd = SettingsKey.workingDirectoryNewSplit.resolve(activePaneCwd: activeCwd)
        var spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        spec.lastKnownCwd = inheritedCwd
        // `splitPane` already makes the new leaf the active pane, so the split lands focused.
        let (next, _) = WorkspaceTreeOps.splitPane(active, axis: axis, newSpec: spec, before: leading, in: tree)
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
        // When `target` is its tab's SOLE tiled leaf, closing it cascades the whole TAB away — capture the
        // tab for ⇧⌘T reopen BEFORE the op mutates the tree (the cascade can also drop the session, so the
        // pre-mutation snapshot is the only source). A pane that is one of several leaves leaves its tab
        // alive, so nothing is recorded.
        if let removedTab = tabRemovedByClosing(target) { recordClosedTab(removedTab) }
        tree = WorkspaceTreeOps.closePane(target, in: tree)
        reconcileTree()
    }

    /// The ``TabID`` that closing leaf `target` would REMOVE — i.e. `target` is the only leaf in its tab,
    /// so the close empties the tree and cascades the tab away. `nil` when the tab survives the close
    /// (more than one leaf) or `target` is absent. Lets the close paths capture the whole tab for reopen
    /// BEFORE the op drops it.
    private func tabRemovedByClosing(_ target: PaneID) -> TabID? {
        guard let (sIdx, tIdx) = WorkspaceTreeOps.locate(target, in: tree) else { return nil }
        let tab = tree.sessions[sIdx].tabs[tIdx]
        // The tab is removed only when `target` is the SOLE leaf (the tree prunes to empty).
        guard tab.root.leafCount == 1 else { return nil }
        return tab.id
    }

    /// Captures tab `tabID` — its split tree + every leaf's ``PaneSpec`` + the owning ``SessionID`` — onto
    /// the in-memory ``recentlyClosedTabs`` LIFO so ⇧⌘T (``reopenLastClosedPane()``) can restore it.
    /// Called BEFORE a close op mutates the tree (the cascade can drop the whole session, so the
    /// pre-mutation snapshot is the only source). Bounded at ``recentlyClosedTabsCap`` — the oldest
    /// record(s) drop off past the cap so a long open/close session never grows it unbounded. No-op if
    /// `tabID` is absent.
    func recordClosedTab(_ tabID: TabID) {
        for session in tree.sessions {
            guard let tab = session.tabs.first(where: { $0.id == tabID }) else { continue }
            let leaves = tab.allPaneIDs()
            // Skip an all-EPHEMERAL tab (a system-dialog overlay tab — the monitor auto-manages its
            // lifecycle, so "reopening" it would resurrect a dead window stream). Mirrors the canvas
            // `closePane(_:)` `!isEphemeral` reopen-slot guard: only a tab holding ≥1 real (non-ephemeral)
            // pane is worth reopening.
            let hasReopenablePane = leaves.contains { id in
                guard let spec = session.specs[id] else { return false }
                return !spec.kind.isEphemeral
            }
            guard hasReopenablePane else { return }
            // Snapshot only the closing tab's specs (its leaf set), not the whole session's side table.
            var specs: [PaneID: PaneSpec] = [:]
            for id in leaves where session.specs[id] != nil {
                specs[id] = session.specs[id]
            }
            recentlyClosedTabs.append(RecentlyClosedTab(tab: tab, specs: specs, sessionID: session.id))
            if recentlyClosedTabs.count > Self.recentlyClosedTabsCap {
                recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.recentlyClosedTabsCap)
            }
            // The record IS the undo affordance — surface it (the app wires this to the transient
            // "TAB CLOSED · ⇧⌘T REOPENS" chip). After the append so a hook observer sees the LIFO state.
            onTabCloseRecorded?()
            return
        }
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

    /// Moves tree focus in `direction` — the keyboard / menu / command-palette entry point that has no
    /// `GeometryReader` of its own. Resolves against ``treeGeometryBounds``: the view-reported layout when one
    /// has landed (``updateSolvedLayout(_:)``, wired from `SplitContainer`'s layout pass), else a nominal rect
    /// — direction is scale-invariant for the tiled tree (`moveFocusTree` re-solves into the bounds), so the
    /// ⌃⌘arrow chords are NEVER dead. Deliberately NOT gated on a layout report: a wait-for-a-report guard
    /// blocks forever if no mounted view happens to call `updateSolvedLayout`, silently no-opping every
    /// directional chord.
    public func moveFocusTreeUsingReportedLayout(_ direction: FocusDirection) {
        moveFocusTree(direction, bounds: treeGeometryBounds)
    }

    /// Adds a new tab (single leaf of `kind`) to the active session and selects it; materializes its leaf.
    /// The tab lands at the configured ``SettingsKey/newTabPosition`` (the `new-tab-position` setting): `.auto`/
    /// `.end` append, `.afterCurrent` inserts after the active tab. The ⌘T gesture
    /// (``newTerminalPane(_:)`` `.newTab`) funnels through here, so it inherits the same placement.
    public func newTab(kind: PaneKind) {
        newTab(kind: kind, launchGrace: .milliseconds(1400))
    }

    /// Core of ``newTab(kind:)``. `launchGrace` is kept for call-site + overload parity with the paths that
    /// still schedule a deferred send (chat / agent-resume call this then defer their OWN command), but this
    /// path types no startup `cd` — the inherited cwd rides `channelOpen`, so the grace is unused (`_`).
    func newTab(kind: PaneKind, launchGrace _: Duration) {
        // Resolve the new tab's initial cwd from the NEW-TAB working-directory policy against the active
        // pane's last-known cwd (none when there is no active pane) and stamp it on the new spec. The host
        // starts the PTY in that cwd; no visible startup `cd` is sent.
        let activeCwd = inheritableCwd(of: tree.activeSession?.activeTab?.activePane)
        let inheritedCwd = SettingsKey.workingDirectoryNewTab.resolve(activePaneCwd: activeCwd)
        var spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        spec.lastKnownCwd = inheritedCwd
        let (next, _) = WorkspaceTreeOps.newTab(in: tree, spec: spec, at: SettingsKey.newTabPosition)
        tree = next
        reconcileTree()
    }

    /// The `lastKnownCwd` of pane `id` sanitized as an INHERIT SOURCE for a new tab / split / window: a
    /// transient plugin-cache dir (``PaneSpec/looksLikeTransientPluginCwd(_:)`` — `…/owner---repo`) is
    /// dropped to `nil`. Without this a racing `cwd`/`gitStatus` probe that caught the shell mid zinit
    /// turbo `builtin cd` can seed the NEW pane's cwd — poisoning its spawn dir, its folder-name title,
    /// AND its By-Project group (the "new pane lands in zsh-users---zsh-autosuggestions" symptom). Mirrors the
    /// spawn-seed guard in `LivePaneSession.initialCwd` and the write guard in ``setLastKnownCwd(_:for:)``.
    /// `nil` pane / no cwd ⇒ `nil` (the policy then resolves the host default).
    private func inheritableCwd(of id: PaneID?) -> String? {
        id.flatMap { tree.spec(for: $0)?.lastKnownCwd }
            .flatMap { PaneSpec.looksLikeTransientPluginCwd($0) ? nil : $0 }
    }

    /// Closes tab `tabID` (dropping its panes) and cascades like ``closePaneTree(_:)``.
    public func closeTab(_ tabID: TabID) {
        recordClosedTab(tabID) // capture BEFORE the op drops the tab (⇧⌘T reopen)
        tree = WorkspaceTreeOps.closeTab(tabID, in: tree)
        reconcileTree()
    }

    /// Close the active tab of the active session (the ⌘⇧W "Close Tab" routing target). A no-op when
    /// there is no active tab. The tree ops cascade an emptied session / re-seed a default like
    /// `closeTab(_:)` does. Routed through ``closeConfirmationNeeded(scope:pane:)`` — under the default
    /// ``CloseConfirmationPolicy/process`` policy this closes immediately unless a pane in the tab is busy,
    /// while `.always` / `.multipleTabs` park the close behind a confirmation.
    public func closeActiveTab() {
        guard let tab = tree.activeSession?.activeTab else { return }
        if closeConfirmationNeeded(scope: .tab) {
            // Park the WHOLE tab (its `TabID`, not a single leaf): `confirmPendingClose` resolves a tab park
            // through `closeTab(_:)`, so confirming drops every pane in the tab. Parking a single leaf
            // instead would keep its siblings, regressing ⌘⇧W into a one-pane close.
            parkTabClose(tab.id)
        } else {
            closeTab(tab.id)
        }
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
        // Badge auto-clear: acknowledge any completion/done badge for every pane in the newly-active tab
        // regardless of HOW the tab switch was triggered (keyboard ⌘1–⌘9, cycleTab, NavigatorColumn, or a
        // direct selectTab call). The `NavigatorColumn.selectRow` badge loop keeps its own copy so it fires
        // even for a same-tab pane-focus that never reaches `selectTab`.
        if let tab = tree.activeSession?.activeTab {
            for id in tab.allPaneIDs() { clearAgentBadge(id) }
        }
    }

    /// Adds a new session (one tab, one leaf of `kind`) and selects it; materializes its leaf. The new
    /// session's leaf inherits the configured ``SettingsKey/workingDirectoryNewWindow`` policy (the "New
    /// Window" working-directory setting) resolved against the active pane's last-known cwd.
    public func newSession(name: String, kind: PaneKind) {
        newSession(name: name, kind: kind, launchGrace: .milliseconds(1400))
    }

    /// Core of ``newSession(name:kind:)``. `launchGrace` is kept for call-site + overload parity with
    /// `newTab` / `splitActivePane`, but this path types no startup `cd` — the inherited cwd rides
    /// `channelOpen` (host-side spawn), so the grace is unused here (`_`).
    func newSession(name: String, kind: PaneKind, launchGrace _: Duration) {
        // Resolve the new window's initial cwd from the NEW-WINDOW policy against the active pane's
        // last-known cwd (none when there is no active pane), stamp it on the new spec, and let the host
        // spawn the PTY directly in that cwd. Mirrors `newTab` / `splitActivePane`.
        let activeCwd = inheritableCwd(of: tree.activeSession?.activeTab?.activePane)
        let inheritedCwd = SettingsKey.workingDirectoryNewWindow.resolve(activePaneCwd: activeCwd)
        var spec = PaneSpec(kind: kind, title: defaultTitle(for: kind))
        spec.lastKnownCwd = inheritedCwd
        let previous = tree.activeSessionID
        let (next, _) = WorkspaceTreeOps.newSession(in: tree, name: name, spec: spec)
        tree = next
        // Keep the OUTGOING session mounted: creating + switching to a new session must not dismantle the
        // session you just left — otherwise returning to it repaints from the lossy ring.
        if let newID = tree.activeSessionID { noteActiveSessionChanged(to: newID, from: previous) }
        reconcileTree()
    }

    /// Closes session `sessionID` (dropping all its tabs/panes) and selects another (or re-seeds a default
    /// when it was the last). Reconcile tears down its leaves.
    public func closeSession(_ sessionID: SessionID) {
        tree = WorkspaceTreeOps.closeSession(sessionID, in: tree)
        noteSessionClosed(sessionID) // drop it from the keep-mounted retention LRU; keep the now-active one
        reconcileTree()
    }

    /// SESSION-RETENTION LRU: the most-recent-first session ids whose pane subtrees the
    /// keep-mounted compositor keeps MOUNTED (at `opacity 0`) even while inactive — so an A→B→A round-trip
    /// does NOT dismantle A's ghostty surfaces and repaint them from the lossy 256 KB ring (dropped prompts
    /// on unfocused panes, blank alt-screen TUIs). Capped at ``retainedSessionCap`` (active + previous;
    /// LRU-evicted beyond) so we never hold every session's live Metal surface on-window. `SplitContainer`
    /// renders a hidden layer for each retained session's tabs; retained-but-inactive sessions have no active
    /// tab, so their panes are hidden + non-interactive (and, off-screen, their video panes release their
    /// `liveVideoCap` slots via the visibility-driven lifecycle). `internal(set)` so the
    /// `WorkspaceStore+Lifecycle` retention helpers can mutate it; still not publicly settable.
    public internal(set) var retainedSessionIDs: [SessionID] = []

    /// Selects session `sessionID` — a pure active-state change (the full leaf set stays registered).
    public func selectSession(_ sessionID: SessionID) {
        noteActiveSessionChanged(to: sessionID, from: tree.activeSessionID)
        tree = WorkspaceTreeOps.selectSession(sessionID, in: tree)
        reconcileTree()
    }

    // MARK: - Tree mutations (the shell wrappers the IDE views drive)

    /// Focuses leaf `id` in the tree (sets its tab's `activePane` + selects that session/tab). The full
    /// leaf set stays registered — a pure active-state change. The IDE shell calls this on a leaf tap.
    public func focusPaneTree(_ id: PaneID) {
        guard tree.contains(id) else { return }
        let alreadyActive = tree.activeSession?.activeTab?.activePane == id
        guard !alreadyActive else { return }
        tree = WorkspaceTreeOps.focusPane(id, in: tree)
        reconcileTree()
    }

    /// ``focusPaneTree(_:)`` for a TELEPORT — a jump whose destination was not visually pointed at
    /// (⌘⇧U attention walk, a palette / Open Quickly row, a Global Search hit, a notification /
    /// connection-alert click). When the landing CROSSED a tab (or session) boundary it fires
    /// ``onCrossTabJump`` with the ``JumpBreadcrumb`` destination line, so the shell can flash a
    /// "JUMPED · session ▸ tab" orientation cue. A same-tab focus (or a no-op on a gone pane) stays
    /// silent — the cue is for the disorienting whole-viewport swap only. Deliberate navigation
    /// (a labeled rail row / tab click) keeps calling ``focusPaneTree(_:)`` directly: the user chose
    /// that destination by name, so a chip would be noise.
    public func jumpToPaneTree(_ id: PaneID) {
        let beforeTab = tree.activeSession?.activeTab?.id
        focusPaneTree(id)
        guard let session = tree.activeSession, let tab = session.activeTab,
              tab.id != beforeTab, tab.contains(id) else { return }
        onCrossTabJump?(JumpBreadcrumb.text(
            sessionName: session.name,
            tabTitle: JumpBreadcrumb.tabDisplayTitle(tab: tab, specs: session.specs),
            includeSession: tree.sessions.count > 1,
        ))
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

    /// Renames PANE `id` by writing its spec `title` (the rail row displays the pane-spec title via
    /// ``RailRowsBuilder/rowTitle(kind:spec:)``, whose precedence lets an explicit rename WIN over the cwd
    /// folder name). A blank/whitespace title is a no-op — clearing back to the folder name is done by not
    /// renaming, never by storing an empty title (which the row would then have to special-case). Live-model
    /// aware via ``updateSpecLive(_:_:)``, so the rename persists in whichever model is current.
    ///
    /// Also sets ``PaneSpec/userRenamed`` — the unambiguous "this title is a custom user identity" flag
    /// ``RailRowsBuilder/rowTitle(kind:spec:processLabel:)`` gates the rename branch on. Inferring the flag
    /// from `title != lastKnownTitle` instead misfires for shells that emit changing OSC titles.
    public func renamePane(_ id: PaneID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateSpecLive(id) {
            $0.title = trimmed
            $0.userRenamed = true
        }
    }

    /// Renames session `sessionID`. Pure metadata — the leaf set is unchanged.
    public func renameSession(_ sessionID: SessionID, to name: String) {
        tree = WorkspaceTreeOps.renameSession(sessionID, to: name, in: tree)
        reconcileTree()
    }

    // MARK: - Tree command-routing conveniences (the keyboard/menu/palette entry points)

    /// Splits the active pane along `axis`, inserting a leaf of the user's default kind (Settings ▸
    /// Canvas). The command/menu/palette "split right/down" entry — it resolves the default kind here,
    /// because the CALLER, not the tree ops, owns default-kind resolution.
    public func splitActivePaneDefault(axis: SplitAxis) {
        splitActivePane(axis: axis, kind: SettingsKey.defaultPaneKind)
    }

    /// Adds a tab to the active session carrying the user's default-kind leaf. The "new tab" command entry.
    public func newTabDefault() {
        newTab(kind: SettingsKey.defaultPaneKind)
    }

    /// The SINGLE source of the default new-session name — "Session N" where N is one past the current
    /// session count, so a created session is never blank. Every session-minting path (the agent control
    /// backend, session templates) names through THIS, so the paths can never drift.
    public var defaultSessionName: String {
        "Session \(tree.sessions.count + 1)"
    }

    // MARK: - Launch presets (Warp launch-configuration parity)

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
    /// side-collection (presets / templates) edit seam for cross-file store extensions, mirroring
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

    // MARK: - Find-in-terminal

    /// Opens the ⌘F find bar over the active pane (the keyboard / menu / right-click "Find…" entry). Routes
    /// to the active terminal's ``TerminalViewModel/onRequestFind`` (set by ``TerminalScreenView``); a no-op
    /// for a non-terminal active pane or an empty shell. The find bar's PURE engine is
    /// ``TerminalSearchController`` (unit-tested).
    public func requestFindInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let live = registry[active] as? LivePaneSession else { return }
        live.terminalModel?.onRequestFind?()
    }

    // MARK: - Global Search (cross-tab scrollback search)

    /// The most-recent Global Search results (⇧⌘F), or `nil` before the first run. IN-MEMORY only (NOT
    /// persisted) — a relaunch starts blank. `@Observable` (a normal stored var) so `GlobalSearchView`
    /// re-renders as results land; `private(set)` so only ``runGlobalSearch(query:caseSensitive:isRegex:)``
    /// mutates it. Reopening ⇧⌘F shows the last results until the query is re-run.
    public private(set) var globalSearch: GlobalSearchResults?

    /// The query / flags the last Global Search ran with (so the overlay restores its field + `Aa`/`.*` pills
    /// when reopened). IN-MEMORY only; mutated only by ``runGlobalSearch(query:caseSensitive:isRegex:)``.
    public private(set) var globalSearchQuery: String = ""
    public private(set) var globalSearchCaseSensitive = false
    public private(set) var globalSearchRegex = false

    /// The per-pane scrollback sources for the OPEN ⇧⌘F overlay, mirrored across the libghostty seam
    /// ONCE per overlay-open (``beginGlobalSearchSession()``) and reused for every keystroke's in-memory match
    /// pass (``runGlobalSearch(query:caseSensitive:isRegex:)``) — so typing does NOT re-snapshot the full
    /// scrollback of every pane across the seam on each character. `nil` while the overlay is closed (dropped
    /// by ``endGlobalSearchSession()``); a re-open re-snapshots fresh scrollback. `@ObservationIgnored`: a
    /// derived buffer, not view state (the rendered `globalSearch` results carry the observation).
    @ObservationIgnored private var globalSearchSourceCache: [GlobalSearchSource]?

    /// Moves (swaps) the active pane with its geometric neighbour in `direction` (Zellij "move pane") —
    /// the keyboard/menu/palette entry point that has no `GeometryReader` of its own. Mirrors
    /// ``moveFocusTreeUsingReportedLayout(_:)``: resolves against ``treeGeometryBounds`` (the reported
    /// layout when available, else a nominal rect — the neighbour relation is scale-invariant), so the
    /// ⌥⌘⇧arrow chords are never dead; a no-op when there is no neighbour on the requested side. The moved
    /// pane keeps focus (its `PaneID` is unchanged, so reconcile is a registry no-op). No-op without an
    /// active pane.
    public func swapActivePaneInDirection(_ direction: FocusDirection) {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        tree = WorkspaceTreeOps.movePaneInDirection(active, direction, bounds: treeGeometryBounds, in: tree)
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

    // cycleTab / selectTabNumber (the next-prev + ⌘1…⌘9 tab-navigation entries) live in
    // `WorkspaceStore+TabOrdering.swift` — pure `selectTab` conveniences, factored out to keep this class
    // body under the `type_body_length` ceiling.

    // MARK: - Rolled-up agent status (sidebar/tab dots)

    /// The per-pane Claude status the detection signals reduce to. Defaults ``ClaudeStatus/none`` for every
    /// leaf; the detection wiring (foreground-process watch + hooks + manifest fallback) feeds real verdicts
    /// in from the `LivePaneSession`. Stored on the store so the sidebar/chrome dots have a single
    /// observable source. PRUNED to the live leaf set on every reconcile, in the shared diff core alongside
    /// `selectedPanes` / `nativeFrameSize`.
    public internal(set) var paneAgentStatus: [PaneID: ClaudeStatus] = [:]

    /// The per-pane host-provided agent LABEL (the type-27 `label`: the blocking prompt / last assistant
    /// line) — the cheap, host-trusted activity summary the sidebar shows under the session name. No
    /// scrollback access, no LLM, no round-trip; carried verbatim on the wire. PRUNED to the live leaf
    /// set alongside ``paneAgentStatus``. An empty / whitespace label is treated as absent (no key).
    public internal(set) var paneAgentLabel: [PaneID: String] = [:]

    /// The per-pane COARSE foreground-process name the host reports (wire type 26 — the display-only hint
    /// ``LivePaneSession/foregroundProcessName`` captures), mirrored onto the store so the sidebar rail
    /// can show the trailing process label ("zsh") and ``TabBadgeResolver`` can classify a `caffeinate`/`sudo`
    /// session WITHOUT reaching into the private handle. Written by ``setForegroundProcess(_:for:)`` from
    /// ``handleAgentSignal(id:event:)``; an empty / whitespace name removes the key. PRUNED to the live leaf
    /// set alongside ``paneAgentStatus``.
    public internal(set) var paneForegroundProcess: [PaneID: String] = [:]

    /// The per-pane OSC 9;4 PROGRESS mirror (wire type 32) — the SINGLE observable source the sidebar
    /// tab badge (via ``TabBadgeResolver`` → ``RailRowsBuilder``) and the macOS Dock aggregate
    /// (``rollupProgress(forSession:)``) both read. Written by ``handleProgress(_:for:)`` from each live
    /// pane's `.progress` event (``Connection/ConnectionViewModel`` `onProgressUpdate` → the store hook in
    /// `wireMaterializedLeaf`); a ``ProgressState/clear`` removes the key. A progress edge bumps
    /// ``completionFlashTick`` so the rail repaints. PRUNED to the live leaf set alongside
    /// ``paneForegroundProcess``. The methods live in `WorkspaceStore+Progress.swift`; the stored dict stays
    /// here so `@Observable` synthesises on it.
    public internal(set) var paneProgress: [PaneID: PaneProgress] = [:]

    /// The per-pane ``AgentBadgeGates`` OVERRIDE map — the tab-context-menu badge toggles. An absent key ⇒
    /// the pane follows the GLOBAL default (``SettingsKey/agentBadgeGates``); ``agentBadgeGates(for:)``
    /// resolves override-else-global, and ``RailRowsBuilder`` feeds it to ``TabBadgeGating/resolve(...)``.
    /// Pure VIEW state, NOT persisted (a runtime affordance, like ``paneReadOnly``). PRUNED to the live leaf
    /// set alongside ``paneAgentStatus``.
    public internal(set) var paneAgentBadgeOverrides: [PaneID: AgentBadgeGates] = [:]

    // MARK: - Read-only mode (the per-pane input gate's single source of truth)

    /// The set of panes currently in READ-ONLY mode. The SINGLE observable source of truth the
    /// `🔒 READ ONLY ×` pill, the sidebar lock indicator, and ``isReadOnly(for:)`` all read — so a flip
    /// from ANY entry point (the pill `×`, the View-menu item, the command-palette term, or a programmatic
    /// `setPaneReadOnly`) converges to one value. Written by the per-pane seams in
    /// `WorkspaceStore+ReadOnly.swift` AND mirrored from each live ``TerminalViewModel/onReadOnlyChanged``
    /// (wired in ``wireMaterializedLeaf``). Pure VIEW state, NOT persisted (a runtime toggle — no launch
    /// config key). PRUNED to the live leaf set alongside ``paneAgentStatus``.
    public internal(set) var paneReadOnly: Set<PaneID> = []

    // MARK: - Sidebar tab mirrors (the sidebar is ALWAYS grouped By-Project, in creation order)

    /// The per-TAB MANUAL status-badge override set by `slopdesk tab badge --kind <kind>`
    /// (the client-control CLI). An EXPLICIT override that wins over the per-pane DERIVED badge
    /// (``TabBadgeResolver`` — agent / completion / busy / progress) for the tab's REPRESENTATIVE (active)
    /// pane row in the sidebar rail and the `tab list` badge column. Keyed by ``TabID`` (the badge is
    /// per-tab); being explicit, it bypasses the per-pane agent-badge gates. Pure VIEW state, NOT persisted
    /// (a runtime affordance like ``paneAgentBadgeOverrides``). Written by
    /// ``setTabBadgeOverride(_:for:)``; PRUNED on every ``reconcileTree()`` (TabID-keyed → in
    /// ``pruneTreeSidebarMirrors``, not the pane-keyed prune).
    public internal(set) var tabBadgeOverrides: [TabID: TabBadgeKind] = [:]

    /// Per-pane compact git summary (branch / ahead / behind / changed count) — the sidebar tab row's
    /// SECOND LINE (``PaneGitSummary/compactLine``; the row falls back to the plain cwd when a pane has
    /// no entry / no repo). Refreshed via ``refreshGitSummary(for:from:)`` on command completion (OSC
    /// 133;D), on a cwd change, and once on connect; PRUNED to the live leaf set alongside the other
    /// per-pane mirrors. Runtime-only; never persisted.
    public internal(set) var paneGitSummary: [PaneID: PaneGitSummary] = [:]

    /// Panes with an in-flight git-summary `gitStatus` fetch — de-dupes concurrent requests (a completion
    /// burst must not fan out N identical RPCs). Cleared as each reply lands (or is dropped).
    private var paneGitSummaryInFlight: Set<PaneID> = []

    /// When each pane's ``paneGitSummary`` entry was last fetched — the freshness clock the
    /// ~3 s RTT-snapshot edge consults so a quiet ACTIVE pane re-fetches its stale git line at most once per
    /// ``gitSummaryStaleWindow`` (bounded, never a poll). Stamped by ``applyGitSummary(_:toplevel:for:at:)``,
    /// PRUNED to the live leaf set alongside ``paneGitSummary``. Runtime-only; never persisted.
    public internal(set) var paneGitFetchedAt: [PaneID: Date] = [:]

    /// The COALESCING memory for the attention notification: the last status we fired an
    /// attention edge for, per pane. So a flap that re-enters the same attention state (`done → working →
    /// done`) does not re-notify — only a transition INTO `needsPermission`/`done` from the last-notified
    /// state fires. PRUNED with `paneAgentStatus` so a recycled / closed pane id can't leak or mis-flap.
    var lastNotifiedStatus: [PaneID: ClaudeStatus] = [:]

    /// The THIN attention-notification sink (the same seam shape as ``onLongCommandNotify`` /
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

    // MARK: - Background-pane command-completion awareness (badge + focus-gated notify)

    /// The per-pane "a command finished while you were elsewhere" badge: a green ✓ / red ✗ a BACKGROUND
    /// pane carries until you look at it (mirrors ``paneAgentStatus``). Set only for an UNFOCUSED pane,
    /// cleared when the pane gains focus (or the app returns active). PRUNED to the live leaf set alongside
    /// ``paneAgentStatus``. `internal(set)` so the badge mutators in `WorkspaceStore+Completion.swift` (a
    /// same-module extension) can write it; still read-only to other modules.
    public internal(set) var panePendingCompletion: [PaneID: PaneCompletionBadge] = [:]

    /// RUNTIME-ONLY per-pane "when did this clean completion land" mirror — the EPHEMERAL `completedAt` that
    /// lets the badge flash decay from ``TabBadgeKind/completed`` (the brief checkmark) to
    /// ``TabBadgeKind/finished`` (the persistent accent dot). Stamped on a `.success` completion-badge edge
    /// (``setCompletionBadge(_:for:)``) and on an agent's entry into ``ClaudeStatus/done``
    /// (``setAgentStatus(_:for:)``); read by ``completionFreshness(forPane:now:)`` vs "now". NOT persisted
    /// (it resets on relaunch, harmlessly); PRUNED to the live leaf set alongside ``panePendingCompletion``.
    public internal(set) var paneCompletedAt: [PaneID: Date] = [:]

    /// RUNTIME-ONLY per-pane "when did this pane last see an attention-relevant edge" mirror — the `since`
    /// FALLBACK for the titlebar dot's NEEDS-ATTENTION breakdown (``UnseenAttentionEntry/since``) when no
    /// clean-completion stamp exists (a BLOCKED `needsPermission` agent / a `.failure` badge never stamps
    /// ``paneCompletedAt``). Stamped by the ``setAgentStatus(_:for:at:)`` chokepoint (genuine transitions
    /// only) and the ``setCompletionBadge(_:for:at:)`` set-edge. Per-PANE (not per-tab), so a tab-level
    /// recency stamp cannot stand in for it. NOT persisted; PRUNED to the live leaf set alongside
    /// ``paneCompletedAt``.
    public internal(set) var paneAttentionAt: [PaneID: Date] = [:]

    /// RUNTIME-ONLY per-pane "when did the current foreground command start" stamp — the busy-dot
    /// REVEAL anchor ``paneShowsBusyDot(_:now:)`` compares against "now" so the plain
    /// ``TabBadgeKind/commandBusy`` dot appears only once a command has run past the configured delay.
    /// Stamped on the command-START edge (``handleCommandStarted(id:at:)`` — which also arms the one-shot
    /// that re-renders the rail at the reveal boundary), cleared on completion. NOT persisted;
    /// PRUNED to the live leaf set alongside ``paneCompletedAt``.
    public internal(set) var paneCommandStartedAt: [PaneID: Date] = [:]

    /// How long a clean completion shows its brief ``TabBadgeKind/completed`` checkmark flash before it
    /// settles to the persistent ``TabBadgeKind/finished`` accent dot. Short — the flash is meant to be a beat,
    /// not a dwell — but long enough to register. Compared against ``paneCompletedAt`` in
    /// ``completionFreshness(forPane:now:)``.
    public static let completedFlashWindow: TimeInterval = 3

    /// A lightweight monotonic counter the sidebar rail OBSERVES so the completion-badge flash can decay on
    /// its own. ``completionFreshness(forPane:now:)`` reads the wall clock at row-BUILD time — NOT an
    /// `@Observable` dependency — so once a quiet completed pane stops mutating the store, nothing re-renders
    /// its row and the brief ``TabBadgeKind/completed`` checkmark would stick forever (until an unrelated
    /// mutation / focusing the tab clears it). When a clean completion stamps ``paneCompletedAt``, the store
    /// arms a one-shot (``flashDecayScheduler``) that after ``completedFlashWindow`` bumps this tick → the
    /// rail re-renders EXACTLY ONCE and the row settles to the ``TabBadgeKind/finished`` dot. The bump
    /// carries no row data; it exists ONLY to invalidate the observing view at the flash-window boundary.
    public internal(set) var completionFlashTick: UInt = 0

    /// The injectable one-shot that drives the ``completionFlashTick`` bump at the flash-window boundary:
    /// called as `flashDecayScheduler(completedFlashWindow) { bump }` right after a clean completion
    /// stamps ``paneCompletedAt``. The default (``mainRunLoopFlashDecay``) fires on the main run loop — a
    /// per-completion one-shot, NOT a global per-second timer, so a quiet workspace never re-renders the rail
    /// on a tick. Tests inject a stub that CAPTURES the `bump` (and delay) and fires it synchronously, for a
    /// deterministic boundary re-render with no wall-clock `Task.sleep`. `@ObservationIgnored`: wiring, not
    /// view state (like ``onLongCommandNotify``).
    @ObservationIgnored
    public var flashDecayScheduler = WorkspaceStore.mainRunLoopFlashDecay

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

    /// The THIN long-command notification sink: the app sets it to call
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
    // block ops). The stored properties stay here because `@Observable` synthesises on them.

    // MARK: - reconcileTree (the LIVE tree path)

    /// The tree-driven counterpart of ``reconcile()``, diffing `tree.allPaneIDs()` against the registry.
    /// Delegates the whole load-bearing diff to the shared
    /// ``reconcileRegistry(desiredLeafIDs:spec:onMaterialize:)`` — the same orphan-remove-then-teardown,
    /// `tearingDownVideo` ceiling-accounting, cache pruning, and `makeSession`/`adopt(id:)` materialize the
    /// canvas path uses — but sourced from ``tree`` via `tree.spec(for:)`.
    ///
    /// It wires the SAME per-leaf side effects the canvas `reconcile()` does (pane-rebind /
    /// `onEndpointCommitted`, OSC-9 `onExplicitNotification`), marks the autotype target, syncs the focus
    /// coordinator to the TREE's active pane, and schedules the debounced save. Those side effects are inert
    /// for the pure-diff unit tests (`FakePaneSession` is not a `LivePaneSession`, and such stores carry no
    /// `persistence`), so the tree-reconcile suite still pins the bare diff. Idempotent.
    public func reconcileTree() {
        reconcileRegistry(
            desiredLeafIDs: tree.allPaneIDs(),
            spec: { tree.spec(for: $0) },
            onMaterialize: { [weak self] id, handle in
                self?.wireMaterializedLeaf(id: id, handle: handle)
            },
        )
        // Mark the SLOPDESK_AUTOTYPE target (the first leaf in DFS order) + sync the focus coordinator to
        // the tree's active pane (the iPad-regular first-responder arbiter), then debounce-save. Mirrors the
        // canvas `reconcile()` tail; the model-aware save persists the tree (see `scheduleSave`).
        let autotypeTarget = tree.allPaneIDs().first
        for (id, handle) in registry {
            (handle as? LivePaneSession)?.isAutotypeTarget = (id == autotypeTarget)
        }
        if let focused = tree.activeSession?.activeTab?.activePane, focusCoordinator.focusedPane != focused {
            focusCoordinator.focus(focused)
        }
        // A pane that just gained focus (selectTab / selectSession / focusPaneTree all route here) is being
        // watched — clear its pending command-completion badge.
        clearActiveLeafCompletionBadge()
        // Prune the tree-keyed sidebar mirrors (the manual tab badges) to the live tree. Keyed by
        // TabID, so pruned here against the tree rather than in the pane-keyed `reconcileRegistry`
        // cache-prune. The helper lives in WorkspaceStore+TabOrdering.
        pruneTreeSidebarMirrors()
        scheduleSave()
    }

    /// The per-new-leaf wiring the live reconcile runs for a materialized ``LivePaneSession`` — factored
    /// out of the canvas `reconcile()`'s `onMaterialize` closure so the tree path and the canvas path
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
        // CLAUDE AUTO-DETECT: fold the agent-detection wire signals (types 26/27) into this pane's
        // ClaudeStatusMachine and mirror the result into `paneAgentStatus` (→ the sidebar/tab/chrome dots).
        connection?.onAgentSignal = { [weak self] event in
            self?.handleAgentSignal(id: id, event: event)
        }
        // Forward this pane's fresh-vs-resumed reconnect verdict to the app's toast sink, tagged with the
        // pane id so the "reattached / fresh shell" toast identifies (and can focus) it.
        connection?.onResumeOutcomeResolved = { [weak self] outcome in
            self?.onSessionResumeOutcome?(id, outcome)
        }
        // OSC 9;4 PROGRESS (wire type 32): mirror this pane's validated taskbar-style progress into
        // `paneProgress` (→ the sidebar tab badge + the macOS Dock aggregate). A `.clear` arrives as `nil` and
        // removes the indicator; `handleProgress` bumps `completionFlashTick` on an edge so the rail repaints.
        connection?.onProgressUpdate = { [weak self] progress in
            self?.handleProgress(progress, for: id)
        }
        // OSC 7 cwd edge: keep the spec's inheritance source fresh as soon as the shell reports `cd`.
        connection?.onWorkingDirectoryChanged = { [weak self] cwd in
            self?.setLastKnownCwd(cwd, for: id)
        }
        // HOST-computed By-Project key (wire type 34): persist every pushed edge into the pane spec so the
        // sidebar sections render from the host's truth (and a cold relaunch renders them from disk).
        connection?.onProjectKeyChanged = { [weak self] key in
            self?.setProjectKey(key, for: id)
        }
        // COMMAND-START STALE-BADGE CLEAR (progress-state.md): a new command beginning (OSC 133;C) clears this
        // pane's stale completion ✓/✗ so a busy background pane resolves to the running spinner, not the prior
        // run's exit badge.
        connection?.onCommandStarted = { [weak self] in
            self?.handleCommandStarted(id: id)
        }
        // BACKGROUND-PANE COMMAND-COMPLETION: route a finished command (OSC 133;D, type 23) to the
        // focus-gated store handler — badges an UNFOCUSED pane (✓/✗) and fires the long-command
        // notification only when backgrounded.
        connection?.onCommandCompleted = { [weak self, weak connection] exitCode, durationMS in
            guard let self else { return }
            // See ``PaneSpec/completionNotificationTitle`` — prefers the live OSC 0/2 shell title over
            // the static spec title so the banner/toast identifies WHICH command/directory finished.
            let title = tree.spec(for: id)?.completionNotificationTitle ?? ""
            handleCommandCompleted(id: id, exitCode: exitCode, durationMS: durationMS, paneTitle: title)
            // cwd-freshness fallback: refresh this pane's last-known cwd from the host `cwd` RPC on
            // command completion too, so shells without OSC 7 still update the inherit source for the next
            // new tab / split. `[weak connection]` avoids a retain cycle (the closure is owned by `connection`).
            refreshCwd(for: id, from: connection)
            // The sidebar git line follows every completed command (a commit / checkout / touch changes
            // branch + dirty state) — same validate-then-drop RPC idiom as the cwd refresh above.
            refreshGitSummary(for: id, from: connection)
        }
        // LIVE TITLE PERSISTENCE: persist the shell's live OSC title into lastKnownTitle so a relaunch can
        // restore the tab title for untouched (default-titled) panes. The dirty guard avoids a needless
        // reconcile + save when the title didn't actually change.
        connection?.onTitleChanged = { [weak self] title in
            self?.updateSpecLive(id) { spec in
                guard spec.lastKnownTitle != title else { return }
                spec.lastKnownTitle = title
            }
        }
        // RESUME IDENTITY CAPTURE (SLOPDESK_DETACH_ENABLED): persist the live session UUID +
        // highest-contiguous-seq into the spec on each RTT snapshot (~3 s cadence) and on reconnect
        // so the next launch can feed them into seedResumeIdentity → RETURNING_CLIENT reattach.
        connection?.onResumeIdentitySnapshot = { [weak self, weak connection] sessionID, seq in
            guard let self else { return }
            updateSpecLive(id) { spec in
                guard spec.resumeSessionID != sessionID || spec.resumeLastReceivedSeq != seq else { return }
                spec.resumeSessionID = sessionID
                spec.resumeLastReceivedSeq = seq
            }
            // GIT-LINE population/staleness on the RTT-snapshot edge (~3 s): populate once when absent
            // (a freshly-attached pane gets its line before the first OSC 133;D), then re-fetch ONLY the
            // ACTIVE pane and ONLY when its cached line is older than `gitSummaryStaleWindow` — so a pane
            // that sits idle after the first populate still self-heals its line (a sibling-pane commit / a
            // detached-session drift) without the snapshot cadence becoming a git-status poll. A genuine
            // reconnect refreshes unconditionally via `onReconnected` below.
            if shouldRefreshGitOnSnapshot(id) {
                refreshGitSummary(for: id, from: connection)
            }
            // HOST-AUTHORITATIVE cwd on ATTACH: a shell that emits no OSC-7 (Starship / hookless) never
            // reports its cwd until a command completes, so a freshly-connected pane's title sits at the
            // "Terminal" fallback. The snapshot edge is the earliest recurring post-connect signal — pull the
            // host cwd ONCE here (populate-once gate) so the folder-name title lands without waiting for a
            // command. The gate closes the moment `lastKnownCwd` is set, so this never becomes a cwd poll.
            // `retries` collapses the up-to-3 s wait for the FIRST landing into ~1 s when the metadata client
            // is briefly not ready at the first snapshot (it self-heals via the cadence regardless).
            if shouldRefreshCwdOnAttach(id) {
                refreshCwd(for: id, from: connection, retries: 3)
            }
        }
        // RECONNECT git-line refresh: a REAL reconnect edge (distinct from the steady-state RTT snapshot
        // above) spawns a fresh host shell and may have missed sibling-pane commits / detached drift while
        // the link was down — ALWAYS re-fetch this pane's git line. Fires once per reconnect, so it is not
        // a poll.
        connection?.onReconnected = { [weak self, weak connection] in
            guard let self else { return }
            refreshGitSummary(for: id, from: connection)
            // HOST-AUTHORITATIVE cwd on RECONNECT: a mux reconnect may have RESPAWNED a fresh host
            // shell (no server-side resume), so this pane's live cwd is only knowable from the host. Pull
            // it via the `proc_pidinfo` `cwd` RPC (shell-agnostic — needs no OSC-7) so the cwd-derived
            // title re-lands immediately instead of collapsing to "Terminal" until the next command
            // completes. Paired with the unconditional `initialCwd` hint (SlopDeskClient.connect) that
            // puts the respawned shell back in the project dir, so this reads the RIGHT cwd, not `$HOME`.
            // `retries` matters MOST here: the reconnect edge has no populate-once cadence to fall back on
            // (`lastKnownCwd` is already non-nil), so a single-shot pull that raced the control plane would
            // never re-fire — the bounded retry guarantees the fresh-shell cwd re-lands.
            refreshCwd(for: id, from: connection, retries: 3)
            // INSPECTOR RE-ARM across a link flap: the inspector second channel (terminal port + 1) dies
            // with the same link drop, but the host's reattach re-assert re-emits the SAME type-27
            // status — the `applyDetectedStatus` dedupe guard eats it, so the status transition can
            // never re-open the channel (and macOS never drives pause()/resume()). This reconnect edge
            // is the one once-per-flap signal left: tear down the stale client and re-subscribe fresh
            // (full re-tail; the model's upsert/dedup makes the replay safe). Resolved from the registry
            // at fire time (not captured) so a pane torn down mid-flap is a clean no-op; a `.none` pane
            // no-ops inside the session.
            (registry[id] as? LivePaneSession)?.reestablishInspectorOnReconnect()
        }
        // SYNC-INPUT (tree path, Zellij ToggleActiveSyncTab): when the per-tab sync flag is on, mirror this
        // pane's keystrokes into every other pane in its tab via the same broadcastTap seam the canvas
        // broadcast path uses. The `fanSyncInput` guard (shared `isFanningBroadcast` flag) prevents a
        // sibling's re-entrant sendInput from looping back into another fan-out. A no-op while disarmed.
        let terminal = (handle as? LivePaneSession)?.terminalModel
        terminal?.broadcastTap = { [weak self] data in self?.fanSyncInput(from: id, data) }
        // TILING from the terminal surface: the renderer's right-click "Split Right/Down" fires
        // `onContextMenuSplit` (the rebindable ⌘D/⌘⇧D flows through `wireKeyInterceptor` → the shared
        // `route(...)`, not here). A split MINTS a pane, so it offers the pane-type chooser (terminal / remote
        // window), not a hard-coded terminal. Focus THIS pane first so the chooser's active-pane split targets
        // the surface the user acted on. No chooser host (headless / no titlebar) → a direct terminal split.
        // `true` = side-by-side (horizontal), `false` = stacked (vertical).
        terminal?.onContextMenuSplit = { [weak self] horizontal in
            self?.splitFromContextMenu(paneID: id, horizontal: horizontal)
        }
        // Hand the libghostty surface its PURE keybinding interceptor (prefix engine + override-aware
        // single-chord table). The helper lives in WorkspaceStore+Keybinding so this body stays under the
        // lint ceiling (same pattern as `seedBlockBookmarks`).
        wireKeyInterceptor(terminal: terminal)
        // FOCUS-ON-CLICK: the surface's mouseDown calls `onRequestFocus`; route it to the tree focus so the
        // workspace focus (chrome / inspector / which pane the next split or close targets) follows a click.
        terminal?.onRequestFocus = { [weak self] in self?.focusPaneTree(id) }
        // READ-ONLY convergence: mirror a flip of THIS pane's input gate — by the pill `×`,
        // the View-menu item, the command-palette term, or the model's own toggle — into the store's
        // `paneReadOnly` set (the single source the pill + the sidebar lock both read). The closure writes
        // the set DIRECTLY (not back through `setPaneReadOnly`, which also drives the model) so there is no
        // re-entrant loop with the model's `isReadOnly` didSet; both writers land the same value, idempotent.
        terminal?.onReadOnlyChanged = { [weak self] on in
            guard let self else { return }
            if on { paneReadOnly.insert(id) } else { paneReadOnly.remove(id) }
        }
        // BOOKMARKS: seed the pane's block model from persistence + wire its change closure to persist
        // back (the helper lives in WorkspaceStore+Blocks so this body stays under the lint ceiling).
        seedBlockBookmarks(id: id, handle: handle)
    }

    /// Folds one Claude-Code agent-detection event (wire types 26/27) for pane `id` into the owning
    /// ``LivePaneSession``'s state machine, then mirrors the new ``ClaudeStatus`` into ``paneAgentStatus``
    /// so the sidebar/tab/chrome ``AgentStatusDot``s light up live. The session owns the dedupe + the
    /// dynamic inspector open/close; `setAgentStatus` is itself idempotent.
    private func handleAgentSignal(id: PaneID, event: SlopDeskClient.Event) {
        guard let session = registry[id] as? LivePaneSession else { return }
        let status = session.feedAgentSignal(event)
        // CAPTURE the cheap host-provided label (the type-27 blocking prompt / last line) for the sidebar
        // activity summary — set BEFORE setAgentStatus so an attention edge's notification detail reads the
        // fresh label. type 26 carries no label, so only type 27 updates it.
        if case let .claudeStatus(_, _, label) = event {
            setAgentLabel(label, for: id)
        }
        // Mirror the COARSE foreground-process name (wire type 26) onto the store so the sidebar
        // rail's trailing process label + the `caffeinate`/`sudo` ``TabBadgeResolver`` classification can
        // read it without reaching into the private handle. Display-only — it never touches the agent
        // status (the type-27 verdict stays authoritative, exactly as `LivePaneSession.feedAgentSignal`).
        if case let .foregroundProcess(name) = event {
            setForegroundProcess(name, for: id)
        }
        // Agent activity counts as tab activity, but the recency stamp rides the genuine status change
        // INSIDE `setAgentStatus` (the per-pane status-write chokepoint) — so a working / blocked background
        // tab floats up under the `.updated` sort, and non-wire status writes stamp too. A blanket
        // per-signal stamp HERE would be wrong: it also fires on a type-26 foreground-process change, which
        // carries no status transition.
        setAgentStatus(status, for: id)
    }

    /// Updates the spec for `id` in whichever live model is active: the tree's side table when
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
    /// (`tearingDownVideo` / `videoPromotionGeneration` / the `videoTeardownSettle` teardown `Task`),
    /// per-pane cache pruning, and materialize-via-`makeSession` + `adopt(id:)` — exists ONCE. Two
    /// hand-synced copies would be a maintenance hazard: the two paths must diff IDENTICALLY. The caller
    /// supplies the canonical-order `desiredLeafIDs` + a `spec(for:)` lookup; an optional `onMaterialize`
    /// runs its per-new-leaf side wiring (pane-rebind / OSC-9). After it returns:
    ///
    ///   `Set(registry.keys) == Set(desiredLeafIDs)`
    ///
    /// Steps, in order (see ``reconcile()``'s doc for the full rationale):
    /// 1. **Prune per-pane caches** to the live leaf set (a closed/switched-away pane drops out; caches can't
    ///    grow unbounded).
    /// 2. **Orphan removal (synchronous) + teardown (async, launched not awaited)** — the registry entry is
    ///    removed synchronously so `keys == leafIDs` holds the instant this returns; an orphan holding a live
    ///    video stack keeps its cap slot (`tearingDownVideo` + the close-time / completion-site
    ///    `videoPromotionGeneration` nudges + the `videoTeardownSettle` hold) until it actually releases.
    /// 3. **Materialize new leaves** — `makeSession(spec)` + `adopt(id:)` per new leaf, then `onMaterialize`.
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
        // Evict cached native sizes for panes that are gone (else the dict leaks across a long session of
        // open/close).
        if !nativeFrameSize.isEmpty {
            nativeFrameSize = nativeFrameSize.filter { leafSet.contains($0.key) }
        }
        // Prune the per-pane mirrors below to the live leaf set in lockstep — a closed pane must drop out so
        // the dict can't grow unbounded and no stale entry surfaces in a rollup / on a recycled id.
        // Agent status (absent key reads `.none`):
        if !paneAgentStatus.isEmpty {
            paneAgentStatus = paneAgentStatus.filter { leafSet.contains($0.key) }
        }
        // Agent label + attention-notify coalescing memory: a recycled id must re-arm cleanly so the
        // next genuine edge notifies (no mis-flap).
        if !paneAgentLabel.isEmpty {
            paneAgentLabel = paneAgentLabel.filter { leafSet.contains($0.key) }
        }
        if !lastNotifiedStatus.isEmpty {
            lastNotifiedStatus = lastNotifiedStatus.filter { leafSet.contains($0.key) }
        }
        // Completion badge (✓/✗):
        if !panePendingCompletion.isEmpty {
            panePendingCompletion = panePendingCompletion.filter { leafSet.contains($0.key) }
        }
        // Completion-timestamp mirror (the badge-flash decay clock):
        if !paneCompletedAt.isEmpty {
            paneCompletedAt = paneCompletedAt.filter { leafSet.contains($0.key) }
        }
        // Attention-edge timestamp mirror (the NEEDS-ATTENTION `since` fallback):
        if !paneAttentionAt.isEmpty {
            paneAttentionAt = paneAttentionAt.filter { leafSet.contains($0.key) }
        }
        // Command-start stamp (the busy-dot reveal clock):
        if !paneCommandStartedAt.isEmpty {
            paneCommandStartedAt = paneCommandStartedAt.filter { leafSet.contains($0.key) }
        }
        // Foreground-process mirror (process label / privilege badge):
        if !paneForegroundProcess.isEmpty {
            paneForegroundProcess = paneForegroundProcess.filter { leafSet.contains($0.key) }
        }
        // Git-summary mirror (the sidebar git line):
        if !paneGitSummary.isEmpty {
            paneGitSummary = paneGitSummary.filter { leafSet.contains($0.key) }
        }
        // Git-summary freshness clock:
        if !paneGitFetchedAt.isEmpty {
            paneGitFetchedAt = paneGitFetchedAt.filter { leafSet.contains($0.key) }
        }
        // OSC 9;4 progress mirror (else a stale spinner/bar survives in a Dock rollup):
        if !paneProgress.isEmpty {
            paneProgress = paneProgress.filter { leafSet.contains($0.key) }
        }
        // READ-ONLY set (absent id reads writable). Mirrors the `selectedPanes` Set-prune idiom above
        // (intersect, not reallocate, only when needed).
        if !paneReadOnly.isEmpty, !paneReadOnly.isSubset(of: leafSet) {
            paneReadOnly.formIntersection(leafSet)
        }
        // Agent-badge override map:
        if !paneAgentBadgeOverrides.isEmpty {
            paneAgentBadgeOverrides = paneAgentBadgeOverrides.filter { leafSet.contains($0.key) }
        }

        // 2. Orphans: remove from the registry synchronously (the registry is the source of truth for
        //    "what is live"), then drive teardown. Removing first guarantees the invariant holds the
        //    instant reconcile returns, even though teardown's async cleanup completes slightly after.
        let orphans = registry.filter { !leafSet.contains($0.key) }.map(\.value)
        for orphan in orphans {
            registry.removeValue(forKey: orphan.id)
            // Hold the cap slot for an orphan that is STILL holding a live video stack. Read
            // `isVideoActive` NOW, before the async teardown nils it, and record the id so
            // `activateVideo` keeps counting it until its teardown task actually releases the resources.
            if orphan.kind.isVideo, orphan.isVideoActive {
                tearingDownVideo.insert(orphan.id)
                // Closing an ACTIVE video pane is a slot-freeing event: once this orphan's teardown
                // releases its stack, a gated on-screen sibling should re-attempt
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
                    // For a `.remoteGUI` orphan that was holding a live stack, `teardown()` only KICKS OFF
                    // the release — it sets `RemoteWindowModel.active = nil`, and the actual
                    // UDP/VTDecompression/display-link teardown happens a few runloop turns later inside the
                    // SwiftUI dismantle → `VideoWindowPipeline.deactivate()` → detached `session.stop()`.
                    // Hold the cap slot for `videoTeardownSettle` past `teardown()` so a same-tick sibling
                    // cannot be admitted while the outgoing stack is still up (transient cap+1). Only
                    // entered for an id actually IN `tearingDownVideo` (a `.remoteGUI` pane that was live)
                    // and only when a settle is configured, so the terminal-only / `.zero`-settle paths are
                    // unaffected. The sleep is cancel-safe.
                    if self.tearingDownVideo.contains(orphan.id), self.videoTeardownSettle > .zero {
                        try? await Task.sleep(for: self.videoTeardownSettle)
                    }
                    // The orphan's video resources are released — stop counting it against the cap.
                    // Serialized on the main actor with `activateVideo`'s read, so a same-tick reopen sees
                    // the slot freed only after the real release.
                    if self.tearingDownVideo.remove(orphan.id) != nil {
                        // COMPLETION-SITE nudge: the close-time bump (above) fires while this slot is STILL
                        // counted against the cap, so a same-tick gated reopen is refused and parks on the
                        // "Video paused" placeholder. Removing the id here is the instant the slot ACTUALLY
                        // frees — nudge again so that gated on-screen pane re-attempts admission now,
                        // instead of waiting for an unrelated event (another deactivate / re-appear) to
                        // happen to nudge it.
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

    // MARK: - reconcile (the single canvas diff seam)

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
    /// NOTE — same-tick close+reopen and the video ceiling: step-1 teardown is launched (not
    /// awaited) before step-2 materialize, so a same-tick close+open of two `.remoteGUI` panes would
    /// transiently overlap their live video stacks. The ceiling IS still protected without making reconcile
    /// `async`: step-1 records an orphan whose `isVideoActive` was true into `tearingDownVideo` (reading the
    /// flag BEFORE teardown nils it), the teardown task removes it after the `await`, and ``activateVideo(_:)``
    /// counts `tearingDownVideo.count` as occupied — so a new pane can't be admitted until the orphan's UDP /
    /// VTDecompression / CVDisplayLink stack actually releases. reconcile staying synchronous is deliberate
    /// (called inline by every mutation and from `init`) — awaiting teardown before materialize would ripple
    /// `async` through the whole mutation surface.
    private func reconcile() {
        // SAFETY: when the LIVE model is the tree, the canvas is retained-but-dead and its `reconcile()`
        // must NEVER run — it diffs the SAME registry against the (default, dead) canvas leaf set, which
        // would orphan + tear down every TREE-materialized handle. Any remaining caller of a canvas
        // mutation (the system-dialog monitor / notification reveal) therefore no-ops on the tree shell
        // rather than corrupting the live registry; the tree path uses `reconcileTree()`. (On a `.canvas`
        // store this guard is a pure passthrough.)
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
                // PANE REBIND: persist every committed video endpoint into the pane's spec — else a picked
                // window lives only in the RemoteWindowModel (spec `video: nil`) and a relaunch re-shows the
                // picker; a REBOUND endpoint (stale CGWindowID re-resolved by app+title) must overwrite the
                // stale id. The leaf set is unchanged by `updateSpec`, so the nested reconcile is a no-op +
                // save. The TITLE follows the binding only while it was tracking the previous binding (or
                // was never bound) — a user rename survives re-picks.
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
                // CLAUDE AUTO-DETECT: same agent-signal fold as the tree path's `wireMaterializedLeaf`.
                connection?.onAgentSignal = { [weak self] event in
                    self?.handleAgentSignal(id: id, event: event)
                }
                // COMMAND-START STALE-BADGE CLEAR: same command-start badge reset as the tree path.
                connection?.onCommandStarted = { [weak self] in
                    self?.handleCommandStarted(id: id)
                }
                // BACKGROUND-PANE COMMAND-COMPLETION: same focus-gated completion route as the tree path.
                connection?.onCommandCompleted = { [weak self] exitCode, durationMS in
                    guard let self else { return }
                    // Same live-title preference as the tree path — see ``PaneSpec/completionNotificationTitle``.
                    let title = spec(for: id)?.completionNotificationTitle ?? ""
                    handleCommandCompleted(id: id, exitCode: exitCode, durationMS: durationMS, paneTitle: title)
                }
                connection?.onWorkingDirectoryChanged = { [weak self] cwd in
                    self?.setLastKnownCwd(cwd, for: id)
                }
                // HOST-computed By-Project key (canvas path): same guarded persist as wireMaterializedLeaf.
                connection?.onProjectKeyChanged = { [weak self] key in
                    self?.setProjectKey(key, for: id)
                }
                // LIVE TITLE PERSISTENCE (canvas path): same lastKnownTitle wire as wireMaterializedLeaf.
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

        // 3. Mark the `SLOPDESK_AUTOTYPE` target (docs/22 §7): the first pane on the canvas. The store owns
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
    /// always-mounted canvas a pane's host never unmounts/re-registers, so no tab-switch `reassertFocus`
    /// is needed.
    private func syncFocusCoordinator() {
        guard let focused = workspace.focusedPane else { return }
        if focusCoordinator.focusedPane != focused {
            focusCoordinator.focus(focused)
        }
    }

    // MARK: - Persistence (debounced; cancel-safe)

    /// The workspace as it should be PERSISTED: ephemeral (auto-managed) system-dialog panes are stripped so
    /// they never survive a relaunch (the monitor re-spawns live ones on reconnect — a stale dialog windowID
    /// would otherwise stream a dead window). Focus is re-normalized in case it pointed at a stripped pane.
    /// Identity passthrough when there are none, so a normal save pays nothing.
    private func persistableWorkspace() -> Workspace {
        let ephemeral = workspace.canvas.allIDs().filter { workspace.canvas.spec(for: $0)?.kind.isEphemeral == true }
        guard !ephemeral.isEmpty else { return workspace }
        var w = workspace
        for id in ephemeral {
            w.canvas = w.canvas.removing(id) ?? Canvas(items: [], camera: w.canvas.camera)
        }
        return w.normalizingFocus()
    }

    /// The value snapshot the debounced/immediate save writes — the v10 ``TreeWorkspace`` when
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

    /// Schedules a debounced save of the value tree (docs/22 §6): cancels any pending save and starts a
    /// fresh one, so a burst of mutations writes exactly once after the quiet period. Cancel-safe (a
    /// superseded task's `Task.sleep` throws `CancellationError`, which `try?` swallows before any write). A
    /// no-op until `savingEnabled` (set after the init reconcile) and when no `persistence` is configured
    /// (the fake/test seam never touches disk). The supersession-guard-plus-atomic-write critical section
    /// lives in the body below.
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
            // The supersession re-check AND the atomic write are ONE main-actor critical
            // section: `await MainActor.run` re-checks `saveGeneration` and, only if still current, writes,
            // never releasing the actor between guard and rename. `saveImmediately()` also writes on the main
            // actor under a bumped generation, so the two RENAMES serialize there and a stale snapshot's
            // rename can never interleave between a newer write's guard and rename. `Task.cancel()` cannot
            // stop a task already past its sleep, so the generation guard — decided on the actor where every
            // `saveGeneration` mutation happens — is what lets `saveImmediately()` / a newer write win.
            // Encoding the small layout tree on the main actor is acceptable; the (now-current) handle clear
            // happens in the same block.
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
    /// shared mux behind the connect-gate). `nil` in tests / headless ⇒ no gating.
    public var isAppConnected: (@MainActor () -> Bool)?

    /// The ⌘+ / ⌘- / ⌘0 font-zoom seam — wired by the app shell to the live ``PreferencesStore`` so a zoom
    /// mutates the SINGLE source of truth (`terminal.fontSize`), keeping the Settings "Size" stepper in
    /// sync. The store fires it ONLY for a terminal active pane (the no-op-off-terminal contract the
    /// FontScroll hooks already hold). `nil` in tests / headless ⇒ the zoom is a clean no-op.
    public var onFontSizeStep: ((FontSizeStep) -> Void)?

    /// The cwd-visit sink: fired with the pane's NEW working directory whenever ``setLastKnownCwd(_:for:)``
    /// records a CHANGED cwd (passes the dirty guard). The app wires this to ``FolderFrecencyStore/record(cwd:)``
    /// so the Open-Quickly **Folders** filter learns the directories you visit — but the store stays
    /// SwiftUI-/Folders-agnostic: a plain `(String) -> Void`, not a dependency on the Folders module. `nil` in
    /// tests / headless ⇒ no frecency side effect. Dirty-guarded, so a re-focus / unchanged refresh never
    /// records a phantom visit.
    public var onCwdVisited: ((String) -> Void)?

    /// Commits the app-global connection ``ConnectionTarget`` into the persisted ``Workspace/connection``
    /// (called by ``AppConnection/onTargetCommitted`` on a successful connect) so the connect-gate
    /// prefills the last-used host next launch. Debounced-saves like any other mutation.
    public func commitConnectionTarget(_ target: ConnectionTarget) {
        switch liveModel {
        case .canvas:
            guard workspace.connection != target else { return }
            workspace.connection = target
        case .tree:
            // Stamp the target onto the active session (the per-session host seam; MVP all sessions
            // share the one AppConnection, so this is the prefill source for the gate next launch).
            guard let sIdx = tree.activeSessionIndex, tree.sessions[sIdx].connection != target else { return }
            tree.sessions[sIdx].connection = target
        }
        scheduleSave()
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
        PaneChooserRegistry.option(for: kind).title
    }
}

// MARK: - Interactive layout drags (commit-on-release)

public extension WorkspaceStore {
    /// Swaps two leaves in the active tab — the commit for a drag-to-move: you grabbed `source`'s top handle
    /// and dropped it onto `target`. Both keep their `PaneID`, so reconcile is a registry no-op (no surface
    /// teardown) and only the solved geometry changes. ONE reconcile, fired from the gesture's `.onEnded`
    /// (the live drag is the view's overlay) so the keystroke / terminal-resize path stays quiet during the
    /// drag. No-op if the ids are equal or either is absent / they are in different tabs.
    func swapPanesTree(_ source: PaneID, _ target: PaneID) {
        guard source != target else { return }
        let next = WorkspaceTreeOps.swapPanes(source, target, in: tree)
        guard next != tree else { return }
        tree = next
        reconcileTree()
    }

    /// Relocates `source` to sit beside `target` along `axis`, on the BEFORE side when `before` (else after)
    /// — the commit for a drag-to-EDGE drop: you grabbed `source`'s top handle and dropped it on an edge of
    /// `target`, so it becomes a new row/column on that side (the directional re-split — this is also how a
    /// split is reoriented from side-by-side to stacked). `source` keeps its `PaneID`, so reconcile tears
    /// down nothing — only the solved geometry changes. ONE reconcile, fired from the gesture's `.onEnded`.
    /// No-op if the ids are equal / either is absent / they are in different tabs, or the relocation would
    /// not change the tree.
    func moveLeafTree(_ source: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) {
        guard source != target else { return }
        let next = WorkspaceTreeOps.moveLeaf(source, beside: target, axis: axis, before: before, in: tree)
        guard next != tree else { return }
        tree = next
        reconcileTree()
    }

    /// Docks `source` to the OUTERMOST `edge` of its tab — the commit for a drag-to-CONTAINER-edge drop: you
    /// dragged `source`'s handle into the container's outer gutter, so it becomes a full-span column
    /// (`.left`/`.right`) or row (`.top`/`.bottom`). `source` keeps its `PaneID`, so reconcile tears down
    /// nothing. ONE reconcile, fired from the gesture's `.onEnded`. No-op if `source` is absent, its tab has
    /// only one leaf, the dock would breach the depth ceiling, or it would not change the tree (already
    /// docked there).
    func moveLeafToRootEdgeTree(_ source: PaneID, edge: PaneDropEdge) {
        let next = WorkspaceTreeOps.moveLeafToRootEdge(source, edge: edge, in: tree)
        guard next != tree else { return }
        tree = next
        reconcileTree()
    }

    /// Relocates `source` beside `target` — ACROSS tabs of the same session when needed. The commit for a
    /// rail-drag MOVE of an already-streamed window dropped on a pane's edge band (docs/45): the window's
    /// existing pane leaves its tab (a sole-leaf tab closes) and lands beside the pane under the cursor,
    /// KEEPING its `PaneID` so reconcile tears down nothing — the live stream survives the move. ONE
    /// reconcile on release. Same-tab drops keep `moveLeafTree`'s no-op rules; cross-session moves are
    /// no-ops (the pane's spec cannot leave its session's side table).
    func moveLeafAcrossTabsTree(_ source: PaneID, beside target: PaneID, axis: SplitAxis, before: Bool) {
        guard source != target else { return }
        let next = WorkspaceTreeOps.moveLeafAcrossTabs(source, beside: target, axis: axis, before: before, in: tree)
        guard next != tree else { return }
        tree = next
        reconcileTree()
    }

    /// Docks `source` at the ACTIVE tab's outermost `edge` — across tabs of the same session when needed.
    /// The commit for a rail-drag MOVE of an already-streamed window dropped in the container gutter
    /// (docs/45). KEEPS `PaneID` (no surface teardown); ONE reconcile on release; no-op when nothing
    /// would change (already docked there / sole pane of the active tab).
    func moveLeafToActiveTabRootEdgeTree(_ source: PaneID, edge: PaneDropEdge) {
        let next = WorkspaceTreeOps.moveLeafToActiveTabRootEdge(source, edge: edge, in: tree)
        guard next != tree else { return }
        tree = next
        reconcileTree()
    }

    /// Brings pane `id` fully into view — the one-call "take me to this pane" the right rail's streamed
    /// rows and the rail-drag move commit share. A background-tab pane routes through ``selectTab(_:)``
    /// FIRST: `focusPaneTree` alone would also land on the right tab (`focusPane` repoints session + tab),
    /// but it skips `selectTab`'s badge auto-clear — and a tab the user was just taken to has been seen,
    /// the same rule a left-rail row click applies.
    func revealPaneTree(_ id: PaneID) {
        if let session = tree.activeSession,
           let index = session.tabIndex(containing: id),
           index != session.activeTabIndex
        {
            selectTab(index)
        }
        focusPaneTree(id)
    }

    /// Suspends/resumes host grid-resize delivery for EVERY live terminal pane — the shell raises this for
    /// the duration of a sidebar/inspector-divider drag. Dragging an AppKit `NSSplitView` divider
    /// live-resizes the content column every cell-step; for a remote terminal each forward is a host PTY
    /// reflow + a re-streamed redraw. Holding them and flushing the final grid ONCE on release keeps the
    /// content from re-rendering per drag step (the same commit-on-release rule as the pane divider). The
    /// non-terminal handles (`.remoteGUI`/`.systemDialog`) have no `terminalModel`, so they are skipped.
    func setTerminalResizeSuspended(_ suspended: Bool) {
        // The interactive-resize bracket for BOTH dividers (the SwiftUI pane divider's begin/end and the
        // AppKit sidebar divider's drag-active/settle). Drives the pane scrim's "drag in progress" hold so
        // a PAUSED drag keeps the overlay up (see ``isInteractiveResizeActive``).
        isInteractiveResizeActive = suspended
        for handle in allSessions {
            (handle as? LivePaneSession)?.terminalModel?.setResizeSuspended(suspended)
        }
    }

    /// LIVE pane-divider drag: set the leading child's ABSOLUTE flex weight (clamped) and re-solve the layout,
    /// WITHOUT reconciling the registry or persisting. A divider drag changes only weights, not the SET of
    /// panes, so each frame is a pure tree assign + SwiftUI re-layout (the panes resize live). The shell
    /// brackets the drag with ``setTerminalResizeSuspended(_:)`` — holding the host grid-resize send until
    /// release, the "update the layout live but defer the server event to drag-end" rule — and commits once on
    /// release via ``commitDividerResize()``.
    func setDividerWeightLive(splitID: SplitNodeID, leadingChildIndex: Int, leadingWeight: Double) {
        tree = WorkspaceTreeOps.setDividerWeight(
            splitID: splitID, leadingChildIndex: leadingChildIndex, leadingWeight: leadingWeight, in: tree,
        )
    }

    /// Commits a finished live divider drag: reconcile (housekeeping) + persist the settled ratio ONCE. The
    /// per-frame ``setDividerWeightLive(splitID:leadingChildIndex:leadingWeight:)`` skips this, so it runs a
    /// single time on release rather than every frame.
    func commitDividerResize() {
        reconcileTree()
    }

    /// Evens ONLY the double-clicked seam — the divider between children `leadingChildIndex` and
    /// `leadingChildIndex + 1` of split `splitID` resets to an equal pair share (sum-preserving), while
    /// every OTHER divider's dragged ratio survives. The `PaneDivider` double-click target; the whole-tab
    /// even reset stays on ``balanceActivePaneSplits()`` (the ⌃⌘= chord). The leaf set is unchanged, so
    /// reconcile is a registry no-op.
    func evenDividerTree(splitID: SplitNodeID, leadingChildIndex: Int) {
        tree = WorkspaceTreeOps.evenDivider(splitID: splitID, leadingChildIndex: leadingChildIndex, in: tree)
        reconcileTree()
    }

    /// The bounds the tree's geometric ops (directional focus / move-pane) solve the active tab into:
    /// the union of the frames the view last reported via ``updateSolvedLayout(_:)`` (the exact geometry
    /// the user sees), else the reported container bounds (``updateContainerBounds(_:)``), else a nominal
    /// desktop rect — a directional neighbour is scale-invariant on the tiled tree (cf.
    /// `WorkspaceTreeOps.neighbour(of:in:)`, which solves into a fixed unit square), so a chord fired
    /// before the first layout report still resolves correctly instead of dying.
    private var treeGeometryBounds: CGRect {
        if let solved = lastSolvedLayout, !solved.frames.isEmpty {
            var bounds = CGRect.null
            for rect in solved.frames.values { bounds = bounds.union(rect) }
            if !bounds.isNull, bounds.width > 0, bounds.height > 0 { return bounds }
        }
        if let reported = lastContainerBounds, reported.width > 0, reported.height > 0 {
            return reported
        }
        return CGRect(x: 0, y: 0, width: 1280, height: 800)
    }
}

// MARK: - Find-in-terminal + Global Search command entries

public extension WorkspaceStore {
    /// Advances the active pane's find bar to the NEXT match (the ⌘G keyboard / menu entry).
    /// Routes to the active terminal's ``TerminalViewModel/onRequestFindNext``; when that is unset (the bar
    /// has never been opened) it FALLS BACK to ``onRequestFind`` so ⌘G OPENS the find bar — faithful
    /// "find next opens find". A no-op for a non-terminal active pane / empty shell.
    func requestFindNextInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let model = (registry[active] as? LivePaneSession)?.terminalModel else { return }
        if let next = model.onRequestFindNext { next() } else { model.onRequestFind?() }
    }

    /// Steps the active pane's find bar to the PREVIOUS match (the ⇧⌘G entry). Same
    /// open-if-closed fallback as ``requestFindNextInActivePane()``.
    func requestFindPrevInActivePane() {
        guard let active = tree.activeSession?.activeTab?.activePane,
              let model = (registry[active] as? LivePaneSession)?.terminalModel else { return }
        if let prev = model.onRequestFindPrev { prev() } else { model.onRequestFind?() }
    }

    /// Runs `query` across EVERY live terminal pane's scrollback (session → tab → pane order),
    /// building the grouped results the ⇧⌘F surface renders. Snapshots each live terminal pane's
    /// ``TerminalViewModel/searchScrollbackLines()`` into a ``GlobalSearchSource`` (group title = the pane's
    /// spec title, falling back to its last-known shell title, else "Tab"), then delegates the match math to
    /// the PURE ``GlobalSearchController/run(sources:query:caseSensitive:isRegex:)`` — the SAME engine the
    /// in-pane find bar uses, never a second matcher. Non-terminal (video) and never-connected panes
    /// contribute no lines and so are simply absent.
    func runGlobalSearch(query: String, caseSensitive: Bool, isRegex: Bool) {
        globalSearchQuery = query
        globalSearchCaseSensitive = caseSensitive
        globalSearchRegex = isRegex
        // Re-run only the IN-MEMORY match pass over the per-overlay scrollback snapshot (gathered ONCE on
        // open by ``beginGlobalSearchSession()``), so a keystroke does not re-mirror every pane's scrollback
        // across the libghostty seam. Fall back to a fresh snapshot when no overlay session is active
        // (defensive — e.g. a direct call from a test or the seed path before begin); the results are
        // identical either way.
        let sources = globalSearchSourceCache ?? collectGlobalSearchSources()
        globalSearch = GlobalSearchController.run(
            sources: sources, query: query, caseSensitive: caseSensitive, isRegex: isRegex,
        )
    }

    /// Snapshot every live terminal pane's scrollback into searchable sources ONCE and cache them for
    /// the open ⇧⌘F overlay. Called on overlay-OPEN (a re-open re-snapshots fresh scrollback); keystrokes then
    /// re-run only the in-memory match pass over this cache via ``runGlobalSearch(query:caseSensitive:isRegex:)``.
    func beginGlobalSearchSession() {
        globalSearchSourceCache = collectGlobalSearchSources()
    }

    /// Drop the cached scrollback sources when the overlay CLOSES so the next open re-snapshots fresh
    /// scrollback (and the mirrored buffers don't outlive the overlay).
    func endGlobalSearchSession() {
        globalSearchSourceCache = nil
    }

    /// Crosses the libghostty seam to mirror EVERY live terminal pane's scrollback (session → tab → pane order)
    /// into a ``GlobalSearchSource`` (group title = the pane's spec title, else its last-known shell title, else
    /// "Tab"). The ONLY cross-seam step in Global Search; ``runGlobalSearch`` caches its result per overlay-open
    /// so keystrokes don't repeat it. Non-terminal (video) and never-connected panes contribute no lines and so
    /// are simply absent. Resolves the model through the ``TerminalModelProviding`` seam
    /// (not an `as? LivePaneSession` cast) so it stays headlessly testable with a recording double.
    private func collectGlobalSearchSources() -> [GlobalSearchSource] {
        var sources: [GlobalSearchSource] = []
        for session in tree.sessions {
            for tab in session.tabs {
                for paneID in tab.allPaneIDs() {
                    guard let spec = session.spec(for: paneID), spec.kind == .terminal,
                          let model = (registry[paneID] as? TerminalModelProviding)?.terminalModel else { continue }
                    let title = spec.title.isEmpty ? (spec.lastKnownTitle ?? "Tab") : spec.title
                    sources.append(GlobalSearchSource(
                        paneID: paneID,
                        sessionID: session.id,
                        tabID: tab.id,
                        groupTitle: title,
                        lines: model.searchScrollbackLines(),
                    ))
                }
            }
        }
        return sources
    }

    /// Jumps to a Global Search hit — selects its session, its tab, and focuses its pane
    /// (``focusPaneTree(_:)`` resolves session+tab+pane together), then RE-ARMS the pane's in-surface
    /// libghostty search near the hit so the amber highlight + scroll-to-match land on the result.
    /// A no-op if the pane is gone.
    func jumpToGlobalSearchResult(_ hit: GlobalSearchHit) {
        guard tree.contains(hit.paneID) else { return }
        jumpToPaneTree(hit.paneID) // selects hit.sessionID + hit.tabID + focuses hit.paneID (+ breadcrumb)
        guard let model = (registry[hit.paneID] as? TerminalModelProviding)?.terminalModel else { return }
        // Click-to-line: ALWAYS scroll straight to the clicked hit's mirror row so the landing is
        // correct in every mode and independent of the current viewport. The literal `search:` matcher is armed
        // for the amber highlight ONLY in literal + case-INSENSITIVE mode (the one mode it matches faithfully);
        // case-sensitive literal and regex modes clear any stale highlight and just scroll — matching the find
        // bar's literal-highlight ceiling. Pass the tracked case-sensitivity AND regex flags so the controller
        // branches correctly. The pure controller computes the ordered actions; an empty query yields none.
        let actions = GlobalSearchController.navigationActions(
            for: hit,
            query: globalSearchQuery,
            caseSensitive: globalSearchCaseSensitive,
            isRegex: globalSearchRegex,
            // Map the logical (unwrapped) hit line to the physical grid row `scroll_to_row` addresses — the
            // mirror collapses soft-wrapped rows, so a heavily-wrapped pane would otherwise land rows too high.
            lines: model.searchScrollbackLines(),
            columns: model.searchGridColumns(),
        )
        for action in actions {
            model.performSearchSurfaceAction(action)
        }
    }

    /// Closes the active pane through the busy-shell guard: an idle pane closes immediately,
    /// a pane mid-command parks behind the `pendingClose` confirmation. No-op without an active pane.
    func requestCloseActivePaneTree() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        if closeConfirmationNeeded(scope: .pane, pane: active) {
            parkPaneClose(active)
        } else {
            closePaneTree(active)
        }
    }

    /// Breaks the active pane out into a new tab (the "break pane to tab" command entry).
    /// No-op without an active pane.
    func breakActivePaneToTab() {
        guard let active = tree.activeSession?.activeTab?.activePane else { return }
        breakPaneToTab(active)
    }

    /// Toggles render-only zoom on the active pane (the "zoom/maximize" command entry).
    func toggleZoomActivePane() { toggleZoomTree() }
}

// MARK: - Production session factory

public extension WorkspaceStore {
    /// The production `makeSession` factory: wires ``LivePaneSession`` with a mux-backed client
    /// factory and an inspector builder. The app passes `WorkspaceStore.liveMakeSession(...)` as
    /// `makeSession` so tests can substitute `{ FakePaneSession($0) }` instead (docs/22 §0).
    ///
    /// - Parameters:
    ///   - makeInspector: builds the read-only `InspectorClient` for a terminal endpoint (subscribed
    ///     dynamically once a `claude` is detected), or `nil` when no second channel is available.
    ///     Defaults to ``liveMakeInspector(_:)`` — a lazily-connecting NWConnection #2 client (see
    ///     that function for the unproven-host guardrail).
    ///   - muxRegistry: the per-host shared-connection pool. Every `SlopDeskClient` is backed by a
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

    /// Builds a `@Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient` whose clients route over the
    /// shared mux connection pooled by `registry`. Each `SlopDeskClient` is constructed with an
    /// injected `makeTransport` that vends a fresh `MuxClientTransport` bound to the registry's
    /// acquire/release — so the channel is opened on the shared connection at `connect()` and released
    /// (refcount--) at `close()`, with the shared transport torn down only when the LAST pane's channel
    /// goes. The registry is `@MainActor`; the transport's acquire/release closures hop onto the main
    /// actor to call it.
    ///
    /// The `resumeSeed` parameter is passed straight through to `SlopDeskClient.init(resumeSeed:)`, which
    /// sets `sessionID` / `highestContiguousSeq` / `highestSeqFed` synchronously as part of construction
    /// (`docs/DECISIONS.md`). Seeding a restored pane's identity AFTER this factory returns the client —
    /// a fire-and-forget `Task { await c.seedResumeIdentity(...) }` — races the separately-scheduled
    /// `connect()` Task on the actor's mailbox, so the seed MUST ride `init`. `nil` = a fresh /
    /// never-restored pane (no seed, no race).
    private static func muxBackedClientFactory(
        registry: ConnectionRegistry,
    ) -> @Sendable (SlopDeskClient.ResumeSeed?) -> SlopDeskClient {
        { @Sendable resumeSeed in
            SlopDeskClient(
                makeTransport: {
                    MuxClientTransport(
                        acquire: { host, port, sessionID, lastReceivedSeq, initialCwd in
                            try await registry.acquire(
                                host: host,
                                port: port,
                                sessionID: sessionID,
                                lastReceivedSeq: lastReceivedSeq,
                                initialCwd: initialCwd,
                            )
                        },
                        release: { host, port, channelID in
                            await registry.release(host: host, port: port, channelID: channelID)
                        },
                    )
                },
                resumeSeed: resumeSeed,
            )
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
    /// dynamically once a `claude` is detected in it).
    ///
    /// ### Guardrail (docs/22 §7): the LIVE network inspector path is NOT runtime-proven
    /// PATH 1 (the terminal byte-pipeline) is proven; the inspector second channel (NWConnection #2) is wired
    /// cleanly but **no host-side inspector serving / port exists yet** (no `slopdesk-hostd` inspector daemon
    /// to invent). So this returns a *ready, lazily-connecting* client rather than eagerly dialing: it stands
    /// up an ``NWByteChannel`` over a fresh `NWConnection` to `host:inspectorPort` (the ``inspectorPort(for:)``
    /// convention) but does NOT `start()` it — the channel connects on the first `send`/`subscribe`, driven by
    /// ``LivePaneSession/subscribeInspector()`` (the leaf's `.task` on appear). Against a host that
    /// doesn't serve the port the connection never completes its handshake and the fold yields no cards — the
    /// terminal is unaffected. The FOLD logic is fully unit-testable in-process via `LoopbackByteChannel.pair()`
    /// + ``InspectorClient/init(channel:)`` (docs/22 §8), independent of this builder. Real-network inspector
    /// serving is a hardware followup.
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
        // it here so a plain terminal (no claude detected) opens no inspector socket.
        let channel = NWByteChannel(connection: connection)
        return InspectorClient(channel: channel)
    }
}

// MARK: - Command application

/// Dispatches a pure ``WorkspaceCommand`` to the matching store mutation (docs/22 §5). The keyboard layer
/// (macOS `Commands`, iPad `UIKeyCommand`) and the compact on-screen affordances all funnel intent through
/// this one free function, keeping the chord → command → mutation chain in one place.
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
    // entry (only the explicit .newPane(kind) items), so recording it verbatim would silently drop it from
    // the recents block AND waste a ring slot. Record the RESOLVED kind instead — it resolves in the
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

// MARK: - New-pane gesture (direct terminal mint)

/// Factored into a same-file extension (like `splitFromContextMenu`) so the new-pane entry point stays
/// OUT of the `WorkspaceStore` primary body's `type_body_length` budget.
public extension WorkspaceStore {
    /// Create a new TERMINAL pane placed by `context` and FOCUSED. Every new-pane gesture (⌘T / ⌘D /
    /// the `+` button / the context-menu splits) mints a terminal DIRECTLY — the in-pane kind chooser
    /// is retired: the default kind gets the hot path, and every non-terminal kind has its own
    /// explicit shortcut (⌥⌘N desktop; Open Quickly / the picker for windows), so a kind question on
    /// the hot path has no second answer left. cwd inheritance is the `newTab` / `splitActivePane`
    /// placement + inherit path, unchanged.
    func newTerminalPane(_ context: NewPanePlacement) {
        switch context {
        case let .split(axis, leading): splitActivePane(axis: axis, kind: .terminal, leading: leading)
        case .newTab: newTab(kind: .terminal)
        }
    }

    /// Model-agnostic read of pane `id`'s persisted ``PaneSpec/lastKnownCwd`` (from the tree or canvas
    /// spec, whichever backs ``liveModel``). Shared by ``setLastKnownCwd(_:for:)``'s dirty guard and the
    /// attach-edge cwd-pull gate ``shouldRefreshCwdOnAttach(_:)``.
    func lastKnownCwd(for paneID: PaneID) -> String? {
        switch liveModel {
        case .tree: tree.spec(for: paneID)?.lastKnownCwd
        case .canvas: workspace.canvas.spec(for: paneID)?.lastKnownCwd
        }
    }

    /// Whether the connect/reconnect snapshot edge should pull pane `id`'s cwd from the host. TRUE
    /// only while ``PaneSpec/lastKnownCwd`` is still empty — a POPULATE-ONCE gate so the ~3 s RTT-snapshot
    /// cadence never becomes a cwd poll. A shell that emits no OSC-7 (Starship / hookless) would otherwise
    /// sit at the "Terminal" fallback until its first command completes; one host `proc_pidinfo` pull on
    /// attach lands the folder-name title. Once any source populates the cwd this returns false and stops.
    func shouldRefreshCwdOnAttach(_ id: PaneID) -> Bool {
        lastKnownCwd(for: id) == nil
    }

    /// Persists the host-resolved working directory of pane `paneID` into ``PaneSpec/lastKnownCwd`` — the
    /// single sink every cwd source (OSC 7, the `cwd` RPC, the palette resolver) funnels through, so the
    /// titlebar / rail / palette all mirror the same value. Live-model-aware (routes through the same
    /// `updateSpecLive` wire as `lastKnownTitle`); guarded against an unchanged value so a re-focus does NOT
    /// spend a reconcile.
    func setLastKnownCwd(_ cwd: String, for paneID: PaneID) {
        // Drop a TRANSIENT plugin-cache-dir reading before it can poison the inherit source (see
        // ``PaneSpec/looksLikeTransientPluginCwd(_:)``). The live-cwd sources are `proc_pidinfo`-based
        // (`refreshCwd` on command completion, the palette's `cwd()` resolver), which race a plugin
        // manager's turbo `builtin cd`; without this a later new-tab / split / relaunch spawns its PTY in
        // e.g. `…/zsh-users---zsh-autosuggestions` instead of the real project cwd.
        guard !PaneSpec.looksLikeTransientPluginCwd(cwd) else { return }
        let current = lastKnownCwd(for: paneID)
        guard current != cwd else { return }
        updateSpecLive(paneID) { $0.lastKnownCwd = cwd }
        // The cwd just CHANGED (the guard above proves it differs from the stored value), so this is a
        // genuine visit — notify the frecency sink. Kept after the dirty guard so an unchanged re-focus is silent.
        onCwdVisited?(cwd)
        // The sidebar git line follows the cwd: a `cd` can enter/leave/switch repos, so refetch this
        // pane's summary. The stale line stays visible until the fresh reply lands (no flicker on a
        // same-repo `cd`); the post-completion `refreshCwd` funnels through here ONLY when the cwd
        // actually changed (the dirty guard above), so this never double-fetches a quiet completion.
        refreshGitSummary(for: paneID, from: (handle(for: paneID) as? LivePaneSession)?.connection)
    }

    /// Model-agnostic read of pane `id`'s persisted ``PaneSpec/projectKey`` (tree or canvas spec, whichever
    /// backs ``liveModel``) — the ``setProjectKey(_:for:)`` dirty guard's mirror of ``lastKnownCwd(for:)``.
    func projectKey(for paneID: PaneID) -> String? {
        switch liveModel {
        case .tree: tree.spec(for: paneID)?.projectKey
        case .canvas: workspace.canvas.spec(for: paneID)?.projectKey
        }
    }

    /// Persists the HOST-computed By-Project key (wire type 34) into ``PaneSpec/projectKey`` — the write
    /// sink ``ConnectionViewModel/onProjectKeyChanged`` funnels into, mirroring ``setLastKnownCwd(_:for:)``:
    /// a transient plugin-cache reading (``PaneSpec/looksLikeTransientPluginCwd(_:)`` — the host's resolver
    /// can race a zinit turbo `builtin cd` just as a client-side `gitStatus` sweep can) is DROPPED, and an
    /// unchanged value short-circuits before `updateSpecLive` so a reattach re-assert never spends a
    /// reconcile + save. ``paneProjectKey(_:)`` reads it back for the sidebar sectioning.
    func setProjectKey(_ key: String, for paneID: PaneID) {
        guard !key.isEmpty, !PaneSpec.looksLikeTransientPluginCwd(key) else { return }
        guard projectKey(for: paneID) != key else { return }
        updateSpecLive(paneID) { $0.projectKey = key }
    }

    /// cwd-freshness fallback: pull pane `id`'s current working directory from the host `cwd` RPC
    /// (`proc_pidinfo` — shell-agnostic, needs no OSC-7) and persist it via the dirty-guarded
    /// ``setLastKnownCwd(_:for:)``, so a `cd` in this pane becomes the inherit source for the NEXT new tab /
    /// split AND the folder-name title lands without waiting for the shell to emit anything. A `nil`
    /// connection / failed RPC is a silent no-op (validate-then-drop); the metadata client's 5 s timeout
    /// bounds the await.
    ///
    /// **Attach-edge retry.** On a fresh (re)connect the pane's `activeMetadataClient` can
    /// briefly be `nil` — the control plane is still being (re)established — so a single-shot pull can MISS
    /// and leave the title at "Terminal" until the next ~3 s RTT-snapshot retry (and the RECONNECT caller,
    /// whose `lastKnownCwd` is already non-nil, has NO populate-once retry at all). `retries > 0` re-arms a
    /// short-delayed retry up to `retries` times, stopping the instant the RPC answers — so the cwd lands in
    /// ~1 RTT on connect and a reconnect that respawned a fresh shell reliably re-reads the host cwd.
    /// `retries == 0` (the command-completion caller, where the client is long-since live) keeps the
    /// original single-shot behaviour. The bounded retry holds `connection` strongly only for its ~1 s
    /// window; a torn-down connection just answers `nil` and exhausts the budget.
    private func refreshCwd(for id: PaneID, from connection: ConnectionViewModel?, retries: Int = 0) {
        guard let connection else { return }
        Task { @MainActor [weak self] in
            if let cwd = await connection.activeMetadataClient?.cwd() {
                self?.setLastKnownCwd(cwd, for: id)
                return
            }
            // Metadata client not ready yet (or the RPC failed): re-arm a bounded, short-delayed retry so
            // the attach-edge pull is not a one-shot. Stops as soon as `self`/the budget is gone.
            guard let self, retries > 0 else { return }
            try? await Task.sleep(for: .milliseconds(300))
            refreshCwd(for: id, from: connection, retries: retries - 1)
        }
    }

    // MARK: - Sidebar git line (the per-pane compact summary)

    /// Refreshes pane `id`'s compact git summary (``paneGitSummary`` → the sidebar row's second line)
    /// from the host `gitStatus` RPC on the pane's OWN metadata channel. Fired on command completion
    /// (OSC 133;D, beside ``refreshCwd(for:from:)``), on a cwd CHANGE (``setLastKnownCwd(_:for:)`` — a
    /// `cd` can enter/leave/switch repos), and once on connect (the resume-identity edge). The stale
    /// value stays visible until the fresh reply lands (no flicker on a same-repo `cd`); a `nil`
    /// connection / failed RPC is a silent no-op (validate-then-drop), and the in-flight set de-dupes a
    /// completion burst. (The By-Project key itself is HOST-pushed — wire type 34 → ``setProjectKey(_:for:)``
    /// — so the reply's `repoRoot` only scopes the same-repo fan-out below, never the sectioning.)
    func refreshGitSummary(for id: PaneID, from connection: ConnectionViewModel?) {
        guard let connection, !paneGitSummaryInFlight.contains(id) else { return }
        paneGitSummaryInFlight.insert(id)
        Task { @MainActor [weak self] in
            let payload = await connection.activeMetadataClient?.gitStatus()
            guard let self else { return }
            paneGitSummaryInFlight.remove(id)
            guard let payload else { return }
            applyGitSummary(PaneGitSummary(payload: payload), toplevel: payload.repoRoot, for: id)
        }
    }

    /// The context-menu "Refresh Git Status" entry: re-probe pane `id`'s git line on demand
    /// through its OWN live connection. A `.remoteGUI` / faked pane (no ``LivePaneSession``) is a silent
    /// no-op via ``refreshGitSummary(for:from:)``'s `nil`-connection guard.
    func refreshGitSummary(for id: PaneID) {
        refreshGitSummary(for: id, from: (handle(for: id) as? LivePaneSession)?.connection)
    }

    /// Applies a freshly-fetched git `summary` for pane `id`: a dirty-guarded write to
    /// ``paneGitSummary`` and a ``paneGitFetchedAt`` freshness stamp — then FANS the same summary out to
    /// every OTHER live pane whose By-Project key (``paneProjectKey(_:)`` — the host-pushed spec key, else
    /// the cwd fallback) matches the reply's `toplevel` (a sibling in the SAME repo now knows a sibling-pane
    /// commit landed without waiting for its own command edge), each with its own dirty guard so a quiet
    /// sibling never churns the `@Observable` rail. An EMPTY toplevel is "no repo", not a shared key, so it
    /// never fans out. `now` is injectable for a deterministic staleness test.
    func applyGitSummary(_ summary: PaneGitSummary, toplevel: String, for id: PaneID, at now: Date = Date()) {
        // Validate-then-drop a reading taken while the shell was transiently inside a plugin-cache dir (a
        // zinit turbo `builtin cd` the `gitStatus` RPC raced): its `toplevel` is the PLUGIN's repo and its
        // branch/changed counts are that plugin's, not the user's project. Discard the WHOLE reading (no
        // summary write, no sibling fan-out) so the git line is never poisoned; the next completion edge
        // re-probes at the settled cwd.
        guard !PaneSpec.looksLikeTransientPluginCwd(toplevel) else { return }
        if paneGitSummary[id] != summary { paneGitSummary[id] = summary }
        paneGitFetchedAt[id] = now
        guard !toplevel.isEmpty else { return }
        for pane in tree.allPaneIDs() where pane != id && paneProjectKey(pane) == toplevel {
            if paneGitSummary[pane] != summary { paneGitSummary[pane] = summary }
            paneGitFetchedAt[pane] = now
        }
    }

    /// How long a git line stays "fresh" on the ~3 s RTT-snapshot edge before a re-fetch is
    /// allowed — long enough that the snapshot cadence is never a git-status poll, short enough that a quiet
    /// pane's stale line self-heals within a minute.
    static let gitSummaryStaleWindow: TimeInterval = 60

    /// Whether the ~3 s RTT-snapshot edge should re-fetch pane `id`'s git line: ALWAYS when there
    /// is no entry yet (initial populate), else ONLY when it is the ACTIVE pane AND its cached line is older
    /// than ``gitSummaryStaleWindow``. A background pane is never re-fetched on this edge (a genuine reconnect
    /// refreshes it via ``ConnectionViewModel/onReconnected``), so the snapshot cadence stays cheap + bounded.
    func shouldRefreshGitOnSnapshot(_ id: PaneID, now: Date = Date()) -> Bool {
        if paneGitSummary[id] == nil { return true }
        guard isActivePane(id) else { return false }
        guard let fetchedAt = paneGitFetchedAt[id] else { return true }
        return now.timeIntervalSince(fetchedAt) > Self.gitSummaryStaleWindow
    }

    /// Whether pane `id` is the currently-focused pane in the live model — the tree's active tab's
    /// active pane, or the canvas focus. Used to bound the snapshot-edge git re-fetch to the pane the user is
    /// actually looking at.
    func isActivePane(_ id: PaneID) -> Bool {
        switch liveModel {
        case .tree: tree.activeSession?.activeTab?.activePane == id
        case .canvas: workspace.focusedPane == id
        }
    }
}
