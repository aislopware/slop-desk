// CommandNavigatorPresentation — the words and the two measurements the Command Navigator (⌃⌘O)
// card is cut from, in the layer BOTH renderers read.
//
// The navigator is `Platform::Both` (`binding_rows.rs:131`) and therefore has two drawings: the
// phone's SwiftUI `CommandNavigatorView` and the Mac's AppKit `MacCommandNavigatorView`. Everything
// below is the part of that card which is neither AppKit nor SwiftUI — a placeholder, four zero-state
// sentences, three footer hints, the two help strings the row's affordances carry, and the card's own
// width and results ceiling. It sits here for the reason ``PaletteMetrics`` and ``FindBarMetrics``
// do: a number or a sentence re-typed into a second renderer is a pair that drifts the first time
// either is tuned, and nothing in the repo compares a string literal in one file with a string
// literal in another.
//
// What is NOT here: the ranking (``CommandNavigatorModel``), the list itself
// (`TerminalBlockModel.blocks(filter:)`), the jump (`WorkspaceStore.jumpToNavigatorBlockInActivePane`)
// and the clamp (`ListNavigation.clampedSelection`). Each of those was already shared before this
// file existed; this only finishes the set with the card's own vocabulary.

import CoreGraphics // the two measurements are geometry, so they are CGFloat at both spenders
import Foundation
import SlopDeskWorkspaceCore

// MARK: - The card's two measurements

/// The Command Navigator card's fixed width and its results ceiling — the ``PaletteMetrics`` shape,
/// for the same reason: a card that stretched with the pane would put its trailing affordances a
/// pane's width away from the command they act on.
public enum CommandNavigatorMetrics {
    /// The card's fixed width. Narrower than the palette's, because a row here is ONE command line
    /// rather than a title, a place line and a keycap column.
    public static let panelWidth: CGFloat = 480
    /// The tallest the results viewport may be. Past this the list scrolls instead of the card
    /// growing; a renderer standing in a SHORT pane may shrink it further, never grow it.
    ///
    /// `CGFloat` rather than `Double` because both spenders are geometry — a SwiftUI `.frame` and an
    /// `NSLayoutConstraint` constant — and a `Double` would be implicitly converted at each of them.
    public static let resultsMaxHeight: CGFloat = 320
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

// MARK: - The words

/// Every word the Command Navigator card says.
public enum CommandNavigatorPresentation {
    /// The search field's placeholder.
    public static let searchPlaceholder = "Search commands…"

    /// The zero state when the query matched nothing but the pane HAS commands.
    public static let noMatches = "No matches"

    /// The zero-state line for an empty list, scoped to the active segment.
    ///
    /// Two questions in one answer, because they are asked together and answered differently: a
    /// query that matched nothing is `No matches` (the list is empty because of what was TYPED), and
    /// an empty segment names the segment (the list is empty because the pane has nothing in it).
    public static func emptyLine(filter: BlockNavigatorFilter, hasBlocks: Bool) -> String {
        guard !hasBlocks else { return noMatches }
        switch filter {
        case .all: return "No commands yet"
        case .failed: return "No failed commands"
        case .bookmarked: return "No bookmarked commands"
        }
    }

    /// The selected row's "run this again in the pane" affordance, and the chord that does it
    /// without the pointer.
    public static let reRunHelp = "Re-run (⌘↩)"
    /// The selected row's "put this command's captured output on the clipboard" affordance.
    public static let copyOutputHelp = "Copy Output (⌘C)"
    /// The per-row star.
    public static let bookmarkHelp = "Bookmark"

    /// ↑/↓ walk the list.
    public static let navigateHint = CommandNavigatorHint(label: "Navigate", glyph: "↑↓")
    /// ↩ jumps the pane's scrollback to the selected command and closes.
    public static let jumpHint = CommandNavigatorHint(label: "Jump", glyph: "↩")
    /// Esc closes without moving the viewport.
    public static let closeHint = CommandNavigatorHint(label: "Close", glyph: "esc")
}
