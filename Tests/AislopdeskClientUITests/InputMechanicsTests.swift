import XCTest
@testable import AislopdeskClientUI

/// Unit tests for the pure iOS table-stakes logic: floating-cursor delta→arrow mapping, the
/// accessory-bar show/hide decision, and the IME-vs-key routing decision. These are the
/// macOS-testable cores behind the `#if os(iOS)` UIKit wrappers (doc 17 §2.5).
final class InputMechanicsTests: XCTestCase {

    // MARK: FloatingCursorMapping (5pt threshold → arrow count, the spec's examples)

    func testFloatingCursorSubThresholdEmitsNothing() {
        var m = FloatingCursorMapping()         // 5pt
        XCTAssertEqual(m.feed(deltaX: 4), [])   // 4pt → 0 arrows
        XCTAssertEqual(m.accumulated, 4, accuracy: 0.0001)
    }

    func testFloatingCursorOneRightArrow() {
        var m = FloatingCursorMapping()
        XCTAssertEqual(m.feed(deltaX: 6), [.right])  // 6pt → 1 right
        XCTAssertEqual(m.accumulated, 1, accuracy: 0.0001) // 1pt remainder
    }

    func testFloatingCursorTwoLeftArrows() {
        var m = FloatingCursorMapping()
        XCTAssertEqual(m.feed(deltaX: -12), [.left, .left]) // -12pt → 2 left
        XCTAssertEqual(m.accumulated, -2, accuracy: 0.0001) // -2pt remainder
    }

    func testFloatingCursorAccumulatesSmallDeltas() {
        var m = FloatingCursorMapping()
        // Three 2pt nudges = 6pt total → one right arrow once the threshold is crossed.
        XCTAssertEqual(m.feed(deltaX: 2), [])
        XCTAssertEqual(m.feed(deltaX: 2), [])
        XCTAssertEqual(m.feed(deltaX: 2), [.right])
        XCTAssertEqual(m.accumulated, 1, accuracy: 0.0001)
    }

    func testFloatingCursorExactThresholdEmitsOne() {
        var m = FloatingCursorMapping()
        XCTAssertEqual(m.feed(deltaX: 5), [.right]) // exactly 5pt → 1
        XCTAssertEqual(m.accumulated, 0, accuracy: 0.0001)
    }

    func testFloatingCursorResetClearsRemainder() {
        var m = FloatingCursorMapping()
        _ = m.feed(deltaX: 4)
        m.reset()
        XCTAssertEqual(m.accumulated, 0)
    }

    func testFloatingCursorNonFiniteDeltaIsIgnored() {
        var m = FloatingCursorMapping()
        XCTAssertEqual(m.feed(deltaX: .nan), [])
        XCTAssertEqual(m.feed(deltaX: .infinity), [])
        XCTAssertEqual(m.feed(deltaX: -.infinity), [])
        XCTAssertEqual(m.accumulated, 0, accuracy: 0.0001, "non-finite deltas never poison the accumulator")
        XCTAssertEqual(m.feed(deltaX: 6), [.right], "a finite delta after a non-finite one still works")
    }

    func testFloatingCursorByteEncoding() {
        XCTAssertEqual(FloatingCursorMapping.bytes(for: .right), [0x1B, 0x5B, 0x43]) // ESC [ C
        XCTAssertEqual(FloatingCursorMapping.bytes(for: .left), [0x1B, 0x5B, 0x44])  // ESC [ D
        XCTAssertEqual(FloatingCursorMapping.bytes(for: [.left, .left]),
                       [0x1B, 0x5B, 0x44, 0x1B, 0x5B, 0x44])
    }

    // MARK: KeyboardAccessoryDecision (~150pt threshold)

    func testAccessoryHiddenWhenKeyboardAbsent() {
        let d = KeyboardAccessoryDecision()
        XCTAssertFalse(d.shouldShowAccessoryBar(keyboardHeight: 0))
    }

    func testAccessoryHiddenForHardwareKeyboardShortcutBar() {
        let d = KeyboardAccessoryDecision()
        // A hardware-keyboard shortcut bar is short (< 150pt) → hide.
        XCTAssertFalse(d.shouldShowAccessoryBar(keyboardHeight: 55))
        XCTAssertFalse(d.shouldShowAccessoryBar(keyboardHeight: 149))
    }

