import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The Agents settings-card model ``AgentHooksController``: the install / uninstall /
/// status state machine driven through three injected async seams (the app wires them to the active
/// connection's first-pane ``MetadataClient``; here they are fakes). Each behavior has a test that FAILS on
/// the un-fixed code:
/// - `refresh()` folds the typed status report — installed+listener → `.installed`, installed with the
///   listener DOWN → `.installedInactive` (the false-green bug — hooks
///   written to settings.json while hostd was launched without `SLOPDESK_AGENT_HOOKS=1` are DEAD, so the
///   card must warn, not show "✓ Installed"), not-installed → `.notInstalled`, `nil` → `.disconnected`
///   (the nil case is what keeps the card off a FALSE "Not Installed");
/// - `install()`/`uninstall()` transition THROUGH `.working` (captured inside the seam); install RE-PROBES
///   on success too (a successful settings write does NOT prove the listener is bound) and both re-probe on
///   failure rather than getting stuck `.working`;
/// - `refresh()` is a no-op while a write owns `.working` (a concurrent appear-probe can't clobber it).
@MainActor
final class AgentHooksControllerTests: XCTestCase {
    private typealias Report = MetadataClient.AgentHookStatusReport

    private static let active = Report(installed: true, listenerActive: true)
    private static let inactive = Report(installed: true, listenerActive: false)
    private static let notInstalled = Report(installed: false, listenerActive: false)

    // MARK: refresh() folds the typed status report

    func testRefreshInstalledWithListenerGivesInstalled() async {
        let controller = AgentHooksController(refreshStatus: { Self.active })
        await controller.refresh()
        XCTAssertEqual(controller.state, .installed)
        XCTAssertTrue(controller.isInstalled)
    }

    /// The false-green fix — installed on disk but the host hook
    /// listener is unbound ⇒ `.installedInactive`, NEVER the green `.installed`.
    func testRefreshInstalledWithoutListenerGivesInstalledInactive() async {
        let controller = AgentHooksController(refreshStatus: { Self.inactive })
        await controller.refresh()
        XCTAssertEqual(
            controller.state, .installedInactive,
            "hooks in settings.json + no bound listener = a DEAD integration — warn, don't show green",
        )
        XCTAssertTrue(controller.isInstalled, "the entries ARE on disk — Uninstall/behaviour stay available")
        XCTAssertTrue(controller.actionsEnabled, "Uninstall remains actionable from the inactive state")
    }

    func testRefreshNotInstalledGivesNotInstalled() async {
        let controller = AgentHooksController(refreshStatus: { Self.notInstalled })
        await controller.refresh()
        XCTAssertEqual(controller.state, .notInstalled)
        XCTAssertFalse(controller.isInstalled)
        XCTAssertTrue(controller.actionsEnabled, "a known, connected state ⇒ the buttons are actionable")
    }

    func testRefreshNilGivesDisconnected() async {
        let controller = AgentHooksController(refreshStatus: { nil })
        await controller.refresh()
        XCTAssertEqual(controller.state, .disconnected, "a nil status (no connected pane) ⇒ .disconnected")
        XCTAssertTrue(controller.isDisconnected)
        XCTAssertFalse(controller.actionsEnabled, "the buttons disable while no pane backs the card")
    }

    // MARK: install() / uninstall() success paths

    /// A successful install RE-PROBES (it does not blindly land `.installed`): with the listener live
    /// the probe lands the green `.installed`.
    func testInstallSuccessWithLiveListenerGivesInstalled() async {
        let host = FakeHooksHost(listenerActive: true)
        let controller = AgentHooksController(
            install: { host.installed = true
                return true
            },
            refreshStatus: { host.report },
        )
        await controller.refresh()
        XCTAssertEqual(controller.state, .notInstalled)
        await controller.install()
        XCTAssertEqual(controller.state, .installed)
    }

    /// Clicking Install on a hostd with NO bound listener must land
    /// `.installedInactive` — landing `.installed` directly would flash the false green
    /// over a dead integration.
    func testInstallSuccessWithoutListenerGivesInstalledInactive() async {
        let host = FakeHooksHost(listenerActive: false)
        let controller = AgentHooksController(
            install: { host.installed = true
                return true
            },
            refreshStatus: { host.report },
        )
        await controller.install()
        XCTAssertEqual(
            controller.state, .installedInactive,
            "a successful settings write does NOT prove the listener — the re-probe lands the honest state",
        )
    }

    func testUninstallSuccessGivesNotInstalled() async {
        let controller = AgentHooksController(uninstall: { true }, refreshStatus: { Self.active })
        await controller.refresh()
        XCTAssertEqual(controller.state, .installed)
        await controller.uninstall()
        XCTAssertEqual(controller.state, .notInstalled)
    }

