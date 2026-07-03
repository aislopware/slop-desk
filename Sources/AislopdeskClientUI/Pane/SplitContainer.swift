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
import AislopdeskWorkspaceCore
import SwiftUI

struct SplitContainer: View {
    let store: WorkspaceStore
    /// TabSide partition: which COLUMN of the workspace this container renders. `nil` (iOS, the
    /// single-region shell) renders every tab and reveals the active one; `.terminal` / `.gui` renders
    /// only that side's tabs and reveals the side's DISPLAYED tab (``WorkspaceStore/displayedTab(on:)``)
    /// — the active tab when it is on this side, else the side's last-active tab. Keyboard focus stays
    /// keyed on the GLOBAL active tab, so only one pane across both columns owns first responder.
    var side: TabSide?
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// Live pane-move drag (grab-handle). View-local: the store is untouched until release, so the
    /// terminal-grid / remote-window redraw fires once on commit, not per drag frame.
    @State private var move: PaneMoveDrag?

    /// EVERY tab of every RETAINED session (the active session + the LRU-retained previous ones — see
    /// ``WorkspaceStore/retainedSessionIDs``), in session-then-tab-bar order — narrowed to this
    /// container's ``side`` (a tab is rendered by exactly ONE container; the side derivation partitions).
    /// We render ALL of them (see `body`), revealing only the displayed one, so NEITHER a tab switch NOR
    /// an A→B→A session switch unmounts a pane subtree (R-lifecycle #3 — a session switch used to
    /// dismantle every outgoing surface and repaint via the lossy ring replay). Stale retained ids (a
    /// since-closed session) are dropped by the `tree.sessions` intersection; the active session is always
    /// included even before the first switch (when the retention set is still empty).
    private var tabs: [AislopdeskWorkspaceCore.Tab] {
        let retained = store.retainedSessionIDs
        let activeID = store.tree.activeSessionID
        return store.tree.sessions
            .filter { retained.contains($0.id) || $0.id == activeID }
            .flatMap { session in
                guard let side else { return session.tabs }
                return session.tabs.filter { session.side(ofTab: $0) == side }
            }
    }

    /// The tab this container REVEALS (+ makes interactive); every other tab is mounted but hidden. For a
    /// side-scoped container this is the side's displayed tab — which may differ from the global active
    /// tab while focus lives in the OTHER column.
    private var shownTabID: TabID? {
        if let side { return store.displayedTabID(on: side) }
        return store.tree.activeSession?.activeTab?.id
    }

    /// The GLOBAL active tab's id — the keyboard-focus owner (first responder lives in it, whichever
    /// column shows it) and the solved-layout reporter's gate.
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
                    let isShown = tab.id == shownTabID
                    tabLayer(tab, isShown: isShown, in: bounds)
                        .opacity(isShown ? 1 : 0)
                        .allowsHitTesting(isShown)
                        .accessibilityHidden(!isShown)
                        .id(tab.id) // OUTER key only — inner pane leaves stay keyed by PaneID
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            // Report the full container bounds — the geometric ops' fallback before the first solved-layout
            // report. View-only — never reconciles. Skipped on the static snapshot path. Fires ONCE at the
            // container level, not per tab.
            .onAppear { if !staticMirror { store.updateContainerBounds(bounds) } }
            .onChange(of: bounds) { _, newBounds in if !staticMirror { store.updateContainerBounds(newBounds) } }
        }
        .background(NativePaneColor.window)
    }

    /// One tab's pane tree, placed absolutely in a ZStack. Rendered for EVERY tab; the caller hides +
    /// disables all but the SHOWN one (this container's revealed tab). Interaction chrome (dividers, move
    /// handles, drop) is drawn only for the shown tab — a hidden tab is non-interactive, so it needs none.
    @ViewBuilder
    private func tabLayer(_ tab: AislopdeskWorkspaceCore.Tab, isShown: Bool, in bounds: CGRect) -> some View {
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
                    // ON-SCREEN gate (A2/R-lifecycle #2): visible ⟺ the pane's tab is SHOWN (this column
                    // reveals it) AND it is not zoom-hidden. A `.remoteGUI` pane drives its `liveVideoCap`
                    // activation off THIS — a hidden tab / zoom-collapsed sibling releases its slot + stops
                    // the UDP/VT/Metal pipeline, re-activating when it returns (onDisappear never fires
                    // under keep-all-mounted).
                    isVisible: isShown && !entry.isHidden,
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
            // Interaction chrome only for the shown tab (a hidden tab is non-interactive anyway).
            if isShown {
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
        // never reconciles. Gated on the GLOBAL active tab (the keyboard ops' target), not merely shown —
        // the OTHER column's displayed-but-unfocused tab must not overwrite the focus geometry. Skipped for
        // hidden tabs + the static path.
        .onAppear { reportSolvedLayout(frames, isShown: isShown, tabID: tab.id) }
        .onChange(of: frames) { _, newFrames in reportSolvedLayout(newFrames, isShown: isShown, tabID: tab.id) }
        .onChange(of: isShown) { _, nowShown in reportSolvedLayout(frames, isShown: nowShown, tabID: tab.id) }
        .onChange(of: activeTabID) { _, _ in reportSolvedLayout(frames, isShown: isShown, tabID: tab.id) }
    }

    /// Forwards the GLOBAL active tab's solved frames to `store.updateSolvedLayout` (a hidden tab, the
    /// other column's unfocused tab, or the static snapshot path never reports — the store must only ever
    /// hold the geometry keyboard focus ops act on).
    private func reportSolvedLayout(_ frames: [PaneID: CGRect], isShown: Bool, tabID: TabID) {
        guard isShown, tabID == activeTabID, !staticMirror, !frames.isEmpty else { return }
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
    static func isPaneFocused(_ paneID: PaneID, in tab: AislopdeskWorkspaceCore.Tab, activeTabID: TabID?) -> Bool {
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
                .animation(.easeOut(duration: 0.12), value: move.zone)
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
        if let edge = containerEdge(at: location, container: container, sourceRect: sourceRect) {
            return .dock(edge: edge)
        }
        // 2) Over a target leaf (not the source): centre → swap, edge band → re-split.
        guard let (target, rect) = leaf(at: location, in: leaves, excluding: source),
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
        return .resplit(target: target, edge: dominantEdge(u: u, v: v, band: band))
    }

    /// The first leaf (in solver DFS order) whose rect contains `location`, excluding the dragged `source`.
    /// Iterating the ORDERED leaves (not the unordered `frames` dict) keeps the resolved target deterministic
    /// if a min-clamped, over-subscribed layout ever overlaps two rects.
    private func leaf(
        at location: CGPoint,
        in leaves: [SplitTreeRenderModel.PlacedLeaf],
        excluding source: PaneID,
    ) -> (PaneID, CGRect)? {
        for placed in leaves where placed.id != source && placed.rect.contains(location) {
            return (placed.id, placed.rect)
        }
        return nil
    }

    /// The container outer edge whose gutter contains `location` (deepest wins; tie → a vertical left/right
    /// edge), or `nil` if the cursor is in no gutter. An edge the `sourceRect` already fully spans is skipped
    /// (docking there changes nothing).
    private func containerEdge(at location: CGPoint, container: CGRect, sourceRect: CGRect) -> PaneDropEdge? {
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
        for entry in distances where !sourceSpans(sourceRect, entry.edge, container) {
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
    private func sourceSpans(_ rect: CGRect, _ edge: PaneDropEdge, _ container: CGRect) -> Bool {
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
    private func dominantEdge(u: CGFloat, v: CGFloat, band: CGFloat) -> PaneDropEdge {
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
}
#endif
