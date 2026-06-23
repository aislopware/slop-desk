// L5OverlayLogicTests — view-LOGIC tests for the L5 overlay layer (command palette / modal / toast /
// context menu). Pure model + coordinator level only; NEVER instantiates Ghostty/VT/Metal/SCStream
// (hang-safety rule). Covers:
//   - SearchMixer ranking + per-filter gating + section separators + zero-state recents,
//   - PaletteAction routing (running a row mutates the store; settings/filter actions),
//   - the busy-close ConfirmModal flow via the store's pendingCloseSpec (confirm vs cancel),
//   - OverlayCoordinator toast lifecycle (push / de-dupe / cap / dismiss),
//   - ContextMenuModel action mapping (pane/tab item → store mutation).

import AislopdeskAgentDetect
import AislopdeskTransport
import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

// MARK: - Hang-safe session factories

/// A busy-shell dummy session so a close routes through the `pendingClose` confirmation guard. Mirrors
/// `DummyPaneSession` exactly, only flipping `isShellBusy` to true.
@MainActor
final class BusyPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false
    var isShellBusy: Bool { true }

    init(spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind == .remoteGUI { isVideoActive = active } }
    func pause() {}
    func resume() {}
    func teardown() {}
}

@MainActor
private func makeIdleStore() -> WorkspaceStore {
    WorkspaceStore(
        restoringTree: .defaultWorkspace(), liveModel: .tree,
        makeSession: { spec in DummyPaneSession(spec: spec) },
    )
}

@MainActor
private func makeBusyStore() -> WorkspaceStore {
    WorkspaceStore(
        restoringTree: .defaultWorkspace(), liveModel: .tree,
        makeSession: { spec in BusyPaneSession(spec: spec) },
    )
}

// MARK: - SearchMixer ranking / filtering

@MainActor
final class PaletteMixerTests: XCTestCase {
    private func mixer(_ store: WorkspaceStore) -> SearchMixer {
        SearchMixer(sources: [
            ActionsPaletteSource(),
            TabsPaletteSource.snapshot(store),
            EmptyPaletteSource(filter: .files, sectionTitle: "Files"),
        ])
    }

    func testActionsCatalogIsNonEmptyAndIncludesOpenSettings() {
        let store = makeIdleStore()
        let results = mixer(store).results(query: "")
        let ids = Set(results.map(\.id))
        XCTAssertTrue(ids.contains("action.newTerminalTab"))
        XCTAssertTrue(ids.contains("action.openSettings"))
    }

    func testQueryFiltersToMatchingRows() {
        let store = makeIdleStore()
        let results = SearchMixer.selectable(mixer(store).results(query: "split"))
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.title.lowercased().contains("split") })
    }

    func testPrefixOutranksMidWordSubstring() {
        // "New Tab" (title prefix "new") should outrank "New Remote Window Tab" for query "new".
        let store = makeIdleStore()
        let results = SearchMixer.selectable(mixer(store).results(query: "New"))
        let newTabIndex = results.firstIndex { $0.id == "action.newTerminalTab" }
        XCTAssertNotNil(newTabIndex)
        // Exact-ish prefix "New Tab" must be first among the matches.
        XCTAssertEqual(results.first?.id, "action.newTerminalTab")
    }

    func testActiveFilterGatesSourcesToTabsOnly() {
        let store = makeIdleStore()
        let results = mixer(store).results(query: "", activeFilter: .tabs)
        // Only the TABS source runs ⇒ no action rows present.
        XCTAssertFalse(results.contains { $0.id.hasPrefix("action.") })
        XCTAssertTrue(results.contains { $0.id.hasPrefix("tab.") })
    }

    func testEmptyStubSourceContributesNoRowsButRegistersFilter() {
        let store = makeIdleStore()
        let m = mixer(store)
        XCTAssertTrue(m.availableFilters.contains(.files))
        // Filtering to Files yields no rows (the stub returns []).
        XCTAssertTrue(m.results(query: "anything", activeFilter: .files).isEmpty)
    }

    func testSectionSeparatorPrecedesEachNonEmptySource() {
        let store = makeIdleStore()
        let results = mixer(store).results(query: "") // all sources, no filter
        // The first row of the Actions group is the "Actions" separator.
        XCTAssertEqual(results.first?.isSeparator, true)
        XCTAssertEqual(results.first?.title, "Actions")
        // The TABS source (non-empty: one default pane) gets its own separator too.
        XCTAssertTrue(results.contains { $0.isSeparator && $0.title == "Tabs" })
    }

    func testSelectableExcludesSeparators() {
        let store = makeIdleStore()
        let results = mixer(store).results(query: "")
        let selectable = SearchMixer.selectable(results)
        XCTAssertFalse(selectable.contains(where: \.isSeparator))
        XCTAssertLessThan(selectable.count, results.count)
    }
}

