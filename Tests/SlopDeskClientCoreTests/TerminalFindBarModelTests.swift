// TerminalFindBarModelTests pins the in-pane find bar's driver (``TerminalFindBarModel``): what it ASKS
// the surface for, and what it publishes from the answer. The model is HEADLESS — its only renderer touch
// is `surface as? TerminalSurfaceActions`, which a pure in-memory ``FakeSearchSurface`` satisfies (NO real
// `TerminalSurfaceDriver` / VideoToolbox / Metal — the hang-safety rule; this mirrors the existing
// `CapturingSurface`/`RecordingSurface` fakes in `TerminalViewModelTests`).
//
// It moved here with the model (docs/56 §3): the driver never needed a view framework — it imported SwiftUI
// for `@Observable`, which is `Observation` — so both it and its suite belong below the UI targets, where the
// phone's find bar and the Mac's read one implementation.
//
// ⚠️ THE FAKE DOES NOT MATCH ANYTHING, and that is the point of this suite after gap 4. It RECORDS the
// query and the three toggles the bar handed it and ANSWERS a canned count, because the matching is
// `slopdesk-vterm`'s and has its own tests there — a fake that searched would be the second engine this
// change deleted, rebuilt inside the test target, which `CLAUDE.md` bans by name ("not a test fake"). What
// is worth pinning here is the crossing: that every mode goes out through the four-mode door, that no mode
// falls back to driving the viewport by row, and that the counter prints what came back rather than
// something this side derived.
//
// The bind-action strings are still asserted as STRINGS on purpose, even though the model builds them
// through ``TerminalSearchSurfaceAction``. They are libghostty-vt's wire vocabulary, not ours: a test that
// asserted `.end` against `.end` would pass on the day the enum's `wire` spelling drifted from what the
// surface parses.

import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

@MainActor
final class TerminalFindBarModelTests: XCTestCase {
    /// A pure in-memory terminal surface that RECORDS what the bar asked for and answers canned results.
    /// Hang-safe (no SCStream/VT/Metal).
    private final class FakeSearchSurface: TerminalSurface, TerminalSurfaceActions, @unchecked Sendable {
        /// One `find` as the bar spelled it — the assertion subject for every mode test.
        struct Find: Equatable {
            let query: String
            let caseSensitive: Bool
            let wholeWord: Bool
            let isRegex: Bool
        }

        private(set) var actions: [String] = []
        private(set) var finds: [Find] = []
        /// What the next ``find(_:caseSensitive:wholeWord:isRegex:)`` answers.
        var hitCount = 0
        /// What ``findPosition()`` answers.
        var position: (current: Int, total: Int)?
        var onWrite: ((Data) -> Void)?

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

        func scrollbackLines() -> [TerminalScrollbackLine] { [] }

        func find(_ query: String, caseSensitive: Bool, wholeWord: Bool, isRegex: Bool) -> Int {
            finds.append(Find(
                query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex,
            ))
            return hitCount
        }

        func findPosition() -> (current: Int, total: Int)? { position }

        /// Drop the recorded traffic so a test can assert on a fresh window without the open/query priming
        /// noise.
        func reset() {
            actions.removeAll()
            finds.removeAll()
        }
    }

    /// Build a find-bar model bound to a headless ``TerminalViewModel`` fed by a fake surface, run `body`, and
    /// keep the (weakly-held) vm + surface alive across it (the model holds the vm weakly; the vm holds the
    /// surface weakly).
    private func withBar(
        hits: Int = 3,
        at position: (current: Int, total: Int)? = (1, 3),
        _ body: (_ bar: TerminalFindBarModel, _ surface: FakeSearchSurface) -> Void,
    ) {
        let surface = FakeSearchSurface()
        surface.hitCount = hits
        surface.position = position
        let vm = TerminalViewModel(surface: surface)
        let bar = TerminalFindBarModel()
        bar.attach(vm)
        body(bar, surface)
        withExtendedLifetime((vm, surface)) {}
    }

    /// `open()` shows the bar; typing runs the query on the surface and PUBLISHES what came back.
    func testOpenShowsBarAndPublishesTheSurfacesCount() {
        withBar { bar, surface in
            XCTAssertFalse(bar.visible)
            bar.open()
            XCTAssertTrue(bar.visible)

            bar.setQuery("docs")
            XCTAssertEqual(surface.finds.last?.query, "docs")
            XCTAssertEqual(bar.matchCount, 3, "the count is the surface's, not one computed here")
            XCTAssertEqual(bar.positionLabel?.current, 1)
            XCTAssertEqual(bar.positionLabel?.total, 3)
        }
    }

