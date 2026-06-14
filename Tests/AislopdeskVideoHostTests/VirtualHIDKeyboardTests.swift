#if os(macOS)
import XCTest
@testable import AislopdeskVideoHost

/// Pins the pure virtual-HID keyboard core (the path that types into a SecurityAgent password dialog,
/// which Secure Event Input blocks for synthetic CGEvents): macOS keycode → HID usage mapping, the
/// modifier byte, the 8-byte boot report, and the stateful fold of key down/up events.
final class VirtualHIDKeyboardTests: XCTestCase {
    // MARK: keycode → HID usage

    func testLetterMapping() {
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x00), 0x04, "kVK_ANSI_A → HID a")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x06), 0x1D, "kVK_ANSI_Z → HID z")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x11), 0x17, "kVK_ANSI_T → HID t")
    }

    func testDigitAndSymbolMapping() {
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x12), 0x1E, "1")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x1D), 0x27, "0")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x18), 0x2E, "= +")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x2C), 0x38, "/ ?")
    }

    func testEditAndNavKeys() {
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x24), 0x28, "Return")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x33), 0x2A, "Delete/Backspace")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x31), 0x2C, "Space")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x35), 0x29, "Escape")
        XCTAssertEqual(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0x7C), 0x4F, "Right arrow")
    }

    func testUnmappedKeyReturnsNil() {
        XCTAssertNil(VirtualHIDKeyboard.hidUsage(forVirtualKey: 0xFFFF))
    }

    // MARK: modifier byte

    func testModifierByte() {
        XCTAssertEqual(VirtualHIDKeyboard.modifierByte([]), 0x00)
        XCTAssertEqual(VirtualHIDKeyboard.modifierByte(.shift), 0x02)
        XCTAssertEqual(VirtualHIDKeyboard.modifierByte(.control), 0x01)
        XCTAssertEqual(VirtualHIDKeyboard.modifierByte(.option), 0x04)
        XCTAssertEqual(VirtualHIDKeyboard.modifierByte(.command), 0x08)
        XCTAssertEqual(VirtualHIDKeyboard.modifierByte([.command, .shift]), 0x0A)
        // CapsLock + Fn are NOT modifier-byte bits (case comes via Shift).
        XCTAssertEqual(VirtualHIDKeyboard.modifierByte([.capsLock, .function]), 0x00)
    }

    func testModifierKeyDetection() {
        XCTAssertTrue(VirtualHIDKeyboard.isModifierKey(0x38), "kVK_Shift")
        XCTAssertTrue(VirtualHIDKeyboard.isModifierKey(0x37), "kVK_Command")
        XCTAssertFalse(VirtualHIDKeyboard.isModifierKey(0x00), "a is not a modifier")
    }

    // MARK: boot report

    func testBootReportLayout() {
        XCTAssertEqual(
            VirtualHIDKeyboard.bootReport(modifiers: 0x02, keys: [0x04]),
            [0x02, 0x00, 0x04, 0, 0, 0, 0, 0],
            "shift + 'a' → 'A'",
        )
        XCTAssertEqual(
            VirtualHIDKeyboard.bootReport(modifiers: 0, keys: []),
            [0, 0, 0, 0, 0, 0, 0, 0],
            "empty report",
        )
    }

    func testBootReportSortsKeys() {
        XCTAssertEqual(
            VirtualHIDKeyboard.bootReport(modifiers: 0, keys: [0x10, 0x04, 0x08]),
            [0, 0, 0x04, 0x08, 0x10, 0, 0, 0],
        )
    }

    func testBootReportRollsOverPastSix() {
        let r = VirtualHIDKeyboard.bootReport(modifiers: 0, keys: [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(Array(r[2...]), [0x01, 0x01, 0x01, 0x01, 0x01, 0x01], "ErrorRollOver")
    }

    // MARK: stateful fold (typing "Ab")

    func testTypingShiftedThenUnshifted() {
        var s = HIDKeyboardState()
        // Shift down → modifier byte set, no keys.
        XCTAssertEqual(s.apply(virtualKey: 0x38, down: true, modifiers: .shift), [0x02, 0, 0, 0, 0, 0, 0, 0])
        // 'a' down with shift held → 'A'.
        XCTAssertEqual(s.apply(virtualKey: 0x00, down: true, modifiers: .shift), [0x02, 0, 0x04, 0, 0, 0, 0, 0])
        // 'a' up.
        XCTAssertEqual(s.apply(virtualKey: 0x00, down: false, modifiers: .shift), [0x02, 0, 0, 0, 0, 0, 0, 0])
        // Shift up.
        XCTAssertEqual(s.apply(virtualKey: 0x38, down: false, modifiers: []), [0, 0, 0, 0, 0, 0, 0, 0])
        // 'b' down, no modifiers → 'b'.
        XCTAssertEqual(s.apply(virtualKey: 0x0B, down: true, modifiers: []), [0, 0, 0x05, 0, 0, 0, 0, 0])
        XCTAssertEqual(s.apply(virtualKey: 0x0B, down: false, modifiers: []), [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testTwoKeysHeldConcurrently() {
        var s = HIDKeyboardState()
        _ = s.apply(virtualKey: 0x00, down: true, modifiers: []) // a
        let r = s.apply(virtualKey: 0x0B, down: true, modifiers: []) // + b
        XCTAssertEqual(r, [0, 0, 0x04, 0x05, 0, 0, 0, 0], "both a(0x04) and b(0x05) held")
    }

    func testUnmappedKeyYieldsNoReport() {
        var s = HIDKeyboardState()
        XCTAssertNil(s.apply(virtualKey: 0xFFFF, down: true, modifiers: []))
    }

    func testReleaseAllReportIsZero() {
        XCTAssertEqual(HIDKeyboardState().releaseAllReport(), [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testReleaseAllClearsHeldKeysSoLaterKeysAreNotPhantomReasserted() {
        // releaseAll() must CLEAR the folded press state, not merely return the zero report. Otherwise a
        // key held when the keyboard was released re-appears in the NEXT key's report — a phantom press
        // typed into the next secure (password) field, a key the user never pressed.
        var s = HIDKeyboardState()
        _ = s.apply(virtualKey: 0x00, down: true, modifiers: []) // press 'a' (held, never released)
        XCTAssertEqual(s.releaseAll(), [0, 0, 0, 0, 0, 0, 0, 0], "release ships the all-zero report")
        // Type 'b' next: the report must contain ONLY 'b' (0x05), NOT the previously-held 'a' (0x04).
        let r = s.apply(virtualKey: 0x0B, down: true, modifiers: [])
        XCTAssertEqual(r, [0, 0, 0x05, 0, 0, 0, 0, 0], "the released 'a' is gone — no phantom re-assertion")
    }

    // MARK: backend routing (virtual HID ONLY while secure input is active)

    func testBackendUsesVirtualHIDOnlyWhenSecureAndAvailable() {
        // The whole point of the conditional routing: HID only when a secure field is up.
        XCTAssertEqual(InputInjector.keyboardBackend(virtualHIDAvailable: true, secureInputActive: true), .virtualHID)
        XCTAssertEqual(InputInjector.keyboardBackend(virtualHIDAvailable: true, secureInputActive: false), .cgEvent)
    }

    func testBackendFallsBackToCGEventWhenHIDUnavailable() {
        // No bridge/virtual keyboard configured → always CGEvent, even inside a secure field.
        XCTAssertEqual(InputInjector.keyboardBackend(virtualHIDAvailable: false, secureInputActive: true), .cgEvent)
        XCTAssertEqual(InputInjector.keyboardBackend(virtualHIDAvailable: false, secureInputActive: false), .cgEvent)
    }
}
#endif