// MARK: - PaletteAction routing (running a row mutates the store)

@MainActor
final class PaletteActionRoutingTests: XCTestCase {
    func testRunningSplitRowSplitsTheActivePane() throws {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        let split = try? XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.splitRight" })
        let before = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        try coordinator.run(XCTUnwrap(split))
        let after = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        XCTAssertEqual(after, before + 1, "running the split row adds a pane")
        XCTAssertFalse(coordinator.paletteVisible, "running a row closes the palette")
    }

    func testRunningNewTabRowAddsTabAndRecordsRecent() throws {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let newTab = try? XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.newTerminalTab" })
        try coordinator.run(XCTUnwrap(newTab))
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore + 1)
        XCTAssertTrue(store.recentCommands.contains(.newPane(.terminal)), "the verb is recorded into recents")
    }

    func testOpenSettingsRowOpensSettingsAndClosesPalette() throws {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        let row = try? XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == "action.openSettings" })
        try coordinator.run(XCTUnwrap(row))
        XCTAssertTrue(coordinator.settingsVisible)
        XCTAssertFalse(coordinator.paletteVisible)
    }

    func testTabsRowFocusesThatPane() throws {
        let store = makeIdleStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        coordinator.paletteFilter = .tabs
        // Pick the FIRST pane (not currently active — split focuses the new second pane).
        let firstPane = try? XCTUnwrap(store.tree.activeSession?.activeTab?.root.allPaneIDs().first)
        let tabsSource = TabsPaletteSource.snapshot(store)
        let row = try? XCTUnwrap(
            tabsSource.candidates(query: "").first { $0.id == "tab.\(firstPane!.raw.uuidString)" },
        )
        try coordinator.run(XCTUnwrap(row))
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, firstPane)
    }

    func testKeyboardSelectionMoveAndAccept() {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        coordinator.paletteQuery = "split"
        coordinator.paletteSelection = 0
        let selectable = coordinator.selectableResults
        XCTAssertGreaterThanOrEqual(selectable.count, 1)
        // Move down stays clamped within the selectable rows.
        coordinator.moveSelection(100)
        XCTAssertEqual(coordinator.paletteSelection, selectable.count - 1)
        coordinator.moveSelection(-100)
        XCTAssertEqual(coordinator.paletteSelection, 0)
        // Accept runs the selected row (a split) and closes.
        let before = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        coordinator.acceptSelected()
        let after = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        XCTAssertEqual(after, before + 1)
        XCTAssertFalse(coordinator.paletteVisible)
    }

    func testSeparatorRowIsNoOp() {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        let sep = PaletteItem.separator("Actions", filter: .actions)
        coordinator.run(sep)
        XCTAssertTrue(coordinator.paletteVisible, "running a separator does nothing (palette stays open)")
    }

    func testZeroStateSurfacesRecents() {
        let store = makeIdleStore()
        store.recordRecentCommand(.toggleZoom)
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        coordinator.paletteQuery = ""
        let results = coordinator.paletteResults
        XCTAssertTrue(results.contains { $0.isSeparator && $0.title == "Recents" })
        // The toggle-zoom recent maps onto its catalog row.
        XCTAssertTrue(results.contains { $0.id == "action.toggleZoom" })
    }
}

// MARK: - ConfirmModal flow (pendingCloseSpec confirm / cancel)

