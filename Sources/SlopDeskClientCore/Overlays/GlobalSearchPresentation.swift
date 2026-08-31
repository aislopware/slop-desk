// GlobalSearchPresentation — the near-side FACE of `slopdesk_workspace::global_search`.
//
// The sixth surface off the shared SwiftUI floor (docs/56 stage D): the Mac draws it as an `NSPanel`
// (``SlopDeskMacUI/MacGlobalSearchView``), the phone as a full-height ``SlopDeskPhoneUI/PhoneGlobalSearchCardView``
// inside ``SlopDeskPhoneUI/PhoneOverlayCardHostView``.
// The match MATH was already shared before this file existed — `GlobalSearchController` runs it and
// `WorkspaceStore.runGlobalSearch` owns the query — so what crossed is the reading of a result: how
// the matched run is cut out of its line, the two zero-state lines, and the card's measurements.
//
// ## The excerpt crosses as OFFSETS, not as three strings
//
// ``excerptSlices(_:)`` is the piece that most looks like layout and is not. A hit's `highlight` is a
// UTF-16 range over a Swift `String`, and mapping one onto UTF-8 can FAIL — a boundary that lands
// inside a surrogate pair names no character position. The rule is to degrade to a flat excerpt
// rather than to trap, and it has to be ONE rule: a half that re-derived it would eventually index
// out of bounds on the one line in a scrollback that contains an emoji.
//
// Returning three substrings would copy the excerpt twice and hand back slices the caller did not
// cut. The door answers two BYTE OFFSETS and a bool instead — one crossing, no copy, and a range
// that cannot be placed writes NEITHER out-parameter, so a caller that ignored the bool would read
// its own untouched memory rather than a plausible wrong cut.

import CSlopDeskFFI
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The mode pills

/// One `Aa` / `ab` / `.*` mode pill, as a VALUE.
///
/// ⚠️ The find bar and the global-search query bar render these pills IDENTICALLY — that is a locked
/// invariant (see ``FindTogglePillAppearance``'s own note — the SwiftUI `FindTogglePillTray` that used to
/// carry it dissolved into a stack view), and the labels and help strings live on the far
/// side so the two surfaces read them rather than agree on them. Three surfaces do now, in fact, across
/// two imperative frameworks: no call site can see another's.
public enum FindModePill: String, CaseIterable, Sendable {
    case caseSensitive
    case wholeWord
    case regex

    /// The pill's own index — the SHARED index space both lists are bitmasks over.
    var index: UInt8 {
        switch self {
        case .caseSensitive: 0
        case .wholeWord: 1
        case .regex: 2
        }
    }

    /// The glyph on the chip.
    public var label: String { Self.pills[self]?.label ?? "" }

    /// The hover/accessibility help.
    public var help: String { Self.pills[self]?.help ?? "" }

    /// Whether the glyph is drawn underlined — the whole-word chip's own mark, and nothing else's.
    public var underlined: Bool { Self.pills[self]?.underlined ?? false }

    /// The two the CROSS-TAB search offers. Whole-word is the in-pane find bar's alone: the global
    /// search runs over a scrollback mirror rather than over the terminal surface's own live grid, and the two
    /// engines do not agree about what a word boundary is.
    public static let globalSearch: [Self] = offered(global: true)

    /// The three the IN-PANE find bar offers, in drawn order: `Aa`, `ab|`, `.*`.
    ///
    /// It lives beside ``globalSearch`` rather than in the find bar's own presentation because the
    /// two lists are one DECISION — "which engine can answer which question" — and a reader who wants
    /// to know why whole-word is missing upstairs has to be able to see both lists at once. They are
    /// one bitmask over one index space on the far side for the same reason.
    public static let inPaneFindBar: [Self] = offered(global: false)

    /// The pills a surface offers, in drawn order, from the bitmask over the shared index space.
    private static func offered(global: Bool) -> [Self] {
        let mask = slopdesk_ws_find_mode_pills(global)
        return allCases.filter { mask & (1 << $0.index) != 0 }
    }

    /// All three pills' words and marks, in three crossings, once per process.
    private static let pills: [Self: (underlined: Bool, label: String, help: String)] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { pill in
            let blob = wsAnswerBytes { out, cap in Int(slopdesk_ws_find_mode_pill(pill.index, out, cap)) }
            guard let underlined = blob.first else { return nil }
            let text = wsRuns(Array(blob.dropFirst()), count: 2)
            return (pill, (underlined == 1, text[0], text[1]))
        },
    )
}

