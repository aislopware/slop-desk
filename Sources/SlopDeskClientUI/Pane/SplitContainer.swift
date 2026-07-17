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
// Dividers drag → LIVE resize: `store.setDividerWeightLive` each frame (panes move live) bracketed by
// `store.setTerminalResizeSuspended` (defer the host grid-resize to release) + `store.commitDividerResize`;
// double-click → `store.evenDividerTree` (evens ONLY that seam — the whole-tab reset stays on the ⌃⌘=
// `balanceActivePaneSplits`). SYSTEM colours only.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

struct SplitContainer: View {
    let store: WorkspaceStore
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false
    /// The cross-container drag rendezvous — lets the in-canvas grab handle resolve SIDEBAR / tear-off
    /// destinations once the cursor leaves this hosting view, and lets a satellite-origin drag preview
    /// its canvas landing here. `nil` (previews / iOS / static path) keeps the drag canvas-only.
    var paneDrag: PaneDragCoordinator?

    /// Live pane-move drag (grab-handle). View-local: the store is untouched until release, so the
    /// terminal-grid / remote-window redraw fires once on commit, not per drag frame.
    @State private var move: PaneMoveDrag?

    /// EVERY tab of every RETAINED session (the active session + the LRU-retained previous ones — see
    /// ``WorkspaceStore/retainedSessionIDs``), in session-then-tab-bar order. We render ALL of them (see
    /// `body`), revealing only the active session's active tab, so NEITHER a tab switch NOR an A→B→A session
    /// switch unmounts a pane subtree — unmounting on a session switch would dismantle every outgoing
    /// surface and force a repaint via the lossy ring replay. Stale retained ids (a since-closed session) are dropped
    /// by the `tree.sessions` intersection; the active session is always included even before the first switch
    /// (when the retention set is still empty).
    private var tabs: [SlopDeskWorkspaceCore.Tab] {
        let retained = store.retainedSessionIDs
        let activeID = store.tree.activeSessionID
        return store.tree.sessions
            .filter { retained.contains($0.id) || $0.id == activeID }
            .flatMap(\.tabs)
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
            // report. View-only — never reconciles. Skipped on the static snapshot path. Fires ONCE at the
            // container level, not per tab.
            .onAppear { if !staticMirror { reportContainerBounds(bounds) } }
            .onChange(of: bounds) { _, newBounds in if !staticMirror { reportContainerBounds(newBounds) } }
        }
        .background(NativePaneColor.window)
        #if os(macOS)
            // Register this canvas's SCREEN rect (and, through it, the main window frame — the tear-off
            // boundary) with the drag coordinator, so sidebar/satellite drags can hit-test it.
            .background(canvasFrameReader)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var canvasFrameReader: some View {
        if let paneDrag, !staticMirror {
            DropTargetFrameReader(key: .canvas, coordinator: paneDrag)
        }
    }
    #endif

    /// Push the container bounds to the store (the geometric ops' fallback) AND the drag coordinator
    /// (the canvas-local space a satellite-origin drag resolves its insert zones in).
    private func reportContainerBounds(_ bounds: CGRect) {
        store.updateContainerBounds(bounds)
        paneDrag?.canvasBounds = bounds
    }

