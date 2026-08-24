// PaneGrabPillArt — everything the GRAB PILL's drawings must agree on (docs/56 stage F, batch P6).
//
// The grab pill is the `-` a pane reveals on hover at its top edge: grab it and the pane moves. There
// is one gesture and there are already TWO drawings of it — ``PaneMoveHandle`` over a leaf of the
// canvas, and the satellite window's own strip (`SatellitePaneContent`), which drags the same pane by
// the same pill into the same four destinations. Wave R adds a third when the canvas becomes AppKit.
//
// ⚠️ TWO OF THEM ARE THE SAME DRAG. The satellite strip's whole purpose is merging back INTO the
// canvas: the user grabs the pill in the detached window, crosses the main window, and releases on a
// leaf whose own pill is the thing they are aiming at. The two pills are compared across a single
// gesture, at the same size, seconds apart — so a 44 that became a 42, or a reveal that scaled by 1.1
// on one side and 1.15 on the other, does not read as two files disagreeing. It reads as the pill
// changing size while the user is holding it. That is ``Slate/DropChip``'s argument (increment 56e)
// applied to the affordance the chip is dragged BY, and it is the reason this file exists rather than
// a preference for named numbers.
//
// WHY THE FLOOR AND NOT EITHER RENDERER. The AppKit canvas cannot reach into the draining target, and
// the draining target must not reach up. A number both need therefore has exactly two futures —
// spelled twice, or moved down — and 56e's ruling picks the second: when both renderers need the same
// ARTWORK it goes to the floor rather than into a gate, because a gate can only report a drift that
// has already shipped. Nothing here draws; a `some View` in this target fails `slopdesk-invariants`,
// which is the same line ``Slate/DropChip`` sits on.
//
// What is NOT here is the WORDING and the OUTCOME — `PaneDropRegister` (`SlopDeskClientCore`) owns
// "what would releasing here do", and this file owns only "how big is the thing you grabbed".

import CoreGraphics // CGFloat — this file is points and a ratio, and never a view

package extension Slate {
    /// The pane's grab pill, as numbers — read by the SwiftUI canvas handle, by the satellite
    /// window's strip, and by the AppKit canvas that joins them.
    enum GrabPill {
        // MARK: The strip (the hit area)

        /// The hit strip's height, flush to the leaf's TOP edge.
        ///
        /// 14 puts the pill's centre 7pt in, INSIDE the pane's own top padding band. The obvious
        /// alternative — a 3pt inset over a 22pt strip — lands the pill at ~14pt, which is over the
        /// first line of terminal text: the affordance would sit on the content it is offering to
        /// move.
        package static let stripHeight: CGFloat = 14
        /// The strip's floor. Below this a strip is no longer a target a pointer can find, so a very
        /// narrow leaf keeps a grabbable pill rather than a proportionally honest one.
        package static let stripWidthMin: CGFloat = 56
        /// The strip's ceiling — and the width the SATELLITE strip takes outright, because a detached
        /// window is wide and the share below would resolve here for every window worth detaching
        /// into. Named rather than repeated: the two strips are compared inside one drag.
        package static let stripWidthMax: CGFloat = 160
        /// The share of a leaf the strip spans between those two bounds. Centred and clamped so the
        /// strip covers minimal terminal real estate and can never overlap the dividers either side.
        package static let stripWidthShare = 0.4

        /// The strip's width over a leaf this wide — the share, held between the two bounds.
        ///
        /// `Double.minimum`/`.maximum` rather than `<`/`>` ternaries, per `CLAUDE.md`: this is a
        /// drawing whose two renderers must land on the same pixel, and the NaN/±0 behaviours of the
        /// ternary spelling are exactly the kind of difference that survives a review.
        package static func stripWidth(forLeafWidth width: CGFloat) -> CGFloat {
            CGFloat(Double.minimum(
                Double(stripWidthMax), Double.maximum(Double(stripWidthMin), Double(width) * stripWidthShare),
            ))
        }

        // MARK: The pill itself

        /// The `-` bar's width. The pill is the ink; the strip around it is only the target.
        package static let barWidth: CGFloat = 30
        /// The `-` bar's height.
        package static let barHeight: CGFloat = 4

        /// The contrast plate's width, and below it its height.
        ///
        /// The plate is drawn ONLY under an unthemed pane — a `.desktop` video stream, whose desktop
        /// is usually light, where the bare tertiary bar tuned to the terminal palette disappears
        /// completely. It carries the hairline and the chip shadow (the same voice as the rest of the
        /// over-video chrome) and leaves the bar's own styling untouched, so a terminal leaf and a
        /// video leaf reveal the same pill with one of them standing on paper.
        package static let plateWidth: CGFloat = 44
        /// The contrast plate's height. Wider than the bar it carries by a hair on every side, which
        /// is what makes it read as the bar's ground rather than as a second pill behind it.
        package static let plateHeight: CGFloat = 10

        /// How far the pill grows on hover, before the grab. It scales on HOVER ONLY: once the drag
        /// is live the pill is at rest again, because the thing that moves from then on is the pane.
        package static let hoverScale = 1.15
    }
}
