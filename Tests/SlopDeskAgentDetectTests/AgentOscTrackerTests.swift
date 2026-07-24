import XCTest
@testable import SlopDeskAgentDetect

final class AgentOscTrackerTests: XCTestCase {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    func testTitleAndProgressAreRetained() {
        var tracker = AgentOscTracker()
        tracker.observe(bytes("\u{1B}]0;⠂ project\u{07}"))
        XCTAssertEqual(tracker.latestTitle, "⠂ project")
        tracker.observe(bytes("\u{1B}]9;4;3;\u{07}"))
        XCTAssertEqual(tracker.latestProgress, "4;3;")
        // OSC 2 updates the same slot; ST termination works too.
        tracker.observe(bytes("\u{1B}]2;✳ Claude Code\u{1B}\\"))
        XCTAssertEqual(tracker.latestTitle, "✳ Claude Code")
    }

    func testEmptyTitleClears() {
        var tracker = AgentOscTracker()
        tracker.observe(bytes("\u{1B}]0;something\u{07}"))
        tracker.observe(bytes("\u{1B}]0;\u{07}"))
        XCTAssertEqual(tracker.latestTitle, "")
    }

    func testChunkSplitSequenceReassembles() {
        var tracker = AgentOscTracker()
        tracker.observe(bytes("\u{1B}]0;spl"))
        tracker.observe(bytes("it title\u{07}"))
        XCTAssertEqual(tracker.latestTitle, "split title")
    }

    func testOtherOscCommandsAndDCSAreIgnored() {
        var tracker = AgentOscTracker()
        tracker.observe(bytes("\u{1B}]7;file:///tmp\u{07}"))
        tracker.observe(bytes("\u{1B}P+q544e\u{1B}\\"))
        tracker.observe(bytes("\u{1B}]133;A\u{07}"))
        XCTAssertEqual(tracker.latestTitle, "")
        XCTAssertEqual(tracker.latestProgress, "")
    }

    func testControlCharsStrippedAndCapped() {
        var tracker = AgentOscTracker()
        let long = String(repeating: "x", count: 400)
        tracker.observe(bytes("\u{1B}]0;a\u{01}b\(long)\u{07}"))
        XCTAssertTrue(tracker.latestTitle.hasPrefix("ab"))
        XCTAssertEqual(tracker.latestTitle.count, 256)
    }

    func testOversizedBodyIsDiscardedWholesale() {
        var tracker = AgentOscTracker()
        let huge = String(repeating: "y", count: 5000)
        tracker.observe(bytes("\u{1B}]0;\(huge)\u{07}"))
        XCTAssertEqual(tracker.latestTitle, "")
        // The stream recovers for the next sequence.
        tracker.observe(bytes("\u{1B}]0;fresh\u{07}"))
        XCTAssertEqual(tracker.latestTitle, "fresh")
    }

    func testClearRetainedKeepsInFlightParseState() {
        var tracker = AgentOscTracker()
        tracker.observe(bytes("\u{1B}]0;old\u{07}"))
        tracker.observe(bytes("\u{1B}]0;spanning"))
        tracker.clearRetained()
        XCTAssertEqual(tracker.latestTitle, "")
        tracker.observe(bytes(" change\u{07}"))
        XCTAssertEqual(tracker.latestTitle, "spanning change")
    }
}
