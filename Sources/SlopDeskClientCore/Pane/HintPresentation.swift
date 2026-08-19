// HintPresentation — the Vimium-style Hint Mode overlay's decisions and wording, for both of the halves
// that will draw it.
//
// The MATH was already below the view before this file existed: ``HintLabelAssigner/targets(rows:cwd:schemes:patterns:maxScanColumns:)``
// finds the spans, ``HintLabelAssigner`` assigns the two-letter labels and filters them against what has been typed, and
// ``TerminalCellMetrics`` turns a cell into a rect. What was still spelled inside the SwiftUI overlay is
// everything between that math and the ink — which badge is faded, which is dimmed, whether the overlay
// is up at all, and every word it says.
//
// THE PER-LETTER FADE IS THE PIECE THAT LOOKS LIKE LAYOUT AND IS NOT. A label is two characters and the
// overlay draws them in two different inks — the already-typed prefix faded, the rest solid — so the
// user can see which key is next. Said as `offset < typed.count` it is one rule; re-derived per renderer
// it is a place where a half could fade the wrong letter and still look plausible, because on the very
// common case (nothing typed yet) both spellings agree.
//
// The badge's plate is a FIXED yellow with BLACK text — theme-independent so it reads over any terminal
// background, the same rationale the secure-input pill's fixed blue carries. That is a token decision,
// so it stays with the renderers; what is here is which INK ROLE each letter takes, not which colour.

import Foundation
import SlopDeskWorkspaceCore

package enum HintPresentation {
    // MARK: - Is the overlay up?

    /// Whether the overlay draws at all.
    ///
    /// Three things have to hold together, and the third is the honest ceiling: a headless surface does
    /// not conform to ``TerminalViewportSnapshotting`` (the real one hangs without a window server), so
    /// it reports no cell metrics and the overlay renders NOTHING. Labels are ABSENT, never wrong — a
    /// badge drawn at a guessed cell size would point at the wrong word.
    ///
    /// `cellWidth`/`cellHeight` are `0` when the caller has no snapshot, which is why the predicate takes
    /// the numbers rather than an optional metrics value: both halves already have them as scalars at
    /// the point the question is asked.
    package static func isArmed(intent: HintIntent?, cellWidth: Double, cellHeight: Double) -> Bool {
        intent != nil && cellWidth > 0 && cellHeight > 0
    }

    // MARK: - Reading a label

    /// The label AS DRAWN. Hint labels are assigned lowercase and always shown uppercase — a two-letter
    /// badge over terminal output has to be read at a glance, and mixed case at 10pt on a yellow plate is
    /// not.
    package static func displayLabel(_ label: String) -> String { label.uppercased() }

    /// Whether the character at `offset` of a label has already been typed, and so draws faded.
    ///
    /// The comparison is against the typed prefix's LENGTH rather than against its characters: hint
    /// labels are ASCII by construction (``HintLabelAssigner``'s alphabet), and comparing lengths keeps
    /// the rule honest for a partially-typed label that no longer matches at all — those badges are
    /// dimmed as a whole by ``dimmed(label:matched:)``, and a dimmed badge showing its first letter
    /// faded is exactly the progress cue that was wanted.
    package static func isFaded(offset: Int, typed: String) -> Bool { offset < typed.count }

    /// The labels the typed prefix still admits — a set, because every badge asks about itself.
    package static func matchedLabels(typed: String, labels: [String]) -> Set<String> {
        Set(HintLabelAssigner.filter(typed: typed, labels: labels).matched)
    }

    /// Whether a badge is DIMMED: the typed prefix has ruled its label out.
    ///
    /// Ruled-out badges are dimmed rather than removed. A label that vanished would let the eye think a
    /// target had gone away, and the remaining badges would then have to be re-read from scratch after
    /// every keystroke; dimmed, the field the user is scanning stays where it was.
    package static func dimmed(label: String, matched: Set<String>) -> Bool { !matched.contains(label) }

    // MARK: - The words

    /// The caps word on the mode badge.
    package static let title = "HINTS"

    /// What VoiceOver calls one badge.
    package static func labelAccessibility(_ label: String) -> String { "Hint \(displayLabel(label))" }

    /// What VoiceOver calls the mode badge.
    package static func badgeAccessibilityLabel(_ intent: HintIntent) -> String {
        "Hint mode \(intent.badgeLabel)"
    }

    /// The mode badge's a11y hint — the two ways out, said once.
    package static let badgeAccessibilityHint = "Press a label, or Escape to exit"

    /// The `×` plate's tooltip. It names the key as well as the action, because the `×` is the fallback
    /// and Esc is the way the mode is actually left.
    package static let exitHelp = "Exit hint mode (Esc)"
}
