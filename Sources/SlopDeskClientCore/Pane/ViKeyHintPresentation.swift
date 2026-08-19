// ViKeyHintPresentation — the vi / copy-mode reference card as VALUES: the three hint tables, their
// headings, the pill's wording, and the arithmetic that decides how the card re-flows.
//
// THE TABLES ARE THE HONESTY SURFACE. The card lists ONLY the keys
// ``TerminalViewModel/handleCopyModeKey(_:)`` actually wires — a faithful subset of full vi — and
// ``advertisedKeys`` is what a test reads to prove it (`ViKeyHintPresentationTests`). Since the E17 LIFT
// (DECISIONS.md 2026-07-14: the fork gained a set-selection / viewport-info ABI) that subset includes
// the cursor motions `h`/`l`, `w`/`b`/`e`, `0`/`^`/`$`, plus the visual anchor-swap `o` and the `Y`
// line-yank, all previously omitted as unwired. Still deliberately absent: `H`/`M`/`L` (screen-relative
// jumps, not wired). `f` arms Hint Mode, which is its own overlay over its own seam
// (``TerminalViewModel/beginHint(_:)``).
//
// THE REFLOW IS ARITHMETIC, NOT A `ViewThatFits`. The card used to ask "which of my three layouts
// fits?" by BUILDING all three and measuring them, which is the same question — and the same cost —
// `PanelTabs.labelling(available:cell:gap:named:selected:)` was rewritten as arithmetic for in
// increment 51. Two reasons it has to be arithmetic here too. `ViewThatFits` has no AppKit equivalent
// at all, so an AppKit card could only re-derive the ladder from this file's prose; and a candidate
// that is BUILT is a candidate that exists — every row, every keycap, three times — to answer a
// question about width. Said as a comparison it is one answer, both frameworks ask it the same way,
// and the RUNG BOUNDARIES are pinnable without mounting anything.

import Foundation
import SlopDeskWorkspaceCore

// MARK: - One row of the card

/// One reference entry: the key chip(s) and what they do.
package struct ViKeyHint: Identifiable, Equatable, Sendable {
    package let keys: [String]
    package let label: String

    /// Keys and label together, because two rows can share either one alone (`n`/`N` and `y`/`↩` both
    /// carry two chips; "Visual" and "Visual line" both name a visual mode).
    package var id: String { keys.joined(separator: " ") + "|" + label }

    package init(keys: [String], label: String) {
        self.keys = keys
        self.label = label
    }
}

// MARK: - The three columns

/// The card's three columns, in their drawn order.
package enum ViKeyHintColumn: String, CaseIterable, Sendable {
    case motion
    case selection
    case search

    /// The column's caps heading.
    package var heading: String {
        switch self {
        case .motion: "MOTION"
        case .selection: "SELECT"
        case .search: "SEARCH"
        }
    }

    /// The column's rows.
    package var hints: [ViKeyHint] {
        switch self {
        case .motion: ViKeyHintPresentation.motion
        case .selection: ViKeyHintPresentation.selection
        case .search: ViKeyHintPresentation.search
        }
    }
}

// MARK: - How the card re-flows

/// Which of the three arrangements the card's width affords.
///
/// The middle rung exists because MOTION is the tall column (eight rows against seven and five): at a
/// width that cannot take three columns, stacking the two SHORT ones beside it costs less height than
/// stacking all three, and a narrow split pane still gets the whole card rather than a clipped one.
package enum ViKeyHintLayout: Equatable, Sendable {
    /// MOTION | SELECT | SEARCH.
    case threeColumns
    /// MOTION beside SELECT-over-SEARCH.
    case motionBesideStack
    /// One tall column.
    case oneColumn
}

// MARK: - The card's words and its ladder