// MARK: - The card's measurements

/// The results panel's own dimensions on the Mac.
///
/// It is a large card rather than a full-window surface: the workspace behind it is the context the
/// search is ABOUT, and a results panel that covered it would make every hit a jump into the dark.
/// The phone takes the whole sheet instead, which is the same intent at a screen where there is no
/// "behind".
///
/// Both numbers cross BY VALUE in one call, because a caller that asked separately could pair one
/// surface's width with another's height.
public enum GlobalSearchMetrics {
    public static let panelWidth: Double = size.width
    public static let panelHeight: Double = size.height

    private static let size = slopdesk_ws_global_search_panel_size()
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
    /// The query bar's prompt. The zero-state lines already lived below the view; this one did not,
    /// and stood spelled character for character in both halves' query bars.
    public static var queryPrompt: String { words[0] }

    /// What a group's disclosure ANNOUNCES — the Mac hangs it off the chevron's
    /// `accessibilityDescription`, the phone off `accessibilityValue`, and both said it themselves.
    /// A state a screen reader reads out is copy, and copy is the surface's meaning, not its drawing.
    public static func disclosureState(collapsed: Bool) -> String { collapsed ? words[1] : words[2] }

    /// The three fixed words, in ONE crossing, once per process. Both disclosure states ride together
    /// because asking again mid-animation is a crossing per frame.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_global_search_words(out, cap)) },
        count: 3,
    )

    /// Cuts `hit`'s excerpt around its highlighted run.
    ///
    /// The range arrives as UTF-16 offsets, pre-clamped into the excerpt's bounds by
    /// ``GlobalSearchController``; what comes back is where they land in the excerpt's own BYTES. A
    /// range that cannot be placed — past the end, inside a surrogate pair, or inverted — degrades to
    /// the FLAT excerpt, never a trap and never a guessed run.
    public static func excerptSlices(_ hit: GlobalSearchHit) -> GlobalSearchExcerpt {
        let excerpt = hit.excerpt
        let flat = GlobalSearchExcerpt(before: excerpt, match: "", after: "")
        let bytes = Array(excerpt.utf8)
        var lowByte = 0
        var highByte = 0
        let placed = bytes.withUnsafeBufferPointer { borrowed in
            slopdesk_ws_global_search_excerpt(
                borrowed.baseAddress, borrowed.count,
                hit.highlight.lowerBound, hit.highlight.upperBound,
                &lowByte, &highByte,
            )
        }
        guard placed else { return flat }
        // Byte offsets from `char_indices`, so both land on a character boundary; the excerpt is
        // sliced rather than rebuilt, so there is no attributed-string index conversion on this path.
        let utf8 = excerpt.utf8
        guard let low = utf8.index(utf8.startIndex, offsetBy: lowByte, limitedBy: utf8.endIndex),
              let high = utf8.index(utf8.startIndex, offsetBy: highByte, limitedBy: utf8.endIndex)
        else { return flat }
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
        let bytes = Array(query.utf8)
        let blob = bytes.withUnsafeBufferPointer { borrowed in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_global_search_empty_line(borrowed.baseAddress, borrowed.count, out, cap))
            }
        }
        return wsRuns(blob, count: 1)[0]
    }

    /// The `N results — M tabs` line, or `nil` when there is nothing to count yet.
    ///
    /// Gated on a NON-EMPTY query rather than on non-empty results: a blank field with a stale result
    /// set behind it would otherwise print a count for a search the user has cleared. An absent result
    /// set is "no search has run at all", which is a different fact from a search that found nothing.
    public static func summary(_ results: GlobalSearchResults?, query: String) -> String? {
        let bytes = Array(query.utf8)
        let blob = bytes.withUnsafeBufferPointer { borrowed in
            wsAnswerBytes { out, cap in
                Int(slopdesk_ws_global_search_summary(
                    results != nil,
                    UInt32(results?.totalMatches ?? 0),
                    UInt32(results?.tabCount ?? 0),
                    borrowed.baseAddress,
                    borrowed.count,
                    out,
                    cap,
                ))
            }
        }
        return blob.isEmpty ? nil : wsRuns(blob, count: 1)[0]
    }
}
