import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The TWO-TIER contract at the fusion point (2026-08-11), driven with REAL Claude Code hook JSON
/// through the real ``ClaudePaneDetector``.
///
/// Once a pane is hook-covered the agent announces its own edges, so the screen engine may only
/// corroborate. The reported bug — Tab-switching an `AskUserQuestion` walking the mark
/// idle ↔ blocked — needed a torn screen read to be believed over a live hook block; here the
/// torn read is fed DIRECTLY, so these pins hold even if every guard upstream of the machine fails.
final class ClaudePaneDetectorHookAuthorityTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    /// The exact payload Claude Code posts when it asks the human something.
    private func askHook(id: String) -> Data {
        json(
            #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"\#(id)","#
                + #""tool_input":{"questions":[{"question":"Which approach?"}]}}"#,
        )
    }

    private func postHook(tool: String, id: String) -> Data {
        json(#"{"hook_event_name":"PostToolUse","tool_name":"\#(tool)","tool_use_id":"\#(id)"}"#)
    }

    /// What a mid-repaint grid reads as: an idle prompt box with the `❯` pointer, `visible_idle`.
    private let tornRead = AgentScreenDetection(state: .idle, visibleIdle: true)
    private let dialogRead = AgentScreenDetection(state: .blocked, visibleBlocker: true)

    // MARK: The reported bug, at the fusion point

    func testTornScreenReadsNeverWalkAHookBlockedPaneOutOfTheBlock() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)
        XCTAssertEqual(d.status, .needsPermission)
        XCTAssertTrue(d.hasAuthoritativeFeed)

        // 14 Tab presses' worth of scans, alternating torn and whole reads at the real cadence.
        var now: TimeInterval = 1.3
        var frames = 0
        for step in 0..<60 {
            let emission = d.screenDetection(step.isMultiple(of: 3) ? tornRead : dialogRead, at: now)
            if emission.status != nil { frames += 1 }
            XCTAssertEqual(d.status, .needsPermission, "at \(now)")
            now += 0.3
        }
        XCTAssertEqual(frames, 0, "and not one type-27 frame of churn on the wire")
    }

    /// The second-order damage: each lap satisfied the hook-less completion shape, so every Tab
    /// press minted a finished turn. Pinned at the transition level the host counts.
    func testNoLapMeansNoFalseCompletionEdge() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)

        var previous = d.status
        var completions = 0
        var now: TimeInterval = 1.3
        for step in 0..<60 {
            _ = d.screenDetection(step.isMultiple(of: 3) ? tornRead : dialogRead, at: now)
            if MuxChannelSession.isCompletionTransition(previous: previous, next: d.status),
               !d.isQuietTransition
            {
                completions += 1
            }
            previous = d.status
            now += 0.3
        }
        XCTAssertEqual(completions, 0)
    }

    // MARK: Nothing correct waits on the watchdog

    func testTheAnswerStillResolvesInstantly() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)
        _ = d.screenDetection(dialogRead, at: 1.3)
        XCTAssertEqual(d.status, .needsPermission)

        let resolved = d.hook(bytes: postHook(tool: "AskUserQuestion", id: "ask-1"), at: 2)
        XCTAssertEqual(d.status, .working, "the human answered — no window, no confirmation")
        XCTAssertNotNil(resolved.status, "and the client is told at once")
    }

    /// A sibling call in the same assistant turn finishing is not an answer.
    func testAParallelToolResultDoesNotHandTheDialogBack() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)
        let sibling = d.hook(bytes: postHook(tool: "Bash", id: "bash-7"), at: 1.5)
        XCTAssertEqual(d.status, .needsPermission)
        XCTAssertNil(sibling.status, "not even a frame — nothing changed")
    }

    func testEscCancelStillUnblocksInstantlyAndSilently() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)
        let cancelled = d.userInput(bytes: Data([0x1B]), at: 1.2)
        XCTAssertEqual(d.status, .idle)
        guard case let .claudeStatus(_, kind, _)? = cancelled.status else {
            XCTFail("expected a type-27, got \(String(describing: cancelled.status))")
            return
        }
        XCTAssertEqual(kind, AgentStatusKind.quiet.rawValue)
    }

    // MARK: The two ways a call ends that are not a result

    /// A tool that FAILS or is interrupted emits `PostToolUseFailure` INSTEAD of `PostToolUse`,
    /// with the same `tool_use_id` (verified against the shipped CLI 2.1.227). Nothing else can
    /// resolve that call: an `.ask` ledger entry is deliberately immune to a later `PreToolUse`,
    /// so before this was parsed a failed `AskUserQuestion` left a hand raised over a dialog that
    /// was no longer on screen, for the rest of the turn.
    func testAFailedCallStillResolvesItsOwnBlock() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)
        XCTAssertEqual(d.status, .needsPermission)

        // The agent works on: a sibling call starting does NOT hand the dialog back…
        _ = d.hook(bytes: json(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"b-1"}"#), at: 1.5)
        XCTAssertEqual(d.status, .needsPermission)

        // …only the question's own ending does, however it ends.
        _ = d.hook(
            bytes: json(
                #"{"hook_event_name":"PostToolUseFailure","tool_name":"AskUserQuestion","#
                    + #""tool_use_id":"ask-1","error":"tool execution failed"}"#,
            ),
            at: 2,
        )
        XCTAssertEqual(d.status, .working)
    }

    /// ⚠️ An INTERRUPT is not a failed call, it is a FINISHED TURN — and Claude Code emits no
    /// `Stop` for one (verified against the shipped CLI 2.1.227). Reading `is_interrupt` as "a tool
    /// ended, carry on working" pinned the pane `working` with the spinner up until the dissent
    /// watchdog corrected it, ten seconds later, into a "turn finished" announcement for a turn the
    /// human had cancelled. The pane goes idle at once, and QUIETLY: nobody needs telling about the
    /// Esc they just pressed.
    func testAnInterruptEndsTheTurnQuietlyRatherThanContinuingIt() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)
        XCTAssertEqual(d.status, .needsPermission)

        let interrupted = d.hook(
            bytes: json(
                #"{"hook_event_name":"PostToolUseFailure","tool_name":"AskUserQuestion","#
                    + #""tool_use_id":"ask-1","error":"interrupted","is_interrupt":true}"#,
            ),
            at: 2,
        )
        XCTAssertEqual(d.status, .idle)
        guard case let .claudeStatus(_, kind, _)? = interrupted.status else {
            XCTFail("expected a type-27, got \(String(describing: interrupted.status))")
            return
        }
        XCTAssertEqual(kind, AgentStatusKind.quiet.rawValue, "no banner for the user's own Esc")
    }

    /// "No" is an answer. `PermissionDenied` names the gated call, so the block resolves on the
    /// announcement rather than on the next `PreToolUse` standing in for one.
    func testADeniedPermissionResolvesOnItsOwnEvent() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(
            bytes: json(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"p-1"}"#),
            at: 1,
        )
        XCTAssertEqual(d.status, .needsPermission)

        let denied = d.hook(
            bytes: json(
                #"{"hook_event_name":"PermissionDenied","tool_name":"Bash","#
                    + #""tool_use_id":"p-1","reason":"user_rejected"}"#,
            ),
            at: 2,
        )
        XCTAssertEqual(d.status, .working)
        XCTAssertNotNil(denied.status, "and the client hears about it at once")
    }

    /// An MCP server asking the human is the same block a permission dialog is — and it has its own
    /// id namespace (`elicitation_id`), so it pairs in the ledger exactly like a tool call does.
    /// Previously reachable only by classifying a `Notification` message as `elicitation_dialog`.
    func testAnMCPElicitationBlocksAndItsResultResolvesIt() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(
            bytes: json(
                #"{"hook_event_name":"Elicitation","mcp_server_name":"maestro","#
                    + #""message":"Which simulator?","elicitation_id":"e-1"}"#,
            ),
            at: 1,
        )
        XCTAssertEqual(d.status, .needsPermission)

        // A sibling tool finishing is not an answer to it.
        _ = d.hook(bytes: postHook(tool: "Bash", id: "b-1"), at: 1.5)
        XCTAssertEqual(d.status, .needsPermission)

        _ = d.hook(
            bytes: json(#"{"hook_event_name":"ElicitationResult","elicitation_id":"e-1","action":"accept"}"#),
            at: 2,
        )
        XCTAssertEqual(d.status, .working)
    }

    /// …and an elicitation whose payload names no `elicitation_id` still pairs. An id-less ledger
    /// entry is swept by ANY unrelated call's `PostToolUse` (that is the rule for an entry naming
    /// nothing), which handed the pane back as working while the MCP prompt was still on screen.
    /// The server name is the fallback key: stable across the pair, and one server does not stack
    /// two elicitations on one human.
    func testAnIdlessElicitationIsStillPairedByItsServer() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(
            bytes: json(
                #"{"hook_event_name":"Elicitation","mcp_server_name":"maestro","#
                    + #""message":"Which simulator?"}"#,
            ),
            at: 1,
        )
        XCTAssertEqual(d.status, .needsPermission)

        // Unrelated tool traffic is not an answer to it.
        _ = d.hook(bytes: postHook(tool: "Bash", id: "b-1"), at: 1.5)
        XCTAssertEqual(d.status, .needsPermission, "somebody else's call is not this dialog's answer")

        _ = d.hook(
            bytes: json(#"{"hook_event_name":"ElicitationResult","mcp_server_name":"maestro","action":"accept"}"#),
            at: 2,
        )
        XCTAssertEqual(d.status, .working)
    }

    // MARK: The block CLASS, when blocks stack

    /// Blocks stack, so the `kind` byte on the wire has to name the block that is still standing.
    /// The class used to be carried forward from the last blocking event: with
    /// `[AskUserQuestion, Bash(gated)]` the approval dialog is raised second, and once it is
    /// approved its `PreToolUse` arrives with event byte 0 — leaving every client drawing
    /// "Permission needed" over an unanswered question for as long as it stood. The ledger knows
    /// which entries survive, so it outranks the standing byte.
    func testTheWireKindNamesTheBlockThatIsStillStanding() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        guard case let .claudeStatus(_, asked, _)? = d.hook(bytes: askHook(id: "ask-1"), at: 1).status else {
            XCTFail("the question should announce itself")
            return
        }
        XCTAssertEqual(asked, AgentStatusKind.waitingForInput.rawValue)

        let gated = d.hook(
            bytes: json(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_use_id":"b-1"}"#),
            at: 2,
        )
        guard case let .claudeStatus(_, permission, _)? = gated.status else {
            XCTFail("the permission dialog should announce itself")
            return
        }
        XCTAssertEqual(permission, AgentStatusKind.permission.rawValue)

        // The human approves the Bash. Its own `PreToolUse` resolves it — and the question is still
        // on screen, so the pane stays blocked, as a QUESTION.
        let approved = d.hook(
            bytes: json(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"b-1"}"#),
            at: 3,
        )
        XCTAssertEqual(d.status, .needsPermission)
        guard case let .claudeStatus(_, standing, _)? = approved.status else {
            XCTFail("the block changed class — that is a wire event")
            return
        }
        XCTAssertEqual(
            standing,
            AgentStatusKind.waitingForInput.rawValue,
            "not `permission`: that dialog is answered and gone",
        )
    }

    /// The pure helper, at its edges: not blocked is always 0, and the ledger outranks both the
    /// standing class and the incoming event's.
    func testBlockKindEdges() {
        XCTAssertEqual(ClaudePaneDetector.blockKind(standing: 1, ledger: 2, event: 1, blocked: false), 0)
        XCTAssertEqual(ClaudePaneDetector.blockKind(standing: 1, ledger: 2, event: 0, blocked: true), 2)
        // No ledger answer (a SCREEN-raised block carries no call identity) → the event, then the
        // class already standing.
        XCTAssertEqual(ClaudePaneDetector.blockKind(standing: 2, ledger: 0, event: 1, blocked: true), 1)
        XCTAssertEqual(ClaudePaneDetector.blockKind(standing: 2, ledger: 0, event: 0, blocked: true), 2)
        // Any byte tolerated — an unknown event class never overwrites a known standing one.
        XCTAssertEqual(ClaudePaneDetector.blockKind(standing: 2, ledger: 0, event: 99, blocked: true), 2)
    }

    // MARK: The escape hatch

    /// Hooks are best-effort. A relay that dies mid-block must not pin a hand nothing can lower —
    /// sustained, uninterrupted screen dissent takes authority back.
    func testAStalledHookFeedLosesAuthorityToASteadyScreen() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)

        var now: TimeInterval = 1.3
        while now < 1 + ClaudeStatusMachine.screenDissentToRelease {
            _ = d.screenDetection(tornRead, at: now)
            XCTAssertEqual(d.status, .needsPermission, "held at \(now)")
            now += 0.3
        }
        while d.status == .needsPermission, now < 1 + ClaudeStatusMachine.screenDissentToRelease + 2 {
            _ = d.screenDetection(tornRead, at: now)
            now += 0.3
        }
        XCTAssertEqual(d.status, .idle, "…but never forever")
        XCTAssertFalse(d.hasAuthoritativeFeed)
        XCTAssertTrue(d.isQuietTransition, "a correction is not a finished turn")
    }

    /// …and one live hook puts the pane straight back under coverage.
    func testAnyHookRestoresCoverage() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: askHook(id: "ask-1"), at: 1)
        var now: TimeInterval = 1.3
        while now < 1 + ClaudeStatusMachine.screenDissentToRelease + 1 {
            _ = d.screenDetection(tornRead, at: now)
            now += 0.3
        }
        XCTAssertFalse(d.hasAuthoritativeFeed)
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit","prompt":"go on"}"#), at: now)
        XCTAssertTrue(d.hasAuthoritativeFeed)
        XCTAssertEqual(d.status, .working)
    }

    // MARK: The same contract, with no hooks in sight

    /// ⚠️ The tier is keyed on the FEED, not on the agent's name. The ctl `report` verb is the other
    /// way an agent describes itself, and any agent can call it — so a codex / gemini / bespoke
    /// wrapper that reports `blocked` gets the identical treatment Claude gets from its hook socket:
    /// the screen may corroborate it but not overrule it, and the watchdog is still the escape
    /// hatch. No per-agent code anywhere in the machine.
    func testACtlReportEarnsTheSameAuthorityAHookDoes() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "codex", at: 0)
        _ = d.report(state: "blocked", message: "approve the patch?", at: 1)
        XCTAssertEqual(d.status, .needsPermission)
        XCTAssertTrue(d.hasAuthoritativeFeed, "reporting your own state IS describing yourself")

        // The same torn/whole alternation that used to flap a Claude pane.
        var now: TimeInterval = 1.3
        for step in 0..<40 {
            _ = d.screenDetection(step.isMultiple(of: 3) ? tornRead : dialogRead, at: now)
            XCTAssertEqual(d.status, .needsPermission, "at \(now)")
            now += 0.3
        }
        // …and the agent's own next report resolves it instantly.
        _ = d.report(state: "working", message: nil, at: now)
        XCTAssertEqual(d.status, .working)
    }

    /// A pane with no authoritative feed at all keeps herdr's behaviour verbatim — the screen decides.
    func testAHookFreePaneIsUnaffected() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.screenDetection(dialogRead, at: 4)
        XCTAssertEqual(d.status, .needsPermission)
        XCTAssertFalse(d.hasAuthoritativeFeed)
        _ = d.screenDetection(tornRead, at: 4.3)
        XCTAssertEqual(d.status, .idle, "one read decides when there is nothing better")
    }
}