@MainActor
final class ConfirmModalFlowTests: XCTestCase {
    func testBusyCloseParksAPendingCloseSpec() throws {
        let store = makeBusyStore()
        let pane = try? XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        store.splitActivePane(axis: .horizontal, kind: .terminal) // make it a split so it isn't last
        try store.requestClosePaneTree(XCTUnwrap(pane))
        XCTAssertNotNil(store.pendingCloseSpec, "a busy shell parks the close behind the confirm modal")
    }

    func testCancelClearsThePendingClose() throws {
        let store = makeBusyStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let pane = try? XCTUnwrap(store.tree.activeSession?.activeTab?.root.allPaneIDs().first)
        try store.requestClosePaneTree(XCTUnwrap(pane))
        XCTAssertNotNil(store.pendingCloseSpec)
        store.cancelPendingClose()
        XCTAssertNil(store.pendingCloseSpec, "cancel clears the pending close, pane stays")
    }

    func testConfirmClosesThePaneAndClearsThePending() throws {
        let store = makeBusyStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let panes = store.tree.activeSession?.activeTab?.root.allPaneIDs() ?? []
        XCTAssertEqual(panes.count, 2)
        let target = try? XCTUnwrap(panes.first)
        try store.requestClosePaneTree(XCTUnwrap(target))
        XCTAssertNotNil(store.pendingCloseSpec)
        store.confirmPendingClose()
        XCTAssertNil(store.pendingCloseSpec)
        XCTAssertFalse(try store.tree.contains(XCTUnwrap(target)), "confirm actually closes the pane")
    }
}

// MARK: - Toast lifecycle

@MainActor
final class ToastLifecycleTests: XCTestCase {
    func testPushAppendsNewestLast() {
        let c = OverlayCoordinator()
        c.pushToast(Toast(id: "a", title: "A"))
        c.pushToast(Toast(id: "b", title: "B"))
        XCTAssertEqual(c.toasts.map(\.id), ["a", "b"])
    }

    func testSameIdReplaces() {
        let c = OverlayCoordinator()
        c.pushToast(Toast(id: "x", title: "First"))
        c.pushToast(Toast(id: "x", title: "Second"))
        XCTAssertEqual(c.toasts.count, 1)
        XCTAssertEqual(c.toasts.first?.title, "Second")
    }

    func testCapEvictsOldest() {
        let c = OverlayCoordinator()
        for i in 0..<8 { c.pushToast(Toast(id: "t\(i)", title: "T\(i)")) }
        XCTAssertEqual(c.toasts.count, 4, "the stack is capped at 4")
        XCTAssertEqual(c.toasts.first?.id, "t4", "the oldest are evicted")
        XCTAssertEqual(c.toasts.last?.id, "t7")
    }

    func testDismissRemovesById() {
        let c = OverlayCoordinator()
        c.pushToast(Toast(id: "a", title: "A"))
        c.pushToast(Toast(id: "b", title: "B"))
        c.dismissToast("a")
        XCTAssertEqual(c.toasts.map(\.id), ["b"])
    }

    /// The value-level invariant the ToastCard auto-dismiss-timer fix depends on: a same-id REPLACEMENT
    /// must carry the NEW `autoDismiss`. The agent-attention bridge pushes a sticky (`autoDismiss == nil`)
    /// toast when an agent needs input, then a 4s-auto-dismiss toast (same id) when it later finishes; the
    /// replacement has to surface the new delay so `ToastCard.task(id: toast)` reschedules. The view timer
    /// itself is view-only (not observable here), so this pins the model contract the view keys on.
    func testSameIdReplacementCarriesNewAutoDismiss() {
        let c = OverlayCoordinator()
        // needsInput → sticky (no auto-dismiss).
        c.pushToast(Toast(id: "attn.x", flavor: .attention, title: "Agent", autoDismiss: nil))
        XCTAssertNil(c.toasts.first?.autoDismiss)
        // finished → same id, now auto-dismissing after 4s. The replacement must adopt the new delay.
        c.pushToast(Toast(id: "attn.x", flavor: .attention, title: "Agent", autoDismiss: .seconds(4)))
        XCTAssertEqual(c.toasts.count, 1, "same id de-dupes to one toast")
        XCTAssertEqual(c.toasts.first?.autoDismiss, .seconds(4), "the replacement carries the new autoDismiss")
        // Inverse direction: a finished (auto-dismiss) toast replaced by a needsInput (sticky) one stays.
        c.pushToast(Toast(id: "attn.x", flavor: .attention, title: "Agent", autoDismiss: nil))
        XCTAssertNil(c.toasts.first?.autoDismiss, "the sticky replacement drops the timer")
    }
}

