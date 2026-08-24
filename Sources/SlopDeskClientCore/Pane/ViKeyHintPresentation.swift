// ViKeyHintPresentation — the near-side FACE of `slopdesk_workspace::vi_hints`.
//
// THE TABLES ARE THE HONESTY SURFACE, and they moved. The card lists ONLY the keys
// ``TerminalViewModel/handleCopyModeKey(_:)`` actually wires — a faithful subset of full vi — and the
// subset itself is now `slopdesk_workspace::vi_hints`'s three tables, with ``advertisedKeys`` still the
// flattening a test reads to prove it. What that buys is a table one language can drift from instead
// of two: since the E17 LIFT (DECISIONS.md 2026-07-14) the subset includes `h`/`l`, `w`/`b`/`e`,
// `0`/`^`/`$`, the visual anchor-swap `o` and the `Y` line-yank; still deliberately absent are
// `H`/`M`/`L`. `f` arms Hint Mode, which is its own overlay over its own seam.
//
// THE REFLOW IS ARITHMETIC, NOT A `ViewThatFits`, and now it is arithmetic on the far side. The
// renderer MEASURES — only it can ask its own type what a column costs at its intrinsic width — and
// the shared rule DECIDES, which is the same division of labour ``PanelTabs`` uses. `ViewThatFits`
// has no AppKit equivalent at all, so an AppKit card could only re-derive the ladder from prose; and
// a candidate that is BUILT is a candidate that exists — every row, every keycap, three times — to
// answer a question about width.
//
// A COLUMN crosses in ONE delivery rather than a door per string: twenty rows across three columns is
// sixty-eight strings, inside a view body that re-runs whenever the card's width changes. The rows
// are then read ONCE into a `static let`, so every later render pays an array subscript.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

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

    /// The column's own index, which is what both the column door and the group bytes speak in.
    var index: UInt8 {
        switch self {
        case .motion: 0
        case .selection: 1
        case .search: 2
        }
    }

    /// The column at `index`, or `nil` for a byte no column has.
    static func at(_ index: UInt8) -> Self? {
        allCases.first { $0.index == index }
    }

    /// The column's caps heading.
    package var heading: String { ViKeyHintPresentation.heading(of: self) }

    /// The column's rows.
    package var hints: [ViKeyHint] { ViKeyHintPresentation.rows[self] ?? [] }
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

    /// The rung `code` names; anything past the end is the one that always fits.
    init(code: UInt8) {
        switch code {
        case 0: self = .threeColumns
        case 1: self = .motionBesideStack
        default: self = .oneColumn
        }
    }

    /// The byte the group door reads this rung as.
    var code: UInt8 {
        switch self {
        case .threeColumns: 0
        case .motionBesideStack: 1
        case .oneColumn: 2
        }
    }
}

// MARK: - The card's words and its ladder

