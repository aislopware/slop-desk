// CursorColorHexTests — pins the pure 6-hex ↔ RGB bridge that `CursorPreviewView`'s color wells
// use to read/write the `TerminalPreferences.cursorColor` / `cursorTextColor` fields. The helper is AppKit-
// free so it runs headlessly on the macOS `swift test` host. Each case asserts against an INDEPENDENT
// expected value (not the helper's own derivation), so a broken parse / format / clamp fails the build.

#if canImport(SwiftUI)
import XCTest
@testable import SlopDeskClientUI

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
}
#endif
