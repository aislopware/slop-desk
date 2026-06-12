import Foundation
import CoreGraphics
import Network
import AislopdeskClient
import AislopdeskInspector
import AislopdeskTransport

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

    /// The sidebar consumed the rename request (its inline field is open) — or the request became
    /// moot (pane gone).
    public func clearRenameRequest() {
        pendingRename = nil
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

    /// The last viewport size the canvas view reported (docs/30 §5.3). Used by new-pane placement, the
    /// in-view guarantee, and the centre/tidy camera ops so the store can position panes without the
    /// view passing a size into every mutation. A nominal desktop default until the view reports one.
    private var lastViewport: CGSize = CGSize(width: 1280, height: 800)

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
        saveDebounce: Duration = .milliseconds(600),
        videoTeardownSettle: Duration = .zero
    ) {
        self.workspace = restoring ?? .defaultWorkspace()
        self.makeSession = makeSession
        self.liveVideoCap = liveVideoCap
        self.persistence = persistence
        self.saveDebounce = saveDebounce
        self.videoTeardownSettle = videoTeardownSettle
        reconcile()   // materialize idle sessions for the restored/default leaves
        savingEnabled = true   // arm debounced saves only AFTER the restore reconcile
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
        workspace.focusedPane = id
        // A new pane exits any maximize (the canvas layout changed).
        if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
        if let group { workspace.canvas = workspace.canvas.assigning(id, toGroup: group) }
        // In-view guarantee: a new pane that lands off (or barely clipping) the current viewport would be
        // invisible — pan the camera to centre it unless its CENTRE is already inside the viewport.
        let visible = CGRect(origin: workspace.canvas.camera.origin, size: viewport)
        if let f = workspace.canvas.frame(of: id), !visible.contains(CGPoint(x: f.midX, y: f.midY)) {
            workspace.canvas = workspace.canvas.centered(on: id, viewport: viewport)
        }
        reconcile()
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
            item.spec, near: id, viewport: lastViewport, size: item.frame.size
        )
        workspace.canvas = canvas
        workspace.focusedPane = newID
        if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
        if let group = item.groupID {
            workspace.canvas = workspace.canvas.assigning(newID, toGroup: group)
        }
        // In-view guarantee, mirroring addPane.
        let visible = CGRect(origin: workspace.canvas.camera.origin, size: lastViewport)
        if let f = workspace.canvas.frame(of: newID), !visible.contains(CGPoint(x: f.midX, y: f.midY)) {
            workspace.canvas = workspace.canvas.centered(on: newID, viewport: lastViewport)
        }
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

    /// Confirms the parked busy-shell close. No-op when nothing is pending (e.g. the pane was
    /// already closed by another path — `closePane` clears a matching `pendingClose`).
    public func confirmPendingClose() {
        guard let id = pendingClose else { return }
        pendingClose = nil
        closePane(id)
    }

    /// Dismisses the busy-shell close confirmation without closing.
    public func cancelPendingClose() {
        pendingClose = nil
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
        workspace.focusedPane = id
        if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
        // In-view guarantee, mirroring addPane: the pane may have been closed far off-viewport.
        let visible = CGRect(origin: workspace.canvas.camera.origin, size: lastViewport)
        if let f = workspace.canvas.frame(of: id), !visible.contains(CGPoint(x: f.midX, y: f.midY)) {
            workspace.canvas = workspace.canvas.centered(on: id, viewport: lastViewport)
        }
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
        let spec = PaneSpec(kind: .systemDialog, title: label,
                            video: VideoEndpoint(windowID: windowID, title: label, appName: owner))
        let viewport = lastViewport
        let (canvas, id) = workspace.canvas.adding(spec, near: workspace.focusedPane, viewport: viewport)
        workspace.canvas = canvas
        workspace.focusedPane = id
        // A surfacing prompt exits maximize and is panned into view (it demands attention).
        if workspace.maximizedPane != nil { workspace.maximizedPane = nil }
        let visible = CGRect(origin: workspace.canvas.camera.origin, size: viewport)
        if let f = workspace.canvas.frame(of: id), !visible.contains(CGPoint(x: f.midX, y: f.midY)) {
            workspace.canvas = workspace.canvas.centered(on: id, viewport: viewport)
        }
        reconcile()
        // isSecure is a pure-live property (never persisted), so set it on the just-materialized session
        // directly rather than threading it through the Codable spec.
        (registry[id] as? LivePaneSession)?.markSystemDialog(isSecure: isSecure)
        return id
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
        guard workspace.focusedPane != id else { return }
        workspace = workspace.focusing(id)
        reconcile()
    }

    /// Moves focus in `dir`, resolved geometrically against the last solved layout (docs/22 §2.1).
    /// `.next`/`.previous` fall back to the canonical ``Canvas/allIDs()`` cycle when no layout has been
    /// reported yet (e.g. compact mode), so cycling always works.
    public func move(_ dir: FocusDirection) {
        guard let focused = workspace.focusedPane else { return }
        let target: PaneID?
        switch dir {
        case .next, .previous:
            if let solved = lastSolvedLayout, solved.frames[focused] != nil {
                target = FocusResolver.neighbor(of: focused, dir, in: solved)
            } else {
                target = FocusResolver.cycle(workspace.canvas.allIDs(), from: focused, forward: dir == .next)
            }
        case .left, .right, .up, .down:
            guard let solved = lastSolvedLayout else { return }
            target = FocusResolver.neighbor(of: focused, dir, in: solved)
        }
        guard let target, target != focused else { return }
        focus(target)
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
        workspace.focusedPane = id
        reconcile()
    }

    /// Sets pane `id`'s frame (the corner/edge resize commit). The VIEW frame change drives the
    /// terminal host's `layout()` → reflow (the existing path; no new resize API). Item set unchanged.
    public func resizePane(_ id: PaneID, to frame: CGRect) {
        guard workspace.canvas.contains(id) else { return }
        workspace.canvas = workspace.canvas.resizing(id, to: frame)
        reconcile()
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
        guard abs(dw) >= 0.5 || abs(dh) >= 0.5 else { return }
        let snapped = CGRect(origin: frame.origin,
                             size: CGSize(width: frame.width + dw, height: frame.height + dh))
        workspace.canvas = workspace.canvas.resizing(id, to: snapped)
        reconcile()
    }

    /// Brings pane `id` to the front and focuses it (on focus / drag-start). Item set unchanged.
    public func raisePane(_ id: PaneID) {
        guard workspace.canvas.contains(id) else { return }
        workspace.canvas = workspace.canvas.raising(id)
        workspace.focusedPane = id
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
            FileHandle.standardError.write(Data("Aislopdesk[workspace]: scrollPan d=(\(Int(delta.width)),\(Int(delta.height))) liveOff=(\(Int(liveCameraOffset.width)),\(Int(liveCameraOffset.height))) camOrigin=(\(Int(workspace.canvas.camera.origin.x)),\(Int(workspace.canvas.camera.origin.y)))\n".utf8))
        }
        scrollCommitTask?.cancel()
        scrollCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard let self, !Task.isCancelled else { return }
            self.commitScrollPan()
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
            FileHandle.standardError.write(Data("Aislopdesk[workspace]: commitScrollPan camOrigin (\(Int(before.x)),\(Int(before.y)))→(\(Int(after.x)),\(Int(after.y))) foldedOff=(\(Int(off.width)),\(Int(off.height)))\n".utf8))
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
            y: box.midY - lastViewport.height / 2
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

    // MARK: - Viewport bookmarks (⇧⌘1–9 save, ⌘1–9 recall)

    /// Saves the current viewport into bookmark `slot` (1–9), named after the focused pane. The
    /// in-flight scroll pan is committed FIRST so the saved camera is what the user actually sees,
    /// not the last committed position. Records the focused pane as the recall anchor (see
    /// ``CanvasBookmark``).
    public func saveBookmark(_ slot: Int) {
        guard (1...9).contains(slot) else { return }
        commitScrollPan()
        let name = workspace.focusedPane
            .flatMap { workspace.canvas.spec(for: $0)?.title }
            ?? "Bookmark \(slot)"
        workspace.bookmarks[slot] = CanvasBookmark(
            pane: workspace.focusedPane,
            cameraOrigin: workspace.canvas.camera.origin,
            name: name
        )
        reconcile()   // metadata-only (leaf set unchanged) — reconcile just persists
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
            guard let self, self.paneStillRegistered(id, as: handle) else { return }
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
        let activeOthers = registry.values.filter { $0.kind.isVideo && $0.isVideoActive && $0.id != id }.count
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
    public func bootstrapFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) {
        if let (target, video) = Self.videoTarget(from: env) {
            let spec = PaneSpec(kind: .remoteGUI, title: video.title, video: video)
            workspace = Self.singleLeafWorkspace(spec: spec, connection: target)
        } else if let target = Self.terminalTarget(from: env) {
            let spec = PaneSpec(kind: .terminal, title: "Terminal")
            workspace = Self.singleLeafWorkspace(spec: spec, connection: target)
        } else {
            workspace = .defaultWorkspace()
        }
        reconcile()
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
        let port = (env["AISLOPDESK_AUTOCONNECT_PORT"]).flatMap { UInt16($0) } ?? 7420
        let target = ConnectionTarget(host: host, port: port, mediaPort: media, cursorPort: cursor)
        return (target, VideoEndpoint(windowID: wid, title: title))
    }

    /// A one-pane workspace from `spec` (the bootstrap shape) with the app `connection` target. The pane
    /// id is minted fresh; the item sits at the canvas origin at the default size, focused, ungrouped.
    private static func singleLeafWorkspace(spec: PaneSpec, connection: ConnectionTarget? = nil) -> Workspace {
        let paneID = PaneID()
        let item = CanvasItem(id: paneID, spec: spec,
                              frame: CGRect(origin: .zero, size: Canvas.defaultItemSize), z: 0)
        return Workspace(canvas: Canvas(items: [item]), focusedPane: paneID, connection: connection)
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
            if orphan.kind.isVideo && orphan.isVideoActive {
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
                        // COMPLETION-SITE nudge (VIDEO-UI-1): the close-time bump (`reconcile`, above)
                        // fired while this slot was STILL counted against the cap, so a same-tick gated
                        // reopen was refused and is now parked on the "Video paused" placeholder.
                        // Removing the id here is the instant the slot ACTUALLY frees — nudge again so
                        // that gated on-screen pane re-attempts admission now, instead of waiting for an
                        // unrelated event (another deactivate / re-appear) to happen to nudge it.
                        self.videoPromotionGeneration &+= 1
                    }
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
        }

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

    private func scheduleSave() {
        guard savingEnabled, let persistence else { return }
        saveTask?.cancel()
        // Snapshot the (Sendable, value-typed) PERSISTABLE workspace now (ephemeral dialog panes stripped)
        // so the write reflects this mutation.
        let snapshot = persistableWorkspace()
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
        try? persistence.save(persistableWorkspace())
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
        guard workspace.connection != target else { return }
        workspace.connection = target
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
        case .terminal:     return "Terminal"
        case .claudeCode:   return "Claude Code"
        case .remoteGUI:    return "Remote window"
        case .systemDialog: return "System dialog"
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
    ///   - makeInspector: builds the read-only `InspectorClient` for a `.claudeCode` endpoint, or
    ///     `nil` when no second channel is available (e.g. the descriptor cannot be built headless).
    ///     Defaults to ``liveMakeInspector(_:)`` — a lazily-connecting NWConnection #2 client (see
    ///     that function for the unproven-host guardrail).
    ///   - muxRegistry: the per-host shared-connection pool. Every `AislopdeskClient` is backed by a
    ///     logical channel over the per-host shared `MuxNWConnection` (refcounted by the registry).
    static func liveMakeSession(
        makeInspector: @escaping @MainActor (ConnectionTarget) -> InspectorClient? = liveMakeInspector,
        muxRegistry: ConnectionRegistry,
        target: @escaping @MainActor () -> ConnectionTarget = { .default }
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
        registry: ConnectionRegistry
    ) -> @Sendable () -> AislopdeskClient {
        { @Sendable in
            AislopdeskClient(makeTransport: {
                MuxClientTransport(
                    acquire: { host, port, sessionID, lastReceivedSeq in
                        try await registry.acquire(
                            host: host, port: port, sessionID: sessionID, lastReceivedSeq: lastReceivedSeq
                        )
                    },
                    release: { host, port, channelID in
                        await registry.release(host: host, port: port, channelID: channelID)
                    }
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

    /// Builds the production read-only ``InspectorClient`` for a `.claudeCode` pane's `endpoint`.
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
/// Commands that act on "the focused pane" read it from the store's current `workspace.focusedPane`;
/// a command with no valid target (no focused pane) is a graceful no-op.
@MainActor
public func apply(_ command: WorkspaceCommand, to store: WorkspaceStore) {
    switch command {
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
        // Create an empty group; the user assigns panes via the sidebar context menu / drag.
        store.addGroup(name: "Group")
    case let .focus(direction):
        store.move(direction)
    case let .cycleFocus(forward):
        store.move(forward ? .next : .previous)
    case .toggleZoom:
        store.toggleZoom()
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
    }
}
