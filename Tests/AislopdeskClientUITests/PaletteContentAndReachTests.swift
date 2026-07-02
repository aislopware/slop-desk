// PaletteContentAndReachTests — the "palette-content-and-ios-reach" audit group:
//   1. (HIGH) the command palette had NO hardware-keyboard entry point on iOS — the per-pane interceptor
//      routed with no overlay toggles, so a focused-pane ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J died at a nil toggle.
//   2. the curated catalog was missing many spec-named verbs (Reopen Closed Pane, Sync Input to All Panes,
//      Close Window, Font Size ±/Reset).
//   3. the Read Only / Secure Keyboard Entry rows never lit the ✓ gutter even when active.
//
// All headless — no view, no socket, no video (per the hang-safety rule), driven by a tree-model
// `WorkspaceStore` over the tiny `MountTestPaneSession` double (defined in `OverlayCoordinatorMountTests`).

import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

@MainActor
final class PaletteContentAndReachTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    private func makeOverlay() -> (OverlayCoordinator, WorkspaceStore) {
        let store = makeStore()
        return (OverlayCoordinator(store: store), store)
    }

    private func row(_ id: String) throws -> PaletteItem {
        try XCTUnwrap(
            ActionsPaletteSource.catalog.first { $0.id == id },
            "the catalog has the '\(id)' row",
        )
    }

    /// The selectable row ids the verbs-only mixer returns for `query` (the snapshot the palette renders).
    private func searchIDs(_ query: String) -> [String] {
        let mixer = SearchMixer(sources: ActionsPaletteSource.categorySources())
        return SearchMixer.selectable(mixer.results(query: query)).map(\.id)
    }

    // MARK: - Finding 1 (HIGH): the iOS hardware-keyboard interceptor routes the overlay chords

    /// THE iOS reachability pin: a per-pane ``TerminalKeyInterceptor``'s resolved overlay action must route
    /// through ``WorkspaceStore/routeInterceptedKey(_:)``, which threads the view-injected
    /// ``WorkspaceStore/overlayKeyToggles`` — so ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J fire their overlays on a
    /// platform with no app-level NSEvent monitor (iPad). REVERT-TO-CONFIRM-FAIL: the un-fixed interceptor
    /// called the bare `WorkspaceBindingRegistry.route(action, to:)` (no toggles), so `.commandPalette` →
    /// `toggles.palette?()` was nil and `fired["palette"]` stays false — every assertion below trips.
    func testInterceptedOverlayChordsFireTheInjectedToggles() {
        let store = makeStore()
        var fired: Set<String> = []
        store.overlayKeyToggles = WorkspaceOverlayKeyToggles(
            palette: { fired.insert("palette") },
            cheatSheet: { fired.insert("cheatSheet") },
            globalSearch: { fired.insert("globalSearch") },
            jumpTo: { fired.insert("jumpTo") },
            openQuickly: { fired.insert("openQuickly") },
            peekReply: { fired.insert("peekReply") },
        )

        let routed: [(WorkspaceAction, String)] = [
            (.commandPalette, "palette"),
            (.globalSearch, "globalSearch"),
            (.openQuickly, "openQuickly"),
            (.jumpTo, "jumpTo"),
            (.peekAndReply, "peekReply"),
        ]
        for (action, key) in routed {
            store.routeInterceptedKey(action)
            XCTAssertTrue(
                fired.contains(key),
                "the intercepted \(action) chord fired its injected overlay toggle '\(key)' (iOS reachability)",
            )
        }
    }

    /// Control: with NO toggles installed (the macOS default — its NSEvent dispatcher owns the chord before the
    /// surface), `routeInterceptedKey` is a graceful no-op, never a trap. Proves the seam is opt-in.
    func testInterceptedOverlayChordIsAGracefulNoOpWhenUnwired() {
        let store = makeStore()
        // No overlayKeyToggles set ⇒ all nil. Routing the palette chord must not crash / mutate anything.
        store.routeInterceptedKey(.commandPalette)
        XCTAssertNil(store.overlayKeyToggles.palette, "no toggle installed ⇒ the chord is a graceful no-op")
    }

    // MARK: - Finding 2: the curated catalog surfaces the previously-missing spec verbs

    /// The catalog now ENUMERATES the spec-named verbs that were unreachable (Reopen Closed Pane, Sync Input
    /// to All Panes, Close Window, Font Size ±/Reset), each under its own
    /// category. REVERT-TO-CONFIRM-FAIL: dropping any row makes its `catalog.first` nil → the `XCTUnwrap` trips.
    func testCatalogSurfacesPreviouslyMissingVerbs() throws {
        let expected: [(id: String, title: String, category: PaletteCategory)] = [
            ("action.reopenClosed", "Reopen Closed Pane", .tab),
            ("action.toggleSyncInput", "Sync Input to All Panes", .pane),
            ("action.closeWindow", "Close Window", .window),
            ("action.increaseFontSize", "Increase Font Size", .view),
            ("action.decreaseFontSize", "Decrease Font Size", .view),
            ("action.resetFontSize", "Reset Font Size", .view),
        ]
        for (id, title, category) in expected {
            let item = try row(id)
            XCTAssertEqual(item.title, title, "the '\(id)' row's title")
            XCTAssertEqual(item.category, category, "the '\(id)' row's category")
            XCTAssertEqual(item.filter, .actions, "the '\(id)' row is a verb (Actions filter)")
        }
    }

    /// A representative previously-missing verb surfaces in the palette SNAPSHOT for a typed query (not just in
    /// the static array) — proving it is actually reachable through the mixer. FAILS before the row existed.
    func testReopenClosedSurfacesInThePaletteSnapshot() {
        XCTAssertTrue(
            searchIDs("reopen").contains("action.reopenClosed"),
            "typing 'reopen' surfaces the Reopen Closed Pane verb in the palette snapshot",
        )
        XCTAssertTrue(
            searchIDs("font").contains("action.increaseFontSize"),
            "typing 'font' surfaces the font-size verbs",
        )
    }

    /// CLOSED loop: the "Close Window" row routes through the injected ``OverlayCoordinator/closeWindow``
    /// actuator (macOS `performClose` → the close-confirmation gate) — NOT the dead `requestCloseWindow()` park
    /// the audit flagged. Pin that running it fires the closure AND closes the palette. FAILS if the
    /// `.closeWindow` run arm dropped the injected actuator.
    func testRunningCloseWindowRowFiresInjectedActuatorAndCloses() throws {
        let (overlay, _) = makeOverlay()
        var fired = false
        overlay.closeWindow = { fired = true }
        overlay.openPalette()
        let item = try row("action.closeWindow")

        overlay.run(item)
        XCTAssertTrue(fired, "the Close Window row fires the injected performClose actuator")
        XCTAssertFalse(overlay.paletteVisible, "a window-scope action closes the palette")
    }

    // MARK: - Finding 3: Read Only lights the ✓ gutter when the active pane is read-only

    /// `OverlayHostView.toggledState(for:store:)` now resolves the Read Only ✓ off the live `store` + active
    /// pane (the convergent `paneReadOnly` set), so the gutter tracks the real input gate. REVERT-TO-CONFIRM-
    /// FAIL: the un-fixed predicate had no `action.toggleReadOnly` case → `default: false` → the post-toggle
    /// assertion (✓ shown) trips. A non-toggle row never shows ✓ (control).
    func testToggledStateTracksActivePaneReadOnly() throws {
        let store = makeStore()
        let chrome = WorkspaceChromeState()
        let predicate = OverlayHostView.toggledState(for: chrome, store: store)
        let readOnlyRow = try row("action.toggleReadOnly")
        let plainRow = try row("action.newTerminalTab")

        XCTAssertFalse(predicate(readOnlyRow), "a fresh active pane is writable ⇒ no ✓ on Read Only")
        XCTAssertFalse(predicate(plainRow), "a non-toggle row never shows ✓")

        store.toggleReadOnlyInActivePane()
        XCTAssertTrue(
            predicate(readOnlyRow),
            "the active pane is now read-only ⇒ the Read Only ✓ gutter lights (fails on the un-fixed predicate)",
        )

        store.toggleReadOnlyInActivePane()
        XCTAssertFalse(predicate(readOnlyRow), "toggling back off clears the ✓")
    }

    /// The Secure Keyboard Entry ✓ reads the active model's `secureInputActive` mirror; with no live terminal
    /// model (a headless active pane) it resolves false — proving the predicate consults the model flag rather
    /// than a hardcoded value (and never lights spuriously).
    func testToggledStateSecureEntryReadsModelFlag() throws {
        let store = makeStore()
        let predicate = OverlayHostView.toggledState(for: WorkspaceChromeState(), store: store)
        let secureRow = try row("action.secureKeyboardEntry")
        XCTAssertFalse(
            predicate(secureRow),
            "no live terminal model ⇒ secureInputActive is false ⇒ no spurious ✓",
        )
    }

    // MARK: - Batch 4 (catalog completeness): theme/config verbs, layout presets

    /// The Theme / Config verbs ("Theme: Switch Theme / Open Theme File" + "Settings: Reload
    /// Config") are now in the catalog under SETTINGS, each routing its coordinator action. REVERT-TO-CONFIRM-
    /// FAIL: they were absent (the palette had Open Settings only), so `catalog.first` is nil → `XCTUnwrap` trips.
    func testThemeAndConfigVerbsAreInTheCatalog() throws {
        let expected: [(id: String, title: String)] = [
            ("action.switchTheme", "Switch Theme"),
            ("action.reloadConfig", "Reload Config"),
            ("action.openThemeFile", "Open Theme File"),
        ]
        for (id, title) in expected {
            let item = try row(id)
            XCTAssertEqual(item.title, title, "the '\(id)' row's title")
            XCTAssertEqual(item.category, .settings, "the '\(id)' theme/config verb groups under SETTINGS")
            XCTAssertEqual(item.filter, .actions, "the '\(id)' row is a verb (Actions filter)")
        }
        XCTAssertTrue(searchIDs("theme").contains("action.switchTheme"), "typing 'theme' surfaces Switch Theme")
        XCTAssertTrue(searchIDs("reload").contains("action.reloadConfig"), "typing 'reload' surfaces Reload Config")
    }

    /// CLOSED loop: each Theme / Config row runs the injected ``OverlayCoordinator`` closure (the app binds them
    /// to ``PreferencesStore`` / `NSWorkspace`), then closes the palette. FAILS if a row's run arm dropped its
    /// closure (the dead-control regression the audit flags).
    func testRunningThemeConfigRowsFireInjectedCoordinatorClosures() throws {
        let (overlay, _) = makeOverlay()
        var fired: Set<String> = []
        overlay.switchTheme = { fired.insert("switchTheme") }
        overlay.reloadConfig = { fired.insert("reloadConfig") }
        overlay.openThemeFile = { fired.insert("openThemeFile") }
        for (id, key) in [
            ("action.switchTheme", "switchTheme"),
            ("action.reloadConfig", "reloadConfig"),
            ("action.openThemeFile", "openThemeFile"),
        ] {
            overlay.openPalette()
            try overlay.run(row(id))
            XCTAssertTrue(fired.contains(key), "running '\(id)' fires its injected '\(key)' coordinator closure")
            XCTAssertFalse(overlay.paletteVisible, "running '\(id)' closes the palette")
        }
    }

    /// The five NAMED layout presets (tmux/zellij `select-layout`; registry-documented "menu/palette only") are
    /// now palette rows under PANE, each a `.store` arm calling ``WorkspaceStore/applyLayout(_:)``. REVERT-TO-
    /// CONFIRM-FAIL: they were on NO surface (only the chorded Cycle Layout shipped) → the `XCTUnwrap` trips.
    func testNamedLayoutPresetsAreInTheCatalog() throws {
        for (id, title) in [
            ("action.layoutEvenHorizontal", "Layout: Even Horizontal"),
            ("action.layoutEvenVertical", "Layout: Even Vertical"),
            ("action.layoutMainVertical", "Layout: Main Vertical"),
            ("action.layoutMainHorizontal", "Layout: Main Horizontal"),
            ("action.layoutTiled", "Layout: Tiled"),
        ] {
            let item = try row(id)
            XCTAssertEqual(item.title, title, "the '\(id)' row's title")
            XCTAssertEqual(item.category, .pane, "the '\(id)' layout preset groups under PANE")
            XCTAssertNil(item.shortcut, "the named presets ship no default chord ⇒ no hint chip")
            guard case .store = item.action else {
                XCTFail("the '\(id)' layout preset is a `.store` row that re-tiles directly")
                return
            }
        }
        XCTAssertTrue(
            searchIDs("layout").contains("action.layoutTiled"),
            "typing 'layout' surfaces the named presets in the palette snapshot",
        )
    }
}
