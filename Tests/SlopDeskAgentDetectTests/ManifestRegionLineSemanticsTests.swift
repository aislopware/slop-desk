import XCTest
@testable import SlopDeskAgentDetect

/// Byte-exact Rust `str::lines()` semantics for region math — pinned after the
/// herdr-differential harness (scripts/herdr-differential.py) caught two CR-handling
/// divergences the ported fixture suite missed: Swift's grapheme-based split never breaks
/// `\r\n`, and Rust keeps the `\r` on a final line that has no trailing newline.
final class ManifestRegionLineSemanticsTests: XCTestCase {
    func testRustLinesSplitsCRLF() {
        XCTAssertEqual(RegionText.rustLines("a\r\nb\r\nc"), ["a", "b", "c"])
    }

    func testRustLinesKeepsCarriageReturnOnFinalUnterminatedLine() {
        XCTAssertEqual(RegionText.rustLines("a\nb\r"), ["a", "b\r"])
    }

    func testRustLinesStripsOnlyOneCarriageReturnBeforeNewline() {
        XCTAssertEqual(RegionText.rustLines("a\r\r\nb"), ["a\r", "b"])
    }

    func testRustLinesDropsOneTrailingEmptyOnCRLFTerminator() {
        XCTAssertEqual(RegionText.rustLines("a\r\n"), ["a"])
    }

    /// The `\r`-drift slice on CRLF content, verified against the real herdr binary:
    /// stripped-line offset math starts the bottom-1 slice two bytes early, inside the
    /// previous line's `\r\n` terminator. Deliberate upstream quirk — do not "fix".
    func testBottomNonEmptyLinesCRLFDriftMatchesUpstream() {
        let screen = "line one\r\ndevin\r\nline three\r"
        let region = ManifestRegion.bottomNonEmptyLines(1).resolveScreen(screen)
        XCTAssertEqual(region, "\r\nline three\r")
    }

    /// Rust `trim()` treats `\r` as whitespace, so a final bare-`\r` line is blank and the
    /// non-empty scan reaches past it.
    func testCarriageReturnOnlyFinalLineIsBlankForNonEmptyScan() {
        let screen = "abc\n\r"
        let region = ManifestRegion.bottomNonEmptyLines(1).resolveScreen(screen)
        XCTAssertEqual(region, "abc\n\r")
    }

    func testHorizontalRuleDetectionTrimsCarriageReturn() {
        XCTAssertTrue(ManifestRegion.isHorizontalRule("───\r"))
    }
}
