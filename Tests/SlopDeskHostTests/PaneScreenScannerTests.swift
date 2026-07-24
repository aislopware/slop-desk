import XCTest
@testable import SlopDeskAgentDetect
@testable import SlopDeskHost

/// The scan pipeline over the resident grid: grid upkeep, agent gating, startup grace,
/// idle-scan skip, the working→idle hold, and publish dedupe — all with injected inputs.
final class PaneScreenScannerTests: XCTestCase {
    /// A claude working screen: the braille OSC title arrives via the tracker inside `pending`.
    private func workingBytes() -> Data {
        Data("\u{1B}]0;⠂ fixing the bug\u{07}some tool output\r\n".utf8)
    }

    private func input(
        pending: Data = Data(),
        replay: Data? = nil,
        agent: AgentKind? = .claude,
        seq: UInt64,
        now: TimeInterval,
    ) -> PaneScreenScanner.Input {
        PaneScreenScanner.Input(
            pending: pending,
            rebuildReplay: replay,
            rows: 24,
            cols: 80,
            agent: agent,
            contentSeq: seq,
            now: now,
        )
    }

    func testWorkingTitlePublishesWorkingAfterTheStartupGrace() {
        var scanner = PaneScreenScanner()
        // First scan: agent appears → startup grace suppresses.
        var out = scanner.scan(input(pending: workingBytes(), seq: 1, now: 0))
        XCTAssertNil(out.publish)
        // Past the 3 s grace the braille title resolves working and publishes.
        out = scanner.scan(input(seq: 2, now: 3.5))
        XCTAssertEqual(out.publish?.state, .working)
        XCTAssertEqual(out.publish?.matchedRuleID, "osc_title_working")
        // An unchanged verdict does not re-publish.
        out = scanner.scan(input(seq: 3, now: 4))
        XCTAssertNil(out.publish)
    }

    func testNoAgentPublishesNothingButKeepsTheGridWarm() {
        var scanner = PaneScreenScanner()
        // SCREEN bytes land before the agent is identified — the grid keeps them (only the
        // retained OSC evidence is cleared on an agent change, herdr's clear_retained).
        let blockedForm = Data(
            "──────────\r\n  1. Yes\r\n  2. No\r\n\r\nEnter to select · ↑/↓ to navigate · Esc to cancel\r\n"
                .utf8,
        )
        var out = scanner.scan(input(pending: blockedForm, agent: nil, seq: 1, now: 0))
        XCTAssertNil(out.publish)
        // The agent appears later: after ITS startup grace, the standing blocked form on the
        // ALREADY-WARM grid publishes.
        out = scanner.scan(input(agent: .claude, seq: 2, now: 10))
        XCTAssertNil(out.publish) // grace
        out = scanner.scan(input(seq: 3, now: 14))
        XCTAssertEqual(out.publish?.state, .blocked)
    }

    func testWorkingToPlainIdleHoldsThenPublishes() {
        var scanner = PaneScreenScanner()
        _ = scanner.scan(input(pending: workingBytes(), seq: 1, now: 0))
        var out = scanner.scan(input(seq: 2, now: 4))
        XCTAssertEqual(out.publish?.state, .working)
        // The title clears (plain program title) → the engine falls back to plain idle;
        // the hold suppresses the first rechecks and tightens the cadence to 100 ms.
        let clearTitle = Data("\u{1B}]0;zsh\u{07}".utf8)
        out = scanner.scan(input(pending: clearTitle, seq: 3, now: 5))
        XCTAssertNil(out.publish)
        XCTAssertEqual(out.nextInterval, AgentDetectionHold.pendingIdleRecheck)
        out = scanner.scan(input(seq: 4, now: 5.1))
        XCTAssertNil(out.publish)
        out = scanner.scan(input(seq: 5, now: 5.2))
        XCTAssertNil(out.publish)
        // Third recheck releases the hold and the idle publishes.
        out = scanner.scan(input(seq: 6, now: 5.3))
        XCTAssertEqual(out.publish?.state, .idle)
        XCTAssertEqual(out.nextInterval, AgentDetectionHold.scanInterval)
    }

