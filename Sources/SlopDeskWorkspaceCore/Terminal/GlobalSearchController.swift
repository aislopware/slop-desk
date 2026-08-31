import SlopDeskWorkspaceModel

// MARK: - GlobalSearch (pure cross-pane find engine behind ⇧⌘F)

/// One searchable pane fed into ``GlobalSearchController/run(sources:query:caseSensitive:isRegex:)``: the
/// pane's tree identity (so a result row can jump back to the exact session → tab → pane) plus the flat
/// scrollback text mirror to scan. The store builds one per *live terminal* pane off
/// ``TerminalViewModel/searchScrollbackLines()``; a pane that never received bytes contributes `lines: []`
/// and is simply absent from the results.
public struct GlobalSearchSource: Equatable, Sendable {
    /// The join key back to the live-session registry (the pane to focus when a hit is clicked).
    public let paneID: PaneID
    /// The owning session (selected first on jump).
    public let sessionID: SessionID
    /// The owning tab within the session (selected second on jump).
    public let tabID: TabID
    /// The header shown above this source's hits — the owning tab/pane title (`find.png` group header).
    public let groupTitle: String
    /// One entry per scrollback line (no trailing newline) — the exact shape ``ScrollbackMatcher`` eats.
    public let lines: [String]

    public init(paneID: PaneID, sessionID: SessionID, tabID: TabID, groupTitle: String, lines: [String]) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.tabID = tabID
        self.groupTitle = groupTitle
        self.lines = lines
    }
}

/// One found occurrence within a source, carried with everything a result row needs to render and to jump:
/// the source identity, the in-buffer location (`line`/`column`/`length`, UTF-16 code units, matching
/// ``ScrollbackMatcher/Match``), a ready-to-render `excerpt` (the full matched line), and the
/// `highlight` UTF-16 column range within that excerpt to tint amber (mirrors `find.png` / `global-search.png`).
public struct GlobalSearchHit: Equatable, Sendable {
    public let paneID: PaneID
    public let sessionID: SessionID
    public let tabID: TabID
    /// 0-based line index within the source's buffer.
    public let line: Int
    /// UTF-16 column offset of the match start within the line.
    public let column: Int
    /// UTF-16 length of the match.
    public let length: Int
    /// The full text of the matched line (the legible context shown in the result row).
    public let excerpt: String
    /// The UTF-16 sub-range of `excerpt` to highlight — clamped into the excerpt's bounds so it never
    /// constructs an invalid range (`column..<column+length`, bounded by the excerpt's UTF-16 count).
    public let highlight: Range<Int>

    public init(
        paneID: PaneID,
        sessionID: SessionID,
        tabID: TabID,
        line: Int,
        column: Int,
        length: Int,
        excerpt: String,
        highlight: Range<Int>,
    ) {
        self.paneID = paneID
        self.sessionID = sessionID
        self.tabID = tabID
        self.line = line
        self.column = column
        self.length = length
        self.excerpt = excerpt
        self.highlight = highlight
    }
}

/// All hits from a single source, headed by its `groupTitle` (a "grouped by tab" header) and carrying
/// the source identity so the group header itself can jump. Only sources with ≥1 hit become a group.
public struct GlobalSearchGroup: Equatable, Sendable {
    public let groupTitle: String
    public let paneID: PaneID
    public let sessionID: SessionID
    public let tabID: TabID
    public let hits: [GlobalSearchHit]

    public init(groupTitle: String, paneID: PaneID, sessionID: SessionID, tabID: TabID, hits: [GlobalSearchHit]) {
        self.groupTitle = groupTitle
        self.paneID = paneID
        self.sessionID = sessionID
        self.tabID = tabID
        self.hits = hits
    }
}

/// The assembled global-search result set: the per-source `groups` (source order preserved, zero-hit sources
/// dropped), the flat `totalMatches` count, and the `tabCount` (number of groups). The `N results — M tabs`
/// line those two numbers become is `GlobalSearchPresentation.summary`, which reads it from
/// `slopdesk_workspace::global_search` along with the gate that decides whether it prints at all.
public struct GlobalSearchResults: Equatable, Sendable {
    public let groups: [GlobalSearchGroup]
    public let totalMatches: Int
    public let tabCount: Int

