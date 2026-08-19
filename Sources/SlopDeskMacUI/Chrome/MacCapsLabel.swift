// MacCapsLabel — the engraved all-caps micro-heading, spelled once for the whole AppKit half
// (docs/56 stage D, increment 55).
//
// One recipe: the instrument face at ``Slate/Typeface/small``, upper-cased, with
// ``Slate/Typeface/instrumentTracking`` kerning. It is what a card uses to NAME a region — the palette's
// section rows, Open Quickly's filter headers, the peek card's `RECENT`, the cheat sheet's categories,
// the keybindings editor's groups, and every device-panel section heading.
//
// It arrived here by census rather than by design. Increment 53 merged the two device panels' shells
// and found `macDevicePanelCapsLabel`; a grep for ``Slate/Typeface/instrumentTracking`` then found the
// SAME four-attribute dictionary open-coded five more times across `Overlays/` and `Settings/`, each
// with its own copy of the "wide enough to read as engraving" comment. Six copies of a typographic
// rule is six chances for one card to be a half-step off the others, and a reader comparing two of
// them cannot tell whether the difference is a decision or a slip.
//
// TWO SPELLINGS, ONE RECIPE, and the split is not stylistic. Four of the six call sites already own an
// `NSTextField` — a reused row cell, a heading built in an initialiser — and want only the string, so
// ``macCapsString(_:color:weight:)`` is the primitive. The other two want a label they can hand
// straight to an `NSStackView`, so ``macCapsLabel(_:color:weight:)`` wraps it. The label spelling MUST
// go through the string spelling; that is the whole point, and the ratchet in
// `scripts/check-supervisor.sh` bans a seventh copy of the attribute dictionary anywhere in this target.
//
// NO DEFAULT COLOUR ROLE, deliberately. The six sites disagree — `Slate.Native.State.header` on a
// device panel, `Slate.Native.Overlay.tertiary` on a summoned card, `Slate.Native.Text.tertiary` in
// Settings — and they are RIGHT to: an overlay's ink ladder is not a page's. What is shared is the
// FACE, the caps and the tracking; the ink is the surface's own answer, so it stays a required
// argument and a call site cannot inherit the wrong one by forgetting.

import AppKit
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

/// The engraved caps micro-heading as an attributed string.
///
/// `weight` is `.medium` because five of the six sites are; the device panel's section heading is
/// `.semibold` and says why at its call site.
@MainActor
func macCapsString(
    _ words: String, color: NSColor, weight: NSFont.Weight = .medium,
) -> NSAttributedString {
    NSAttributedString(
        string: words.uppercased(),
        attributes: [
            .font: Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: weight),
            .foregroundColor: color,
            // Wide enough to read as engraving, applied ONLY to an all-caps label — tracking on mixed
            // case reads as a rendering fault rather than as a voice.
            .kern: Slate.Typeface.instrumentTracking,
        ],
    )
}

/// The same heading as a finished, non-selectable label.
///
/// `isSelectable = false` is part of the recipe rather than a caller's choice: this is taxonomy, not
/// content. A selectable section header lets a drag inside a card start a text selection instead of
/// the gesture the card is for.
@MainActor
func macCapsLabel(
    _ words: String, color: NSColor, weight: NSFont.Weight = .medium,
) -> NSTextField {
    let label = NSTextField(labelWithAttributedString: macCapsString(words, color: color, weight: weight))
    label.isSelectable = false
    return label
}
