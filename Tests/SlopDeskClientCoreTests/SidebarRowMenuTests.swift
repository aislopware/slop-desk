// SidebarRowMenuTests — the row's context MENU as a value: what is offered, and what a flip does.
//
// Lifted out of the SwiftUI row with docs/56 stage D, because the Mac now builds an `NSMenu` from the
// same table the phone builds its `.contextMenu` from. What is pinned here is the shape of that table
// (which entries, in which order, reading which state) and the two write paths — a VERB and a
// SWITCH — because a menu that offers a dead control or flips the wrong key is a bug no render shows.
//
// Headless: a tree-model `WorkspaceStore` over the `RecordingPaneSession` double (no socket / video /
// Metal — hang-safety).

import Defaults
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

@MainActor
final class SidebarRowMenuTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func activePane(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane, "the seeded session has a pane")
    }

    // MARK: - What is offered

    /// The table's SHAPE: rename, then the badge acknowledgement, then the five gate/notify switches,
    /// each pair fenced by a separator. Pinned as a whole because the order is the menu's grammar —
    /// the verbs act on THIS pane now, the switches decide what it will do next.
    func testTheMenuIsRenameThenClearThenTheFiveSwitches() throws {
        let store = makeStore()
        let pane = try activePane(store)
        let entries = SidebarRowMenu.entries(for: pane, store: store, preventSleep: nil)
        XCTAssertEqual(entries.count, 9)
        XCTAssertEqual(entries[0], .action(.rename))
        XCTAssertEqual(entries[1], .separator)
        XCTAssertEqual(entries[2], .action(.clearBadge))
        XCTAssertEqual(entries[3], .separator)
        let switches = entries.dropFirst(4).compactMap { entry -> SidebarRowSwitch? in
            guard case let .toggle(flag, _) = entry else { return nil }
            return flag
        }
        XCTAssertEqual(
            switches,
            [
                .badgeWhileProcessing, .badgeWhenComplete, .badgeWhenAwaitingInput,
                .notifyTaskComplete, .notifyAwaitInput,
            ],
        )
    }

    /// `preventSleep: nil` is a preview / pre-injection shell — the sleep row and its separator are
    /// ABSENT rather than present-and-dead. A control that does nothing is worse than no control.
    func testSleepRowIsAbsentWithoutAPreferencesStore() throws {
        let store = makeStore()
        let pane = try activePane(store)
        let without = SidebarRowMenu.entries(for: pane, store: store, preventSleep: nil)
        XCTAssertFalse(without.contains { entry in
            guard case let .toggle(flag, _) = entry else { return false }
            return flag == .preventSleep
        })
        let with = SidebarRowMenu.entries(for: pane, store: store, preventSleep: true)
        XCTAssertEqual(with.count, without.count + 2, "the row arrives behind its own separator")
        XCTAssertEqual(with[with.count - 2], .separator)
        XCTAssertEqual(with.last, .toggle(.preventSleep, isOn: true))
    }

    /// Every switch reads its CURRENT state — the menu is a picture of the pane, not a list of names.
    func testSwitchesReadTheirLiveState() throws {
        let store = makeStore()
        let pane = try activePane(store)
        let gates = store.agentBadgeGates(for: pane)
        let entries = SidebarRowMenu.entries(for: pane, store: store, preventSleep: false)
        XCTAssertTrue(entries.contains(.toggle(.badgeWhileProcessing, isOn: gates.badgeWhileProcessing)))
        XCTAssertTrue(entries.contains(.toggle(.badgeWhenComplete, isOn: gates.badgeWhenComplete)))
        XCTAssertTrue(entries.contains(.toggle(.badgeWhenAwaitingInput, isOn: gates.badgeWhenAwaitingInput)))
        XCTAssertTrue(entries.contains(.toggle(.notifyTaskComplete, isOn: Defaults[.agentNotifyTaskComplete])))
        XCTAssertTrue(entries.contains(.toggle(.notifyAwaitInput, isOn: Defaults[.agentNotifyAwaitInput])))
    }

    /// Every entry that can be clicked has a title — an `NSMenuItem` with an empty one is a blank row.
    func testEveryVerbAndSwitchIsTitled() {
        for verb in [SidebarRowVerb.rename, .clearBadge] {
            XCTAssertFalse(verb.title.isEmpty)
        }
        for flag in [
            SidebarRowSwitch.badgeWhileProcessing, .badgeWhenComplete, .badgeWhenAwaitingInput,
            .notifyTaskComplete, .notifyAwaitInput, .preventSleep,
        ] {
            XCTAssertFalse(flag.title.isEmpty)
        }
    }

    // MARK: - What a click does

    /// `Rename` opens the inline field on THIS row's tab — even a background one, which is the whole
    /// reason the verb exists beside ⌘R.
    func testRenameRequestsThisRowsTab() throws {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let tabA = try XCTUnwrap(store.tree.activeSession?.tabs.first?.id)
        let paneA = try XCTUnwrap(store.tree.activeSession?.tabs.first?.activePane)
        let rows = RailRowsBuilder.rows(for: store)
        let rowA = try XCTUnwrap(rows.first { $0.id == paneA }, "tab A has a row")
        XCTAssertNotEqual(store.tree.activeSession?.activeTabIndex, 0, "precondition: tab A is background")

        SidebarRowMenu.run(.rename, row: rowA, store: store)
        XCTAssertEqual(store.pendingTabRename, tabA)
    }

    /// `Clear Badge` acknowledges the pane's attention — the mouse twin of walking into the pane.
    func testClearBadgeDropsThePanesCompletion() throws {
        let store = makeStore()
        let pane = try activePane(store)
        store.setCompletionBadge(.failure, for: pane)
        XCTAssertNotNil(store.panePendingCompletion[pane], "precondition: the badge is up")

        let row = try XCTUnwrap(RailRowsBuilder.rows(for: store).first { $0.id == pane })
        SidebarRowMenu.run(.clearBadge, row: row, store: store)
        XCTAssertNil(store.panePendingCompletion[pane])
    }

    /// A badge gate is a PER-PANE override seeded from the pane's current EFFECTIVE gates, so the
    /// first flip preserves the other two rather than dropping them to the global default. This is the
    /// one thing about the table that is not obvious from its shape.
    func testFlippingOneBadgeGatePreservesTheOtherTwo() throws {
        let store = makeStore()
        let pane = try activePane(store)
        let before = store.agentBadgeGates(for: pane)

        SidebarRowMenu.flip(.badgeWhileProcessing, paneID: pane, store: store, togglePreventSleep: {})
        let after = store.agentBadgeGates(for: pane)
        XCTAssertEqual(after.badgeWhileProcessing, !before.badgeWhileProcessing)
        XCTAssertEqual(after.badgeWhenComplete, before.badgeWhenComplete)
        XCTAssertEqual(after.badgeWhenAwaitingInput, before.badgeWhenAwaitingInput)
    }

    /// The notify keys are GLOBAL `Defaults` — a fire-time is not a per-pane fact.
    func testNotifySwitchesFlipTheGlobalKeys() throws {
        let store = makeStore()
        let pane = try activePane(store)
        let before = Defaults[.agentNotifyTaskComplete]
        defer { Defaults[.agentNotifyTaskComplete] = before }

        SidebarRowMenu.flip(.notifyTaskComplete, paneID: pane, store: store, togglePreventSleep: {})
        XCTAssertEqual(Defaults[.agentNotifyTaskComplete], !before)
    }

    /// The SLEEP flag is handed BACK to the caller — this layer never reaches a host-local sidecar
    /// preference, which is why the entry is absent when no store was threaded in.
    func testPreventSleepIsHandedBackToTheCaller() throws {
        let store = makeStore()
        let pane = try activePane(store)
        var handedBack = 0
        SidebarRowMenu.flip(.preventSleep, paneID: pane, store: store, togglePreventSleep: { handedBack += 1 })
        XCTAssertEqual(handedBack, 1)
    }
}
