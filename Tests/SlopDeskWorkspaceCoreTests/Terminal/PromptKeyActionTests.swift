import SlopDeskWorkspaceCore
import XCTest

/// The phone's editing chords, and the two halves of how a press becomes one.
///
/// The Mac needs neither half: AppKit's key-binding table names every chord in this suite and
/// delivers it as a selector, so that view maps SELECTORS and no table of its own. UIKit has no
/// counterpart, so the phone NAMES the key here — `PhoneKey.promptKey(_:)`, the USB HID keyboard page
/// and nothing framework-shaped — and asks Rust which verb it is, through
/// `slopdesk_prompt_key_action`. `docs/68` §10's split exactly: the naming is the view's, the decision
/// is Rust's.
///
/// ⚠️ WHAT IS PINNED HERE IS THE CROSSING, NOT THE TABLE. Every chord's meaning is decided in
/// `slopdesk_terminal::prompt::keys` and tested exhaustively there against the same cases; a second
/// exhaustive suite on this side would be the cross-language mirror the one-implementation rule
/// forbids. These assertions ask something the Rust tests cannot: that the enum a caller writes
/// arrives at the door as the key the resolver saw, and comes back as the verb it answered.
final class PromptKeyActionTests: XCTestCase {
    // The USB HID keyboard page's own numbers. Named rather than inlined for the same reason
    // ``PhoneKeyTests`` names them: this suite runs on the macOS runner, where `UIKeyboardHIDUsage`
    // does not exist and the usages are a standard rather than a framework's.
    private enum HID {
        static let returnKey: UInt16 = 40
        static let escape: UInt16 = 41
        static let backspace: UInt16 = 42
        static let tab: UInt16 = 43
        static let a: UInt16 = 4
        static let home: UInt16 = 74
        static let forwardDelete: UInt16 = 76
        static let end: UInt16 = 77
        static let pageUp: UInt16 = 75
        static let pageDown: UInt16 = 78
        static let right: UInt16 = 79
        static let left: UInt16 = 80
        static let down: UInt16 = 81
        static let up: UInt16 = 82
        static let keypadEnter: UInt16 = 88
    }

    // MARK: - Naming the key

    func testEveryNamedKeyIsReadOffItsHIDUsage() {
        let expected: [(UInt16, PromptKey)] = [
            (HID.right, .right), (HID.left, .left), (HID.down, .down), (HID.up, .up),
            (HID.home, .home), (HID.end, .end), (HID.pageUp, .pageUp), (HID.pageDown, .pageDown),
            (HID.backspace, .backspace), (HID.forwardDelete, .forwardDelete),
            (HID.tab, .tab), (HID.returnKey, .return), (HID.escape, .escape),
        ]
        for (usage, key) in expected {
            XCTAssertEqual(
                PhoneKey.promptKey(PhoneKey.Press(hidUsage: usage)), key,
                "HID usage \(usage)",
            )
        }
    }

    /// The keypad's ↩ is a SECOND usage for one key, and a prompt that submitted on one and not the
    /// other would be a hardware-keyboard-only bug — the software keyboard only ever sends 40.
    func testTheKeypadEnterSubmitsLikeTheMainReturn() {
        XCTAssertEqual(PhoneKey.promptKey(PhoneKey.Press(hidUsage: HID.keypadEnter)), .return)
    }

    /// A letter is named by its CHARACTER and not by its usage: the chord table is written against
    /// ⌃A, ⌃E, ⌃W and the rest, which are letters, and a usage would fix them to one layout.
    func testALetterIsNamedByItsCharacterAndFoldedToLowercase() {
        XCTAssertEqual(
            PhoneKey.promptKey(PhoneKey.Press(charactersIgnoringModifiers: "a", hidUsage: HID.a)),
            .character(UInt8(ascii: "a")),
        )
        XCTAssertEqual(
            PhoneKey.promptKey(
                PhoneKey.Press(charactersIgnoringModifiers: "A", hidUsage: HID.a, shift: true),
            ),
            .character(UInt8(ascii: "a")),
        )
    }

    /// A press the table has no name for still has to answer something, and `0` is the HID page's own
    /// "no event" — the resolver reads it as a key that names no verb, so the byte goes to the shell.
    func testAKeyWithNoAsciiNameIsTheEmptyCharacter() {
        XCTAssertEqual(
            PhoneKey.promptKey(PhoneKey.Press(charactersIgnoringModifiers: "é")), .character(0),
        )
        XCTAssertEqual(PhoneKey.promptKey(PhoneKey.Press()), .character(0))
    }

    // MARK: - Deciding the verb

    func testTheBareKeysCarryTheirOwnMeaning() {
        XCTAssertEqual(PromptKeyAction.of(.left, bufferEmpty: false), .move(.grapheme(.backward), extend: false))
        XCTAssertEqual(PromptKeyAction.of(.right, bufferEmpty: false), .move(.grapheme(.forward), extend: false))
        XCTAssertEqual(PromptKeyAction.of(.home, bufferEmpty: false), .move(.lineEdge(.backward), extend: false))
        XCTAssertEqual(PromptKeyAction.of(.end, bufferEmpty: false), .move(.lineEdge(.forward), extend: false))
        XCTAssertEqual(PromptKeyAction.of(.backspace, bufferEmpty: false), .delete(.grapheme(.backward)))
        XCTAssertEqual(PromptKeyAction.of(.forwardDelete, bufferEmpty: false), .delete(.grapheme(.forward)))
        XCTAssertEqual(PromptKeyAction.of(.return, bufferEmpty: false), .submit)
        XCTAssertEqual(PromptKeyAction.of(.escape, bufferEmpty: false), .cancel)
        XCTAssertEqual(PromptKeyAction.of(.tab, bufferEmpty: false), .completeForward)
        XCTAssertEqual(PromptKeyAction.of(.tab, shift: true, bufferEmpty: false), .completeBackward)
    }

