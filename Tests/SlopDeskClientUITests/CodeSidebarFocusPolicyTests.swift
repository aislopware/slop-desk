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
}
#endif
