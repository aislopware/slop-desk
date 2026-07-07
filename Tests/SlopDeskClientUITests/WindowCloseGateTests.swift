// WindowCloseGateTests — E3 WI-4. Proves the macOS window-close gate (`WindowCloseGate`, the pure logic
// behind `WindowCloseConfirmationDelegate.windowShouldClose`) can NEVER strand the window.
//
// The regression this guards: the old delegate returned a bare `false` whenever a confirmation parked, with
// NOTHING in the app observing `pendingWindowClose` to resolve it — under the default `.process` policy a
// single busy pane made the red traffic-light silently fail to close the window, with no escape. These pin
// that a parked close ALWAYS has a path to actually close (confirm ⇒ closeable), a cancel keeps the window
// open WITHOUT leaving a stale park, and a no-confirmation close happens immediately without prompting.
//
// Headless: drives a tree-model `WorkspaceStore` over the same `MountTestPaneSession` double the coordinator
// suite uses, with a STUB `confirm` closure in place of the real `NSAlert` (the hang-safety rule forbids an
// `NSWindow` in a test; the alert itself is AppKit plumbing, code-reviewed).

#if os(macOS)
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class WindowCloseGateTests: XCTestCase {
    private let key = SettingsKey.closeConfirmWindowKey

    override func setUp() {
        super.setUp()
        SettingsKey.store.removeObject(forKey: key)
    }

    override func tearDown() {
        SettingsKey.store.removeObject(forKey: key)
        super.tearDown()
    }

    /// A live tree-model store with one default session (one terminal pane) — enough for `requestCloseWindow`
    /// to resolve an active session.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    func testNoConfirmationNeededClosesImmediatelyWithoutPrompting() {
        // Default `.process` policy + an idle shell ⇒ no park ⇒ close now, and `confirm` is NEVER called.
        let store = makeStore()
        var promptShown = false
        let allowed = WindowCloseGate.resolve(store: store) {
            promptShown = true
            return false
        }
        XCTAssertTrue(allowed, "an idle process-policy window closes immediately")
        XCTAssertFalse(promptShown, "no confirmation prompt is shown when none is needed")
        XCTAssertNil(store.pendingWindowClose, "no park is left behind")
    }

    func testParkedCloseClosesWhenUserConfirms() {
        // `.always` parks every close; confirming MUST let the window close. The OLD delegate returned `false`
        // here unconditionally, with no resolution path — the window could never close. This is the bug pin.
        SettingsKey.store.set("always", forKey: key)
        let store = makeStore()

        let allowed = WindowCloseGate.resolve(store: store) { true }

        XCTAssertTrue(allowed, "confirming a parked close lets the window close — never trapped")
        XCTAssertNil(store.pendingWindowClose, "the park is consumed on confirm")
    }

    func testParkedCloseKeepsWindowOpenAndClearsParkWhenUserCancels() {
        SettingsKey.store.set("always", forKey: key)
        let store = makeStore()

        let allowed = WindowCloseGate.resolve(store: store) { false }

        XCTAssertFalse(allowed, "cancelling keeps the window open")
        XCTAssertNil(store.pendingWindowClose, "cancel clears the park (no stale block on the next attempt)")
    }

    func testConfirmIsPresentedExactlyOnceWhenParked() {
        SettingsKey.store.set("always", forKey: key)
        let store = makeStore()
        var calls = 0
        _ = WindowCloseGate.resolve(store: store) {
            calls += 1
            return true
        }
        XCTAssertEqual(calls, 1, "the synchronous prompt is presented exactly once per close attempt")
    }
}
#endif
