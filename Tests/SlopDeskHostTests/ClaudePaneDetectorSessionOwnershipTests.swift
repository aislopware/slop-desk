import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// SESSION OWNERSHIP (2026-08-11). The hook relay routes by `SLOPDESK_PANE_ID`, an ENVIRONMENT
/// VARIABLE — so every descendant of the pane's shell inherits it. A `claude -p …` run from a
/// script, a Makefile, or the pane agent's own Bash tool is a SEPARATE claude with its OWN session
/// id, posting the full hook set to the pane that spawned it.
final class ClaudePaneDetectorSessionOwnershipTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func ask(session: String, id: String) -> Data {
        json(
            #"{"hook_event_name":"PreToolUse","session_id":"\#(session)","tool_name":"AskUserQuestion","#
                + #""tool_use_id":"\#(id)","tool_input":{"questions":[{"question":"Which?"}]}}"#,
        )
    }

    private func event(_ name: String, session: String) -> Data {
        json(#"{"hook_event_name":"\#(name)","session_id":"\#(session)"}"#)
    }

    /// A nested run must not answer a question asked by the pane's own agent, end its turn, or
    /// retire its session.
    func testANestedClaudeCannotDriveThePanesAgent() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: ask(session: "outer", id: "ask-1"), at: 1)
        XCTAssertEqual(d.status, .needsPermission)

        // `claude -p` starts under the pane agent's Bash tool.
        _ = d.hook(bytes: event("SessionStart", session: "inner"), at: 2)
        XCTAssertEqual(d.status, .needsPermission, "a different session's start is not our start")

        _ = d.hook(bytes: event("UserPromptSubmit", session: "inner"), at: 2.1)
        XCTAssertEqual(d.status, .needsPermission)

        // …it finishes. This must not mint a finished turn for the pane.
        let stopped = d.hook(bytes: event("Stop", session: "inner"), at: 3)
        XCTAssertEqual(d.status, .needsPermission, "someone else's turn ending is not ours")
        XCTAssertNil(stopped.status, "not even a frame")

        // …and exits. This must not blank the pane or arm the post-exit lockout.
        _ = d.hook(bytes: event("SessionEnd", session: "inner"), at: 3.2)
        XCTAssertEqual(d.status, .needsPermission, "a nested exit is not the pane's agent exiting")
        XCTAssertTrue(d.hasAuthoritativeFeed)

        // The human finally answers the OUTER question, and that still resolves instantly.
        _ = d.hook(
            bytes: json(
                #"{"hook_event_name":"PostToolUse","session_id":"outer","#
                    + #""tool_name":"AskUserQuestion","tool_use_id":"ask-1"}"#,
            ),
            at: 4,
        )
        XCTAssertEqual(d.status, .working)
    }

    /// The owner's OWN exit still ends the pane — ownership must not become a way to get stuck.
    func testTheOwningSessionStillEndsThePane() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: event("SessionStart", session: "outer"), at: 1)
        _ = d.hook(bytes: event("UserPromptSubmit", session: "outer"), at: 1.1)
        XCTAssertEqual(d.status, .working)
        _ = d.hook(bytes: event("SessionEnd", session: "outer"), at: 2)
        XCTAssertEqual(d.status, .none)
    }

    /// …and once it has, the NEXT session claims the pane — `claude` run again in the same pane is
    /// the ordinary case and must work with zero delay.
    func testTheNextSessionClaimsAFreePane() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: event("SessionStart", session: "first"), at: 1)
        _ = d.hook(bytes: event("SessionEnd", session: "first"), at: 2)
        XCTAssertEqual(d.status, .none)

        _ = d.hook(bytes: event("SessionStart", session: "second"), at: 30)
        _ = d.hook(bytes: event("UserPromptSubmit", session: "second"), at: 30.1)
        XCTAssertEqual(d.status, .working, "a free pane is claimed by whoever speaks next")
    }

    /// The same gate protects the SESSION TITLE (wire type 36). A nested run's prompt is not the
    /// human's prompt, and renaming the pane's session to it is a visible, sticky wrong answer.
    func testANestedPromptDoesNotRetitleTheSession() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        let mine = d.hook(
            bytes: json(
                #"{"hook_event_name":"UserPromptSubmit","session_id":"outer","#
                    + #""prompt":"fix the detector flap"}"#,
            ),
            at: 1,
        )
        XCTAssertNotNil(mine.intent, "my own prompt titles my session")

        let theirs = d.hook(
            bytes: json(
                #"{"hook_event_name":"UserPromptSubmit","session_id":"inner","#
                    + #""prompt":"summarise this file in one line"}"#,
            ),
            at: 2,
        )
        XCTAssertNil(theirs.intent, "a nested run's prompt is not this session's intent")
    }

    /// Ownership must not become a way to get STUCK. An agent that dies without a `SessionEnd`
    /// (crash, `kill -9`) and is replaced inside one presence poll leaves a stale owner holding the
    /// pane — the dissent watchdog is what frees it, and then the replacement claims it.
    func testACrashedOwnerIsFreedByTheWatchdogSoAReplacementCanClaim() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: event("UserPromptSubmit", session: "dead"), at: 1)
        XCTAssertEqual(d.status, .working)

        // The replacement is up and idle at its prompt, but its session is foreign → ignored.
        _ = d.hook(bytes: event("SessionStart", session: "fresh"), at: 2)
        XCTAssertEqual(d.status, .working, "still pinned by the corpse")

        // The screen says otherwise, steadily, and eventually wins.
        let idleRead = AgentScreenDetection(state: .idle, visibleIdle: true)
        var now: TimeInterval = 2.3
        while d.status == .working, now < 2 + ClaudeStatusMachine.screenDissentToRelease + 3 {
            _ = d.screenDetection(idleRead, at: now)
            now += 0.3
        }
        XCTAssertEqual(d.status, .idle, "the watchdog broke the deadlock")

        // …and the pane is free, so the live agent's very next hook drives it again.
        _ = d.hook(bytes: event("UserPromptSubmit", session: "fresh"), at: now)
        XCTAssertEqual(d.status, .working)
        XCTAssertTrue(d.hasAuthoritativeFeed)
    }

    /// …and when the corpse died BETWEEN turns, the replacement does not have to wait for the
    /// watchdog at all: a `SessionStart` naming a new session on a pane whose turn is over is a
    /// restart, and takes the pane immediately.
    ///
    /// Safe for the same structural reason `/clear` is: a nested `claude -p` is spawned BY a tool
    /// call, so the parent is `working` or blocked at that instant — never at rest. The gate is the
    /// pane's own state, not a timer, so no window has to be guessed.
    func testARestartAfterACrashClaimsARestedPaneAtOnce() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: event("SessionStart", session: "dead"), at: 1)
        _ = d.hook(bytes: event("UserPromptSubmit", session: "dead"), at: 1.1)
        _ = d.hook(bytes: event("Stop", session: "dead"), at: 2)
        XCTAssertEqual(d.status, .done, "the turn is over; then the process is killed")

        // The human runs `claude` again, well inside the presence-absence grace window — so no
        // `processPresent(false)` ever lands to free the pane.
        _ = d.hook(bytes: event("SessionStart", session: "fresh"), at: 3)
        _ = d.hook(bytes: event("UserPromptSubmit", session: "fresh"), at: 4)
        XCTAssertEqual(d.status, .working, "the replacement drives the pane from its first turn")

        // …and the corpse cannot take it back.
        _ = d.hook(bytes: event("SessionEnd", session: "dead"), at: 5)
        XCTAssertEqual(d.status, .working, "a late goodbye from the dead session is not ours")
    }

    /// `/clear` and `/resume` are the everyday way a pane changes session, and they must be
    /// instant — no watchdog, no window.
    ///
    /// They are safe for exactly one reason, verified against the shipped CLI (2.1.227):
    /// `clearConversation` **awaits** the `SessionEnd` hook (`reason: "clear"`) before it does
    /// anything else, and `/resume` does the same with `reason: "resume"`. The old session hands
    /// the pane back before the new one speaks. That is the whole difference between a replacement
    /// and a nested `claude -p`, which never says goodbye because it never had the pane.
    func testClearHandsThePaneOverImmediately() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.hook(bytes: event("UserPromptSubmit", session: "before"), at: 1)
        XCTAssertEqual(d.status, .working)

        _ = d.hook(
            bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"before","reason":"clear"}"#),
            at: 2,
        )
        _ = d.hook(bytes: event("SessionStart", session: "after"), at: 2.01)
        _ = d.hook(bytes: event("UserPromptSubmit", session: "after"), at: 2.02)
        XCTAssertEqual(d.status, .working, "the new conversation drives the pane at once")
    }

    /// A pane whose agent never names a session (ctl `report`, or a hook payload without the field)
    /// keeps working exactly as before — ownership is opt-in evidence, not a requirement.
    func testUnattributedFeedsAreUnaffected() {
        var d = ClaudePaneDetector()
        _ = d.sample(name: "codex", at: 0)
        _ = d.report(state: "blocked", message: "approve?", at: 1)
        XCTAssertEqual(d.status, .needsPermission)
        _ = d.report(state: "working", message: nil, at: 2)
        XCTAssertEqual(d.status, .working)
        _ = d.report(state: "done", message: "built", at: 3)
        XCTAssertEqual(d.status, .done)
    }
}
