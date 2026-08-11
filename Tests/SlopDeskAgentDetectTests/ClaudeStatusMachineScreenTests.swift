import XCTest
@testable import SlopDeskAgentDetect

/// The `.screen` signal's reconciliation rules (DECISIONS round 4): screen verdicts are
/// continuous ground truth, gated against young hook blocks by the paint grace.
final class ClaudeStatusMachineScreenTests: XCTestCase {
    private let blocked = AgentScreenDetection(state: .blocked, visibleBlocker: true)
    private let working = AgentScreenDetection(state: .working, visibleWorking: true)
    private let visibleIdle = AgentScreenDetection(state: .idle, visibleIdle: true)
    private let plainIdle = AgentScreenDetection(state: .idle)
    private let freeze = AgentScreenDetection(state: .unknown, skipStateUpdate: true)

    func testScreenBlockedRaisesAManifestBlock() {
        var m = ClaudeStatusMachine()
        m.reduce(.processPresent(true), at: 0)
        XCTAssertEqual(m.reduce(.screen(blocked), at: 1), .needsPermission)
        // A later manifest-grade working clears it (manifest provenance, not hook).
        XCTAssertEqual(m.reduce(.screen(working), at: 2), .working)
    }

    func testScreenWorkingPromotesFromNothing() {
        var m = ClaudeStatusMachine()
        // The scan only runs with an identified agent — a working screen implies presence.
        XCTAssertEqual(m.reduce(.screen(working), at: 0), .working)
    }

