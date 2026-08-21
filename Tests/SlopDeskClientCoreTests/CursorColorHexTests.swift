// CursorColorHexTests — the 6-hex ↔ RGB bridge the cursor colour wells read and write the
// `TerminalPreferences.cursorColor` / `cursorTextColor` fields through, driven at its two public entry
// points. AppKit-free, so it runs headlessly on the macOS `swift test` host.
//
// WHAT THIS SUITE IS NOW. The rule moved to `slopdesk_terminal::cursor_color` and the crate pins it there —
// the clamp order, the NaN answer, the round-half-away-from-zero, the sign the Swift used to accept, the one
// Unicode scalar the config trim reads differently from Foundation. What is pinned HERE is the other half:
// that `CursorColorHex.rgb` and `.hex` still answer the same things through the door they now ask. Every
// behavioural case below predates the port and is unchanged, which is what makes "delete the original in the
// same change" a diff a reviewer can check (`docs/55` §6) — and the marshalling cases at the end are the
// ones only this side can fail, because a packed answer unpacked wrong on this side is invisible in Rust.
//
// Each case asserts against an INDEPENDENT expected value, never the helper's own derivation, so a broken
// parse / format / clamp / unpack fails the build.

#if canImport(SwiftUI)
import SlopDeskClientCore
import XCTest

final class CursorColorHexTests: XCTestCase {
    // MARK: rgb(_:) — parse

    func testParsesValidHexUppercaseAndLowercase() {
        let upper = CursorColorHex.rgb("FF8800")
        XCTAssertEqual(upper?.r, 255)
        XCTAssertEqual(upper?.g, 136)
        XCTAssertEqual(upper?.b, 0)

        // Case-insensitive: the lowercased spelling parses to the SAME channels.
        let lower = CursorColorHex.rgb("ff8800")
        XCTAssertEqual(lower?.r, 255)
        XCTAssertEqual(lower?.g, 136)
        XCTAssertEqual(lower?.b, 0)
    }

    func testParsesBlackAndWhite() {
        XCTAssertEqual(CursorColorHex.rgb("000000")?.r, 0)
        XCTAssertEqual(CursorColorHex.rgb("000000")?.b, 0)
        XCTAssertEqual(CursorColorHex.rgb("FFFFFF")?.g, 255)
    }

    func testEmptyStringIsNilFollowTheme() {
        // The empty / "follow the theme" sentinel must NOT parse to a colour (so the well shows the default).
        XCTAssertNil(CursorColorHex.rgb(""))
        XCTAssertNil(CursorColorHex.rgb("   "))
    }

    func testWrongLengthAndInvalidCharsAreNil() {
        XCTAssertNil(CursorColorHex.rgb("12345")) // 5 chars
        XCTAssertNil(CursorColorHex.rgb("1234567")) // 7 chars
        XCTAssertNil(CursorColorHex.rgb("#FF8800")) // leading hash → 7 chars
        XCTAssertNil(CursorColorHex.rgb("GG0000")) // non-hex digit
    }

    // MARK: hex(r:g:b:) — format

    func testFormatsUnitDoublesToUppercaseHex() {
        XCTAssertEqual(CursorColorHex.hex(r: 1, g: 136.0 / 255, b: 0), "FF8800")
        XCTAssertEqual(CursorColorHex.hex(r: 0, g: 0, b: 0), "000000")
        XCTAssertEqual(CursorColorHex.hex(r: 1, g: 1, b: 1), "FFFFFF")
    }

    func testFormatClampsOutOfRangeAndNaN() {
        XCTAssertEqual(CursorColorHex.hex(r: 1.5, g: -0.2, b: 0), "FF0000")
        XCTAssertEqual(CursorColorHex.hex(r: .nan, g: .infinity, b: 0), "00FF00")
    }

    // MARK: round trip

    func testParseFormatRoundTripIsIdentity() {
        for token in ["3FA9F5", "37352F", "FCFBF9", "010203", "ABCDEF"] {
            guard let c = CursorColorHex.rgb(token) else {
                XCTFail("\(token) should parse")
                continue
            }
            let back = CursorColorHex.hex(
                r: Double(c.r) / 255, g: Double(c.g) / 255, b: Double(c.b) / 255,
            )
            XCTAssertEqual(back, token, "round trip drifted for \(token)")
        }
    }

    // MARK: the crossing itself

    /// The door answers one packed `Int32`, so a channel taken out at the wrong shift is a bug that lives
    /// entirely on THIS side and cannot fail a Rust test. Three DISTINCT channels are what catch it: a
    /// symmetric colour like `808080` would survive any permutation of the three masks.
    func testPackedAnswerIsUnpackedInTheRightChannelOrder() {
        let parsed = CursorColorHex.rgb("102040")
        XCTAssertEqual(parsed?.r, 0x10)
        XCTAssertEqual(parsed?.g, 0x20)
        XCTAssertEqual(parsed?.b, 0x40)
    }

    /// The parse takes a `String` and the door takes UTF-8 bytes, so a value that is not six ASCII
    /// characters has to cross as more bytes than characters and still answer `nil` rather than reading a
    /// byte count as a character count. A settings field is free text; nothing stops a person pasting this.
    func testMultiByteScalarsCrossAsBytesAndStillNameNoColour() {
        XCTAssertNil(CursorColorHex.rgb("ÀÀÀ"), "three scalars, six UTF-8 bytes — a length, not a colour")
        XCTAssertNil(CursorColorHex.rgb("FF88🎨"))
        XCTAssertNil(CursorColorHex.rgb("😀😀😀"))
    }

    /// The format side writes into a fixed six-byte buffer and decodes exactly what was written. A door that
    /// reported a different length, or a decode that read past it, would show up as a string of the wrong
    /// size here — the one thing the Rust side has no way to observe.
    func testFormattedAnswerIsAlwaysSixASCIICharacters() {
        for value in [-1.0, 0.0, 0.5, 1.0, 2.0, Double.nan, Double.infinity, -Double.infinity] {
            let answer = CursorColorHex.hex(r: value, g: value, b: value)
            XCTAssertEqual(answer.count, 6, "\(value) formatted to \(answer)")
            XCTAssertEqual(answer.utf8.count, 6, "\(value) formatted to non-ASCII bytes")
        }
    }
}
#endif
