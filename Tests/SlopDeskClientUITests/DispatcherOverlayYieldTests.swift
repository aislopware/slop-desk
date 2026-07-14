// DispatcherOverlayYieldTests — the live `WorkspaceKeyDispatcher`'s MODAL-YIELD gate pinned
// headlessly: while a keyboard-capturing overlay (the Open-Quickly picker) is presented, the app NSEvent
// monitor must NOT resolve the GLOBAL chord table behind it. Before the fix the monitor — which PREEMPTS the
// responder chain — swallowed any bound ⌘-chord before the picker's `.onKeyPress` ran, so ⌘1–9 switched the
// BACKGROUND tab (instead of quick-picking the Nth result) and ⌘W DESTRUCTIVELY closed the focused pane behind
// the open picker. These drive the dispatcher's real `handle(_:)` with a synthetic NSEvent (no
// window-server resource — the hang-safety rule is about SCStream/VT/Metal, not NSEvent) and assert the gate
// yields the keyboard to the picker (passthrough), and — as the load-bearing control — that with the picker
// HIDDEN the very same chord is still owned (swallowed + dispatched) by the monitor.
//
// FAILS on the pre-fix code: there was no `isOverlayCapturingKeys` gate, so `handle(⌘W)` returned `nil`
// (swallow) and routed `.closePane` even with the picker up — the destructive behaviour this fix removes.

