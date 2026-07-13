import XCTest
@testable import SlopDeskHost

/// ``AltScreenSegmentStripper`` — a closed TUI screen contributes nothing to replayed history;
/// an open one IS the live TUI's repaint and must survive byte-exact.
final class AltScreenSegmentStripperTests: XCTestCase {
    private func strip(_ s: String) -> String {
        // Lossy decode is fine here: inputs are ASCII test fixtures, outputs are compared whole.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: AltScreenSegmentStripper.strip(Data(s.utf8)), as: UTF8.self)
    }

    /// The field shape: an exited vim session — enter, megabytes of drawing, leave — vanishes
    /// entirely; the surrounding transcript joins seamlessly.
    func testClosedSegmentDroppedWhole() {
        XCTAssertEqual(
            strip("$ vi .\r\n\u{1B}[?1049hTUI DRAWING\u{1B}[2J\u{1B}[H\u{1B}[?1049l$ done\r\n"),
            "$ vi .\r\n$ done\r\n",
        )
    }

    /// A segment still open at end-of-stream is the LIVE TUI's screen — kept verbatim,
    /// its opening DECSET included (the reattaching client must actually enter the alt screen).
    func testOpenSegmentKeptVerbatim() {
        let live = "$ vi .\r\n\u{1B}[?1049hLIVE TUI FRAME"
        XCTAssertEqual(strip(live), live)
    }

    /// Only the LAST (open) segment survives when earlier ones closed.
    func testEarlierClosedSegmentsDropEvenWithLiveTail() {
        XCTAssertEqual(
            strip("a\u{1B}[?1049hOLD\u{1B}[?1049lb\u{1B}[?1049hLIVE"),
            "ab\u{1B}[?1049hLIVE",
        )
    }

    /// `?47`/`?1047` open and close segments too, and an alt-enter INSIDE an open segment is
    /// interior (the segment closes on the next alt-leave, not one-per-enter).
    func testVariantModesAndNestedEnter() {
        XCTAssertEqual(strip("x\u{1B}[?47hDRAW\u{1B}[?1049hMORE\u{1B}[?1047ly"), "xy")
    }

    /// An alt-leave with no open segment is a defensive reset on the main screen — kept.
    func testLeaveWithoutEnterKept() {
        XCTAssertEqual(strip("a\u{1B}[?1049lb"), "a\u{1B}[?1049lb")
    }

    /// Mixed-param DECSET/DECRST keep their non-alt params outside the dropped segment
    /// (`?1049;12h` sets blink globally — that survives even though the screen switch is cut).
    func testMixedParamsSurviveOutsideSegment() {
        XCTAssertEqual(
            strip("a\u{1B}[?1049;12hDRAW\u{1B}[?1049;25lb"),
            "a\u{1B}[?12h\u{1B}[?25lb",
        )
    }

    /// An embedded `?1049l` inside a DCS body must not close the segment; string sequences
    /// outside a segment pass through whole. Truncated trailing sequences pass through.
    func testStringBodiesOpaqueAndTruncationPassesThrough() {
        XCTAssertEqual(
            strip("a\u{1B}[?1049hX\u{1B}Pq##\u{1B}[?1049l##\u{1B}\\Y\u{1B}[?1049lb"),
            "ab",
        )
        let osc = "a\u{1B}]0;title\u{07}b"
        XCTAssertEqual(strip(osc), osc)
        XCTAssertEqual(strip("tail\u{1B}[?10"), "tail\u{1B}[?10")
        XCTAssertEqual(strip("tail\u{1B}"), "tail\u{1B}")
    }

    /// Pipeline: an exited-TUI transcript replays as pure main-screen history; a live-TUI
    /// transcript keeps its (open) alt segment AND gets the net input modes re-asserted after it.
    func testPipelineDropsClosedTUIAndKeepsLiveOne() throws {
        let transform = try XCTUnwrap(
            ScrollbackReplayTransform.make(environment: [:], reassertInputModes: true),
        )
        let exited = transform(
            Data("$ vi\r\n\u{1B}[?1049h\u{1B}[?1002hDRAW\u{1B}[?1002l\u{1B}[?1049l$ ok\r\n".utf8),
        )
        XCTAssertEqual(exited, Data("$ vi\r\n$ ok\r\n".utf8))

        let live = transform(Data("$ vi\r\n\u{1B}[?1002h\u{1B}[?1049hFRAME".utf8))
        XCTAssertEqual(live, Data("$ vi\r\n\u{1B}[?1049hFRAME\u{1B}[?1002h".utf8))
    }
}
