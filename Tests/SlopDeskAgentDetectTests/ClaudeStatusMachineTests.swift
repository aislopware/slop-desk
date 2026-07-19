import XCTest
@testable import SlopDeskAgentDetect

/// Pure, deterministic state-machine tests. The clock is INJECTED (every `reduce`
/// call takes an absolute `now: TimeInterval`); no `Date()` is reachable from the
/// machine. Each test drives a real signal sequence and asserts the resulting
/// `ClaudeStatus` — never a recomputation of the machine's own derivation.
final class ClaudeStatusMachineTests: XCTestCase {
    // MARK: Core transitions

    func testFreshMachineIsNone() {
        let m = ClaudeStatusMachine()
        XCTAssertEqual(m.status, .none)
    }

    func testProcessPresentAloneGivesIdle() {
        var m = ClaudeStatusMachine()
        let s = m.reduce(.processPresent(true), at: 0)
        XCTAssertEqual(s, .idle, "claude foreground process present → idle")
    }

    func testSessionStartGivesIdle() {
        var m = ClaudeStatusMachine()
        XCTAssertEqual(m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0), .idle)
    }

    func testUserPromptSubmitGivesWorking() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        XCTAssertEqual(m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 1), .working)
    }

    func testPreToolUseGivesWorking() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.sessionStart(sessionID: "s1")), at: 0)
        XCTAssertEqual(m.reduce(.hook(.preToolUse(sessionID: "s1", tool: "Bash")), at: 1), .working)
    }

    func testNotificationPermissionGivesBlocked() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        let s = m.reduce(.hook(.notification(kind: .permission, label: "Allow Bash?")), at: 1)
        XCTAssertEqual(s, .needsPermission, "permission_prompt → needsPermission (blocked)")
        XCTAssertEqual(m.label, "Allow Bash?", "carries the prompt label")
    }

    func testNotificationWaitingGivesBlocked() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        // A generic "waiting for input" notification also blocks (needs a human).
        XCTAssertEqual(m.reduce(.hook(.notification(kind: .waitingForInput, label: nil)), at: 1), .needsPermission)
    }

    func testBlockedClearedByNextPromptOrTool() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        XCTAssertEqual(m.reduce(.hook(.notification(kind: .permission, label: "Allow?")), at: 1), .needsPermission)
        // User answered → next tool runs → back to working, and label is cleared.
        XCTAssertEqual(m.reduce(.hook(.preToolUse(sessionID: "s1", tool: "Bash")), at: 2), .working)
        XCTAssertNil(m.label)
    }

    func testStopGivesDone() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        XCTAssertEqual(m.reduce(.hook(.stop(sessionID: "s1")), at: 1), .done)
    }

    func testStopCarriesLabel() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        _ = m.reduce(.hook(.stop(sessionID: "s1", label: "Done — refactored 3 files")), at: 1)
        XCTAssertEqual(m.label, "Done — refactored 3 files")
    }

    // MARK: Injected-clock timeouts

    func testDoneDecaysToIdleAfterTimeout() {
        var m = ClaudeStatusMachine(doneToIdleTimeout: 5)
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        XCTAssertEqual(m.reduce(.hook(.stop(sessionID: "s1")), at: 10), .done)
        // A tick before the timeout keeps it done.
        XCTAssertEqual(m.reduce(.tick, at: 14), .done)
        // A tick at/after the timeout decays to idle.
        XCTAssertEqual(m.reduce(.tick, at: 15), .idle)
    }

    func testDoneTimeoutMeasuredFromStopNotFromStart() {
        // The done→idle clock is anchored at the Stop time, not session start.
        var m = ClaudeStatusMachine(doneToIdleTimeout: 5)
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 100)
        XCTAssertEqual(m.reduce(.hook(.stop(sessionID: "s1")), at: 100), .done)
        XCTAssertEqual(m.reduce(.tick, at: 104), .done, "4s after stop → still done")
        XCTAssertEqual(m.reduce(.tick, at: 105), .idle, "5s after stop → idle")
    }

    func testWorkingDoesNotDecayOnTick() {
        var m = ClaudeStatusMachine(doneToIdleTimeout: 5)
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        // Working is not time-decayed by the done timeout.
        XCTAssertEqual(m.reduce(.tick, at: 1000), .working)
    }

    func testBlockedNeverAutoDecays() {
        var m = ClaudeStatusMachine(doneToIdleTimeout: 5)
        _ = m.reduce(.hook(.notification(kind: .permission, label: "Allow?")), at: 0)
        // Blocked must persist until a human acts — a tick far in the future keeps it blocked.
        XCTAssertEqual(m.reduce(.tick, at: 100_000), .needsPermission)
    }

    // MARK: Termination

    func testSessionEndGivesNone() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        XCTAssertEqual(m.reduce(.hook(.sessionEnd(sessionID: "s1")), at: 1), .none)
    }

    func testProcessAbsentGivesNone() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.processPresent(true), at: 0)
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 1)
        XCTAssertEqual(m.reduce(.processPresent(false), at: 2), .none, "claude gone → none")
        XCTAssertNil(m.label, "label cleared on termination")
    }

    // MARK: Manifest verdict (no-hooks fallback feeds the machine too)

    func testManifestVerdictDrivesWorkingWhenNoHooks() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.processPresent(true), at: 0) // idle
        XCTAssertEqual(m.reduce(.manifestVerdict(.working), at: 1), .working)
    }

    func testManifestVerdictBlockedDrivesBlocked() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.processPresent(true), at: 0)
        XCTAssertEqual(m.reduce(.manifestVerdict(.needsPermission), at: 1), .needsPermission)
    }

    func testManifestNoneIsIgnoredWhileProcessPresent() {
        // A conservative `none`/unsure manifest verdict must not knock a present process
        // back to `none` — process presence is the floor.
        var m = ClaudeStatusMachine()
        _ = m.reduce(.processPresent(true), at: 0)
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 1) // working
        XCTAssertEqual(m.reduce(.manifestVerdict(.none), at: 2), .working, "unsure manifest doesn't downgrade")
    }

    func testManifestDoneDecaysToIdleAfterTimeout() {
        // A manifest-sourced `.done` anchors the SAME done→idle decay clock as a hook Stop —
        // a nil anchor would latch the pane `.done` forever (decayIfDue requires `doneSince`).
        var m = ClaudeStatusMachine(doneToIdleTimeout: 5)
        _ = m.reduce(.processPresent(true), at: 0)
        XCTAssertEqual(m.reduce(.manifestVerdict(.done), at: 10), .done)
        XCTAssertEqual(m.reduce(.tick, at: 14), .done, "4s after the verdict → still done")
        XCTAssertEqual(m.reduce(.tick, at: 15), .idle, "5s after the verdict → decays to idle")
    }

    // MARK: Hooks outweigh manifest (defense-in-depth precedence)

    func testHookBlockedSurvivesAManifestWorkingGuess() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.notification(kind: .permission, label: "Allow?")), at: 0) // blocked
        // A coarse manifest "working" guess must NOT clear an authoritative hook block.
        XCTAssertEqual(m.reduce(.manifestVerdict(.working), at: 1), .needsPermission)
    }

    // MARK: Block-source provenance (review #5 — a manifest block must be clearable by a manifest verdict)

    /// A MANIFEST-sourced `.needsPermission` (the no-hooks approval-UI cue) must be CLEARABLE by a
    /// later manifest `.working` verdict — the screen left the approval prompt and a spinner is now
    /// showing. The pre-fix code set the same `hookBlocked` flag for both sources, so a manifest block
    /// could never clear (stuck-blocked) — this is the revert-to-confirm-fail guard.
    func testManifestBlockIsClearedByALaterManifestWorking() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.processPresent(true), at: 0) // idle floor
        XCTAssertEqual(
            m.reduce(.manifestVerdict(.needsPermission), at: 1),
            .needsPermission,
            "manifest approval UI → blocked",
        )
        // The approval prompt is gone and the screen now shows a spinner → the manifest block clears.
        XCTAssertEqual(
            m.reduce(.manifestVerdict(.working), at: 2),
            .working,
            "a manifest-sourced block must be clearable by a later manifest verdict (not stuck-blocked)",
        )
    }

    /// The same clear path via a manifest `.idle` verdict (the screen returned to an empty compose box).
    /// `.idle` only lifts off `.none` in `applyManifest`, so first force the machine back to `.none`-able
    /// ground is not needed — instead assert via `.working` is covered above; here pin that a manifest
    /// block does NOT survive a manifest `.working` while a genuine HOOK block DOES (the asymmetry).
    func testHookBlockOutranksManifestButManifestBlockDoesNot() {
        // Hook block: a manifest .working can't clear it.
        var hookM = ClaudeStatusMachine()
        _ = hookM.reduce(.hook(.notification(kind: .permission, label: "Allow?")), at: 0)
        XCTAssertEqual(hookM.reduce(.manifestVerdict(.working), at: 1), .needsPermission, "hook block survives")
        // Manifest block: a manifest .working DOES clear it.
        var manifestM = ClaudeStatusMachine()
        _ = manifestM.reduce(.processPresent(true), at: 0)
        _ = manifestM.reduce(.manifestVerdict(.needsPermission), at: 1)
        XCTAssertEqual(manifestM.reduce(.manifestVerdict(.working), at: 2), .working, "manifest block clears")
    }

    // MARK: Idempotence / duplicates / out-of-order / unknown

    func testDuplicateSignalsAreIdempotent() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 0)
        XCTAssertEqual(m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 1), .working)
        XCTAssertEqual(m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 2), .working)
    }

    func testDuplicateProcessPresentIsStable() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.processPresent(true), at: 0)
        _ = m.reduce(.hook(.userPromptSubmit(sessionID: "s1")), at: 1) // working
        // A redundant processPresent(true) must NOT reset working back to idle.
        XCTAssertEqual(m.reduce(.processPresent(true), at: 2), .working)
    }

    func testStopBeforeAnyPromptStillDone() {
        // Out-of-order: a Stop arrives without a preceding prompt. Don't crash; treat as done.
        var m = ClaudeStatusMachine()
        XCTAssertEqual(m.reduce(.hook(.stop(sessionID: "s1")), at: 0), .done)
    }

    func testTickBeforeAnySignalStaysNone() {
        var m = ClaudeStatusMachine()
        XCTAssertEqual(m.reduce(.tick, at: 999), .none)
    }

    func testProcessAbsentWhenAlreadyNoneStaysNone() {
        var m = ClaudeStatusMachine()
        XCTAssertEqual(m.reduce(.processPresent(false), at: 0), .none)
    }

    func testEmptyAndWeirdLabelsDoNotCrash() {
        var m = ClaudeStatusMachine()
        _ = m.reduce(.hook(.notification(kind: .permission, label: "")), at: 0)
        _ = m.reduce(.hook(.notification(kind: .permission, label: String(repeating: "x", count: 100_000))), at: 1)
        XCTAssertEqual(m.status, .needsPermission)
    }

    func testOscTitleClaudeGivesPresenceFloor() {
        // An OSC title "Claude: foo" is weak corroboration → at least idle.
        var m = ClaudeStatusMachine()
        XCTAssertEqual(m.reduce(.oscTitle("Claude: my-project"), at: 0), .idle)
    }

    func testOscTitleNonClaudeDoesNotPromote() {
        var m = ClaudeStatusMachine()
        XCTAssertEqual(m.reduce(.oscTitle("zsh — ~/code"), at: 0), .none)
    }
}
