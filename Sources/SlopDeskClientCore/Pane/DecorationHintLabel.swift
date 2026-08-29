// DecorationHintLabel — the hint badge's plate geometry and its two-letter run
//
// A hint badge is a 2-letter plate standing on the first cell of its target. Both shells build it the
// same way and neither build is a framework question: the constraint set is Auto Layout (ONE api on
// both — see `ViewEdges.swift`), and the letter run is `NSAttributedString` (Foundation, likewise).
// What differs is the label VIEW the run is handed to — `attributedStringValue` on an `NSTextField`,
// `attributedText` on a `UILabel` — and that stays in the shell.
//
// ⚠️ WHICH letters are faded is ``HintPresentation``'s, not this file's. This is the DRAWING of the
// answer; `HintPresentation.isFaded(offset:typed:)` is the answer. Re-deriving the fade here would put
// the progress cue in two places again, one rung lower.

#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SlopDeskSlate

@MainActor
package enum DecorationHintBadge {
    /// ⚠️ 14 is UNNAMED on the floor — the badge's minimum height, deliberately UNDER the keycap's 18
    /// because a badge stands ON the grid rather than beside a label. It was the SECOND spelling until
    /// this file; both shells now read it here. Proposed `Slate.Metric.hintBadge`.
    package static let minHeight: CGFloat = 14

    /// The badge's own layout: the label inset by a hair at each end, centred, and a plate that is at
    /// least ``minHeight`` tall and never shorter than the label it carries.
    package static func constraints(
        in badge: SlateHostView,
        text: SlateHostView,
    ) -> [NSLayoutConstraint] {
        [
            text.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: Slate.Metric.space1),
            text.trailingAnchor.constraint(
                equalTo: badge.trailingAnchor, constant: -Slate.Metric.space1,
            ),
            text.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            badge.heightAnchor.constraint(greaterThanOrEqualTo: text.heightAnchor),
        ]
    }

    /// The uppercase letters, already-typed ones faded (the progress cue), the rest solid.
    ///
    /// `font` and `ink` arrive from the shell because a font and a colour are two of the three types
    /// the shells genuinely spell apart — and because the badge's ink is a PINNED black rather than a
    /// theme rung, which is its renderer's own table to state.
    package static func letters(
        label: String,
        typed: String,
        font: SlateNativeFont,
        ink: SlateNativeColor,
    ) -> NSAttributedString {
        let run = NSMutableAttributedString()
        for (offset, character) in HintPresentation.displayLabel(label).enumerated() {
            let faded = HintPresentation.isFaded(offset: offset, typed: typed)
            run.append(NSAttributedString(
                string: String(character),
                attributes: [
                    .font: font,
                    .foregroundColor: faded ? ink.withAlphaComponent(Slate.Opacity.dim) : ink,
                ],
            ))
        }
        return run
    }
}
