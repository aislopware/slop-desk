import XCTest
@testable import SlopDeskWorkspaceCore

/// ``AgentHookEnforcer`` — the hooks are installed, not offered. Two injected async seams (the app
/// wires them to the active connection's first-pane ``MetadataClient``; here they are fakes) and one
/// pass per connection. Each behaviour has a test that fails on the wrong implementation:
/// - a probe that says installed+listener is ``AgentHookEnforcer/Outcome/active`` and installs NOTHING
///   (an enforcer that re-installed every connection would rewrite the host's `settings.json` on every
///   reconnect);
/// - installed with the listener DOWN is ``AgentHookEnforcer/Outcome/inactive`` — hooks written to
///   `settings.json` while the host's hook socket never bound are DEAD, and reporting that as success is
///   the same lie the old card's green check told;
/// - not-installed installs and then RE-PROBES (a successful settings write does not prove the listener);
/// - `nil` (no connected pane) attempts nothing and stays retryable, never a false "not installed";
/// - a pass already in flight swallows a re-entrant call rather than firing a second install.
@MainActor
final class AgentHookEnforcerTests: XCTestCase {
    private typealias Report = MetadataClient.AgentHookStatusReport

    private static let active = Report(installed: true, listenerActive: true)
    private static let inactive = Report(installed: true, listenerActive: false)
    private static let notInstalled = Report(installed: false, listenerActive: false)

    // MARK: An already-installed host is left alone

    func testAlreadyInstalledWithListenerIsActiveAndInstallsNothing() async {
        var installs = 0
        let enforcer = AgentHookEnforcer(
            install: { installs += 1
                return true
            },
            refreshStatus: { Self.active },
        )
        await enforcer.enforce()
        XCTAssertEqual(enforcer.outcome, .active)
        XCTAssertEqual(installs, 0, "an installed host must not be rewritten on every reconnect")
    }

    /// Installed on disk but the host hook listener is unbound ⇒ `.inactive`, never `.active`.
    func testInstalledWithoutListenerIsInactive() async {
        let enforcer = AgentHookEnforcer(refreshStatus: { Self.inactive })
        await enforcer.enforce()
        XCTAssertEqual(
            enforcer.outcome, .inactive,
            "hooks in settings.json + no bound listener = a DEAD integration — say so, don't call it active",
        )
    }

    // MARK: A host without them gets them

    func testNotInstalledInstallsAndReProbesToInstalled() async {
        let host = FakeHooksHost(listenerActive: true)
        let enforcer = AgentHookEnforcer(
            install: { host.installed = true
                return true
            },
            refreshStatus: { host.report },
        )
        await enforcer.enforce()
        XCTAssertEqual(enforcer.outcome, .installed)
        XCTAssertTrue(host.installed, "the hooks actually reached the host")
    }

    /// Installing on a hostd with NO bound listener lands `.inactive` — the write worked, the daemon
    /// needs restarting, and neither `.installed` nor `.failed` would say that.
    func testInstallOnAHostWithoutAListenerIsInactive() async {
        let host = FakeHooksHost(listenerActive: false)
        let enforcer = AgentHookEnforcer(
            install: { host.installed = true
                return true
            },
            refreshStatus: { host.report },
        )
        await enforcer.enforce()
        XCTAssertEqual(
            enforcer.outcome, .inactive,
            "a successful settings write does NOT prove the listener — the re-probe lands the honest state",
        )
    }

    // MARK: Nothing to talk to, and nothing to report

    func testNoConnectedPaneIsUnreachableAndAttemptsNothing() async {
        var installs = 0
        let enforcer = AgentHookEnforcer(
            install: { installs += 1
                return true
            },
            refreshStatus: { nil },
        )
        await enforcer.enforce()
        XCTAssertEqual(enforcer.outcome, .unreachable, "a nil status is 'ask again', never 'not installed'")
        XCTAssertEqual(installs, 0)
    }

    func testTheInitialOutcomeIsUnknown() {
        XCTAssertEqual(AgentHookEnforcer().outcome, .unknown, "before any pass has run")
    }

    // MARK: Failure paths

    func testARefusedInstallIsFailed() async {
        let enforcer = AgentHookEnforcer(install: { false }, refreshStatus: { Self.notInstalled })
        await enforcer.enforce()
        XCTAssertEqual(enforcer.outcome, .failed)
    }

    /// The install RPC reported success and the host still says not-installed — a lie somewhere, and
    /// `.failed` is the only honest reading of it.
    func testAnInstallThatDidNotTakeIsFailed() async {
        let enforcer = AgentHookEnforcer(install: { true }, refreshStatus: { Self.notInstalled })
        await enforcer.enforce()
        XCTAssertEqual(enforcer.outcome, .failed)
    }

    /// The pane went away between the install and the re-probe: retryable, not failed.
    func testAProbeThatLosesThePaneAfterInstallingIsUnreachable() async {
        var probes = 0
        let enforcer = AgentHookEnforcer(
            install: { true },
            refreshStatus: {
                probes += 1
                return probes == 1 ? Self.notInstalled : nil
            },
        )
        await enforcer.enforce()
        XCTAssertEqual(enforcer.outcome, .unreachable)
    }

    // MARK: One pass at a time

    /// Two connections landing back to back must not fire two installs — the second call returns while
    /// the first is still suspended in the seam.
    func testAReentrantPassIsSwallowed() async {
        var resume: CheckedContinuation<Bool, Never>?
        var installs = 0
        let enforcer = AgentHookEnforcer(
            install: { installs += 1
                return await withCheckedContinuation { resume = $0 }
            },
            refreshStatus: { Self.notInstalled },
        )

        let first = Task { await enforcer.enforce() }
        while resume == nil { await Task.yield() }
        await enforcer.enforce() // re-entrant: must return without touching the seams
        XCTAssertEqual(installs, 1, "a pass in flight swallows the second call")

        resume?.resume(returning: true)
        await first.value
        XCTAssertEqual(enforcer.outcome, .failed, "this fake host still answers not-installed")
    }
}

/// A tiny stateful fake host: `installed` flips when the install seam fires; `listenerActive` is fixed
/// at construction (the listener binds only at hostd launch — no RPC can flip it).
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
