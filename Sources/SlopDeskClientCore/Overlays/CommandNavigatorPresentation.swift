// CommandNavigatorPresentation — the near-side FACE of `slopdesk_workspace::command_navigator`.
//
// The navigator is `Platform::Both` (`binding_rows.rs:131`) and therefore has two drawings: the
// phone's UIKit ``PhoneCommandNavigatorView`` and the Mac's AppKit `MacCommandNavigatorView`.
// Everything below is the part of that card which is neither of them — a placeholder, four zero-state
// sentences, three footer hints, the two help strings the row's affordances carry, and the card's own
// width and results ceiling. It crossed for the reason ``PaletteMetrics`` and ``FindBarMetrics`` did:
// a number or a sentence re-typed into a second renderer is a pair that drifts the first time either
// is tuned, and nothing in the repo compares a string literal in one file with a string literal in
// another.
//
// What is NOT here: the ranking (``CommandNavigatorModel``), the list itself
// (`TerminalBlockModel.blocks(filter:)`), the jump (`WorkspaceStore.jumpToNavigatorBlockInActivePane`)
// and the clamp (`ListNavigation.clampedSelection`). Each of those was already shared before this
// file existed; this only finishes the set with the card's own vocabulary.

import CoreGraphics // the two measurements are geometry, so they are CGFloat at both spenders
import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

// MARK: - The card's two measurements

/// The Command Navigator card's fixed width and its results ceiling — the ``PaletteMetrics`` shape,
/// for the same reason: a card that stretched with the pane would put its trailing affordances a
/// pane's width away from the command they act on.
///
/// Both numbers cross BY VALUE in one call, because a caller that asked separately could pair one
/// card's width with another's ceiling.
public enum CommandNavigatorMetrics {
    /// The card's fixed width. Narrower than the palette's, because a row here is ONE command line
    /// rather than a title, a place line and a keycap column.
    public static let panelWidth = CGFloat(size.width)
    /// The tallest the results viewport may be. Past this the list scrolls instead of the card
    /// growing; a renderer standing in a SHORT pane may shrink it further, never grow it.
    ///
    /// `CGFloat` rather than `Double` because both spenders are geometry — a SwiftUI `.frame` and an
    /// `NSLayoutConstraint` constant — and a `Double` would be implicitly converted at each of them.
    public static let resultsMaxHeight = CGFloat(size.height)

    private static let size = slopdesk_ws_command_navigator_metrics()
}

// MARK: - One footer hint

/// One `label + glyph` pair on the card's foot bar (`Navigate ↑↓`).
///
/// A value rather than two strings at a call site so the two renderers cannot end up saying
/// "Navigate" and "Move" about the same key.
public struct CommandNavigatorHint: Sendable, Hashable {
    /// What pressing the key does, in sentence case.
    public let label: String
    /// The key itself, as the arrows / word the keyboard prints.
    public let glyph: String

    public init(label: String, glyph: String) {
        self.label = label
        self.glyph = glyph
    }
}

// MARK: - The command line, cut

/// A navigator row's command line and the runs the query matched in it.
///
/// The whole cut in ONE value because the two are decided together: the placeholder dash is what the
/// runs were cut FROM, and a renderer holding one without the other could mark a line it is not
/// drawing.
public struct CommandNavigatorLineCut: Sendable {
    /// The text the row draws — the block's command, or the em-dash placeholder for a block that has
    /// not reported one yet.
    public let line: String
    /// ``line`` split into alternating unmatched / matched stretches. Never empty.
    public let runs: [FuzzyRun]
}

// MARK: - The words

/// Every word the Command Navigator card says.
public enum CommandNavigatorPresentation {
    /// The search field's placeholder.
    public static var searchPlaceholder: String { words[0] }

    /// The zero state when the query matched nothing but the pane HAS commands.
    public static var noMatches: String { words[1] }

    /// The zero-state line for an empty list, scoped to the active segment.
    ///
    /// Two questions in one answer, because they are asked together and answered differently: a
    /// query that matched nothing is `No matches` (the list is empty because of what was TYPED), and
    /// an empty segment names the segment (the list is empty because the pane has nothing in it).
    public static func emptyLine(filter: BlockNavigatorFilter, hasBlocks: Bool) -> String {
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_ws_command_navigator_empty_line(filter.navigatorCode, hasBlocks, out, cap))
        }
        return wsRuns(blob, count: 1)[0]
    }

    /// `1.4s · 4m ago` — the duration the block reports and the age the Outline words, joined by the
    /// app's one separator. Either half may be missing; both missing is an empty line.
    public static func metaLine(_ block: CommandBlock, firstSeen: Date?) -> String {
        var parts: [String] = []
        if let duration = block.durationLabel { parts.append(duration) }
        if let firstSeen {
            parts.append(OutlinePresentation.relativeTime(from: firstSeen, now: Date()))
        }
        return parts.joined(separator: " · ")
    }

    /// The command line as it is drawn, cut at the query's matched runs.
    ///
    /// WHERE the cuts fall is ``FuzzyMatcher/runs(of:ranges:)``'s and the em-dash placeholder is this
    /// card's; only the INK is a renderer's. A still-forming block has no command text yet and shows
    /// the dash — no real query can match it, so it appears only in the zero-query list.
    public static func markedCommand(_ text: String, query: String) -> CommandNavigatorLineCut {
        let line = text.isEmpty ? "—" : text
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let ranges = trimmed.isEmpty ? [] : FuzzyMatcher.score(trimmed, line)?.ranges ?? []
        return CommandNavigatorLineCut(line: line, runs: FuzzyMatcher.runs(of: line, ranges: ranges))
    }

    /// The selected row's "run this again in the pane" affordance, and the chord that does it
    /// without the pointer.
    public static var reRunHelp: String { words[2] }
    /// The selected row's "put this command's captured output on the clipboard" affordance.
    public static var copyOutputHelp: String { words[3] }
    /// The per-row star.
    public static var bookmarkHelp: String { words[4] }

    /// ↑/↓ walk the list.
    public static let navigateHint = CommandNavigatorHint(label: words[5], glyph: words[6])
    /// ↩ jumps the pane's scrollback to the selected command and closes.
    public static let jumpHint = CommandNavigatorHint(label: words[7], glyph: words[8])
    /// Esc closes without moving the viewport.
    public static let closeHint = CommandNavigatorHint(label: words[9], glyph: words[10])

    /// Every fixed word in ONE crossing, once per process. The three hints' labels and glyphs ride
    /// together because a foot bar is drawn as a unit — one that said "Navigate" beside "↩" would be
    /// two of the six disagreeing.
    private static let words: [String] = wsRuns(
        wsAnswerBytes { out, cap in Int(slopdesk_ws_command_navigator_words(out, cap)) },
        count: 11,
    )
}

private extension BlockNavigatorFilter {
    /// The code this segment crosses as. An unrecognised one reads as the widest on the far side,
    /// because a zero state naming the wrong segment is worse than one naming the whole pane.
    var navigatorCode: UInt8 {
        switch self {
        case .all: 0
        case .failed: 1
        case .bookmarked: 2
        }
    }
}