    func testUninstallReversesInstall() async {
        let host = FakeHooksHost(listenerActive: true)
        let controller = AgentHooksController(
            install: { host.installed = true
                return true
            },
            uninstall: { host.installed = false
                return true
            },
            refreshStatus: { host.report },
        )
        await controller.install()
        XCTAssertEqual(controller.state, .installed)
        await controller.uninstall()
        XCTAssertEqual(controller.state, .notInstalled, "uninstall reverses install")
    }

    // MARK: the transient .working state is real (not an instantaneous skip)

    func testInstallTransitionsThroughWorking() async {
        var controller: AgentHooksController!
        var stateInsideSeam: AgentHooksController.InstallState?
        controller = AgentHooksController(
            install: {
                // The seam runs AFTER install() has set `.working` and BEFORE it lands the success state.
                stateInsideSeam = controller.state
                return true
            },
            refreshStatus: { Self.active },
        )
        await controller.install()
        XCTAssertEqual(stateInsideSeam, .working, "install() must enter .working before firing the seam")
        XCTAssertEqual(controller.state, .installed, "and land .installed after a successful seam + probe")
    }

    // MARK: failure paths re-probe (never stuck .working)

    func testFailedInstallReProbesToNotInstalled() async {
        let controller = AgentHooksController(install: { false }, refreshStatus: { Self.notInstalled })
        await controller.install()
        XCTAssertEqual(
            controller.state, .notInstalled,
            "a failed install must re-probe (here the host is still not-installed), not stay .working",
        )
    }

    func testFailedInstallReProbesToDisconnectedWhenStatusNil() async {
        let controller = AgentHooksController(install: { false }, refreshStatus: { nil })
        await controller.install()
        XCTAssertEqual(
            controller.state, .disconnected,
            "a failed install whose re-probe finds no pane lands .disconnected, never stuck .working",
        )
    }

    func testFailedUninstallReProbesToInstalled() async {
        let controller = AgentHooksController(uninstall: { false }, refreshStatus: { Self.active })
        await controller.uninstall()
        XCTAssertEqual(
            controller.state, .installed,
            "a failed uninstall must re-probe (the host is still installed), not stay .working",
        )
    }

    // MARK: refresh() must not clobber an in-flight write

    func testRefreshIsNoOpWhileWriteInFlight() async {
        var resume: CheckedContinuation<Bool, Never>?
        let controller = AgentHooksController(
            // The install seam suspends until the test resumes it, holding the controller in `.working`.
            install: { await withCheckedContinuation { resume = $0 } },
            // Would flip the state to `.notInstalled` if refresh() were NOT guarded against `.working`.
            refreshStatus: { Self.notInstalled },
        )

        let writing = Task { await controller.install() }
        // Let the install Task progress into the seam's suspension (state is `.working`).
        while resume == nil { await Task.yield() }
        XCTAssertEqual(controller.state, .working)

        await controller.refresh()
        XCTAssertEqual(controller.state, .working, "refresh() is a no-op while a write owns .working")

        resume?.resume(returning: true)
        await writing.value
        // The resumed write re-probes (this fake host still answers not-installed) — the point here is
        // only that the mid-flight refresh() could not clobber `.working`.
        XCTAssertEqual(controller.state, .notInstalled)
    }

    // MARK: derived view flags

    func testDerivedFlagsForWorking() async {
        var resume: CheckedContinuation<Bool, Never>?
        let controller = AgentHooksController(install: { await withCheckedContinuation { resume = $0 } })
        let writing = Task { await controller.install() }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(controller.isWorking)
        XCTAssertFalse(controller.actionsEnabled, "buttons disable while a write is in flight")
        resume?.resume(returning: true)
        await writing.value
    }

    func testUnknownIsTreatedAsDisconnectedForDisplay() {
        let controller = AgentHooksController()
        XCTAssertEqual(controller.state, .unknown, "the initial state before the first probe")
        XCTAssertTrue(controller.isDisconnected, "unknown renders like disconnected (the connect note shows)")
        XCTAssertFalse(controller.actionsEnabled)
    }
}

/// A tiny stateful fake host: `installed` flips with the install/uninstall seams; `listenerActive` is
/// fixed at construction (the listener binds only at hostd launch — no RPC can flip it).
@MainActor
private final class FakeHooksHost {
    var installed = false
    let listenerActive: Bool

    init(listenerActive: Bool) {
        self.listenerActive = listenerActive
    }

    var report: MetadataClient.AgentHookStatusReport {
        .init(installed: installed, listenerActive: installed ? listenerActive : false)
    }
}
