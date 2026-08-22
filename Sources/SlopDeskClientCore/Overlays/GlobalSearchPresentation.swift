// GlobalSearchPresentation — what the ⇧⌘F cross-tab results surface IS, for both of the halves that
// draw it, and the mode pills the in-pane find bar shares with it.
//
// The sixth surface off the shared SwiftUI floor (docs/56 stage D): the Mac draws it as an `NSPanel`
// (``SlopDeskMacUI/MacGlobalSearchView``), the phone as a full-height card inside ``OverlayHostView``.
// The match MATH was already shared before this file existed — `GlobalSearchController` runs it and
// `WorkspaceStore.runGlobalSearch` owns the query — so what is here is the reading of a result: how
// the matched run is cut out of its line, the two zero-state lines, and the card's measurements.
//
// ## The excerpt's three pieces
//
// ``excerptSlices(_:)`` is the piece that most looks like layout and is not. A hit's `highlight` is a
// UTF-16 range over a Swift `String`, and mapping one onto the other can FAIL — a range that lands
// inside a surrogate pair has no `String.Index`. The rule is to degrade to a flat excerpt rather than
// to trap, and it has to be one rule: a half that re-derived it would eventually index out of bounds
// on the one line in a scrollback that contains an emoji.

import SlopDeskWorkspaceCore

// MARK: - The mode pills

/// One `Aa` / `ab` / `.*` mode pill, as a VALUE.
///
/// ⚠️ The find bar and the global-search query bar render these pills IDENTICALLY — that is a locked
/// invariant (see ``FindTogglePillTray``'s own note), and the labels and help strings live here so
/// the two surfaces read them rather than agree on them. Three surfaces do now, in fact: the Mac's
/// results panel is AppKit and cannot see a SwiftUI view's call site at all.
public enum FindModePill: String, CaseIterable, Sendable {
    case caseSensitive
    case wholeWord
    case regex

    /// The glyph on the chip.
    public var label: String {
        switch self {
        case .caseSensitive: "Aa"
        case .wholeWord: "ab"
        case .regex: ".*"
        }
    }

    /// The hover/accessibility help.
    public var help: String {
        switch self {
        case .caseSensitive: "Case sensitive"
        case .wholeWord: "Whole word"
        case .regex: "Regex (ICU)"
        }
    }

    /// Whether the glyph is drawn underlined — the whole-word chip's own mark, and nothing else's.
    public var underlined: Bool { self == .wholeWord }

    /// The two the CROSS-TAB search offers. Whole-word is the in-pane find bar's alone: the global
    /// search runs over a scrollback mirror rather than over libghostty's own buffer, and the two
    /// engines do not agree about what a word boundary is.
    public static let globalSearch: [Self] = [.caseSensitive, .regex]

    /// The three the IN-PANE find bar offers, in drawn order: `Aa`, `ab|`, `.*`.
    ///
    /// It lives beside ``globalSearch`` rather than in the find bar's own presentation for the reason
    /// the sentence above gives — the two lists are one DECISION, "which engine can answer which
    /// question", and a reader who wants to know why whole-word is missing upstairs has to be able to
    /// see both lists at once. A subset spelled in another file is a subset that can quietly stop
    /// being one.
    public static let inPaneFindBar: [Self] = [.caseSensitive, .wholeWord, .regex]
}

// MARK: - The card's measurements

/// The results panel's own dimensions on the Mac.
///
/// It is a large card rather than a full-window surface: the workspace behind it is the context the
/// search is ABOUT, and a results panel that covered it would make every hit a jump into the dark.
/// The phone takes the whole sheet instead, which is the same intent at a screen where there is no
/// "behind".
public enum GlobalSearchMetrics {
    public static let panelWidth: Double = 720
    public static let panelHeight: Double = 560
}

// MARK: - Reading a result

/// One excerpt cut into the three runs a row draws: the text before the match, the match, and the
/// text after it.
///
/// A run that could not be placed comes back as the whole line in `before` with the other two empty,
/// which needs no flag at either call site: the two outer runs are drawn in the supporting ink and
/// the middle one is marked, so an empty middle simply marks nothing.
public struct GlobalSearchExcerpt: Equatable, Sendable {
    public let before: String
    public let match: String
    public let after: String
}

public enum GlobalSearchPresentation {
    /// The query bar's prompt. The zero-state lines below already lived here; this one did not, and
    /// stood spelled character for character in both halves' query bars.
    public static let queryPrompt = "Search across all tabs…"

    /// What a group's disclosure ANNOUNCES — the Mac hangs it off the chevron's
    /// `accessibilityDescription`, the phone off `accessibilityValue`, and both said it themselves.
    /// A state a screen reader reads out is copy, and copy is the surface's meaning, not its drawing.
    public static func disclosureState(collapsed: Bool) -> String {
        collapsed ? "Collapsed" : "Expanded"
    }

    /// Cuts `hit`'s excerpt around its highlighted run.
    ///
    /// The range arrives as UTF-16 offsets, pre-clamped into the excerpt's bounds by
    /// ``GlobalSearchController``. Mapping them back onto `String.Index`es can still fail — a
    /// boundary inside a surrogate pair has no character position — and the answer to that is a FLAT
    /// excerpt, never a trap and never a guessed run. Built by slicing and re-joining substrings, so
    /// there is no attributed-string index conversion anywhere on this path to go wrong.
    public static func excerptSlices(_ hit: GlobalSearchHit) -> GlobalSearchExcerpt {
        let excerpt = hit.excerpt
        let utf16 = excerpt.utf16
        guard let lowUTF16 = utf16.index(
            utf16.startIndex, offsetBy: hit.highlight.lowerBound, limitedBy: utf16.endIndex,
        ),
            let highUTF16 = utf16.index(
                utf16.startIndex, offsetBy: hit.highlight.upperBound, limitedBy: utf16.endIndex,
            ),
            let low = lowUTF16.samePosition(in: excerpt),
            let high = highUTF16.samePosition(in: excerpt),
            low <= high
        else { return GlobalSearchExcerpt(before: excerpt, match: "", after: "") }
        return GlobalSearchExcerpt(
            before: String(excerpt[excerpt.startIndex..<low]),
            match: String(excerpt[low..<high]),
            after: String(excerpt[high...]),
        )
    }

    /// The zero-state line: a hint before anything is typed, a verdict once something was.
    ///
    /// The distinction is the whole point of having two — "no results" under an empty field would
    /// report a failure nobody asked for.
    public static func emptyStateLine(query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Search every tab’s scrollback."
            : "No results."
    }

    /// The `N results — M tabs` line, or `nil` when there is nothing to count yet.
    ///
    /// The summary is gated on a NON-EMPTY query rather than on non-empty results: a blank field with
    /// a stale result set behind it would otherwise print a count for a search the user has cleared.
    public static func summary(_ results: GlobalSearchResults?, query: String) -> String? {
        guard let results, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return results.summary
    }
}
