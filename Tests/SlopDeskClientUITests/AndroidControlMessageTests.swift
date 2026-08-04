// AndroidControlMessageTests — every byte the panel sends upstream.
//
// `scrcpy` publishes no wire specification; its own documentation says the control protocol is
// defined by the unit tests on both sides. This file is our half of that. The layouts are transcribed
// from `app/src/control_msg.c` at v4.1, so a version bump that reorders a field has to fail HERE
// rather than as a device that responds to taps in the wrong place — a failure nobody would attribute
// to a protocol change.
//
// The one-way invariant is pinned as hard as the layouts: `SET_CLIPBOARD` must carry sequence zero,
// because a non-zero sequence makes the device write a reply into the byte stream the client is
// decoding as H.264.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class AndroidControlMessageTests: XCTestCase {
    // MARK: Touch — the panel's whole pointer path

    func testATouchIsThirtyTwoBytesInTheServersOrder() {
        let message = AndroidControlMessage.touch(
            action: .down, x: 0x0102_0304, y: -2, width: 0x0506, height: 0x0708,
            pressure: 1, actionButton: .primary, buttons: .primary,
        )
        XCTAssertEqual(message.count, 32)
        XCTAssertEqual([UInt8](message), [
            2, // INJECT_TOUCH_EVENT
            0, // ACTION_DOWN
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, // SC_POINTER_ID_GENERIC_FINGER
            0x01, 0x02, 0x03, 0x04, // x
            0xFF, 0xFF, 0xFF, 0xFE, // y — signed, because a drag legitimately leaves the frame
            0x05, 0x06, // width
            0x07, 0x08, // height
            0xFF, 0xFF, // pressure 1.0 as u16fp
            0x00, 0x00, 0x00, 0x01, // action button
            0x00, 0x00, 0x00, 0x01, // buttons
        ])
    }

    func testThePanelInjectsFingersRatherThanAMouse() {
        // Android's gesture recognisers, its scrollers and its fling physics are all built for touch,
        // and a mouse pointer id makes a drag arrive as a hover in views that tell them apart.
        XCTAssertEqual(AndroidControlMessage.fingerPointerID, UInt64.max - 1)
        XCTAssertEqual(AndroidControlMessage.virtualFingerPointerID, UInt64.max - 2)
    }

    func testEveryMotionActionKeepsThePlatformsNumber() {
        XCTAssertEqual(AndroidMotionAction.down.rawValue, 0)
        XCTAssertEqual(AndroidMotionAction.up.rawValue, 1)
        XCTAssertEqual(AndroidMotionAction.move.rawValue, 2)
        XCTAssertEqual(AndroidMotionAction.cancel.rawValue, 3)
        // 4 is OUTSIDE, which the panel never sends — 5 and 6 are the pinch's second contact.
        XCTAssertEqual(AndroidMotionAction.pointerDown.rawValue, 5)
        XCTAssertEqual(AndroidMotionAction.pointerUp.rawValue, 6)
    }

    // MARK: Keys

    func testAKeycodeIsFourteenBytes() {
        let message = AndroidControlMessage.key(
            action: .up, keycode: .appSwitch, repeatCount: 1, metaState: [.alt, .meta],
        )
        XCTAssertEqual(message.count, 14)
        XCTAssertEqual([UInt8](message), [
            0, // INJECT_KEYCODE
            1, // ACTION_UP
            0x00, 0x00, 0x00, 0xBB, // KEYCODE_APP_SWITCH = 187
            0x00, 0x00, 0x00, 0x01, // repeat
            0x00, 0x01, 0x00, 0x02, // META_ALT_ON | META_META_ON
        ])
    }

    func testAToolbarPressIsADownAndAnUp() {
        let messages = AndroidControlMessage.keyPress(.home)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0][1], AndroidKeyAction.down.rawValue)
        XCTAssertEqual(messages[1][1], AndroidKeyAction.up.rawValue)
        XCTAssertEqual(messages[0][5], 3) // KEYCODE_HOME
    }

    func testBackTravelsAsBackOrScreenOnRatherThanAsAKeycode() {
        // On a sleeping device the same press wakes it, which is what the hardware key does and what
        // anyone pressing the toolbar's Back means.
        let messages = AndroidControlMessage.pressBack()
        XCTAssertEqual(messages, [Data([4, 0]), Data([4, 1])])
    }

    // MARK: Text

    func testTextIsLengthPrefixedUtf8() {
        XCTAssertEqual(
            AndroidControlMessage.text("hi"), Data([1, 0, 0, 0, 2]) + Data("hi".utf8),
        )
    }

    func testAnEmptyStringProducesNoMessageAtAll() {
        XCTAssertNil(AndroidControlMessage.text(""))
        XCTAssertNil(AndroidControlMessage.setClipboard("", paste: true))
        XCTAssertNil(AndroidControlMessage.startApp(""))
    }

    func testTruncationNeverSplitsACharacter() {
        // Cutting a multi-byte scalar in half sends the device a byte sequence it decodes as a
        // replacement character — typing an emoji would silently corrupt the field.
        let emoji = String(repeating: "😀", count: 4) // 4 bytes each
        let truncated = AndroidControlMessage.truncateUTF8(emoji, toByteCount: 10)
        XCTAssertEqual(truncated.count, 8)
        XCTAssertEqual(String(bytes: truncated, encoding: .utf8), "😀😀")
    }

    func testTextIsCutAtTheServersOwnCeiling() {
        let long = String(repeating: "a", count: 400)
        let message = try? XCTUnwrap(AndroidControlMessage.text(long))
        XCTAssertEqual(message?.count, 5 + 300)
    }

    // MARK: The one-way invariant

    func testSetClipboardAlwaysAsksForNoAcknowledgement() {
        // THE load-bearing assertion in this file. A non-zero sequence asks the device to reply, and
        // a device→client message on this connection lands in the middle of the video stream.
        let message = try? XCTUnwrap(AndroidControlMessage.setClipboard("x", paste: true))
        XCTAssertEqual([UInt8](message?.prefix(9) ?? Data()), [9, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual([UInt8](message?.suffix(6) ?? Data()), [1, 0, 0, 0, 1, UInt8(ascii: "x")])
    }

    func testGetClipboardAndUhidHaveNoEncoderAtAll() {
        // Not a gap: the message types between `SET_CLIPBOARD` and `OPEN_HARD_KEYBOARD_SETTINGS` are
        // the ones with device replies, and leaving them unencodable is what keeps a single
        // full-duplex connection sound. This pins the numbering that makes the omission visible.
        XCTAssertEqual(AndroidControlMessage.collapsePanels, 7)
        XCTAssertEqual(AndroidControlMessage.setClipboard, 9) // 8 = GET_CLIPBOARD, skipped
        XCTAssertEqual(AndroidControlMessage.rotateDevice, 11) // 12…14 = UHID_*, skipped
        XCTAssertEqual(AndroidControlMessage.openHardKeyboardSettings, 15)
        XCTAssertEqual(AndroidControlMessage.resetVideo, 17)
    }

    // MARK: The small messages

    func testDisplayPowerIsTwoBytes() {
        XCTAssertEqual(AndroidControlMessage.displayPower(on: false), Data([10, 0]))
        XCTAssertEqual(AndroidControlMessage.displayPower(on: true), Data([10, 1]))
    }

    func testABodilessMessageIsItsTypeAlone() {
        XCTAssertEqual(
            AndroidControlMessage.simple(AndroidControlMessage.rotateDevice), Data([11]),
        )
    }

    func testStartAppTakesAOneByteLengthAndNotFour() {
        let message = try? XCTUnwrap(AndroidControlMessage.startApp("com.x"))
        XCTAssertEqual([UInt8](message?.prefix(2) ?? Data()), [16, 5])
    }

    // MARK: Fixed point (`sc_float_to_*fp`)

    func testUnsignedFixedPointSaturatesRatherThanWrapping() {
        XCTAssertEqual(AndroidControlMessage.unsignedFixedPoint(0), 0)
        XCTAssertEqual(AndroidControlMessage.unsignedFixedPoint(0.5), 0x8000)
        XCTAssertEqual(AndroidControlMessage.unsignedFixedPoint(1), 0xFFFF)
        XCTAssertEqual(AndroidControlMessage.unsignedFixedPoint(4), 0xFFFF)
        XCTAssertEqual(AndroidControlMessage.unsignedFixedPoint(-1), 0)
    }

    func testSignedFixedPointSaturatesAtBothEnds() {
        XCTAssertEqual(AndroidControlMessage.signedFixedPoint(0), 0)
        XCTAssertEqual(AndroidControlMessage.signedFixedPoint(0.5), 0x4000)
        XCTAssertEqual(AndroidControlMessage.signedFixedPoint(1), 0x7FFF)
        XCTAssertEqual(AndroidControlMessage.signedFixedPoint(-1), -0x8000)
        XCTAssertEqual(AndroidControlMessage.signedFixedPoint(-9), -0x8000)
    }

    func testAScrollEventIsTwentyOneBytesAndCarriesNotchesOverSixteen() {
        // The wire field is [-1, 1]; the protocol's own scale is [-16, 16] notches, so one notch is
        // 1/16 and a value that skipped the division would saturate on a single click.
        let message = AndroidControlMessage.scroll(
            x: 1, y: 2, width: 3, height: 4, horizontal: 0, vertical: 1,
        )
        XCTAssertEqual(message.count, 21)
        XCTAssertEqual([UInt8](message.suffix(8)), [
            0x00, 0x00, // horizontal
            0x08, 0x00, // vertical: 1/16 of full scale
            0x00, 0x00, 0x00, 0x00, // buttons
        ])
    }
}
#endif
