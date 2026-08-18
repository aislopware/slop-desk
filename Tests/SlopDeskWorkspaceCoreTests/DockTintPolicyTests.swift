import XCTest
@testable import SlopDeskWorkspaceCore

/// The Dock-tile CROSSING (``DockTintPolicy``) + the store aggregate it reads. The rollup crosses as the
/// wire's own `OSC 9;4` discriminant and the fraction comes back beside a `present` flag, so what is
/// pinned here is that each case reaches the byte it means and each answer is read back into the right
/// field. Which rollup tints, which animates, and the fraction the determinate one draws with are
/// `slopdesk_workspace::chrome::dock_tile`'s, and are tested there.
///
/// The AppKit actuation (`DockProgressController` drawing the `NSDockTile` + the `requestUserAttention`
/// bounce) is GUI-verified only — never instantiate an `NSDockTile` in a test.
@MainActor
final class DockTintPolicyTests: XCTestCase {
    private func resolve(
        _ rollup: PaneProgress?, failure: Bool = false, animate: Bool = true, badge: Bool = true,
    ) -> DockTileModel {
        DockTintPolicy.resolve(
            progressRollup: rollup, anyFailure: failure,
            animateProgressEnabled: animate, errorBadgeEnabled: badge,
        )
    }

    /// Each rollup case reaches its own discriminant: a spinner that crossed as the error byte would
    /// tint instead of animating, and a determinate value that crossed as the spinner's would lose its
    /// fraction. `nil` — the clear — crosses as no rollup at all.
    func testEachRollupCaseCrossesAsItsOwnDiscriminant() throws {
        let spinner = resolve(.indeterminate)
        XCTAssertTrue(spinner.animatesProgress)
        XCTAssertNil(spinner.determinateFraction, "a spinner has no fraction to draw")
        XCTAssertEqual(spinner.tint, .none)

        let bar = resolve(.determinate(percent: 40))
        XCTAssertTrue(bar.animatesProgress)
        XCTAssertEqual(try XCTUnwrap(bar.determinateFraction), 0.4, accuracy: 0.0001, "the percent came too")

        let held = resolve(.error(percent: 80))
        XCTAssertEqual(held.tint, .error)
        XCTAssertFalse(held.animatesProgress)

        XCTAssertEqual(resolve(nil), .inert, "nothing reported is the inert tile, not a stuck one")
    }

    /// The two toggles and the exit signal land in their own parameters — swapping either toggle at the
    /// door would tint what should animate, or animate what should only tint.
    func testTheTogglesAndTheExitLandInTheirOwnSlots() {
        XCTAssertEqual(resolve(.error(percent: 80), badge: false).tint, .none)
        XCTAssertEqual(resolve(nil, failure: true).tint, .error, "a failing exit alone tints")
        XCTAssertEqual(resolve(nil, failure: true, badge: false).tint, .none)
        XCTAssertFalse(resolve(.indeterminate, animate: false).animatesProgress)
        XCTAssertNil(resolve(.determinate(percent: 40), animate: false).determinateFraction)
    }

    // MARK: - store aggregate: dockTileModel reflects the cross-session union (default toggles)

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// With the default toggles (error-badge ON, animate OFF), a held `.error` progress on ANY pane tints the
    /// Dock; an all-clear leaves it inert. The Dock is process-global, so `dockTileModel` rolls up the whole
    /// tree (not one session). Revert-to-confirm-fail: a `dockTileModel` that ignored `paneProgress` would stay
    /// inert here.
    func testDockTileModelTintsOnErrorAndClears() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.tree.allPaneIDs().first)
        XCTAssertEqual(store.dockTileModel, .inert, "no progress → inert tile")

        store.handleProgress(.error(percent: 80), for: id)
        XCTAssertEqual(store.dockTileModel.tint, .error, "a held error tints the Dock red (badge default ON)")

        store.handleProgress(nil, for: id) // the failing session ends
        XCTAssertEqual(store.dockTileModel, .inert, "clearing the last error session resets the tile")
    }

    /// A `.failure` completion badge (a non-zero exit) on any pane also tints the Dock — the
    /// `anyFailureCompletion` half of the union.
    func testDockTileModelTintsOnFailureCompletion() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.setCompletionBadge(.failure, for: id)
        XCTAssertEqual(store.dockTileModel.tint, .error, "a non-zero exit tints the Dock red")

        store.setCompletionBadge(nil, for: id)
        XCTAssertEqual(store.dockTileModel, .inert, "clearing the failure resets the tile")
    }

    // MARK: - revealNextErrorPane: cycle through failing tabs, acknowledging + clearing the tint

    /// Clicking the tinted Dock (``revealNextErrorPane()``) jumps to a failing pane and ACKNOWLEDGES it, so a
    /// second call clears the LAST failing pane and the tint goes inert — the "jump to the next failing
    /// tab and clear the tint" cycle. Revert-to-confirm-fail: removing the `acknowledgeError` step leaves the
    /// tint stuck `.error` after both calls (the second assertion FAILS).
    func testRevealNextErrorPaneCyclesAndClearsTint() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })

        store.handleProgress(.error(percent: 10), for: first)
        store.handleProgress(.error(percent: 20), for: second)
        store.focusPaneTree(first)
        XCTAssertEqual(store.dockTileModel.tint, .error, "two failing panes tint the Dock")

        store.revealNextErrorPane()
        let activeAfterFirst = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertTrue([first, second].contains(activeAfterFirst), "the reveal jumped focus to a failing pane")
        XCTAssertEqual(store.dockTileModel.tint, .error, "one failing pane remains → still tinted")

        store.revealNextErrorPane()
        XCTAssertEqual(store.dockTileModel, .inert, "acknowledging the last failing pane clears the tint")
    }

    /// A no-op when nothing is failing (no trap, no spurious focus change).
    func testRevealNextErrorPaneNoOpWhenNoErrors() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.handleProgress(.indeterminate, for: id) // running, not failing
        let before = store.tree.activeSession?.activeTab?.activePane
        store.revealNextErrorPane()
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, before, "no failing pane → no focus jump")
        XCTAssertEqual(store.dockTileModel, .inert, "a running spinner with animate OFF is inert, not tinted")
    }
}
