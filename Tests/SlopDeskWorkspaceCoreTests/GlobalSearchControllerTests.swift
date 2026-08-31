import Foundation
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The pure ⇧⌘F Global Search engine: runs ``ScrollbackMatcher/computeMatches(lines:query:caseSensitive:isRegex:wholeWord:expecting:)`` over every
/// terminal pane's scrollback mirror, drops zero-hit sources, groups by source, builds full-line excerpts with
/// UTF-16 highlight ranges, and counts what survived. All against in-memory sources — no view, no store, no
/// libghostty-vt. The `N results — M tabs` LINE those counts become is `slopdesk_workspace::global_search`'s and
/// is pinned there; what is asserted here is the counting.
final class GlobalSearchControllerTests: XCTestCase {
    /// Mints a source with a fresh identity (UUID-backed) and the given title + buffer.
    private func source(_ title: String, _ lines: [String]) -> GlobalSearchSource {
        GlobalSearchSource(
            paneID: PaneID(),
            sessionID: SessionID(),
            tabID: TabID(),
            groupTitle: title,
            lines: lines,
        )
    }

    // MARK: Grouping + summary

    func testGroupsByTabAndCountsSummary() {
        // 3 sources; "doc" hits in 2 of them (2 + 2 = 4 hits); the third has none and must be dropped.
        let sources = [
            source("alpha", ["open docs", "read doc"]), // 2 hits
            source("beta", ["doc doc"]), // 2 hits ("doc" at col 0 and col 4)
            source("gamma", ["nothing here"]), // 0 hits ⇒ no group
        ]
        let results = GlobalSearchController.run(sources: sources, query: "doc", caseSensitive: false, isRegex: false)

        XCTAssertEqual(results.groups.count, 2)
        XCTAssertEqual(results.totalMatches, 4)
        XCTAssertEqual(results.tabCount, 2)
        // Source order is preserved; the zero-hit "gamma" is absent (not merely empty).
        XCTAssertEqual(results.groups.map(\.groupTitle), ["alpha", "beta"])
        XCTAssertEqual(results.groups.map(\.hits.count), [2, 2])
    }

    // MARK: Empty source

    func testEmptySourceContributesNoGroup() {
        let sources = [
            source("empty-pane", []), // never received bytes ⇒ absent
            source("live-pane", ["a doc line"]), // 1 hit
        ]
        let results = GlobalSearchController.run(sources: sources, query: "doc", caseSensitive: false, isRegex: false)

        XCTAssertEqual(results.groups.count, 1)
        XCTAssertEqual(results.groups.first?.groupTitle, "live-pane")
        XCTAssertEqual(results.totalMatches, 1)
        XCTAssertEqual(results.tabCount, 1)
    }

    // MARK: Excerpt + highlight range

    func testExcerptAndHighlightRange() throws {
        let results = GlobalSearchController.run(
            sources: [source("only", ["the docs folder"])],
            query: "doc",
            caseSensitive: false,
            isRegex: false,
        )
        let hit = try XCTUnwrap(results.groups.first?.hits.first)
        // The excerpt is the FULL matched line, not a substring.
        XCTAssertEqual(hit.excerpt, "the docs folder")
        // "the " is 4 UTF-16 units, so "doc" begins at column 4 with length 3.
        XCTAssertEqual(hit.column, 4)
        XCTAssertEqual(hit.length, 3)
        // The highlight is that exact UTF-16 sub-range of the excerpt.
        XCTAssertEqual(hit.highlight, 4..<7)
        // …and slicing the excerpt by that UTF-16 range yields the matched term (proves the range is usable).
        // swiftlint:disable:next legacy_objc_type
        let ns = hit.excerpt as NSString
        let sliced = ns.substring(with: NSRange(location: hit.highlight.lowerBound, length: hit.highlight.count))
        XCTAssertEqual(sliced, "doc")
    }

    // MARK: Case + regex honored (parity with the ScrollbackMatcher flags)

    func testCaseSensitiveAndRegexHonored() {
        // Case-insensitive (default) matches both "doc" and "DOC"; case-sensitive narrows to the exact "DOC".
        let caseSource = [source("case", ["doc", "DOC"])]
        let insensitive = GlobalSearchController.run(
            sources: caseSource,
            query: "DOC",
            caseSensitive: false,
            isRegex: false,
        )
        XCTAssertEqual(insensitive.totalMatches, 2)
        let sensitive = GlobalSearchController.run(
            sources: caseSource,
            query: "DOC",
            caseSensitive: true,
            isRegex: false,
        )
        XCTAssertEqual(sensitive.totalMatches, 1)
        XCTAssertEqual(sensitive.groups.first?.hits.first?.line, 1)

        // Regex mode honors the pattern (literal mode would not match "do." at all).
        let regexSource = [source("regex", ["dog", "dot", "cat"])]
        let regex = GlobalSearchController.run(
            sources: regexSource,
            query: "do.",
            caseSensitive: false,
            isRegex: true,
        )
        XCTAssertEqual(regex.totalMatches, 2)
        let literal = GlobalSearchController.run(
            sources: regexSource,
            query: "do.",
            caseSensitive: false,
            isRegex: false,
        )
        XCTAssertEqual(literal.totalMatches, 0) // no literal "do." substring exists
    }

