import XCTest
@testable import SlopDeskVideoClient

/// The iPad hardware keyboard's half of the remote-desktop pane: USB HID usage → macOS virtual keycode.
/// The table is the whole feature — a wrong keycode on a remote desktop is a wrong character typed into
/// someone's editor — and it is pure, so it is checked here rather than on a device.
final class HIDVirtualKeyMapTests: XCTestCase {
    func testLetterLadderMapsBothEnds() {
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x04), 0, "a → kVK_ANSI_A")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x1D), 6, "z → kVK_ANSI_Z")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x16), 1, "s → kVK_ANSI_S")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x0F), 37, "l → kVK_ANSI_L")
    }

    func testDigitLadderPutsZeroLast() {
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x1E), 18, "1 → kVK_ANSI_1")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x26), 25, "9 → kVK_ANSI_9")
        XCTAssertEqual(
            HIDVirtualKeyMap.virtualKey(hidUsage: 0x27), 29,
            "the HID page runs 1…9 then 0 — an off-by-one here types a 9 for every 0",
        )
    }

    func testEditingAndWhitespace() {
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x28), 36, "return")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x29), 53, "escape")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x2A), 51, "backspace")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x2B), 48, "tab")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x2C), 49, "space")
    }

    func testFunctionRowIsNotSequential() {
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x3A), 122, "F1")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x3B), 120, "F2 — kVK's F-keys are out of order")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x3E), 96, "F5")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x45), 111, "F12")
    }

    func testArrowsAndNavigation() {
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x4F), 124, "right")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x50), 123, "left")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x51), 125, "down")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x52), 126, "up")
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x4C), 117, "forward delete")
    }

    func testBothSidesOfEveryModifierAreDistinct() {
        // The host's latch balance counts left and right separately; folding them would leave one side
        // stuck down after a two-handed ⇧.
        let pairs: [(UInt16, UInt16)] = [
            (0xE0, 59), (0xE1, 56), (0xE2, 58), (0xE3, 55),
            (0xE4, 62), (0xE5, 60), (0xE6, 61), (0xE7, 54),
        ]
        for (usage, expected) in pairs {
            XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: usage), expected, "usage \(usage)")
            XCTAssertTrue(HIDVirtualKeyMap.isModifier(hidUsage: usage), "usage \(usage) must latch")
        }
    }

    func testCapsLockIsAModifierButALetterIsNot() {
        XCTAssertEqual(HIDVirtualKeyMap.virtualKey(hidUsage: 0x39), 57, "caps lock")
        XCTAssertTrue(HIDVirtualKeyMap.isModifier(hidUsage: 0x39))
        XCTAssertFalse(HIDVirtualKeyMap.isModifier(hidUsage: 0x04), "a is not a modifier")
        XCTAssertFalse(HIDVirtualKeyMap.isModifier(hidUsage: 0x28), "return is not a modifier")
    }

    func testUnmappedUsagesSendNothing() {
        // A key with no macOS equivalent must return nil so the caller forwards NOTHING and lets the
        // responder chain have it — inventing a keycode types the wrong character on someone's desktop.
        XCTAssertNil(HIDVirtualKeyMap.virtualKey(hidUsage: 0x00), "reserved / no-event")
        XCTAssertNil(HIDVirtualKeyMap.virtualKey(hidUsage: 0x49), "insert has no ANSI keycode")
        XCTAssertNil(HIDVirtualKeyMap.virtualKey(hidUsage: 0x65), "past the mapped range")
        XCTAssertNil(HIDVirtualKeyMap.virtualKey(hidUsage: 0xFFFF), "off the keyboard page entirely")
    }

    func testTheTableHasNoAccidentalCollisions() {
        // Every usage that maps must map somewhere reachable, and the only DELIBERATE duplicate is the
        // non-US `#` sharing the ANSI backslash key. A second collision means a typo in the table.
        var owners: [UInt16: [UInt16]] = [:]
        for usage in UInt16(0)...UInt16(0xE7) {
            guard let keyCode = HIDVirtualKeyMap.virtualKey(hidUsage: usage) else { continue }
            owners[keyCode, default: []].append(usage)
        }
        let collisions = owners.filter { $0.value.count > 1 }
        XCTAssertEqual(collisions.count, 1, "unexpected collisions: \(collisions)")
        XCTAssertEqual(collisions[42].map { Set($0) }, Set([0x31, 0x32]), "\\ and non-US #")
    }
}