    public init(groups: [GlobalSearchGroup], totalMatches: Int, tabCount: Int) {
        self.groups = groups
        self.totalMatches = totalMatches
        self.tabCount = tabCount
    }

    /// An empty result set (empty query / nothing matched) — the `nil`-equivalent the overlay renders blank.
    public static let empty = Self(groups: [], totalMatches: 0, tabCount: 0)
}

/// Transient per-group collapse state for the Global Search surface (⇧⌘F): the set of result groups the
/// user has explicitly collapsed, keyed by each group's stable ``PaneID`` (one group == one source pane).
///
/// A PURE value type so the disclosure-toggle reducer is unit-testable WITHOUT instantiating the overlay
/// (the hang-safety rule keeps real surfaces/windows out of tests). `MacGlobalSearch` holds one as a plain
/// stored property and asks it whether to draw a group's hit rows; keying by ``PaneID`` (not by index) means a live
/// re-run that re-orders or drops groups carries the collapse intent forward where the pane survives and
/// simply lets a vanished pane's stale id fall away — never collapsing the WRONG group.
///
/// Default (`collapsed` empty) == every group EXPANDED: a fresh search shows all hits — the
/// disclosure control to the left of each group header collapses on demand
/// (`docs/ui-shell/spec/user-interface__find.md`).
public struct GlobalSearchCollapseState: Equatable, Sendable {
    /// The pane groups the user has collapsed (their hit rows hidden). Empty ⇒ all groups expanded.
    public private(set) var collapsed: Set<PaneID>

    public init(collapsed: Set<PaneID> = []) { self.collapsed = collapsed }

    /// `true` when the group identified by `paneID` is collapsed (its hit rows hidden).
    public func isCollapsed(_ paneID: PaneID) -> Bool { collapsed.contains(paneID) }

    /// Whether the group's hit rows should be SHOWN — the inverse of ``isCollapsed(_:)``, named for the
    /// view's call site (it renders a group's hits only when this is `true`). A group never seen before is
    /// expanded by default.
    public func showsHits(_ paneID: PaneID) -> Bool { !collapsed.contains(paneID) }

    /// Flip the collapsed/expanded state of `paneID` — the disclosure-control reducer. Collapsing one group
    /// leaves every other group's state untouched.
    public mutating func toggle(_ paneID: PaneID) {
        if collapsed.contains(paneID) {
            collapsed.remove(paneID)
        } else {
            collapsed.insert(paneID)
        }
    }
}

/// The PURE engine behind ⇧⌘F Global Search: it runs ``ScrollbackMatcher/computeMatches``
/// over every live terminal pane's scrollback mirror and assembles the grouped, summarised results the
/// global-search surface renders. NO view, NO store, NO engine — the surface-collection glue (snapshotting
/// each pane's scrollback, the jump) lives in `WorkspaceStore`; THIS is the single, fully unit-testable core,
/// reusing the SAME match math as the in-pane find bar so the two never drift.
///
/// Behaviour:
/// - Reuses ``ScrollbackMatcher/computeMatches(lines:query:caseSensitive:isRegex:)`` per source —
///   no second matcher to keep in sync.
/// - Drops sources with zero hits; `tabCount` is therefore the number of surviving `groups`.
/// - Preserves source order (the store feeds sources in session → tab → pane order).
/// - Empty query ⇒ `.empty`. Invalid regex ⇒ `.empty` (inherits the controller's validate-then-drop; never traps).
public enum GlobalSearchController {
    /// Runs `query` across all `sources`, returning the grouped/summarised results. See the type docs above.
    public static func run(
        sources: [GlobalSearchSource],
        query: String,
        caseSensitive: Bool,
        isRegex: Bool,
    ) -> GlobalSearchResults {
        guard !query.isEmpty else { return .empty }

        var groups: [GlobalSearchGroup] = []
        var totalMatches = 0
        // The widest answer any source has given so far, as the next source's first guess. A short
        // guess on this door does not cost a copy, it costs a second SCAN of that pane's whole
        // scrollback — `slopdesk_find_matches` builds its answer to report the size and keeps
        // nothing. The panes of one workspace hold similar buffers and are being asked the same
        // question, so the first pane pays the retry and the rest do not; over-guessing costs a
        // malloc. Measured through the door over a 10 000-row / 736 KB pane, a query matching every
        // row: 3.52 ms against 1.83 ms — per pane, per keystroke, across every open pane at once.
        var expected = 0

        for source in sources {
            let matches = ScrollbackMatcher.computeMatches(
                lines: source.lines,
                query: query,
                caseSensitive: caseSensitive,
                isRegex: isRegex,
                expecting: expected,
            )
            expected = Swift.max(expected, matches.count)
            guard !matches.isEmpty else { continue } // zero-hit source ⇒ no group

            var hits: [GlobalSearchHit] = []
            hits.reserveCapacity(matches.count)
            for match in matches {
                // The excerpt is the FULL matched line (legible row context). `computeMatches` only ever
                // returns in-range line indices, but guard anyway — never index out of bounds on a hostile buffer.
                let excerpt = source.lines.indices.contains(match.line) ? source.lines[match.line] : ""
                // The highlight is `match`'s UTF-16 column range, clamped into the excerpt so a malformed
                // (start > end) range can never be constructed (which would trap).
                let utf16Len = excerpt.utf16.count
                let start = Swift.min(Swift.max(0, match.column), utf16Len)
                let end = Swift.min(Swift.max(start, match.column + match.length), utf16Len)
                hits.append(GlobalSearchHit(
                    paneID: source.paneID,
                    sessionID: source.sessionID,
                    tabID: source.tabID,
                    line: match.line,
                    column: match.column,
                    length: match.length,
                    excerpt: excerpt,
                    highlight: start..<end,
                ))
            }

            groups.append(GlobalSearchGroup(
                groupTitle: source.groupTitle,
                paneID: source.paneID,
                sessionID: source.sessionID,
                tabID: source.tabID,
                hits: hits,
            ))
            totalMatches += matches.count
        }

        return GlobalSearchResults(groups: groups, totalMatches: totalMatches, tabCount: groups.count)
    }

