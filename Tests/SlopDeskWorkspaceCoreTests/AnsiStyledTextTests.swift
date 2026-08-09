// AnsiStyledTextTests — pins the STYLED half of the block-output skimmer (user-directed 2026-08-09:
// the ladder's peek shows a command's output the way the terminal drew it).
//
// `BlockOutputSanitizerTests` already pins the TEXT this pass produces — plain text is now this pass
// with the styles dropped, so those tests are the referee for the skimming rules and these are the
// referee for what each byte was written UNDER. The malformed cases matter as much as the well-formed
// ones: this pass runs over bytes a remote shell chose, so every degenerate form must yield a style,
// never a trap.

import XCTest
@testable import SlopDeskWorkspaceCore

final class AnsiStyledTextTests: XCTestCase {
    private func parse(_ text: String) -> [[AnsiRun]] {
        AnsiStyledParser.lines(from: Data(text.utf8))
    }

    /// The one line of the whole file: joining the runs back up must reproduce the plain text, which
    /// is how the clipboard path can be expressed on this pass without drifting from it.
    func testTheRunsRejoinIntoExactlyThePlainText() {
        let raw = "\u{1B}[1;32mok\u{1B}[0m done\nsecond\ttab\n\u{1B}[31mlast"
        let data = Data(raw.utf8)
        let rejoined = AnsiStyledParser.lines(from: data)
            .map { $0.map(\.text).joined() }
            .joined(separator: "\n")
        XCTAssertEqual(rejoined, BlockOutputSanitizer.plainText(from: data))
    }

    func testUnstyledTextIsOnePlainRun() {
        let line = parse("hello")[0]
        XCTAssertEqual(line.map(\.text), ["hello"])
        XCTAssertTrue(line[0].style.isPlain)
    }

    func testTheStandardAndBrightForegroundSlots() {
        let line = parse("\u{1B}[31mred\u{1B}[91mbright")[0]
        XCTAssertEqual(line.map(\.text), ["red", "bright"])
        XCTAssertEqual(line[0].style.foreground, .indexed(1))
        XCTAssertEqual(line[1].style.foreground, .indexed(9))
    }

    func testBackgroundSlotsAndTheirReset() {
        let line = parse("\u{1B}[42mon\u{1B}[49moff")[0]
        XCTAssertEqual(line[0].style.background, .indexed(2))
        XCTAssertNil(line[1].style.background)
    }

    /// `38;5;N` — the 256-colour form every modern tool emits.
    func testTheTwoFiftySixColourForm() {
        let line = parse("\u{1B}[38;5;208mamber")[0]
        XCTAssertEqual(line[0].style.foreground, .indexed(208))
    }

    /// `38;2;r;g;b` — truecolour, kept as sent (no quantising to a palette the profile may not match).
    func testTheDirectTwentyFourBitForm() {
        let line = parse("\u{1B}[38;2;149;128;255mpurple")[0]
        XCTAssertEqual(line[0].style.foreground, .rgb(r: 149, g: 128, b: 255))
    }

    /// The colon-separated variant of the same sequence, which some tools emit per the ITU spec.
    func testColonSeparatedParametersAreAlsoParameters() {
        let line = parse("\u{1B}[38:5:208mamber")[0]
        XCTAssertEqual(line[0].style.foreground, .indexed(208))
    }

    func testAttributesAndTheirIndividualResets() {
        let line = parse("\u{1B}[1;3;4;7mall\u{1B}[22;23;24;27mnone")[0]
        let on = line[0].style
        XCTAssertTrue(on.bold && on.italic && on.underline && on.inverse)
        let off = line[1].style
        XCTAssertFalse(off.bold || off.italic || off.underline || off.inverse)
    }

    /// SGR 2 is DIM, not "bold off" — and 22 clears both.
    func testDimIsItsOwnAttributeAndTwentyTwoClearsBoth() {
        let line = parse("\u{1B}[1;2mboth\u{1B}[22mneither")[0]
        XCTAssertTrue(line[0].style.bold)
        XCTAssertTrue(line[0].style.dim)
        XCTAssertTrue(line[1].style.isPlain)
    }

    /// Reverse video is REPORTED, not resolved: the defaults it swaps in belong to the surface, and
    /// only the view knows those.
    func testInverseIsReportedRatherThanResolved() {
        let line = parse("\u{1B}[7mrev")[0]
        XCTAssertTrue(line[0].style.inverse)
        XCTAssertNil(line[0].style.foreground)
        XCTAssertNil(line[0].style.background)
    }

