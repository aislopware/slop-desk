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
        let store = WorkspaceStore(makeSession: { seed in MountTestPaneSession(seed.spec) })
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
        dispatcher.readLiveModifiers = { [.command] } // ⌘ physically held throughout

        _ = dispatcher.handle(flagsChanged(command: true))
        XCTAssertTrue(store.shortcutHintActive, "precondition: the hint is up")

        windowIsKey = false
        _ = dispatcher.handle(flagsChanged(command: false))

        XCTAssertFalse(store.shortcutHintActive, "the stranded hint was cleared on the next pass")
    }

    // MARK: - The stuck-hint guards (the "numbers with no key held" bug)

    /// THE REPORTED BUG: the hold timer fires on a 250 ms-stale transition, and the ⌘ key-up that
    /// should have cancelled it can be swallowed past the monitor entirely (menu tracking, an app
    /// switch completing). The fire must re-validate against the LIVE hardware modifiers — a timer
    /// whose ⌘ is already gone shows nothing.
    func testAStaleTimerFireShowsNothingOnceCommandIsGone() async throws {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        dispatcher.shortcutHintHoldDelay = .milliseconds(5)
        dispatcher.readLiveModifiers = { [] } // by fire time the release was eaten elsewhere

        _ = dispatcher.handle(flagsChanged(command: true))
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertFalse(store.shortcutHintActive, "a fire without live ⌘ is a stale timer, not a hold")
    }

    /// The positive control for the guard above: the same timer path DOES show the hint while ⌘ is
    /// still physically down at fire time.
    func testTheTimerFireShowsTheHintWhileCommandIsStillHeld() async throws {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        dispatcher.shortcutHintHoldDelay = .milliseconds(5)
        dispatcher.readLiveModifiers = { [.command] }

        _ = dispatcher.handle(flagsChanged(command: true))
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(store.shortcutHintActive, "a genuine hold still shows through the timer path")
    }

    /// The keystroke SELF-HEAL: a hint that somehow survived its release (the key-up swallowed after
    /// the hint was already up) is cleared by the next event of any kind — it can outlive the hold by
    /// at most one keystroke, never sit on screen indefinitely.
    func testTheNextKeystrokeHealsAHintWhoseReleaseWasSwallowed() throws {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        dispatcher.shortcutHintHoldDelay = .zero
        dispatcher.readLiveModifiers = { [.command] }

        _ = dispatcher.handle(flagsChanged(command: true))
        XCTAssertTrue(store.shortcutHintActive, "precondition: the hint is up")

        dispatcher.readLiveModifiers = { [] } // ⌘ was released, but the transition never arrived
        let result = try dispatcher.handle(
            XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: 0,
            )),
        )

        XCTAssertNotNil(result, "the healing keystroke still reaches the pane untouched")
        XCTAssertFalse(store.shortcutHintActive, "and the stranded hint is gone")
    }

    /// App DEACTIVATION mid-hold (⌘⇥ away) is the one exit where no further event of any kind
    /// reaches a local monitor — the resign notification is the only signal left, and it must clear
    /// both an active hint and a still-pending timer.
    func testAppDeactivationClearsTheHint() {
        let store = makeStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store)
        dispatcher.shortcutHintHoldDelay = .zero
        dispatcher.readLiveModifiers = { [.command] }
        dispatcher.install()
        defer { dispatcher.teardown() }

        _ = dispatcher.handle(flagsChanged(command: true))
        XCTAssertTrue(store.shortcutHintActive, "precondition: the hint is up")

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        XCTAssertFalse(store.shortcutHintActive, "deactivation cleared the hint with no event needed")
    }
}
#endif