package enum ViKeyHintPresentation {
    // MARK: The tables

    package static let motion: [ViKeyHint] = [
        ViKeyHint(keys: ["h", "j", "k", "l"], label: "Move cursor"),
        ViKeyHint(keys: ["w", "b", "e"], label: "Word motions"),
        ViKeyHint(keys: ["0", "^", "$"], label: "Line start / end"),
        ViKeyHint(keys: ["⌃d", "⌃u"], label: "Half page"),
        ViKeyHint(keys: ["⌃f", "⌃b"], label: "Full page"),
        ViKeyHint(keys: ["g", "G"], label: "Top / bottom"),
        ViKeyHint(keys: ["[", "]"], label: "Prev / next prompt"),
        ViKeyHint(keys: ["1", separator, "9"], label: "Repeat count"),
    ]

    /// Every row here is WIRED (the honesty rule): the cursor motions + `o` + `Y` joined the card with
    /// the E17 ceiling lift; `f` rides the Hint Mode overlay via `beginHint`, its own seam.
    package static let selection: [ViKeyHint] = [
        ViKeyHint(keys: ["v"], label: "Visual"),
        ViKeyHint(keys: ["V"], label: "Visual line"),
        ViKeyHint(keys: ["⌃v"], label: "Visual block"),
        ViKeyHint(keys: ["o"], label: "Swap ends"),
        ViKeyHint(keys: ["y", "↩"], label: "Yank + exit"),
        ViKeyHint(keys: ["Y"], label: "Yank line"),
        ViKeyHint(keys: ["f"], label: "Hint links"),
    ]

    package static let search: [ViKeyHint] = [
        ViKeyHint(keys: ["/"], label: "Find forward"),
        ViKeyHint(keys: ["?"], label: "Find backward"),
        ViKeyHint(keys: ["n", "N"], label: "Next / prev match"),
        ViKeyHint(keys: ["Esc", "q"], label: "Exit vi mode"),
        ViKeyHint(keys: ["⌘/"], label: "Toggle this bar"),
    ]

    /// The RANGE token. It sits in a `keys` array so `1 … 9` reads as one row, but it is not a key: a
    /// renderer draws it as bare text rather than as a chip, and ``advertisedKeys`` filters it out so
    /// the honesty test never has to know about it.
    package static let separator = "…"

    /// Every key chip the card advertises, flattened across all three columns with the separator
    /// dropped — the honesty surface a test reads to prove the card lists ONLY wired keys (e.g. never
    /// the once-dead `o`). The renderers draw from the SAME tables, so this cannot drift from what is
    /// shown.
    package static var advertisedKeys: [String] {
        (motion + selection + search).flatMap(\.keys).filter { $0 != separator }
    }

    // MARK: The pill

    /// The pill's combined a11y label, so VoiceOver reads "Vi mode VISUAL 5".
    package static func accessibilityLabel(mode: TerminalViewModel.VisualMode, count: Int?) -> String {
        var parts = ["Vi mode", mode.pillLabelOrDefault]
        if let count { parts.append(String(count)) }
        return parts.joined(separator: " ")
    }

    /// The pill's a11y hint, and the `×` plate's tooltip — one string, because they name one action.
    package static let exitHelp = "Exit vi mode"

    /// What VoiceOver calls the card as a whole.
    package static let barAccessibilityLabel = "Vi mode key hints"

    // MARK: The width ladder

    /// Which arrangement a card of `available` points can afford.
    ///
    /// `columnWidth` is what ONE column costs at its intrinsic width — its widest row, chips, gap and
    /// label together — asked of the caller because only the renderer can measure its own type. That is
    /// the same division of labour ``PanelTabs/labelling(available:cell:gap:named:selected:)`` uses, and
    /// for the same reason: the DECISION is shared, the measurement is the framework's.
    ///
    /// `gap` is the space between two side-by-side columns. The stacked rung is measured against the
    /// WIDER of the two short columns, because a `VStack` is as wide as its widest child — the same
    /// arithmetic `ViewThatFits` was doing by building the thing and asking it.
    package static func layout(
        forWidth available: Double,
        gap: Double,
        columnWidth: (ViKeyHintColumn) -> Double,
    ) -> ViKeyHintLayout {
        let motionWidth = columnWidth(.motion)
        let selectionWidth = columnWidth(.selection)
        let searchWidth = columnWidth(.search)
        if motionWidth + selectionWidth + searchWidth + gap * 2 <= available { return .threeColumns }
        if motionWidth + Swift.max(selectionWidth, searchWidth) + gap <= available { return .motionBesideStack }
        return .oneColumn
    }

    /// The columns each of the layout's slots draws, in order.
    ///
    /// Returning the arrangement as a list of COLUMN GROUPS rather than as three hand-written bodies is
    /// what keeps the two renderers from disagreeing about which column got stacked with which: one
    /// group is one horizontal slot, and the columns inside it stack vertically.
    package static func groups(for layout: ViKeyHintLayout) -> [[ViKeyHintColumn]] {
        switch layout {
        case .threeColumns: [[.motion], [.selection], [.search]]
        case .motionBesideStack: [[.motion], [.selection, .search]]
        case .oneColumn: [[.motion, .selection, .search]]
        }
    }
}
