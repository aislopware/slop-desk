// MacViCursorOverlay — the copy-mode BLOCK CURSOR, in AppKit (docs/56 wave R, batch R3).
//
// The AppKit half of ``ViCursorOverlay``. A DECORATION coincident with the terminal surface, drawing
// ONE accent-outlined cell at the vi cursor while copy-mode is armed. The SELECTION is deliberately
// NOT drawn here — a keyboard-started visual range goes through the fork's `set_selection` ABI and
// libghostty paints it natively; only the cursor (client state by design) needs a view.
//
// HONESTY: the drawn position is ``TerminalViewModel/viCursorCell`` — a VIEWPORT-relative cell the
// model re-derives from a fresh `viewportInfo()` readback after every copy-mode key and on every
// renderer scroll echo, and clears when the cursor scrolls off-viewport. So the block is absent,
// never wrong (the anti-jitter rule); a headless / placeholder surface conforms to neither seam and
// draws nothing.
//
// WHERE the block goes is not decided here — ``ViCursorGeometry`` owns the four ways to be absent and
// the wide-glyph span rule, and this view maps its one `CGRect` to pixels. What IS this file's is the
// pair of facts the SwiftUI half got for free and AppKit does not: the coordinate space is FLIPPED
// (see `isFlipped`), and `.strokeBorder`'s inward stroke has to be spelled as an inset (see
// ``borderRect(in:)``).

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskTerminal
import SlopDeskWorkspaceCore

@MainActor
final class MacViCursorOverlay: NSView {
    /// The pane's terminal model — observed for ``TerminalViewModel/viCursorCell`` and the copy-mode
    /// badge gate, dereferenced non-reactively for the surface's cell geometry at refresh time.
    private let model: TerminalViewModel

    /// The cell footprint the block currently wears, in the surface's top-left-origin space, or `nil`
    /// when there is nothing honest to draw. Stored rather than recomputed inside `draw(_:)`: a
    /// redraw can be asked for by AppKit (a window move, an appearance flip) at a moment that has
    /// nothing to do with the cursor, and re-reading libghostty's viewport from inside a draw pass
    /// would make the block's truth depend on when the compositor felt like asking.
    private var cell: CGRect?

    init(model: TerminalViewModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(false)
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ FLIPPED, and every rect in this file depends on it. ``TerminalCellMetrics`` answers in the
    /// surface's TOP-LEFT-origin space (row 0 at the top, y growing downward) — the space SwiftUI's
    /// `Canvas`/`offset` already work in, which is why the SwiftUI half never had to say so. An
    /// unflipped `NSView` would draw row 0 at the BOTTOM of the pane: still compiling, still one crisp
    /// block, and wrong by the whole height of the viewport.
    override var isFlipped: Bool { true }

    /// Transparent to the pointer — this is a decoration over a terminal that must keep every click
    /// (select, ⌘click a link, right-click the context menu). The AppKit spelling of the SwiftUI
    /// half's `.allowsHitTesting(false)`; sufficient here only because this view owns no
    /// `NSTrackingArea` (a tracking area is rect-based and keeps firing whatever `hitTest` answers).
    override func hitTest(_: NSPoint) -> NSView? { nil }

    /// The rect whose STROKE lands inside `cell` rather than straddling its edge.
    ///
    /// SwiftUI's `.strokeBorder` strokes INWARD; `NSBezierPath.stroke()` centres the line on the path,
    /// so a naive port would paint `strokeWidth / 2` of accent into the neighbouring cells on all four
    /// sides — the block would read as wider than the glyph it wears and would smear the columns
    /// either side of it. Half a point at a time, in a decoration whose whole job is to be exactly one
    /// cell wide.
    static func borderRect(in cell: CGRect) -> CGRect {
        cell.insetBy(dx: ViCursorGeometry.strokeWidth / 2, dy: ViCursorGeometry.strokeWidth / 2)
    }

    /// A terminal-authentic BLOCK cursor: one sharp-cornered accent block, exactly the glyph's cell
    /// footprint. A real terminal block INVERTS the glyph; an overlay cannot, so the roles split — the
    /// FULL-strength edge is the visibility (the crisp silhouette the eye finds across a busy buffer)
    /// and the interior wash stays LIGHT so the glyph underneath still reads. Sharp corners, no glow
    /// (the Meridian at-rest zero-ornament law).
    override func draw(_: NSRect) {
        guard let cell else { return }
        let accent = Slate.Native.accent
        // `slateScalingAlpha`, NOT `withAlphaComponent`: the SwiftUI half spends `.opacity(_:)`, which
        // SCALES the colour's own alpha, and the scaling form is the one that stays appearance-dynamic
        // — the accent is a light/dark pair and a replaced alpha would resolve it once, here.
        accent.slateScalingAlpha(ViCursorGeometry.fillOpacity).setFill()
        NSBezierPath(rect: cell).fill()
        accent.setStroke()
        let edge = NSBezierPath(rect: Self.borderRect(in: cell))
        edge.lineWidth = ViCursorGeometry.strokeWidth
        edge.stroke()
    }

    /// A resize moves every cell, and no observable property bumps when it does — the cell metrics are
    /// read off the live surface, which the pane resized under us. Without this the block would sit at
    /// its pre-resize point until the next copy-mode key, which is a WRONG position rather than an
    /// absent one — the failure this whole family refuses.
    override func layout() {
        super.layout()
        refresh()
    }

    /// The accent is appearance-dynamic and `draw(_:)` resolves it against whatever appearance the
    /// pane is standing in, so a theme flip only needs the pixels asked for again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: The live read

    /// Reading the two gates here is what makes the block move the instant a motion lands. The
    /// geometry read stays out of `read`: `cellMetrics()` is a libghostty readback, not observable
    /// state, so tracking it would register nothing and cost a call per arm.
    ///
    /// `apply` discards the reading and asks ``refresh()`` for the values again, because `layout()`
    /// needs that same recompute with no reading in hand — the tracked pair is the DEPENDENCY, not
    /// the input.
    private func follow() {
        ObservationFollow.arm(self) { view in
            (active: view.model.copyModeBadgeActive, cell: view.model.viCursorCell)
        } apply: { view, _ in
            view.refresh()
        }
    }

    private func refresh() {
        let next = ViCursorGeometry.rect(
            copyModeActive: model.copyModeBadgeActive,
            cell: model.viCursorCell,
            metrics: (model.surface as? TerminalViewportSnapshotting)?.cellMetrics(),
        )
        guard next != cell else { return }
        cell = next
        needsDisplay = true
    }
}
