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
        private(set) var actions: [String] = []
        var onWrite: ((Data) -> Void)?

        init(lines: [String]) { self.lines = lines }

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

    /// ES-E5-3 (find-next-opens-find): ⌘G with the bar closed OPENS it (faithful otty behaviour).
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
}
#endif
