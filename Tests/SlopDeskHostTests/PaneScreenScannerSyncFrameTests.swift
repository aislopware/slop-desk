import XCTest
@testable import SlopDeskAgentDetect
@testable import SlopDeskHost

/// The mid-repaint tear, end to end (user-reported 2026-08-11): Tab-switching between an
/// `AskUserQuestion`'s questions walked the pane's mark blocked → idle → blocked, once per press.
///
/// Claude Code repaints its dialog inside a synchronized update (`CSI ? 2026 h … l`) and ERASES
/// each line before rewriting it. A scan whose byte prefix lands between the erase and the rewrite
/// reads a dialog with no footer on it — and the highest rule still matching is then
/// `live_prompt_box`, because the dialog's own option list carries the `❯` pointer while the footer
/// needles that would veto it (`enter to select`, `esc to cancel`, …) sit BELOW the last horizontal
/// rule, outside `prompt_box_body`. So the torn read reports `idle` + `visible_idle` — the one
/// screen verdict strong enough to clear even an authoritative hook block.
///
/// These tests pin the shape of the false verdict AND the two guards that make it unreachable.
final class PaneScreenScannerSyncFrameTests: XCTestCase {
    /// The pane's grid lives in `slopdesk-screend`; skip by name when it is not built.
    override func setUpWithError() throws {
        try ScreendFixture.requireDaemon()
    }

    // MARK: The fixture — an `AskUserQuestion` screen, shaped like the captured one

    private static let rule = String(repeating: "─", count: 60)

