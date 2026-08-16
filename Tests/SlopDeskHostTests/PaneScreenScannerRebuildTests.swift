import SlopDeskScreen
import XCTest
@testable import SlopDeskAgentDetect
@testable import SlopDeskHost

/// The ring REBUILD is a reconstruction, not an observation — the scanner must not publish a
/// verdict off it until the program has repainted at the new size.
///
/// A rebuild happens because the pane RESIZED, and an inline TUI dismisses its dialogs with
/// RELATIVE motion measured at the OLD width. Re-feeding those bytes at the NEW width lands the
/// erase in the wrong row and leaves the head of a long-answered permission dialog in the visible
/// grid — which the engine reads, correctly, as `blocked`. That is how switching tabs raised a
/// "Claude is waiting for your input" banner on a pane sitting quietly at its prompt.
final class PaneScreenScannerRebuildTests: XCTestCase {
    /// The pane's grid lives in `slopdesk-screend`; skip by name when it is not built.
    override func setUpWithError() throws {
        try ScreendFixture.requireDaemon()
    }

    /// A ring whose LIVE screen is the idle prompt box: a permission dialog, then the app's own
    /// dismissal — `CSI 9A` + `CSI J` — for the nine rows the dialog occupied AT 80 COLUMNS.
    private static func ring() -> Data {
        var s = ""
        s += "\u{1B}]0;\u{2733} slop-desk\u{07}" // ✳ rest title
        s += "run the build\r\n"
        s += String(repeating: "\u{2500}", count: 60) + "\r\n"
        s += "Bash command\r\n"
        s += "swift build " + String(repeating: "x", count: 55) + "\r\n"
        s += "Do you want to proceed?\r\n"
        s += "\u{276F} 1. Yes, and don't ask again for this command in this project\r\n"
        s += "  2. No, and tell Claude what to do differently (esc)\r\n"
        s += "  3. No, and give feedback about why this is the wrong call\r\n"
        s += "  4. No, and stop the whole run right here without asking me\r\n"
        s += "Enter to select \u{B7} \u{2191}/\u{2193} to navigate \u{B7} Esc to cancel\r\n"
        s += "\u{1B}[9A\u{1B}[J" // the dialog is dismissed — nine rows, at eighty columns
        s += "\u{256D}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256E}\r\n"
        s += "\u{2502} > ready \u{2502}\r\n"
        s += "\u{2570}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{256F}\r\n"
        return Data(s.utf8)
    }

    /// What the ring reconstructs to at `cols`, straight from the engine — a private pane key, so
    /// this reads the same grid the scanner would build without sharing one with it.
    private static func detection(cols: Int) throws -> AgentScreenDetection {
        try AgentScreenDetection(ScreenClient.shared.detect(
            pane: "rebuild-probe-\(cols)-\(UUID().uuidString)",
            agent: AgentKind.claude.label,
            raw: ring(),
            rows: 40,
            cols: cols,
            reset: true,
        ))
    }

    private func input(
        pending: Data = Data(),
        replay: Data? = nil,
        cols: Int = 80,
        seq: UInt64,
        now: TimeInterval,
    ) -> PaneScreenScanner.Input {
        PaneScreenScanner.Input(
            pending: pending,
            rebuildReplay: replay,
            rows: 40,
            cols: cols,
            agent: .claude,
            contentSeq: seq,
            now: now,
        )
    }

    /// The premise: the SAME ring reconstructs to two different screens, and the narrower one is a
    /// permission dialog the user answered long ago. Pins WHY the gate below has to exist.
    func testTheSameRingReconstructsToABlockedScreenAtANarrowerWidth() throws {
        XCTAssertEqual(try Self.detection(cols: 80).state, .idle)
        let narrow = try Self.detection(cols: 40)
        XCTAssertEqual(narrow.state, .blocked)
        XCTAssertEqual(narrow.matchedRuleID, "legacy_no_prompt_blocker")
    }

    /// The gate: a rebuild at the new width publishes NOTHING, however loudly the reconstruction
    /// reads — the resized program has not repainted yet, so there is nothing to report.
    func testARebuiltGridPublishesNothingUntilTheProgramRepaints() {
        var scanner = PaneScreenScanner()
        // Warm the pane at 80 columns and let it settle on the idle prompt.
        var out = scanner.scan(input(pending: Self.ring(), seq: 1, now: 0))
        XCTAssertNil(out.publish) // startup grace
        out = scanner.scan(input(seq: 2, now: 4))
        XCTAssertEqual(out.publish?.state, .idle)

        // The pane resizes: the grid is rebuilt from the ring at 40 columns. The reconstruction
        // reads `blocked` — and must go nowhere.
        out = scanner.scan(input(replay: Self.ring(), cols: 40, seq: 3, now: 5))
        XCTAssertNil(out.publish, "a reconstruction is not an observation")
        // Still nothing while the program stays quiet, however many scans go by.
        out = scanner.scan(input(cols: 40, seq: 3, now: 5.4))
        XCTAssertNil(out.publish)
        out = scanner.scan(input(cols: 40, seq: 3, now: 5.8))
        XCTAssertNil(out.publish)
    }

    /// …and the gate LIFTS: the SIGWINCH repaint lands, and whatever the program then draws is
    /// published normally. The hold is not a mute.
    func testTheRepaintAfterARebuildIsPublishedNormally() {
        var scanner = PaneScreenScanner()
        var out = scanner.scan(input(pending: Self.ring(), seq: 1, now: 0))
        XCTAssertNil(out.publish)
        out = scanner.scan(input(seq: 2, now: 4))
        XCTAssertEqual(out.publish?.state, .idle)
        out = scanner.scan(input(replay: Self.ring(), cols: 40, seq: 3, now: 5))
        XCTAssertNil(out.publish)

        // The program repaints at the new size — a real blocked form this time.
        let repaint = Data(
            "\u{1B}[2J\u{1B}[H\u{1B}]0;\u{2800} working\u{07}"
                .utf8,
        )
        out = scanner.scan(input(pending: repaint, cols: 40, seq: 4, now: 5.3))
        XCTAssertEqual(out.publish?.state, .working)
        XCTAssertEqual(out.publish?.matchedRuleID, "osc_title_working")
    }
}
