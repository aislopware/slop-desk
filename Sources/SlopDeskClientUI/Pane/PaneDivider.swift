// PaneDivider — the resize handle between two split panes. A thin separator hairline drawn
// inside a comfortable hit band; a resize cursor on hover. Dragging resizes the panes LIVE — the layout
// updates every frame, like an AppKit `NSSplitView` divider — while the host grid-resize SEND is deferred
// until release (the shell brackets the drag with `setTerminalResizeSuspended`, so the server gets ONE resize
// event when the drag settles, not one per frame). Double-click evens out THIS seam only (never the whole tab).
//
// LIVE-RESIZE RULE: the drag sets the leading child's ABSOLUTE weight each frame — `handle.leadingWeight`
// captured at drag start, plus the cursor translation converted to weight (`Δpx · flexSum / parentSpan`).
// A ghost-seam preview with a separate commit-on-release step is unnecessary and would risk a "divider
// chases itself, seam barely travels" mismatch; two things keep it cursor-matched instead:
//   1. the gesture reads its translation in the STABLE `PaneMoveSpace.name` coordinate space (NOT the
//      divider's own frame, which slides out from under the cursor as the panes resize), so the translation
//      tracks the real cursor; and
//   2. it's ABSOLUTE-from-start (not an accumulated per-frame delta), so an over-drag into the min-weight
//      clamp HOLDS and resumes exactly when the cursor returns — no drift.
// The store clamps the weight at `SplitWeight.minWeight`, so the seam stops on the neighbour by itself: no
// ghost-seam preview and no travel clamp are needed (the real panes move + the resize scrim covers them).
//
// THE END-CLEANUP IS OWED ON TEARDOWN, NOT ONLY ON GESTURE END. `onResizeBegin` raises
// `setTerminalResizeSuspended(true)`, which is WORKSPACE-WIDE state on the store rather than anything this
// seam owns: every live terminal stops forwarding its grid to the host until something lowers it again.
// SwiftUI's `@GestureState` reset covers an end and a cancel, but it covers them through an `.onChange`
// observer that dies with the view — so a seam that is UNMOUNTED while the button is still down (a pane
// closed under the drag, the tab switched, the tab layer rebuilt) would leave the flag raised for the rest
// of the session and the host would never hear another grid resize. That wedges the whole workspace, not
// just this seam. `.onDisappear` is the SwiftUI spelling of the same safety net ``MacPaneDivider`` reaches
// through `viewDidMoveToWindow`, and both funnel into ONE release guarded by `startLead` so the drag that
// ends normally and then unmounts releases exactly once.
//
// Hit-test guardrail: the FAT transparent hit band gets `.contentShape(Rectangle())` over a
// thin visual hairline; SplitContainer applies `.position(...)` to this whole view, so the hit area travels
// WITH the handle. SYSTEM/DS colours only (the accent hairline is a drag affordance, not a hover state).

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI

struct PaneDivider: View {
    let handle: SplitTreeRenderModel.DividerHandle
    /// Drag start — wired to `store.setTerminalResizeSuspended(true)`, holding the host grid-resize for the
    /// whole drag ("update the layout live, defer the server event to drag-end").
    var onResizeBegin: () -> Void = {}
    /// Each frame — the new ABSOLUTE leading-child weight (store clamps it). Wired to
    /// `store.setDividerWeightLive`, which re-solves the layout WITHOUT reconciling / persisting per frame.
    var onResizeChange: (_ leadingWeight: Double) -> Void = { _ in }
    /// Drag end / cancel / TEARDOWN — wired to `store.setTerminalResizeSuspended(false)` (flush the settled
    /// grid to the host) + `store.commitDividerResize()` (reconcile + persist ONCE). Called at most ONCE per
    /// `onResizeBegin`, from whichever of the three arrives first (see ``releaseDrag()``); a seam that never
    /// began a drag never calls it at all.
    var onResizeEnd: () -> Void = {}
    /// Double-click → even out THIS seam (50/50, sum-preserving). Wired to `store.evenDividerTree` with
    /// this handle's `(splitID, childIndex)` — never the whole-tab `balanceActivePaneSplits` reset.
    var onReset: () -> Void = {}

    /// `true` for the duration of the gesture. SwiftUI auto-resets `@GestureState` on end/cancel/interrupt, so
    /// the end-cleanup (unsuspend + commit) can never be skipped by a CANCELLED drag. It says nothing about an
    /// UNMOUNTED one — the reset is observed through an `.onChange` that goes away with the view — which is
    /// why the release is also owed from `.onDisappear`; see the file header.
    @GestureState private var gestureActive = false
    /// The leading child's weight captured at drag start — the absolute anchor for the whole gesture, and the
    /// "a drag is in flight" flag that makes ``releaseDrag()`` idempotent. `nil` between drags; set on the
    /// first change, cleared by whichever release arrives first.
    @State private var startLead: Double?

