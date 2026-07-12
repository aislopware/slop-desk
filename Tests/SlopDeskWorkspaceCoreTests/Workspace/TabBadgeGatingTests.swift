import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

/// Progress cluster: ``TabBadgeGating/resolve(...)`` — the SOURCE-AWARE tab-badge gating that masks the
/// resolver inputs by source so the agent (``AgentBadgeGates``) and command (``CommandBadgeGates``) toggles
/// gate their OWN badge families independently. The crux: turning OFF the agent "while processing" spinner must
/// NOT silence a program's busy / OSC 9;4 progress marker — which now surfaces as its own `.commandRunning`
/// (distinct from the agent `.running`), so masking by source keeps it visible.
final class TabBadgeGatingTests: XCTestCase {
    private let agentSpinnerOff = AgentBadgeGates(
        badgeWhileProcessing: false, badgeWhenComplete: true, badgeWhenAwaitingInput: true,
    )

    // MARK: - The separation (agent-while-processing conflates the OSC 9;4 spinner)

    /// agent "while processing" OFF drops the AGENT thinking spinner.
    func testAgentSpinnerGateDropsAgentWorkingSpinner() {
        let badge = TabBadgeGating.resolve(
            agent: .working, completion: nil, isBusy: false, foregroundProcess: nil,
            agentGates: agentSpinnerOff, commandGates: .allOn,
        )
        XCTAssertNil(badge, "the agent thinking spinner is gated off")
    }

    /// …but the SAME gate must NOT hide a PROGRAM's progress marker. Revert-to-confirm-fail: a post-fuse
    /// gate that drops the agent badge returns nil here — masking by source keeps the program's own
    /// `.commandRunning`. (A merely-busy shell with no OSC 9;4 report shows nothing at all, so the
    /// program marker under test is the explicit progress report.)
    func testAgentSpinnerGateKeepsProgramProgressSpinner() {
        let badge = TabBadgeGating.resolve(
            agent: .none, completion: nil, isBusy: true, foregroundProcess: nil,
            progress: .indeterminate, agentGates: agentSpinnerOff, commandGates: .allOn,
        )
        XCTAssertEqual(badge, .commandRunning, "a program progress marker is never silenced by the agent gate")
    }

    /// …nor a program's OSC 9;4 indeterminate progress (the exact spec'd no-opt-out badge).
    func testAgentSpinnerGateKeepsOSC94ProgressSpinner() {
        let badge = TabBadgeGating.resolve(
            agent: .none, completion: nil, isBusy: false, foregroundProcess: nil,
            progress: .indeterminate, agentGates: agentSpinnerOff, commandGates: .allOn,
        )
        XCTAssertEqual(
            badge, .commandRunning, "OSC 9;4 program progress survives the agent while-processing gate",
        )
    }

    /// An OSC 9;4;2 program progress ERROR has NO opt-out: it survives BOTH the agent gate AND the command
    /// "when fails" gate (which gates only a command-EXIT `.failure`, a separate signal).
    func testProgressErrorHasNoOptOut() {
        let allOff = AgentBadgeGates(
            badgeWhileProcessing: false, badgeWhenComplete: false, badgeWhenAwaitingInput: false,
        )
        let cmdOff = CommandBadgeGates(
            whenCommandFinishes: false, whenCommandFails: false, whenCommandAwaitsInput: false,
        )
        let badge = TabBadgeGating.resolve(
            agent: .none, completion: nil, isBusy: false, foregroundProcess: nil,
            progress: .error(percent: 40), agentGates: allOff, commandGates: cmdOff,
        )
        XCTAssertEqual(badge, .error, "an OSC 9;4;2 progress error is never an opt-out badge")
    }

    // MARK: - Command gates (the new TAB BADGE toggles)

    /// "When Command Fails" OFF drops a `.failure`-EXIT error badge (but leaves the progress-error path, tested
    /// above, untouched).
    func testCommandFailsGateDropsExitFailureBadge() {
        let cmdFailOff = CommandBadgeGates(
            whenCommandFinishes: true, whenCommandFails: false, whenCommandAwaitsInput: true,
        )
        let dropped = TabBadgeGating.resolve(
            agent: .none, completion: .failure, isBusy: false, foregroundProcess: nil,
            agentGates: .allOn, commandGates: cmdFailOff,
        )
        XCTAssertNil(dropped, "an exit-failure badge is gated off by When Command Fails")
        let shown = TabBadgeGating.resolve(
            agent: .none, completion: .failure, isBusy: false, foregroundProcess: nil,
            agentGates: .allOn, commandGates: .allOn,
        )
        XCTAssertEqual(shown, .error, "and shows when the gate is on")
    }

    /// "When Command Finishes" OFF drops a `.success`-EXIT completed badge.
    func testCommandFinishesGateDropsExitSuccessBadge() {
        let cmdFinishOff = CommandBadgeGates(
            whenCommandFinishes: false, whenCommandFails: true, whenCommandAwaitsInput: true,
        )
        let dropped = TabBadgeGating.resolve(
            agent: .none, completion: .success, isBusy: false, foregroundProcess: nil,
            completionFreshness: .settled, agentGates: .allOn, commandGates: cmdFinishOff,
        )
        XCTAssertNil(dropped, "a success-exit badge is gated off by When Command Finishes")
        let shown = TabBadgeGating.resolve(
            agent: .none, completion: .success, isBusy: false, foregroundProcess: nil,
            completionFreshness: .settled, agentGates: .allOn, commandGates: .allOn,
        )
        XCTAssertEqual(shown, .finished, "and shows the settled dot when the gate is on")
    }

    /// The agent + command "complete" gates are INDEPENDENT: with the AGENT "when complete" OFF an agent-done
    /// badge is dropped, but a COMMAND `.success` (its own gate ON) still surfaces — the conflation the resolver
    /// would otherwise fold into one `.finished`.
    func testAgentAndCommandCompleteGatesAreIndependent() {
        let agentCompleteOff = AgentBadgeGates(
            badgeWhileProcessing: false, badgeWhenComplete: false, badgeWhenAwaitingInput: true,
        )
        // Agent done alone, agent gate OFF → no badge.
        XCTAssertNil(
            TabBadgeGating.resolve(
                agent: .done, completion: nil, isBusy: false, foregroundProcess: nil,
                agentGates: agentCompleteOff, commandGates: .allOn,
            ),
            "an agent-done badge is gated off by the AGENT when-complete gate",
        )
        // A command success with its OWN gate ON still surfaces, independent of the agent gate.
        XCTAssertEqual(
            TabBadgeGating.resolve(
                agent: .done, completion: .success, isBusy: false, foregroundProcess: nil,
                completionFreshness: .settled, agentGates: agentCompleteOff, commandGates: .allOn,
            ),
            .finished,
            "a command-success badge surfaces independent of the agent when-complete gate",
        )
    }

    /// All gates ON is an identity pass-through for every signal source (no badge is wrongly dropped).
    func testAllGatesOnPassThrough() {
        XCTAssertEqual(
            TabBadgeGating.resolve(
                agent: .needsPermission, completion: nil, isBusy: false, foregroundProcess: nil,
                agentGates: .allOn, commandGates: .allOn,
            ),
            .awaitingInput,
        )
        XCTAssertEqual(
            TabBadgeGating.resolve(
                agent: .working, completion: nil, isBusy: false, foregroundProcess: nil,
                agentGates: .allOn, commandGates: .allOn,
            ),
            .running,
            "with the agent gate ON the agent spinner shows",
        )
    }
}