    /// One tab's pane tree, placed absolutely in a ZStack. Rendered for EVERY tab; the caller hides +
    /// disables all but the active one. Interaction chrome (dividers, move handles, drop) is drawn only for
    /// the active tab — a hidden tab is non-interactive, so it needs none.
    @ViewBuilder
    private func tabLayer(_ tab: SlopDeskWorkspaceCore.Tab, isActive: Bool, in bounds: CGRect) -> some View {
        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
        let frames = Dictionary(layout.leaves.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        ZStack(alignment: .topLeading) {
            // EVERY pane — visible AND zoom-hidden — renders from ONE `ForEach` over
            // ``SplitTreeRenderModel/Layout/compositorLeaves``. `.id` only dedups WITHIN one `ForEach`, so
            // one keyed list keeps the zoom hidden↔visible flip within one collection and the hosted
            // terminal / `.remoteGUI` video surface is never torn down.
            ForEach(layout.compositorLeaves, id: \.id) { entry in
                PaneContainer(
                    store: store,
                    paneID: entry.id,
                    // A zoom-hidden pane must never claim first responder (mirrors the keep-all-mounted
                    // focus-steal guard for hidden tabs).
                    isFocused: !entry.isHidden && Self.isPaneFocused(entry.id, in: tab, activeTabID: activeTabID),
                    // ON-SCREEN gate: visible ⟺ the pane's tab is the active tab AND it is
                    // not zoom-hidden. A `.remoteGUI` pane drives its `liveVideoCap` activation off THIS — a
                    // hidden tab / zoom-collapsed sibling releases its slot + stops the UDP/VT/Metal pipeline,
                    // re-activating when it returns (onDisappear never fires under keep-all-mounted).
                    isVisible: isActive && !entry.isHidden,
                    // The content's live size IS the resize signal `PaneContainer`'s scrim keys off.
                    size: entry.leaf.rect.size,
                    staticMirror: staticMirror,
                )
                .frame(width: entry.leaf.rect.width, height: entry.leaf.rect.height)
                .position(x: entry.leaf.rect.midX, y: entry.leaf.rect.midY)
                // ZOOM keep-mounted: a zoomed tab still emits every sibling as a HIDDEN compositor leaf at
                // its un-zoomed rect — revealed/hidden here exactly like an inactive tab's layer, so the
                // libghostty surface / `.remoteGUI` stream survives the zoom toggle and un-zoom is a pure
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
                .zIndex(Self.dividerZ)
            }
            if isActive || moveSourceIsIn(frames) {
                // Grab-handles + the live drag overlay (extracted to keep this ZStack type-checkable).
                moveLayer(leaves: layout.leaves, frames: frames, container: bounds)
                    .zIndex(Self.moveZ)
            }
            if isActive {
                // The landing preview for a drag that STARTED OUTSIDE this tab — a satellite window's
                // grab strip, or a tree pane whose tab was spring-loaded away — same zone visuals,
                // driven by the coordinator's published destination.
                if let paneDrag, !staticMirror {
                    ExternalDropZonePreview(coordinator: paneDrag, frames: frames, container: bounds)
                        .zIndex(Self.moveZ)
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .coordinateSpace(name: PaneMoveSpace.name)
        // Report the ACTIVE tab's solved leaf rects to the store (`updateSolvedLayout`) — required wiring:
        // without it `lastSolvedLayout` stays forever nil and the ⌃⌘arrow / ⌥⌘⇧arrow chords resolve against
        // the store's nominal fallback instead of the real geometry. View-only state;
        // never reconciles. Skipped for hidden tabs (only the visible geometry counts) + the static path.
        .onAppear { reportSolvedLayout(frames, isActive: isActive) }
        .onChange(of: frames) { _, newFrames in reportSolvedLayout(newFrames, isActive: isActive) }
        .onChange(of: isActive) { _, nowActive in reportSolvedLayout(frames, isActive: nowActive) }
    }

    /// Forwards the active tab's solved frames to `store.updateSolvedLayout` (a hidden tab / the static
    /// snapshot path never reports — the store must only ever hold the geometry the user actually sees)
    /// and mirrors them to the drag coordinator so a satellite-origin drag resolves its canvas insert
    /// zones against the same live geometry.
    private func reportSolvedLayout(_ frames: [PaneID: CGRect], isActive: Bool) {
        guard isActive, !staticMirror, !frames.isEmpty else { return }
        store.updateSolvedLayout(SolvedLayout(frames: frames))
        paneDrag?.canvasFrames = frames
    }

    /// The z-index band the compositor ZStack stacks by: panes at the base (0), then the divider layer,
    /// then the move-handle / drag-overlay layer.
    static let dividerZ: Double = 10
    static let moveZ: Double = 20

    /// Whether the live drag's SOURCE pane is one of this tab layer's leaves — the keep-mounted gate
    /// that lets its grab-handle gesture survive a spring-loaded tab switch.
    private func moveSourceIsIn(_ frames: [PaneID: CGRect]) -> Bool {
        guard let move else { return false }
        return frames[move.source] != nil
    }

    /// Whether pane `paneID` (in `tab`) should own the renderer's keyboard focus — the guard that makes
    /// keep-all-mounted safe. TRUE only when `tab` is the ACTIVE tab AND `paneID` is that tab's `activePane`.
    /// Every mounted background tab still carries its own `activePane`, but it must NOT claim first responder
    /// (`GhosttyLayerBackedView.applyKeyboardFocus` acts only when `isFocusedPane`), or the last-mounted hidden
    /// tab would steal the keyboard from the visible one. Pure + static so it is headlessly testable.
    static func isPaneFocused(_ paneID: PaneID, in tab: SlopDeskWorkspaceCore.Tab, activeTabID: TabID?) -> Bool {
        tab.id == activeTabID && paneID == tab.activePane
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
    /// still leave: onto a sidebar row, the New-Tab slot, or out of the window entirely. Skipped
    /// entirely on the static snapshot path.
    @ViewBuilder
    private func moveLayer(
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        frames: [PaneID: CGRect],
        container: CGRect,
    ) -> some View {
        if !staticMirror, leaves.count > 1 || paneDrag != nil {
            ForEach(leaves, id: \.id) { leaf in
                moveHandle(for: leaf, leaves: leaves, container: container)
            }
            if let move {
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
        }
    }

    private func moveHandle(
        for leaf: SplitTreeRenderModel.PlacedLeaf,
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
    ) -> some View {
        PaneMoveHandle(
            leafSize: leaf.rect.size,
            isDragging: move?.source == leaf.id,
            onChanged: { loc in
                let dest = dragDestination(
                    at: loc, leaves: leaves, container: container, source: leaf.id, sourceRect: leaf.rect,
                )
                // The local overlay draws only the CANVAS zones of the source's OWN (active) tab; an
                // external destination reads `.none` here (its cursor chip is clipped at the
                // hosting-view edge anyway — the coordinator's floating panel + the sidebar highlights
                // are the affordance out there), and so does a spring-loaded canvas zone (the ACTIVE
                // tab's `ExternalDropZonePreview` owns that preview — this layer's frames are the wrong
                // tab's).
                let localZone = sourceIsInActiveTab(leaf.id) ? Self.canvasZone(of: dest) : PaneDropZone.none
                move = PaneMoveDrag(source: leaf.id, location: loc, zone: localZone)
                publishTreeDrag(dest, source: leaf.id, local: loc, soleLeaf: leaves.count <= 1)
            },
            onEnded: { loc in
                let dest = dragDestination(
                    at: loc, leaves: leaves, container: container, source: leaf.id, sourceRect: leaf.rect,
                )
                commitDestination(dest, source: leaf.id, local: loc)
                move = nil
                paneDrag?.end()
            },
            onTap: { store.focusPaneTree(leaf.id) },
            // A video leaf streams arbitrary (usually light) content — the handle pill needs its
            // contrast plate there (see `PaneMoveHandle.contentIsUnthemed`).
            contentIsUnthemed: store.tree.spec(for: leaf.id)?.kind.isVideo == true,
        )
        .frame(width: leaf.rect.width, height: leaf.rect.height)
        .position(x: leaf.rect.midX, y: leaf.rect.midY)
        // During a drag only the source handle stays live (it owns the gesture); the rest stop hit-testing
        // so their top strips don't shadow the drop target.
        .allowsHitTesting(move == nil || move?.source == leaf.id)
    }

    /// Commits the resolved drop `zone` with exactly ONE store op (remote-app rule: the drag was all
    /// view-local; the terminal-grid / remote-window redraw fires once, here on release).
    private func commit(_ zone: PaneDropZone, source: PaneID) {
        switch zone {
        case .none:
            break
        case let .swap(target):
            store.swapPanesTree(source, target)
        case let .resplit(target, edge):
            store.moveLeafTree(source, beside: target, axis: edge.axis, before: edge.insertsBefore)
        case let .dock(edge):
            store.moveLeafToRootEdgeTree(source, edge: edge)
        }
    }

    /// The FULL destination for a tree drag at canvas-local `loc`: inside the canvas the live in-tab
    /// resolution applies unchanged; outside it, the coordinator's registered targets (sidebar rows,
    /// the New-Tab slot, the tear-off boundary) take over. Without a coordinator (previews / iOS) the
    /// gesture stays canvas-only, exactly the old behaviour.
    ///
    /// A SPRING-LOADED reveal can switch the active tab mid-drag — the source then no longer lives in
    /// the visible tab, so the canvas resolves with INSERT semantics against the coordinator's pushed
    /// active-tab layout instead of this (hidden) layer's own leaves.
    private func dragDestination(
        at loc: CGPoint,
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
        source: PaneID,
        sourceRect: CGRect,
    ) -> PaneDragDestination {
        if let paneDrag, !sourceIsInActiveTab(source) {
            guard let canvas = paneDrag.targetFrame(.canvas) else { return .canvas(.none) }
            return paneDrag.resolveSpringLoadedTreeDestination(
                at: PaneDragResolver.screenPoint(fromCanvasLocal: loc, canvas: canvas),
                source: source,
                sourceIsSoleLeafOfItsTab: leaves.count <= 1,
            )
        }
        if container.contains(loc) || paneDrag == nil {
            return .canvas(resolveZone(
                at: loc, leaves: leaves, container: container, source: source, sourceRect: sourceRect,
            ))
        }
        guard let paneDrag, let canvas = paneDrag.targetFrame(.canvas) else { return .canvas(.none) }
        return paneDrag.resolveTreeExternalDestination(
            at: PaneDragResolver.screenPoint(fromCanvasLocal: loc, canvas: canvas),
            source: source,
            sourceIsSoleLeafOfItsTab: leaves.count <= 1,
        )
    }

    /// Whether `source` still lives in the ACTIVE tab — false after a spring-loaded reveal switched
    /// tabs under a live drag. Decides both the canvas resolution semantics (in-tab swap/re-split vs
    /// insert) and the commit family (same-tab move vs cross-tab move).
    private func sourceIsInActiveTab(_ source: PaneID) -> Bool {
        store.tree.activeSession?.activeTab?.allPaneIDs().contains(source) ?? true
    }

    /// Mirror the live tree drag to the coordinator — the sidebar highlights / New-Tab slot / floating
    /// chip / spring-load dwell all render off this one published state. `soleLeaf` rides along so the
    /// coordinator's auto-scroll tick can re-resolve the external destination without re-asking here.
    private func publishTreeDrag(_ dest: PaneDragDestination, source: PaneID, local: CGPoint, soleLeaf: Bool) {
        guard let paneDrag, let canvas = paneDrag.targetFrame(.canvas) else { return }
        paneDrag.update(
            source: source,
            origin: .tree,
            screenPoint: PaneDragResolver.screenPoint(fromCanvasLocal: local, canvas: canvas),
            destination: dest,
            sourceIsSoleLeafOfItsTab: soleLeaf,
        )
    }

    /// Commits the FULL destination with exactly ONE store op. `.canvas` keeps the original in-tab
    /// vocabulary; the external destinations map onto the (PaneID-preserving) cross-tab / detach ops,
    /// so no surface tears down on any path.
    private func commitDestination(_ dest: PaneDragDestination, source: PaneID, local: CGPoint) {
        switch dest {
        case let .canvas(zone) where !sourceIsInActiveTab(source):
            // Spring-loaded landing: the zone was resolved (insert semantics) against ANOTHER tab's
            // canvas — commit with the cross-tab ops. `.swap` can't come out of the insert resolution.
            switch zone {
            case let .resplit(target, edge):
                store.moveLeafAcrossTabsTree(source, beside: target, axis: edge.axis, before: edge.insertsBefore)
            case let .dock(edge):
                store.moveLeafToActiveTabRootEdgeTree(source, edge: edge)
            case .swap,
                 .none:
                break
            }
        case let .canvas(zone):
            commit(zone, source: source)
        case let .sidebarRow(anchor):
            store.moveLeafAcrossTabsTree(source, beside: anchor, axis: .horizontal, before: false)
        case .newTab:
            store.breakPaneToTab(source)
        case .tearOff:
            // Record the drop point FIRST — the detach op's `detachedPanes` change synchronously drives
            // the satellite coordinator, which consumes the placement when it opens the window.
            if let paneDrag, let canvas = paneDrag.targetFrame(.canvas) {
                paneDrag.recordPlacement(
                    source, at: PaneDragResolver.screenPoint(fromCanvasLocal: local, canvas: canvas),
                )
            }
            store.detachPaneToWindow(source)
        case .none:
            break
        }
    }

    /// The in-canvas zone a full destination carries (`.none` for every external destination — the
    /// local overlay must not preview a drop that will land outside this canvas).
    static func canvasZone(of dest: PaneDragDestination) -> PaneDropZone {
        if case let .canvas(zone) = dest { return zone }
        return .none
    }

    // MARK: - Drop-zone resolution (container gutter > target edge band > target centre)

    /// Resolves the cursor `location` to the drop action a release would commit. Precedence: the container
    /// outer DOCK gutter first (full-span dock), then — over a non-source target leaf — its CENTRE box
    /// (swap) vs an EDGE band (re-split). Empty space / the source's own pane → `.none` (cancel).
    private func resolveZone(
        at location: CGPoint,
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
        source: PaneID,
        sourceRect: CGRect,
    ) -> PaneDropZone {
        // 1) Container outer gutter → dock. Suppress an edge the source ALREADY fully spans (docking there is
        //    a visual no-op — also keeps grabbing the top/edge pane from instantly previewing a dock).
        if let edge = PaneDropGeometry.containerEdge(at: location, container: container, sourceRect: sourceRect) {
            return .dock(edge: edge)
        }
        // 2) Over a target leaf (not the source): centre → swap, edge band → re-split.
        guard let (target, rect) = PaneDropGeometry.leaf(at: location, in: leaves, excluding: source),
              rect.width > 0, rect.height > 0
        else {
            return .none
        }
        let u = (location.x - rect.minX) / rect.width
        let v = (location.y - rect.minY) / rect.height
        let band = PaneDropMetrics.edgeBandFraction
        let inCentreX = u >= band && u <= 1 - band
        let inCentreY = v >= band && v <= 1 - band
        if inCentreX, inCentreY {
            return .swap(target: target)
        }
        return .resplit(target: target, edge: PaneDropGeometry.dominantEdge(u: u, v: v, band: band))
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
