// PaneStatusPillPresentation — the near-side FACE of `slopdesk_workspace::status_pill`.
//
// The rules moved: which chips are up under which gates, what each one says, whether it carries an
// `×`, and what plate it stands on are all decided in Rust now and reach here through the four doors
// `docs/55` §6 describes — the classifiers as SCALARS (six gates in one byte, three chips out in
// another), the words as a GROUP (one crossing per chip rather than four).
//
// What stays on this side is the vocabulary the renderers diff against. ``PaneStatusPill`` and
// ``PaneStatusPillFill`` are Swift enums because 262 files pattern-match them and SwiftUI decides
// what to redraw from their `Equatable`; the KIND is what crosses, never a `Color`, so each renderer
// still resolves "the chrome plate" or "the fixed security tone" to its own type. That is not a
// formality: the shipped themes have `info == accent`, so a security badge derived from the palette
// goes invisible against the accent, and only a named tone can say so.
//
// Every string is read ONCE into a `static let` — `SettingsCatalog` measured what a door per string
// inside a SwiftUI body costs, and these chips re-render on every keystroke in a synced tab.

import CSlopDeskFFI
import Foundation

// MARK: - What a pill is filled with

/// The theme-independent tones the vivid pills wear. Named, never valued — see the file header.
package enum PaneStatusPillInk: Equatable, Sendable {
    /// The fixed security blue. A SAFETY signal that must never collapse into the theme accent.
    case security
    /// The fixed sync amber. A mode this dangerous never blends with the chrome.
    case sync
}

/// How a pill's plate is drawn.
package enum PaneStatusPillFill: Equatable, Sendable {
    /// The chrome plate: the raised surface plus a subtle hairline. It BLENDS with the chrome rather
    /// than standing out — `readonly-mode.png`'s "bordered or subtly filled chip rather than a brightly
    /// coloured badge".
    case chrome
    /// A fixed vivid tone and NO border: the fill is loud enough that a hairline would only muddy it.
    case fixed(PaneStatusPillInk)

    /// The plate `code` names — `slopdesk_ws_status_pill_fill`'s answer.
    ///
    /// A code no chip has cannot happen: the only caller feeds it a ``PaneStatusPill``'s own index.
    /// It falls back to the chrome plate rather than trapping, because a chip drawn on the quiet
    /// plate is a smaller wrong than a crash inside a view body.
    init(code: UInt8) {
        switch code {
        case 1: self = .fixed(.security)
        case 2: self = .fixed(.sync)
        default: self = .chrome
        }
    }
}

// MARK: - The three pills

/// One pane status chip, as a value.
///
/// The vi/copy-mode pill is deliberately NOT a case here: its label is the MODEL's
/// (`VI` / `VISUAL` / `VISUAL LINE` / `VISUAL BLOCK`, plus a live repeat count), so it is a reading of
/// pane state rather than a constant, and it lives in ``ViKeyHintPresentation`` with the rest of vi
/// mode. Its place in the stack is still decided here — see ``PaneStatusPillPresentation/showsViModePill(_:)``.
package enum PaneStatusPill: String, CaseIterable, Sendable {
    case readOnly
    case secureInput
    case syncInput

    /// The chip's own index, which is both the door's argument and its bit in the visible mask.
    var index: UInt8 {
        switch self {
        case .readOnly: 0
        case .secureInput: 1
        case .syncInput: 2
        }
    }

    /// The uppercase word on the chip.
    package var label: String { Self.words[self]?.label ?? "" }

    /// What VoiceOver reads for the chip itself.
    package var accessibilityLabel: String { Self.words[self]?.accessibilityLabel ?? "" }

    /// The sentence that says what the mode DOES — the part a badge alone cannot.
    package var accessibilityHint: String { Self.words[self]?.accessibilityHint ?? "" }

    /// The `×` plate's tooltip, or `nil` for a pill that carries no `×`.
    ///
    /// Secure input has none, and that is a decision rather than an omission the far side records:
    /// it is a SAFETY indicator the user does not dismiss with a click.
    package var dismissHelp: String? { Self.words[self]?.dismissHelp }

    /// Whether the chip carries an `×`.
    ///
    /// Read from the delivery's own flag rather than from `dismissHelp != nil`, so the near side
    /// cannot disagree with the far one about a chip whose tooltip is empty.
    package var isDismissible: Bool { Self.words[self]?.isDismissible ?? false }

    /// The plate this chip stands on.
    package var fill: PaneStatusPillFill { Self.fills[self] ?? .chrome }

    // MARK: Read once

    /// Everything the three chips say, in three crossings, once per process.
    private static let words: [Self: Words] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { pill in Words(pill).map { (pill, $0) } },
    )

    /// The three plates, in three crossings, once per process.
    private static let fills: [Self: PaneStatusPillFill] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, PaneStatusPillFill(code: slopdesk_ws_status_pill_fill($0.index))) },
    )

    /// One chip's delivery: `[u8 is_dismissible]` then four runs.
    private struct Words {
        let isDismissible: Bool
        let label: String
        let accessibilityLabel: String
        let accessibilityHint: String
        let dismissHelp: String?

        /// `nil` for an index no chip has — §4's `0`, which cannot happen from ``allCases``.
        init?(_ pill: PaneStatusPill) {
            let blob = wsAnswerBytes { out, cap in
                Int(slopdesk_ws_status_pill_words(pill.index, out, cap))
            }
            guard let flag = blob.first else { return nil }
            let text = wsRuns(Array(blob.dropFirst()), count: 4)
            isDismissible = flag == 1
            label = text[0]
            accessibilityLabel = text[1]
            accessibilityHint = text[2]
            // A zero-length tooltip is NO tooltip; the flag beside it says the same thing, and the
            // far side derives that flag from the string's presence, so the two agree by construction.
            dismissHelp = text[3].isEmpty ? nil : text[3]
        }
    }
}