// MARK: - Palette shortcut hints derive from the registry (no drift)

/// The ActionsPaletteSource catalog must NEVER hardcode a `shortcut:` glyph that drifts from the chord the
/// `WorkspaceKeyboardBank` actually registers. Each catalog row's hint must equal
/// `WorkspaceBindingRegistry.glyph(for:)` of its mapped action — and be `nil` when the action has no
/// registry chord (so the palette never advertises a chord that fires nothing). Proven to FAIL on the
/// pre-fix hardcoded strings (e.g. Rename showed "⌘R" but the chord is ⇧⌘R; Toggle Maximize showed "⇧⌘↩"
/// but the chord is ⌥⌘↩; Reconnect showed "⇧⌘R" but no reconnect chord exists).
@MainActor
final class PaletteShortcutDriftTests: XCTestCase {
    /// Catalog row id → the WorkspaceAction whose registry glyph it must mirror (nil ⇒ no registry chord).
    private static let expected: [(id: String, action: WorkspaceAction?)] = [
        ("action.newTerminalTab", .newTab),
        ("action.newRemoteTab", nil),
        ("action.splitRight", .splitRight),
        ("action.splitDown", .splitDown),
        ("action.closePane", .closePane),
        ("action.closeTab", .closeTab),
        ("action.toggleZoom", .toggleZoom),
        ("action.toggleSidebar", .toggleSidebar),
        ("action.renamePane", .renamePane),
        ("action.reconnect", nil),
        ("action.openSettings", nil),
        ("action.cheatSheet", .cheatSheet),
    ]

    func testEachCatalogShortcutEqualsRegistryGlyphOrNilWhenUnbound() throws {
        for (id, action) in Self.expected {
            let row = try XCTUnwrap(
                ActionsPaletteSource.catalog.first { $0.id == id }, "missing catalog row \(id)",
            )
            let expectedGlyph = action.flatMap { WorkspaceBindingRegistry.glyph(for: $0) }
            XCTAssertEqual(
                row.shortcut, expectedGlyph,
                "catalog row \(id) shortcut \(String(describing: row.shortcut)) must equal the registry "
                    + "glyph \(String(describing: expectedGlyph)) for its action",
            )
        }
    }

    /// Spot-check the concrete glyphs the drift bug got wrong, so a future hardcode regression is caught.
    func testKnownDriftedGlyphsAreNowCorrect() throws {
        func shortcut(_ id: String) throws -> String? {
            try XCTUnwrap(ActionsPaletteSource.catalog.first { $0.id == id }).shortcut
        }
        XCTAssertEqual(try shortcut("action.renamePane"), "⇧⌘R")
        XCTAssertEqual(try shortcut("action.toggleZoom"), "⌥⌘↩")
        XCTAssertNil(try shortcut("action.reconnect"), "no reconnect chord exists ⇒ no hint")
    }
}

// MARK: - Top-bar connection status pill derivation

/// The chrome must surface a down / reconnecting / unreachable host (previously `AppConnection.status` was
/// never read by any chrome view). These pin the PURE `TopBarConnectionPill` derivation the WindowTopBar +
/// WorkspaceRootView feed: a give-up state yields a visible non-empty label, a "trouble" colour role, and a
/// reconnect affordance; an in-flight state hides the manual Retry. Proven to fail before the derivation
/// existed (there was no status surface at all).
@MainActor
final class TopBarConnectionPillTests: XCTestCase {
    func testUnreachableSurfacesLabelTroubleAndReconnect() {
        let status = ConnectionStatus.unreachable
        XCTAssertFalse(TopBarConnectionPill.label(for: status).isEmpty, "unreachable shows a non-empty label")
        XCTAssertEqual(TopBarConnectionPill.colorRole(for: status), .trouble)
        XCTAssertTrue(TopBarConnectionPill.showsReconnect(for: status), "give-up state offers manual Retry")
    }

