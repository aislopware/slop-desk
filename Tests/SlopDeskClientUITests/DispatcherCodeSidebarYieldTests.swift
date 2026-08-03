// DispatcherCodeSidebarYieldTests — the WEBVIEW-YIELD gate pinned headlessly: while the right code
// panel's WKWebView holds first responder, the app NSEvent monitor must NOT resolve the global chord
// table — the embedded VS Code's own vocabulary (⌘P/⌘F/⌘S/⌘W/⌘1–9 …) collides with it wholesale, and
// the monitor PREEMPTS the responder chain, so an unyielded ⌘W would close the workspace PANE while
// the user meant "close the editor tab". The one exception: ⌘⇧R (Toggle Code Panel) keeps its app
// meaning — closing the panel is how the keyboard comes back without the mouse.
//
// Driven through the dispatcher's real `handle(_:)` with a synthetic NSEvent and an injected
// `isCodeSidebarCapturingKeys` (no WKWebView is created — hang-safety holds; the live default reads
// the webview pool, which these tests never touch).

#if os(macOS)
import AppKit
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class DispatcherCodeSidebarYieldTests: XCTestCase {
    /// A synthetic `.keyDown` NSEvent (no window server) carrying exactly the fields the dispatcher's
    /// `KeyChordNormalizer` reads.
    private func keyDown(
        _ chars: String, keyCode: UInt16, command: Bool = false, shift: Bool = false,
        option: Bool = false,
    ) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode,
        )!
    }

    /// A headless tree-model store with TWO leaves (a split), so a `.closePane` would be an immediate
    /// observable close — the destructive action the yield must suppress.
    private func makeTwoLeafStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        WorkspaceBindingRegistry.route(.splitRight, to: store)
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "precondition: the split gave the tab two leaves")
        return store
    }

    private func makeDispatcher(
        store: WorkspaceStore, webViewFocused: Bool,
    ) -> WorkspaceKeyDispatcher {
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        dispatcher.isCodeSidebarCapturingKeys = { webViewFocused }
        return dispatcher
    }

    /// With the webview focused, ⌘W passes through to WebKit (VS Code's close-editor) — no swallow, no
    /// pane close, not even a parked confirmation.
    func testWebViewFocusYieldsCloseChord() {
        let store = makeTwoLeafStore()
        let dispatcher = makeDispatcher(store: store, webViewFocused: true)

        let result = dispatcher.handle(keyDown("w", keyCode: 13, command: true))

        XCTAssertNotNil(result, "⌘W is passed through to the webview (not swallowed) while it has focus")
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "⌘W must NOT close a pane behind the webview")
        XCTAssertNil(store.pendingCloseSpec, "⌘W must NOT even park a close behind the webview")
    }

    /// With the webview focused, ⌘D (split right) passes through — VS Code's add-selection-to-next-match
    /// must reach the editor, not mint a workspace split.
    func testWebViewFocusYieldsSplitChord() {
        let store = makeTwoLeafStore()
        let dispatcher = makeDispatcher(store: store, webViewFocused: true)

        let result = dispatcher.handle(keyDown("d", keyCode: 2, command: true))

        XCTAssertNotNil(result, "⌘D is passed through to the webview while it has focus")
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "⌘D must NOT mint a split behind the webview")
    }

    /// The ONE escape hatch: ⌘⇧R stays app-owned while the webview has focus — swallowed and routed to
    /// `.toggleCodeSidebar`, so the panel can always be closed from the keyboard.
    func testCmdShiftRStaysAppOwnedWhileWebViewFocused() {
        let store = makeTwoLeafStore()
        let dispatcher = makeDispatcher(store: store, webViewFocused: true)
        var toggled = 0
        dispatcher.setToggleCodeSidebar { toggled += 1 }

        let result = dispatcher.handle(keyDown("R", keyCode: 15, command: true, shift: true))

        XCTAssertNil(result, "⌘⇧R is swallowed — the panel toggle is the webview-yield's one exception")
        XCTAssertEqual(toggled, 1, "⌘⇧R routed .toggleCodeSidebar through the installed chrome closure")
    }

    /// The load-bearing control: with the webview NOT focused the SAME ⌘W is still owned by the
    /// monitor — swallowed and routed to `.closePane`.
    func testWebViewUnfocusedStillOwnsCloseChord() {
        let store = makeTwoLeafStore()
        let dispatcher = makeDispatcher(store: store, webViewFocused: false)

        let result = dispatcher.handle(keyDown("w", keyCode: 13, command: true))

        XCTAssertNil(result, "with the webview unfocused the monitor still OWNS ⌘W")
        XCTAssertEqual(store.tree.allPaneIDs().count, 1, "the swallowed ⌘W routed .closePane → one leaf gone")
    }

    /// ⌘⇧R with the webview unfocused routes the same way (the toggle is global chrome, not
    /// webview-conditional).
    func testCmdShiftRRoutesWhileWebViewUnfocused() {
        let store = makeTwoLeafStore()
        let dispatcher = makeDispatcher(store: store, webViewFocused: false)
        var toggled = 0
        dispatcher.setToggleCodeSidebar { toggled += 1 }

        let result = dispatcher.handle(keyDown("R", keyCode: 15, command: true, shift: true))

        XCTAssertNil(result, "⌘⇧R is an owned chord at rest too")
        XCTAssertEqual(toggled, 1)
    }

    /// The SECOND escape hatch: ⌥⌘R hands the keyboard back to the pane WITHOUT closing the panel —
    /// so it too has to survive the yield, or a focused editor could only be left by hiding it.
    func testOptionCmdRStaysAppOwnedWhileWebViewFocused() {
        let store = makeTwoLeafStore()
        let dispatcher = makeDispatcher(store: store, webViewFocused: true)
        var focused = 0
        dispatcher.setFocusCodePanel { focused += 1 }

        let result = dispatcher.handle(keyDown("r", keyCode: 15, command: true, option: true))

        XCTAssertNil(result, "⌥⌘R is swallowed — the keyboard hand-off must work FROM inside the editor")
        XCTAssertEqual(focused, 1, "⌥⌘R routed .focusCodePanel through the installed closure")
    }

    /// …and the same chord going the other way, with the terminal holding the keyboard.
    func testOptionCmdRRoutesWhileWebViewUnfocused() {
        let store = makeTwoLeafStore()
        let dispatcher = makeDispatcher(store: store, webViewFocused: false)
        var focused = 0
        dispatcher.setFocusCodePanel { focused += 1 }

        let result = dispatcher.handle(keyDown("r", keyCode: 15, command: true, option: true))

        XCTAssertNil(result, "⌥⌘R is an owned chord at rest too")
        XCTAssertEqual(focused, 1)
    }

    /// The yield's exemption set stays exactly two entries wide. Every other action must keep
    /// passing through — the editor is where VS Code's own vocabulary has to work.
    func testOnlyTheTwoEscapeHatchesSurviveTheYield() {
        for action in [WorkspaceAction.toggleCodeSidebar, .focusCodePanel] {
            XCTAssertTrue(WorkspaceKeyDispatcher.survivesCodePanelYield(action), "\(action) is an escape hatch")
        }
        for action in [WorkspaceAction.closePane, .splitRight, .toggleSidebar, .jumpTo, .pinWindow] {
            XCTAssertFalse(
                WorkspaceKeyDispatcher.survivesCodePanelYield(action),
                "\(action) must yield to the embedded editor",
            )
        }
    }
}
#endif
