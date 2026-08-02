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
}
#endif