    /// ⚠️ REVERSED 2026-08-11. A single visible idle past a 1 s paint grace USED to clear a hook
    /// block — that is what turned one torn mid-repaint read into a released block, a flapping mark
    /// and a false finished turn. Under hook coverage the screen no longer outranks the feed at all:
    /// it must contradict it, unbroken, for ``ClaudeStatusMachine/screenDissentToRelease``.
    func testAVisibleIdleNoLongerClearsAHookBlockOnOneRead() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: "allow?")), at: 10)
        XCTAssertEqual(m.reduce(.screen(visibleIdle), at: 10.5), .needsPermission)
        XCTAssertEqual(m.reduce(.screen(visibleIdle), at: 11.5), .needsPermission, "the old 1 s grace")
        // …and it stays blocked across a whole burst of them, which is what a repaint looks like.
        for step in 0..<20 {
            XCTAssertEqual(m.reduce(.screen(visibleIdle), at: 11.5 + 0.3 * Double(step)), .needsPermission)
        }
    }

    /// The watchdog: hooks are best-effort, so an UNINTERRUPTED contradiction eventually wins —
    /// otherwise a dead relay would pin a hand nothing could lower.
    func testSustainedScreenDissentEventuallyReleasesAHookBlock() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: "allow?")), at: 0)
        var now: TimeInterval = 1
        while now < ClaudeStatusMachine.screenDissentToRelease {
            XCTAssertEqual(m.reduce(.screen(visibleIdle), at: now), .needsPermission, "at \(now)")
            now += 0.3
        }
        XCTAssertEqual(
            m.reduce(.screen(visibleIdle), at: ClaudeStatusMachine.screenDissentToRelease + 1), .idle,
        )
        XCTAssertFalse(m.hasAuthoritativeFeed, "the feed stopped describing this pane — screen takes over")
        XCTAssertTrue(m.isQuiet, "a correction, never a finished turn")
    }

    /// One agreeing read in the middle is an INTERRUPTION — the argument restarts from zero. This is
    /// what makes a repaint (blocked, blocked, torn, blocked, …) unable to accumulate at all.
    func testAnyAgreementRestartsTheDissentClock() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: nil)), at: 0)
        for step in 0..<30 {
            let t = 1 + 0.3 * Double(step)
            // Every fourth read agrees with the hook; the rest contradict it.
            let verdict = (step + 1).isMultiple(of: 4) ? blocked : visibleIdle
            XCTAssertEqual(m.reduce(.screen(verdict), at: t), .needsPermission, "at \(t)")
        }
    }

    func testPlainIdleNeverClearsAHookBlock() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: nil)), at: 0)
        XCTAssertEqual(m.reduce(.screen(plainIdle), at: 100), .needsPermission)
    }

    /// A screen `working` is the same tier as a screen `idle` — it argues, it does not decide.
    func testScreenWorkingNoLongerClearsAHookBlockOnOneRead() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: nil)), at: 0)
        XCTAssertEqual(m.reduce(.screen(working), at: 0.2), .needsPermission)
        XCTAssertEqual(m.reduce(.screen(working), at: 2), .needsPermission)
        XCTAssertEqual(m.reduce(.screen(working), at: 5), .needsPermission)
    }

    /// The tier-1 resolutions all still land INSTANTLY — nothing correct waits on the watchdog.
    func testEveryAuthoritativeResolutionIsStillImmediate() {
        // The answered question.
        var answered = ClaudeStatusMachine()
        answered.reduce(.hook(.notification(kind: .waitingForInput, label: "?", toolUseID: "t1")), at: 0)
        XCTAssertEqual(
            answered.reduce(.hook(.postToolUse(sessionID: nil, tool: "AskUserQuestion", toolUseID: "t1")), at: 0.1),
            .working,
        )
        // The approved permission.
        var approved = ClaudeStatusMachine()
        approved.reduce(.hook(.notification(kind: .permission, label: nil, toolUseID: "t2")), at: 0)
        XCTAssertEqual(
            approved.reduce(.hook(.preToolUse(sessionID: nil, tool: "Bash", toolUseID: "t2")), at: 0.1),
            .working,
        )
        // The Esc-cancel — no hook exists for it, so the keystroke is the signal.
        var cancelled = ClaudeStatusMachine()
        cancelled.reduce(.hook(.notification(kind: .waitingForInput, label: "?", toolUseID: "t3")), at: 0)
        XCTAssertEqual(cancelled.reduce(.userInput, at: 0.1), .idle)
        XCTAssertTrue(cancelled.isQuiet, "the human dismissed it themselves — nothing to announce")
        // The finished turn.
        var stopped = ClaudeStatusMachine()
        stopped.reduce(.hook(.notification(kind: .permission, label: nil, toolUseID: "t4")), at: 0)
        XCTAssertEqual(stopped.reduce(.hook(.stop(sessionID: nil, label: "ok")), at: 0.1), .done)
    }

    /// A pane with NO hook feed (codex, gemini, hooks not installed) keeps herdr's world verbatim:
    /// the screen is the authority and decides on the spot.
    func testWithoutHookCoverageTheScreenStillDecidesImmediately() {
        var m = ClaudeStatusMachine()
        m.reduce(.processPresent(true), at: 0)
        XCTAssertFalse(m.hasAuthoritativeFeed)
        XCTAssertEqual(m.reduce(.screen(blocked), at: 1), .needsPermission)
        XCTAssertEqual(m.reduce(.screen(visibleIdle), at: 1.3), .idle, "one read, no waiting")
        XCTAssertFalse(m.isQuiet, "and it still counts as herdr's completion edge")
    }

    /// The RAISE direction gets its own, shorter window: a human waiting on a dialog nobody
    /// announced is the expensive failure.
    func testAnUnannouncedBlockIsRaisedOnTheShorterWindow() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.userPromptSubmit(sessionID: nil)), at: 0)
        XCTAssertEqual(m.reduce(.screen(blocked), at: 1), .working, "not on one read")
        XCTAssertEqual(
            m.reduce(.screen(blocked), at: 1 + ClaudeStatusMachine.screenDissentToRaise), .needsPermission,
        )
        XCTAssertLessThan(
            ClaudeStatusMachine.screenDissentToRaise, ClaudeStatusMachine.screenDissentToRelease,
            "asymmetric on purpose",
        )
    }

    func testScreenIdleLeavesTheDoneDecayIntact() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.stop(sessionID: nil, label: "done!")), at: 0)
        XCTAssertEqual(m.reduce(.screen(visibleIdle), at: 1), .done)
        // The decay still fires on its own clock.
        XCTAssertEqual(m.reduce(.tick, at: 9), .idle)
    }

    func testSkipStateUpdateFreezesEverything() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.userPromptSubmit(sessionID: nil)), at: 0)
        XCTAssertEqual(m.reduce(.screen(freeze), at: 1), .working)
        m.reduce(.hook(.notification(kind: .permission, label: nil)), at: 2)
        XCTAssertEqual(m.reduce(.screen(freeze), at: 3), .needsPermission)
    }

    func testUnknownStateChangesNothing() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.userPromptSubmit(sessionID: nil)), at: 0)
        XCTAssertEqual(m.reduce(.screen(AgentScreenDetection(state: .unknown)), at: 1), .working)
    }

    func testScreenBlockedKeepsHookProvenance() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: "allow?")), at: 0)
        // Screen agrees the pane is blocked — the HOOK provenance (and label) must survive,
        // so a legacy coarse manifest working still cannot clear it.
        m.reduce(.screen(blocked), at: 0.1)
        XCTAssertEqual(m.status, .needsPermission)
        XCTAssertEqual(m.displayLabel, "allow?")
        XCTAssertEqual(m.reduce(.manifestVerdict(.working), at: 0.2), .needsPermission)
    }
}
