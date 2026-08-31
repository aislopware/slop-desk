// ViCursorOverlayView — the copy-mode BLOCK CURSOR, in UIKit (docs/62, the pane-leaf cluster).
//
// A DECORATION coincident with the terminal surface, drawing ONE accent-outlined cell at the vi cursor
// while copy-mode is armed. The SELECTION is deliberately NOT drawn here — a keyboard-started visual
// range goes through `libghostty-vt`'s `set_selection` door and the terminal renderer paints it; only the
// cursor (client state by design) needs a view.
//
// HONESTY: the drawn position is ``TerminalViewModel/viCursorCell`` — a VIEWPORT-relative cell the model
// re-derives from a fresh `viewportInfo()` readback after every copy-mode key and on every renderer
// scroll echo, and clears when the cursor scrolls off-viewport. So the block is absent, never wrong (the
// anti-jitter rule); a headless / placeholder surface conforms to neither seam and draws nothing.
//
// WHERE the block goes is not decided here — ``ViCursorGeometry`` owns the four ways to be absent and the
// wide-glyph span rule, and this view maps its one `CGRect` to a frame.
//
// ⚠️ TWO THINGS THE MAC HALF HAD TO SAY AND THIS ONE DOES NOT, both worth recording because the
// temptation is to port the workaround along with the code.
//
//   1. NO FLIP. ``TerminalCellMetrics`` answers in the surface's TOP-LEFT-origin space, which is
//      `UIView`'s own — so the `isFlipped { true }` the Mac needs has no counterpart and the rect is used
//      verbatim. An `NSView` that forgot the flip drew row 0 at the BOTTOM; there is no equivalent
//      mistake available here.
//   2. NO STROKE INSET. `NSBezierPath.stroke()` centres the line on the path, so the Mac half spells an
//      explicit half-width inset (``MacViCursorOverlay/borderRect(in:)``) to reproduce SwiftUI's inward
//      `.strokeBorder`. A `CALayer`'s `borderWidth` is drawn INSIDE its bounds by definition, so this
//      half gets the inward stroke from the framework and the inset would be a second, wrong one.
//
// That is also why this is a layer and not a `draw(_:)` override: the block is a filled rectangle with an
// inward border, which is two `CALayer` properties. A `draw` override would force a CPU-rasterized
// backing store the size of the pane to paint one cell (docs/62 §5.1(f)), and would then have to
// re-derive the inset the layer gives for free.
//
// `Slate.*` tokens only; hit-transparent; no `libghostty-vt` / Metal touched.

#if os(iOS)
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import SlopDeskWorkspaceCore
import UIKit

@MainActor
final class ViCursorOverlayView: UIView {
    /// The pane's terminal model — observed for ``TerminalViewModel/viCursorCell`` and the copy-mode badge
    /// gate, dereferenced non-reactively for the surface's cell geometry at refresh time.
    private let model: TerminalViewModel

    /// The block itself. A subview rather than this view's own layer, because this view spans the whole
    /// pane (it is coincident with the surface) and the block is one cell inside it.
    private let block = UIView()

    /// The cell footprint the block currently wears, or `nil` when there is nothing honest to draw.
    /// Stored rather than recomputed inside a layout pass: re-reading `libghostty-vt`'s viewport from inside
    /// layout would make the block's truth depend on when UIKit felt like asking.
    private var cell: CGRect?

    /// The live following. Stored for ``teardown()`` alone: this view can be detached from the pane and
    /// still be retained for a beat, which is the one case ``ObservationFollow/stop()`` exists for.
    private var cursorFollow: ObservationFollow?

    init(model: TerminalViewModel) {
        self.model = model
        super.init(frame: .zero)
        isAccessibilityElement = false
        // DECORATION only: never swallow a touch. The renderer owns tap-to-position, the selection drag
        // and the long-press menu, and a touch this view answered would do none of them. The UIKit
        // spelling of `.allowsHitTesting(false)`, and — unlike AppKit — it is the WHOLE spelling: there is
        // no rect-based tracking area that keeps firing whatever hit-testing answers.
        isUserInteractionEnabled = false

        block.isHidden = true
        block.isUserInteractionEnabled = false
        block.layer.borderWidth = ViCursorGeometry.strokeWidth
        addSubview(block)

        // A `CGColor` on a layer is RESOLVED, not dynamic, and the accent is a light/dark pair — so the
        // border has to be re-inked on an appearance flip. The FILL rides `backgroundColor`, a `UIColor`
        // the view keeps dynamic by itself, which is also what preserves the SCALING alpha: the Mac half
        // reaches for `slateScalingAlpha` over `withAlphaComponent` for exactly this reason, and here the
        // scaling form is the only one that survives the round trip.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.reink()
        }
        reink()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// End the following, so a wake already in flight cannot re-arm against a model this view has
    /// finished with.
    func teardown() {
        cursorFollow?.stop()
        cursorFollow = nil
    }

    /// A terminal-authentic BLOCK cursor: one sharp-cornered accent block, exactly the glyph's cell
    /// footprint. A real terminal block INVERTS the glyph; an overlay cannot, so the roles split — the
    /// FULL-strength edge is the visibility (the crisp silhouette the eye finds across a busy buffer) and
    /// the interior wash stays LIGHT so the glyph underneath still reads. Sharp corners, no glow (the
    /// Meridian at-rest zero-ornament law).
    private func reink() {
        block.backgroundColor = Slate.Native.accent.slateScalingAlpha(ViCursorGeometry.fillOpacity)
        block.layer.borderColor = Slate.Native.accent
            .resolvedColor(with: traitCollection).cgColor
    }

    /// A resize moves every cell, and no observable property bumps when it does — the cell metrics are
    /// read off the live surface, which the pane resized under us. Without this the block would sit at its
    /// pre-resize point until the next copy-mode key, which is a WRONG position rather than an absent one
    /// — the failure this whole family refuses.
    ///
    /// ⚠️ READS ONLY (docs/62 hazard 7). ``refresh()`` touches the model and the surface and writes
    /// nothing back; a mutating call here would invalidate observation, schedule a relayout, and land
    /// straight back in this method.
    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    // MARK: The live read

    /// The following, through ``ObservationFollow/arm(_:read:apply:)`` — reading the two gates in `read`
    /// is what makes the block move the instant a motion lands. The geometry read stays OUT of `read`:
    /// `cellMetrics()` is a renderer readback, not observable state, so tracking it would register
    /// nothing and cost a call per arm.
    ///
    /// `apply` discards the reading and asks ``refresh()`` for the values again, because `layoutSubviews`
    /// needs that same recompute with no reading in hand — the tracked pair is the DEPENDENCY, not the
    /// input.
    private func follow() {
        cursorFollow = ObservationFollow.arm(self) { view in
            DecorationViCursor.track(view.model)
        } apply: { view, _ in
            view.refresh()
        }
    }

    private func refresh() {
        let next = DecorationViCursor.rect(for: model)
        guard next != cell else { return }
        cell = next
        guard let next else {
            block.isHidden = true
            return
        }
        block.isHidden = false
        // ⚠️ Set WITHOUT an implicit animation. A block that slid from its old cell to its new one on
        // every `j` would be a cursor lagging behind the key that moved it — the Meridian mechanical law,
        // and the reason the Mac half repaints rather than animates. A frame assignment outside an
        // animation block is already unanimated in UIKit, but `CATransaction` says so where a later
        // caller could wrap this in one.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block.frame = next
        CATransaction.commit()
    }
}
#endif
