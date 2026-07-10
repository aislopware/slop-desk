import XCTest
@testable import SlopDeskClient
@testable import SlopDeskWorkspaceCore

/// The titlebar attention dot — the bell-style "something needs you" indicator next to the centre title
/// (``WorkspaceStore/hasUnseenAttention``). Visible iff ANY pane other than the focused leaf currently
/// resolves to an attention-class badge (agent blocked / unread finish / failed command) through the SAME
/// gated pipeline the sidebar rail renders (``TabBadgeGating`` + the manual tab override) — so the dot and
/// the rail can never disagree, and a badge the user silenced never lights the dot. Entirely headless
/// (`FakePaneSession`, no SwiftUI).
@MainActor
final class TitlebarAttentionDotTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    /// A store with a second, UNFOCUSED pane: split, then re-focus the original leaf.
    private func makeStoreWithBackgroundPane() throws -> (store: WorkspaceStore, focused: PaneID, background: PaneID) {
        let store = makeStore()
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let second = try XCTUnwrap(store.tree.allPaneIDs().first { $0 != first })
        store.focusPaneTree(first)
        return (store, first, second)
    }

    // MARK: - the attention-class membership pin (pure)

    /// Pins WHICH badge kinds light the dot: the "finished or waiting on you" states — never the live
    /// activity / privilege markers (a running agent is not a notification; the dot means unread, not busy).
    func testAttentionClassMembership() {
        XCTAssertTrue(TabBadgeKind.awaitingInput.needsAttention)
        XCTAssertTrue(TabBadgeKind.error.needsAttention)
        XCTAssertTrue(TabBadgeKind.completed.needsAttention)
        XCTAssertTrue(TabBadgeKind.finished.needsAttention)
        XCTAssertFalse(TabBadgeKind.running.needsAttention)
        XCTAssertFalse(TabBadgeKind.commandRunning.needsAttention)
        XCTAssertFalse(TabBadgeKind.sudo.needsAttention)
        XCTAssertFalse(TabBadgeKind.caffeinate.needsAttention)
    }

    // MARK: - the store derivation

    func testFreshStoreShowsNoDot() {
        XCTAssertFalse(makeStore().hasUnseenAttention, "an all-clear workspace keeps the titlebar bare")
    }

    func testBlockedBackgroundAgentShowsDot() throws {
        let (store, _, background) = try makeStoreWithBackgroundPane()
        store.setAgentStatus(.needsPermission, for: background)
        XCTAssertTrue(store.hasUnseenAttention, "a blocked background agent lights the dot")
    }

    func testDoneBackgroundAgentShowsDot() throws {
        let (store, _, background) = try makeStoreWithBackgroundPane()
        store.setAgentStatus(.done, for: background)
        XCTAssertTrue(store.hasUnseenAttention, "an unread agent finish lights the dot")
    }

    func testBackgroundCompletionBadgeShowsDot() throws {
        let (store, _, background) = try makeStoreWithBackgroundPane()
        store.setCompletionBadge(.failure, for: background)
        XCTAssertTrue(store.hasUnseenAttention, "a failed background command lights the dot")
        store.setCompletionBadge(.success, for: background)
        XCTAssertTrue(store.hasUnseenAttention, "an unread clean finish lights the dot too")
        store.setCompletionBadge(nil, for: background)
        XCTAssertFalse(store.hasUnseenAttention, "clearing the badge clears the dot")
    }

    /// Live-activity states are NOT notifications: a working agent / an active OSC 9;4 progress spinner on a
    /// background pane keeps the dot off (the dot means "waiting on you", not "something is happening").
    func testActivityStatesShowNoDot() throws {
        let (store, _, background) = try makeStoreWithBackgroundPane()
        store.setAgentStatus(.working, for: background)
        XCTAssertFalse(store.hasUnseenAttention, "a working agent is activity, not attention")
        store.setAgentStatus(.idle, for: background)
        store.handleProgress(PaneProgress.indeterminate, for: background)
        XCTAssertFalse(store.hasUnseenAttention, "an active progress spinner is activity, not attention")
    }

    /// A held-red OSC 9;4;2 progress ERROR resolves to the error tier — that IS attention.
    func testProgressErrorShowsDot() throws {
        let (store, _, background) = try makeStoreWithBackgroundPane()
        store.handleProgress(PaneProgress.error(percent: 40), for: background)
        XCTAssertTrue(store.hasUnseenAttention, "a held progress error lights the dot")
    }

    /// The focused leaf never lights the dot (you are looking at it); focusing AWAY from a still-blocked
    /// pane lights it, focusing BACK clears it — with no store mutation in between.
    func testFocusedPaneIsExcluded() throws {
        let (store, focused, background) = try makeStoreWithBackgroundPane()
        store.setAgentStatus(.needsPermission, for: focused)
        XCTAssertFalse(store.hasUnseenAttention, "a blocked agent on the pane you're watching needs no dot")
        store.focusPaneTree(background)
        XCTAssertTrue(store.hasUnseenAttention, "focusing away, the same blocked pane now lights the dot")
        store.focusPaneTree(focused)
        XCTAssertFalse(store.hasUnseenAttention, "focusing back clears it again")
    }

    /// While the app is INACTIVE nothing counts as focused (mirrors the B3 badge gate), so even the active
    /// leaf's attention lights the dot; returning active re-excludes it.
    func testAppInactiveCountsActiveLeaf() throws {
        let store = makeStore()
        let paneID = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.isAppActive = false
        store.setAgentStatus(.done, for: paneID)
        XCTAssertTrue(store.hasUnseenAttention, "backgrounded app ⇒ even the active leaf counts")
        store.isAppActive = true
        XCTAssertFalse(store.hasUnseenAttention, "returning active re-excludes the focused leaf")
    }

    /// The dot honours the SAME per-pane agent-badge gates as the rail: a pane whose "when complete" badge
    /// is toggled off never lights the dot for a `.done`, while awaiting-input (its own gate still on) does.
    func testAgentBadgeGatesSilenceTheDot() throws {
        let (store, _, background) = try makeStoreWithBackgroundPane()
        store.setAgentBadgeOverride(AgentBadgeGates.allOn.toggling(.whenComplete), for: background)
        store.setAgentStatus(.done, for: background)
        XCTAssertFalse(store.hasUnseenAttention, "a gated-off done badge never lights the dot")
        store.setAgentStatus(.needsPermission, for: background)
        XCTAssertTrue(store.hasUnseenAttention, "the awaiting-input gate is independent and still on")
    }

    /// A manual `tab badge --kind` override on a BACKGROUND tab drives the dot exactly like the rail: an
    /// attention-class override lights it, an activity-class override does not.
    func testManualTabBadgeOverrideDrivesDot() throws {
        let store = makeStore()
        let firstTab = try XCTUnwrap(store.tree.activeSession?.tabs.first?.id)
        store.newTab(kind: .terminal) // the new tab becomes active → the first tab is now background
        XCTAssertNotEqual(store.tree.activeSession?.activeTab?.id, firstTab, "precondition: first tab unfocused")
        store.setTabBadgeOverride(.error, for: firstTab)
        XCTAssertTrue(store.hasUnseenAttention, "an explicit error override lights the dot")
        store.setTabBadgeOverride(.running, for: firstTab)
        XCTAssertFalse(store.hasUnseenAttention, "an explicit activity override does not")
        store.setTabBadgeOverride(nil, for: firstTab)
        XCTAssertFalse(store.hasUnseenAttention)
    }
}
