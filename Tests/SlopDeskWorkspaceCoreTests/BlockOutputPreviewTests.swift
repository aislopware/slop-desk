// BlockOutputPreviewTests — pins the ladder peek's excerpt rule (user-directed 2026-08-09): a clean
// command is read from its FIRST lines, a failed one from its LAST, and the card is always told how
// much it is not showing (and from which end), so a preview can never quietly stand in for the whole.
//
// The excerpt is built from the block's RAW captured bytes, so these also pin that the STYLE survives
// the trip (user-directed 2026-08-09 — the peek shows output the way the terminal drew it).

import XCTest
@testable import SlopDeskWorkspaceCore

final class BlockOutputPreviewTests: XCTestCase {
    private let log = (1...20).map { "line \($0)" }.joined(separator: "\n")

    /// The builder takes bytes off the wire; the tests speak in strings.
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    func testACleanCommandIsReadFromTheTop() {
        let preview = BlockOutputPreviewBuilder.make(rawOutput: bytes(log), failed: false, maxLines: 8)
        XCTAssertEqual(preview.plainLines.first, "line 1")
        XCTAssertEqual(preview.plainLines.last, "line 8")
        XCTAssertEqual(preview.hiddenCount, 12)
        XCTAssertFalse(preview.fromTail)
    }

    /// The regression this split exists for: the first lines of a failing build are the banner every
    /// build prints, and the message that matters is the last thing said.
    func testAFailedCommandIsReadFromTheBottom() {
        let preview = BlockOutputPreviewBuilder.make(rawOutput: bytes(log), failed: true, maxLines: 8)
        XCTAssertEqual(preview.plainLines.first, "line 13")
        XCTAssertEqual(preview.plainLines.last, "line 20")
        XCTAssertEqual(preview.hiddenCount, 12)
        XCTAssertTrue(preview.fromTail)
    }

    func testOutputThatFitsHidesNothingFromEitherEnd() {
        for failed in [false, true] {
            let preview = BlockOutputPreviewBuilder.make(
                rawOutput: bytes("one\ntwo\nthree"), failed: failed, maxLines: 8,
            )
            XCTAssertEqual(preview.plainLines, ["one", "two", "three"])
            XCTAssertEqual(preview.hiddenCount, 0)
        }
    }

    /// A block's captured bytes almost always begin and end with the newline that separated the
    /// command from its prompt — a preview opening on an empty row reads as a bug.
    func testBlankEdgesAreDroppedBeforeTheExcerptIsTaken() {
        let preview = BlockOutputPreviewBuilder.make(
            rawOutput: bytes("\n   \nreal output\n\n  \n"), failed: false, maxLines: 8,
        )
        XCTAssertEqual(preview.plainLines, ["real output"])
        XCTAssertEqual(preview.hiddenCount, 0)
        XCTAssertFalse(preview.isEmpty)
    }

    func testAllBlankOutputIsEmptyRatherThanARowOfNothing() {
        let preview = BlockOutputPreviewBuilder.make(rawOutput: bytes("\n\n   \n"), failed: false)
        XCTAssertTrue(preview.isEmpty)
        XCTAssertEqual(preview.hiddenCount, 0)
    }

    func testEmptyOutputIsEmpty() {
        XCTAssertTrue(BlockOutputPreviewBuilder.make(rawOutput: Data(), failed: false).isEmpty)
    }

    /// A build log can emit one 4 000-column line; the card is a fixed width, so the cut happens here
    /// and is VISIBLE as a cut rather than being clipped away by the layout.
    func testAnOverLongLineIsCutWithAnEllipsis() {
        let long = String(repeating: "x", count: 500)
        let preview = BlockOutputPreviewBuilder.make(
            rawOutput: bytes(long), failed: false, maxColumns: 20,
        )
        XCTAssertEqual(preview.plainLines, [String(repeating: "x", count: 20) + "…"])
    }

    func testALineExactlyAtTheColumnCapIsNotMarkedAsCut() {
        let exact = String(repeating: "x", count: 20)
        let preview = BlockOutputPreviewBuilder.make(
            rawOutput: bytes(exact), failed: false, maxColumns: 20,
        )
        XCTAssertEqual(preview.plainLines, [exact])
    }

    /// The count is CHARACTERS, not UTF-8 bytes — a monospaced card advances by grapheme clusters.
    func testTheColumnCapCountsCharactersNotBytes() {
        let preview = BlockOutputPreviewBuilder.make(
            rawOutput: bytes(String(repeating: "é", count: 30)), failed: false, maxColumns: 10,
        )
        XCTAssertEqual(preview.plainLines, [String(repeating: "é", count: 10) + "…"])
    }

    /// A tab inside a fixed-width card advances by a value the card cannot honour — expand it before
    /// the cut so the column count means what it says.
    func testTabsAreExpandedBeforeTheCut() {
        let preview = BlockOutputPreviewBuilder.make(rawOutput: bytes("\tok"), failed: false)
        XCTAssertEqual(preview.plainLines, ["    ok"])
    }

    func testDegenerateLineBudgetShowsNothing() {
        let preview = BlockOutputPreviewBuilder.make(rawOutput: bytes(log), failed: false, maxLines: 0)
        XCTAssertTrue(preview.isEmpty)
    }

    /// End-to-end on real VT bytes: the escapes are gone from the TEXT and present in the STYLE.
    func testTheExcerptCarriesTheColoursTheTerminalDrew() {
        let raw = bytes("\u{1B}[32mPASS\u{1B}[0m first\nsecond\n\u{1B}[31mFAIL\u{1B}[0m third\n")
        let preview = BlockOutputPreviewBuilder.make(rawOutput: raw, failed: true, maxLines: 2)
        XCTAssertEqual(preview.plainLines, ["second", "FAIL third"])
        XCTAssertEqual(preview.hiddenCount, 1)
        // The failure line splits at the reset: red "FAIL", then unstyled " third".
        let last = preview.lines[1]
        XCTAssertEqual(last.map(\.text), ["FAIL", " third"])
        XCTAssertEqual(last[0].style.foreground, .indexed(1))
        XCTAssertTrue(last[1].style.isPlain)
    }

    /// The cut mark inherits the style it cut INTO — an ellipsis in the default ink at the end of a
    /// coloured line would read as a separate piece of output rather than as this line's end.
    func testTheCutMarkWearsTheStyleItCutInto() {
        let raw = bytes("\u{1B}[34m" + String(repeating: "x", count: 40))
        let preview = BlockOutputPreviewBuilder.make(
            rawOutput: raw, failed: false, maxColumns: 10,
        )
        let line = preview.lines[0]
        XCTAssertEqual(line.last?.text, "…")
        XCTAssertEqual(line.last?.style.foreground, .indexed(4))
    }
}