    // MARK: Invalid regex — validate-then-drop

    func testInvalidRegexYieldsNoResultsNeverTraps() {
        let results = GlobalSearchController.run(
            sources: [source("only", ["doc one", "doc two"])],
            query: "doc(", // unbalanced ⇒ invalid pattern
            caseSensitive: false,
            isRegex: true,
        )
        XCTAssertTrue(results.groups.isEmpty) // dropped, never trapped
        XCTAssertEqual(results.totalMatches, 0)
        XCTAssertEqual(results.tabCount, 0)
    }

    // MARK: Empty query

    func testEmptyQueryYieldsZeroResults() {
        let results = GlobalSearchController.run(
            sources: [source("only", ["doc one", "doc two"])],
            query: "",
            caseSensitive: false,
            isRegex: false,
        )
        XCTAssertEqual(results, .empty)
        XCTAssertEqual(results.totalMatches, 0)
        XCTAssertEqual(results.tabCount, 0)
    }

    // MARK: Click-to-line navigation

    /// The DEFINITIVE click-to-line invariant: two DIFFERENT hits on DIFFERENT lines in the SAME pane
    /// scroll to two DISTINCT rows in ALL THREE modes (literal case-insensitive, literal case-SENSITIVE,
    /// regex). Landing is mode-independent and viewport-independent — it never depends on an ordinal that
    /// case-sensitivity / regex / viewport can desync. The OLD literal path emitted `search:` +
    /// (ordinal+1)×`navigate_search:next` (no `scroll_to_row` at all in literal mode), so each of these
    /// assertions fails on the un-fixed ordinal walk.
    ///
    /// ⚠️ **The mode arguments are gone, and their absence is the assertion.** This used to answer a LIST
    /// whose first element armed (or refused to arm) the surface's literal matcher, because that matcher
    /// could not express case-sensitivity or regex and the overlay had to decide which modes were safe to
    /// paint. It can express all four now, so the highlight is armed by ``WorkspaceStore`` through the
    /// find door and this decides one thing: which row to bring into view.
    func testScrollActionTargetsDistinctRowsInEveryMode() throws {
        // One pane, hits on three distinct lines under each mode's query.
        func hitsFor(query: String, caseSensitive: Bool, isRegex: Bool, lines: [String]) throws -> [GlobalSearchHit] {
            let results = GlobalSearchController.run(
                sources: [source("pane", lines)],
                query: query,
                caseSensitive: caseSensitive,
                isRegex: isRegex,
            )
            let hits = try XCTUnwrap(results.groups.first?.hits)
            XCTAssertEqual(hits.count, 3, "expected three hits on distinct lines for \(query)")
            return hits
        }

        struct Mode {
            let name: String
            let query: String
            let caseSensitive: Bool
            let isRegex: Bool
            let lines: [String]
        }

        let modes = [
            Mode(
                name: "literal case-insensitive", query: "doc", caseSensitive: false, isRegex: false,
                lines: ["alpha DOC", "beta doc", "gamma Doc"],
            ),
            Mode(
                name: "literal case-sensitive", query: "DOC", caseSensitive: true, isRegex: false,
                lines: ["alpha DOC", "beta DOC", "gamma DOC"],
            ),
            Mode(
                name: "regex", query: #"\d+"#, caseSensitive: false, isRegex: true,
                lines: ["alpha 12", "beta 34", "gamma 56"],
            ),
        ]
        for mode in modes {
            let hits = try hitsFor(
                query: mode.query, caseSensitive: mode.caseSensitive, isRegex: mode.isRegex, lines: mode.lines,
            )
            let first = GlobalSearchController.scrollAction(for: hits[0], query: mode.query)
            let third = GlobalSearchController.scrollAction(for: hits[2], query: mode.query)
            XCTAssertEqual(first, "scroll_to_row:\(hits[0].line)", mode.name)
            XCTAssertEqual(third, "scroll_to_row:\(hits[2].line)", mode.name)
            XCTAssertNotEqual(hits[0].line, hits[2].line, mode.name)
            XCTAssertNotEqual(first, third, "\(mode.name): distinct rows must scroll to distinct targets")
        }
    }