    /// The dialog as it stands between repaints: two horizontal rules, the option list with the
    /// `❯` pointer above the second, the footer below it.
    private static func dialogScreen(footer: Bool) -> String {
        var lines = [
            "  Reading docs/46-gates-env-paths.md",
            rule,
            "←  ☐ Next step  ☐ Language  ✔ Submit  →",
            "What should I do next in this repo?",
            "❯ 1. Run make test-touched",
            "  2. Review the current diff",
            "  3. Type something.",
            rule,
            "  4. Chat about this",
            "",
        ]
        if footer { lines.append("Enter to select · Tab/Arrow keys to navigate · Esc to cancel") }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The genuine article the dialog used to be confused with: an empty prompt box at rest.
    private static func idlePromptScreen() -> String {
        [
            "  Done — 8256 tests, 0 failures.",
            rule,
            "❯ ",
            rule,
            "  ? for shortcuts",
            "",
        ].joined(separator: "\r\n") + "\r\n"
    }

    private func input(
        pending: Data = Data(),
        replay: Data? = nil,
        seq: UInt64,
        now: TimeInterval,
    ) -> PaneScreenScanner.Input {
        PaneScreenScanner.Input(
            pending: pending,
            rebuildReplay: replay,
            rows: 24,
            cols: 80,
            agent: .claude,
            contentSeq: seq,
            now: now,
        )
    }

    /// Repaints the whole dialog inside ONE synchronized frame, the way Ink does: home, erase
    /// down, rewrite. Returned as `(openerAndErase, rewriteAndCloser)` so a test can cut the
    /// stream exactly where a PTY read boundary would.
    private func repaintHalves(footer: Bool) -> (Data, Data) {
        let head = "\u{1B}[?2026h\u{1B}[H\u{1B}[J"
        let tail = Self.dialogScreen(footer: footer) + "\u{1B}[?2026l"
        return (Data(head.utf8), Data(tail.utf8))
    }

    // (The false verdict ITSELF — that a footerless dialog must not read as an idle prompt box —
    // is pinned where the rule ladder lives: `the_claude_dialog_never_reads_as_an_idle_prompt_box`
    // in rust/slopdesk-screend/tests/cross_region_gate.rs. What is left here is the SCANNER's two
    // guards, which are hostd's: they are about time, and the clock is on this side.)

    // MARK: Guard 1 — never read a grid the program has not finished painting

    func testScanMidSynchronizedRepaintPublishesNothing() {
        var scanner = PaneScreenScanner()
        // Paint the dialog and get past the startup grace, so `blocked` is the standing verdict.
        let (head, tail) = repaintHalves(footer: true)
        _ = scanner.scan(input(pending: head + tail, seq: 1, now: 0))
        var out = scanner.scan(input(seq: 2, now: 4))
        XCTAssertEqual(out.publish?.state, .blocked)

        // A Tab repaint arrives, CUT after the erase and before the footer is rewritten.
        let (head2, tail2) = repaintHalves(footer: true)
        out = scanner.scan(input(pending: head2, seq: 3, now: 4.4))
        XCTAssertNil(out.publish, "the grid is half a frame — the program said so with mode 2026")
        XCTAssertEqual(
            out.nextInterval,
            AgentDetectionHold.pendingIdleRecheck,
            "recheck fast: the frame closes in milliseconds",
        )

        // The rest of the frame lands; the closed frame is a consistent grid again.
        out = scanner.scan(input(pending: tail2, seq: 4, now: 4.5))
        XCTAssertNil(out.publish, "unchanged verdict — and crucially never an idle")
    }

    /// An open frame may defer detection, never freeze it: a program that dies mid-paint (or a
    /// stream that loses its closer) must not pin the pane's status forever.
    func testAnUnclosedFrameStopsSuppressingAtTheCap() {
        var scanner = PaneScreenScanner()
        let (head, tail) = repaintHalves(footer: true)
        _ = scanner.scan(input(pending: head + tail, seq: 1, now: 0))
        XCTAssertEqual(scanner.scan(input(seq: 2, now: 4)).publish?.state, .blocked)

        // Open a frame that never closes, and wipe the screen inside it.
        let stuck = Data(("\u{1B}[?2026h\u{1B}[H\u{1B}[J" + "$ \r\n").utf8)
        var out = scanner.scan(input(pending: stuck, seq: 3, now: 4.4))
        XCTAssertNil(out.publish)
        out = scanner.scan(input(seq: 4, now: 5.0))
        XCTAssertNil(out.publish, "still inside the cap")
        // Past the cap the grid is believed again — and then hands off to the blocked→idle
        // confirmation hold, which releases on its own reads.
        var now: TimeInterval = 5.5
        var published: AgentScreenDetection?
        for seq in UInt64(5)...12 where published == nil {
            out = scanner.scan(input(seq: seq, now: now))
            published = out.publish
            now += out.nextInterval
        }
        XCTAssertEqual(published?.state, .idle, "detection resumes; it is never frozen")
    }

    /// …but the cap is per FRAME. A busy TUI opens a new synchronized frame every few
    /// milliseconds, and each one is well-formed — anchoring the deadline on "a frame was open
    /// last scan too" would let one second of ordinary repainting retire the guard permanently,
    /// and every scan after that reads a torn grid. Held for two full seconds of repaints here.
    func testAContinuousRepaintStreamNeverRetiresTheHold() {
        var scanner = PaneScreenScanner()
        let (head, tail) = repaintHalves(footer: true)
        _ = scanner.scan(input(pending: head + tail, seq: 1, now: 0))
        XCTAssertEqual(scanner.scan(input(seq: 2, now: 4)).publish?.state, .blocked)

        // Every scan lands mid-frame, but on a DIFFERENT frame each time: the previous repaint
        // closed and the next one opened between reads, exactly as Tab-holding produces.
        var seq: UInt64 = 3
        var now: TimeInterval = 4.4
        for _ in 0..<20 {
            let (nextHead, nextTail) = repaintHalves(footer: true)
            let chunk = nextTail + nextHead // …closes the previous frame, opens the next
            let out = scanner.scan(input(pending: chunk, seq: seq, now: now))
            XCTAssertNil(out.publish, "a torn grid is never published, however long the burst runs")
            seq += 1
            now += 0.1
        }
        XCTAssertGreaterThan(now - 4.4, PaneScreenScanner.syncFrameHoldCap, "well past the cap")

        // Closing the last frame restores an intact dialog — still blocked, never an idle blip.
        let out = scanner.scan(input(pending: tail, seq: seq, now: now))
        XCTAssertNotEqual(out.publish?.state, .idle)
    }

    // MARK: Guard 2 — a blocked → idle needs confirming, whatever the source of the idle

    func testABlockedToIdleFlipNeedsConfirmationEvenWhenVisible() {
        var scanner = PaneScreenScanner()
        let (head, tail) = repaintHalves(footer: true)
        _ = scanner.scan(input(pending: head + tail, seq: 1, now: 0))
        XCTAssertEqual(scanner.scan(input(seq: 2, now: 4)).publish?.state, .blocked)

        // The dialog gives way to a real, empty prompt box, painted as ONE complete frame (so
        // guard 1 does not apply). The engine's verdict is a genuine visible idle — and even that
        // must not publish on first sight, because a block is expensive to leave by mistake.
        let paint = Data("\u{1B}[?2026h\u{1B}[H\u{1B}[J\(Self.idlePromptScreen())\u{1B}[?2026l".utf8)
        var out = scanner.scan(input(pending: paint, seq: 3, now: 4.4))
        XCTAssertNil(out.publish, "one read is not enough to leave a block")
        out = scanner.scan(input(seq: 4, now: 4.5))
        XCTAssertNil(out.publish)
        out = scanner.scan(input(seq: 5, now: 4.6))
        XCTAssertNil(out.publish)
        out = scanner.scan(input(seq: 6, now: 4.7))
        XCTAssertEqual(out.publish?.state, .idle, "the confirmations release it")
        XCTAssertTrue(out.publish?.visibleIdle == true)
        XCTAssertLessThan(4.7 - 4.4, AgentDetectionHold.pendingIdleCap, "released by count, not the cap")
    }

    // MARK: The whole point — the mark stops flapping

    func testTabRepaintsCutAtEveryByteNeverWalkThePaneOutOfTheBlock() {
        let (head, tail) = repaintHalves(footer: true)
        let frame = head + tail
        // Cut the repaint at EVERY byte offset — one of them is the boundary that used to tear.
        for cut in stride(from: 1, to: frame.count, by: 7) {
            var scanner = PaneScreenScanner()
            let detector = ClaudePaneDetector()
            _ = detector.sample(name: "claude", at: 0)
            _ = scanner.scan(input(pending: frame, seq: 1, now: 0))
            var out = scanner.scan(input(seq: 2, now: 4))
            if let publish = out.publish { _ = detector.screenDetection(publish, at: 4) }
            XCTAssertEqual(detector.status, .needsPermission, "cut \(cut): setup")

            var now: TimeInterval = 4.3
            var seq: UInt64 = 3
            for piece in [frame.prefix(cut), frame.suffix(from: frame.startIndex + cut)] {
                out = scanner.scan(input(pending: Data(piece), seq: seq, now: now))
                if let publish = out.publish { _ = detector.screenDetection(publish, at: now) }
                XCTAssertEqual(detector.status, .needsPermission, "cut \(cut): mid-repaint")
                now += out.nextInterval
                seq += 1
            }
            // …and it stays blocked once everything has settled.
            for _ in 0..<6 {
                out = scanner.scan(input(seq: seq, now: now))
                if let publish = out.publish { _ = detector.screenDetection(publish, at: now) }
                now += out.nextInterval
                seq += 1
            }
            XCTAssertEqual(detector.status, .needsPermission, "cut \(cut): settled")
        }
    }
}
