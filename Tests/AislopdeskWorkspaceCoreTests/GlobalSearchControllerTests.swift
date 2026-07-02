import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// The pure ⇧⌘F Global Search engine (E5 WI-1): runs ``TerminalSearchController/computeMatches`` over every
/// terminal pane's scrollback mirror, drops zero-hit sources, groups by source, builds full-line excerpts with
/// UTF-16 highlight ranges, and produces the `N results — M tabs` summary. All against in-memory sources — no
/// view, no store, no libghostty.
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
        XCTAssertEqual(results.summary, "4 results — 2 tabs")
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

    // MARK: Case + regex honored (parity with TerminalSearchController flags)

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
        XCTAssertEqual(results.summary, "0 results — 0 tabs")
    }

    // MARK: Click-to-line navigation (ES-E5-5)

    /// The DEFINITIVE click-to-line invariant: two DIFFERENT hits on DIFFERENT lines in the SAME pane must
    /// `scroll_to_row` to those two DISTINCT lines in ALL THREE modes (literal case-insensitive, literal
    /// case-SENSITIVE, regex). Landing is mode-independent and viewport-independent — it never depends on an
    /// ordinal that case-sensitivity / regex / viewport can desync. The OLD literal path emitted
    /// `search:` + (ordinal+1)×`navigate_search:next` (no `scroll_to_row` at all in literal mode), so each of
    /// these `scroll_to_row` assertions fails on the un-fixed ordinal walk.
    func testNavigationActionsScrollToDistinctRowsInEveryMode() throws {
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

        // --- Mode 1: literal, case-INSENSITIVE. Arms the faithful literal highlight, THEN scrolls to the row.
        let insensitive = try hitsFor(
            query: "doc", caseSensitive: false, isRegex: false,
            lines: ["alpha DOC", "beta doc", "gamma Doc"],
        )
        let insFirst = GlobalSearchController.navigationActions(for: insensitive[0], query: "doc", caseSensitive: false)
        let insThird = GlobalSearchController.navigationActions(for: insensitive[2], query: "doc", caseSensitive: false)
        XCTAssertEqual(insFirst, ["search:doc", "scroll_to_row:\(insensitive[0].line)"])
        XCTAssertEqual(insThird, ["search:doc", "scroll_to_row:\(insensitive[2].line)"])
        XCTAssertNotEqual(insensitive[0].line, insensitive[2].line)
        XCTAssertNotEqual(insFirst, insThird, "distinct rows must scroll to distinct targets")

        // --- Mode 2: literal, case-SENSITIVE. Must NOT arm the (case-insensitive) literal matcher — clearing
        // any stale highlight and scrolling straight to the row. This is the revert-to-confirm-fail case: the
        // old code routed case-sensitive through the ordinal `navigate_search:next` walk, which both emits no
        // `scroll_to_row` AND mis-lands (case-sensitive ordinal ≠ libghostty's case-insensitive cursor).
        let sensitive = try hitsFor(
            query: "DOC", caseSensitive: true, isRegex: false,
            lines: ["alpha DOC", "beta DOC", "gamma DOC"],
        )
        let senFirst = GlobalSearchController.navigationActions(for: sensitive[0], query: "DOC", caseSensitive: true)
        let senThird = GlobalSearchController.navigationActions(for: sensitive[2], query: "DOC", caseSensitive: true)
        XCTAssertEqual(senFirst, ["end_search", "scroll_to_row:\(sensitive[0].line)"])
        XCTAssertEqual(senThird, ["end_search", "scroll_to_row:\(sensitive[2].line)"])
        XCTAssertNotEqual(sensitive[0].line, sensitive[2].line)
        XCTAssertNotEqual(senFirst, senThird, "distinct case-sensitive rows must scroll to distinct targets")
        XCTAssertFalse(
            senFirst.contains { $0.hasPrefix("search:") },
            "case-sensitive jump must not arm libghostty's case-insensitive literal matcher",
        )
        XCTAssertFalse(senThird.contains("navigate_search:next"), "case-sensitive jump must not step the cursor")

        // --- Mode 3: regex. Must NOT arm the literal matcher (no regex engine) — end + scroll straight to row.
        let regex = try hitsFor(
            query: #"\d+"#, caseSensitive: false, isRegex: true,
            lines: ["alpha 12", "beta 34", "gamma 56"],
        )
        let rxFirst = GlobalSearchController.navigationActions(for: regex[0], query: #"\d+"#, isRegex: true)
        let rxThird = GlobalSearchController.navigationActions(for: regex[2], query: #"\d+"#, isRegex: true)
        XCTAssertEqual(rxFirst, ["end_search", "scroll_to_row:\(regex[0].line)"])
        XCTAssertEqual(rxThird, ["end_search", "scroll_to_row:\(regex[2].line)"])
        XCTAssertNotEqual(regex[0].line, regex[2].line)
        XCTAssertNotEqual(rxFirst, rxThird, "distinct regex rows must scroll to distinct targets")
        XCTAssertFalse(
            rxThird.contains { $0.hasPrefix("search:") },
            "regex jump must not arm libghostty's literal search",
        )
        XCTAssertFalse(rxThird.contains("navigate_search:next"), "regex jump must not step the dead literal cursor")
        XCTAssertFalse(rxThird.contains("navigate_search:previous"))
    }

    /// Bug 1 (soft-wrap coordinate mapping): the click-to-line `scroll_to_row` must target the PHYSICAL grid
    /// row, not the logical (unwrapped) mirror index. When the caller passes the source `lines` + grid
    /// `columns`, a wide (wrapped) line above the hit shifts its physical row down. Revert-to-confirm-fail:
    /// the un-fixed `navigationActions` emitted `scroll_to_row:<hit.line>` (the logical index), one row too
    /// high per wrap continuation above the hit.
    func testNavigationActionsMapLogicalLineToPhysicalRowAcrossWrap() throws {
        // cols = 4. Row 0 ("abcdefgh", 8 cells) wraps to 2 physical rows; the "doc" on logical line 1 starts
        // at physical row 2.
        let lines = ["abcdefgh", "beta doc"]
        let results = GlobalSearchController.run(
            sources: [source("pane", lines)], query: "doc", caseSensitive: false, isRegex: false,
        )
        let hit = try XCTUnwrap(results.groups.first?.hits.first)
        XCTAssertEqual(hit.line, 1, "the match's LOGICAL mirror index is 1")

        // With the grid width, the logical line 1 maps to physical row 2 (past the 2-row wrapped line 0).
        let mapped = GlobalSearchController.navigationActions(
            for: hit, query: "doc", caseSensitive: false, isRegex: false, lines: lines, columns: 4,
        )
        XCTAssertEqual(mapped, ["search:doc", "scroll_to_row:2"])

        // Without a grid width (default), the mapping degrades to the identity — the pre-fix logical row.
        let unmapped = GlobalSearchController.navigationActions(for: hit, query: "doc")
        XCTAssertEqual(unmapped, ["search:doc", "scroll_to_row:1"])
    }

    /// An empty query arms nothing and scrolls nowhere (validate-then-drop) in every mode.
    func testNavigationActionsEmptyQueryYieldsNothing() throws {
        let results = GlobalSearchController.run(
            sources: [source("pane", ["a doc"])],
            query: "doc",
            caseSensitive: false,
            isRegex: false,
        )
        let hit = try XCTUnwrap(results.groups.first?.hits.first)
        XCTAssertEqual(GlobalSearchController.navigationActions(for: hit, query: ""), [])
        XCTAssertEqual(GlobalSearchController.navigationActions(for: hit, query: "", caseSensitive: true), [])
        XCTAssertEqual(GlobalSearchController.navigationActions(for: hit, query: "", isRegex: true), [])
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