    func testFailedSurfacesLabelTroubleAndReconnect() {
        let status = ConnectionStatus.failed("huge raw NWError dump")
        XCTAssertFalse(TopBarConnectionPill.label(for: status).isEmpty)
        XCTAssertEqual(TopBarConnectionPill.colorRole(for: status), .trouble)
        XCTAssertTrue(TopBarConnectionPill.showsReconnect(for: status))
        // The compact label never dumps the raw payload into the chrome.
        XCTAssertFalse(TopBarConnectionPill.label(for: status).contains("NWError"))
    }

    func testReconnectingShowsInFlightAndHidesRetry() {
        let status = ConnectionStatus.reconnecting(attempt: 2, nextRetry: nil)
        XCTAssertFalse(TopBarConnectionPill.label(for: status).isEmpty)
        XCTAssertEqual(TopBarConnectionPill.colorRole(for: status), .inFlight)
        XCTAssertFalse(TopBarConnectionPill.showsReconnect(for: status), "the supervisor is already retrying")
    }

    func testConnectedIsConnectedRoleNoRetry() {
        XCTAssertEqual(TopBarConnectionPill.colorRole(for: .connected), .connected)
        XCTAssertFalse(TopBarConnectionPill.showsReconnect(for: .connected))
    }

    func testHelpCarriesHostAndHeadline() {
        let help = TopBarConnectionPill.help(host: "studio.local", status: .unreachable)
        XCTAssertTrue(help.contains("studio.local"))
        XCTAssertTrue(help.contains("Unreachable"))
    }
}

// MARK: - Connect-to-Host overlay (the host/port editor — D1 connect surface)

/// The rewrite deleted ConnectionGateView and left the app-global `AppConnection` form unbound by any view,
/// so a non-default host could never be entered. These pin the restored connect surface: the palette
/// "Connect to Host…" row opens the editor (and closes the palette), and the editor's Connect path is gated
/// on `canConnect` with the why-disabled `validationHint`. Proven to FAIL before the action + overlay were
/// wired (no "action.connect" row, no `connectVisible`/`openConnect()` on the coordinator).
@MainActor
final class ConnectHostOverlayLogicTests: XCTestCase {
    /// A registry whose `makeConnection` always throws — drives the failure/transition logic with no socket.
    private func failingRegistry() -> ConnectionRegistry {
        ConnectionRegistry { _, _ in throw AislopdeskTransportError.timedOut("test: connect refused") }
    }

    func testConnectPaletteRowOpensConnectOverlayAndClosesPalette() throws {
        let store = makeIdleStore()
        let coordinator = OverlayCoordinator(store: store)
        coordinator.openPalette()
        let row = try XCTUnwrap(
            ActionsPaletteSource.catalog.first { $0.id == "action.connect" },
            "the catalog must carry a Connect-to-Host action row",
        )
        XCTAssertEqual(row.title, "Connect to Host…")
        coordinator.run(row)
        XCTAssertTrue(coordinator.connectVisible, "running the row opens the host editor")
        XCTAssertFalse(coordinator.paletteVisible, "running the row closes the palette")
    }

    func testOpenAndCloseConnectToggleVisibility() {
        let coordinator = OverlayCoordinator()
        XCTAssertFalse(coordinator.connectVisible)
        coordinator.openConnect()
        XCTAssertTrue(coordinator.connectVisible)
        coordinator.closeConnect()
        XCTAssertFalse(coordinator.connectVisible)
    }

