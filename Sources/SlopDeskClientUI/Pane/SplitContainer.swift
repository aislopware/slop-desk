// SplitContainer — renders EVERY tab's pane tree, revealing only the active one. The
// IDENTITY-PRESERVING compositor. Keeping all tabs mounted at opacity(0) (never unmounting an inactive tab's
// subtree) is the documented invariant that keeps a libghostty surface ALIVE across a tab switch — so
// switching tabs shows each pane's CURRENT screen with no teardown / soft-reset / lossy ring-replay.
//
// It reads the PURE render model `SplitTreeRenderModel.layout(for: tab, in: bounds)` (the same solver the
// FocusResolver uses) which turns the tab's `SplitNode` tree into placed leaf rects + divider handle rects.
// Branch nodes are NOT walked into nested HStacks/VStacks here — the solver already produced absolute rects,
// so we place every leaf + divider ABSOLUTELY in ONE ZStack keyed `.id(PaneID)`. This honors the repo
// guardrail "drive geometry in one structure, never tree-relocate a pane on a mode change" (a zoom, a split
// add/remove, a resize all just re-emit rects — the leaf views keep their identity and the libghostty
// surface survives). Do NOT switch to HSplitView/VSplitView — they rebuild subtrees and kill surfaces.
//
// NO STATIC-MIRROR FLAG. This view was the ENTRY POINT of a defaulted-false `staticMirror` parameter
// for a headless `ImageRenderer` snapshot path: it threaded down through `PaneContainer` into both leaves
// and branched ~20 times on the way. No caller ever passed `true` — not the two mounts of this view
// (`ContentColumn`, and `SatellitePaneContent` onto `PaneContainer`), not a preview, not a UI test —
// so every one of those branches had exactly one reachable arm. It was deleted in increment 56d,
// before the AppKit canvas rewrite could hand-write them all a second time, and
// `scripts/check-supervisor.sh` fails the build if the name comes back. A snapshot renderer, if it is
// ever wanted, gates ONCE where the render starts: a flag that reaches a leaf's `.task` and a pure
// predicate in ClientCore is a second rendering mode maintained by everyone who touches the canvas.
//
// NO DRAG DECISIONS. The grab-handle drag used to live here as a `@State private var move` plus six
// private methods — where the cursor would land, whether the source is still in the active tab, what a
// release commits, and the two geometry reports. Not one of them read a design token, laid anything
// out or named a view type, which is docs/56 §3's per-DECLARATION test verbatim; increment 54 missed
// them because the canvas is ONE import edge no matter how much decision is inside it, and 56c's ruling
// says why that is not an excuse — *a method on a `View` is not a view, but nothing that is not one can
// reach it*. They are ``PaneCanvasDragController``'s (`SlopDeskClientCore`) now, so the second renderer
// CALLS them instead of translating them. The one that had to move most is `commitDestination`: its
// tear-off arm records the drop placement BEFORE `detachPaneToWindow`, because `detachedPanes` mutates
// synchronously — an ordering that was pinned by a doc comment and is pinned by a test now.
//
// Dividers drag → LIVE resize: `store.setDividerWeightLive` each frame (panes move live) bracketed by
// `store.setTerminalResizeSuspended` (defer the host grid-resize to release) + `store.commitDividerResize`;
// double-click → `store.evenDividerTree` (evens ONLY that seam — the whole-tab reset stays on the ⌃⌘=
// `balanceActivePaneSplits`). SYSTEM colours only.

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct SplitContainer: View {
    let store: WorkspaceStore
    /// The cross-container drag rendezvous — lets the in-canvas grab handle resolve SIDEBAR / tear-off
    /// destinations once the cursor leaves this hosting view, and lets a satellite-origin drag preview
    /// its canvas landing here. `nil` (previews / iOS) keeps the drag canvas-only.
    var paneDrag: PaneDragCoordinator?

    /// The live pane-move drag (grab handle) and every decision it turns on — where the cursor would
    /// land, what a release commits, and the two geometry reports the chords resolve against. It is
    /// ``PaneCanvasDragController`` in `SlopDeskClientCore` rather than six private methods here for the
    /// reason docs/56 §3 states per DECLARATION: none of them read a token, laid anything out or named a
    /// view, so leaving them inside this `some View` meant the AppKit canvas would have re-written them
    /// by hand — `commitDestination`'s load-bearing tear-off ORDER included.
    ///
    /// `@State` with the store + coordinator taken at construction: both are app-lifetime and this view
    /// already holds them for exactly as long, and a later `attach` would have raced the tab layer's own
    /// appear hook, which is where the first solved-layout report comes from.
    @State private var drag: PaneCanvasDragController

    init(store: WorkspaceStore, paneDrag: PaneDragCoordinator? = nil) {
        self.store = store
        self.paneDrag = paneDrag
        _drag = State(initialValue: PaneCanvasDragController(store: store, coordinator: paneDrag))
    }

    /// EVERY tab of every RETAINED session (the active session + the LRU-retained previous ones — see
    /// ``WorkspaceStore/retainedSessionIDs``), in session-then-tab-bar order. We render ALL of them (see
    /// `body`), revealing only the active session's active tab, so NEITHER a tab switch NOR an A→B→A session
    /// switch unmounts a pane subtree — unmounting on a session switch would dismantle every outgoing
    /// surface and force a repaint via the lossy ring replay. Stale retained ids (a since-closed session) are dropped
    /// by the `tree.sessions` intersection; the active session is always included even before the first switch
    /// (when the retention set is still empty).
    private var tabs: [SlopDeskWorkspaceModel.Tab] {
        PaneCanvasMounting.mountedTabs(
            sessions: store.tree.sessions,
            retained: store.retainedSessionIDs,
            activeID: store.tree.activeSessionID,
        )
    }

    /// The selected tab's id — the ONE tab shown + interactive; every other tab is mounted but hidden.
    private var activeTabID: TabID? { store.tree.activeSession?.activeTab?.id }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            // KEEP-ALL-MOUNTED: every tab of the active session stays mounted at opacity(0), never torn down —
            // dropping this invariant would kill the libghostty surface on every hidden tab. Render a layer for
            // EVERY tab of the active session, but reveal + hit-test only the selected one. A hidden tab's panes stay
            // on-window, so their ghostty surfaces keep ticking + repainting from live host output — switching
            // to a tab shows its CURRENT screen with NO teardown/soft-reset/ring-replay (the replay is a lossy
            // re-feed that dropped an unfocused pane's prompt). PaneIDs are unique across a session's tabs, so
            // one ZStack keyed per-tab (and per-`PaneID` within) has no identity collision.
            ZStack {
                ForEach(tabs) { tab in
                    let isActive = tab.id == activeTabID
                    tabLayer(tab, isActive: isActive, in: bounds)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                        .id(tab.id) // OUTER key only — inner pane leaves stay keyed by PaneID
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            // Report the full container bounds — the geometric ops' fallback before the first solved-layout
            // report. View-only — never reconciles. Fires ONCE at the container level, not per tab.
            .onAppear { drag.reportContainerBounds(bounds) }
            .onChange(of: bounds) { _, newBounds in drag.reportContainerBounds(newBounds) }
        }
        .background(Slate.Surface.terminal)
        // Register this canvas's SCREEN rect (and, through it, the main window frame — the tear-off
        // boundary) with the drag coordinator, so sidebar/satellite drags can hit-test it.
        .background(canvasFrameReader)
    }

    /// The canvas's drop-target registration, and the LAST platform gate in this file.
    ///
    /// It is a gate rather than a missing feature: the reader publishes a SCREEN rect so that a drag
    /// crossing between separate hosting views (the AppKit split's columns, a satellite `NSWindow`)
    /// can be hit-tested in one space — and a phone has one window, one hosting view and no
    /// cross-window drag to resolve. `paneDrag` is nil on iOS for exactly that reason, so the body
    /// would be empty there even if the type existed. Written as ONE gate INSIDE the builder, not as
    /// a second gate around the `.background` above: an empty `@ViewBuilder` is `EmptyView`, which
    /// costs the phone nothing and costs the reader one place to be wrong instead of two.
    @ViewBuilder
    private var canvasFrameReader: some View {
        #if os(macOS)
        if let paneDrag {
            DropTargetFrameReader(key: .canvas, coordinator: paneDrag)
        }
        #endif
    }

    /// One tab's pane tree, placed absolutely in a ZStack. Rendered for EVERY tab; the caller hides +
    /// disables all but the active one. Interaction chrome (dividers, move handles, drop) is drawn only for
    /// the active tab — a hidden tab is non-interactive, so it needs none.
    @ViewBuilder
    private func tabLayer(_ tab: SlopDeskWorkspaceModel.Tab, isActive: Bool, in bounds: CGRect) -> some View {
        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
        let frames = Dictionary(layout.leaves.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        ZStack(alignment: .topLeading) {
            // EVERY pane — visible AND zoom-hidden — renders from ONE `ForEach` over
            // ``SplitTreeRenderModel/Layout/compositorLeaves``. `.id` only dedups WITHIN one `ForEach`, so
            // one keyed list keeps the zoom hidden↔visible flip within one collection and the hosted
            // terminal / video surface is never torn down.
            ForEach(layout.compositorLeaves, id: \.id) { entry in
                PaneContainer(
                    store: store,
                    paneID: entry.id,
                    // A zoom-hidden pane must never claim first responder (mirrors the keep-all-mounted
                    // focus-steal guard for hidden tabs). While the code panel's webview owns the
                    // keyboard the workspace-focused pane renders UNFOCUSED (hollow cursor, no focus
                    // chrome) — and, through the terminal's focus-gated responder claim, stops
                    // re-taking the keyboard the editor is using.
                    isFocused: CodeSidebarKeyboardState.paneRendersFocused(
                        workspaceFocused: !entry.isHidden
                            && PaneFocusPolicy.isPaneFocused(entry.id, in: tab, activeTabID: activeTabID),
                        sidebarOwnsKeyboard: CodeSidebarKeyboardState.shared.ownsKeyboard,
                    ),
                    // ON-SCREEN gate: visible ⟺ the pane's tab is the active tab AND it is
                    // not zoom-hidden. A video pane drives its `liveVideoCap` activation off THIS — a
                    // hidden tab / zoom-collapsed sibling releases its slot + stops the UDP/VT/Metal pipeline,
                    // re-activating when it returns (onDisappear never fires under keep-all-mounted).
                    isVisible: isActive && !entry.isHidden,
                    // The content's live size IS the resize signal `PaneContainer`'s scrim keys off.
                    size: entry.leaf.rect.size,
                )
                .frame(width: entry.leaf.rect.width, height: entry.leaf.rect.height)
                .position(x: entry.leaf.rect.midX, y: entry.leaf.rect.midY)
                // ZOOM keep-mounted: a zoomed tab still emits every sibling as a HIDDEN compositor leaf at
                // its un-zoomed rect — revealed/hidden here exactly like an inactive tab's layer, so the
                // libghostty surface / video stream survives the zoom toggle and un-zoom is a pure
                // visibility flip (no teardown, no lossy ring-replay).
                .opacity(entry.isHidden ? 0 : 1)
                .allowsHitTesting(!entry.isHidden)
                .accessibilityHidden(entry.isHidden)
                .id(entry.id) // identity hazard: never reuse a surface across panes
            }
            // Interaction chrome only for the active tab (a hidden tab is non-interactive anyway) —
            // EXCEPT the moveLayer of the tab OWNING a live drag: a spring-loaded reveal switches tabs
            // mid-drag, and unmounting the source tab's layer would destroy the grab handle whose
            // gesture is still tracking. The hidden layer sits at opacity(0) with hit-testing off, so
            // keeping it mounted renders nothing.
            if isActive {
                // Dividers + the grab-handles / live drag overlay sit ABOVE the panes (z 0) via an
                // explicit z-index band.
                ForEach(layout.dividers, id: \.key) { handle in
                    dividerView(handle)
                }
                .zIndex(PaneCanvasMetrics.dividerZ)
            }
            if isActive || drag.moveSourceIsIn(frames) {
                // Grab-handles + the live drag overlay (extracted to keep this ZStack type-checkable).
                moveLayer(leaves: layout.leaves, frames: frames, container: bounds)
                    .zIndex(PaneCanvasMetrics.moveZ)
            }
            if isActive {
                // The landing preview for a drag that STARTED OUTSIDE this tab — a satellite window's
                // grab strip, or a tree pane whose tab was spring-loaded away — same zone visuals,
                // driven by the coordinator's published destination.
                if let paneDrag {
                    ExternalDropZonePreview(coordinator: paneDrag, frames: frames, container: bounds)
                        .zIndex(PaneCanvasMetrics.moveZ)
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .coordinateSpace(name: PaneMoveSpace.name)
        // Report the ACTIVE tab's solved leaf rects to the store (`updateSolvedLayout`) — required wiring:
        // without it `lastSolvedLayout` stays forever nil and the ⌃⌘arrow / ⌥⌘⇧arrow chords resolve against
        // the store's nominal fallback instead of the real geometry. View-only state;
        // never reconciles. Skipped for hidden tabs (only the visible geometry counts).
        .onAppear { drag.reportSolvedLayout(frames, isActive: isActive) }
        .onChange(of: frames) { _, newFrames in drag.reportSolvedLayout(newFrames, isActive: isActive) }
        .onChange(of: isActive) { _, nowActive in drag.reportSolvedLayout(frames, isActive: nowActive) }
    }

    /// One divider, placed at its LIVE solved seam (`handle.rect.mid`, which the solver re-emits as the panes
    /// resize each drag frame). The view sits at its solved position the whole time — moving `.position` does
    /// NOT interrupt the drag because (a) the `ForEach` keys on the STABLE `handle.key` so the view identity
    /// survives the per-frame weight mutation (no teardown), and (b) `PaneDivider` reads its translation in
    /// the fixed `PaneMoveSpace.name` coordinate space, so the cursor delta is correct regardless of where
    /// the handle has slid. (A frozen-host / `.offset` dance is unnecessary and would only treat a symptom —
    /// keying on the stable `handle.key` instead of `id: \.self` fixes the identity churn at the source.)
    private func dividerView(_ handle: SplitTreeRenderModel.DividerHandle) -> some View {
        PaneDivider(
            handle: handle,
            // Live resize: hold the host grid-resize for the drag, set the leading weight absolutely each
            // frame (panes move live), then flush + persist ONCE on release.
            onResizeBegin: { store.setTerminalResizeSuspended(true) },
            onResizeChange: { leadingWeight in
                store.setDividerWeightLive(
                    splitID: handle.splitID,
                    leadingChildIndex: handle.childIndex,
                    leadingWeight: leadingWeight,
                )
            },
            onResizeEnd: {
                store.setTerminalResizeSuspended(false)
                store.commitDividerResize()
            },
            // Double-click evens ONLY this seam — NOT balanceActivePaneSplits(), which rebalances every
            // split of the tab and wiped the other dividers' dragged ratios.
            onReset: { store.evenDividerTree(splitID: handle.splitID, leadingChildIndex: handle.childIndex) },
        )
        .position(x: handle.rect.midX, y: handle.rect.midY)
    }

    /// The pane move affordance: a top grab handle per leaf plus the live drag overlay. With a drag
    /// coordinator wired even a SOLE leaf gets its handle — a lone pane has no in-tab target, but it can
    /// still leave: onto a sidebar row, the New-Tab slot, or out of the window entirely.
    @ViewBuilder
    private func moveLayer(
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        frames: [PaneID: CGRect],
        container: CGRect,
    ) -> some View {
        if leaves.count > 1 || paneDrag != nil {
            ForEach(leaves, id: \.id) { leaf in
                moveHandle(for: leaf, leaves: leaves, container: container)
            }
            if let move = drag.move {
                PaneMoveOverlay(
                    drag: move,
                    frames: frames,
                    container: container,
                    sourceTitle: store.tree.activeSession?.specs[move.source]?.title,
                )
                .allowsHitTesting(false)
                // Quick opacity snap between zones (paired with the per-zone `.id` cross-fade in the
                // overlay) — NOT the 0.20s slab frame-morph, which swept a big rectangle edge-to-edge.
                .animation(Slate.Anim.smallFade, value: move.zone)
            }
            // Escape bails out of a live move without committing — armed only while a drag is in flight,
            // so it never shadows Escape for anything else at rest. Mounted UNCONDITIONALLY: the
            // monitor owns its own platform gate (see ``PaneMoveEscapeMonitor``), and restating it
            // here would be the same fact in two files. Escape and a gesture cancel are the SAME
            // bail-out, so both are the controller's one `interrupted()` rather than two spellings.
            PaneMoveEscapeMonitor(isActive: drag.move != nil) { drag.interrupted() }
                .frame(width: 0, height: 0)
        }
    }

    private func moveHandle(
        for leaf: SplitTreeRenderModel.PlacedLeaf,
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
    ) -> some View {
        PaneMoveHandle(
            leafSize: leaf.rect.size,
            isDragging: drag.move?.source == leaf.id,
            // Every arm of the gesture is the controller's — this closure supplies the cursor point and
            // the frame it was measured in, and nothing else. What the destination IS, which zone the
            // local overlay may preview, and what a release commits are all decisions, so they are the
            // one place an AppKit canvas will ask them from too.
            onChanged: { loc in
                drag.changed(leaf: leaf, among: leaves, container: container, at: loc)
            },
            onEnded: { loc in
                drag.ended(leaf: leaf, among: leaves, container: container, at: loc)
            },
            onTap: { store.focusPaneTree(leaf.id) },
            // The interruption safety net: a cancel, or this leaf closing mid-drag (torn out of the
            // `ForEach` before `onEnded` can fire), still clears the drag state + the cross-window
            // coordinator — otherwise `.allowsHitTesting(move == nil || …)` below wedges EVERY other
            // handle non-interactive forever. No commit here — a cancel commits nothing.
            onInterrupted: { drag.interrupted() },
            // A video leaf streams arbitrary (usually light) content — the handle pill needs its
            // contrast plate there (see `PaneMoveHandle.contentIsUnthemed`).
            contentIsUnthemed: store.tree.spec(for: leaf.id)?.kind.isVideo == true,
        )
        .frame(width: leaf.rect.width, height: leaf.rect.height)
        .position(x: leaf.rect.midX, y: leaf.rect.midY)
        // During a drag only the source handle stays live (it owns the gesture); the rest stop hit-testing
        // so their top strips don't shadow the drop target.
        .allowsHitTesting(drag.move == nil || drag.move?.source == leaf.id)
    }
}

/// The canvas-side landing preview for a drag whose SOURCE is not in this tab — a satellite window's
/// grab strip, or a tree pane whose own tab was spring-loaded away mid-drag: draws the coordinator's
/// resolved insert zone with the SAME static previews the in-canvas overlay uses (one drop
/// vocabulary). Reads only the PUBLISHED drag, so it re-renders on destination transitions — never per
/// cursor frame.
private struct ExternalDropZonePreview: View {
    let coordinator: PaneDragCoordinator
    let frames: [PaneID: CGRect]
    let container: CGRect

    var body: some View {
        if let drag = coordinator.drag, frames[drag.source] == nil,
           case let .canvas(zone) = drag.destination
        {
            Group {
                switch zone {
                case let .swap(target):
                    if let rect = frames[target] { PaneMoveOverlay.washPreview(rect) }
                case let .resplit(target, edge):
                    if let rect = frames[target] { PaneMoveOverlay.slabPreview(in: rect, edge: edge) }
                case let .dock(edge):
                    PaneMoveOverlay.railPreview(in: container, edge: edge)
                case .none:
                    EmptyView()
                }
            }
            .allowsHitTesting(false)
        }
    }
}
#endif
