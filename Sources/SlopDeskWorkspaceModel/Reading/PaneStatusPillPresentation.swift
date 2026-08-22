// PaneStatusPillPresentation — the pane's top-trailing status chips as VALUES: which of them are up,
// in what order, and what each one says.
//
// The three pills were ONE shape spelled three times. `PaneStatusPills.swift` held a lock chip, a
// secure-input chip and a sync-input chip that differed in a word, a glyph, two sentences of
// accessibility copy, whether they carried an `×`, and whether their fill was the chrome plate or a
// fixed vivid tone — and agreed about everything else, including the two `static var fillColor: Color`
// escape hatches that existed so a test could read what the view drew. Two of the three had one; the
// third did not, which is exactly the drift a shape-spelled-three-times produces.
//
// THE FILL IS A KIND, NOT A COLOUR. `SlopDeskClientCore` sits below the token floor and draws nothing,
// so what crosses is "chrome plate with a hairline" or "a fixed, theme-independent tone with no
// border", and each renderer resolves that to its own `Color` / `NSColor`. That is not a formality: the
// whole POINT of the two vivid pills is that their tone is theme-INDEPENDENT — the shipped themes have
// `info == accent`, so a security badge derived from the palette goes invisible against the accent —
// and a decision recorded as a colour literal could not say that, only be it.
//
// THE ORDER IS A LIST, NOT A `VStack`. The four gates and the top-down stacking were spelled inside
// `TerminalLeafView`'s body, where only one of the two halves can reach them; an AppKit column would
// have re-derived "read-only hides under vi, secure input hides under read-only, sync input hides under
// nothing" from the same prose and been right by luck.

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

    /// The uppercase word on the chip.
    package var label: String {
        switch self {
        case .readOnly: "READ ONLY"
        case .secureInput: "SECURE INPUT"
        case .syncInput: "SYNC INPUT"
        }
    }

    /// What VoiceOver reads for the chip itself.
    package var accessibilityLabel: String {
        switch self {
        case .readOnly: "Read only"
        case .secureInput: "Secure input"
        case .syncInput: "Sync input"
        }
    }

    /// The sentence that says what the mode DOES — the part a badge alone cannot.
    package var accessibilityHint: String {
        switch self {
        case .readOnly: "Disable read-only mode to allow input again"
        case .secureInput: "Secure keyboard entry is active — other apps cannot read your keystrokes"
        case .syncInput: "Keystrokes typed here are mirrored into every other pane in this tab"
        }
    }

    /// The `×` plate's tooltip, or `nil` for a pill that carries no `×`.
    ///
    /// Secure input has none, and that is a decision rather than an omission: it is a SAFETY indicator
    /// the user does not dismiss with a click. The auto path clears when the password prompt ends and
    /// the manual path clears from the Edit menu or the palette, so a `×` here would offer to turn off
    /// something this chip does not own.
    package var dismissHelp: String? {
        switch self {
        case .readOnly: "Disable read-only"
        case .secureInput: nil
        case .syncInput: "Turn off sync input for this tab"
        }
    }

    /// Whether the chip carries an `×`.
    package var isDismissible: Bool { dismissHelp != nil }

    /// The plate this chip stands on.
    package var fill: PaneStatusPillFill {
        switch self {
        case .readOnly: .chrome
        case .secureInput: .fixed(.security)
        case .syncInput: .fixed(.sync)
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
}

package enum PaneStatusPillPresentation {
    /// The chips that are up, TOP-DOWN in the order they stack in the pane's trailing corner.
    ///
    /// Three exclusions, and each is a rule rather than a preference:
    ///
    /// - READ-ONLY steps aside under vi/copy mode. Copy mode's keybindings drive a selection rather than
    ///   the shell, so the lock is not what the user is being told about; the lock itself stays on and
    ///   the chip returns the moment copy mode exits.
    /// - SECURE INPUT steps aside under read-only. No input path can fire there, so the cue is moot.
    /// - SYNC INPUT steps aside for NOTHING, and that asymmetry is the point. The mode leaks INTO this
    ///   pane from its siblings regardless of this pane's own input gate, so a gate that hid it would
    ///   hide a cross-pane input leak the user cannot otherwise explain (field report: two same-project
    ///   panes "leaking into each other" with the armed state unsurfaced).
    ///
    /// The order puts the two gated chips above the ungated one so a chip appearing or leaving never
    /// makes the safety warning jump.
    package static func visible(_ conditions: PaneStatusConditions) -> [PaneStatusPill] {
        var pills: [PaneStatusPill] = []
        if conditions.readOnly, !conditions.copyMode { pills.append(.readOnly) }
        if conditions.secureInput, conditions.secureInputIndicator, !conditions.readOnly {
            pills.append(.secureInput)
        }
        if conditions.syncInput { pills.append(.syncInput) }
        return pills
    }

    /// Whether the vi/copy-mode pill stands ABOVE ``visible(_:)``'s chips.
    ///
    /// It is mutually exclusive with the read-only chip by construction (that one is gated on
    /// `!copyMode`), so the two never fight for the top slot. What it also has to yield to is HINT MODE:
    /// the `HINTS` badge owns the same corner from a different overlay, and without this gate the two
    /// drew on top of each other. One corner, one mode chip.
    package static func showsViModePill(_ conditions: PaneStatusConditions) -> Bool {
        conditions.copyMode && !conditions.hintMode
    }

    /// Whether the vi key-hint bar stands along the pane's BOTTOM: in vi mode, with the per-session `⌘/`
    /// toggle on. The copy-mode gate makes teardown unconditional, so the card can never linger after vi
    /// mode exits.
    package static func showsViKeyHintBar(_ conditions: PaneStatusConditions, hintsToggled: Bool) -> Bool {
        conditions.copyMode && hintsToggled
    }
}
