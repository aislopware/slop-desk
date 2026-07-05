import Defaults
import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

// MARK: - TerminalViewModelSecureInputTests (E17 ES-E17-4 / WI-7 — the LIVE Auto-Secure-Input pill reconcile)

/// Pins the `🛡 SECURE INPUT` pill mirror's reaction to a LIVE "Auto Secure Input" settings change. The model's
/// `refreshSecureInput()` reads the setting live, but it is only re-invoked from the `hostNoEcho` /
/// `manualSecureInput` `didSet`s — NEVER on a settings-toggle edge — so an engaged pill goes stale until the leaf
/// reconciles it via ``TerminalViewModel/reconcileSecureInputSetting()``. These tests drive that public seam
/// directly (no leaf / SwiftUI render — the hang-safety rule) by flipping the global `Defaults[.autoSecureInput]`
/// the model reads, then assert the pill mirror reconciles. The global is saved / restored so the round-trip
/// never leaks into other tests.
@MainActor
final class TerminalViewModelSecureInputTests: XCTestCase {
    /// The dev machine's real `autoSecureInput` default, captured so the test's writes never leak out.
    private var savedAuto = true

    override func setUp() {
        super.setUp()
        savedAuto = Defaults[.autoSecureInput]
    }

    override func tearDown() {
        Defaults[.autoSecureInput] = savedAuto
        super.tearDown()
    }

    #if os(macOS)
    /// Turning "Auto Secure Input" OFF live hides the pill AT ONCE on a pane already engaged on the AUTO path
    /// (host at a no-echo prompt). Revert-to-confirm-fail: with an empty `reconcileSecureInputSetting()` body the
    /// pill mirror stays lit after the setting flips, so the final assert fails — exactly the E17 footgun (the
    /// process-global lock + the pill linger against the user's just-expressed OFF preference).
    func testReconcileHidesPillWhenAutoTurnedOffLive() {
        Defaults[.autoSecureInput] = true
        let model = TerminalViewModel()
        model.hostNoEcho = true // host enters a no-echo prompt → the auto path lights the pill (didSet refresh)
        XCTAssertTrue(model.secureInputActive, "auto on + host no-echo lights the secure-input pill")

        Defaults[.autoSecureInput] = false // the user turns the setting OFF in Settings
        XCTAssertTrue(
            model.secureInputActive,
            "stale until reconciled — no model `didSet` fires on a global settings change",
        )

        model.reconcileSecureInputSetting()
        XCTAssertFalse(model.secureInputActive, "reconciling the live setting hides the pill immediately")
    }

    /// The reconcile honours the FULL engage formula `(auto && hostNoEcho) || manual` — a pane held secure by the
    /// MANUAL toggle stays lit even after Auto is turned off (manual is an independent reason). Guards against a
    /// reconcile that blindly clears the pill on any auto-off rather than recomputing the formula.
    func testReconcileLeavesManuallyHeldPillLit() {
        Defaults[.autoSecureInput] = true
        let model = TerminalViewModel()
        model.manualSecureInput = true // the Edit-menu / palette manual override
        XCTAssertTrue(model.secureInputActive, "manual on lights the pill")

        Defaults[.autoSecureInput] = false
        model.reconcileSecureInputSetting()
        XCTAssertTrue(model.secureInputActive, "the manual toggle keeps the pill lit regardless of the auto setting")
    }

    /// Turning Auto back ON live re-lights the pill while the host is still at a no-echo prompt — the reconcile is
    /// symmetric (it re-evaluates the formula, not a one-way clear).
    func testReconcileReLightsPillWhenAutoTurnedBackOn() {
        Defaults[.autoSecureInput] = false
        let model = TerminalViewModel()
        model.hostNoEcho = true // no-echo prompt up, but auto is off → pill dark
        XCTAssertFalse(model.secureInputActive, "auto off leaves the pill dark even at a no-echo prompt")

        Defaults[.autoSecureInput] = true
        model.reconcileSecureInputSetting()
        XCTAssertTrue(model.secureInputActive, "re-enabling Auto re-lights the pill while the prompt is still up")
    }
    #endif
}
