import XCTest
@testable import SlopDeskWorkspaceCore

/// The phone key path's MARSHALLING.
///
/// Every rule these exercise — the C0 fold, the arrows' introducer, the meta prefix, the accessory
/// threshold, the floating cursor's quantisation — is `slopdesk_workspace::phone_key`, and is tested
/// exhaustively there. What is pinned here is the crossing: that the two strings and the flag word
/// reach the door describing the press the responder actually saw, that a length of zero is read as
/// "sends nothing" rather than as an empty array, and that the floating cursor's remainder survives
/// a round trip through the boundary — which is the one piece of state on the near side and
/// therefore the one thing a marshalling bug could silently drop.
final class PhoneKeyTests: XCTestCase {
    // Usages spelled as numbers rather than through `UIKeyboardHIDUsage`, because this suite runs on
    // the macOS test runner where UIKit does not exist. They are the USB HID keyboard page's, and
    // `slopdesk_workspace::phone_key` pins each one against the key it names.
    private enum HID {
        static let escape: UInt16 = 41
        static let tab: UInt16 = 43
        static let space: UInt16 = 44
        static let up: UInt16 = 82
        static let left: UInt16 = 80
        static let home: UInt16 = 74
        static let pageUp: UInt16 = 75
        static let f5: UInt16 = 62
        static let backspace: UInt16 = 42
        static let returnKey: UInt16 = 40
    }

    // MARK: The two paths

    func testTypingGoesToTheProxyAndModifiersToTheEncoder() {
        XCTAssertEqual(PhoneKey.route(PhoneKey.Press(charactersIgnoringModifiers: "a")), .imeProxy)
        // A CJK commit is the reason the split exists at all.
        XCTAssertEqual(PhoneKey.route(PhoneKey.Press(charactersIgnoringModifiers: "日")), .imeProxy)
        XCTAssertEqual(
            PhoneKey.route(PhoneKey.Press(charactersIgnoringModifiers: " ", hidUsage: HID.space)),
            .imeProxy,
            "the space bar types",
        )
        XCTAssertEqual(
            PhoneKey.route(PhoneKey.Press(charactersIgnoringModifiers: "c", control: true)),
            .keyEncoding,
        )
        XCTAssertEqual(
            PhoneKey.route(PhoneKey.Press(charactersIgnoringModifiers: "b", option: true)),
            .keyEncoding,
        )
        XCTAssertEqual(
            PhoneKey.route(PhoneKey.Press(charactersIgnoringModifiers: "c", command: true)),
            .keyEncoding,
        )
        let esc = PhoneKey.Press(hidUsage: HID.escape)
        XCTAssertEqual(PhoneKey.route(esc), .keyEncoding)
        XCTAssertTrue(PhoneKey.routesToKeyEncoding(esc))
    }

    // MARK: The bytes

    /// The usage and the base string both reach the door, and each answers its own question: the
    /// usage names the key, the string is only ever the layout's base for a fold or a meta prefix.
    func testTheUsageAndTheBaseBothReachTheDoor() {
        let altB = PhoneKey.Press(charactersIgnoringModifiers: "b", option: true)
        XCTAssertEqual(PhoneKey.encode(altB), [0x1B, 0x62], "⌥b takes the base letter, not the layout's ∫")
        let ctrlBracket = PhoneKey.Press(charactersIgnoringModifiers: "[", control: true)
        XCTAssertEqual(PhoneKey.encode(ctrlBracket), [0x1B], "⌃[ is ESC")
        let shiftTab = PhoneKey.Press(hidUsage: HID.tab, shift: true)
        XCTAssertEqual(PhoneKey.encode(shiftTab), [0x1B, 0x5B, 0x5A], "⇧ is the only back-tab discriminator")
    }

    /// The nav block, which a press keyed by its committed characters could not carry at all
    /// (`docs/29` #7) — these keys commit nothing a table can match.
    func testTheNavBlockCrossesOnItsUsageAlone() {
        XCTAssertEqual(PhoneKey.encode(PhoneKey.Press(hidUsage: HID.home)), [0x1B, 0x5B, 0x48])
        XCTAssertEqual(PhoneKey.encode(PhoneKey.Press(hidUsage: HID.pageUp)), [0x1B, 0x5B, 0x35, 0x7E])
        XCTAssertEqual(
            PhoneKey.encode(PhoneKey.Press(hidUsage: HID.f5)),
            [0x1B, 0x5B, 0x31, 0x35, 0x7E],
        )
    }

