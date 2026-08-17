// AndroidControlMessageTests — the MARSHALLING for what the panel sends upstream.
//
// Every byte layout is `rust/slopdesk-androidd/src/control.rs`, and all 18 cases this file used to
// carry were ported there unchanged — including the load-bearing one, that `SET_CLIPBOARD` asks for
// no acknowledgement. Repeating them here would be the cross-language mirror fixture the tree
// forbids: two suites that can only ever agree or be a bug.
//
// What is left is what only exists on THIS side of the door:
//
// - the FIELD ROUTING — a record has seventeen fields and each encoder reads a different subset, so
//   a scalar assigned to the wrong one is a bug the Rust suite cannot see;
// - the kind constants — a Swift function pointed at the wrong encoder;
// - the refusal mapping — `0` becoming `nil` rather than an empty `Data`;
// - the two convenience pairs, which are the encoder called twice.
//
// The one-way invariant is now a TYPE, not an assertion: `AndroidBodilessMessage` has no case for
// `GET_CLIPBOARD` or `UHID_*`, so the test that pinned their numbering has become the fact that
// nothing here can name them. What is still worth asserting is that the four safe ones each reach
// their own type byte.

#if os(macOS)
import Foundation
import XCTest
@testable import SlopDeskClientUI

final class AndroidControlMessageTests: XCTestCase {
    // MARK: Field routing — the record has seventeen fields and each encoder reads a few

    /// Every scalar a touch carries lands in its own place, with no two swapped. Distinct values
    /// throughout, so a crossed assignment cannot pass by coincidence.
    func testATouchRoutesEveryFieldToItsOwnPlace() {
        let message = AndroidControlMessage.touch(
            action: .move, x: 0x0102_0304, y: -2, width: 0x0506, height: 0x0708,
            pressure: 1, actionButton: .secondary, buttons: .tertiary,
        )
        XCTAssertEqual([UInt8](message), [
            2, // INJECT_TOUCH_EVENT
            2, // ACTION_MOVE — the action, not the type
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, // the finger pointer id
            0x01, 0x02, 0x03, 0x04, // x
            0xFF, 0xFF, 0xFF, 0xFE, // y
            0x05, 0x06, // width
            0x07, 0x08, // height
            0xFF, 0xFF, // pressure
            0x00, 0x00, 0x00, 0x02, // action button — SECONDARY
            0x00, 0x00, 0x00, 0x04, // buttons — TERTIARY, and not a copy of the one above
        ])
    }

    /// A key routes its own four, and the keycode and meta-state vocabularies survive the crossing.
    func testAKeyRoutesItsOwnFields() {
        let message = AndroidControlMessage.key(
            action: .up, keycode: .appSwitch, repeatCount: 1, metaState: [.alt, .meta],
        )
        XCTAssertEqual([UInt8](message), [
            0, 1, // INJECT_KEYCODE, ACTION_UP
            0x00, 0x00, 0x00, 0xBB, // KEYCODE_APP_SWITCH = 187
            0x00, 0x00, 0x00, 0x01, // repeat
            0x00, 0x01, 0x00, 0x02, // META_ALT_ON | META_META_ON
        ])
    }

    /// A scroll reads the position and the two float fields, and NOT the touch's pressure slot.
    func testAScrollRoutesItsFloatsAndNotTheTouchesPressure() {
        let message = AndroidControlMessage.scroll(
            x: 1, y: 2, width: 3, height: 4, horizontal: 0, vertical: 1,
        )
        XCTAssertEqual(message.count, 21)
        XCTAssertEqual([UInt8](message.suffix(8)), [
            0x00, 0x00, // horizontal
            0x08, 0x00, // vertical: 1/16 of full scale, so the notch division crossed too
            0x00, 0x00, 0x00, 0x00, // buttons
        ])
    }

    // MARK: The kind constants — each Swift function must reach its own encoder

    func testEachFunctionReachesItsOwnEncoder() {
        XCTAssertEqual(AndroidControlMessage.text("hi")?.first, 1) // INJECT_TEXT
        XCTAssertEqual(AndroidControlMessage.touch(
            action: .down, x: 0, y: 0, width: 1, height: 1,
        ).first, 2) // INJECT_TOUCH_EVENT
        XCTAssertEqual(AndroidControlMessage.scroll(
            x: 0, y: 0, width: 1, height: 1, horizontal: 0, vertical: 0,
        ).first, 3) // INJECT_SCROLL_EVENT
        XCTAssertEqual(AndroidControlMessage.setClipboard("x", paste: false)?.first, 9)
        XCTAssertEqual(AndroidControlMessage.displayPower(on: true).first, 10)
        XCTAssertEqual(AndroidControlMessage.startApp("com.x")?.first, 16)
    }

    /// Each bodiless case reaches its own type byte — the routing a shared `simple` could get wrong.
    func testEachBodilessCaseReachesItsOwnTypeByte() {
        XCTAssertEqual(AndroidControlMessage.simple(.collapsePanels), Data([7]))
        XCTAssertEqual(AndroidControlMessage.simple(.rotateDevice), Data([11]))
        XCTAssertEqual(AndroidControlMessage.simple(.openHardKeyboardSettings), Data([15]))
        XCTAssertEqual(AndroidControlMessage.simple(.resetVideo), Data([17]))
    }

    // MARK: The refusal mapping

    /// A refusal is `nil`, not an empty `Data` a caller would write to the socket as a no-op.
    func testARefusalBecomesNilRatherThanAnEmptyMessage() {
        XCTAssertNil(AndroidControlMessage.text(""))
        XCTAssertNil(AndroidControlMessage.setClipboard("", paste: true))
        XCTAssertNil(AndroidControlMessage.startApp(""))
    }

    /// The body reaches the door as UTF-8 and comes back length-prefixed, cut at the ceiling.
    func testABodyCrossesAndIsCutAtTheServersCeiling() {
        XCTAssertEqual(AndroidControlMessage.text("hi"), Data([1, 0, 0, 0, 2]) + Data("hi".utf8))
        XCTAssertEqual(AndroidControlMessage.text(String(repeating: "a", count: 400))?.count, 5 + 300)
    }

    // MARK: The convenience pairs

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
        XCTAssertEqual(AndroidControlMessage.pressBack(), [Data([4, 0]), Data([4, 1])])
    }

    // MARK: The pointer ids

    func testThePanelInjectsFingersRatherThanAMouse() {
        // Android's gesture recognisers, its scrollers and its fling physics are all built for touch,
        // and a mouse pointer id makes a drag arrive as a hover in views that tell them apart.
        XCTAssertEqual(AndroidControlMessage.fingerPointerID, UInt64.max - 1)
        XCTAssertEqual(AndroidControlMessage.virtualFingerPointerID, UInt64.max - 2)
    }
}
#endif
