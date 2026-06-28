// SplitContainer — renders the active tab's pane tree (REBUILD-V2, L2). The IDENTITY-PRESERVING compositor.
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
// double-click → `store.balanceActivePaneSplits` (even reset). SYSTEM colours only.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct SplitContainer: View {
    let store: WorkspaceStore
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// Live pane-move drag (otty grab-handle). View-local: the store is untouched until release, so the
    /// terminal-grid / remote-window redraw fires once on commit, not per drag frame.
    @State private var move: PaneMoveDrag?

    private var tab: AislopdeskWorkspaceCore.Tab? { store.tree.activeSession?.activeTab }

    /// The active tab's focused pane (drives the focus ring / renderer first-responder).
    private var focusedPane: PaneID? { tab?.activePane }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            content(in: bounds)
        }
        .background(NativePaneColor.window)
    }

    @ViewBuilder
    private func content(in bounds: CGRect) -> some View {
        if let tab {
            // E21 WI-6: feed the FLOATING overlay layer. The store's `floatingPanePairs(for:)` reads
            // `tab.floatingPanes` × each spec's persisted `floatingFrame`; the render model clamps them into
            // `bounds` and emits `floatingLeaves` (z-ordered, last = topmost), which `floatingLayer` draws as
            // `FloatingPaneCard`s topmost in this ZStack. `floatingLeaves` is empty for a zoomed / float-less
            // tab, so the non-floating path is byte-identical to before.
            let layout = SplitTreeRenderModel.layout(for: tab, in: bounds, floating: store.floatingPanePairs(for: tab))
            let frames = Dictionary(layout.leaves.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
            ZStack(alignment: .topLeading) {
                ForEach(layout.leaves, id: \.id) { leaf in
                    PaneContainer(
                        store: store,
                        paneID: leaf.id,
                        isFocused: leaf.id == focusedPane,
                        // The pane's laid-out size IS the generic resize signal (any source) the scrim keys off.
                        size: leaf.rect.size,
                        staticMirror: staticMirror,
                    )
                    .id(leaf.id) // identity hazard: never reuse a surface across panes
                    .frame(width: leaf.rect.width, height: leaf.rect.height)
                    .position(x: leaf.rect.midX, y: leaf.rect.midY)
                }
                ForEach(layout.dividers, id: \.key) { handle in
                    dividerView(handle)
                }
                // otty grab-handles + the live drag overlay (extracted to keep this ZStack type-checkable).
                moveLayer(leaves: layout.leaves, frames: frames, container: bounds)
                // FLOATING cards last → topmost over the tiled panes, dividers, and the move overlay.
                floatingLayer(layout.floatingLeaves, container: bounds)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .coordinateSpace(name: PaneMoveSpace.name)
            // Report the TRUE float viewport (the full container bounds) so the store's commit-clamp shares
            // one coordinate space with the render model's place-clamp (no edge discrepancy). View-only — never
            // reconciles. Skipped on the static snapshot path.
            .onAppear { if !staticMirror { store.updateFloatingBounds(bounds) } }
            .onChange(of: bounds) { _, newBounds in if !staticMirror { store.updateFloatingBounds(newBounds) } }
        } else {
            Color.clear
        }
    }

    /// The floating overlay layer (E21 WI-6): one ``FloatingPaneCard`` per floating leaf, in z-order (the
    /// render model emits them last = topmost). Extracted to keep the compositor ZStack type-checkable, like
    /// ``moveLayer(leaves:frames:container:)``. Each card is keyed `.id(PaneID)` so its hosted surface is never
    /// reconstructed across panes; the card itself bumps its z-order while a grab/resize drag is in flight.
    private func floatingLayer(_ floats: [SplitTreeRenderModel.PlacedLeaf], container: CGRect) -> some View {
        ForEach(floats, id: \.id) { leaf in
            FloatingPaneCard(
                store: store,
                paneID: leaf.id,
                frame: leaf.rect,
                isFocused: leaf.id == focusedPane,
                containerBounds: container,
                staticMirror: staticMirror,
            )
            .id(leaf.id)
        }
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
            onReset: { store.balanceActivePaneSplits() },
        )
        .position(x: handle.rect.midX, y: handle.rect.midY)
    }

    /// The otty move affordance: a top grab handle per leaf (≥2 leaves only) plus the live drag overlay.
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
                .animation(Otty.Anim.smallFade, value: move.zone)
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
