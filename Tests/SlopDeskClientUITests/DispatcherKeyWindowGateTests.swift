// DispatcherKeyWindowGateTests (keyboard audit) — the live `WorkspaceKeyDispatcher`'s KEY-WINDOW gate pinned
// headlessly: the app NSEvent monitor is application-wide (a `.keyDown` local monitor fires for events sent to
// ANY window in the process), so when a SEPARATE window is key — the stock SwiftUI Settings scene (⌘,) or an
// attached sheet — a bound workspace chord must NOT resolve against the hidden workspace tree behind it. These
// drive the dispatcher's real `handle(_:)` with a synthetic NSEvent (no window-server resource — the
// hang-safety rule is about SCStream/VT/Metal, not NSEvent) and assert that with the workspace window NOT key
// every bound chord PASSES THROUGH (never swallowed, never mutates the tree), while the load-bearing control
// (workspace window key) keeps the monitor OWNING the same chord.
//
// FAILS on the pre-fix code: there was no `isWorkspaceWindowKey` gate, so `handle(⌘W)` returned `nil` (swallow)
// and routed `.closePane` even while the Settings window was frontmost — closing a background terminal pane
// while Settings refused to close.

#if os(macOS)
import AppKit
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class DispatcherKeyWindowGateTests: XCTestCase {
    private func keyDown(
        _ chars: String, keyCode: UInt16, command: Bool = false, shift: Bool = false,
    ) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode,
        )!
    }

    /// A headless tree-model store with TWO leaves in its single tab (a split), so a `.closePane` is a
    /// non-cascading, non-busy mid-tab close that fires immediately (no confirmation park) — making a
    /// destructive close observable as a leaf-count drop.
    private func makeTwoLeafStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        WorkspaceBindingRegistry.route(.splitRight, to: store)
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "precondition: the split gave the tab two leaves")
        return store
    }

    /// With the workspace window NOT key (Settings / a sheet is frontmost), ⌘W is PASSED THROUGH (handle
    /// returns the event, not `nil`) and does NOT close a pane behind it — neither a park nor a leaf drop. This
    /// is the core destructive-action regression: ⌘W in the Settings window must reach the Settings window, not
    /// kill a terminal pane in the hidden main window.
    func testWorkspaceNotKeyYieldsCloseChordAndDoesNotDestroyPane() {
        let store = makeTwoLeafStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isWorkspaceWindowKey: { false })

        let result = dispatcher.handle(keyDown("w", keyCode: 13, command: true))

        XCTAssertNotNil(result, "⌘W passes through to the frontmost (Settings) window when the workspace isn't key")
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "⌘W must NOT close a background workspace pane")
        XCTAssertNil(store.pendingCloseSpec, "⌘W must NOT even park a close behind the frontmost window")
    }

    /// The load-bearing control: with the workspace window KEY the SAME ⌘W is still owned by the monitor —
    /// swallowed (handle returns `nil`) and routed to `.closePane`, dropping the active leaf. Together the two
    /// tests prove the gate — not an accidental table miss — is what flips ⌘W from "own the chord" to "yield it
    /// to the frontmost window".
    func testWorkspaceKeyStillOwnsCloseChordAndClosesPane() {
        let store = makeTwoLeafStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isWorkspaceWindowKey: { true })

        let result = dispatcher.handle(keyDown("w", keyCode: 13, command: true))

        XCTAssertNil(result, "with the workspace key the monitor still OWNS ⌘W (swallows + dispatches it)")
        XCTAssertEqual(store.tree.allPaneIDs().count, 1, "the swallowed ⌘W routed .closePane → one leaf gone")
    }

    /// ⌘T (new terminal pane) is likewise yielded while the workspace window isn't key — a new tab must not be
    /// minted in the hidden workspace behind the Settings window.
    func testWorkspaceNotKeyYieldsNewTabChord() {
        let store = makeTwoLeafStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isWorkspaceWindowKey: { false })

        let before = store.tree.allPaneIDs().count
        let result = dispatcher.handle(keyDown("t", keyCode: 17, command: true))

        XCTAssertNotNil(result, "⌘T passes through when the workspace window isn't key")
        XCTAssertEqual(store.tree.allPaneIDs().count, before, "⌘T must NOT mint a pane behind the frontmost window")
    }

    /// A BARE key passes through UNCHANGED regardless of key-window state (the gate never swallows normal
    /// typing — the default `{ true }` keeps at-rest behaviour identical).
    func testBareKeyPassesThroughRegardlessOfKeyWindowState() {
        let store = makeTwoLeafStore()
        for workspaceKey in [true, false] {
            let dispatcher = WorkspaceKeyDispatcher(store: store, isWorkspaceWindowKey: { workspaceKey })
            let result = dispatcher.handle(keyDown("a", keyCode: 0))
            XCTAssertNotNil(result, "a bare key always reaches the focused responder (workspaceKey=\(workspaceKey))")
        }
    }

    // MARK: - The hardened gate predicate (multi-window audit fix)

    /// The regression the hardened predicate closes: `WeakWindowBox.window` is WEAK, so before the introspect
    /// capture — or after the captured workspace window is deallocated / a re-render overwrote the box with a
    /// window that later closed — the old gate expression `window.map(\.isKeyWindow) ?? true` reported the
    /// workspace as KEY while a completely different window (Settings, a sheet) owned the keyboard, so a bound
    /// chord was swallowed + resolved against the hidden tree. A nil capture must NEVER report the workspace
    /// as key, whatever window currently is.
    func testNilCapturedWindowNeverReportsWorkspaceKey() {
        let someOtherWindow = NSObject() // stands in for the Settings window being key
        XCTAssertFalse(
            SlopDeskClientApp.workspaceWindowIsKey(captured: nil, keyWindow: someOtherWindow),
            "a nil (uncaptured / deallocated) workspace window must not claim the keyboard",
        )
        XCTAssertFalse(
            SlopDeskClientApp.workspaceWindowIsKey(captured: nil, keyWindow: nil),
            "with no key window at all there is nothing to own chords for",
        )
    }

    /// The gate is a pure IDENTITY comparison against the application's key window: true exactly when the
    /// captured workspace window IS the key window; any other key window (Settings scene, an attached sheet,
    /// a window-backed panel) resolves false so that window keeps its own keystrokes.
    func testWorkspaceWindowIsKeyRequiresIdentityWithTheKeyWindow() {
        let workspace = NSObject()
        let settings = NSObject()
        XCTAssertTrue(SlopDeskClientApp.workspaceWindowIsKey(captured: workspace, keyWindow: workspace))
        XCTAssertFalse(SlopDeskClientApp.workspaceWindowIsKey(captured: workspace, keyWindow: settings))
        XCTAssertFalse(SlopDeskClientApp.workspaceWindowIsKey(captured: workspace, keyWindow: nil))
    }

    /// End-to-end through the dispatcher: a STALE (empty) `WeakWindowBox` + another window key — built with the
    /// SAME predicate the app wires — must yield ⌘W (pass through, no tree mutation). On the old `?? true`
    /// closure this swallowed the chord and closed a background pane.
    func testStaleWindowBoxYieldsChordsWhileAnotherWindowIsKey() {
        let store = makeTwoLeafStore()
        let box = WeakWindowBox() // never captured (or the workspace window was deallocated)
        let otherKeyWindow = NSObject()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isWorkspaceWindowKey: {
            SlopDeskClientApp.workspaceWindowIsKey(captured: box.window, keyWindow: otherKeyWindow)
        })

        let result = dispatcher.handle(keyDown("w", keyCode: 13, command: true))

        XCTAssertNotNil(result, "with no captured workspace window ⌘W must pass through to the real key window")
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "⌘W must NOT close a background workspace pane")
        XCTAssertNil(store.pendingCloseSpec, "⌘W must NOT even park a close")
    }
}
#endif
