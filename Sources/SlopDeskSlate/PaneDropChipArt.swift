// PaneDropChipArt — everything the drop chip's TWO drawings must agree on (docs/56 stage D,
// increment 56e).
//
// There are two drop chips and there have to be. The canvas draws a ghost chip (`MacPaneDragChip`)
// anchored to the drop zone it describes; a borderless `NSPanel` (``MacPaneDragChipPanel``) carries
// the same chip once the cursor leaves the content column, because the canvas chip clips at its
// hosting view's edge and this drag legitimately crosses into the sidebar, into another window, and
// onto bare desktop.
//
// ⚠️ BOTH CAN BE ON SCREEN IN ONE DRAG. That is what makes this file necessary rather than tidy. Drag a
// pane to the canvas edge and the in-tree chip is showing; keep going and the panel takes over. A user
// can compare them directly, and any drift — a half-step of padding, a slightly different rim — reads
// as the chip glitching rather than as two files disagreeing.
//
// WHY THE FLOOR AND NOT EITHER HALF. `Package.swift` gives Slate its `SFSafeSymbols` dependency for
// exactly this: *the marks are named as `SFSymbol`s, so both renderers ask for the same artwork*.
// ``PaneDropRegister`` in `SlopDeskClientCore` answers in OUTCOMES — `.swap`, `.splitColumns`,
// `.newWindow` — and deliberately never in glyphs or points, because "what would releasing here do" is
// a decision and "which glyph says so, at what padding" is a drawing. This file is where the two meet,
// one floor below both renderers and drawing nothing itself.
//
// It was not always here. The symbol table sat at the foot of `PaneMoveAffordance.swift` and the metrics
// were raw literals in two places, which one file could hold while BOTH chips were SwiftUI — the panel
// was an `NSHostingView` over a SwiftUI card. Increment 56e rewrote that card in AppKit, and the moment
// it stopped being SwiftUI it also stopped being able to reach into the draining target. Two futures:
// spelled twice, once per renderer, or moved down. Spelled twice is how a `.beside` drop ends up showing
// `rectangle.stack` in one chip and something else in the other, and nobody finds out until a user drags
// between them.
//
// So a new `Mark` case still cannot reach one chip and miss the other — the property the original header
// claimed, and could only really claim while both chips were SwiftUI.

import CoreGraphics // CGFloat — this file is points and a glyph name, and never a view
import SFSafeSymbols
import SlopDeskWorkspaceModel // PaneDropRegister.Mark — the OUTCOME this file draws

package extension PaneDropRegister.Mark {
    /// The SF Symbol every renderer draws for this drop mark.
    ///
    /// The pairs are not arbitrary and each says the outcome in one glance: the two split marks are the
    /// literal split they produce (`2x1` = columns, `1x2` = rows), `.beside` is a STACK because landing
    /// beside a pane's row is landing in that row's tab, and `.cancel` is the one mark that is not a
    /// shape at all — a release that commits nothing has no geometry to show.
    var symbol: SFSymbol {
        switch self {
        case .cancel: .xmark
        case .swap: .rectangle2Swap
        case .splitColumns: .rectangleSplit2x1
        case .splitRows: .rectangleSplit1x2
        case .beside: .rectangleStack
        case .newTab: .plusSquareOnSquare
        case .newWindow: .macwindow
        }
    }
}

package extension Slate {
    /// The drop chip's capsule, as numbers — read by the canvas ghost chip (`MacPaneDragChip`) and by
    /// the detached panel (``MacPaneDragChipPanel``), both AppKit.
    ///
    /// The type sizes are NOT here on purpose: they are ``Slate/Typeface/footnote`` (the glyph,
    /// semibold) and ``Slate/Typeface/base`` (the label, medium), which are ladder rungs both renderers
    /// already name directly. Only the values with nowhere else to live are restated here.
    enum DropChip {
        /// Between the mark and the words. Tighter than ``Slate/Metric/space2`` because the glyph IS the
        /// first word of the phrase — "⇄ swap terminal" is one utterance, and a full step of air would
        /// make it two.
        package static let glyphGap: CGFloat = 6
        /// The capsule's horizontal breathing room.
        package static let padH: CGFloat = 10
        /// The capsule's vertical breathing room. Half of `padH`, which is what makes the shape read as a
        /// capsule rather than as a pill someone rounded off: the cap curve wants more room across than
        /// down.
        package static let padV: CGFloat = 6
        /// The rim's alpha when releasing would commit NOTHING.
        ///
        /// ``Slate/Opacity/dim``, and it used to be a raw `0.4` in the SwiftUI chip — off the ladder by
        /// 0.05, in the one place where being off the ladder mattered least and cost most: it was the
        /// single literal keeping the two chips from being provably identical. Snapped rather than
        /// minted, because a rim alpha is not a new question.
        package static let cancelRim = Slate.Opacity.dim
    }
}
