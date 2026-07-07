import XCTest
@testable import SlopDeskWorkspaceCore

/// Keyboard-map audit 2026-07-07: pins the pure ``KeyEventTextPolicy`` — the testable heart of the
/// "arrow keys type garbage into kitty-protocol apps (Claude Code)" fix. AppKit reports named function
/// keys as PUA placeholders (U+F700–F8FF) in `event.characters`; forwarding one as `ghostty_input_key_s
/// .text` makes ghostty's kitty encoder write the raw PUA bytes to the PTY instead of the `CSI A`-family
/// sequence. The policy must drop exactly that class and NOTHING else — real text, IME output, and
/// unmodified C0 controls all pass verbatim (ghostty's encoder owns their handling).
final class KeyEventTextPolicyTests: XCTestCase {
    // MARK: the fix — function-key placeholders are dropped

    func testArrowKeyPlaceholdersYieldNil() {
        // NSUpArrow/Down/Left/RightFunctionKey — the exact keys from the field report.
        for placeholder in ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"] {
            XCTAssertNil(
                KeyEventTextPolicy.encoderText(for: placeholder),
                "arrow placeholder \(placeholder) must not reach the encoder",
            )
        }
    }

    func testNamedNavigationAndFunctionKeysYieldNil() throws {
        // Home F729 / End F72B / PageUp F72C / PageDown F72D / forward-delete F728 / F1 F704 / F20 F717,
        // plus both ends of the reserved Apple PUA block upstream Ghostty filters.
        for value: UInt32 in [0xF729, 0xF72B, 0xF72C, 0xF72D, 0xF728, 0xF704, 0xF717, 0xF700, 0xF8FF] {
            let scalar = try XCTUnwrap(UnicodeScalar(value))
            XCTAssertNil(KeyEventTextPolicy.encoderText(for: String(scalar)))
        }
    }

    // MARK: everything else passes verbatim

    func testPlainTextPassesThrough() {
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "a"), "a")
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "A"), "A")
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "!"), "!")
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "đ"), "đ") // non-ASCII layout output
    }

    func testUnmodifiedC0ControlsPassThrough() {
        // Enter / Tab / Esc / DEL — ghostty's encoder filters control text itself (isControlUtf8);
        // dropping them here would break the enter/backspace IME special cases.
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "\r"), "\r")
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "\t"), "\t")
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "\u{1B}"), "\u{1B}")
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "\u{7F}"), "\u{7F}")
    }

    func testMultiScalarStringsPassThrough() {
        // Composed/IME commits are real text even when longer than one scalar (mirrors upstream's
        // single-character guard).
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "việt"), "việt")
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "🇻🇳"), "🇻🇳")
    }

    func testBoundaryScalarsOutsideThePUABlockPassThrough() {
        // One below / one above the filtered range — the filter must be exactly F700–F8FF.
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "\u{F6FF}"), "\u{F6FF}")
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: "\u{F900}"), "\u{F900}")
    }

    func testNilAndEmptyAreStable() {
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: nil))
        XCTAssertEqual(KeyEventTextPolicy.encoderText(for: ""), "")
    }
}
