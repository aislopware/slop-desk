#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit

// MARK: - ScrollPanForwarder (BUG-2 "pan stops at the pane edge")

/// A transparent AppKit view that forwards a trackpad/wheel scroll to the canvas pan
/// (``WorkspaceStore/scrollPan(by:)``). The pane's SwiftUI chrome — the resize-handle PERIMETER (the
/// pane "edge") and the header — is hit-OPAQUE (`.contentShape`), so a scroll over it is SWALLOWED: it
/// cannot fall through to the single background pan-catcher behind the panes, and the pan "stops at the
/// edge of the pane". Used as the resize-grip fill + a pane background, this makes every NON-content part
/// of a pane pan the canvas exactly like the empty background does. It overrides ONLY `scrollWheel`, so
/// SwiftUI's resize / move / tap gestures (which use `mouseDown`/`mouseDragged`) still work unobstructed —
/// the default `NSView` mouse handling propagates up to SwiftUI's recognizers untouched. Sign matches
/// ``CanvasView``'s `PanView` so panning over a pane feels identical to panning empty space.
struct ScrollPanForwarder: NSViewRepresentable {
    let store: WorkspaceStore
    func makeNSView(context: Context) -> NSView { ForwardingView(store: store) }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ForwardingView)?.store = store }

    final class ForwardingView: NSView {
        weak var store: WorkspaceStore?
        init(store: WorkspaceStore) { self.store = store; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
        override func scrollWheel(with event: NSEvent) {
            let dx: CGFloat, dy: CGFloat
            if event.hasPreciseScrollingDeltas { dx = event.scrollingDeltaX; dy = event.scrollingDeltaY }
            else { dx = event.scrollingDeltaX * 10; dy = event.scrollingDeltaY * 10 }
            store?.scrollPan(by: CGSize(width: -dx, height: -dy))   // natural-scroll, same sign as PanView
        }
    }
}
#endif

// MARK: - CanvasItemView (one positioned pane on the infinite plane)

/// Renders one ``CanvasItem`` (docs/30 §6.4): the proven ``PaneChromeView`` + ``PaneLeafView``
/// **verbatim**, plus the two canvas-only gestures — drag-to-move (on the header) and 8-anchor resize
/// (on edge/corner grips). The parent ``CanvasView`` positions this view at the item's canvas-space
/// frame (under one rigid camera `.offset`); this view only previews a live move/resize and commits
/// once on `.onEnded` (the `SplitContainer` commit-on-end discipline — no per-frame store mutation, no
/// `TIOCSWINSZ` storm).
///
/// ### Why the body keeps its click (docs/30 §6.5)
/// The move gesture is attached to the HEADER only (inside ``PaneChromeView``), and the resize gesture
/// only to the thin edge/corner grips — both plain `.gesture` (never `.highPriorityGesture`). The
/// terminal body has NO ancestor gesture, so libghostty's own `mouseDown` (selection / mouse reporting)
/// is never stolen; body focus comes from `onRequestFocus` (``wireFocusOnClick(for:)``, ported verbatim
/// from the old `PaneTreeView`), and on iOS from a `.simultaneousGesture(Tap)`.
struct CanvasItemView: View {
    let item: CanvasItem
    let store: WorkspaceStore
    /// The named coordinate space of the canvas plane (so a drag translation is the canvas-space delta,
    /// 1:1 since the camera is a pure translate).
    let coordSpace: String

    /// Non-nil ⇒ this pane is MAXIMIZED: render at this fixed size (the full viewport minus a small
    /// inset) instead of ``CanvasItem/frame``, and suppress the live move/resize offset. The parent
    /// ``CanvasView`` positions us at the camera-anchored viewport centre. Passing a SIZE (not swapping
    /// in a separate full-screen view) is what keeps the maximized pane at the SAME SwiftUI identity as
    /// its canvas tile, so libghostty's surface is merely RESIZED — never torn down + rebuilt. The old
    /// separate-subtree maximize rebuilt the surface, which replayed stale bytes (garbled glyphs) and
    /// crashed the app on repeated maximize/restore cycles.
    var displaySize: CGSize? = nil

