import Foundation
import SlopDeskWorkspaceModel

// MARK: - The pure Command Navigator filter (⌃⌘O / view.commandNavigator)

/// The PURE fuzzy filter behind the Command Navigator overlay (⌃⌘O). The navigator shows the active pane's
/// recent OSC-133 command blocks — the already-pure ``TerminalBlockModel`` (`navigatorBlocks`, newest-first,
/// optionally narrowed by a ``BlockNavigatorFilter`` segment) — and this enum is the ONLY new logic on top:
/// rank + drop those blocks against the typed query.
///
/// Distinct from ``JumpToModel`` (Jump-To = links + commands + actions over the whole pane): the Navigator is
/// a BLOCK/command jump WITHIN the pane, so it filters ``CommandBlock`` directly and the view jumps via
/// ``WorkspaceStore/jumpToNavigatorBlockInActivePane(index:)`` (the shared ``BlockJump`` re-anchor engine — so
/// the delta math is never re-derived in the view).
///
/// What a block is found BY is the only thing decided here; how well it matches is
/// `slopdesk_workspace::search_rank`, the one ranking every search field in the app asks for.
public enum CommandNavigatorModel {
    /// Fuzzy-filter + rank `blocks` by `query`. An EMPTY query returns `blocks` unchanged (the
    /// zero-state list — caller-ordered, i.e. newest-first). A non-empty query drops every block the
    /// matcher rejects, then orders the survivors best-first with the caller's newest-first order
    /// breaking ties.
    ///
    /// A still-forming block has no command text yet, so it is offered as the empty string: no real
    /// query can match it, and the zero state still lists it where it stands.
    public static func filtered(_ blocks: [CommandBlock], query: String) -> [CommandBlock] {
        wsSearchRanked(blocks, query: query) { $0.commandText }
    }
}
