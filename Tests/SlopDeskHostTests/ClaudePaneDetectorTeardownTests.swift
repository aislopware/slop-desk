import SlopDeskAgentDetect
import SlopDeskProtocol
import XCTest
@testable import SlopDeskHost

/// The TEARDOWN contract of the one per-pane detector — what must happen the moment a Claude Code
/// session ends, measured against the wire capture that motivated it.
///
/// Two defects lived here. Both were provable on a real `/exit`:
///
/// 1. **The grace paradox.** Every parsed hook stamped `lastAuthoritativeAt`, including the
///    `SessionEnd` that says the session is over. That stamp arms a 30 s window in which a
///    foreground-presence ABSENCE is dropped — so the one signal announcing the end was also what
///    kept the dead state alive, and the pane's muted ring survived ~31 s past `/exit`.
///
/// 2. **The orphaned title.** Claude Code owns the pane title while it runs (`✳ <topic>`), and its
///    exit-time clear is an EMPTY OSC 0 — which the host sniffer drops on purpose (zsh/p10k emit
///    empty titles during prompt redraw). Nothing else ever re-titles a plain zsh prompt, so the
///    agent's title outlived the agent indefinitely. The fix is ownership, not guard-loosening:
///    the detector that watched the agent take the title retires it when the agent goes.
final class ClaudePaneDetectorTeardownTests: XCTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func stateByte(_ message: WireMessage?) -> UInt8? {
        guard case let .claudeStatus(state, _, _)? = message else { return nil }
        return state
    }

    private func titleText(_ message: WireMessage?) -> String? {
        guard case let .title(text)? = message else { return nil }
        return text
    }

    // MARK: - (1) SessionEnd must not arm the absence grace

    /// The captured sequence: SessionEnd at t=0 while `claude` is still the PTY foreground, the
    /// shell back at t≈1. That absence must terminate on the spot — it is the corroboration of the
    /// SessionEnd, not something to be defended against.
    func testAbsenceRightAfterSessionEndIsNotSuppressed() {
        let d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        _ = d.sample(name: "claude", at: 0.5)
        XCTAssertEqual(d.status, .idle)
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 10)
        XCTAssertEqual(d.status, .none, "SessionEnd terminates")
        // The shell reclaims the foreground a beat later — well inside the old 30 s grace.
        _ = d.sample(name: "zsh", at: 11)
        XCTAssertEqual(d.status, .none, "the absence must NOT be swallowed by a grace SessionEnd armed")
    }

    /// The full resurrection race, end to end through the detector: SessionEnd, then the ~1 Hz poll
    /// still naming `claude` (measured at +34 ms .. +440 ms), then the real absence. The pane must
    /// stay dark the whole way — no re-lift, and no 30 s tail.
    func testSessionEndSurvivesAStillAliveForegroundPoll() {
        let d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        _ = d.sample(name: "claude", at: 0.5)
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 10)
        let resurrection = d.sample(name: "claude", at: 10.04)
        XCTAssertNil(stateByte(resurrection.status), "no type-27 churn — the status never left .none")
        XCTAssertEqual(d.status, .none)
        _ = d.sample(name: "zsh", at: 11)
        XCTAssertEqual(d.status, .none)
    }

    /// The grace itself is untouched for what it was built for: a wrapper-launched agent whose
    /// basename never classifies as `claude` still survives the poll on a MID-session hook.
    func testMidSessionHookStillArmsTheAbsenceGrace() {
        let d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hi"}"#), at: 10)
        XCTAssertEqual(d.status, .working)
        _ = d.sample(name: "node", at: 11)
        XCTAssertEqual(d.status, .working, "a wrapper foreground must not wipe a live turn")
    }

    // MARK: - (2) The title is retired with the agent that owned it

    /// The captured shape: claude titles the pane `✳ Claude Code`, then `/exit`. The detector saw
    /// the agent take the title, so it owes the pane an explicit clear when the agent goes.
    func testAgentGoneRetiresTheTitleItOwned() {
        let d = ClaudePaneDetector()
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#), at: 0)
        _ = d.sample(name: "claude", at: 0.5)
        _ = d.title("✳ Claude Code", at: 1)
        let end = d.hook(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 10)
        XCTAssertEqual(titleText(end.title), "", "the agent-gone edge pushes an explicit title clear")
        XCTAssertTrue(
            end.messages.contains { if case .title = $0 { true } else { false } },
            "the clear rides the same emission the caller enqueues",
        )
    }

    /// The clear is a ONE-SHOT edge, not a state: the next fold must not keep re-clearing a title
    /// the shell may since have set.
    func testTitleClearIsEmittedOnce() {
        let d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.title("✳ Claude Code", at: 1)
        _ = d.hook(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 10)
        let next = d.sample(name: "zsh", at: 11)
        XCTAssertNil(next.title, "the retirement fired already")
        XCTAssertNil(d.tick(at: 12).title)
    }

    /// A pane whose title the agent never touched keeps it. A shell's own title (nvim, a long
    /// `make`) is not the detector's to throw away.
    func testAgentGoneLeavesAForeignTitleAlone() {
        let d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.title("nvim — README.md", at: 1)
        let end = d.hook(bytes: json(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#), at: 10)
        XCTAssertNil(end.title, "only a title the agent demonstrably owned is retired")
    }

    /// The same retirement on the hook-free path: presence absence is the only teardown signal a
    /// pane without installed hooks ever gets.
    func testPresenceAbsenceAlsoRetiresTheAgentTitle() {
        let d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        _ = d.title("⠂ Say hi in one word", at: 1)
        let gone = d.sample(name: "zsh", at: 2)
        XCTAssertEqual(titleText(gone.title), "")
    }

    /// A live agent re-titling itself never triggers a clear — only the gone edge does.
    func testTitleChangesWhileTheAgentLivesEmitNoClear() {
        let d = ClaudePaneDetector()
        _ = d.sample(name: "claude", at: 0)
        XCTAssertNil(d.title("✳ Claude Code", at: 1).title)
        XCTAssertNil(d.title("⠂ Say hi in one word", at: 2).title)
        XCTAssertNil(d.title("✳ Say hi in one word", at: 3).title)
    }
}