// MARK: - Which pills are up, and in what order

/// Everything the four gates read, taken once per render so the decision below is pure.
package struct PaneStatusConditions: Equatable, Sendable {
    /// The pane's input gate is armed (`TerminalViewModel.readOnlyBadgeActive`).
    package var readOnly: Bool
    /// The pane is in vi / copy mode (`TerminalViewModel.copyModeBadgeActive`).
    package var copyMode: Bool
    /// Hint mode is armed on top of vi mode (`TerminalViewModel.hintMode != nil`).
    package var hintMode: Bool
    /// macOS Secure Keyboard Entry is active for this pane.
    package var secureInput: Bool
    /// The "Show Secure Input Indicator" setting is on.
    package var secureInputIndicator: Bool
    /// The pane's TAB is armed for synchronized input.
    package var syncInput: Bool

    package init(
        readOnly: Bool = false,
        copyMode: Bool = false,
        hintMode: Bool = false,
        secureInput: Bool = false,
        secureInputIndicator: Bool = false,
        syncInput: Bool = false,
    ) {
        self.readOnly = readOnly
        self.copyMode = copyMode
        self.hintMode = hintMode
        self.secureInput = secureInput
        self.secureInputIndicator = secureInputIndicator
        self.syncInput = syncInput
    }

    /// The six gates in one byte, low bit first — the order both doors declare.
    var bits: UInt8 {
        var bits: UInt8 = 0
        if readOnly { bits |= 1 << 0 }
        if copyMode { bits |= 1 << 1 }
        if hintMode { bits |= 1 << 2 }
        if secureInput { bits |= 1 << 3 }
        if secureInputIndicator { bits |= 1 << 4 }
        if syncInput { bits |= 1 << 5 }
        return bits
    }
}

package enum PaneStatusPillPresentation {
    /// The chips that are up, TOP-DOWN in the order they stack in the pane's trailing corner.
    ///
    /// The three exclusions and the order live in `slopdesk_workspace::status_pill`; the mask that
    /// comes back is over ``PaneStatusPill``'s own index, low bit first, and low-bit-first IS the
    /// top-down stacking order — so a filter over `allCases` rebuilds the list without restating it.
    package static func visible(_ conditions: PaneStatusConditions) -> [PaneStatusPill] {
        let mask = slopdesk_ws_status_pills(conditions.bits)
        return PaneStatusPill.allCases.filter { mask & (1 << $0.index) != 0 }
    }

    /// Whether the vi/copy-mode pill stands ABOVE ``visible(_:)``'s chips.
    package static func showsViModePill(_ conditions: PaneStatusConditions) -> Bool {
        slopdesk_ws_status_pill_gates(conditions.bits, false) & 1 != 0
    }

    /// Whether the vi key-hint bar stands along the pane's BOTTOM: in vi mode, with the per-session `⌘/`
    /// toggle on.
    package static func showsViKeyHintBar(_ conditions: PaneStatusConditions, hintsToggled: Bool) -> Bool {
        slopdesk_ws_status_pill_gates(conditions.bits, hintsToggled) & 2 != 0
    }
}
