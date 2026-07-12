// SplitContainer — renders EVERY tab's pane tree, revealing only the active one (REBUILD-V2, L2). The
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

    /// Live pane-move drag (grab-handle). View-local: the store is untouched until release, so the
    /// terminal-grid / remote-window redraw fires once on commit, not per drag frame.
    @State private var move: PaneMoveDrag?

    #if os(macOS)
    /// Live rail-window drop (a HOST WINDOW row dragged off the right rail — docs/45 round 3).
    /// View-local like `move`: the store is untouched until `performDrop` commits exactly ONE op.
    @State private var windowDrop: HostWindowDropDrag?
    #endif

    /// EVERY tab of every RETAINED session (the active session + the LRU-retained previous ones — see
    /// ``WorkspaceStore/retainedSessionIDs``), in session-then-tab-bar order. We render ALL of them (see
    /// `body`), revealing only the active session's active tab, so NEITHER a tab switch NOR an A→B→A session
    /// switch unmounts a pane subtree (R-lifecycle #3 — a session switch used to dismantle every outgoing
    /// surface and repaint via the lossy ring replay). Stale retained ids (a since-closed session) are dropped
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
            // KEEP-ALL-MOUNTED (restores the documented "all tabs mounted at opacity(0), never tear down the
            // libghostty surface" invariant the L2 rebuild silently dropped): render a layer for EVERY tab of
            // the active session, but reveal + hit-test only the selected one. A hidden tab's panes stay
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
                #if os(macOS)
                // Rail-window drop preview — ABOVE every tab layer (purely visual; the receiver on
                // the compositor below owns the drag lifecycle).
                if let windowDrop {
                    HostWindowDropOverlay(
                        drag: windowDrop,
                        frames: activeLeafFrames(in: bounds),
                        container: bounds,
                    )
                    .allowsHitTesting(false)
                    .animation(Slate.Anim.smallFade, value: windowDrop.zone)
                    .zIndex(1)
                }
                #endif
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            #if os(macOS)
                // Rail-window drags land HERE (the pane-level E18 receivers decline this UTType, so the
                // drop bubbles up to the compositor, whose local space == the solver's leaf-rect space).
                .onDrop(
                    of: [HostWindowDragPayload.utType],
                    delegate: HostWindowDropReceiver(
                        enabled: !staticMirror,
                        onUpdate: { location in
                            windowDrop = HostWindowDropDrag(
                                location: location,
                                zone: resolveWindowDropZone(at: location, in: bounds),
                            )
                        },
                        onExit: { windowDrop = nil },
                        onPerform: { location in
                            let zone = resolveWindowDropZone(at: location, in: bounds)
                            windowDrop = nil
                            return commitWindowDrop(zone)
                        },
                    ),
                )
            #endif
                // Report the full container bounds — the geometric ops' fallback before the first solved-layout
                // report. View-only — never reconciles. Skipped on the static snapshot path. Fires ONCE at the
                // container level, not per tab.
                .onAppear { if !staticMirror { store.updateContainerBounds(bounds) } }
                .onChange(of: bounds) { _, newBounds in if !staticMirror { store.updateContainerBounds(newBounds) } }
        }
        .background(NativePaneColor.window)
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
                    // ON-SCREEN gate (A2/R-lifecycle #2): visible ⟺ the pane's tab is the active tab AND it is
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
            // Interaction chrome only for the active tab (a hidden tab is non-interactive anyway).
            if isActive {
                // Dividers + the grab-handles / live drag overlay sit ABOVE the panes (z 0) via an
                // explicit z-index band.
                ForEach(layout.dividers, id: \.key) { handle in
                    dividerView(handle)
                }
                .zIndex(Self.dividerZ)
                // Grab-handles + the live drag overlay (extracted to keep this ZStack type-checkable).
                moveLayer(leaves: layout.leaves, frames: frames, container: bounds)
                    .zIndex(Self.moveZ)
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .coordinateSpace(name: PaneMoveSpace.name)
        // Report the ACTIVE tab's solved leaf rects to the store (`updateSolvedLayout`) — the production
        // wiring the L0/L2 rewrite dropped with `SplitTreeView`, which left `lastSolvedLayout` forever nil
        // and the ⌃⌘arrow / ⌥⌘⇧arrow chords resolving against the store's nominal fallback. View-only state;
        // never reconciles. Skipped for hidden tabs (only the visible geometry counts) + the static path.
        .onAppear { reportSolvedLayout(frames, isActive: isActive) }
        .onChange(of: frames) { _, newFrames in reportSolvedLayout(newFrames, isActive: isActive) }
        .onChange(of: isActive) { _, nowActive in reportSolvedLayout(frames, isActive: nowActive) }
    }

    /// Forwards the active tab's solved frames to `store.updateSolvedLayout` (a hidden tab / the static
    /// snapshot path never reports — the store must only ever hold the geometry the user actually sees).
    private func reportSolvedLayout(_ frames: [PaneID: CGRect], isActive: Bool) {
        guard isActive, !staticMirror, !frames.isEmpty else { return }
        store.updateSolvedLayout(SolvedLayout(frames: frames))
    }

    /// The z-index band the compositor ZStack stacks by: panes at the base (0), then the divider layer,
    /// then the move-handle / drag-overlay layer.
    static let dividerZ: Double = 10
    static let moveZ: Double = 20

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
    /// the handle has slid. (No frozen-host / `.offset` dance: that treated a symptom of the OLD `id: \.self`
    /// identity churn, which keying on `handle.key` fixes at the source.)
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

    /// The pane move affordance: a top grab handle per leaf (≥2 leaves only) plus the live drag overlay.
    /// Skipped entirely on the static snapshot path.
    @ViewBuilder
    private func moveLayer(
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        frames: [PaneID: CGRect],
        container: CGRect,
    ) -> some View {
        if !staticMirror, leaves.count > 1 {
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
                move = PaneMoveDrag(
                    source: leaf.id,
                    location: loc,
                    zone: resolveZone(
                        at: loc, leaves: leaves, container: container, source: leaf.id, sourceRect: leaf.rect,
                    ),
                )
            },
            onEnded: { loc in
                let zone = resolveZone(
                    at: loc, leaves: leaves, container: container, source: leaf.id, sourceRect: leaf.rect,
                )
                commit(zone, source: leaf.id)
                move = nil
            },
            onTap: { store.focusPaneTree(leaf.id) },
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
        if let edge = Self.containerEdge(at: location, container: container, sourceRect: sourceRect) {
            return .dock(edge: edge)
        }
        // 2) Over a target leaf (not the source): centre → swap, edge band → re-split.
        guard let (target, rect) = Self.leaf(at: location, in: leaves, excluding: source),
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
        return .resplit(target: target, edge: Self.dominantEdge(u: u, v: v, band: band))
    }

    /// The first leaf (in solver DFS order) whose rect contains `location`, excluding the dragged `source`
    /// (`nil` for an INSERT drag — a rail-window drop has no source pane to exclude). Iterating the ORDERED
    /// leaves (not the unordered `frames` dict) keeps the resolved target deterministic if a min-clamped,
    /// over-subscribed layout ever overlaps two rects.
    private static func leaf(
        at location: CGPoint,
        in leaves: [SplitTreeRenderModel.PlacedLeaf],
        excluding source: PaneID?,
    ) -> (PaneID, CGRect)? {
        for placed in leaves where placed.id != source && placed.rect.contains(location) {
            return (placed.id, placed.rect)
        }
        return nil
    }

    /// The container outer edge whose gutter contains `location` (deepest wins; tie → a vertical left/right
    /// edge), or `nil` if the cursor is in no gutter. An edge the `sourceRect` already fully spans is skipped
    /// (docking there changes nothing); `nil` for an INSERT drag — every edge is meaningful then.
    private static func containerEdge(
        at location: CGPoint, container: CGRect, sourceRect: CGRect?,
    ) -> PaneDropEdge? {
        guard container.width > 0, container.height > 0 else { return nil }
        let gutter = Double.minimum(
            Double(PaneDropMetrics.containerGutterMax),
            Double.minimum(Double(container.width), Double(container.height))
                * Double(PaneDropMetrics.containerGutterFraction),
        )
        let distances: [(edge: PaneDropEdge, dist: CGFloat)] = [
            (.left, location.x - container.minX),
            (.right, container.maxX - location.x),
            (.top, location.y - container.minY),
            (.bottom, container.maxY - location.y),
        ]
        var best: (edge: PaneDropEdge, dist: CGFloat)?
        for entry in distances {
            if let sourceRect, sourceSpans(sourceRect, entry.edge, container) { continue }
            guard entry.dist >= 0, Double(entry.dist) <= gutter else { continue }
            // Deepest into the gutter (smallest distance) wins; iteration order left,right,top,bottom makes a
            // vertical edge win an exact tie (matches the default mental model).
            if let current = best {
                if entry.dist < current.dist { best = entry }
            } else {
                best = entry
            }
        }
        return best?.edge
    }

    /// Whether `rect` already fully spans the container `edge` (so docking the pane there would be a no-op).
    private static func sourceSpans(_ rect: CGRect, _ edge: PaneDropEdge, _ container: CGRect) -> Bool {
        let eps: CGFloat = 1
        switch edge {
        case .left:
            return rect.minX <= container.minX + eps && rect.height >= container.height - eps
        case .right:
            return rect.maxX >= container.maxX - eps && rect.height >= container.height - eps
        case .top:
            return rect.minY <= container.minY + eps && rect.width >= container.width - eps
        case .bottom:
            return rect.maxY >= container.maxY - eps && rect.width >= container.width - eps
        }
    }

    /// The edge band the cursor (normalized `u`,`v` in the target) has penetrated deepest. Called only when
    /// the cursor is NOT in the centre box, so at least one penetration is positive. Exact tie → a vertical
    /// (left/right) edge.
    private static func dominantEdge(u: CGFloat, v: CGFloat, band: CGFloat) -> PaneDropEdge {
        let penetrations: [(edge: PaneDropEdge, pen: CGFloat)] = [
            (.left, band - u),
            (.right, u - (1 - band)),
            (.top, band - v),
            (.bottom, v - (1 - band)),
        ]
        var best = penetrations[0]
        for entry in penetrations.dropFirst() where entry.pen > best.pen { best = entry }
        return best.edge
    }

    #if os(macOS)

    // MARK: - Rail-window drop (docs/45 round 3 — drag a HOST WINDOW row onto the canvas)

    /// The ACTIVE tab's solved leaf rects (the overlay + the zone resolver read the SAME geometry the
    /// user sees). Recomputed per call — the solver is pure rect math over ≤ a handful of leaves.
    private func activeLeafFrames(in bounds: CGRect) -> [PaneID: CGRect] {
        guard let tab = store.tree.activeSession?.activeTab else { return [:] }
        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
        return Dictionary(layout.leaves.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
    }

    private func resolveWindowDropZone(at location: CGPoint, in bounds: CGRect) -> HostWindowDropZone {
        guard let tab = store.tree.activeSession?.activeTab else { return .newTab }
        let layout = SplitTreeRenderModel.layout(for: tab, in: bounds)
        return Self.resolveWindowDropZone(at: location, leaves: layout.leaves, container: bounds)
    }

    /// Resolves the cursor `location` of a rail-window drag to the ``HostWindowDropZone`` a release
    /// would commit — the insert-drag mirror of `resolveZone`: same gutter/edge-band geometry, no
    /// source to exclude, and the CENTRE box / any gap falls back to `.newTab` (the rail click's
    /// verb) instead of swap/cancel — every point of the canvas is a valid landing. `static` + pure
    /// so `HostWindowDropZoneTests` pins the mapping headlessly.
    static func resolveWindowDropZone(
        at location: CGPoint,
        leaves: [SplitTreeRenderModel.PlacedLeaf],
        container: CGRect,
    ) -> HostWindowDropZone {
        if let edge = containerEdge(at: location, container: container, sourceRect: nil) {
            return .dock(edge: edge)
        }
        guard let (target, rect) = leaf(at: location, in: leaves, excluding: nil),
              rect.width > 0, rect.height > 0
        else {
            return .newTab
        }
        let u = (location.x - rect.minX) / rect.width
        let v = (location.y - rect.minY) / rect.height
        let band = PaneDropMetrics.edgeBandFraction
        let inCentreX = u >= band && u <= 1 - band
        let inCentreY = v >= band && v <= 1 - band
        if inCentreX, inCentreY {
            return .newTab
        }
        return .resplit(target: target, edge: dominantEdge(u: u, v: v, band: band))
    }

    /// Commits a rail-window drop: reads the in-flight payload off the ``HostWindowDragSession`` side
    /// channel (NSItemProvider data is drop-time-async, and only rail rows vend this UTType) and opens
    /// the pane at the resolved zone — exactly ONE store op, matching the pane-move rule.
    private func commitWindowDrop(_ zone: HostWindowDropZone) -> Bool {
        guard let payload = HostWindowDragSession.shared.payload else { return false }
        HostWindowDragSession.shared.payload = nil
        switch zone {
        case .newTab:
            store.newRemoteWindowTab(
                windowID: payload.windowID, title: payload.title, appName: payload.appName,
            )
        case let .resplit(target, edge):
            store.newRemoteWindowSplit(
                windowID: payload.windowID, title: payload.title, appName: payload.appName,
                beside: target, axis: edge.axis, before: edge.insertsBefore,
            )
        case let .dock(edge):
            store.newRemoteWindowAtRootEdge(
                windowID: payload.windowID, title: payload.title, appName: payload.appName, edge: edge,
            )
        }
        store.recordRecentCommand(.newPane(.remoteGUI))
        return true
    }
    #endif
}
#endif
