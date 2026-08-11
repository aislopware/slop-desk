import XCTest
@testable import SlopDeskAgentDetect

/// The synchronized-update (DEC private mode 2026) frame tracker: does the byte stream fed so far
/// end inside a repaint the program has not closed yet?
final class AgentSyncFrameTrackerTests: XCTestCase {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    func testOpensOnBeginAndClosesOnEnd() {
        var t = AgentSyncFrameTracker()
        XCTAssertFalse(t.isFrameOpen)
        t.observe(bytes("\u{1B}[?2026h"))
        XCTAssertTrue(t.isFrameOpen)
        t.observe(bytes("\u{1B}[2Ksome repaint\u{1B}[5A"))
        XCTAssertTrue(t.isFrameOpen, "interior bytes do not close the frame")
        t.observe(bytes("\u{1B}[?2026l"))
        XCTAssertFalse(t.isFrameOpen)
    }

    /// The whole point: the opener SPLIT across two PTY reads is exactly the case a whole-buffer
    /// scanner misses, and exactly the case that tears the grid.
    func testOpenerSplitAcrossChunksStillRegisters() {
        for cut in 1..<"\u{1B}[?2026h".utf8.count {
            var t = AgentSyncFrameTracker()
            let all = Array("\u{1B}[?2026h".utf8)
            t.observe(Data(all[..<cut]))
            t.observe(Data(all[cut...]))
            XCTAssertTrue(t.isFrameOpen, "cut at \(cut)")
        }
    }

    func testCloserSplitAcrossChunksStillRegisters() {
        for cut in 1..<"\u{1B}[?2026l".utf8.count {
            var t = AgentSyncFrameTracker()
            t.observe(bytes("\u{1B}[?2026h"))
            let all = Array("\u{1B}[?2026l".utf8)
            t.observe(Data(all[..<cut]))
            t.observe(Data(all[cut...]))
            XCTAssertFalse(t.isFrameOpen, "cut at \(cut)")
        }
    }

    /// An OSC title (or any string sequence) whose BODY spells `?2026h` must not open a frame —
    /// the same opaque-skip rule `SyncUpdateFrameCollapser` applies.
    func testSequenceInsideAStringBodyIsIgnored() {
        var t = AgentSyncFrameTracker()
        t.observe(bytes("\u{1B}]0;\u{1B}[?2026h weird title\u{07}"))
        XCTAssertFalse(t.isFrameOpen)
        // …and the tracker is still parsing correctly afterwards.
        t.observe(bytes("\u{1B}[?2026h"))
        XCTAssertTrue(t.isFrameOpen)
        t.observe(bytes("\u{1B}P q\u{1B}[?2026l\u{1B}\\"))
        XCTAssertTrue(t.isFrameOpen, "a DCS body's closer is not the frame's")
        t.observe(bytes("\u{1B}[?2026l"))
        XCTAssertFalse(t.isFrameOpen)
    }

    func testMultiParameterDECSETCountsAndOtherModesDoNot() {
        var t = AgentSyncFrameTracker()
        t.observe(bytes("\u{1B}[?1049;2026h"))
        XCTAssertTrue(t.isFrameOpen)
        t.observe(bytes("\u{1B}[?25l\u{1B}[?7l"))
        XCTAssertTrue(t.isFrameOpen, "unrelated modes leave the frame alone")
        t.observe(bytes("\u{1B}[?2026;25l"))
        XCTAssertFalse(t.isFrameOpen)
    }

    /// `CSI ? 2026 $ p` is DECRQM — a QUERY. Its intermediate byte must keep it from reading as a set.
    func testDECRQMQueryIsNotAModeSet() {
        var t = AgentSyncFrameTracker()
        t.observe(bytes("\u{1B}[?2026$p"))
        XCTAssertFalse(t.isFrameOpen)
        t.observe(bytes("\u{1B}[?2026h"))
        t.observe(bytes("\u{1B}[?2026$p"))
        XCTAssertTrue(t.isFrameOpen, "a query never closes an open frame either")
    }

    func testResetClosesAnOpenFrame() {
        var t = AgentSyncFrameTracker()
        t.observe(bytes("\u{1B}[?2026h\u{1B}c"))
        XCTAssertFalse(t.isFrameOpen, "RIS ends the repaint")
    }

    func testExplicitResetDropsFrameAndParseState() {
        var t = AgentSyncFrameTracker()
        t.observe(bytes("\u{1B}[?2026h\u{1B}[?20"))
        XCTAssertTrue(t.isFrameOpen)
        t.reset()
        XCTAssertFalse(t.isFrameOpen)
        // The half-parsed `\u{1B}[?20` is gone: `26h` alone is plain text, not a mode set.
        t.observe(bytes("26h"))
        XCTAssertFalse(t.isFrameOpen)
    }

    /// Validate-then-drop: a hostile parameter run is bounded and never opens a frame.
    func testOversizedParameterRunIsDroppedNotHonoured() {
        var t = AgentSyncFrameTracker()
        let stuffing = String(repeating: "1;", count: AgentSyncFrameTracker.maxParamBytes)
        t.observe(bytes("\u{1B}[?\(stuffing)2026h"))
        XCTAssertFalse(t.isFrameOpen)
        // The parser recovers on the next well-formed sequence.
        t.observe(bytes("\u{1B}[?2026h"))
        XCTAssertTrue(t.isFrameOpen)
    }

    /// ESC is an ANYWHERE-transition: it aborts whatever sequence is in flight and begins the next
    /// one. Dropping to ground instead would swallow the ESC, so the `[` after it reads as text and
    /// the `CSI ? 2026 h` that follows an aborted sequence never registers — a repaint the scanner
    /// would then read mid-tear.
    func testEscapeInsideACSIAbortsAndStartsTheNextSequence() {
        var t = AgentSyncFrameTracker()
        t.observe(bytes("\u{1B}[1;2\u{1B}[?2026h"))
        XCTAssertTrue(t.isFrameOpen, "the aborted CSI must not eat the opener that follows it")

        // The aborted sequence's own parameters are discarded, not carried into the next.
        var u = AgentSyncFrameTracker()
        u.observe(bytes("\u{1B}[?2026\u{1B}[h"))
        XCTAssertFalse(u.isFrameOpen, "`CSI h` alone sets no private mode")
    }

    /// The generation counts FRAMES, so a caller timing out an over-long frame can tell "still the
    /// same one" from "a new one every scan" (``PaneScreenScanner``'s hold cap).
    func testFrameGenerationCountsOpeningsOnly() {
        var t = AgentSyncFrameTracker()
        XCTAssertEqual(t.frameGeneration, 0)
        t.observe(bytes("\u{1B}[?2026h"))
        XCTAssertEqual(t.frameGeneration, 1)
        // 2026 is a flag: re-opening an already-open frame is not a new frame.
        t.observe(bytes("\u{1B}[?2026h"))
        XCTAssertEqual(t.frameGeneration, 1)
        t.observe(bytes("\u{1B}[?2026l"))
        XCTAssertEqual(t.frameGeneration, 1, "closing counts nothing")
        t.observe(bytes("\u{1B}[?2026h"))
        XCTAssertEqual(t.frameGeneration, 2)
        t.reset()
        XCTAssertEqual(t.frameGeneration, 0)
    }

    func testArbitraryBytesNeverTrap() {
        var t = AgentSyncFrameTracker()
        var blob = Data()
        for i in 0..<4096 { blob.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7)) }
        t.observe(blob)
        t.observe(Data())
        _ = t.isFrameOpen // no expectation — the point is that nothing traps
    }
}
