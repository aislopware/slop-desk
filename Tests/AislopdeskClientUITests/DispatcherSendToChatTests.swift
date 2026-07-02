// DispatcherSendToChatTests (E13 WI-5 / ES-E13-5) — the live `WorkspaceKeyDispatcher` FIRES the Send-to-Chat
// toggle (⌘⌃↩) through the SAME NSEvent monitor that owns every chord, and SWALLOWS the event (never
// leaks the chord to the PTY). This is the exact wiring the review found missing: `dispatch(_:)` resolved
// `.sendToChat` but called `WorkspaceBindingRegistry.route(...)` WITHOUT threading `toggleSendToChat`, so the
// chord was a permanent no-op (the closure defaulted to nil → graceful no-op) and the dialog never appeared.
//
// Driven headlessly with a synthetic NSEvent (no window-server resource — the hang-safety rule is about
// SCStream/VT/Metal, not NSEvent).
//
// REVERT-TO-CONFIRM-FAIL: with `dispatch(_:)`'s `route(...)` call missing `toggleSendToChat:` (the pre-fix
// state) the closure never fires — `fired` stays 0 and `testSendToChatChordFiresTheToggleAndSwallows` fails.

#if os(macOS)
import AppKit
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class DispatcherSendToChatTests: XCTestCase {
    /// A synthetic `.keyDown` carrying exactly the fields `KeyChordNormalizer` reads. Return is keyCode 36.
    private func keyDown(
        _ chars: String, keyCode: UInt16, command: Bool = false, control: Bool = false, shift: Bool = false,
    ) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if control { flags.insert(.control) }
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode,
        )!
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// ⌘⌃↩ (Return, keyCode 36, command+control) — the Send-to-Chat chord — fires the threaded
    /// `toggleSendToChat` closure EXACTLY once and SWALLOWS the event (returns nil), so the chord never leaks a
    /// CR to the focused PTY. This pins the wiring the review found missing (the dialog now actually opens).
    func testSendToChatChordFiresTheToggleAndSwallows() {
        let store = makeStore()
        var fired = 0
        let dispatcher = WorkspaceKeyDispatcher(store: store, toggleSendToChat: { fired += 1 })

        let result = dispatcher.handle(keyDown("\r", keyCode: 36, command: true, control: true))

        XCTAssertEqual(fired, 1, "⌘⌃↩ fires the threaded toggleSendToChat exactly once (the dialog opens)")
        XCTAssertNil(result, "⌘⌃↩ is OWNED by the monitor (swallowed) — the CR never leaks to the PTY")
    }

    /// The graceful-default control: a dispatcher built WITHOUT a `toggleSendToChat` closure (the headless /
    /// test default) still OWNS ⌘⌃↩ (swallows it) but does nothing — never a dead chord, never a CR leak. So
    /// the chord is live when wired and a non-trapping no-op when not.
    func testSendToChatChordIsAGracefulNoOpWithoutAToggle() {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store) // no toggleSendToChat

        let result = dispatcher.handle(keyDown("\r", keyCode: 36, command: true, control: true))

        XCTAssertNil(result, "⌘⌃↩ is still swallowed (owned by the monitor) even with no toggle — no PTY leak")
    }
}
#endif