    /// Live drag-to-move preview (rigid `.offset`; auto-resets on gesture end). The committed move
    /// lands via ``WorkspaceStore/movePane(_:by:)`` on `.onEnded`.
    @GestureState private var moveLive: CGSize = .zero
    /// Live resize preview — the previewed canvas-space frame, or `nil` when not resizing. Auto-resets
    /// on gesture end; the committed frame lands via ``WorkspaceStore/resizePane(_:to:)``.
    @GestureState private var resizeLive: CGRect?

    private var isFocused: Bool { store.isFocused(item.id) }

    var body: some View {
        let maximized = displaySize != nil
        // Maximized → fixed viewport size (parent centres us); otherwise the live-resize preview, else
        // the persisted frame.
        let shown = displaySize.map { CGRect(origin: .zero, size: $0) } ?? (resizeLive ?? item.frame)
        // Keep the ANCHORED edge pinned during a resize: the parent positions us at the original
        // frame's centre, so shift by the centre delta of the previewed frame (zero when not resizing),
        // plus the rigid move preview. A maximized pane can't be moved/resized → no live offset.
        let offsetX = maximized ? 0 : (shown.midX - item.frame.midX) + moveLive.width
        let offsetY = maximized ? 0 : (shown.midY - item.frame.midY) + moveLive.height

        return PaneChromeView(
            id: item.id,
            spec: item.spec,
            handle: store.handle(for: item.id),
            isFocused: isFocused,
            isZoomed: store.workspace.maximizedPane == item.id,
            store: store,
            moveHandleGesture: AnyGesture(moveGesture.map { _ in () })
        ) {
            PaneLeafView(
                handle: store.handle(for: item.id),
                spec: item.spec,
                isFocused: isFocused,
                focusCoordinator: store.focusCoordinator,
                store: store
            )
        }
        .frame(width: shown.width, height: shown.height)   // resize previews live (intended reflow)
        #if os(macOS)
        // BUG-2: catch a scroll over the pane CHROME (header / focus-ring border / padding) and pan the
        // canvas, instead of the opaque chrome swallowing it. Behind the content, so the video/terminal
        // NSView (in front) still gets — and forwards — its own scroll. The resize-grip PERIMETER is the
        // OVERLAY in front of this, so its grips forward via `gripBase` (below); together they make the
        // whole pane pan like empty space.
        .background { ScrollPanForwarder(store: store) }
        #endif
        .overlay { resizeHandles }
        .offset(x: offsetX, y: offsetY)
        // NOTE: the dragged pane floats above its siblings via the OUTER `.zIndex` in CanvasView (sibling
        // stacking lives there) — driven by `store.isFocused`, which the move/resize gestures set at drag
        // START (`raiseOnGestureStart`). A `.zIndex` here would be inert (no siblings at this level).
        .onAppear { wireFocusOnClick(for: item.id) }
        #if os(iOS)
        // Absorb a touch on the body → focus this pane AND block the background pan from firing under
        // it (the bottom Color.clear pan layer never sees a touch that lands on a pane).
        .simultaneousGesture(TapGesture().onEnded { store.focus(item.id) })
        #endif
    }

    // MARK: Gestures

