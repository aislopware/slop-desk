import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``TabBadgeGating/resolve(...)`` — the gating RULE is `slopdesk-agent::badge`; what is tested here is
/// the crossing. Five adjacent booleans are five chances to transpose two toggles, so each gate is
/// switched off ALONE against the one signal it owns: if any pair were swapped, the badge that
/// disappeared would be the wrong one.
final class TabBadgeGatingTests: XCTestCase {
    private func badge(
        agent: ClaudeStatus = .none,
        completion: PaneCompletionBadge? = nil,
        isBusy: Bool = false,
        progress: PaneProgress? = nil,
        unseenAgentDone: Bool = false,
        agentGates: AgentBadgeGates = .allOn,
        commandGates: CommandBadgeGates = .allOn,
    ) -> TabBadgeKind? {
        TabBadgeGating.resolve(
            agent: agent, completion: completion, isBusy: isBusy, foregroundProcess: nil,
            completionFreshness: .settled, progress: progress, unseenAgentDone: unseenAgentDone,
            agentGates: agentGates, commandGates: commandGates,
        )
    }

    /// Each toggle, off by itself, silences its OWN signal and leaves the other four alone.
    func testEachGateReachesTheSignalItNames() {
        let cases: [(name: String, shown: TabBadgeKind, gates: AgentBadgeGates)] = [
            ("while processing", .running, AgentBadgeGates(badgeWhileProcessing: false)),
            ("when complete", .finished, AgentBadgeGates(badgeWhenComplete: false)),
            ("when awaiting input", .awaitingInput, AgentBadgeGates(badgeWhenAwaitingInput: false)),
        ]
        let signals: [TabBadgeKind: ClaudeStatus] = [
            .running: .working, .finished: .done, .awaitingInput: .needsPermission,
        ]
        for (name, shown, gates) in cases {
            let agent = signals[shown] ?? .none
            XCTAssertEqual(badge(agent: agent), shown, "\(name): shown with every gate on")
            XCTAssertNil(badge(agent: agent, agentGates: gates), "\(name): its own gate silences it")
            // The OTHER two agent signals are untouched by this gate.
            for (other, otherAgent) in signals where other != shown {
                XCTAssertEqual(
                    badge(agent: otherAgent, agentGates: gates), other,
                    "\(name) must not silence \(other)",
                )
            }
        }
    }

    /// The two COMMAND-exit toggles, likewise — and neither touches the agent's family.
    func testTheCommandExitGatesReachTheirOwnExits() {
        let finishesOff = CommandBadgeGates(whenCommandFinishes: false)
        let failsOff = CommandBadgeGates(whenCommandFails: false)
        XCTAssertEqual(badge(completion: .success), .finished)
        XCTAssertNil(badge(completion: .success, commandGates: finishesOff))
        XCTAssertEqual(badge(completion: .success, commandGates: failsOff), .finished)
        XCTAssertEqual(badge(completion: .failure), .error)
        XCTAssertNil(badge(completion: .failure, commandGates: failsOff))
        XCTAssertEqual(badge(completion: .failure, commandGates: finishesOff), .error)
    }

    /// The program's own signals cross UNGATED: no toggle can silence a busy shell, an OSC 9;4
    /// spinner, or a held-red 9;4;2 — which is the whole reason the five flags are separate.
    func testNoGateSilencesTheProgramItself() {
        let everythingOff = AgentBadgeGates(
            badgeWhileProcessing: false, badgeWhenComplete: false, badgeWhenAwaitingInput: false,
        )
        let commandsOff = CommandBadgeGates(
            whenCommandFinishes: false, whenCommandFails: false, whenCommandAwaitsInput: false,
        )
        XCTAssertEqual(
            badge(
                agent: .working,
                isBusy: true,
                progress: .indeterminate,
                agentGates: everythingOff,
                commandGates: commandsOff,
            ),
            .commandRunning,
        )
        XCTAssertEqual(
            badge(progress: .error(percent: 40), agentGates: everythingOff, commandGates: commandsOff),
            .error,
        )
        XCTAssertEqual(
            badge(isBusy: true, agentGates: everythingOff, commandGates: commandsOff), .commandBusy,
        )
    }

    /// The unread agent-finish latch rides the "when complete" flag, not a sixth one.
    func testTheUnreadLatchCrossesUnderTheCompleteGate() {
        XCTAssertEqual(badge(agent: .idle, isBusy: true, unseenAgentDone: true), .finished)
        XCTAssertEqual(
            badge(
                agent: .idle,
                isBusy: true,
                unseenAgentDone: true,
                agentGates: AgentBadgeGates(badgeWhenComplete: false),
            ),
            .commandBusy,
        )
    }
}
