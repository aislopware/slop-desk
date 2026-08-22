// PaneStatusPillArt — the pane status chip's MARK, one table for every renderer (docs/56 stage F,
// batch P6).
//
// ``PaneStatusPill`` (`SlopDeskClientCore`) answers in STATES — read-only, secure input, sync input —
// and deliberately never in glyphs, because "which mode is this pane in" is a decision and "which
// symbol says so" is a drawing. This file is where the two meet, one floor below both renderers.
//
// It is the same move `Slate/PaneDropChipArt.swift` made in increment 56e, made before rather than
// after the second renderer arrives. That table sat at the foot of a SwiftUI file and could stay
// there only while both of its chips were SwiftUI; the day one became AppKit it had to be spelled
// twice or moved down. The status pill is one renderer TODAY and two the moment wave R writes
// `MacPaneStatusPills`, and a table split across the framework boundary drifts in the one direction
// nothing catches: a FOURTH pill added below reaches the half whose author added it and misses the
// other, so a pane says "SYNC INPUT" with a padlock on one platform and the grouped-panes mark on the
// other. Moving it now costs one file; moving it later costs finding out from a user.
//
// The WEIGHT the mark is drawn at is not here, and that is the boundary rather than an omission. A
// vivid chip carries a heavier glyph than a chrome one — but the thing that decides which is
// ``PaneStatusPill/fill``, already a shared name, and the weight itself is `Font.Weight` on one side
// and `NSFont.Weight` on the other. A name below and one line per framework is the
// ``ToastPresentation`` deal; restating it here would only give the floor a type it cannot hold in
// both spellings.

import SFSafeSymbols
import SlopDeskWorkspaceModel // PaneStatusPill — the STATE this file draws

package extension PaneStatusPill {
    /// The SF Symbol every renderer draws for this pill.
    ///
    /// Each pairing carries an argument the glyph alone cannot. The lock is the SOLID padlock and not
    /// the gold 🔒 emoji, because `readonly-mode.png` shows a monochrome dark padlock matching the
    /// label's weight — an emoji renders in its own colours and cannot take the theme's ink. Secure
    /// input takes the lock-SHIELD, which is macOS's own secure-event-input idiom, so the chip reads
    /// as the system state it reports rather than as a second read-only badge. And sync input takes
    /// the grouped-panes mark — the SAME symbol the palette entry that arms it wears, so the chip and
    /// the command that raised it read as one feature rather than two.
    var symbol: SFSymbol {
        switch self {
        case .readOnly: .lockFill
        case .secureInput: .lockShieldFill
        case .syncInput: .rectangle3Group
        }
    }
}