    func testAccessoryShownForSoftwareKeyboard() {
        let d = KeyboardAccessoryDecision()
        XCTAssertTrue(d.shouldShowAccessoryBar(keyboardHeight: 150)) // at threshold
        XCTAssertTrue(d.shouldShowAccessoryBar(keyboardHeight: 336)) // full sw keyboard
    }

    // MARK: InputRouting (IME proxy vs key encoding)

    func testPlainTextRoutesToIMEProxy() {
        let press = InputRouting.KeyPress(characters: "a")
        XCTAssertEqual(InputRouting.route(press), .imeProxy)
    }

    func testCJKTextRoutesToIMEProxy() {
        // A composed CJK character (committed) flows through the IME proxy.
        let press = InputRouting.KeyPress(characters: "日")
        XCTAssertEqual(InputRouting.route(press), .imeProxy)
    }

    func testControlComboRoutesToKeyEncoding() {
        let press = InputRouting.KeyPress(characters: "\u{03}", charactersIgnoringModifiers: "c", control: true)
        XCTAssertEqual(InputRouting.route(press), .keyEncoding)
    }

    func testAltComboRoutesToKeyEncoding() {
        let press = InputRouting.KeyPress(characters: "∫", charactersIgnoringModifiers: "b", option: true)
        XCTAssertEqual(InputRouting.route(press), .keyEncoding)
    }

    func testSpecialKeyRoutesToKeyEncoding() {
        let esc = InputRouting.KeyPress(characters: "", isSpecial: true)
        XCTAssertEqual(InputRouting.route(esc), .keyEncoding)
        XCTAssertTrue(InputRouting.routesToKeyEncoding(esc))
    }

    func testCommandComboRoutesToKeyEncoding() {
        // Command-combos are app shortcuts, not IME text.
        let press = InputRouting.KeyPress(characters: "c", command: true)
        XCTAssertEqual(InputRouting.route(press), .keyEncoding)
    }

    // MARK: KeyEncoding — the platform-agnostic terminal byte mapping (the headless-testable core of
    // the iOS key path; the UIKit `TerminalInputResponderView` forwards to it). R12 #3 / #5 / #6.

    // #3 — Ctrl maps the full C0 control range, not just letters.

    func testControlCodeMapsLetters() {
        XCTAssertEqual(KeyEncoding.controlCode(for: "a"), [0x01])
        XCTAssertEqual(KeyEncoding.controlCode(for: "c"), [0x03])
        XCTAssertEqual(KeyEncoding.controlCode(for: "C"), [0x03])  // case-insensitive
        XCTAssertEqual(KeyEncoding.controlCode(for: "z"), [0x1A])
    }

    func testControlCodeMapsC0SymbolRange() {
        XCTAssertEqual(KeyEncoding.controlCode(for: "["), [0x1B])   // Ctrl-[ = ESC (the headline fix)
        XCTAssertEqual(KeyEncoding.controlCode(for: "\\"), [0x1C])
        XCTAssertEqual(KeyEncoding.controlCode(for: "]"), [0x1D])
        XCTAssertEqual(KeyEncoding.controlCode(for: "^"), [0x1E])
        XCTAssertEqual(KeyEncoding.controlCode(for: "_"), [0x1F])
        XCTAssertEqual(KeyEncoding.controlCode(for: "@"), [0x00])
        XCTAssertEqual(KeyEncoding.controlCode(for: " "), [0x00])   // Ctrl-Space = NUL
        XCTAssertEqual(KeyEncoding.controlCode(for: "?"), [0x7F])   // Ctrl-? = DEL
    }

    func testEncodeCtrlBracketSendsESC() {
        // The full encode path: Ctrl+[ (charactersIgnoringModifiers "[", not a special key) → ESC.
        let press = InputRouting.KeyPress(
            characters: "[", charactersIgnoringModifiers: "[", control: true, isSpecial: false)
        XCTAssertEqual(KeyEncoding.encode(press), [0x1B])
    }

    // #5 — Option + special key applies the xterm meta/ESC prefix (was dropped → bare key).

    func testOptionBackspaceEmitsMetaDEL() {
        let press = InputRouting.KeyPress(characters: "\u{7F}", option: true, isSpecial: true)
        XCTAssertEqual(KeyEncoding.encode(press), [0x1B, 0x7F])    // ESC + DEL = delete-previous-word
    }

