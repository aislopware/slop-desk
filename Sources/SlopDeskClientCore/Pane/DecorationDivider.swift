// DecorationDivider — what a resize seam is WIRED to, and where its ratio chip sets its three runs.
//
// `MacPaneDivider` and `PaneDividerView` are two gestures over one seam: a mouse-down with a
// one-point slop against a `UIPanGestureRecognizer` with UIKit's own hysteresis, a pushed `NSCursor`
// against nothing at all. Those are real differences and they stay up there. What was typed twice and
// is not a difference:
//
//   * the FOUR callbacks the canvas wires each seam to. Four `var`s, four `@escaping` parameters and
//     four assignments in each shell — twelve identical lines apiece, and the kind that drift
//     silently, since a shell that grew a fifth gesture would grow a fifth closure nobody compares.
//   * the ratio chip's LAYOUT: three runs on one baseline, `62 · 38`, with the dot spaced off each
//     number by the same rung on both sides and the pair inset from the chip's edges. That is an
//     arrangement, not a spelling — Auto Layout is one API on both platforms — and two anchor blocks
//     can disagree by a rung with nothing going red.
//
// `no-cross-target-clone` counted the first as two windows (the stored pair and the initialiser) and
// the second as one (docs/56 §3, docs/62 stage I).
//
// ⚠️ WHAT DID NOT COME DOWN, and it is the interesting half. `handle`'s `didSet` guard, the readout's
// hide-before-you-cut ORDER and the field-by-field `percents` comparison are all pinned by
// `macui_memos` M9 against the Mac file, because each one is a MEASUREMENT (three uncached CoreText
// builds per hidden seam per frame) rather than an arrangement. A memo that moved would still be one
// implementation, but the rule that proves it is still there reads the renderer — so the memo stays
// beside the thing it memoizes, and what descends is the wiring and the geometry around it.

#if os(macOS)
import AppKit
#else
import UIKit
#endif

import SlopDeskSlate
import SlopDeskWorkspaceCore

/// The four things a resize seam can report, in one value.
///
/// A struct rather than four parameters, and for `GuiLeafChromeLayout.Overlays`' reason turned around:
/// there the labels stop six same-typed views being swapped silently, here they stop four same-shaped
/// closures being. `onResizeEnd` and `onReset` have identical types and opposite meanings — flush the
/// grid and commit, against even this seam out — so a transposition would compile and would commit a
/// resize every time somebody double-clicked.
///
/// Every arm defaults to a no-op, because a seam is legitimately un-wired in a test and in a preview:
/// what it draws is the handle's, and the handle is a value.
package struct DecorationDividerActions {
    /// Drag start — wired to `store.setTerminalResizeSuspended(true)`, holding the host grid-resize
    /// for the whole drag ("update the layout live, defer the server event to drag-end").
    package var onResizeBegin: () -> Void
    /// Each frame — the new ABSOLUTE leading-child weight (already clamped). Wired to
    /// `store.setDividerWeightLive`, which re-solves the layout WITHOUT reconciling / persisting.
    package var onResizeChange: (_ leadingWeight: Double) -> Void
    /// Drag end / interruption — wired to `store.setTerminalResizeSuspended(false)` (flush the settled
    /// grid to the host) + `store.commitDividerResize()` (reconcile + persist ONCE). Called at most
    /// ONCE per ``onResizeBegin``.
    package var onResizeEnd: () -> Void
    /// Double-click / double-tap → even out THIS seam (50/50, sum-preserving). Wired to
    /// `store.evenDividerTree` with this handle's `(splitID, childIndex)` — never the whole-tab
    /// `balanceActivePaneSplits`.
    package var onReset: () -> Void

    package init(
        onResizeBegin: @escaping () -> Void = {},
        onResizeChange: @escaping (Double) -> Void = { _ in },
        onResizeEnd: @escaping () -> Void = {},
        onReset: @escaping () -> Void = {},
    ) {
        self.onResizeBegin = onResizeBegin
        self.onResizeChange = onResizeChange
        self.onResizeEnd = onResizeEnd
        self.onReset = onReset
    }
}

/// The live `62 · 38` chip's three runs, placed once.
@MainActor
package enum DecorationRatioReadout {
    /// Every constraint that lays the chip out, ready to activate.
    ///
    /// Three labels rather than one string, because the `·` is a TIER and not a character: the numbers
    /// are the reading and the dot is the punctuation between them, so they are set in different inks
    /// and separated by the grid step. The INKS stay per-shell — a `SlateNativeColor` is one of the three
    /// names that genuinely differ — and only where the runs sit is one decision.
    ///
    /// The rungs are READ here rather than passed in. Which rung an arrangement spends is exactly what
    /// two halves can get different, so a signature that took them would have kept the drift and moved
    /// only the anchors; `SlopDeskSlate` is below this target, so there is nothing stopping the whole
    /// decision descending together.
    ///
    /// The vertical extent is the LEADING run's alone: the other two are centred on its baseline box,
    /// so the chip's height is one number's line height plus a rung either side, whatever the dot's
    /// own face reports.
    package static func constraints(
        in host: SlateHostView,
        leading: SlateHostView,
        dot: SlateHostView,
        trailing: SlateHostView,
    ) -> [NSLayoutConstraint] {
        [
            leading.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: Slate.Metric.space2,
            ),
            leading.topAnchor.constraint(equalTo: host.topAnchor, constant: Slate.Metric.space1),
            leading.bottomAnchor.constraint(
                equalTo: host.bottomAnchor, constant: -Slate.Metric.space1,
            ),
            dot.leadingAnchor.constraint(
                equalTo: leading.trailingAnchor, constant: Slate.Metric.space1,
            ),
            dot.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            trailing.leadingAnchor.constraint(
                equalTo: dot.trailingAnchor, constant: Slate.Metric.space1,
            ),
            trailing.centerYAnchor.constraint(equalTo: leading.centerYAnchor),
            trailing.trailingAnchor.constraint(
                equalTo: host.trailingAnchor, constant: -Slate.Metric.space2,
            ),
        ]
    }
}