#if os(macOS)
import AppKit
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class DispatcherOverlayYieldTests: XCTestCase {
    /// A synthetic `.keyDown` NSEvent (no window server) carrying exactly the fields the dispatcher's
    /// `KeyChordNormalizer` reads: `charactersIgnoringModifiers`, `keyCode`, and the modifier flags.
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
    /// non-cascading, non-busy mid-tab close that fires immediately (no confirmation park) — making the
    /// destructive close observable as a leaf-count drop.
    private func makeTwoLeafStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        WorkspaceBindingRegistry.route(.splitRight, to: store) // mints a focused terminal sibling leaf
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "precondition: the split gave the tab two leaves")
        return store
    }

    /// While the picker is visible, ⌘W is PASSED THROUGH to the focused overlay (handle returns the event,
    /// not `nil`) and does NOT close the pane behind it — neither a park nor a leaf drop. This is the core
    /// destructive-action regression: ⌘W must select the Opened pill in the picker, never destroy
    /// the focused pane/session.
    func testPickerVisibleYieldsCloseChordAndDoesNotDestroyPane() {
        let store = makeTwoLeafStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isOverlayCapturingKeys: { true })

        let result = dispatcher.handle(keyDown("w", keyCode: 13, command: true))

        XCTAssertNotNil(result, "⌘W is passed through to the picker (not swallowed) while it is open")
        XCTAssertEqual(store.tree.allPaneIDs().count, 2, "⌘W must NOT close a pane behind the open picker")
        XCTAssertNil(store.pendingCloseSpec, "⌘W must NOT even park a close behind the open picker")
    }

    /// The load-bearing control: with the picker HIDDEN the SAME ⌘W is still owned by the monitor — swallowed
    /// (handle returns `nil`) and routed to `.closePane`, dropping the active leaf. This is exactly the
    /// behaviour the gate suppresses while the picker is up; together the two tests prove the gate is what
    /// flips ⌘W from "destroy the focused pane" to "reach the picker".
    func testPickerHiddenStillOwnsCloseChordAndClosesPane() {
        let store = makeTwoLeafStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isOverlayCapturingKeys: { false })

        let result = dispatcher.handle(keyDown("w", keyCode: 13, command: true))

        XCTAssertNil(result, "with no picker up the monitor still OWNS ⌘W (swallows + dispatches it)")
        XCTAssertEqual(store.tree.allPaneIDs().count, 1, "the swallowed ⌘W routed .closePane → one leaf gone")
    }

    /// While the picker is visible, ⌘2 (a global `.selectTab(2)` chord) is PASSED THROUGH to the picker (so
    /// `OpenQuicklyView.onKeyPress` can quick-pick the 2nd result) instead of being resolved as the
    /// background tab-switch. Asserted via the swallow/passthrough contract: handle returns the event.
    func testPickerVisibleYieldsQuickPickDigitChord() {
        let store = makeTwoLeafStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isOverlayCapturingKeys: { true })

        let result = dispatcher.handle(keyDown("2", keyCode: 19, command: true))

        XCTAssertNotNil(result, "⌘2 reaches the picker (quick-pick #2), not the background .selectTab")
    }

    /// The control for the digit chord: with the picker HIDDEN ⌘2 is owned by the monitor (swallowed +
    /// dispatched to `.selectTab(2)`), so handle returns `nil`. Proves the gate — not an accidental table miss
    /// — is what yields ⌘2 to the picker above.
    func testPickerHiddenOwnsQuickPickDigitChord() {
        let store = makeTwoLeafStore()
        let dispatcher = WorkspaceKeyDispatcher(store: store, isOverlayCapturingKeys: { false })

        let result = dispatcher.handle(keyDown("2", keyCode: 19, command: true))

        XCTAssertNil(result, "with no picker up ⌘2 is the global .selectTab chord (swallowed)")
    }

    /// The at-rest boundary is preserved: a BARE key passes through UNCHANGED whether or not the picker is up
    /// (the gate never swallows normal typing — it only stops the monitor from OWNING a bound chord).
    func testBareKeyPassesThroughRegardlessOfPickerState() {
        let store = makeTwoLeafStore()
        for capturing in [true, false] {
            let dispatcher = WorkspaceKeyDispatcher(store: store, isOverlayCapturingKeys: { capturing })
            let result = dispatcher.handle(keyDown("a", keyCode: 0))
            XCTAssertNotNil(result, "a bare key always reaches the focused responder (capturing=\(capturing))")
        }
    }

    // MARK: - overlay-keyboard-gate: the SCRIMMED modals + Global Search yield destructive ⌘-chords

    /// Drives the dispatcher through the REAL `overlay.capturesKeyboardWhileVisible` seam (no view) and asserts
    /// that while `present(overlay)` has a focus-stealing surface up, each destructive global chord PASSES
    /// THROUGH (handle returns the event, never swallows it) and does NOT mutate the BACKGROUND tree — neither
    /// closing a leaf (⌘W) nor minting a tab (⌘T). `name` tags the failing surface.
    ///
    /// REVERT-TO-CONFIRM-FAIL: narrow `capturesKeyboardWhileVisible` back to
    /// `openQuicklyVisible || peekReplyVisible` and every case below regresses — the
    /// scrimmed modal / Global Search no longer trips the gate, so ⌘W is swallowed + routes `.closePane`
    /// (a leaf drops) and ⌘T mints a terminal tab behind the open overlay.
    private func assertOverlayYieldsDestructiveChords(
        _ name: String, present: (OverlayCoordinator) -> Void,
    ) {
        let store = makeTwoLeafStore()
        let overlay = OverlayCoordinator(store: store)
        let dispatcher = WorkspaceKeyDispatcher(
            store: store, isOverlayCapturingKeys: { overlay.capturesKeyboardWhileVisible },
        )

        // Load-bearing control: with NOTHING up the monitor still OWNS ⌘W (swallows + would route .closePane).
        XCTAssertFalse(overlay.capturesKeyboardWhileVisible, "\(name): precondition — nothing up")

        present(overlay)
        XCTAssertTrue(
            overlay.capturesKeyboardWhileVisible, "\(name): the presented overlay must own the keyboard",
        )

        // `allPaneIDs().count` captures BOTH destructive directions: ⌘W .closePane drops a leaf, ⌘T
        // .newPane(.terminal) mints one — so while the overlay owns the keyboard it must stay PINNED.
        let leavesBefore = store.tree.allPaneIDs().count

        // ⌘W — destructive close
        let close = dispatcher.handle(keyDown("w", keyCode: 13, command: true))
        XCTAssertNotNil(close, "\(name): ⌘W is passed through to the overlay (not swallowed)")
        XCTAssertEqual(store.tree.allPaneIDs().count, leavesBefore, "\(name): ⌘W must NOT close a background pane")
        XCTAssertNil(store.pendingCloseSpec, "\(name): ⌘W must NOT even park a close behind the overlay")

        // ⌘T — new terminal pane (tree-mutating)
        let newTab = dispatcher.handle(keyDown("t", keyCode: 17, command: true))
        XCTAssertNotNil(newTab, "\(name): ⌘T is passed through to the overlay (not swallowed)")
        XCTAssertEqual(
            store.tree.allPaneIDs().count,
            leavesBefore,
            "\(name): ⌘T must NOT mint a pane behind the overlay",
        )

        // ⌘2 — background tab-switch
        let selectTab = dispatcher.handle(keyDown("2", keyCode: 19, command: true))
        XCTAssertNotNil(selectTab, "\(name): ⌘2 is passed through to the overlay (not the background tab-switch)")
    }

    /// HIGH: the four SCRIMMED modals (Command Palette / Cheat Sheet / Connect / Remote-Picker) each yield the
    /// destructive global chords through the real gate — they were in `anyModalVisible` but NOT in
    /// `capturesKeyboardWhileVisible`, so ⌘W/⌘T/⌘2 leaked to the workspace behind their scrim.
    func testScrimmedModalsYieldDestructiveChordsThroughTheRealOverlayGate() {
        assertOverlayYieldsDestructiveChords("palette") { $0.openPalette() }
        assertOverlayYieldsDestructiveChords("cheatSheet") { $0.openCheatSheet() }
        assertOverlayYieldsDestructiveChords("connect") { $0.openConnect() }
        assertOverlayYieldsDestructiveChords("remotePicker") { $0.openRemotePicker() }
    }

    /// MEDIUM: the non-scrimmed Global Search surface (whose query field holds focus) likewise yields the
    /// destructive chords — it stays OUT of `anyModalVisible` (must not dim the workspace) but is now in
    /// `capturesKeyboardWhileVisible`, so ⌘W can't destroy a pane while the user is typing a cross-tab search.
    func testGlobalSearchYieldsDestructiveChordsThroughTheRealOverlayGate() {
        assertOverlayYieldsDestructiveChords("globalSearch") { $0.openGlobalSearch() }
    }
}
#endif