    var body: some View {
        ZStack {
            // Transparent hit band (the full handle rect) — grabbable.
            Color.clear.contentShape(Rectangle())
            // The crisp resting hairline — accent + a touch thicker while actively dragging.
            hairlineShape(
                // The pane-seam line INSIDE the island: the profile's edge tone, one step off the
                // glass — the JetBrains-Islands internal divider, never a chrome-coloured gap.
                color: gestureActive ? Slate.State.accent : Slate.Terminal.edge,
                // Both thicknesses are the ladder's, and the resting one used to be a `private let
                // hairline: CGFloat = 1` on this struct — the same value `Slate.Metric.hairline`
                // already carried, spelled a second time one floor up. The hit band is the handle
                // rect either way; only the drawn line moves.
                thickness: gestureActive ? Slate.Metric.dividerHoverWidth : Slate.Metric.hairline,
            )
        }
        .frame(width: handle.rect.width, height: handle.rect.height)
        .panePointer(resizePointer)
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
        // Fires on end AND cancel (`gestureActive` resets either way) — the ordinary release, for a drag
        // whose seam is still on screen when the button comes up.
        .onChange(of: gestureActive) { _, active in
            if !active { releaseDrag() }
        }
        // THE TEARDOWN SAFETY NET, and the reason it is not redundant with the observer above: that
        // observer is part of this view, so an unmount mid-drag destroys it INSTEAD of firing it, and the
        // workspace-wide suspend flag `onResizeBegin` raised would stay raised for the rest of the session.
        // Every way this seam can vanish under a live drag ends here — `SplitContainer` mounts the whole
        // divider band under `if isActive`, so a tab switch removes it; `layout.dividers` loses this
        // handle's `key` when the pane on either side closes, so the `ForEach` row goes; and an evicted or
        // torn-out tab takes the entire `.id(tab.id)` layer, descendants included. SwiftUI runs
        // `.onDisappear` for all three, which is the same "removed from the tree" event AppKit reports to
        // ``MacPaneDivider`` as `window == nil`.
        //
        // A drag that ends normally and THEN unmounts is not double-released: the `.onChange` above already
        // cleared `startLead`, and ``releaseDrag()`` is a no-op without it. The reverse order is safe for
        // the same reason, so it does not matter which SwiftUI delivers first. It is also safe if SwiftUI
        // were ever to re-identify this seam mid-drag: the old view releases what it began instead of
        // stranding it, which is strictly better than the wedge, and cannot happen anyway while the
        // `ForEach` keys on the weight-independent ``SplitDividerHandle/key``.
        .onDisappear { releaseDrag() }
        .animation(Slate.Anim.dividerHover, value: gestureActive)
        // The live ratio readout (`62 · 38`) — MERIDIAN L3 status: present ONLY while the drag is
        // working, hard-cut on release (mounted AFTER the `.animation` above so it never fades).
        // Each frame's re-solve rebuilds `handle` with fresh pair weights, so the numbers track the
        // seam live; a degenerate pair (a `.fixed` side) yields nil ⇒ absent, never wrong.
        .overlay { if gestureActive { ratioReadout } }
    }

    /// The drag's end-cleanup, spelled ONCE because two different events owe it: the gesture ending or
    /// cancelling, and this view being torn out of the tree while the button is still down. `startLead` is
    /// both the anchor and the latch — set on the first drag frame, right after `onResizeBegin`, so it is
    /// exactly the "there is something to release" bit, and clearing it before the callback makes a second
    /// arrival a no-op. That also makes a release with no matching begin harmless, which is what a plain
    /// unmount at rest (every tab switch, every pane close) delivers: `onResizeEnd` unsuspends the whole
    /// workspace's terminals and stages a commit, so calling it on a seam that was never dragged would spend
    /// a reconcile per divider per tab switch and could lower a suspend a DIFFERENT drag is holding.
    ///
    /// The AppKit half's `endDrag()` is the same three lines against the same flag — the guarantee is
    /// shared, the mechanism is each framework's own.
    private func releaseDrag() {
        guard startLead != nil else { return }
        startLead = nil
        onResizeEnd()
    }

    /// The instrument-voice split percentages, centered on the seam: the answer to "am I at the ratio I
    /// was aiming for?" while the eye is already on the divider (feedback at the trigger — never a HUD
    /// elsewhere). `EmptyView` for a degenerate pair. Hit-transparent so the drag beneath is untouched.
    @ViewBuilder
    private var ratioReadout: some View {
        if let pct = handle.splitPercents {
            HStack(spacing: Slate.Metric.space1) {
                Text("\(pct.leading)")
                    .foregroundStyle(Slate.Text.primary)
                Text("·")
                    .foregroundStyle(Slate.Text.tertiary)
                Text("\(pct.trailing)")
                    .foregroundStyle(Slate.Text.primary)
            }
            .modifier(InstrumentChipShell(accessibility: "\(pct.leading) to \(pct.trailing) percent split"))
            .allowsHitTesting(false)
        }
    }

    /// This seam's reading of ``PaneCanvasMetrics/resizePointer(axis:toLeading:toTrailing:)`` — the
    /// truth-at-the-clamp rule, taken from the handle's own pair weights so the glyph can never
    /// disagree with the gesture's clamp.
    private var resizePointer: PanePointer {
        PaneCanvasMetrics.resizePointer(
            axis: handle.axis,
            toLeading: handle.canMoveTowardLeading,
            toTrailing: handle.canMoveTowardTrailing,
        )
    }

    /// The absolute leading weight for a cursor translation of `translation` points along the split axis:
    /// `startLead +` the translation converted to weight via
    /// ``SplitDividerHandle/weightDelta(pixelIncrement:)``
    /// (`Δpx · flexSum / parentSpan` — the inverse of a flex child's `extent = weight/flexSum·span`, and the
    /// same conversion the keyboard resize uses). It returns 0 for a zero/non-finite span, leaving `base`
    /// unchanged. Clamped by the handle so BOTH panes keep the solver's pixel floor
    /// (``SplitTreeRenderModel/DividerHandle/clampedLeadingWeight(_:)`` — the store's own clamp is
    /// weight-relative and let a wide parent squash a pane invisible); over-drags hold at the floor
    /// and resume when the cursor returns, exactly as with the store clamp.
    private func targetLeadingWeight(translation: CGFloat) -> Double {
        let base = startLead ?? handle.leadingWeight
        return handle.clampedLeadingWeight(base + handle.weightDelta(pixelIncrement: translation))
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
