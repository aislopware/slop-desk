import XCTest
@testable import SlopDeskAgentDetect

/// The POST-EXIT FLOOR LOCKOUT — the machine's answer to the resurrection race.
///
/// `SessionEnd` fires while the `claude` process is still alive (measured: 0.3–1.5 s of overlap
/// before the PTY foreground drops back to the shell). Every weak liveness signal keeps seeing a
/// live agent across that gap — the ~1 Hz foreground poll, the 300 ms screen scan, the OSC title —
/// and each of them used to lift the presence floor straight back off `.none`, so the pane's
/// muted ring came back within milliseconds of the session ending.
///
/// The lockout is the machine-level veto: while it is armed, NOTHING weak may lift `.none`. Only an
/// authoritative hook (a genuinely new session) clears it. This is herdr's process-exit primacy and
/// t3code's `context.stopped` idempotence expressed in the one place both belong — the reducer.
final class ClaudeStatusMachineExitLockoutTests: XCTestCase {
    // MARK: The race the lockout exists to lose

    /// The measured shape: SessionEnd at t=0, the foreground poll still reporting `claude` at
    /// t=0.05 (the process has not reaped yet). Without the lockout that sample resurrects `.idle`.
    func testForegroundPresenceCannotResurrectRightAfterSessionEnd() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        XCTAssertEqual(m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 10), .none)
        XCTAssertEqual(
            m.reduce(.processPresent(true), at: 10.05), .none,
            "a still-alive claude process must NOT lift the floor inside the lockout",
        )
    }

    /// The 300 ms screen scan is the other resurrection path — a manifest verdict off the resident
    /// grid still shows claude's prompt box for a beat after the session ended.
    func testScreenVerdictCannotResurrectRightAfterSessionEnd() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        _ = m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 10)
        let idleScreen = AgentScreenDetection(state: .idle, visibleIdle: true)
        XCTAssertEqual(m.reduce(.screen(idleScreen), at: 10.3), .none)
        let workingScreen = AgentScreenDetection(state: .working)
        XCTAssertEqual(m.reduce(.screen(workingScreen), at: 10.6), .none)
    }

    /// The coarse ctl/manifest fallback shares the veto — every non-`.none` verdict it can publish
    /// used to lift the floor.
    func testManifestVerdictCannotResurrectRightAfterSessionEnd() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        _ = m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 10)
        XCTAssertEqual(m.reduce(.manifestVerdict(.working), at: 10.1), .none)
        XCTAssertEqual(m.reduce(.manifestVerdict(.needsPermission), at: 10.2), .none)
        XCTAssertEqual(m.reduce(.manifestVerdict(.done), at: 10.3), .none)
    }

    /// claude's own OSC title is still on screen after `/exit` until the shell repaints — the
    /// `titleNamesClaude` floor lift must be vetoed too.
    func testClaudeNamingTitleCannotResurrectRightAfterSessionEnd() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        _ = m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 10)
        XCTAssertEqual(m.reduce(.oscTitle("Claude: slop-desk"), at: 10.1), .none)
    }

    /// An informational Notification (`auth_success`, `idle_prompt`) lifts the floor on the normal
    /// path; inside the lockout it must not.
    func testInformationalNotificationCannotResurrectRightAfterSessionEnd() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        _ = m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 10)
        XCTAssertEqual(m.reduce(.hook(.notification(kind: .other, label: nil)), at: 10.1), .none)
    }

    // MARK: What the lockout must NOT break

    /// The lockout is a short veto, not a mute: once it lapses a genuinely restarted agent lights
    /// up off plain presence again (the hook-free pane's only signal).
    func testPresenceLiftsAgainOnceTheLockoutLapses() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        _ = m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 10)
        let after = 10 + ClaudeStatusMachine.postExitFloorLockout
        XCTAssertEqual(m.reduce(.processPresent(true), at: after), .idle)
    }

    /// A real new session announces itself with an authoritative hook — that clears the veto
    /// immediately, so `claude` relaunched inside the lockout is never held dark.
    func testSessionStartClearsTheLockoutImmediately() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        _ = m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 10)
        XCTAssertEqual(m.reduce(.hook(.sessionStart(sessionID: "s2")), at: 10.2), .idle)
        XCTAssertEqual(
            m.reduce(.processPresent(true), at: 10.3), .idle,
            "the veto is gone with the new session — weak signals corroborate it again",
        )
    }

    /// A turn beginning is just as authoritative as a session opening (a resumed session submits a
    /// prompt without necessarily re-announcing SessionStart).
    func testUserPromptSubmitClearsTheLockoutImmediately() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        _ = m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 10)
        XCTAssertEqual(m.reduce(.hook(.userPromptSubmit(sessionID: "s2")), at: 10.1), .working)
    }

    /// Presence ABSENCE is ground truth, not a guess: it needs no protection and must never arm a
    /// veto of its own — a pane whose agent simply exited stays instantly re-detectable.
    func testAbsenceTerminationArmsNoLockout() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.processPresent(true), at: 0)
        XCTAssertEqual(m.reduce(.processPresent(false), at: 1), .none)
        XCTAssertEqual(
            m.reduce(.processPresent(true), at: 1.1), .idle,
            "only a HOOK sessionEnd arms the lockout — the process-absence path is already truth",
        )
    }
}
