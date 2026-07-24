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

    func testVisibleIdleClearsAHookBlockOnlyAfterTheGrace() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: "allow?")), at: 10)
        // Inside the paint grace the young hook block wins (stale-snapshot race).
        XCTAssertEqual(m.reduce(.screen(visibleIdle), at: 10.5), .needsPermission)
        // Past the grace the screen is believed — the Esc-cancel liberation.
        XCTAssertEqual(m.reduce(.screen(visibleIdle), at: 11.5), .idle)
    }

    func testPlainIdleNeverClearsAHookBlock() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: nil)), at: 0)
        XCTAssertEqual(m.reduce(.screen(plainIdle), at: 100), .needsPermission)
    }

    func testScreenWorkingClearsAHookBlockAfterTheGrace() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: nil)), at: 0)
        XCTAssertEqual(m.reduce(.screen(working), at: 0.2), .needsPermission)
        XCTAssertEqual(m.reduce(.screen(working), at: 2), .working)
    }

    func testHookReassertionDoesNotResetTheGraceAnchor() {
        var m = ClaudeStatusMachine()
        m.reduce(.hook(.notification(kind: .permission, label: nil)), at: 0)
        // The hook repeats itself just before the screen contradicts — the ORIGINAL entry
        // time still governs, so the (old) dialog's disappearance is believed.
        m.reduce(.hook(.notification(kind: .permission, label: nil)), at: 1.4)
        XCTAssertEqual(m.reduce(.screen(visibleIdle), at: 1.5), .idle)
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
