import XCTest
@testable import AislopdeskVideoProtocol

/// Round-trip + wire-tolerance for the `focusWindow` control message (type 9) — the
/// client→host "this pane was focused, raise its window" signal that replaced the abandoned
/// no-raise background-injection approach. Like `keepalive`/`bye` it is a single zero-body type
/// byte, and like every control type it is wire-safe in both directions (an old peer that lacks
/// the case hits the decoder's `default` and THROWS `.malformed`, which both consumers
/// catch-and-drop — never a crash).
final class FocusWindowCodecTests: XCTestCase {
    /// encode → decode → .focusWindow, a single type byte (value 9, no body — like `bye`/`keepalive`).
    func testFocusWindowRoundTrip() throws {
        let msg = VideoControlMessage.focusWindow
        let bytes = msg.encode()
        XCTAssertEqual(bytes, Data([9]), "focusWindow is a single type byte (value 9, zero body)")
        XCTAssertEqual(bytes.count, 1)
        XCTAssertEqual(msg.messageType, 9)
        XCTAssertEqual(try VideoControlMessage.decode(bytes), .focusWindow)
    }

    /// Type 9 is the next free byte after windowList (8) and collides with nothing else.
    func testFocusWindowTypeByteIsNextFree() {
        XCTAssertEqual(VideoControlMessage.focusWindow.messageType, 9)
        XCTAssertEqual(VideoControlMessage.listWindows.messageType, 7)
        XCTAssertEqual(VideoControlMessage.windowList([]).messageType, 8)
        XCTAssertEqual(VideoControlMessage.keepalive.messageType, 6)
    }

    /// Adding case 9 perturbs no existing case's wire bytes.
    func testExistingZeroBodyCasesUnperturbed() throws {
        XCTAssertEqual(VideoControlMessage.bye.encode(), Data([3]))
        XCTAssertEqual(VideoControlMessage.keepalive.encode(), Data([6]))
        XCTAssertEqual(VideoControlMessage.listWindows.encode(), Data([7]))
        XCTAssertEqual(try VideoControlMessage.decode(Data([9])), .focusWindow)
    }
}
