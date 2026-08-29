// DecorationViModeCard — the two pieces of vi-mode chrome that are not a framework at all
//
// The mode pill and the key-hint card each carry a piece of state that decides whether a repaint
// happens, and BOTH renderers had a byte-identical copy of it. Neither is a view: one is "has this
// reading changed since the last paint, and is this the first one", the other is "which rung does
// this width afford, and is it the rung already hung". A `CGFloat` comparison and an enum equality
// do not know which shell called them.
//
// What stays in the shell is the paint itself — `attributedStringValue` versus `attributedText`,
// `NSAnimationContext` versus `UIView.animate`, `orientation` versus `axis`.

import SlopDeskSlate
import SlopDeskWorkspaceCore

/// The vi mode pill's paint gate: the last reading it drew, and whether it has ever drawn.
///
/// The mirrors are re-synced after EVERY copy-mode key, including the ones that move a cursor and
/// leave both readings alone, so the gate exists to make those repaints free.
@MainActor
package final class DecorationViModePill {
    /// How a reading arrived — which is the ONLY thing the shells do differently with it. A pill
    /// fading its own arrival in reads as a lag, not as a transition, so the first paint is not
    /// animated and every later one is.
    package enum Arrival {
        case first
        case again
    }

    /// The last applied mode. Read by the shells' ring ladder, which is two inks over
    /// ``TerminalViewModel/VisualMode/isVisual``.
    package private(set) var mode: TerminalViewModel.VisualMode = .none
    /// The last applied repeat count.
    package private(set) var pending: Int?
    private var painted = false

    package init() {}

    /// Take a reading, or `nil` when it changes nothing.
    ///
    /// `painted` gates the early-out as well as the animation: the resting reading is `.none` / `nil`,
    /// so an unpainted pill would compare equal to itself and never draw a word.
    package func accept(mode: TerminalViewModel.VisualMode, pending: Int?) -> Arrival? {
        guard !painted || mode != self.mode || pending != self.pending else { return nil }
        let arrival: Arrival = painted ? .again : .first
        painted = true
        self.mode = mode
        self.pending = pending
        return arrival
    }
}

/// The vi key-hint card's width ladder: which rung a proposal affords, and the re-hang that follows.
///
/// The COLUMN VIEWS are never rebuilt — only re-parented. A rung change is a re-flow, not a content
/// change, and rebuilding would throw away the measured widths the whole ladder runs on.
@MainActor
package final class DecorationViKeyHintLadder {
    /// Between two columns stacked into one slot.
    private static let stackSpacing = Slate.Metric.space3

    private var rung: ViKeyHintLayout?

    package init() {}

    /// The rung `width` affords, or `nil` when it names the rung already hung.
    ///
    /// ⚠️ Measured against the width left INSIDE the card's own padding, not the proposal itself. The
    /// padding is a fixed cost at both ends, and a ladder that spent the whole proposal would keep
    /// three columns at a width that fits three columns and nothing else — which is a card whose last
    /// column is cut off by its own edge inset.
    package func rung(
        forWidth width: Double,
        gap: Double,
        columnWidth: (ViKeyHintColumn) -> Double,
    ) -> ViKeyHintLayout? {
        let next = ViKeyHintPresentation.layout(
            forWidth: width - Double(Slate.Metric.space3) * 2,
            gap: gap,
            columnWidth: columnWidth,
        )
        guard next != rung else { return nil }
        rung = next
        return next
    }

    /// Hang the columns in the slots the rung names.
    ///
    /// `makeGroup` is the one seam: a vertical strip is `orientation` on AppKit and `axis` on UIKit,
    /// which is the divergence ``SlateHostStack`` is explicitly not allowed to paper over. Everything
    /// the two frameworks spell alike — the spacing, the alignment, the teardown, the parenting —
    /// happens here.
    package func rehang(
        _ next: ViKeyHintLayout,
        in slots: SlateHostStack,
        column: (ViKeyHintColumn) -> SlateHostView?,
        group makeGroup: () -> SlateHostStack,
    ) {
        for slot in slots.arrangedSubviews {
            slots.removeArrangedSubview(slot)
            slot.removeFromSuperview()
        }
        for group in ViKeyHintPresentation.groups(for: next) {
            let stack = makeGroup()
            stack.alignment = .leading
            stack.spacing = Self.stackSpacing
            stack.translatesAutoresizingMaskIntoConstraints = false
            for name in group {
                guard let view = column(name) else { continue }
                stack.addArrangedSubview(view)
            }
            slots.addArrangedSubview(stack)
        }
    }
}
