// BlockOutputPreviewTests — pins the ladder peek's excerpt rule (user-directed 2026-08-09): a clean
// command is read from its FIRST lines, a failed one from its LAST, and the card is always told how
// much it is not showing (and from which end), so a preview can never quietly stand in for the whole.

import XCTest
@testable import SlopDeskWorkspaceCore

final class BlockOutputPreviewTests: XCTestCase {
    private let log = (1...20).map { "line \($0)" }.joined(separator: "\n")

    func testACleanCommandIsReadFromTheTop() {
        let preview = BlockOutputPreviewBuilder.make(plainText: log, failed: false, maxLines: 8)
        XCTAssertEqual(preview.lines.first, "line 1")
        XCTAssertEqual(preview.lines.last, "line 8")
        XCTAssertEqual(preview.hiddenCount, 12)
        XCTAssertFalse(preview.fromTail)
    }

    /// The regression this split exists for: the first lines of a failing build are the banner every
    /// build prints, and the message that matters is the last thing said.
    func testAFailedCommandIsReadFromTheBottom() {
        let preview = BlockOutputPreviewBuilder.make(plainText: log, failed: true, maxLines: 8)
        XCTAssertEqual(preview.lines.first, "line 13")
        XCTAssertEqual(preview.lines.last, "line 20")
        XCTAssertEqual(preview.hiddenCount, 12)
        XCTAssertTrue(preview.fromTail)
    }

    func testOutputThatFitsHidesNothingFromEitherEnd() {
        for failed in [false, true] {
            let preview = BlockOutputPreviewBuilder.make(
                plainText: "one\ntwo\nthree", failed: failed, maxLines: 8,
            )
            XCTAssertEqual(preview.lines, ["one", "two", "three"])
            XCTAssertEqual(preview.hiddenCount, 0)
        }
    }

    /// A block's captured bytes almost always begin and end with the newline that separated the
    /// command from its prompt — a preview opening on an empty row reads as a bug.
    func testBlankEdgesAreDroppedBeforeTheExcerptIsTaken() {
        let preview = BlockOutputPreviewBuilder.make(
            plainText: "\n   \nreal output\n\n  \n", failed: false, maxLines: 8,
        )
        XCTAssertEqual(preview.lines, ["real output"])
        XCTAssertEqual(preview.hiddenCount, 0)
        XCTAssertFalse(preview.isEmpty)
    }

    func testAllBlankOutputIsEmptyRatherThanARowOfNothing() {
        let preview = BlockOutputPreviewBuilder.make(plainText: "\n\n   \n", failed: false)
        XCTAssertTrue(preview.isEmpty)
        XCTAssertEqual(preview.hiddenCount, 0)
    }

    func testEmptyOutputIsEmpty() {
        XCTAssertTrue(BlockOutputPreviewBuilder.make(plainText: "", failed: false).isEmpty)
    }

    /// A build log can emit one 4 000-column line; the card is a fixed width, so the cut happens here
    /// and is VISIBLE as a cut rather than being clipped away by the layout.
    func testAnOverLongLineIsCutWithAnEllipsis() {
        let long = String(repeating: "x", count: 500)
        let preview = BlockOutputPreviewBuilder.make(plainText: long, failed: false, maxColumns: 20)
        XCTAssertEqual(preview.lines, [String(repeating: "x", count: 20) + "…"])
    }

    func testALineExactlyAtTheColumnCapIsNotMarkedAsCut() {
        let exact = String(repeating: "x", count: 20)
        let preview = BlockOutputPreviewBuilder.make(plainText: exact, failed: false, maxColumns: 20)
        XCTAssertEqual(preview.lines, [exact])
    }

    /// The count is CHARACTERS, not UTF-8 bytes — a monospaced card advances by grapheme clusters.
    func testTheColumnCapCountsCharactersNotBytes() {
        let preview = BlockOutputPreviewBuilder.make(
            plainText: String(repeating: "é", count: 30), failed: false, maxColumns: 10,
        )
        XCTAssertEqual(preview.lines, [String(repeating: "é", count: 10) + "…"])
    }

    /// A tab inside a fixed-width card advances by a value the card cannot honour — expand it before
    /// the cut so the column count means what it says.
    func testTabsAreExpandedBeforeTheCut() {
        let preview = BlockOutputPreviewBuilder.make(plainText: "\tok", failed: false)
        XCTAssertEqual(preview.lines, ["    ok"])
    }

    func testDegenerateLineBudgetShowsNothing() {
        let preview = BlockOutputPreviewBuilder.make(plainText: log, failed: false, maxLines: 0)
        XCTAssertTrue(preview.isEmpty)
    }

    /// End-to-end with the sanitizer: raw VT bytes in, a clean excerpt out (the real path — the
    /// ladder previews `copyBlockOutput`'s VT-stripped text).
    func testTheExcerptSurvivesTheSanitizerOnRealVtBytes() throws {
        let raw = "\u{1B}[32mPASS\u{1B}[0m first\nsecond\n\u{1B}[31mFAIL\u{1B}[0m third\n"
        let plain = try BlockOutputSanitizer.plainText(from: XCTUnwrap(raw.data(using: .utf8)))
        let preview = BlockOutputPreviewBuilder.make(plainText: plain, failed: true, maxLines: 2)
        XCTAssertEqual(preview.lines, ["second", "FAIL third"])
        XCTAssertEqual(preview.hiddenCount, 1)
    }
}
