import XCTest
@testable import SlopDeskWorkspaceCore

/// The PURE macOS Dock-tile decision (``DockTintPolicy``) + the store aggregate it reads.
/// The AppKit actuation (`DockProgressController` drawing the `NSDockTile` + the `requestUserAttention` bounce)
/// is GUI-verified only (never instantiate an `NSDockTile` in a test); EVERY decision the controller
/// makes is one of these pure functions, pinned here. Headless: pure static + a `FakePaneSession` store (no
/// AppKit, no socket).
@MainActor
final class DockTintPolicyTests: XCTestCase {
    // MARK: - tint(forRollup:) — the plan-pinned function

    /// An `.error` rollup tints red; an in-progress / indeterminate / cleared rollup leaves it untinted. This
    /// is the decision the Dock red-on-error reads. Revert-to-confirm-fail: collapsing `tint` to always-`.none`
    /// makes the error case FAIL.
    func testTintIsErrorOnlyForErrorRollup() {
        XCTAssertEqual(DockTintPolicy.tint(forRollup: .error(percent: 80)), .error)
        XCTAssertEqual(DockTintPolicy.tint(forRollup: .indeterminate), .none, "a spinner is not an error")
        XCTAssertEqual(DockTintPolicy.tint(forRollup: .determinate(percent: 40)), .none, "in-progress is not an error")
        XCTAssertEqual(DockTintPolicy.tint(forRollup: nil), .none, "a clear is not an error")
    }

    // MARK: - resolve(...) — the complete tile decision (toggles + non-zero-exit signal)

    /// The error tint requires the `dock-icon-error-badge` toggle ON: an `.error` rollup with the toggle OFF
    /// produces NO tint. Revert-to-confirm-fail: dropping the `errorBadgeEnabled &&` gate makes the OFF case FAIL.
    func testErrorTintGatedByErrorBadgeToggle() {
        let on = DockTintPolicy.resolve(
            progressRollup: .error(percent: 80), anyFailure: false,
            animateProgressEnabled: false, errorBadgeEnabled: true,
        )
        XCTAssertEqual(on.tint, .error, "error rollup + badge ON → red")

        let off = DockTintPolicy.resolve(
            progressRollup: .error(percent: 80), anyFailure: false,
            animateProgressEnabled: false, errorBadgeEnabled: false,
        )
        XCTAssertEqual(off.tint, .none, "error rollup + badge OFF → no tint")
    }

    /// A non-zero EXIT (a `.failure` completion badge, surfaced as `anyFailure`) tints red even with NO `.error`
    /// progress — the spec "tints when any session reports a non-zero exit OR OSC 9;4;2". Gated by the toggle.
    func testNonZeroExitTintsEvenWithoutErrorProgress() {
        let model = DockTintPolicy.resolve(
            progressRollup: nil, anyFailure: true,
            animateProgressEnabled: false, errorBadgeEnabled: true,
        )
        XCTAssertEqual(model.tint, .error, "a failing exit alone tints the Dock red")

        let gated = DockTintPolicy.resolve(
            progressRollup: nil, anyFailure: true,
            animateProgressEnabled: false, errorBadgeEnabled: false,
        )
        XCTAssertEqual(gated.tint, .none, "the error-badge toggle gates the exit tint too")
    }

    /// Animation requires the `dock-icon-animate-progress` toggle ON AND a RUNNING aggregate: an indeterminate
    /// spinner animates with NO determinate fraction; a determinate value animates WITH its clamped fraction; a
    /// held error never animates; the toggle OFF never animates. Revert-to-confirm-fail: dropping the
    /// `animateProgressEnabled` gate makes the OFF assertions FAIL.
    func testAnimationGatedByToggleAndRunningState() throws {
        let spinner = DockTintPolicy.resolve(
            progressRollup: .indeterminate, anyFailure: false,
            animateProgressEnabled: true, errorBadgeEnabled: true,
        )
        XCTAssertTrue(spinner.animatesProgress, "an indeterminate spinner animates")
        XCTAssertNil(spinner.determinateFraction, "a spinner has no determinate fraction")

        let bar = DockTintPolicy.resolve(
            progressRollup: .determinate(percent: 40), anyFailure: false,
            animateProgressEnabled: true, errorBadgeEnabled: true,
        )
        XCTAssertTrue(bar.animatesProgress, "a determinate value animates")
        XCTAssertEqual(try XCTUnwrap(bar.determinateFraction), 0.4, accuracy: 0.0001, "40% → 0.4 fraction")

        let held = DockTintPolicy.resolve(
            progressRollup: .error(percent: 80), anyFailure: false,
            animateProgressEnabled: true, errorBadgeEnabled: true,
        )
        XCTAssertFalse(held.animatesProgress, "a held error never animates")

        let toggledOff = DockTintPolicy.resolve(
            progressRollup: .indeterminate, anyFailure: false,
            animateProgressEnabled: false, errorBadgeEnabled: true,
        )
        XCTAssertFalse(toggledOff.animatesProgress, "the animate toggle OFF suppresses the animation")
    }

    /// A full / clamped determinate value maps its fraction into `0…1` (no fused multiply, ordered clamp).
    func testDeterminateFractionClampsToUnit() throws {
        let full = DockTintPolicy.resolve(
            progressRollup: .determinate(percent: 100), anyFailure: false,
            animateProgressEnabled: true, errorBadgeEnabled: true,
        )
        XCTAssertEqual(try XCTUnwrap(full.determinateFraction), 1.0, accuracy: 0.0001)

        let zero = DockTintPolicy.resolve(
            progressRollup: .determinate(percent: 0), anyFailure: false,
            animateProgressEnabled: true, errorBadgeEnabled: true,
        )
        XCTAssertEqual(try XCTUnwrap(zero.determinateFraction), 0.0, accuracy: 0.0001)
    }

    /// Nothing reported + no failure → the inert tile (the CLEAR state the controller restores when the last
    /// progress/error session ends — the carryover "no stuck red tile" trap).
    func testNothingReportedIsInert() {
        let model = DockTintPolicy.resolve(
            progressRollup: nil, anyFailure: false,
            animateProgressEnabled: true, errorBadgeEnabled: true,
        )
        XCTAssertEqual(model, .inert)
        XCTAssertTrue(model.isInert)
    }

    // MARK: - store aggregate: dockTileModel reflects the cross-session union (default toggles)

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
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
