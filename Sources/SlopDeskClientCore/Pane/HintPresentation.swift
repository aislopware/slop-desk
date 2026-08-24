// HintPresentation — the near-side FACE of `slopdesk_workspace::hint_overlay`.
//
// The MATH was already below the view before this file existed: ``HintLabelAssigner/targets(rows:cwd:schemes:patterns:maxScanColumns:)``
// finds the spans, ``HintLabelAssigner`` assigns the two-letter labels and filters them against what has been typed, and
// ``TerminalCellMetrics`` turns a cell into a rect. What was still spelled inside the SwiftUI overlay is
// everything between that math and the ink — which badge is faded, which is dimmed, whether the overlay
// is up at all, and every word it says. That is what crossed.
//
// THE PER-LETTER FADE IS THE PIECE THAT LOOKS LIKE LAYOUT AND IS NOT. A label is two characters and the
// overlay draws them in two different inks — the already-typed prefix faded, the rest solid — so the
// user can see which key is next. Said as `offset < typed.count` it is one rule; re-derived per renderer
// it is a place where a half could fade the wrong letter and still look plausible, because on the very
// common case (nothing typed yet) both spellings agree.
//
// The badge's plate is a FIXED yellow with BLACK text — theme-independent so it reads over any terminal
// background, the same rationale the secure-input pill's fixed blue carries. That is a token decision,
// so it stays with the renderers; what crosses is which INK ROLE each letter takes, not which colour.
//
// ``matchedLabels(typed:labels:)`` stays on this side: it is a thin call onto ``HintLabelAssigner``,
// which is the ASSIGNER's own door (`slopdesk_ws_hint_*`) and not this module's.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

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
    /// the point the question is asked, and `0` is exactly what "no snapshot" looks like.
    package static func isArmed(intent: HintIntent?, cellWidth: Double, cellHeight: Double) -> Bool {
        slopdesk_ws_hint_overlay_is_armed(intent != nil, cellWidth, cellHeight)
    }

    // MARK: - Reading a label

    /// The label AS DRAWN. Hint labels are assigned lowercase and always shown uppercase — a two-letter
    /// badge over terminal output has to be read at a glance, and mixed case at 10pt on a yellow plate is
    /// not.
    package static func displayLabel(_ label: String) -> String { badge(label: label, intent: "")[0] }

    /// Whether the character at `offset` of a label has already been typed, and so draws faded.
    ///
    /// The comparison is against the typed prefix's LENGTH rather than against its characters: hint
    /// labels are ASCII by construction (``HintLabelAssigner``'s alphabet), and comparing lengths keeps
    /// the rule honest for a partially-typed label that no longer matches at all — those badges are
    /// dimmed as a whole by ``dimmed(label:matched:)``, and a dimmed badge showing its first letter
    /// faded is exactly the progress cue that was wanted.
    package static func isFaded(offset: Int, typed: String) -> Bool {
        let bytes = Array(typed.utf8)
        return bytes.withUnsafeBufferPointer { borrowed in
            slopdesk_ws_hint_overlay_is_faded(offset, borrowed.baseAddress, borrowed.count)
        }
    }

    /// The labels the typed prefix still admits — a set, because every badge asks about itself.
    ///
    /// The assigner's own filter, not this module's rule: which labels survive a prefix is the same
    /// question ``HintLabelAssigner`` answers when it assigns them.
    package static func matchedLabels(typed: String, labels: [String]) -> Set<String> {
        Set(HintLabelAssigner.filter(typed: typed, labels: labels).matched)
    }

    /// Whether a badge is DIMMED: the typed prefix has ruled its label out.
    ///
    /// Ruled-out badges are dimmed rather than removed. A label that vanished would let the eye think a
    /// target had gone away, and the remaining badges would then have to be re-read from scratch after
    /// every keystroke; dimmed, the field the user is scanning stays where it was.
    package static func dimmed(label: String, matched: Set<String>) -> Bool {
        var arena = WsStrings()
        let spans = matched.map { arena.span($0) }
        let labelBytes = Array(label.utf8)
        return labelBytes.withUnsafeBufferPointer { name in
            spans.withUnsafeBufferPointer { kept in
                arena.bytes.withUnsafeBufferPointer { blob in
                    slopdesk_ws_hint_overlay_dimmed(
                        name.baseAddress, name.count,
                        kept.baseAddress, kept.count,
                        blob.baseAddress, blob.count,
                    )
                }
            }
        }
    }

    // MARK: - The words

    /// The caps word on the mode badge.
    package static var title: String { words[0] }

    /// What VoiceOver calls one badge.
    package static func labelAccessibility(_ label: String) -> String { badge(label: label, intent: "")[1] }

    /// What VoiceOver calls the mode badge.
    package static func badgeAccessibilityLabel(_ intent: HintIntent) -> String {
        badge(label: "", intent: intent.badgeLabel)[2]
    }

    /// The mode badge's a11y hint — the two ways out, said once.
    package static var badgeAccessibilityHint: String { words[1] }

    /// The `×` plate's tooltip. It names the key as well as the action, because the `×` is the fallback
    /// and Esc is the way the mode is actually left.
    package static var exitHelp: String { words[2] }

    /// The three fixed words in ONE crossing, once per process.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_hint_overlay_words(out, cap)) },
        count: 3,
    )

    /// A badge's three readings — as drawn, as VoiceOver reads the badge, as VoiceOver reads the mode.
    /// All three derive from the same pair, so they ride together when a badge is built.
    private static func badge(label: String, intent: String) -> [String] {
        let (name, mode) = (Array(label.utf8), Array(intent.utf8))
        let blob = name.withUnsafeBufferPointer { name in
            mode.withUnsafeBufferPointer { mode in
                wsAnswerBytes { out, cap in
                    Int(slopdesk_ws_hint_overlay_badge(
                        name.baseAddress, name.count,
                        mode.baseAddress, mode.count,
                        out, cap,
                    ))
                }
            }
        }
        return wsRuns(blob, count: 3)
    }
}