    /// Drag-to-move: live rigid preview via `@GestureState`, ONE commit on `.onEnded` (which also
    /// raises + focuses). The translation is read in the canvas coordinate space (1:1 → it IS the
    /// canvas delta). Attached to the header only (passed into ``PaneChromeView``).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
            .updating($moveLive) { value, state, _ in state = value.translation }
            .onChanged { _ in raiseOnGestureStart() }
            .onEnded { value in store.movePane(item.id, by: value.translation) }
    }

    /// Floats this pane to the top the instant a move/resize drag begins (so it is never occluded by a
    /// higher-z sibling mid-gesture). Raising focuses it → CanvasView's outer `.zIndex` lifts it. The
    /// `!isFocused` guard makes it fire at most once per gesture (after the first raise it is focused),
    /// so there is no per-frame store churn; the committed z/frame still land on `.onEnded`.
    private func raiseOnGestureStart() {
        if !store.isFocused(item.id) { store.raisePane(item.id) }
    }

    /// 8-anchor resize for `anchor`: live `.frame` preview (deliberately reflows for native feel), ONE
    /// commit on `.onEnded`. The downstream `sendResize` dedup + host resize-debounce absorb the
    /// intermediate sizes, so only the final frame is persisted.
    private func resizeGesture(_ anchor: ResizeAnchor) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(coordSpace))
            .updating($resizeLive) { value, state, _ in
                state = CanvasGeometry.resizing(item.frame, anchor: anchor, by: value.translation, minSize: Canvas.minItemSize)
            }
            .onChanged { _ in raiseOnGestureStart() }
            .onEnded { value in
                let f = CanvasGeometry.resizing(item.frame, anchor: anchor, by: value.translation, minSize: Canvas.minItemSize)
                store.resizePane(item.id, to: f)
            }
    }

    // MARK: Resize handles

    /// Thin invisible grips at the 4 corners + 4 edges. Edges are laid out first so the corners (added
    /// last) win hit-testing where they overlap. Only the grip area is interactive (the gesture is on
    /// the small grip, not the full-bleed positioning frame), so the terminal body stays clickable.
    private var resizeHandles: some View {
        ZStack {
            edgeHandle(.top, alignment: .top)
            edgeHandle(.bottom, alignment: .bottom)
            edgeHandle(.left, alignment: .leading)
            edgeHandle(.right, alignment: .trailing)
            cornerHandle(.topLeft, alignment: .topLeading)
            cornerHandle(.topRight, alignment: .topTrailing)
            cornerHandle(.bottomLeft, alignment: .bottomLeading)
            cornerHandle(.bottomRight, alignment: .bottomTrailing)
        }
        .allowsHitTesting(store.workspace.maximizedPane == nil)   // no resize while maximized
    }

    private static let cornerGrip: CGFloat = 16
    private static let edgeThickness: CGFloat = 8

    /// The invisible fill of a resize grip. On macOS it is a ``ScrollPanForwarder`` so a scroll over the
    /// grip — the pane PERIMETER, i.e. the "cạnh của pane" — pans the canvas instead of being swallowed
    /// (BUG-2); the SwiftUI resize `.gesture` still fires because the forwarder overrides only
    /// `scrollWheel`. On iOS (no scroll wheel) it is a plain clear rectangle.
    @ViewBuilder private var gripBase: some View {
        #if os(macOS)
        ScrollPanForwarder(store: store)
        #else
        Rectangle().fill(Color.clear)
        #endif
    }

    private func cornerHandle(_ anchor: ResizeAnchor, alignment: Alignment) -> some View {
        gripBase
            .frame(width: Self.cornerGrip, height: Self.cornerGrip)
            .contentShape(Rectangle())
            .gesture(resizeGesture(anchor))
            #if os(macOS)
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func edgeHandle(_ anchor: ResizeAnchor, alignment: Alignment) -> some View {
        let horizontal = (anchor == .top || anchor == .bottom)
        gripBase
            .frame(
                width: horizontal ? nil : Self.edgeThickness,
                height: horizontal ? Self.edgeThickness : nil
            )
            .frame(maxWidth: horizontal ? .infinity : nil, maxHeight: horizontal ? nil : .infinity)
            .contentShape(Rectangle())
            .gesture(resizeGesture(anchor))
            #if os(macOS)
            .onHover { inside in
                if inside { (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() }
                else { NSCursor.pop() }
            }
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    // MARK: Focus wiring (ported verbatim from the old PaneTreeView.wireFocusOnClick)

    /// Points the leaf's terminal renderer at `store.focus(id)` so a click on the terminal BODY focuses
    /// the pane (libghostty's `mouseDown` consumes the tap before any SwiftUI gesture). A faked /
    /// `.remoteGUI` handle has no `terminalModel`, so this is a no-op there. Captures only `store` + `id`
    /// (both stable), so the closure stays correct across reshapes.
    private func wireFocusOnClick(for id: PaneID) {
        guard let live = store.handle(for: id) as? LivePaneSession,
              let model = live.terminalModel else { return }
        model.onRequestFocus = { [weak store] in store?.focus(id) }
        // "Only the active pane swallows scroll": a scroll on a NON-focused terminal pans the canvas
        // instead of scrolling its scrollback (the renderer calls this only when `!isFocusedPane`).
        model.onCanvasScroll = { [weak store] delta in
            // Debounced live accumulator (not a per-step commitCamera) so panning over a background
            // terminal is smooth and never thrashes the canvas re-render cascade (BUG-2/BUG-1 fix).
            store?.scrollPan(by: delta)
        }
    }
}
#endif