    /// The Connect button the overlay shows is gated on `canConnect`; an empty host disables it (with the
    /// why-disabled hint), and a fully-parsed form enables it. The overlay reads exactly these.
    func testConnectGateReflectsFormValidity() {
        let c = AppConnection(registry: failingRegistry())
        c.host = ""
        XCTAssertFalse(c.canConnect)
        XCTAssertEqual(c.validationHint, "Enter a host")

        c.host = "studio.local"
        c.port = "7799"
        c.mediaPort = "9000"
        c.cursorPort = "9001"
        XCTAssertTrue(c.canConnect, "a fully-parsed form enables Connect")
        XCTAssertNil(c.validationHint, "a valid form shows no why-disabled subtext")
    }

    /// The overlay's "Recent Hosts" pick fills the form (form-only — the user still presses Connect), which
    /// is the `fillForm(from:)` the menu calls. A non-default host can thus be re-selected and dialed.
    func testRecentHostPickFillsTheForm() {
        let c = AppConnection(registry: failingRegistry())
        let target = ConnectionTarget(host: "10.0.0.42", port: 7799, mediaPort: 9100, cursorPort: 9101)
        c.fillForm(from: target)
        XCTAssertEqual(c.host, "10.0.0.42")
        XCTAssertEqual(c.port, "7799")
        XCTAssertEqual(c.mediaPort, "9100")
        XCTAssertEqual(c.cursorPort, "9101")
        XCTAssertTrue(c.canConnect)
    }
}

// MARK: - ContextMenuModel action mapping

@MainActor
final class ContextMenuMappingTests: XCTestCase {
    func testPaneItemsIncludeSplitRenameReconnectClose() {
        let pane = PaneID()
        let items = ContextMenuModel.paneItems(paneID: pane, lastKnownCwd: "~/src", isInSplit: true)
        let ids = Set(items.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [
            "pane.splitRight",
            "pane.splitDown",
            "pane.rename",
            "pane.reconnect",
            "pane.close",
        ]))
        XCTAssertTrue(ids.contains("pane.copyPath"), "a known cwd adds Copy Path")
        // The close row is destructive and labeled "Close Pane" in a split.
        let close = try? XCTUnwrap(items.first { $0.id == "pane.close" })
        XCTAssertEqual(close?.role, .destructive)
        XCTAssertEqual(close?.title, "Close Pane")
    }

    func testPaneCloseLabelIsCloseTabWhenNotInSplit() {
        let items = ContextMenuModel.paneItems(paneID: PaneID(), lastKnownCwd: nil, isInSplit: false)
        let close = try? XCTUnwrap(items.first { $0.id == "pane.close" })
        XCTAssertEqual(close?.title, "Close Tab")
        XCTAssertFalse(items.contains { $0.id == "pane.copyPath" }, "no cwd ⇒ no Copy Path row")
    }

    func testPaneSplitRowMutatesTheStore() throws {
        let store = makeIdleStore()
        let pane = try? XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let items = try ContextMenuModel.paneItems(paneID: XCTUnwrap(pane), lastKnownCwd: nil, isInSplit: false)
        let split = try? XCTUnwrap(items.first { $0.id == "pane.splitRight" })
        let before = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        split?.run?(store)
        let after = store.tree.activeSession?.activeTab?.root.allPaneIDs().count ?? 0
        XCTAssertEqual(after, before + 1)
    }

    func testTabCloseRowClosesTheTab() throws {
        let store = makeIdleStore()
        store.newTab(kind: .terminal) // now 2 tabs
        let session = try? XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session?.tabs.count, 2)
        let tab = try? XCTUnwrap(session?.activeTab)
        let pane = try? XCTUnwrap(tab?.activePane)
        let items = try ContextMenuModel.tabItems(paneID: XCTUnwrap(pane), tabID: XCTUnwrap(tab?.id))
        let close = try? XCTUnwrap(items.first { $0.id == "tab.close" })
        close?.run?(store)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, 1, "closing the tab drops it")
    }

    func testSeparatorsAreNonRunnable() {
        let items = ContextMenuModel.paneItems(paneID: PaneID(), lastKnownCwd: "x", isInSplit: true)
        let separators = items.filter(\.isSeparator)
        XCTAssertFalse(separators.isEmpty)
        XCTAssertTrue(separators.allSatisfy { $0.run == nil })
    }
}
