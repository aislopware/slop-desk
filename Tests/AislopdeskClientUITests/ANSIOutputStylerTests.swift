import Foundation
import SwiftUI
import XCTest
@testable import AislopdeskClientUI

/// The colour-preserving block-output renderer (the "block output has no colour, just white text" fix):
/// SGR runs → an `AttributedString` mapped to the active theme's ANSI palette, cursor-motion/OSC stripped.
final class ANSIOutputStylerTests: XCTestCase {
    // A 16-slot palette of DISTINCT sentinel RGBs so a mis-mapped index is caught (slot n == 0x0n_0n_0n… no,
    // use recognisable values). Index i → 0x(i+1) repeated, e.g. slot 1 = 0x111111, slot 10 = 0xAAAAAA.
    private let palette: [UInt32] = (0..<16).map { i in
        let b = UInt32(i + 1) * 0x11 // 0x11, 0x22, … 0x... distinct per slot, ≤ 0x110 clamps fine below 0x100 for i<15
        let c = min(b, 0xFF)
        return (c << 16) | (c << 8) | c
    }

    private let defaultFg: UInt32 = 0xEEEEEE
    private let defaultBg: UInt32 = 0x161616

    /// (text, foregroundColor) for each run, so a test can assert both the surviving characters and the
    /// colour mapping.
    private func runs(_ string: String) -> [(text: String, fg: Color?)] {
        let attr = ANSIOutputStyler.attributed(
            from: Data(string.utf8), palette: palette, defaultFg: defaultFg, defaultBg: defaultBg,
        )
        return attr.runs.map { run in
            (String(attr[run.range].characters), run.foregroundColor)
        }
    }

    private func plain(_ string: String) -> String {
        let attr = ANSIOutputStyler.attributed(
            from: Data(string.utf8), palette: palette, defaultFg: defaultFg, defaultBg: defaultBg,
        )
        return String(attr.characters)
    }

    func testEmptyInput() {
        XCTAssertEqual(
            ANSIOutputStyler.attributed(from: Data(), palette: palette, defaultFg: defaultFg, defaultBg: defaultBg)
                .characters.count,
            0,
        )
    }

    func testPlainTextGetsDefaultForeground() {
        let r = runs("hello")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].text, "hello")
        XCTAssertEqual(r[0].fg, Color(slateHex: defaultFg))
    }

    func testForegroundColourRunMapsToPalette() {
        // `ESC[31m ERR ESC[0m ok` — the ERR run is ANSI red (slot 1); ok reverts to default.
        let r = runs("\u{1B}[31mERR\u{1B}[0mok")
        XCTAssertEqual(r.map(\.text), ["ERR", "ok"])
        XCTAssertEqual(r[0].fg, Color(slateHex: palette[1]))
        XCTAssertEqual(r[1].fg, Color(slateHex: defaultFg))
    }

    func testBoldBrightensBaseColour() {
        // `ESC[1;32m` — bold + ANSI green (slot 2) renders as the BRIGHT slot 10.
        let r = runs("\u{1B}[1;32mX")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].fg, Color(slateHex: palette[10]))
    }

    func testBrightForegroundRange() {
        // `ESC[92m` — bright green directly (slot 10).
        let r = runs("\u{1B}[92mX")
        XCTAssertEqual(r[0].fg, Color(slateHex: palette[10]))
    }

    func test256ColourCube() {
        // `ESC[38;5;196m` — a cube entry (196 = 16 + 180 → r=5,g=0,b=0 → 0xFF0000).
        let r = runs("\u{1B}[38;5;196mX")
        XCTAssertEqual(r[0].fg, Color(slateHex: 0xFF0000))
    }

    func testTruecolour() {
        // `ESC[38;2;10;20;30m` → 0x0A141E.
        let r = runs("\u{1B}[38;2;10;20;30mX")
        XCTAssertEqual(r[0].fg, Color(slateHex: 0x0A141E))
    }

    func testCursorMotionStripped() {
        // A CSI erase / cursor-up between letters is dropped; the letters survive.
        XCTAssertEqual(plain("a\u{1B}[2K\u{1B}[1Ab"), "ab")
    }

    func testOSCTitleStripped() {
        XCTAssertEqual(plain("\u{1B}]0;my title\u{07}visible"), "visible")
    }

    func testCRLFCollapsedAndLoneCROverwrites() {
        XCTAssertEqual(plain("a\r\nb"), "a\nb") // CRLF → LF
        // A lone CR is OVERWRITE motion: the cursor rewinds to column 0 and "X" replaces the first cell,
        // leaving "Xbc" (the terminal's final frame) — NOT the concatenation "abcX".
        XCTAssertEqual(plain("abc\rX"), "Xbc")
    }

    func testProgressBarRendersFinalFrameNotConcatenation() {
        // Three redraws of one line via CR (the pip/cargo/curl progress-bar idiom). The FINAL frame wins;
        // the earlier frames are overwritten, not concatenated into one giant line.
        XCTAssertEqual(plain("10.2 MB\r10.3 MB\r10.5 MB"), "10.5 MB")
    }

    func testEraseToEndOfLineTruncatesShorterFrame() {
        // A longer frame then a shorter one that clears the tail via `ESC [ K` — no leftover characters.
        XCTAssertEqual(plain("100%%\rok\u{1B}[K"), "ok")
    }

    func testLongDigitSGRParamDoesNotTrap() {
        // A degenerate SGR with a 30-digit parameter must NOT overflow Int / trap — the run survives.
        XCTAssertEqual(plain("\u{1B}[999999999999999999999999999999mX"), "X")
    }

    func testDCSAndAPCPayloadsAreStripped() {
        // A DCS (sixel) and an APC (kitty graphics) payload must be consumed up to ST, not leaked as text.
        XCTAssertEqual(plain("\u{1B}Pq#0;2;100;0;0~~~\u{1B}\\visible"), "visible")
        XCTAssertEqual(plain("\u{1B}_Gf=100,payload==\u{1B}\\after"), "after")
    }

    func testTrailingReverseVideoEOLMarkDropped() {
        // zsh PROMPT_EOL_MARK: a reverse-video `%` + pad + lone CR at end → dropped (no stray trailing %).
        XCTAssertEqual(plain("output\n\u{1B}[7m%\u{1B}[0m \r"), "output\n")
    }

    func testReverseVideoPercentMidStreamKept() {
        // A reverse `%` FOLLOWED by real content is NOT a trailing mark → kept.
        XCTAssertEqual(plain("\u{1B}[7m%\u{1B}[0mdone"), "%done")
    }

    func testMalformedTrailingEscapeDoesNotTrap() {
        XCTAssertEqual(plain("done\u{1B}"), "done")
        XCTAssertEqual(plain("x\u{1B}]0;no-term"), "x")
        XCTAssertEqual(plain("y\u{1B}[38;5"), "y") // truncated extended-colour SGR
    }

    func testUnderlineAttributeApplied() {
        let attr = ANSIOutputStyler.attributed(
            from: Data("\u{1B}[4mU\u{1B}[0m".utf8), palette: palette, defaultFg: defaultFg, defaultBg: defaultBg,
        )
        let underlined = attr.runs.contains { $0.underlineStyle == .single }
        XCTAssertTrue(underlined, "an SGR-4 run should carry a single underline")
    }
}
