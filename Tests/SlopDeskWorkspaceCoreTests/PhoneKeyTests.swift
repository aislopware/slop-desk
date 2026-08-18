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
    // MARK: The two paths

    func testTypingGoesToTheProxyAndModifiersToTheEncoder() {
        XCTAssertEqual(PhoneKey.route(PhoneKey.Press(characters: "a")), .imeProxy)
        // A CJK commit is the reason the split exists at all.
        XCTAssertEqual(PhoneKey.route(PhoneKey.Press(characters: "日")), .imeProxy)
        XCTAssertEqual(
            PhoneKey.route(PhoneKey.Press(characters: "\u{03}", charactersIgnoringModifiers: "c", control: true)),
            .keyEncoding,
        )
        XCTAssertEqual(
            PhoneKey.route(PhoneKey.Press(characters: "∫", charactersIgnoringModifiers: "b", option: true)),
            .keyEncoding,
        )
        XCTAssertEqual(PhoneKey.route(PhoneKey.Press(characters: "c", command: true)), .keyEncoding)
        let esc = PhoneKey.Press(characters: "", isSpecial: true)
        XCTAssertEqual(PhoneKey.route(esc), .keyEncoding)
        XCTAssertTrue(PhoneKey.routesToKeyEncoding(esc))
    }

    // MARK: The bytes

    /// Both strings reach the door: the fold reads `charactersIgnoringModifiers` while the special
    /// tables read `characters`, so a marshaller that sent one string twice would fail exactly here.
    func testBothStringsReachTheDoor() {
        let altB = PhoneKey.Press(characters: "∫", charactersIgnoringModifiers: "b", option: true)
        XCTAssertEqual(PhoneKey.encode(altB), [0x1B, 0x62], "⌥b takes the base letter, not the layout's ∫")
        let ctrlBracket = PhoneKey.Press(characters: "[", charactersIgnoringModifiers: "[", control: true)
        XCTAssertEqual(PhoneKey.encode(ctrlBracket), [0x1B], "⌃[ is ESC")
        let shiftTab = PhoneKey.Press(characters: "\t", shift: true, isSpecial: true)
        XCTAssertEqual(PhoneKey.encode(shiftTab), [0x1B, 0x5B, 0x5A], "⇧ is the only back-tab discriminator")
    }

    /// The live cursor-key mode is threaded per call, not remembered.
    func testTheCursorModeIsThreadedThrough() {
        let up = PhoneKey.Press(characters: "\u{F700}", isSpecial: true)
        XCTAssertEqual(PhoneKey.encode(up), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(PhoneKey.encode(up, applicationCursorKeys: true), [0x1B, 0x4F, 0x41])
        let esc = PhoneKey.Press(characters: "\u{1B}", isSpecial: true)
        XCTAssertEqual(PhoneKey.encode(esc, applicationCursorKeys: true), [0x1B], "DECCKM steers only arrows")
    }

    /// A press that sends nothing is `nil`, not an empty array — the door's zero length says so, and
    /// a caller writing `[]` to a pane would be writing a keystroke the user never made.
    func testAPressThatSendsNothingIsNil() {
        XCTAssertNil(PhoneKey.encode(PhoneKey.Press(characters: "c", command: true)))
        XCTAssertNil(PhoneKey.encode(PhoneKey.Press(characters: "")))
    }

    /// A base longer than the inline buffer takes the door's retry protocol rather than truncating.
    func testALongBaseRetriesRatherThanTruncating() {
        let long = String(repeating: "é", count: 40) // 80 UTF-8 bytes, well past the inline buffer
        let press = PhoneKey.Press(characters: long, charactersIgnoringModifiers: long, option: true)
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

    func testABarePlateArrowFollowsTheMode() {
        XCTAssertEqual(PhoneKey.arrowBytes(rightward: true), [0x1B, 0x5B, 0x43])
        XCTAssertEqual(PhoneKey.arrowBytes(rightward: false), [0x1B, 0x5B, 0x44])
        XCTAssertEqual(PhoneKey.arrowBytes(rightward: false, applicationCursorKeys: true), [0x1B, 0x4F, 0x44])
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