    /// The live cursor-key mode is threaded per call, not remembered, and it steers the cursor block
    /// only.
    func testTheCursorModeIsThreadedThrough() {
        let up = PhoneKey.Press(hidUsage: HID.up)
        XCTAssertEqual(PhoneKey.encode(up), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(PhoneKey.encode(up, applicationCursorKeys: true), [0x1B, 0x4F, 0x41])
        XCTAssertEqual(
            PhoneKey.encode(PhoneKey.Press(hidUsage: HID.home), applicationCursorKeys: true),
            [0x1B, 0x4F, 0x48],
        )
        let esc = PhoneKey.Press(hidUsage: HID.escape)
        XCTAssertEqual(PhoneKey.encode(esc, applicationCursorKeys: true), [0x1B], "DECCKM steers only the cursor block")
    }

    /// A press that sends nothing is `nil`, not an empty array — the door's zero length says so, and
    /// a caller writing `[]` to a pane would be writing a keystroke the user never made.
    func testAPressThatSendsNothingIsNil() {
        XCTAssertNil(PhoneKey.encode(PhoneKey.Press(charactersIgnoringModifiers: "c", command: true)))
        XCTAssertNil(
            PhoneKey.encode(PhoneKey.Press(hidUsage: HID.left, command: true)),
            "⌘← is a shortcut that missed, not terminal input",
        )
        XCTAssertNil(PhoneKey.encode(PhoneKey.Press(charactersIgnoringModifiers: "a")), "typing is the proxy's")
        XCTAssertNil(PhoneKey.encode(PhoneKey.Press()))
    }

    /// A base longer than the inline buffer takes the door's retry protocol rather than truncating.
    func testALongBaseRetriesRatherThanTruncating() {
        let long = String(repeating: "é", count: 40) // 80 UTF-8 bytes, well past the inline buffer
        let press = PhoneKey.Press(charactersIgnoringModifiers: long, option: true)
        XCTAssertEqual(PhoneKey.encode(press), [0x1B] + Array(long.utf8))
    }

    // MARK: The accessory bar

    func testTheArmedControlFoldSplitsTheCommit() {
        let folded = PhoneKey.foldArmedControl("cat", armed: true)
        XCTAssertEqual(folded?.controlByte, 0x03)
        XCTAssertEqual(folded?.rest, "at")
        // A multi-byte first scalar: the door reports a byte offset, so the rest must not be sliced
        // by character count.
        XCTAssertEqual(PhoneKey.foldArmedControl("日本", armed: true)?.rest, "本")
        XCTAssertNil(PhoneKey.foldArmedControl("c", armed: false), "unarmed → pass the text through")
        XCTAssertNil(PhoneKey.foldArmedControl("", armed: true), "an empty commit has nothing to fold")
    }

    func testTheBarShowsOnlyForASoftwareKeyboard() {
        let threshold = PhoneKey.softwareKeyboardThreshold
        XCTAssertGreaterThan(threshold, 0)
        XCTAssertFalse(PhoneKey.showsAccessoryBar(keyboardHeight: 0))
        XCTAssertFalse(PhoneKey.showsAccessoryBar(keyboardHeight: threshold - 1))
        XCTAssertTrue(PhoneKey.showsAccessoryBar(keyboardHeight: threshold))
        XCTAssertTrue(PhoneKey.showsAccessoryBar(keyboardHeight: 336))
    }

    /// The bar's plates are synthesized presses, so the same encoder answers them.
    func testTheBarsPlatesAreOrdinaryPresses() {
        XCTAssertEqual(PhoneKey.encode(PhoneKey.Press(hidUsage: HID.escape)), [0x1B])
        XCTAssertEqual(PhoneKey.encode(PhoneKey.Press(hidUsage: HID.tab)), [0x09])
        XCTAssertEqual(PhoneKey.encode(PhoneKey.Press(hidUsage: HID.left)), [0x1B, 0x5B, 0x44])
        XCTAssertEqual(PhoneKey.encode(PhoneKey.Press(hidUsage: HID.backspace)), [0x7F])
        XCTAssertEqual(PhoneKey.encode(PhoneKey.Press(hidUsage: HID.returnKey)), [0x0D])
    }

    // MARK: The floating cursor

    /// The remainder is the whole state, and it crosses out and back on every feed.
    func testTheRemainderSurvivesTheRoundTrip() {
        var cursor = FloatingCursor()
        XCTAssertEqual(cursor.feed(deltaX: 4), [], "under one threshold buys no arrow")
        XCTAssertEqual(cursor.accumulated, 4, accuracy: 1e-9)
        XCTAssertEqual(cursor.feed(deltaX: 2), [0x1B, 0x5B, 0x43], "the carried 4 plus 2 crosses 5")
        XCTAssertEqual(cursor.accumulated, 1, accuracy: 1e-9)
    }

    /// A run arrives as ONE buffer, in the live mode — the caller writes it with a single send.
    func testARunIsOneBuffer() {
        var cursor = FloatingCursor()
        XCTAssertEqual(
            cursor.feed(deltaX: -12, applicationCursorKeys: true),
            [0x1B, 0x4F, 0x44, 0x1B, 0x4F, 0x44],
            "two whole thresholds leftward, SS3 because the TUI set ?1h",
        )
        XCTAssertEqual(cursor.accumulated, -2, accuracy: 1e-9)
    }

    /// A degenerate `UITextInput` point neither wedges the accumulator nor spins the door.
    func testADegenerateDeltaIsDropped() {
        var cursor = FloatingCursor()
        XCTAssertEqual(cursor.feed(deltaX: .nan), [])
        XCTAssertEqual(cursor.feed(deltaX: .infinity), [])
        XCTAssertEqual(cursor.accumulated, 0, accuracy: 1e-9)
        XCTAssertFalse(cursor.feed(deltaX: .greatestFiniteMagnitude).isEmpty, "clamped, not dropped")
    }

    func testResetClearsTheRemainder() {
        var cursor = FloatingCursor()
        _ = cursor.feed(deltaX: 3)
        cursor.reset()
        XCTAssertEqual(cursor.accumulated, 0, accuracy: 1e-9)
        XCTAssertEqual(cursor.feed(deltaX: 3), [], "the 3 that was carried is gone")
    }
}