    /// Soft-wrap coordinate mapping: the click-to-line `scroll_to_row` must target the PHYSICAL grid
    /// row, not the logical (unwrapped) mirror index. A wrapped line above the hit shifts its physical
    /// row down. Revert-to-confirm-fail: the un-fixed navigation emitted `scroll_to_row:<hit.line>` (the
    /// logical index), one row too high per wrap continuation above it.
    ///
    /// ⚠️ The rows are the ENGINE's, read off the mirror — `firstRow`/`lastRow` per logical line. The
    /// client used to recompute them from the text and a column count, which was a second wrap
    /// implementation that could not see a double-width glyph; `ScrollbackWrapMapper` and the
    /// `columns:` argument went with it (docs/68).
    func testScrollActionMapsLogicalLineToPhysicalRowAcrossWrap() throws {
        // Logical line 0 ("abcdefgh") occupies two physical rows, so line 1 starts on row 2.
        let mirror = [
            TerminalScrollbackLine(text: "abcdefgh", firstRow: 0, lastRow: 1),
            TerminalScrollbackLine(text: "beta doc", firstRow: 2, lastRow: 2),
        ]
        let results = GlobalSearchController.run(
            sources: [source("pane", mirror.text)], query: "doc", caseSensitive: false, isRegex: false,
        )
        let hit = try XCTUnwrap(results.groups.first?.hits.first)
        XCTAssertEqual(hit.line, 1, "the match's LOGICAL mirror index is 1")

        XCTAssertEqual(GlobalSearchController.scrollAction(for: hit, query: "doc", lines: mirror), "scroll_to_row:2")

        // Without the mirror (default), the mapping degrades to the identity — the pre-fix logical row.
        XCTAssertEqual(GlobalSearchController.scrollAction(for: hit, query: "doc"), "scroll_to_row:1")
    }

    /// An empty query scrolls nowhere (validate-then-drop).
    func testScrollActionEmptyQueryYieldsNothing() throws {
        let results = GlobalSearchController.run(
            sources: [source("only", ["a doc"])],
            query: "doc",
            caseSensitive: false,
            isRegex: false,
        )
        let hit = try XCTUnwrap(results.groups.first?.hits.first)
        XCTAssertNil(GlobalSearchController.scrollAction(for: hit, query: ""))
    }

    // MARK: Per-group collapse state (the disclosure-control reducer the ⇧⌘F surface owns)

    /// A fresh result set is fully EXPANDED — every group shows its hit rows by default (a group
    /// is collapsed only on an explicit disclosure tap). Reverting the fix (the view unconditionally renders
    /// every group's hits) regresses to "never collapsible"; this pins that the default is expanded AND that a
    /// toggle actually hides the group, distinguishing the fixed behaviour from the dead pre-fix terminal glyph.
    func testCollapseStateDefaultsExpandedAndTogglesPerGroup() {
        let alpha = PaneID()
        let beta = PaneID()
        var state = GlobalSearchCollapseState()

        // Default: nothing collapsed → both groups render their hits.
        XCTAssertTrue(state.showsHits(alpha))
        XCTAssertTrue(state.showsHits(beta))
        XCTAssertFalse(state.isCollapsed(alpha))

        // Collapsing alpha hides ONLY alpha's hit rows; beta stays expanded (per-group, not global).
        state.toggle(alpha)
        XCTAssertTrue(state.isCollapsed(alpha))
        XCTAssertFalse(state.showsHits(alpha))
        XCTAssertTrue(state.showsHits(beta), "collapsing one group must not collapse a sibling group")

        // Toggling alpha again re-expands it; beta is still untouched.
        state.toggle(alpha)
        XCTAssertTrue(state.showsHits(alpha))
        XCTAssertTrue(state.showsHits(beta))
    }

    /// Collapse intent is keyed by ``PaneID`` (group identity), so a collapsed group keeps its state across a
    /// live re-run that re-orders the groups — and an UNRELATED pane id is never collapsed by it. A by-INDEX
    /// implementation would collapse whatever group happened to land at the same row after the re-order.
    func testCollapseStateKeyedByGroupIdentityNotIndex() {
        let first = PaneID()
        let second = PaneID()
        let stranger = PaneID()
        var state = GlobalSearchCollapseState()

        state.toggle(second) // collapse the second group only
        XCTAssertFalse(state.isCollapsed(first))
        XCTAssertTrue(state.isCollapsed(second))
        // A pane never seen by this state is expanded — a stale/foreign id never collapses the wrong group.
        XCTAssertTrue(state.showsHits(stranger))
        // Identity survives a value round-trip (the `@State` carries it across re-runs).
        XCTAssertEqual(state, GlobalSearchCollapseState(collapsed: [second]))
    }
}
