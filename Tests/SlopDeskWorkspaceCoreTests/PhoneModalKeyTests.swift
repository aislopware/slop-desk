import XCTest
@testable import SlopDeskWorkspaceCore

/// The phone's HARDWARE-keyboard road into Copy Mode and Hint Mode.
///
/// Both modes were already drawn on the phone — `TerminalLeafView` mounts the vi pill and the key-hint
/// bar, and both bindings are `Platform::Both` in `rust/slopdesk-workspace/src/binding_rows.rs` — while
/// the only adapters that could turn a press into the modes' abstract keys took an `NSEvent`. The mode
/// engaged, said so, and swallowed everything. What is pinned here is the peer adapter and the seam the
/// responder offers a press through, on the macOS runner, which is the whole point of both being
/// un-gated: an adapter only the iOS triple compiles is an adapter nothing here can reach.
@MainActor
final class PhoneModalKeyTests: XCTestCase {
    // Usages as numbers rather than through `UIKeyboardHIDUsage`, because this suite runs on the macOS
    // runner where UIKit does not exist. They are the USB HID keyboard page's, and
    // `slopdesk_workspace::phone_key` pins each against the key it names — the same reason
    // ``PhoneKeyTests`` spells its own.
    private enum HID {
        static let escape: UInt16 = 41
        static let returnKey: UInt16 = 40
        static let keypadEnter: UInt16 = 88
        static let backspace: UInt16 = 42
        static let tab: UInt16 = 43
        static let up: UInt16 = 82
        static let down: UInt16 = 81
        static let left: UInt16 = 80
        static let right: UInt16 = 79
    }

    private func makeModel() -> (TerminalViewModel, RecordingSurfaceActions) {
        let recorder = RecordingSurfaceActions()
        return (TerminalViewModel(surface: recorder), recorder)
    }

    // MARK: The adapter

    func testTheSixModalKeysCrossAsThemselves() {
        XCTAssertEqual(TerminalViewModel.makeCopyModeKey(PhoneKey.Press(hidUsage: HID.escape)), .escape)
        XCTAssertEqual(TerminalViewModel.makeCopyModeKey(PhoneKey.Press(hidUsage: HID.returnKey)), .enter)
        XCTAssertEqual(
            TerminalViewModel.makeCopyModeKey(PhoneKey.Press(hidUsage: HID.keypadEnter)), .enter,
            "the keypad's Enter is the same intent, and the PTY has one byte for it",
        )
        XCTAssertEqual(TerminalViewModel.makeCopyModeKey(PhoneKey.Press(hidUsage: HID.up)), .up)
        XCTAssertEqual(TerminalViewModel.makeCopyModeKey(PhoneKey.Press(hidUsage: HID.down)), .down)
        XCTAssertEqual(TerminalViewModel.makeCopyModeKey(PhoneKey.Press(hidUsage: HID.left)), .left)
        XCTAssertEqual(TerminalViewModel.makeCopyModeKey(PhoneKey.Press(hidUsage: HID.right)), .right)
    }

    /// Everything else collapses to a `.char` carrying the LAYOUT base plus ⌃/⇧ — the same answer the
    /// Mac's `NSEvent` adapter ends on. `charactersIgnoringModifiers` is what makes `⌃d` read as `d`
    /// rather than as U+0004, which is what copy mode's half-page key is keyed by.
    func testEveryOtherPressCollapsesToItsCharacter() {
        XCTAssertEqual(
            TerminalViewModel.makeCopyModeKey(PhoneKey.Press(charactersIgnoringModifiers: "d", control: true)),
            .char("d", control: true, shift: false),
        )
        XCTAssertEqual(
            TerminalViewModel.makeCopyModeKey(PhoneKey.Press(charactersIgnoringModifiers: "G", shift: true)),
            .char("G", control: false, shift: true),
        )
        XCTAssertEqual(
            TerminalViewModel.makeCopyModeKey(PhoneKey.Press(hidUsage: HID.tab)),
            .char("\u{0}", control: false, shift: false),
            "a special key no mode binds is swallowed by the dispatch's default, not aliased onto one",
        )
    }

    func testHintModeReadsEscapeAndBackspaceByKeyAndTheRestByCharacter() {
        XCTAssertEqual(TerminalViewModel.makeHintKey(PhoneKey.Press(hidUsage: HID.escape)), .escape)
        XCTAssertEqual(TerminalViewModel.makeHintKey(PhoneKey.Press(hidUsage: HID.backspace)), .delete)
        XCTAssertEqual(
            TerminalViewModel.makeHintKey(PhoneKey.Press(charactersIgnoringModifiers: "a")), .character("a"),
        )
    }

