#if canImport(SwiftUI)
import SwiftUI

// MARK: - CanvasView (the pannable infinite plane)

/// The regular-width workspace surface (docs/31): the single infinite ``Canvas`` rendered under a
/// single rigid camera `.offset` (a pure translate — NEVER a scale, so every libghostty surface keeps
/// `bounds == frame == 1:1` and its points-with-y-flip mouse mapping is unchanged). It:
/// - mounts the kind-aware visible items (terminals never culled; off-viewport video culled),
/// - positions each at its canvas-space frame and applies the camera as one `.offset`,
/// - draws a labeled bounding box behind each ``PaneGroup``'s panes (the Figma-style group frame),
/// - pans via a background drag (both platforms) and trackpad scroll/wheel (macOS),
/// - renders the maximized pane full-viewport when one is set (the old zoom branch),
/// - reports the solved layout (geometric focus), the viewport size, and viewport membership
///   (the video-cap "on screen" signal) back to the store.
///
/// Replaces the recursive `PaneTreeView` and the per-tab canvas. The compact (phone) projection stays
/// the carousel.
struct CanvasView: View {
    let store: WorkspaceStore

    /// Screen-space additive offset applied to the content during a LIVE background pan (before commit).
    /// View `@State` so the per-frame pan never touches the store (the `@GestureState` discipline);
    /// only `.onEnded` / a scroll step commits via ``WorkspaceStore/commitCamera(_:)``.
    @State private var livePan: CGSize = .zero

    private static let coordSpace = "canvas"
    /// Outward padding of a group's bounding box around its panes (so the frame doesn't touch the panes).
    private static let groupPadding: CGFloat = 16

    private var canvas: Canvas { store.workspace.canvas }

