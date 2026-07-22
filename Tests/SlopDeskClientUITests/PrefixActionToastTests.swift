// PrefixActionToastTests — the prefix-fired-action announcement seam, pinned headlessly.
//
// The prefix machine's implied-⌘ fold makes ANY workspace chord reachable from two stray terminal
// keystrokes: `⌃B` (readline back-char / vi page-up) arms, and the next bare key within the timeout
// fires its ⌘-folded binding — `⌃B, ⇧i` → ⌘⇧I = "Sync Input to All Panes", SILENTLY. That silent fire
// was the "two panes leaking into each other" field report. The dispatcher now reports every
// prefix-resolved action through `onPrefixActionFired` (the app wires it to a toast naming the action);
// a DIRECT single chord must NOT fire the seam — the user typed it deliberately.
//
// Synthetic NSEvents only (no window-server resource — the hang-safety rule is about SCStream/VT/Metal).

#if os(macOS)
import AppKit
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class PrefixActionToastTests: XCTestCase {
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

    /// The default ⌃B prefix event (keyCode 11 = 'b').
    private var prefixEvent: NSEvent { keyDown("b", keyCode: 11, control: true) }

    /// `⌃B` then bare `⇧i` folds to ⌘⇧I → `.toggleSyncInput` fires AND is announced — the exact two
    /// stray-keystroke path that invisibly armed sync input in the field.
    func testPrefixFoldedSyncInputTogglesAndAnnounces() throws {
        let store = makeStore()
        var fired: [WorkspaceAction] = []
        let dispatcher = WorkspaceKeyDispatcher(store: store, onPrefixActionFired: { fired.append($0) })
        let tabID = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)

        XCTAssertNil(dispatcher.handle(prefixEvent), "the prefix is swallowed")
        // Shifted 'i': charactersIgnoringModifiers reports the shifted character "I" (keyCode 34 = 'i').
        XCTAssertNil(dispatcher.handle(keyDown("I", keyCode: 34, shift: true)), "the folded chord fires")

        XCTAssertEqual(fired, [.toggleSyncInput], "the prefix-fired action is announced exactly once")
        XCTAssertTrue(store.syncInputTabs.contains(tabID), "the fold really armed sync input for the tab")
    }

    /// A DIRECT single chord (⌘⇧I typed deliberately, no prefix) fires the action but NOT the
    /// announcement seam — the toast is for prefix resolutions only, where intent is least certain.
    func testDirectChordDoesNotAnnounce() throws {
        let store = makeStore()
        var fired: [WorkspaceAction] = []
        let dispatcher = WorkspaceKeyDispatcher(store: store, onPrefixActionFired: { fired.append($0) })
        let tabID = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)

        XCTAssertNil(dispatcher.handle(keyDown("I", keyCode: 34, command: true, shift: true)))
        XCTAssertTrue(store.syncInputTabs.contains(tabID), "the direct chord still toggles")
        XCTAssertEqual(fired, [], "a deliberate single chord is not announced")
    }

    /// An UNBOUND armed follow-up (disarm + swallow) announces nothing — no action fired.
    func testUnboundFollowUpAnnouncesNothing() {
        let store = makeStore()
        var fired: [WorkspaceAction] = []
        let dispatcher = WorkspaceKeyDispatcher(store: store, onPrefixActionFired: { fired.append($0) })

        XCTAssertNil(dispatcher.handle(prefixEvent))
        XCTAssertNil(dispatcher.handle(keyDown("q", keyCode: 12)), "unbound armed key is swallowed")
        XCTAssertEqual(fired, [], "no action, no announcement")
    }

    /// Every announced action resolves to a HUMAN-READABLE registry title (the app's toast body relies
    /// on this lookup) — pinned for the sync-input binding specifically.
    func testAnnouncedActionResolvesToRegistryTitle() {
        let title = WorkspaceBindingRegistry.allBindings.first { $0.action == .toggleSyncInput }?.title
        XCTAssertEqual(title, "Sync Input to All Panes")
    }
}
#endif