    /// ⇧ turns a motion into a SELECTION rather than into a second motion, which is the whole of what
    /// the flag means at this prompt and the one thing a marshalling bug could quietly drop: the
    /// motion would still be right and the selection would never appear.
    func testShiftExtendsTheSelectionRatherThanNamingAnotherVerb() {
        XCTAssertEqual(
            PromptKeyAction.of(.left, shift: true, bufferEmpty: false),
            .move(.grapheme(.backward), extend: true),
        )
        XCTAssertEqual(
            PromptKeyAction.of(.right, shift: true, option: true, bufferEmpty: false),
            .move(.word(.forward), extend: true),
        )
    }

    /// The arrows are the shell's history when the line is bare and the editor's caret when ⇧ is held,
    /// so both readings of one key cross the same door.
    func testTheVerticalArrowsWalkHistoryUntilShiftMakesThemMotions() {
        XCTAssertEqual(PromptKeyAction.of(.up, bufferEmpty: false), .historyPrevious)
        XCTAssertEqual(PromptKeyAction.of(.down, bufferEmpty: false), .historyNext)
        XCTAssertEqual(
            PromptKeyAction.of(.up, shift: true, bufferEmpty: false),
            .move(.line(.backward), extend: true),
        )
    }

    /// PageUp reads the SCROLLBACK, which the editor does not own — the one verb here that leaves the
    /// prompt entirely and the reason ``TerminalSurfaceHosting/scrollPages(_:)`` is on the seam.
    func testThePageKeysScrollTheViewportAndNotTheLine() {
        XCTAssertEqual(PromptKeyAction.of(.pageUp, bufferEmpty: false), .scrollPages(-1))
        XCTAssertEqual(PromptKeyAction.of(.pageDown, bufferEmpty: false), .scrollPages(1))
    }

    /// ⌘ names the four clipboard verbs and the two undo ones. They reach this door and not AppKit's
    /// table, which is the phone's whole reason for having a door.
    func testTheCommandChordsNameTheClipboardAndUndo() {
        let cases: [(UInt8, PromptKeyAction)] = [
            (UInt8(ascii: "a"), .selectAll), (UInt8(ascii: "c"), .copy),
            (UInt8(ascii: "x"), .cut), (UInt8(ascii: "v"), .paste),
            (UInt8(ascii: "z"), .undo),
        ]
        for (letter, action) in cases {
            XCTAssertEqual(
                PromptKeyAction.of(.character(letter), command: true, bufferEmpty: false), action,
                "⌘\(Character(UnicodeScalar(letter)))",
            )
        }
        XCTAssertEqual(
            PromptKeyAction.of(.character(UInt8(ascii: "z")), shift: true, command: true, bufferEmpty: false),
            .redo,
        )
    }

    /// ⌃A/⌃E are readline's, and while the app holds the line they are the app's — the same two
    /// chords the Mac gets from its binding table.
    func testTheReadlineChordsMoveTheCaretWhileTheEditorHoldsTheLine() {
        XCTAssertEqual(
            PromptKeyAction.of(.character(UInt8(ascii: "a")), control: true, bufferEmpty: false),
            .move(.lineEdge(.backward), extend: false),
        )
        XCTAssertEqual(
            PromptKeyAction.of(.character(UInt8(ascii: "w")), control: true, bufferEmpty: false),
            .delete(.word(.backward)),
        )
        XCTAssertEqual(
            PromptKeyAction.of(.character(UInt8(ascii: "r")), control: true, bufferEmpty: false),
            .search,
        )
    }

    /// ⌃C and ⌃D are the SIGNAL and the EOF, and neither is the editor's — they go to the shell as
    /// bytes. ⌃D says so twice over: it forwards on an empty line and clears the line first on a full
    /// one, which is the only verb here that does two things.
    func testTheSignalChordsLeaveTheEditorAndReachTheShell() {
        XCTAssertEqual(
            PromptKeyAction.of(.character(UInt8(ascii: "c")), control: true, bufferEmpty: false),
            .forwardAndClear,
        )
        XCTAssertEqual(
            PromptKeyAction.of(.character(UInt8(ascii: "d")), control: true, bufferEmpty: true),
            .forward,
        )
        XCTAssertEqual(
            PromptKeyAction.of(.character(UInt8(ascii: "d")), control: true, bufferEmpty: false),
            .delete(.grapheme(.forward)),
        )
    }

    /// A press the resolver has no verb for answers `.none`, and the caller's contract is that `.none`
    /// means "not mine" — the byte goes on to the encoder. A door that answered a verb here would
    /// swallow ordinary typing.
    func testAnUnclaimedPressNamesNoVerbAtAll() {
        XCTAssertEqual(PromptKeyAction.of(.character(0), bufferEmpty: false), .none)
        XCTAssertEqual(PromptKeyAction.of(.character(UInt8(ascii: "q")), bufferEmpty: false), .none)
    }
}
