import Foundation

// MARK: - E10 WI-10 (G8): the pure Command Navigator filter (⌃⌘O / view.commandNavigator)

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
/// The vendored `FuzzyMatcher` lives in the view module, so it is INJECTED into ``filtered(_:query:score:)``
/// rather than imported here — keeping the model + its tests headless (mirrors ``JumpToModel/filtered``).
public enum CommandNavigatorModel {
    /// Fuzzy-filter + rank `blocks` by `query` using the INJECTED `score` closure (the view passes
    /// `FuzzyMatcher.score(_:_:)?.score`; the headless tests pass a deterministic scorer). An EMPTY query
    /// returns `blocks` unchanged (the zero-state list — caller-ordered, i.e. newest-first). A non-empty
    /// query drops every block the scorer rejects (`nil`) AND every still-forming block (empty `commandText`,
    /// which can never match a real query), then orders the survivors by score DESCENDING, breaking ties by
    /// original order (a STABLE sort, so equal-score blocks keep the caller's newest-first order).
    ///
    /// Integer scores only — the `>` / `<` comparisons are ordered + total (no float, so no NaN hazard; the
    /// codebase's ordered-compare convention applies to float, and this is integer arithmetic).
    public static func filtered(
        _ blocks: [CommandBlock],
        query: String,
        score: (_ query: String, _ haystack: String) -> Int?,
    ) -> [CommandBlock] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return blocks }
        let scored: [(score: Int, order: Int, block: CommandBlock)] = blocks.enumerated()
            .compactMap { offset, block in
                guard !block.commandText.isEmpty, let s = score(trimmed, block.commandText) else { return nil }
                return (s, offset, block)
            }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }.map(\.block)
    }
}