    func testIdleScanSkipDoesNoWorkWithoutNewBytes() {
        var scanner = PaneScreenScanner()
        _ = scanner.scan(input(pending: Data("\u{1B}]0;✳ Claude Code\u{07}".utf8), seq: 1, now: 0))
        var out = scanner.scan(input(seq: 2, now: 4))
        XCTAssertEqual(out.publish?.state, .idle)
        // Quiescent idle + unchanged seq → skip (still no publish, steady cadence).
        out = scanner.scan(input(seq: 2, now: 5))
        XCTAssertNil(out.publish)
        XCTAssertEqual(out.nextInterval, AgentDetectionHold.scanInterval)
    }

    func testRebuildReplayRepaintsTheGrid() {
        var scanner = PaneScreenScanner()
        _ = scanner.scan(input(pending: workingBytes(), seq: 1, now: 0))
        // A rebuild replays ring bytes carrying a blocked form; the verdict follows the grid.
        let blockedScreen = Data(
            "──────────\r\n  1. Yes\r\n  2. No\r\n\r\nEnter to select · ↑/↓ to navigate · Esc to cancel\r\n\u{1B}]0;✳ x\u{07}"
                .utf8,
        )
        let out = scanner.scan(input(replay: blockedScreen, seq: 2, now: 4))
        XCTAssertEqual(out.publish?.state, .blocked)
        XCTAssertTrue(out.publish?.visibleBlocker ?? false)
    }

    func testAgentChangeClearsRetainedOscEvidence() {
        var scanner = PaneScreenScanner()
        _ = scanner.scan(input(pending: workingBytes(), seq: 1, now: 0))
        var out = scanner.scan(input(seq: 2, now: 4))
        XCTAssertEqual(out.publish?.state, .working)
        // The foreground flips to codex: the claude braille title must not leak into codex's
        // ladder, and codex re-enters ITS startup grace.
        out = scanner.scan(input(agent: .codex, seq: 3, now: 5))
        XCTAssertNil(out.publish)
        out = scanner.scan(input(agent: .codex, seq: 4, now: 9))
        // No retained title/progress, blank-ish grid → codex resolves via its own rules and
        // publishes a fresh non-working verdict (the fallback idle).
        XCTAssertEqual(out.publish?.state, .idle)
    }

    func testTranscriptViewerFreezePublishesNothing() {
        var scanner = PaneScreenScanner()
        _ = scanner.scan(input(pending: workingBytes(), seq: 1, now: 0))
        var out = scanner.scan(input(seq: 2, now: 4))
        XCTAssertEqual(out.publish?.state, .working)
        let viewer = Data("showing detailed transcript  ctrl+o to toggle\r\n".utf8)
        out = scanner.scan(input(pending: viewer, seq: 3, now: 5))
        XCTAssertNil(out.publish)
    }
}

/// The detection-text extraction (herdr's `detection_text` shape) + the detector fold.
final class ScreenDetectionFoldTests: XCTestCase {
    func testDetectionTextTrimsTrailingBlankRowsAndJoins() {
        var model = TerminalScreenModel(rows: 5, cols: 20)
        model.feed(Data("hello\r\n  indented\r\n".utf8))
        // Rows 3–5 are blank → dropped; leading whitespace preserved; one trailing newline.
        XCTAssertEqual(model.snapshot().detectionText, "hello\n  indented\n")
    }

    func testDetectionTextEmptyScreenIsEmptyString() {
        let model = TerminalScreenModel(rows: 4, cols: 10)
        XCTAssertEqual(model.snapshot().detectionText, "")
    }

    func testScreenDetectionFoldEmitsType27() {
        var detector = ClaudePaneDetector()
        _ = detector.sample(name: "claude", at: 0)
        let emission = detector.screenDetection(
            AgentScreenDetection(state: .blocked, visibleBlocker: true),
            at: 1,
        )
        XCTAssertEqual(detector.status, .needsPermission)
        XCTAssertNotNil(emission.status)
        // Screen idle after the paint grace clears the (manifest-sourced) block.
        let idle = detector.screenDetection(
            AgentScreenDetection(state: .idle, visibleIdle: true),
            at: 3,
        )
        XCTAssertEqual(detector.status, .idle)
        XCTAssertNotNil(idle.status)
    }

    func testScreenDetectionNeverOpensTheStreamOnAnUndetectedPane() {
        var detector = ClaudePaneDetector()
        // No presence, no prior emission: an unknown-state verdict must stay silent.
        let emission = detector.screenDetection(AgentScreenDetection(state: .unknown), at: 0)
        XCTAssertTrue(emission.isEmpty)
        XCTAssertEqual(detector.status, .none)
    }
}