    var body: some View {
        GeometryReader { geo in
            let camera = canvas.camera
            // The maximized pane, but ONLY if it is actually on the canvas (a dangling id falls back to
            // the normal canvas — load-repair already clears it; this is belt-and-suspenders).
            let maxID: PaneID? = store.workspace.maximizedPane.flatMap { canvas.contains($0) ? $0 : nil }
            ZStack(alignment: .topLeading) {
                // Background pan/scroll catcher — only when NOT maximized (a maximized pane can't be panned).
                if maxID == nil {
                    backgroundPanLayer(camera: camera)
                }
                // ONE always-mounted content path: maximize is per-item GEOMETRY (the maximized pane is
                // sized to the viewport, the others hidden-but-mounted), NOT a separate full-screen
                // subtree. This keeps every pane at its exact SwiftUI identity across maximize/restore, so
                // libghostty surfaces are only RESIZED — never torn down + rebuilt (the prior subtree-swap
                // rebuilt them, replaying stale bytes → garbled glyphs, then crashing on repeated cycles).
                canvasContent(camera: camera, viewport: geo.size, maxID: maxID)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .coordinateSpace(.named(Self.coordSpace))
            .overlay(alignment: .bottomTrailing) { recenterButton(viewport: geo.size) }
            .onAppear { report(geo.size, camera: canvas.camera) }
            .onChange(of: geo.size) { _, s in report(s, camera: canvas.camera) }
            .onChange(of: canvas) { _, _ in report(geo.size, camera: canvas.camera) }
            // Maximize is a workspace flag (not on `canvas`), so `.onChange(of: canvas)` does NOT fire —
            // recompute membership here so entering/leaving maximize correctly reports exactly the
            // maximized pane (or the full canvas) and the now-hidden video panes free their slots.
            .onChange(of: store.workspace.maximizedPane) { _, _ in
                // A maximize toggle mid-background-drag dismantles the pan catcher before its mouseUp can
                // clear `livePan` — drop any stale pan so it never offsets the camera-anchored maximized
                // pane off-centre (a `@State`, unlike `moveLive`, it does not auto-reset).
                livePan = .zero
                report(geo.size, camera: canvas.camera)
            }
            // When the canvas view disappears (a regular→compact projection flip), clear membership so
            // the compact carousel falls back to `isPaneOnCanvas` instead of inheriting a stale set.
            .onDisappear { store.clearViewportMembership() }
        }
        .background(.background)
    }

    // MARK: Content

    private func canvasContent(camera: CanvasCamera, viewport: CGSize, maxID: PaneID?) -> some View {
        let visible = CanvasGeometry.visibleItems(canvas.items, camera: camera, viewport: viewport,
                                                  focused: store.workspace.focusedPane)
        // Canvas-space rect a maximized pane occupies: viewport-sized (minus a small inset for a thin
        // border), anchored at the camera origin so the single camera `.offset` below lands it exactly
        // on the viewport.
        let maxInset: CGFloat = 4
        let maxSize = CGSize(width: max(1, viewport.width - maxInset * 2),
                             height: max(1, viewport.height - maxInset * 2))
        return ZStack(alignment: .topLeading) {
            // Group bounding boxes, BEHIND every pane (decorative; never intercepts clicks/pan). Hidden
            // while a pane is maximized — the maximized pane covers the whole plane.
            if maxID == nil {
                groupLayer
                    .zIndex(-1)
                    .allowsHitTesting(false)
            }
            ForEach(visible.sorted { $0.z < $1.z }) { item in
                let isMax = (item.id == maxID)
                // Maximized pane: anchored to the camera so the rigid `.offset` below lands it on the
                // viewport centre. Others: their canvas-space centre (CONSTANT during a pan).
                let pos = isMax
                    ? CGPoint(x: camera.origin.x + viewport.width / 2, y: camera.origin.y + viewport.height / 2)
                    : CGPoint(x: item.frame.midX, y: item.frame.midY)
                CanvasItemView(item: item, store: store, coordSpace: Self.coordSpace,
                               displaySize: isMax ? maxSize : nil)
                    .position(x: pos.x, y: pos.y)
                    // Maximized pane on top of everything; otherwise the focused pane renders above the
                    // rest (the pane you are interacting with is on top; the dragged pane is usually the
                    // focused one and is raised on commit).
                    .zIndex(isMax ? 2_000_000 : (store.isFocused(item.id) ? 1_000_000 : Double(item.z)))
                    // While maximized the OTHER panes stay MOUNTED (so their surfaces survive restore with
                    // no rebuild → no garbled re-render) but are hidden + non-interactive behind it.
                    .opacity(maxID != nil && !isMax ? 0 : 1)
                    .allowsHitTesting(maxID == nil || isMax)
                    .id(item.id)                                         // LOAD-BEARING (.id(PaneID))
            }
        }
        // Explicit size so `.position` lays out absolutely; off-frame items are NOT clipped here (the
        // outer GeometryReader `.clipped()` clips the viewport), so panned-in panes appear.
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        // The ONLY camera application (rigid). `livePan` = a live background DRAG (view @State); the store's
        // `liveCameraOffset` = a live trackpad/wheel SCROLL pan that has not yet committed (BUG-2/BUG-1
        // freeze fix) — both are visual-only, folded into `camera.origin` on commit with no jump.
        .offset(x: -camera.origin.x + livePan.width + store.liveCameraOffset.width,
                y: -camera.origin.y + livePan.height + store.liveCameraOffset.height)
    }

    // MARK: Group bounding boxes (the Figma-style labeled frame around each group's panes)

    private var groupLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.workspace.groups) { group in
                if let box = canvas.groupBoundingBox(group.id) {
                    let padded = box.insetBy(dx: -Self.groupPadding, dy: -Self.groupPadding)
                    CanvasGroupBox(name: group.name)
                        .frame(width: padded.width, height: padded.height)
                        .position(x: padded.midX, y: padded.midY)   // canvas-space; rides the same camera offset
                }
            }
        }
    }

    // MARK: Background pan

    @ViewBuilder
    private func backgroundPanLayer(camera: CanvasCamera) -> some View {
        #if os(macOS)
        // macOS: a bottom NSView catches scroll-wheel / trackpad-scroll AND empty-background drag to pan
        // (a SwiftUI DragGesture cannot see scroll, and an overlay returning nil from hitTest would get
        // no scroll either — so the catcher sits BEHIND the panes; panes above intercept their own
        // region, and scroll over a terminal still reaches libghostty's scrollback).
        CanvasBackingView(
            onLiveDrag: { livePan = $0 },
            onCommitDrag: { translation in commitPan(translation); livePan = .zero },
            // Scroll-pan goes through the debounced live accumulator (NOT a per-step commitCamera) so a pan
            // no longer thrashes the canvas re-render + report() cascade that froze the video/cursor.
            onScroll: { delta in store.scrollPan(by: delta) }
        )
        #else
        // iOS: one-finger drag on the empty background pans (a touch that starts on a pane is absorbed by
        // that pane's `.simultaneousGesture(Tap)`, so the background never sees it).
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.coordSpace))
                    .onChanged { v in livePan = v.translation }
                    .onEnded { v in commitPan(v.translation); livePan = .zero }
            )
        #endif
    }

    /// Commits a finished background drag: the camera moves OPPOSITE the drag (grab-the-canvas feel), so
    /// the steady offset after commit equals the live offset (no jump).
    private func commitPan(_ translation: CGSize) {
        store.commitCamera(canvas.camera.translated(by: CGSize(width: -translation.width, height: -translation.height)))
    }

    // MARK: Recenter affordance

    @ViewBuilder
    private func recenterButton(viewport: CGSize) -> some View {
        if store.workspace.maximizedPane == nil, canvas.needsRecenter(viewport: viewport), !canvas.items.isEmpty {
            Button {
                store.centerOnAll()
            } label: {
                Label("Recenter", systemImage: "scope")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(16)
            .help("Pan back to your panes")
            .transition(.opacity)
        }
    }

    // MARK: Reporting (geometric focus + viewport + video-cap membership)

    private func report(_ size: CGSize, camera: CanvasCamera) {
        guard size.width > 0, size.height > 0 else { return }
        store.updateViewport(size)
        if let maxID = store.workspace.maximizedPane, canvas.contains(maxID) {
            // Maximize: exactly ONE pane is visible (the others stay MOUNTED but `.opacity(0)` so their
            // surfaces survive restore) → membership is just that pane, so every hidden video pane's
            // `isPaneVisible` flips false and frees its slot. Geometric focus sees the single full pane.
            store.updateViewportMembership([maxID])
            store.updateSolvedLayout(SolvedLayout(frames: [maxID: CGRect(origin: .zero, size: size)]))
        } else {
            store.updateViewportMembership(CanvasGeometry.viewportMembers(canvas.items, camera: camera, viewport: size))
            store.updateSolvedLayout(canvas.solvedLayout())   // canvas-space; FocusResolver consumes unchanged
        }
    }
}

