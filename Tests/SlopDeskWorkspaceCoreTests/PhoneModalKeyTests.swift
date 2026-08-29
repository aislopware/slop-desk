import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// The phone's HARDWARE-keyboard road into Copy Mode and Hint Mode — and, one rung above them, into the
/// ⌃⇥ pane switcher.
///
/// Both modes were already drawn on the phone — `TerminalLeafView` mounts the vi pill and the key-hint
/// bar, and both bindings are `Platform::Both` in `rust/slopdesk-workspace/src/bindings.rs` — while
/// the only adapters that could turn a press into the modes' abstract keys took an `NSEvent`. The mode
/// engaged, said so, and swallowed everything. What is pinned here is the peer adapter and the seam the
/// responder offers a press through, on the macOS runner, which is the whole point of both being
/// un-gated: an adapter only the iOS triple compiles is an adapter nothing here can reach.
///
/// The switcher half below is the SAME defect one rung up, found the same way. The deleted SwiftUI
/// `PaneSwitcherOverlay` (now ``SlopDeskPhoneUI/PhonePaneSwitcherView``)
/// asserted in its own header that a hardware ⌃⇥ "already works" on an iPad; it resolved to no chord (the
/// registry row is `chord: nil` on purpose), fell to the encoder and typed `0x09`, while the card's Esc,
/// Return and arrows walked past it into the PTY. ``PhoneKey/paneSwitcherKey(_:isOpen:)`` is the rule the
/// responder now asks first, and it is un-gated for exactly the reason the modal adapter is.
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

    // MARK: The ⌃⇥ walk, one rung above the modes

    /// A three-pane workspace, which is the smallest ring where ← and → are visibly different steps.
    private func makeSwitcherStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        store.newTab(kind: .terminal)
        store.newTab(kind: .terminal)
        return store
    }

    private func tab(control: Bool, shift: Bool = false) -> PhoneKey.Press {
        PhoneKey.Press(hidUsage: HID.tab, control: control, shift: shift)
    }

    /// THE DEFECT. ⌃⇥ resolved to nothing in the chord table (`pane.switcher` is `chord: nil` on
    /// purpose), fell through to the encoder and typed a literal Tab into the shell — under a card the
    /// app had already drawn. The encode assertion is the receipt: the bytes are still exactly what the
    /// shell used to get, so what fixes this is the ORDER of the questions, not a changed byte rule.
    func testControlTabOpensTheWalkRatherThanTypingATab() {
        let store = makeSwitcherStore()
        let press = tab(control: true)

        XCTAssertNil(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(.tab, [.control])],
            "the gesture has no table row, which is why the responder has to claim it above the table",
        )
        XCTAssertEqual(
            PhoneKey.encode(press), [0x09],
            "and the encoder below still answers Tab — the fix is the rung, not the byte",
        )

        XCTAssertEqual(
            PhoneKey.paneSwitcherKey(press, isOpen: false), .openOrStep(forward: true),
        )
        XCTAssertTrue(store.takePaneSwitcherKey(press), "the walk took the press")
        XCTAssertNotNil(store.paneSwitcher, "…and the card is up")
    }

    /// ⇧ arrives on the press itself (`UIKey.modifierFlags`), not as a distinct back-tab key, so it is
    /// the only thing that separates the two directions.
    func testShiftOnTheSamePressWalksTheOtherWay() {
        XCTAssertEqual(
            PhoneKey.paneSwitcherKey(tab(control: true, shift: true), isOpen: false),
            .openOrStep(forward: false),
        )
    }

    /// The boundary the Mac's `consumePaneSwitcher` defends, defended identically here: a bare ⇥ is shell
    /// completion and ⇧⇥ is how Claude Code cycles permission modes. Neither carries ⌃, and with the walk
    /// closed neither is ours.
    func testABareTabIsStillTheShellsTab() {
        XCTAssertNil(PhoneKey.paneSwitcherKey(tab(control: false), isOpen: false))
        XCTAssertNil(PhoneKey.paneSwitcherKey(tab(control: false, shift: true), isOpen: false))
        let store = makeSwitcherStore()
        XCTAssertFalse(store.takePaneSwitcherKey(tab(control: false)))
        XCTAssertNil(store.paneSwitcher, "nothing opened")
    }

    /// Esc CANCELS and sends nothing. It reaches this rung at all only because it is asked before the
    /// encoder: Escape is deliberately chord-less (a bare Esc must always reach the TUI), so the chord
    /// table could never have claimed it and `0x1B` went to the shell under an open card.
    func testEscapeCancelsTheWalkAndSendsNothing() {
        let store = makeSwitcherStore()
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: false)
        XCTAssertNotNil(store.paneSwitcher, "precondition — a walk is up")
        let press = PhoneKey.Press(hidUsage: HID.escape)

        XCTAssertNil(PhoneKey.keyChord(for: press), "Escape resolves to no chord, by design")
        XCTAssertEqual(PhoneKey.encode(press), [0x1B], "which is the byte that used to leak")

        XCTAssertEqual(PhoneKey.paneSwitcherKey(press, isOpen: true), .cancel)
        XCTAssertTrue(store.takePaneSwitcherKey(press))
        XCTAssertNil(store.paneSwitcher, "the walk is abandoned")
    }

    /// Return COMMITS and sends nothing — the unarmed walk's only key commit, since a phone has no ⌃
    /// release to end the gesture on.
    func testReturnCommitsTheWalkAndSendsNothing() throws {
        let store = makeSwitcherStore()
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: false)
        let landing = try XCTUnwrap(store.paneSwitcher).highlighted
        let press = PhoneKey.Press(hidUsage: HID.returnKey)

        XCTAssertEqual(PhoneKey.encode(press), [0x0D], "the byte that used to leak instead")
        XCTAssertEqual(PhoneKey.paneSwitcherKey(press, isOpen: true), .commit)
        XCTAssertTrue(store.takePaneSwitcherKey(press))
        XCTAssertNil(store.paneSwitcher)
        XCTAssertEqual(
            store.tree.activeSession?.activeTab?.activePane, landing,
            "and the commit landed on the pane the card was marking",
        )
    }

    /// ← / → step the highlight while the card is up. Asserted as OPPOSITES rather than against the
    /// ring's arithmetic, which is ``PaneSwitcher``'s own and pinned where it lives.
    func testTheArrowsStepTheHighlightWhileTheCardIsUp() throws {
        let store = makeSwitcherStore()
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: false)
        let opened = try XCTUnwrap(store.paneSwitcher).highlightIndex

        XCTAssertTrue(store.takePaneSwitcherKey(PhoneKey.Press(hidUsage: HID.right)))
        let stepped = try XCTUnwrap(store.paneSwitcher).highlightIndex
        XCTAssertNotEqual(stepped, opened, "→ moved the mark")

        XCTAssertTrue(store.takePaneSwitcherKey(PhoneKey.Press(hidUsage: HID.left)))
        XCTAssertEqual(
            try XCTUnwrap(store.paneSwitcher).highlightIndex, opened, "← undid exactly what → did",
        )
        XCTAssertNotNil(store.paneSwitcher, "a step never ends the walk")
    }

    /// The same four keys are the TERMINAL's until the card is up — the rung is gated on the gesture,
    /// not on the platform. Without this an arrow key would step a switcher nobody opened.
    func testTheWalksKeysBelongToTheTerminalUntilItIsOpen() {
        for usage in [HID.escape, HID.returnKey, HID.keypadEnter, HID.left, HID.right] {
            XCTAssertNil(
                PhoneKey.paneSwitcherKey(PhoneKey.Press(hidUsage: usage), isOpen: false),
                "usage \(usage) is the terminal's while nothing is walking",
            )
        }
    }

    /// A ⌘ combination falls through the walk exactly as it falls through copy mode — ⌘⇧P must still
    /// reach the palette from under an open card, and ⌘1–9 must still reach the binding table.
    func testACommandCombinationFallsThroughTheWalk() {
        let store = makeSwitcherStore()
        store.openOrStepPaneSwitcher(forward: true, armedByModifier: false)
        let palette = PhoneKey.Press(charactersIgnoringModifiers: "p", command: true, shift: true)

        XCTAssertNil(PhoneKey.paneSwitcherKey(palette, isOpen: true))
        XCTAssertFalse(store.takePaneSwitcherKey(palette))
        XCTAssertNotNil(store.paneSwitcher, "and it did not disturb the walk either")
    }

    /// A refusal is not a swallow. With one pane there is nothing to switch to, so ⌃⇥ must be reported
    /// UNHANDLED and go on to be the shell's Tab — a chord swallowed into a gesture that cannot happen
    /// is a dead key.
    func testARefusedWalkHandsControlTabBack() {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            makeSession: { seed in FakePaneSession(seed.spec) },
            liveVideoCap: 2,
        )
        store.attachLoopbackWorkspaceDocument()
        XCTAssertFalse(store.takePaneSwitcherKey(tab(control: true)))
        XCTAssertNil(store.paneSwitcher)
    }
}
