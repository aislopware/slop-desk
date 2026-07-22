import XCTest
@testable import SlopDeskWorkspaceCore

/// Pins the pure ``KeyEventTextPolicy`` — the testable heart of two encoder-text fixes: "arrow keys type
/// garbage into kitty-protocol apps (Claude Code)" (PUA placeholders U+F700–F8FF forwarded as
/// `ghostty_input_key_s.text` make the kitty encoder write raw PUA bytes instead of `CSI A`), and
/// "Shift+Tab / Shift+Enter / ⌥Enter lose their modifier under the kitty protocol" (control-char text
/// makes `effectiveMods` subtract the consumed Shift/Option, collapsing the chord to a bare `\t`/`\r`).
/// The policy drops exactly those two classes — PUA placeholders and control-led text — and NOTHING
/// else: real text and IME output pass verbatim.
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

    func testC0ControlTextYieldsNil() {
        // Enter / Tab / Shift+Tab (AppKit's 0x19 back-tab) / Esc must NOT carry text into the encoder.
        // ghostty's `effectiveMods` subtracts `consumed_mods` whenever `utf8` is NON-EMPTY, and the kitty
        // path short-circuits enter/tab/backspace on empty binding mods — so a "\t" payload for Shift+Tab
        // made the encoder emit a bare `\t` instead of `CSI 9;2u` (Claude Code's permission-mode toggle),
        // and "\r" for Shift+Enter emitted a bare `\r` (submit) instead of `CSI 13;2u` (newline). Upstream
        // drops any text whose first UTF-8 byte is < 0x20 (SurfaceView_AppKit `keyAction`); mirror that.
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: "\r"))
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: "\t"))
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: "\u{19}"))
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: "\u{1B}"))
    }

    func testControlLedMultiScalarTextYieldsNil() {
        // Upstream's guard is on the FIRST UTF-8 byte of the whole payload, not a single-scalar special
        // case — a control-led string is never legitimate IME output.
        XCTAssertNil(KeyEventTextPolicy.encoderText(for: "\u{1B}[A"))
    }

    func testDELPassesThrough() {
        // DEL (0x7F) is ≥ 0x20 by upstream's first-byte check and both encoder paths special-case
        // backspace text via `isControlUtf8` — keep parity with upstream, which forwards it.
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
