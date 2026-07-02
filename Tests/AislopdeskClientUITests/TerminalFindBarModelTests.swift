// TerminalFindBarModelTests — E5 / WI-3. Pins the in-pane find bar's view-model (``TerminalFindBarModel``):
// the driver over the PURE ``TerminalSearchController`` (count / N-of-M / next-prev-wrap) + the libghostty
// `search:` / `navigate_search:` / `end_search` passthrough. The model is HEADLESS — its only renderer touch
// is `surface as? TerminalSurfaceActions`, which a pure in-memory ``FakeSearchSurface`` satisfies (NO real
// `GhosttySurface` / VideoToolbox / Metal — the hang-safety rule; this mirrors the existing
// `CapturingSurface`/`RecordingSurface` fakes in `TerminalViewModelTests`).
//
// Every case FAILS on the un-fixed tree (the model did not exist before WI-3) and asserts an observable state
// transition (visibility / query / flags / `N of M` / the fired bind-action strings) against expected values,
// never against the output's own derivation.

#if canImport(SwiftUI)
import AislopdeskTerminal
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class TerminalFindBarModelTests: XCTestCase {
    /// A pure in-memory terminal surface: returns a canned scrollback mirror for `searchScrollbackLines()` and
    /// RECORDS the libghostty bind-action strings (`search:…` / `navigate_search:…` / `end_search`) the find
    /// bar fires, so the driver is pinned without a real renderer. Hang-safe (no SCStream/VT/Metal).
    private final class FakeSearchSurface: TerminalSurface, TerminalSurfaceActions, @unchecked Sendable {
        var lines: [String]
        /// The reported grid width for the physical-row mapping (0 ⇒ unknown ⇒ identity mapping).
        var columns: Int
        private(set) var actions: [String] = []
        var onWrite: ((Data) -> Void)?

        init(lines: [String], columns: Int = 0) {
            self.lines = lines
            self.columns = columns
        }

        // TerminalSurface
        func feed(_: Data) {}
        func setSize(cols _: UInt16, rows _: UInt16) {}
        func handleInput(_: Data) {}

        // TerminalSurfaceActions
        func hasSelection() -> Bool { false }
        func readSelection() -> String? { nil }
        func performBindingAction(_ action: String) -> Bool {
            actions.append(action)
            return true
        }

        func scrollbackTextLines() -> [String] { lines }
        func scrollbackGridColumns() -> Int { columns }

        /// Drop the recorded actions so a test can assert on a fresh window of bind-actions (e.g. only those
        /// fired by a subsequent `next()`/`previous()`), without the open/query priming noise.
        func resetActions() { actions.removeAll() }
    }

    /// Build a find-bar model bound to a headless ``TerminalViewModel`` fed by a fake surface, run `body`, and
    /// keep the (weakly-held) vm + surface alive across it (the model holds the vm weakly; the vm holds the
    /// surface weakly).
    private func withBar(
        lines: [String],
        _ body: (_ bar: TerminalFindBarModel, _ surface: FakeSearchSurface) -> Void,
    ) {
        let surface = FakeSearchSurface(lines: lines)
        let vm = TerminalViewModel(surface: surface)
        let bar = TerminalFindBarModel()
        bar.attach(vm)
        body(bar, surface)
        withExtendedLifetime((vm, surface)) {}
    }

    /// ES-E5-1/2: `open()` shows the bar; typing live-counts every match over the snapshot mirror (`N of M`).
    func testOpenShowsBarAndCountsMatches() {
        withBar(lines: ["read the docs here", "no hits", "more docs and docs"]) { bar, _ in
            XCTAssertFalse(bar.visible)
            bar.open()
            XCTAssertTrue(bar.visible)

            bar.setQuery("docs")
            XCTAssertEqual(bar.controller.matchCount, 3) // line0 ×1 + line2 ×2
            XCTAssertEqual(bar.controller.positionLabel?.current, 1)
            XCTAssertEqual(bar.controller.positionLabel?.total, 3)
        }
    }

    /// ES-E5-3: ↩/⌘G next + ⇧↩/⇧⌘G prev advance + wrap the selection AND fire the libghostty nav bind-actions.
    func testNextPreviousWrapAndFireSurfaceNav() {
        withBar(lines: ["docs", "docs", "docs"]) { bar, surface in
            bar.open()
            bar.setQuery("docs") // 3 matches; current = 1
            XCTAssertTrue(surface.actions.contains("search:docs"))

            bar.next()
            XCTAssertEqual(bar.controller.positionLabel?.current, 2)
            bar.next()
            bar.next() // wraps past the last → back to 1
            XCTAssertEqual(bar.controller.positionLabel?.current, 1)
            bar.previous() // wraps past the first → last (3)
            XCTAssertEqual(bar.controller.positionLabel?.current, 3)

            XCTAssertTrue(surface.actions.contains("navigate_search:next"))
            XCTAssertTrue(surface.actions.contains("navigate_search:previous"))
        }
    }

    /// E17 ES-E17-2 / WI-5: a copy-mode `?` opens the bar in BACKWARD direction (``open(backward:)``), and the
    /// bar's vi `n`/`N` then step RELATIVE to that direction — `n` (``next()``) walks AGAINST the natural sense
    /// (`navigate_search:previous`, up the buffer) and `N` (``previous()``) WITH it (`navigate_search:next`,
    /// down). Vim parity: `n` repeats a search in its original direction, `N` opposite.
    ///
    /// Revert-to-confirm-fail: the pre-fix `next()`/`previous()` IGNORED direction — `next()` always fired
    /// `navigate_search:next` and `previous()` always `navigate_search:previous` — so after a BACKWARD open the
    /// first two assertions below (next ⇒ previous, prev ⇒ next) fail (and `open(backward:)` didn't even exist).
    func testBackwardSearchInvertsNextAndPrevDirection() {
        withBar(lines: ["docs", "docs", "docs"]) { bar, surface in
            bar.open(backward: true) // copy-mode `?` bias
            XCTAssertTrue(bar.searchBackward, "? opens the bar searching BACKWARD")
            bar.setQuery("docs")

            surface.resetActions() // drop the open/query priming so we assert only the n/N nav window
            bar.next() // vi `n` under a backward search → step UP the buffer
            bar.previous() // vi `N` under a backward search → step DOWN the buffer
            XCTAssertEqual(
                surface.actions,
                ["navigate_search:previous", "navigate_search:next"],
                "backward search inverts n/N: n steps backward (previous), N steps forward (next)",
            )
        }
    }

    /// Companion guard: a FORWARD search (the ⌘F / `/` default, `searchBackward == false`) keeps the natural
    /// sense — `next()` (vi `n`) steps `navigate_search:next` and `previous()` (vi `N`) `navigate_search:previous`
    /// — so the direction fix never regresses the common forward path.
    func testForwardSearchKeepsNaturalNextPrevDirection() {
        withBar(lines: ["docs", "docs", "docs"]) { bar, surface in
            bar.open() // ⌘F / `/` — forward by default
            XCTAssertFalse(bar.searchBackward, "⌘F / `/` opens the bar searching FORWARD")
            bar.setQuery("docs")

            surface.resetActions()
            bar.next()
            bar.previous()
            XCTAssertEqual(surface.actions, ["navigate_search:next", "navigate_search:previous"])
        }
    }

    /// ES-E5-3 (find-next-opens-find): ⌘G with the bar closed OPENS it.
    func testNextOpensBarWhenClosed() {
        withBar(lines: ["docs"]) { bar, _ in
            XCTAssertFalse(bar.visible)
            bar.next()
            XCTAssertTrue(bar.visible)
        }
    }

    /// ES-E5-3 (Esc/×): close clears the query + matches, hides the bar, and ENDS the surface search (drops the
    /// in-buffer highlights).
    func testCloseClearsQueryHidesBarAndEndsSurfaceSearch() {
        withBar(lines: ["docs"]) { bar, surface in
            bar.open()
            bar.setQuery("docs")
            XCTAssertFalse(bar.controller.query.isEmpty)

            bar.close()
            XCTAssertFalse(bar.visible)
            XCTAssertEqual(bar.controller.query, "")
            XCTAssertNil(bar.controller.positionLabel)
            XCTAssertTrue(surface.actions.contains("end_search"))
        }
    }

    /// ES-E5-4 (`Aa`): the case toggle flips the flag, refreshes the mirror, and narrows the match set.
    func testCaseToggleNarrowsMatches() {
        withBar(lines: ["DOCS docs Docs"]) { bar, _ in
            bar.open()
            bar.setQuery("docs")
            XCTAssertEqual(bar.controller.matchCount, 3) // case-insensitive default

            bar.toggleCaseSensitive()
            XCTAssertTrue(bar.controller.caseSensitive)
            XCTAssertEqual(bar.controller.matchCount, 1) // only the exact "docs"
        }
    }

    /// ES-E5-4 (`.*`): the regex toggle flips the flag and switches literal → ICU pattern matching.
    func testRegexToggleSwitchesToPatternMatching() {
        withBar(lines: ["a1 b2 c3"]) { bar, _ in
            bar.open()
            bar.setQuery("[0-9]")
            XCTAssertEqual(bar.controller.matchCount, 0, "literal mode finds no '[0-9]' substring")

            bar.toggleRegex()
            XCTAssertTrue(bar.controller.isRegex)
            XCTAssertEqual(bar.controller.matchCount, 3, "regex mode matches the three digits")
        }
    }

    /// ES-E5-4 (regex-mode honesty fix): in `.*` mode the bar must NOT arm libghostty's LITERAL search
    /// (`search:<pattern>` / `navigate_search:`) — that matcher has no regex engine, so it would paint a
    /// misleading literal highlight beside the controller's correct regex count and leave the chevrons dead.
    /// Instead each open / next / previous drives in-grid navigation from the controller's own match rows via
    /// `scroll_to_row:<row>` (DISTINCT per match), and ends the literal search so no stale highlight lingers.
    /// Revert-to-confirm-fail: the un-fixed `armSearch`/`next` always arm `search:` + `navigate_search:`, so
    /// the "no literal action in regex mode" + "distinct scroll_to_row per match" assertions fail on it.
    func testRegexModeDrivesScrollToRowNotLiteralSearch() {
        // Three regex matches of `do.`, each on a DISTINCT row (rows 0, 2, 4 of the mirror).
        withBar(lines: ["do1", "xxx", "do2", "yyy", "do3"]) { bar, surface in
            bar.open()
            bar.toggleRegex() // flip to regex BEFORE querying so no literal `search:` is ever armed for it
            XCTAssertTrue(bar.controller.isRegex)

            bar.setQuery("do.")
            XCTAssertEqual(bar.controller.matchCount, 3, "regex `do.` matches do1/do2/do3")
            // The literal needle is NEVER pushed to libghostty in regex mode (would highlight 0 hits + lie).
            XCTAssertFalse(
                surface.actions.contains("search:do."),
                "regex mode must not arm libghostty's literal search",
            )
            // Open arms end_search (clear stale highlight) + scrolls to the first match's row (0).
            XCTAssertTrue(surface.actions.contains("scroll_to_row:0"), "open scrolls to the first regex match row")

            // next / previous emit DISTINCT grid-nav intent per match — and NEVER the literal navigate_search.
            surface.resetActions()
            bar.next() // match 2 → row 2
            bar.next() // match 3 → row 4
            XCTAssertEqual(
                surface.actions,
                ["scroll_to_row:2", "scroll_to_row:4"],
                "regex next steps the viewport to each match's distinct row",
            )
            bar.previous() // back to match 2 → row 2
            XCTAssertEqual(surface.actions.last, "scroll_to_row:2", "regex previous scrolls back to the prior row")
            XCTAssertFalse(
                surface.actions.contains(where: { $0.hasPrefix("navigate_search:") }),
                "regex mode never fires libghostty's literal navigate_search (it would move nothing)",
            )
        }
    }

    /// `ab` whole-word: the toggle flips the controller flag and NARROWS the literal match set to standalone
    /// words (`the` matches "the"/"the cat" but not "theory"). Because libghostty's literal in-surface search
    /// has no word-boundary filter, whole-word mode (like regex) must NOT arm `search:`/`navigate_search:` —
    /// it ends the literal search and drives the viewport from its own match rows via `scroll_to_row` so the
    /// chevrons step the SAME set the counter reports. Revert-to-confirm-fail: the un-fixed model had no
    /// `toggleWholeWord()` and armed `search:the` for any literal query, so both assertions below fail on it.
    func testWholeWordTogglesNarrowMatchesAndDriveRowNav() {
        // Standalone "the" on rows 0 and 2; "theory" on row 1 holds "the" only as a substring.
        withBar(lines: ["the", "theory", "the cat"]) { bar, surface in
            bar.open()
            bar.toggleWholeWord() // flip BEFORE querying so no literal `search:` is ever armed for it
            XCTAssertTrue(bar.controller.wholeWord)

            bar.setQuery("the")
            XCTAssertEqual(bar.controller.matchCount, 2, "whole-word drops the 'the' buried in 'theory'")
            XCTAssertFalse(
                surface.actions.contains("search:the"),
                "whole-word mode must not arm libghostty's literal (no-boundary) search",
            )
            XCTAssertTrue(
                surface.actions.contains("scroll_to_row:0"),
                "open scrolls to the first whole-word match row",
            )

            surface.resetActions()
            bar.next() // second match → row 2
            XCTAssertEqual(surface.actions, ["scroll_to_row:2"], "whole-word next steps the viewport by row")
            XCTAssertFalse(
                surface.actions.contains(where: { $0.hasPrefix("navigate_search:") }),
                "whole-word mode never fires libghostty's literal navigate_search",
            )
        }
    }

    /// Companion guard: LITERAL mode is UNCHANGED by the regex fix — it still arms `search:` and steps
    /// libghostty's own `navigate_search:next`/`previous` (the ac2c7a8 fix), and never falls back to scroll_to_row.
    func testLiteralModeStillArmsSearchAndNavigateSearch() {
        withBar(lines: ["docs", "docs"]) { bar, surface in
            bar.open()
            bar.setQuery("docs")
            XCTAssertTrue(surface.actions.contains("search:docs"))

            surface.resetActions()
            bar.next()
            bar.previous()
            XCTAssertEqual(surface.actions, ["navigate_search:next", "navigate_search:previous"])
            XCTAssertFalse(
                surface.actions.contains(where: { $0.hasPrefix("scroll_to_row:") }),
                "literal mode owns its scroll via navigate_search, not scroll_to_row",
            )
        }
    }

    /// Batch-5: the find bar's `rectangle.stack` "search all tabs" button escalates to cross-tab Global Search
    /// SEEDED with the current query, then dismisses the in-pane bar. The button's function is pinned
    /// (`SearchIconButton("rectangle.stack") // search all tabs`), placed between the next-match
    /// chevron and the close ×.
    ///
    /// Revert-to-confirm-fail: before this batch the model had NO `searchAllTabs()` / `onSearchAllTabs` seam
    /// (the button was a deliberate omission), so neither the seeded escalation nor the auto-dismiss existed.
    func testSearchAllTabsEscalatesWithSeededQueryThenCloses() {
        withBar(lines: ["read the docs", "more docs"]) { bar, _ in
            var seeded: String?
            bar.onSearchAllTabs = { seeded = $0 }
            bar.open()
            bar.setQuery("docs")

            bar.searchAllTabs()
            XCTAssertEqual(seeded, "docs", "escalation seeds Global Search with the live find query")
            XCTAssertFalse(bar.visible, "escalating to Global Search dismisses the in-pane find bar")
        }
    }

    /// Bug 2 (Aa case-sensitive honesty): libghostty's in-surface matcher is HARD-WIRED case-insensitive, so
    /// case-SENSITIVE literal mode must NOT arm `search:` / `navigate_search:` (they would highlight + step
    /// case-folded occurrences the case-sensitive counter says don't exist). Like regex / whole-word, it drives
    /// the viewport from the controller's own match rows via `scroll_to_row` (end_search clears any stale
    /// highlight). Revert-to-confirm-fail: the un-fixed `needsRowDrivenNav` omitted `caseSensitive`, so Aa mode
    /// armed `search:foo` + `navigate_search:` — the assertions below fail on it.
    func testCaseSensitiveModeDrivesScrollToRowNotLiteralSearch() {
        // "foo" (case-sensitive) matches ONLY the exact-case "foo" on row 1; "Foo"/"FOO" are case-folded misses.
        withBar(lines: ["Foo", "foo", "FOO"]) { bar, surface in
            bar.open()
            bar.toggleCaseSensitive() // flip BEFORE querying so no literal `search:` is ever armed for it
            XCTAssertTrue(bar.controller.caseSensitive)

            bar.setQuery("foo")
            XCTAssertEqual(bar.controller.matchCount, 1, "case-sensitive 'foo' matches only the exact-case row")
            XCTAssertFalse(
                surface.actions.contains("search:foo"),
                "case-sensitive mode must not arm libghostty's case-INSENSITIVE literal search",
            )
            XCTAssertTrue(
                surface.actions.contains("scroll_to_row:1"),
                "case-sensitive open scrolls to the sole matching row (1)",
            )

            surface.resetActions()
            bar.next() // single match ⇒ re-scrolls to the same row, NEVER navigate_search
            XCTAssertEqual(surface.actions, ["scroll_to_row:1"])
            XCTAssertFalse(
                surface.actions.contains(where: { $0.hasPrefix("navigate_search:") }),
                "case-sensitive mode never fires libghostty's literal navigate_search",
            )
        }
    }

    /// Bug 1 (soft-wrap coordinate mapping): a row-driven `scroll_to_row` must target the PHYSICAL grid row,
    /// not the logical (unwrapped) mirror index — every soft-wrapped continuation row ABOVE the match shifts
    /// the physical row down. With a known grid width, a wide line above the hit adds its wrap rows.
    /// Revert-to-confirm-fail: the un-fixed `scrollToCurrentMatchRow` emitted `scroll_to_row:<Match.line>`
    /// (the logical index, 1), landing one row too high; the fix maps it through the grid width.
    func testRowDrivenNavMapsLogicalLineToPhysicalRowAcrossWrap() {
        // cols = 4. Row 0 is 8 cells wide ⇒ wraps to 2 physical rows (0,1). The regex match on logical line 1
        // ("do1", 3 cells, 1 row) therefore STARTS at physical row 2, not 1.
        let surface = FakeSearchSurface(lines: ["abcdefgh", "do1"], columns: 4)
        let vm = TerminalViewModel(surface: surface)
        let bar = TerminalFindBarModel()
        bar.attach(vm)
        bar.open()
        bar.toggleRegex()
        bar.setQuery("do.")
        XCTAssertEqual(bar.controller.matchCount, 1, "regex `do.` matches the row-1 'do1'")
        XCTAssertEqual(bar.controller.current?.line, 1, "the match's LOGICAL mirror index is 1")
        XCTAssertTrue(
            surface.actions.contains("scroll_to_row:2"),
            "the logical line 1 maps to physical row 2 (the wide row 0 occupies 2 physical rows)",
        )
        XCTAssertFalse(
            surface.actions.contains("scroll_to_row:1"),
            "must NOT scroll to the un-mapped logical index (one physical row too high)",
        )
        withExtendedLifetime((vm, surface)) {}
    }

    /// Bug 3 (find bar close returns keyboard focus): closing the bar (Esc / × / search-all-tabs) must ask the
    /// surface to re-claim the window's first responder — closing tears down the focused query field without a
    /// workspace-focus change, so nothing else reclaims it and typing would go nowhere until the pane is clicked.
    /// Revert-to-confirm-fail: the un-fixed `close()` never called `reclaimKeyboardFocus()`, so `reclaimed`
    /// stays false.
    func testCloseReclaimsKeyboardFocusOnEveryClosePath() {
        // Esc / × path: close() directly.
        do {
            let surface = FakeSearchSurface(lines: ["docs"])
            let vm = TerminalViewModel(surface: surface)
            var reclaimed = 0
            vm.onReclaimKeyboardFocus = { reclaimed += 1 }
            let bar = TerminalFindBarModel()
            bar.attach(vm)
            bar.open()
            bar.setQuery("docs")
            bar.close()
            XCTAssertEqual(reclaimed, 1, "Esc/× close returns first responder to the terminal surface")
            withExtendedLifetime((vm, surface)) {}
        }
        // search-all-tabs path funnels through close() too.
        do {
            let surface = FakeSearchSurface(lines: ["docs"])
            let vm = TerminalViewModel(surface: surface)
            var reclaimed = 0
            vm.onReclaimKeyboardFocus = { reclaimed += 1 }
            let bar = TerminalFindBarModel()
            bar.attach(vm)
            bar.onSearchAllTabs = { _ in }
            bar.open()
            bar.searchAllTabs()
            XCTAssertEqual(reclaimed, 1, "search-all-tabs escalation also returns first responder")
            withExtendedLifetime((vm, surface)) {}
        }
    }
}
#endif
