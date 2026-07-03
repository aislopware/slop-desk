// PrefixArmedIndicatorTests (keyboard improvement) — the "prefix armed" indicator seam pinned headlessly.
// When the tmux-style ⌃A prefix arms, the `WorkspaceKeyDispatcher` reports the armed edge through its
// `onPrefixArmedChange` closure (the app wires it to `OverlayCoordinator.setPrefixArmed`, which the workspace
// chip reads); every disarm path — a resolved follow-up chord, an unbound follow-up, the double-tap
// send-prefix, and the escape TIMEOUT — must clear it, or the chip lies (shows "armed" while the machine is
// idle and a bare key would go straight to the PTY).
//
// These drive the dispatcher's real `handle(_:)` with synthetic NSEvents (no window-server resource — the
// hang-safety rule is about SCStream/VT/Metal, not NSEvent). FAILS on the un-fixed code: the dispatcher had
// no armed-state seam at all (`onPrefixArmedChange` / `OverlayCoordinator.prefixArmed` did not exist).

#if os(macOS)
import AppKit
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class PrefixArmedIndicatorTests: XCTestCase {
    private func keyDown(
        _ chars: String, keyCode: UInt16, command: Bool = false, control: Bool = false,
    ) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if control { flags.insert(.control) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode,
        )!
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// The default ⌃A prefix event (keyCode 0 = 'a').
    private var prefixEvent: NSEvent { keyDown("a", keyCode: 0, control: true) }

    /// Arming the prefix reports `true`; a bound follow-up chord (⌘D → the seeded post-prefix resolve) FIRES
    /// and reports `false` — the chip shows exactly while the machine awaits the follow-up key.
    func testArmReportsTrueAndResolvedFollowUpClears() {
        let store = makeStore()
        var armed = false
        let dispatcher = WorkspaceKeyDispatcher(store: store, onPrefixArmedChange: { armed = $0 })

        XCTAssertNil(dispatcher.handle(prefixEvent), "the prefix is swallowed (never leaks to the PTY)")
        XCTAssertTrue(armed, "arming the prefix must light the indicator")

        XCTAssertNil(dispatcher.handle(keyDown("d", keyCode: 2, command: true)), "the bound follow-up fires")
        XCTAssertFalse(armed, "a resolved follow-up chord must clear the indicator")
    }

    /// An UNBOUND follow-up key (tmux-faithful disarm + swallow) clears the indicator too.
    func testUnboundFollowUpClears() {
        let store = makeStore()
        var armed = false
        let dispatcher = WorkspaceKeyDispatcher(store: store, onPrefixArmedChange: { armed = $0 })

        XCTAssertNil(dispatcher.handle(prefixEvent))
        XCTAssertTrue(armed)

        XCTAssertNil(dispatcher.handle(keyDown("q", keyCode: 12)), "an unbound armed key is swallowed")
        XCTAssertFalse(armed, "the tmux-faithful disarm must clear the indicator")
    }

    /// Double-tapping the prefix (send-prefix literal) disarms — the indicator clears.
    func testDoubleTapPrefixClears() {
        let store = makeStore()
        var armed = false
        let dispatcher = WorkspaceKeyDispatcher(store: store, onPrefixArmedChange: { armed = $0 })

        XCTAssertNil(dispatcher.handle(prefixEvent))
        XCTAssertTrue(armed)

        XCTAssertNil(dispatcher.handle(prefixEvent), "the double-tap emits the literal prefix + disarms")
        XCTAssertFalse(armed, "send-prefix must clear the indicator")
    }

    /// A bare key while IDLE never lights the indicator (normal typing shows no chip).
    func testBareKeyWhileIdleStaysCleared() {
        let store = makeStore()
        var armed = false
        let dispatcher = WorkspaceKeyDispatcher(store: store, onPrefixArmedChange: { armed = $0 })

        XCTAssertNotNil(dispatcher.handle(keyDown("x", keyCode: 7)), "bare typing passes through")
        XCTAssertFalse(armed)
    }

    /// The escape TIMEOUT clears the indicator WITHOUT another keystroke: the machine's stale arm expires and
    /// the dispatcher's expiry task reports the `false` edge — otherwise the chip would stay lit forever after
    /// an abandoned prefix.
    func testTimeoutClearsIndicatorWithoutAFollowUpKey() async throws {
        let store = makeStore()
        var armed = false
        let dispatcher = WorkspaceKeyDispatcher(store: store, onPrefixArmedChange: { armed = $0 })
        dispatcher.setPrefixTimeout(0.05)

        XCTAssertNil(dispatcher.handle(prefixEvent))
        XCTAssertTrue(armed)

        // The expiry task fires at timeout + a small epsilon; poll well past it (bounded, never flaky-tight).
        for _ in 0..<40 where armed {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(armed, "an abandoned arm must clear the indicator on timeout")
    }

    /// The app wiring target: `OverlayCoordinator.setPrefixArmed` publishes the `@Observable` flag the
    /// workspace chip reads — the closure-driven edges land on the coordinator unchanged (and redundant sets
    /// are idempotent).
    func testCoordinatorPublishesArmedFlag() {
        let store = makeStore()
        let overlay = OverlayCoordinator(store: store)
        let dispatcher = WorkspaceKeyDispatcher(
            store: store, onPrefixArmedChange: { [overlay] in overlay.setPrefixArmed($0) },
        )

        XCTAssertFalse(overlay.prefixArmed)
        XCTAssertNil(dispatcher.handle(prefixEvent))
        XCTAssertTrue(overlay.prefixArmed, "the coordinator mirrors the armed edge for the chip")

        XCTAssertNil(dispatcher.handle(keyDown("q", keyCode: 12)))
        XCTAssertFalse(overlay.prefixArmed, "the coordinator mirrors the disarm edge")

        overlay.setPrefixArmed(false) // idempotent — a redundant clear never traps / re-publishes
        XCTAssertFalse(overlay.prefixArmed)
    }
}
#endif
