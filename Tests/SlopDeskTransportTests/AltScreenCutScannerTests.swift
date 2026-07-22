import XCTest
@testable import SlopDeskTransport

/// ``AltScreenCutScanner`` — exact alt-screen state at a front-truncation cut, so ring/journal
/// eviction can re-open a segment the cut beheaded instead of letting its interior replay onto
/// the main screen.
final class AltScreenCutScannerTests: XCTestCase {
    private func reopen(dropped: String, kept: String = "") -> String? {
        AltScreenCutScanner.reopenSequence(
            afterDropped: Data(dropped.utf8), keptHead: Data(kept.utf8),
        ).map {
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: $0, as: UTF8.self)
        }
    }

    // MARK: Net state

    func testPlainTextIsOutsideAltScreen() {
        XCTAssertNil(reopen(dropped: "hello\nworld\n"))
    }

    func testEmptyDroppedIsOutsideAltScreen() {
        XCTAssertNil(reopen(dropped: ""))
    }

    func testOpenSegmentAtCutReopens1049() {
        XCTAssertEqual(reopen(dropped: "before\n\u{1B}[?1049halt churn"), "\u{1B}[?1049h")
    }

    func testClosedSegmentAtCutDoesNotReopen() {
        XCTAssertNil(reopen(dropped: "a\u{1B}[?1049hchurn\u{1B}[?1049lb"))
    }

    func testRedundantLeaveOnMainScreenStaysOutside() {
        // Claude's exit cleanup emits ?1049l while already on the main screen — the exact
        // pattern that makes a "drop prefix to first unpaired l" heuristic dangerous.
        XCTAssertNil(reopen(dropped: "text\u{1B}[?1049lmore\u{1B}[?1049lend"))
    }

    func testReopenAfterCloseThenReenter() {
        XCTAssertEqual(
            reopen(dropped: "\u{1B}[?1049ha\u{1B}[?1049lb\u{1B}[?1049hc"),
            "\u{1B}[?1049h",
        )
    }

    // MARK: Mode variants — reopen with the SAME mode that opened

    func testMode47Reopens47() {
        XCTAssertEqual(reopen(dropped: "x\u{1B}[?47hy"), "\u{1B}[?47h")
    }

    func testMode1047Reopens1047() {
        XCTAssertEqual(reopen(dropped: "x\u{1B}[?1047hy"), "\u{1B}[?1047h")
    }

    func testMixedParamEnterIsRecognized() {
        XCTAssertEqual(reopen(dropped: "x\u{1B}[?25;1049hy"), "\u{1B}[?1049h")
    }

    func testMixedParamLeaveIsRecognized() {
        XCTAssertNil(reopen(dropped: "\u{1B}[?1049ha\u{1B}[?1049;25lb"))
    }

    // MARK: String-sequence bodies are opaque

    func testDECSETInsideOSCBodyDoesNotOpen() {
        XCTAssertNil(reopen(dropped: "\u{1B}]0;title \u{1B}[?1049h fake\u{07}rest"))
    }

    func testDECSETInsideDCSBodyDoesNotOpen() {
        XCTAssertNil(reopen(dropped: "\u{1B}Pq\u{1B}[?1049h\u{1B}\\rest"))
    }

    func testCutInsideOSCBodyKeepsStateFromBeforeTheBody() {
        // The body never terminates within the dropped prefix — transitions cannot occur
        // inside it, so the state at the cut is the state at the body's start.
        XCTAssertEqual(reopen(dropped: "\u{1B}[?1049halt\u{1B}]0;unterminated title"), "\u{1B}[?1049h")
        XCTAssertNil(reopen(dropped: "main\u{1B}]0;unterminated \u{1B}[?1049h title"))
    }

    // MARK: Straddling sequences (cut lands mid-CSI)

    func testEnterStraddlingTheCutIsResolvedViaKeptHead() {
        XCTAssertEqual(reopen(dropped: "text\u{1B}[?10", kept: "49halt churn"), "\u{1B}[?1049h")
    }

    func testLeaveStraddlingTheCutIsResolvedViaKeptHead() {
        XCTAssertNil(reopen(dropped: "\u{1B}[?1049halt\u{1B}[?104", kept: "9lmain"))
    }

    func testSequenceStartingInKeptHeadIsNotApplied() {
        // Only sequences that START inside the dropped prefix count — the kept head belongs
        // to the surviving stream and will be interpreted by the client itself.
        XCTAssertNil(reopen(dropped: "plain text", kept: "\u{1B}[?1049halt"))
    }

    func testUnresolvableTrailingEscapeLeavesStateAsIs() {
        XCTAssertEqual(reopen(dropped: "\u{1B}[?1049halt\u{1B}", kept: ""), "\u{1B}[?1049h")
        XCTAssertNil(reopen(dropped: "main\u{1B}[?10", kept: ""))
    }
}