// MARK: - CanvasGroupBox (the labeled frame drawn around a group's panes)

/// A decorative rounded rectangle with a name chip at its top-leading corner — the Figma-style group
/// frame drawn behind a ``PaneGroup``'s panes (docs/31). Purely visual: it sizes to the padded group
/// bounding box the parent computes and never intercepts hit-testing (the parent sets
/// `.allowsHitTesting(false)`), so panes and the background pan stay fully interactive through it.
private struct CanvasGroupBox: View {
    let name: String

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
            )
            .overlay(alignment: .topLeading) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
                    .padding(.leading, 10)
                    .padding(.top, -12)   // straddle the top stroke, like a fieldset legend
            }
    }
}

// MARK: - CanvasBackingView (macOS scroll + background-drag pan)

#if os(macOS)
import AppKit

/// The macOS background pan surface: a bottom NSView that converts trackpad/wheel scroll AND an
/// empty-background mouse drag into camera pans (docs/30 §6.3). It sits BEHIND the panes so a click /
/// scroll over a pane reaches the pane (libghostty mouseDown + terminal scrollback), and only
/// empty-background events reach it. The `WindowWidthReader` drop-to-AppKit idiom.
private struct CanvasBackingView: NSViewRepresentable {
    /// Called repeatedly during a background drag with the running translation (screen-space).
    let onLiveDrag: (CGSize) -> Void
    /// Called once on mouse-up with the final translation.
    let onCommitDrag: (CGSize) -> Void
    /// Called per scroll step with the camera delta to apply (already sign-adjusted for natural scroll).
    let onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        PanView(onLiveDrag: onLiveDrag, onCommitDrag: onCommitDrag, onScroll: onScroll)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? PanView else { return }
        v.onLiveDrag = onLiveDrag
        v.onCommitDrag = onCommitDrag
        v.onScroll = onScroll
    }

    final class PanView: NSView {
        var onLiveDrag: (CGSize) -> Void
        var onCommitDrag: (CGSize) -> Void
        var onScroll: (CGSize) -> Void
        private var dragStart: NSPoint?

        init(onLiveDrag: @escaping (CGSize) -> Void,
             onCommitDrag: @escaping (CGSize) -> Void,
             onScroll: @escaping (CGSize) -> Void) {
            self.onLiveDrag = onLiveDrag
            self.onCommitDrag = onCommitDrag
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        // Bottom layer: receives only events not consumed by a pane above it.
        override func scrollWheel(with event: NSEvent) {
            let dx: CGFloat, dy: CGFloat
            if event.hasPreciseScrollingDeltas {
                dx = event.scrollingDeltaX; dy = event.scrollingDeltaY
            } else {
                dx = event.scrollingDeltaX * 10; dy = event.scrollingDeltaY * 10
            }
            // Natural scroll: the content follows the fingers, so the camera moves opposite the scroll.
            onScroll(CGSize(width: -dx, height: -dy))
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = convert(event.locationInWindow, from: nil)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = convert(event.locationInWindow, from: nil)
            // AppKit y grows UP; SwiftUI / canvas y grows DOWN → flip dy so a drag feels natural.
            onLiveDrag(CGSize(width: p.x - start.x, height: -(p.y - start.y)))
        }
        override func mouseUp(with event: NSEvent) {
            guard let start = dragStart else { return }
            let p = convert(event.locationInWindow, from: nil)
            onCommitDrag(CGSize(width: p.x - start.x, height: -(p.y - start.y)))
            dragStart = nil
        }
    }
}
#endif
#endif
