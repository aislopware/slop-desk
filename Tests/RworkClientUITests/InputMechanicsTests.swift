import XCTest
@testable import RworkClientUI

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
}