    func testPlainBackspaceEmitsBareDEL() {
        let press = InputRouting.KeyPress(characters: "\u{7F}", isSpecial: true)
        XCTAssertEqual(KeyEncoding.encode(press), [0x7F])          // non-regression of the plain path
    }

    func testOptionReturnEmitsMetaCR() {
        let press = InputRouting.KeyPress(characters: "\r", option: true, isSpecial: true)
        XCTAssertEqual(KeyEncoding.encode(press), [0x1B, 0x0D])
    }

    // #6 — Shift+Tab is back-tab (CBT, ESC [ Z); plain Tab stays forward TAB.

    func testShiftTabEncodesBackTab() {
        let press = InputRouting.KeyPress(characters: "\t", shift: true, isSpecial: true)
        XCTAssertEqual(KeyEncoding.encode(press), [0x1B, 0x5B, 0x5A])
    }

    func testPlainTabStillForwardTab() {
        let press = InputRouting.KeyPress(characters: "\t", isSpecial: true)
        XCTAssertEqual(KeyEncoding.encode(press), [0x09])
    }

    // Regression guards on the letter / meta / command / arrow-injection paths.

    func testEncodeAltLetterMetaPrefix() {
        let press = InputRouting.KeyPress(characters: "∫", charactersIgnoringModifiers: "b", option: true)
        XCTAssertEqual(KeyEncoding.encode(press), [0x1B, 0x62])    // ESC b
    }

    func testEncodeCommandComboSendsNothing() {
        let press = InputRouting.KeyPress(characters: "c", command: true)
        XCTAssertNil(KeyEncoding.encode(press))
    }

    // R13 #5 — Ctrl+Option+letter keeps the meta/ESC prefix (was dropping Option → bare Ctrl code).

    func testEncodeCtrlOptionLetterMetaControlPrefix() {
        let press = InputRouting.KeyPress(
            characters: "", charactersIgnoringModifiers: "b", control: true, option: true)
        XCTAssertEqual(KeyEncoding.encode(press), [0x1B, 0x02])   // ESC + Ctrl-B (meta + control code)
    }

    func testEncodeCtrlOnlyLetterStillBareControlCode() {
        let press = InputRouting.KeyPress(characters: "", charactersIgnoringModifiers: "c", control: true)
        XCTAssertEqual(KeyEncoding.encode(press), [0x03])         // non-regression: bare Ctrl-C
    }

    // R13 #6 — accessory-bar Ctrl fold for soft-keyboard text (was a dead no-op → Ctrl-C impossible).

    func testFoldArmedControlFoldsFirstScalar() {
        let folded = KeyEncoding.foldArmedControl("c", armed: true)
        XCTAssertEqual(folded?.controlBytes, [0x03])   // Ctrl-C
        XCTAssertEqual(folded?.rest, "")
    }

    func testFoldArmedControlSplitsRest() {
        let folded = KeyEncoding.foldArmedControl("cat", armed: true)
        XCTAssertEqual(folded?.controlBytes, [0x03])   // Ctrl-C folds the first scalar…
        XCTAssertEqual(folded?.rest, "at")             // …the remainder stays plain text
    }

    func testFoldArmedControlNotArmedOrEmptyIsNil() {
        XCTAssertNil(KeyEncoding.foldArmedControl("c", armed: false), "unarmed → pass the text through")
        XCTAssertNil(KeyEncoding.foldArmedControl("", armed: true), "empty commit → nothing to fold")
    }

    func testEncodeArrowFallbackInjected() {
        // The arrow keys are resolved by the iOS layer (UIKit constants) and injected; an empty
        // `characters` special falls through to `arrowFallback`, then takes the Option meta prefix.
        let up = InputRouting.KeyPress(characters: "", charactersIgnoringModifiers: "UP", isSpecial: true)
        let fallback: (InputRouting.KeyPress) -> [UInt8]? = {
            $0.charactersIgnoringModifiers == "UP" ? [0x1B, 0x5B, 0x41] : nil
        }
        XCTAssertEqual(KeyEncoding.encode(up, arrowFallback: fallback), [0x1B, 0x5B, 0x41])
        let optUp = InputRouting.KeyPress(
            characters: "", charactersIgnoringModifiers: "UP", option: true, isSpecial: true)
        XCTAssertEqual(KeyEncoding.encode(optUp, arrowFallback: fallback), [0x1B, 0x1B, 0x5B, 0x41])
    }
}
