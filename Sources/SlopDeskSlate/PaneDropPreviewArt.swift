// PaneDropPreviewArt — the line work every DROP PREVIEW must agree on (docs/62 stage I).
//
// A drop preview is what the canvas paints while a pane is in the air: a wash over the whole leaf you
// would swap with, a wash over the HALF you would re-split into, a rail down the edge you would dock
// against, and a dashed outline round the pane that is already lifted. Four marks, drawn twice —
// `MacPaneMoveAffordance` (AppKit) and `PaneMoveAffordanceView` (UIKit).
//
// ⚠️ THIS RUNG CROSSES A FRAMEWORK BOUNDARY, WHICH ``Slate/GrabPill``'S DOES NOT. That file's two
// renderers are both AppKit, so its numbers could at least be diffed by a reader who opened both. These
// five were spelled in an AppKit file and a UIKit file, and a number written on two sides of a framework
// boundary has nothing to compare itself against at all: no compiler, no gate, and no reviewer who holds
// both open, because the two files share not one import. They were the LAST five figures in the client
// still in that position — every other pair had already come down — and both halves carried a comment
// saying so while they waited for this rung. Minting it is what those comments were waiting for.
//
// WHY THE FLOOR AND NOT A GATE. A gate can only report a drift that has already shipped, and this drift
// is invisible even after it ships: a rim that went 2 → 1.5 on one platform reads as a preview that is
// simply a little softer on the phone, not as two files disagreeing. That is 56e's ruling — when both
// renderers need the same ARTWORK it goes to the floor — and a boundary this rung crosses makes the case
// more sharply than the pair the ruling was written for.
//
// What is NOT here is the WORDING and the OUTCOME: `PaneDropRegister` (`SlopDeskClientCore`) owns "what
// would releasing here do", and the geometry of WHERE each mark lands is `PaneDropGeometry`'s. This file
// owns only how the marks are STROKED. Nothing here draws — a `some View` in this target fails
// `slopdesk-invariants`, the same line ``Slate/DropChip`` and ``Slate/GrabPill`` sit on.

import CoreGraphics // CGFloat — this file is widths, alphas and a dash pattern, and never a view

package extension Slate {
    /// The drop preview's stroke work, as numbers — read by `MacPaneMoveAffordance` (AppKit) and by
    /// `PaneMoveAffordanceView` (UIKit), both drawing the same four marks over the same drag.
    enum DropPreview {
        // MARK: The rims

        /// The rim on a preview that covers a WHOLE rectangle — the swap wash and the dock rail. Full
        /// strength, because both of them are claims about an entire area.
        package static let wholeRim: CGFloat = 2
        /// The rim on the re-split SLAB, which covers half of a pane the user can still see the rest
        /// of. A hair thinner than ``wholeRim`` on purpose: the slab has a seam bar of its own doing
        /// the load-bearing part of the reading, so its border only has to bound the wash. A full
        /// 2 here would read as two borders — the slab's and the pane's own edge, right beside it.
        package static let slabRim: CGFloat = 1.5
        /// How much of the accent that thinner rim spends. Quieter as well as finer: the two moves say
        /// the same thing, and the slab needs to recede from the whole-area marks by both.
        package static let slabRimWash = 0.7

        // MARK: The lifted source

        /// The lifted source's outline — same width as ``slabRim``, and quieter still, because it marks
        /// the pane the user is NOT choosing. It is the only mark in this layer that is about where the
        /// drag came FROM.
        package static let liftedWash = 0.55
        /// Dash-on, dash-off. A dashed outline is the one mark here that says "was here" rather than
        /// "will be here", and no solid stroke can say that — which is why the pattern is a figure on
        /// this rung and not a flag at the two call sites.
        ///
        /// `[CGFloat]`, spelled: `CGContext.setLineDash` and `CAShapeLayer.lineDashPattern` want
        /// different element types, and an inferred `[Int]` here would have made the UIKit half convert
        /// at the call site while the AppKit half did not — a difference in the SPELLING of a shared
        /// number, which is the exact thing this file exists to remove.
        package static let liftedDash: [CGFloat] = [5, 4]
    }
}