    /// The click-to-line action that lands the in-pane viewport on the CLICKED `hit`.
    ///
    /// LANDING is mode-INDEPENDENT and viewport-INDEPENDENT: ALWAYS scroll the viewport straight to the
    /// clicked hit's row. `hit.line` indexes the LOGICAL (unwrapped) `searchScrollbackLines()` mirror
    /// that ``ScrollbackMatcher/computeMatches(lines:query:caseSensitive:isRegex:wholeWord:expecting:)``
    /// scanned, whereas `scroll_to_row:<usize>` addresses SCREEN rows (soft-wrap continuations count) —
    /// so the row is READ OFF the same mirror (``TerminalScrollbackLine/firstRow``, which the engine
    /// reported) before scrolling, landing the clicked row regardless of case-sensitivity, regex,
    /// wrapped output, or where the viewport currently sits. A caller that passes no `lines` (or a stale
    /// index) gets `hit.line` unmapped — the pre-wrap-fix behaviour, which is the honest floor when
    /// there is no mirror to ask. An ordinal `navigate_search:next` walk is avoided: it is
    /// viewport-relative, so a mid-buffer viewport mis-lands.
    ///
    /// ⚠️ **THE HIGHLIGHT IS NO LONGER PART OF THIS DECISION, and it used to be the hard part.** The
    /// surface's matcher took a needle alone, so arming it was faithful in exactly one mode — literal
    /// and case-INSENSITIVE — and the other two cleared the highlight instead and scrolled bare. That
    /// ceiling is gone: ``TerminalViewModel/findInSurface(_:caseSensitive:wholeWord:isRegex:)`` carries
    /// every mode, so ``WorkspaceStore/jumpToGlobalSearchResult(_:)`` arms the real query first and this
    /// answers only where to land. The amber per-glyph highlight now survives `Aa` and `.*`.
    ///
    /// Validate-then-drop: an empty `query` yields `nil` (nothing to scroll to).
    public static func scrollAction(
        for hit: GlobalSearchHit,
        query: String,
        lines: [TerminalScrollbackLine] = [],
    ) -> String? {
        guard !query.isEmpty else { return nil }
        // The LOGICAL (unwrapped) hit line's SCREEN row, read off the same mirror the scan used — the
        // engine's own number, not an estimate from the grid width. No mirror / stale index ⇒ the
        // unmapped row, i.e. the pre-wrap-fix behaviour.
        let row = lines.row(forLine: hit.line) ?? hit.line
        return TerminalSearchSurfaceAction.scrollToRow(row).wire
    }
}
