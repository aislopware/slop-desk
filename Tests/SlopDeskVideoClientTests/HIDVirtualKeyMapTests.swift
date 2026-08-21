import XCTest
@testable import SlopDeskVideoClient

/// The DOOR is reached, and the one thing marshalling can get wrong on the way back.
///
/// The table — every letter, digit, function key, keypad key and both sides of every modifier, plus
/// the collision sweep — is `slopdesk_workspace::hid_virtual_key`, tested there. What can only be
/// checked from this side is the `Option`: `kVK_ANSI_A` is `0`, so a face that read the keycode
/// without its flag would answer "the letter a" for every key macOS has no equivalent for.
final class HIDVirtualKeyMapTests: XCTestCase {
    func testTheAbsentKeyArrivesAsNilAndNotAsKeycodeZero() {
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x04), 0, "a → kVK_ANSI_A, which IS zero")
        XCTAssertNil(HIDVirtualKeyMap.virtualKey(hidUsage: 0x49), "insert has no ANSI keycode")
        XCTAssertNil(HIDVirtualKeyMap.virtualKey(hidUsage: 0xFFFF), "off the keyboard page entirely")
    }

    func testTheTableAndTheLatchPredicateAnswer() {
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x27), 29, "the HID page puts zero LAST")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0xE7), 54, "right command")
        XCTAssertTrue(HIDVirtualKeyMap.isModifier(hidUsage: 0x39), "caps lock")
        XCTAssertFalse(HIDVirtualKeyMap.isModifier(hidUsage: 0x04), "a is not a modifier")
    }
}