    func testResetReturnsToPlainAndSoDoesTheBareForm() {
        for reset in ["\u{1B}[0m", "\u{1B}[m"] {
            let line = parse("\u{1B}[1;31mred\(reset)plain")[0]
            XCTAssertEqual(line.count, 2, "unexpected run split for \(reset.debugDescription)")
            XCTAssertTrue(line[1].style.isPlain)
        }
    }

    /// Same style either side of a no-op sequence must COALESCE — a run per escape would make the
    /// card's attributed string grow with the sender's punctuation rather than with its content.
    func testAdjacentSameStyleTextIsOneRun() {
        let line = parse("\u{1B}[31mred\u{1B}[31mstill")[0]
        XCTAssertEqual(line.map(\.text), ["redstill"])
    }

    /// Style is per-CELL, so a `\r` overwrite takes the STYLE of the frame that overwrote it — the
    /// same rule that makes a progress bar collapse to its final frame rather than to a smear.
    func testACarriageReturnRewriteCarriesTheNewFramesStyle() {
        let line = parse("\u{1B}[31m1234\r\u{1B}[32mab")[0]
        XCTAssertEqual(line.map(\.text), ["ab", "34"])
        XCTAssertEqual(line[0].style.foreground, .indexed(2))
        XCTAssertEqual(line[1].style.foreground, .indexed(1))
    }

    func testEraseToLineEndTruncatesAtTheCursor() {
        let line = parse("\u{1B}[31mlong text\r\u{1B}[32mnew\u{1B}[K")[0]
        XCTAssertEqual(line.map(\.text), ["new"])
        XCTAssertEqual(line[0].style.foreground, .indexed(2))
    }

    /// The style must SURVIVE a line break — a multi-line coloured banner is one SGR then N lines.
    func testStyleCarriesAcrossALineBreak() {
        let lines = parse("\u{1B}[33mone\ntwo")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0][0].style.foreground, .indexed(3))
        XCTAssertEqual(lines[1][0].style.foreground, .indexed(3))
    }

    // MARK: Degenerate input — every one of these must produce a style, not a trap

    func testAnUnterminatedEscapeAtTheEndConsumesTheRest() {
        let lines = parse("text\u{1B}[38;5")
        XCTAssertEqual(lines.map { $0.map(\.text).joined() }, ["text"])
    }

    func testATruncatedExtendedColourIsIgnoredRatherThanGuessed() {
        for raw in ["\u{1B}[38;5mx", "\u{1B}[38;2;10;20mx", "\u{1B}[38mx"] {
            let line = parse(raw)[0]
            XCTAssertNil(line[0].style.foreground, "guessed a colour for \(raw.debugDescription)")
        }
    }

    /// A parameter run long enough to overflow `Int` if accumulated without a cap.
    func testAnAbsurdParameterRunDoesNotTrap() {
        let line = parse("\u{1B}[" + String(repeating: "9", count: 40) + "mx")[0]
        XCTAssertEqual(line.map(\.text), ["x"])
    }

    func testAnOutOfRangeDirectColourIsClampedNotWrapped() {
        let line = parse("\u{1B}[38;2;999;0;0mx")[0]
        XCTAssertEqual(line[0].style.foreground, .rgb(r: 255, g: 0, b: 0))
    }

    /// A private-mode CSI (`ESC [ ? 25 h`) is not an SGR and must leave the style alone — the cursor
    /// hide/show a spinner emits between frames is the commonest one in real captured output.
    func testAPrivateModeSequenceIsNotAnSgr() {
        let line = parse("\u{1B}[31ma\u{1B}[?25hb")[0]
        XCTAssertEqual(line.map(\.text), ["ab"])
        XCTAssertEqual(line[0].style.foreground, .indexed(1))
    }

    /// An OSC (a title set, a hyperlink, an OSC 133 marker) carries no style and must be skipped
    /// whole — a half-skipped OSC would spill its payload into the preview as text.
    func testAnOscIsSkippedWholeAndChangesNothing() {
        let line = parse("\u{1B}[32ma\u{1B}]0;a title\u{07}b")[0]
        XCTAssertEqual(line.map(\.text), ["ab"])
        XCTAssertEqual(line[0].style.foreground, .indexed(2))
    }

    func testInvalidUtf8BecomesAReplacementRatherThanLosingTheLine() {
        let raw = Data([0x61, 0xFF, 0x62])
        let line = AnsiStyledParser.lines(from: raw)[0]
        XCTAssertEqual(line.map(\.text).joined(), "a\u{FFFD}b")
    }

    func testEmptyInputIsOneEmptyLine() {
        XCTAssertEqual(AnsiStyledParser.lines(from: Data()), [[]])
    }
}