    /// ↩/⌘G next + ⇧↩/⇧⌘G prev fire the nav bind-actions and re-read the surface's cursor afterwards.
    ///
    /// The RE-READ is the assertion worth having: the bar holds no index of its own, so a step that
    /// moved the surface's cursor and did not pull the new position would leave the counter frozen on
    /// the previous hit.
    func testNextPreviousFireSurfaceNavAndRereadThePosition() {
        withBar { bar, surface in
            bar.open()
            bar.setQuery("docs")

            surface.position = (2, 3)
            bar.next()
            XCTAssertEqual(bar.positionLabel?.current, 2)
            surface.position = (3, 3)
            bar.previous()
            XCTAssertEqual(bar.positionLabel?.current, 3)

            XCTAssertTrue(surface.actions.contains("navigate_search:next"))
            XCTAssertTrue(surface.actions.contains("navigate_search:previous"))
        }
    }

    /// A copy-mode `?` opens the bar in BACKWARD direction (``open(backward:)``), and the
    /// bar's vi `n`/`N` then step RELATIVE to that direction — `n` (``next()``) walks AGAINST the natural sense
    /// (`navigate_search:previous`, up the buffer) and `N` (``previous()``) WITH it (`navigate_search:next`,
    /// down). Vim parity: `n` repeats a search in its original direction, `N` opposite.
    ///
    /// Revert-to-confirm-fail: the pre-fix `next()`/`previous()` IGNORED direction — `next()` always fired
    /// `navigate_search:next` and `previous()` always `navigate_search:previous` — so after a BACKWARD open the
    /// assertion below fails (and `open(backward:)` didn't even exist).
    func testBackwardSearchInvertsNextAndPrevDirection() {
        withBar { bar, surface in
            bar.open(backward: true) // copy-mode `?` bias
            XCTAssertTrue(bar.searchBackward, "? opens the bar searching BACKWARD")
            bar.setQuery("docs")

            surface.reset() // drop the open/query priming so we assert only the n/N nav window
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
        withBar { bar, surface in
            bar.open() // ⌘F / `/` — forward by default
            XCTAssertFalse(bar.searchBackward, "⌘F / `/` opens the bar searching FORWARD")
            bar.setQuery("docs")

            surface.reset()
            bar.next()
            bar.previous()
            XCTAssertEqual(surface.actions, ["navigate_search:next", "navigate_search:previous"])
        }
    }

    /// Find-next-opens-find: ⌘G with the bar closed OPENS it.
    func testNextOpensBarWhenClosed() {
        withBar { bar, _ in
            XCTAssertFalse(bar.visible)
            bar.next()
            XCTAssertTrue(bar.visible)
        }
    }

    /// Esc/×: close clears the query + the counter, hides the bar, and ENDS the surface search (drops the
    /// in-buffer highlights).
    func testCloseClearsQueryHidesBarAndEndsSurfaceSearch() {
        withBar { bar, surface in
            bar.open()
            bar.setQuery("docs")
            XCTAssertFalse(bar.query.isEmpty)

            bar.close()
            XCTAssertFalse(bar.visible)
            XCTAssertEqual(bar.query, "")
            XCTAssertNil(bar.positionLabel)
            XCTAssertEqual(bar.matchCount, 0, "a closed bar reports nothing, not its last count")
            XCTAssertTrue(surface.actions.contains("end_search"))
        }
    }

    /// ⚠️ **GAP 4's REGRESSION GUARD, and the reason this suite exists in this shape.** Each of `Aa`, `ab`
    /// and `.*` reaches the surface as a FLAG on the four-mode door — never as a mode this side answers by
    /// scanning its own mirror and scrolling by row.
    ///
    /// Revert-to-confirm-fail: before the collapse, all three of these were "row-driven" — the bar computed
    /// its own match list, fired `end_search` and stepped `scroll_to_row:<n>`, and the `N of M` it printed
    /// came from a different scan than the cells the surface lit. Every assertion below fails on that model:
    /// `finds` would be empty (there was no door), and `scroll_to_row:` would be present.
    func testEveryModeCrossesAsAFlagAndNeverAsRowDrivenNav() {
        let cases: [(
            name: String,
            flip: (TerminalFindBarModel) -> Void,
            expect: (String) -> FakeSearchSurface.Find,
        )] = [
            ("Aa", { $0.toggleCaseSensitive() }, {
                .init(query: $0, caseSensitive: true, wholeWord: false, isRegex: false)
            }),
            ("ab", { $0.toggleWholeWord() }, {
                .init(query: $0, caseSensitive: false, wholeWord: true, isRegex: false)
            }),
            (".*", { $0.toggleRegex() }, {
                .init(query: $0, caseSensitive: false, wholeWord: false, isRegex: true)
            }),
        ]
        for mode in cases {
            withBar { bar, surface in
                bar.open()
                mode.flip(bar)
                surface.reset()
                bar.setQuery("do.")

                XCTAssertEqual(
                    surface.finds.last, mode.expect("do."),
                    "\(mode.name) must reach the surface as a flag on the query",
                )
                XCTAssertFalse(
                    surface.actions.contains(where: { $0.hasPrefix("scroll_to_row:") }),
                    "\(mode.name) must not drive the viewport by row — the surface owns the scroll",
                )

                surface.reset()
                bar.next()
                XCTAssertEqual(
                    surface.actions, ["navigate_search:next"],
                    "\(mode.name) steps the surface's own cursor like every other mode",
                )
            }
        }
    }

    /// The plain literal mode is the same path with three flags clear, which is what makes the door one
    /// route rather than a special case bolted beside the old one.
    func testLiteralModeTakesTheSameDoorWithEveryFlagClear() {
        withBar { bar, surface in
            bar.open()
            bar.setQuery("docs")
            XCTAssertEqual(
                surface.finds.last,
                .init(query: "docs", caseSensitive: false, wholeWord: false, isRegex: false),
            )
            XCTAssertFalse(
                surface.actions.contains(where: { $0.hasPrefix("scroll_to_row:") }),
                "literal mode owns its scroll via the surface, not scroll_to_row",
            )
        }
    }

    /// An empty field ENDS the search rather than running it: a stale highlight under a cleared query is
    /// the thing `slopdesk_workspace::find_bar::Arming` exists to prevent, and it must not reach the door
    /// as an empty needle either.
    func testAnEmptyQueryEndsTheSearchWithoutAskingTheDoor() {
        withBar { bar, surface in
            bar.open()
            bar.setQuery("docs")
            surface.reset()

            bar.setQuery("")
            XCTAssertTrue(surface.finds.isEmpty, "an empty field never runs a search")
            XCTAssertEqual(surface.actions, ["end_search"])
            XCTAssertEqual(bar.matchCount, 0)
            XCTAssertNil(bar.positionLabel)
        }
    }

    /// The find bar's `rectangle.stack` "search all tabs" button escalates to cross-tab Global Search
    /// SEEDED with the current query, then dismisses the in-pane bar. The button's function is pinned
    /// (`SearchIconButton("rectangle.stack") // search all tabs`), placed between the next-match
    /// chevron and the close ×.
    ///
    /// Revert-to-confirm-fail: without `searchAllTabs()` / `onSearchAllTabs` on the model, neither the seeded
    /// escalation nor the auto-dismiss exists.
    func testSearchAllTabsEscalatesWithSeededQueryThenCloses() {
        withBar { bar, _ in
            var seeded: String?
            bar.onSearchAllTabs = { seeded = $0 }
            bar.open()
            bar.setQuery("docs")

            bar.searchAllTabs()
            XCTAssertEqual(seeded, "docs", "escalation seeds Global Search with the live find query")
            XCTAssertFalse(bar.visible, "escalating to Global Search dismisses the in-pane find bar")
        }
    }

    /// Find bar close returns keyboard focus: closing the bar (Esc / × / search-all-tabs) must ask the
    /// surface to re-claim the window's first responder — closing tears down the focused query field without a
    /// workspace-focus change, so nothing else reclaims it and typing would go nowhere until the pane is clicked.
    /// Revert-to-confirm-fail: the un-fixed `close()` never called `reclaimKeyboardFocus()`, so `reclaimed`
    /// stays false.
    func testCloseReclaimsKeyboardFocusOnEveryClosePath() {
        // Esc / × path: close() directly.
        do {
            let surface = FakeSearchSurface()
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
            let surface = FakeSearchSurface()
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
