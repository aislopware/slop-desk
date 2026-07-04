// PaneDivider — the resize handle between two split panes (REBUILD-V2, L2). A thin separator hairline drawn
// inside a comfortable hit band; a resize cursor on hover. Dragging resizes the panes LIVE — the layout
// updates every frame, like an AppKit `NSSplitView` divider — while the host grid-resize SEND is deferred
// until release (the shell brackets the drag with `setTerminalResizeSuspended`, so the server gets ONE resize
// event when the drag settles, not one per frame). Double-click evens out THIS seam only (never the whole tab).
//
// LIVE-RESIZE RULE (why this no longer needs the old ghost-seam / commit-on-release dance): the drag sets the
// leading child's ABSOLUTE weight each frame — `handle.leadingWeight` captured at drag start, plus the cursor
// translation converted to weight (`Δpx · flexSum / parentSpan`). Two things keep it cursor-matched instead
// of the old "divider chases itself, seam barely travels" bug:
//   1. the gesture reads its translation in the STABLE `PaneMoveSpace.name` coordinate space (NOT the
//      divider's own frame, which slides out from under the cursor as the panes resize), so the translation
//      tracks the real cursor; and
//   2. it's ABSOLUTE-from-start (not an accumulated per-frame delta), so an over-drag into the min-weight
//      clamp HOLDS and resumes exactly when the cursor returns — no drift.
// The store clamps the weight at `SplitWeight.minWeight`, so the seam stops on the neighbour by itself: no
// ghost-seam preview and no travel clamp are needed (the real panes move + the resize scrim covers them).
//
// Hit-test guardrail (repo memory): the FAT transparent hit band gets `.contentShape(Rectangle())` over a
// thin visual hairline; SplitContainer applies `.position(...)` to this whole view, so the hit area travels
// WITH the handle. SYSTEM/DS colours only (the accent hairline is a drag affordance, not a hover state).

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct PaneDivider: View {
    let handle: SplitTreeRenderModel.DividerHandle
    /// Drag start — wired to `store.setTerminalResizeSuspended(true)`, holding the host grid-resize for the
    /// whole drag ("update the layout live, defer the server event to drag-end").
    var onResizeBegin: () -> Void = {}
    /// Each frame — the new ABSOLUTE leading-child weight (store clamps it). Wired to
    /// `store.setDividerWeightLive`, which re-solves the layout WITHOUT reconciling / persisting per frame.
    var onResizeChange: (_ leadingWeight: Double) -> Void = { _ in }
    /// Drag end / cancel — wired to `store.setTerminalResizeSuspended(false)` (flush the settled grid to the
    /// host) + `store.commitDividerResize()` (reconcile + persist ONCE).
    var onResizeEnd: () -> Void = {}
    /// Double-click → even out THIS seam (50/50, sum-preserving). Wired to `store.evenDividerTree` with
    /// this handle's `(splitID, childIndex)` — never the whole-tab `balanceActivePaneSplits` reset.
    var onReset: () -> Void = {}

    /// The drawn hairline thickness (the hit band is the handle rect; the line is thinner + crisp).
    private let hairline: CGFloat = 1

    /// `true` for the duration of the gesture. SwiftUI auto-resets `@GestureState` on end/cancel/interrupt, so
    /// the end-cleanup (unsuspend + commit) can NEVER be skipped by a cancelled drag.
    @GestureState private var gestureActive = false
    /// The leading child's weight captured at drag start — the absolute anchor for the whole gesture. `nil`
    /// between drags; set on the first change, cleared on end.
    @State private var startLead: Double?

    var body: some View {
        ZStack {
            // Transparent hit band (the full handle rect) — grabbable.
            Color.clear.contentShape(Rectangle())
            // The crisp resting hairline — accent + a touch thicker while actively dragging.
            hairlineShape(
                color: gestureActive ? Slate.State.accent : NativePaneColor.separator,
                thickness: gestureActive ? Slate.Metric.dividerHoverWidth : hairline,
            )
        }
        .frame(width: handle.rect.width, height: handle.rect.height)
        #if os(macOS)
            .pointerStyle(handle.axis == .horizontal ? .columnResize : .rowResize)
        #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(PaneMoveSpace.name))
                    .updating($gestureActive) { _, state, _ in state = true }
                    .onChanged { value in
                        if startLead == nil {
                            startLead = handle.leadingWeight
                            onResizeBegin()
                        }
                        let translation = handle.axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        onResizeChange(targetLeadingWeight(translation: translation))
                    },
            )
            .onTapGesture(count: 2) { onReset() }
            // Fires on end AND cancel (`gestureActive` resets either way). Clean up exactly once.
            .onChange(of: gestureActive) { _, active in
                if !active, startLead != nil {
                    startLead = nil
                    onResizeEnd()
                }
            }
            .animation(Slate.Anim.dividerHover, value: gestureActive)
    }

    /// The absolute leading weight for a cursor translation of `translation` points along the split axis:
    /// `startLead +` the translation converted to weight via ``PaneMath/weightDelta(pixelIncrement:axisSpan:flexSum:)``
    /// (`Δpx · flexSum / parentSpan` — the inverse of a flex child's `extent = weight/flexSum·span`, and the
    /// same conversion the keyboard resize uses). It returns 0 for a zero/non-finite span, leaving `base`
    /// unchanged. The store clamps the result at the min-weight floor.
    private func targetLeadingWeight(translation: CGFloat) -> Double {
        let base = startLead ?? handle.leadingWeight
        return base + PaneMath.weightDelta(
            pixelIncrement: translation, axisSpan: handle.parentSpan, flexSum: handle.flexSum,
        )
    }

    @ViewBuilder
    private func hairlineShape(color: Color, thickness: CGFloat) -> some View {
        if handle.axis == .horizontal {
            Rectangle().fill(color).frame(width: thickness)
        } else {
            Rectangle().fill(color).frame(height: thickness)
        }
    }
}
#endif
