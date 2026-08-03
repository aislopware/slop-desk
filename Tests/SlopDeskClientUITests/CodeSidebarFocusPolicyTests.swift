#if os(macOS)
import AppKit
import XCTest
@testable import SlopDeskClientUI

/// ``CodeSidebarFocusPolicy`` — the embedded VS Code may take the keyboard ONLY from a direct user
/// mouse-down inside the webview; every autofocus path is refused. Pure truth-table (hang-safety:
/// no WKWebView is ever constructed here — the policy is the whole decision).
final class CodeSidebarFocusPolicyTests: XCTestCase {
    func testUserClickInsideIsHonored() {
        XCTAssertTrue(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: .leftMouseDown, clickWasInsideWebView: true),
        )
        XCTAssertTrue(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: .rightMouseDown, clickWasInsideWebView: true),
        )
        XCTAssertTrue(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: .otherMouseDown, clickWasInsideWebView: true),
        )
    }

    func testClickOutsideIsRefused() {
        // A mouse-down elsewhere in the window with a coincident page `focus()` must not move the
        // keyboard into the editor.
        XCTAssertFalse(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: .leftMouseDown, clickWasInsideWebView: false),
        )
    }

    func testProgrammaticAutofocusIsRefused() {
        // VS Code's own `focus()` (load, file open, layout change) arrives with NO current event.
        XCTAssertFalse(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: nil, clickWasInsideWebView: true),
        )
        XCTAssertFalse(
            CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: nil, clickWasInsideWebView: false),
        )
    }

    func testAutofocusRidingAnUnrelatedEventIsRefused() {
        // An autofocus can land while ANY event is current — a keystroke bound for the terminal, a
        // scroll, a hover. None of them is consent, wherever the pointer happens to sit.
        for type: NSEvent.EventType in [.keyDown, .keyUp, .scrollWheel, .mouseMoved, .leftMouseUp, .flagsChanged] {
            XCTAssertFalse(
                CodeSidebarFocusPolicy.shouldAcceptFocus(eventType: type, clickWasInsideWebView: true),
                "\(type) must not hand the webview the keyboard",
            )
        }
    }

    // MARK: Reserved app chords

    func testAppManagementChordsAreReserved() {
        // Quit / Hide / Hide Others / Minimize / window cycling belong to the APP even while the
        // editor holds the keyboard — WKWebView's performKeyEquivalent would otherwise feed them to
        // the page before the main menu ever sees them.
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "q"))
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "h"))
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command, .option], key: "h"))
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "m"))
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "`"))
    }

    func testDeviceDependentFlagBitsDoNotDefeatTheMatch() {
        // Real events carry device-dependent bits (left/right key distinction, caps state) on top
        // of `.command` — the policy must match on the chord, not raw-value equality.
        let raw = NSEvent.ModifierFlags([.command, .init(rawValue: 0x108)])
        XCTAssertTrue(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: raw, key: "q"))
    }

    func testEditorChordsStayWithTheWorkbench() {
        // The user focused the editor on purpose: its own keymap keeps everything else.
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "w"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: "p"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: ","))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command, .shift], key: "q"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.option], key: "q"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [], key: "q"))
        XCTAssertFalse(CodeSidebarFocusPolicy.isReservedAppChord(modifiers: [.command], key: nil))
    }

    // MARK: Editing chords

    func testBareCommandEditingChordsMapToTheNativeEditingActions() {
        // VS Code web never acts on raw ⌘C/⌘V/⌘X/⌘A keydowns — in a browser those are the Edit
        // menu's, and this app's menus are shortcut-less. The webview claims them and drives
        // WebKit's own editing actions instead; unclaimed they bounce back and became phantom
        // terminal input (libghostty's cmd+v paste binding).
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "c"), .copy)
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "v"), .paste)
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "x"), .cut)
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "a"), .selectAll)
    }

    func testModifiedOrForeignChordsAreNotEditingCommands() {
        // Shifted/optioned variants and every other letter stay with VS Code's own keymap
        // (⌘⇧V markdown preview, ⌘⌥C toggle-case-sensitive find, …).
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command, .shift], key: "v"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command, .option], key: "c"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command, .control], key: "a"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: "p"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [], key: "c"))
        XCTAssertNil(CodeSidebarFocusPolicy.editingCommand(modifiers: [.command], key: nil))
    }

    func testDeviceDependentFlagBitsDoNotDefeatTheEditingMatch() {
        let raw = NSEvent.ModifierFlags([.command, .init(rawValue: 0x108)])
        XCTAssertEqual(CodeSidebarFocusPolicy.editingCommand(modifiers: raw, key: "v"), .paste)
    }

    // MARK: Keyboard ownership across key-window changes

    func testAppDeactivationPreservesOwnership() {
        // ⌘⇥ to another app: `didResignKey` fires with NO key window left. The keyboard left the
        // APP, not the editor — dropping the flag here is what let the terminal reclaim first
        // responder in the background, so ⌘⇥-ing back landed in the terminal instead of the editor.
        XCTAssertTrue(CodeSidebarFocusPolicy.keyboardOwnership(
            previous: true, hasKeyWindow: false, webViewHoldsFirstResponder: false,
        ))
        // And a terminal-owned keyboard stays terminal-owned across the same round trip.
        XCTAssertFalse(CodeSidebarFocusPolicy.keyboardOwnership(
            previous: false, hasKeyWindow: false, webViewHoldsFirstResponder: false,
        ))
    }

    func testIntraAppKeyWindowMoveRederivesFromTheLiveResponder() {
        // A satellite pane window taking key moves the keyboard WITHOUT any responder transition —
        // the webview stays its own window's first responder, but it no longer receives keys.
        XCTAssertFalse(CodeSidebarFocusPolicy.keyboardOwnership(
            previous: true, hasKeyWindow: true, webViewHoldsFirstResponder: false,
        ))
        // The main window taking key back with the webview still first responder re-lights it.
        XCTAssertTrue(CodeSidebarFocusPolicy.keyboardOwnership(
            previous: false, hasKeyWindow: true, webViewHoldsFirstResponder: true,
        ))
    }

    // MARK: Remount restore (warm-swap focus hand-back)

    func testRemountInTheClaimedTabRestores() {
        // The editor owned the keyboard in tab A; a tab round-trip (or the panel's Desktop tab /
        // a collapse) unmounted the webview. Remounting back in tab A hands the keyboard back —
        // the workbench looks exactly as it was left, so typing must land in it again.
        XCTAssertTrue(CodeSidebarFocusPolicy.shouldRestoreOnRemount(claimedTab: "A", activeTab: "A"))
    }

    func testRemountInAnotherTabNeverSteals() {
        // Another tab's pane focusing into this project remounts the same pooled webview — the
        // user just focused THAT pane; the editor must not yank the keyboard from it.
        XCTAssertFalse(CodeSidebarFocusPolicy.shouldRestoreOnRemount(claimedTab: "A", activeTab: "B"))
    }

    func testUnclaimedOrUnwiredTabsNeverRestore() {
        // No recorded claim, or the app never wired the active-tab provider (headless tests): the
        // restore must stay off rather than fire on a nil == nil coincidence.
        XCTAssertFalse(CodeSidebarFocusPolicy.shouldRestoreOnRemount(claimedTab: String?.none, activeTab: "A"))
        XCTAssertFalse(
            CodeSidebarFocusPolicy.shouldRestoreOnRemount(claimedTab: String?.none, activeTab: String?.none),
        )
        XCTAssertFalse(CodeSidebarFocusPolicy.shouldRestoreOnRemount(claimedTab: "A", activeTab: String?.none))
    }
}
#endif