package enum ViKeyHintPresentation {
    // MARK: The tables

    package static var motion: [ViKeyHint] { ViKeyHintColumn.motion.hints }
    package static var selection: [ViKeyHint] { ViKeyHintColumn.selection.hints }
    package static var search: [ViKeyHint] { ViKeyHintColumn.search.hints }

    /// The three tables, in three crossings, once per process.
    static let rows: [ViKeyHintColumn: [ViKeyHint]] = Dictionary(
        uniqueKeysWithValues: ViKeyHintColumn.allCases.map { ($0, hints(of: $0)) },
    )

    /// One column's delivery: `[u16 BE rows]`, then two runs per row — the chips joined by U+001F,
    /// then the label.
    ///
    /// The separator cannot collide with the data: every chip in these tables is a single key or a
    /// two-character chord, and none of them can contain a control character.
    private static func hints(of column: ViKeyHintColumn) -> [ViKeyHint] {
        let blob = wsAnswerBytes { out, cap in Int(slopdesk_ws_vi_hint_column(column.index, out, cap)) }
        guard blob.count >= 2 else { return [] }
        let count = Int(blob[0]) << 8 | Int(blob[1])
        let text = wsRuns(Array(blob.dropFirst(2)), count: count * 2)
        return (0..<count).map { row in
            ViKeyHint(keys: text[row * 2].split(separator: chipSeparator).map(String.init), label: text[row * 2 + 1])
        }
    }

    /// U+001F, the unit separator the far side joins a row's chips with.
    private static let chipSeparator: Character = "\u{1f}"

    /// The RANGE token. It sits in a `keys` array so `1 … 9` reads as one row, but it is not a key: a
    /// renderer draws it as bare text rather than as a chip, and ``advertisedKeys`` filters it out so
    /// the honesty test never has to know about it.
    package static var separator: String { words[0] }

    /// Every key chip the card advertises, flattened across all three columns with the separator
    /// dropped — the honesty surface a test reads to prove the card lists ONLY wired keys (e.g. never
    /// the once-dead `o`). The renderers draw from the SAME tables, so this cannot drift from what is
    /// shown.
    package static var advertisedKeys: [String] {
        ViKeyHintColumn.allCases.flatMap(\.hints).flatMap(\.keys).filter { $0 != separator }
    }

    // MARK: The pill

    /// The pill's combined a11y label, so VoiceOver reads "Vi mode VISUAL 5".
    ///
    /// The word on the pill and the sentence built from it come back in ONE delivery, because a
    /// caller that asked separately could print a label the announcement does not match.
    package static func accessibilityLabel(mode: TerminalViewModel.VisualMode, count: Int?) -> String {
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_ws_vi_mode_words(mode.index, UInt32(count ?? 0), count != nil, out, cap))
        }
        return wsRuns(blob, count: 2)[1]
    }

    /// The pill's a11y hint, and the `×` plate's tooltip — one string, because they name one action.
    package static var exitHelp: String { words[1] }

    /// What VoiceOver calls the card as a whole.
    package static var barAccessibilityLabel: String { words[2] }

    /// The heading over `column`.
    static func heading(of column: ViKeyHintColumn) -> String { words[3 + Int(column.index)] }

    /// The card's six fixed words, in ONE crossing, once per process: the range token, the exit help,
    /// the card's own accessibility label, then the three headings in drawn order.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_vi_hint_words(out, cap)) },
        count: 6,
    )

    // MARK: The width ladder

    /// Which arrangement a card of `available` points can afford.
    ///
    /// `columnWidth` is what ONE column costs at its intrinsic width — its widest row, chips, gap and
    /// label together — asked of the caller because only the renderer can measure its own type.
    ///
    /// `gap` is the space between two side-by-side columns. The stacked rung is measured against the
    /// WIDER of the two short columns, because a `VStack` is as wide as its widest child — the same
    /// arithmetic `ViewThatFits` was doing by building the thing and asking it.
    package static func layout(
        forWidth available: Double,
        gap: Double,
        columnWidth: (ViKeyHintColumn) -> Double,
    ) -> ViKeyHintLayout {
        ViKeyHintLayout(code: slopdesk_ws_vi_hint_layout(
            available,
            gap,
            columnWidth(.motion),
            columnWidth(.selection),
            columnWidth(.search),
        ))
    }

    /// The columns each of the layout's slots draws, in order.
    ///
    /// Returning the arrangement as a list of COLUMN GROUPS rather than as three hand-written bodies is
    /// what keeps the two renderers from disagreeing about which column got stacked with which: one
    /// group is one horizontal slot, and the columns inside it stack vertically.
    ///
    /// The delivery is `[u8 groups]` then, per group, `[u8 columns]` and that many column indices —
    /// bytes rather than runs, because every value in it is a small index.
    package static func groups(for layout: ViKeyHintLayout) -> [[ViKeyHintColumn]] {
        groupings[Int(layout.code)] ?? []
    }

    /// The three arrangements, in three crossings, once per process. Keyed by rung code, which is
    /// contiguous from zero.
    private static let groupings: [Int: [[ViKeyHintColumn]]] = Dictionary(
        uniqueKeysWithValues: [ViKeyHintLayout.threeColumns, .motionBesideStack, .oneColumn]
            .map { (Int($0.code), grouping(of: $0)) },
    )

    private static func grouping(of layout: ViKeyHintLayout) -> [[ViKeyHintColumn]] {
        let blob = wsAnswerBytes { out, cap in Int(slopdesk_ws_vi_hint_groups(layout.code, out, cap)) }
        var cursor = 1
        return (0..<Int(blob.first ?? 0)).compactMap { _ in
            guard cursor < blob.count else { return nil }
            let width = Int(blob[cursor])
            cursor += 1
            guard cursor + width <= blob.count else { return nil }
            defer { cursor += width }
            return blob[cursor..<(cursor + width)].compactMap(ViKeyHintColumn.at)
        }
    }
}
