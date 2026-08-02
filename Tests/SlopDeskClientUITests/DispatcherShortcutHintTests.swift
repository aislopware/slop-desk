// DispatcherShortcutHintTests — the ⌘-held sidebar number hint at the live NSEvent monitor.
//
// Holding ⌘ past the hold threshold flips `WorkspaceStore.shortcutHintActive`, and the rail rows swap
// their leading run for the ⌘-digit (`shortcutNumber(for:)`). Like the ⌃⇥ gesture it is driven from
// `.flagsChanged` transitions, not the chord table — a modifier alone is not a chord.
//
// The load-bearing property pinned here: the threshold is a HOLD gate. Every ordinary ⌘-chord (⌘C,
// ⌘W, …) begins with the exact same ⌘-down transition, and a hint that fired on it would flash the
// whole rail on every shortcut the user types.

#if os(macOS)
import AppKit
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class DispatcherShortcutHintTests: XCTestCase {
    /// A `.flagsChanged` event carrying the modifiers STILL held after the transition — ⌘ present is
    /// the hold's arm signal; ⌘ absent is its release.
    private func flagsChanged(command: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero,
            modifierFlags: command ? [.command] : [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 55, // left Command
        )!
    }

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in MountTestPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    /// ⌘ held past the threshold shows the hint; the transition itself is never swallowed (the
    /// terminal tracks modifier state too). Zero delay = the synchronous path, so no timer to await.
    func testHoldingCommandPastTheThresholdShowsTheHint() {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        dispatcher.shortcutHintHoldDelay = .zero

        let result = dispatcher.handle(flagsChanged(command: true))

        XCTAssertNotNil(result, "a modifier transition is never swallowed")
        XCTAssertTrue(store.shortcutHintActive, "⌘ held past the threshold shows the digits")
    }

    /// Releasing ⌘ hides the hint immediately — the resting rail never shows chord chrome.
    func testReleasingCommandHidesTheHint() {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        dispatcher.shortcutHintHoldDelay = .zero

        _ = dispatcher.handle(flagsChanged(command: true))
        _ = dispatcher.handle(flagsChanged(command: false))

        XCTAssertFalse(store.shortcutHintActive, "the ⌘ key-up cleared the hint")
    }

    /// A quick ⌘-chord (⌘ down, key, ⌘ up — all inside the threshold) must never flash the rail:
    /// the release cancels the still-pending hold timer before it fires.
    func testAQuickChordNeverFlashesTheHint() {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store) // default (non-zero) hold delay

        _ = dispatcher.handle(flagsChanged(command: true))
        XCTAssertFalse(store.shortcutHintActive, "inside the threshold nothing shows yet")
        _ = dispatcher.handle(flagsChanged(command: false))

        XCTAssertFalse(store.shortcutHintActive, "and the release leaves the cancelled timer dead")
    }

    /// While a keyboard-capturing overlay (the Open-Quickly picker) is up, ⌘1–9 mean PICKER rows —
    /// the sidebar must not number itself for a chord it will never receive.
    func testCapturingOverlaySuppressesTheHint() {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isOverlayCapturingKeys: { true })
        dispatcher.shortcutHintHoldDelay = .zero

        _ = dispatcher.handle(flagsChanged(command: true))

        XCTAssertFalse(store.shortcutHintActive, "the picker owns ⌘1–9; the rail stays quiet")
    }

    /// The workspace window losing key mid-hold (⌘⇥ to another app IS a ⌘ hold) must clear the hint:
    /// the ⌘ key-up will land while another window is key, so the ordinary release path never runs.
    func testLosingKeyWindowClearsAnActiveHint() {
        let store = makeStore()
        var windowIsKey = true
        let dispatcher = WorkspaceKeyDispatcher(store: store, isWorkspaceWindowKey: { windowIsKey })
        dispatcher.shortcutHintHoldDelay = .zero

        _ = dispatcher.handle(flagsChanged(command: true))
        XCTAssertTrue(store.shortcutHintActive, "precondition: the hint is up")

        windowIsKey = false
        _ = dispatcher.handle(flagsChanged(command: false))

        XCTAssertFalse(store.shortcutHintActive, "the stranded hint was cleared on the next pass")
    }
}
#endif