    // MARK: The seam the responder offers a press through

    func testAModeIsNotArmedUntilItIsEntered() {
        let (model, rec) = makeModel()
        XCTAssertFalse(model.takesModalKeys)
        XCTAssertFalse(
            model.takeModalKey(PhoneKey.Press(charactersIgnoringModifiers: "j")),
            "with no mode up, `j` is typing and belongs to the text path",
        )
        XCTAssertEqual(rec.actions, [])
    }

    /// The defect this file exists for: in copy mode a bare `j` is a MOTION. It is also exactly the
    /// press `PhoneKey.route` sends to the text-input proxy, which is why the responder has to ask the
    /// mode before it asks the router.
    func testCopyModeTakesTheBareLettersTheTextPathWouldHaveEaten() {
        let (model, rec) = makeModel()
        model.enterCopyMode()
        XCTAssertTrue(model.takesModalKeys)
        XCTAssertEqual(
            PhoneKey.route(PhoneKey.Press(charactersIgnoringModifiers: "j")), .imeProxy,
            "the router still says proxy — the mode is what overrides it, not a changed rule",
        )
        XCTAssertTrue(model.takeModalKey(PhoneKey.Press(charactersIgnoringModifiers: "j")))
        XCTAssertTrue(model.takeModalKey(PhoneKey.Press(hidUsage: HID.up)))
        XCTAssertEqual(rec.actions, ["scroll_page_lines:1", "scroll_page_lines:-1"])
    }

    func testEscapeLeavesCopyMode() {
        let (model, _) = makeModel()
        model.enterCopyMode()
        XCTAssertTrue(model.takeModalKey(PhoneKey.Press(hidUsage: HID.escape)))
        XCTAssertFalse(model.isCopyMode)
        XCTAssertFalse(model.takesModalKeys)
    }

    /// A ⌘ combination is never a modal key. On macOS the app's own dispatcher intercepts those before
    /// the surface sees them; on iOS every press reaches the responder, so ⌘K in copy mode has to fall
    /// through to the palette rather than resolve as the `k` motion.
    func testACommandCombinationFallsThrough() {
        let (model, rec) = makeModel()
        model.enterCopyMode()
        XCTAssertFalse(
            model.takeModalKey(PhoneKey.Press(charactersIgnoringModifiers: "k", command: true)),
        )
        XCTAssertEqual(rec.actions, [])
        XCTAssertTrue(model.isCopyMode, "and it did not disturb the mode either")
    }

    /// Hint mode can be armed ON TOP of copy mode, so it is asked first and its Esc peels only its own
    /// layer — the ordering `GhosttyTerminalView.keyDown` documents, now spelled once for both halves.
    func testHintModeIsTheTopLayer() {
        let (model, rec) = makeModel()
        model.enterCopyMode()
        model.hintMode = .open
        XCTAssertTrue(model.takeModalKey(PhoneKey.Press(charactersIgnoringModifiers: "j")))
        XCTAssertEqual(rec.actions, [], "the label letter never reached copy mode's motion")
        XCTAssertTrue(model.takeModalKey(PhoneKey.Press(hidUsage: HID.escape)))
        XCTAssertNil(model.hintMode)
        XCTAssertTrue(model.isCopyMode, "Esc peeled the top layer, and only the top layer")
    }

    // MARK: The receipt tells the truth

    /// A yank writes the PASTEBOARD and only then raises the "COPIED" chip. The write used to sit
    /// inside `#if canImport(AppKit)`, which made it an empty closure on the phone while the chip went
    /// up regardless — a receipt for a copy that had reached nothing.
    func testAYankReachesThePasteboardBeforeItReportsOne() {
        let (model, rec) = makeModel()
        rec.scrollbackLines = ["mercury", "venus"]
        model.enterCopyMode()
        model.handleCopyModeKey(.char("y", control: false, shift: false))
        XCTAssertEqual(model.copyReceipt?.lineCount, 2, "the chip says it copied both lines")
        XCTAssertEqual(
            ClientPasteboard.text(), "mercury\nvenus",
            "…and the default write is a REAL one, through the cross-platform door",
        )
    }
}
