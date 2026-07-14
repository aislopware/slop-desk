// OverlayCoordinatorMountTests — pins the overlay coordinator's mount wiring at the model level. (The ⌘⇧P / ⌘/ GUI
// press + toast emission are acceptance-tested in `check-macos.sh`; these pin the contract the app's
// wiring depends on so a refactor can't silently sever it.)
//
// The app builds an `OverlayCoordinator` in `SlopDeskClientApp.init()`, injects `connectionTarget`, threads
// `togglePalette`/`toggleCheatSheet` into the macOS `WorkspaceKeyDispatcher`, and routes the store's
// background-event sinks through `pushToast`. These exercise the SAME coordinator surface — headless, no
// video/Metal/SCStream (hang-safety rule), over a tree-model `WorkspaceStore` + tiny fake session.

import SlopDeskAgentDetect
import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class OverlayCoordinatorMountTests: XCTestCase {
    /// Builds the coordinator the way the app does: headless tree-model store, `connectionTarget` seam
    /// injected. No socket, no video — the fake session never opens one.
    private func makeCoordinator() -> (OverlayCoordinator, WorkspaceStore) {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
        let overlay = OverlayCoordinator(store: store)
        overlay.connectionTarget = { store.tree.activeSession?.connection ?? .default }
        return (overlay, store)
    }

    // MARK: - The dispatcher + menu toggle drive `paletteVisible`

    /// The ⌘⇧P toggle the app threads into `WorkspaceKeyDispatcher` is `overlay.togglePalette()`. Pin
    /// open-then-close, and that `closePalette()` clears the transient query/filter/selection so the next
    /// open starts clean (the dispatcher fires the SAME closure each press).
    func testTogglePaletteOpensAndCloses() {
        let (overlay, _) = makeCoordinator()
        XCTAssertFalse(overlay.paletteVisible, "the palette starts hidden")

        overlay.togglePalette()
        XCTAssertTrue(overlay.paletteVisible, "the first ⌘⇧P toggle opens the palette")

        // Dirty the transient state, then toggle closed — close must reset it.
        overlay.paletteQuery = "split"
        overlay.paletteFilter = .actions
        overlay.paletteSelection = 3
        overlay.togglePalette()
        XCTAssertFalse(overlay.paletteVisible, "the second ⌘⇧P toggle closes the palette")
        XCTAssertEqual(overlay.paletteQuery, "", "close clears the query")
        XCTAssertNil(overlay.paletteFilter, "close clears the active filter")
        XCTAssertEqual(overlay.paletteSelection, 0, "close resets the keyboard selection")
    }

    // MARK: - Opening the palette resolves the focused pane's cwd (populates the WD pill)

    /// Opening the palette EAGERLY resolves the focused pane's cwd so the WORKING DIRECTORY
    /// header's cwd pill populates even on a fresh prompt (no OSC 133;D completion yet) with the Details/Info
    /// tab closed — the case the two lazy `lastKnownCwd` writers left blank. The app binds
    /// `overlay.resolveActiveCwd` (in `WorkspaceRootView`) to the live `cwd()` RPC → `store.setLastKnownCwd`.
    /// Pin that `openPalette()` AND the ⌘⇧P toggle's open path BOTH fire it. REVERT-TO-CONFIRM-FAIL: drop the
    /// `resolveActiveCwd()` call from `openPalette()` and `fired` stays 0.
    func testOpenPaletteFiresActiveCwdResolution() {
        let (overlay, _) = makeCoordinator()
        var fired = 0
        overlay.resolveActiveCwd = { fired += 1 }

        overlay.openPalette()
        XCTAssertEqual(fired, 1, "openPalette kicks the focused pane's cwd resolution (populates the WD pill)")

        // The ⌘⇧P toggle routes through openPalette, so its open path resolves the cwd too.
        overlay.closePalette()
        overlay.togglePalette()
        XCTAssertEqual(fired, 2, "the ⌘⇧P toggle's open path also resolves the cwd")
    }

    // MARK: - `rankedResults` carries the fzf highlight ranges the view needs

    /// The PaletteView highlights the matched code points from ``RankedRow/titleRanges``; that wiring only
    /// works if `rankedResults` is sourced from `mixer.ranked(...)` (NOT the range-less `paletteResults`).
    /// Pin that a typed query yields a top row over the EXACT catalog title with ranges that reconstruct the
    /// matched substring — a version that dropped the ranges (or wrapped `paletteResults`) would fail here.
    func testRankedResultsCarryHighlightRanges() throws {
        let (overlay, _) = makeCoordinator()
        overlay.openPalette()
        overlay.paletteQuery = "split"

        let firstAction = try XCTUnwrap(
            overlay.rankedResults.first { !$0.item.isSeparator },
            "a 'split' query yields at least one selectable result",
        )
        XCTAssertEqual(
            firstAction.item.title,
            "Split Pane Right",
            "fzf ranks the exact-prefix catalog row first",
        )
        XCTAssertFalse(
            firstAction.titleRanges.isEmpty,
            "the ranked row carries fzf highlight ranges (proves the mixer.ranked wiring)",
        )
        let matched = firstAction.titleRanges.map { String(firstAction.item.title[$0]) }.joined()
        XCTAssertEqual(
            matched,
            "Split",
            "the highlighted code points are the matched query characters, not the whole title",
        )
    }

    /// The zero-state (empty query) has no fzf matches, so its rows must be range-less wrappers — but still
    /// present, sectioned, and mirroring `paletteResults` so the palette is never blank on open.
    func testRankedResultsZeroStateMirrorsPaletteResultsWithoutRanges() {
        let (overlay, _) = makeCoordinator()
        overlay.openPalette()

        let ranked = overlay.rankedResults
        XCTAssertEqual(
            ranked.map(\.item.id),
            overlay.paletteResults.map(\.id),
            "rankedResults mirrors paletteResults row-for-row in the zero-state",
        )
        XCTAssertTrue(
            ranked.allSatisfy(\.titleRanges.isEmpty),
            "the empty-query zero-state carries no highlight ranges",
        )
    }

    /// Regression: once a recents-worthy command has run, the zero-state shows the SAME catalog
    /// verb under both "Recents" and "Actions". The two rows MUST carry distinct ids — a duplicate id is
    /// SwiftUI's documented "the ID occurs multiple times … undefined results" (`ForEach` + `.id(_:)`
    /// drop/mis-diff rows, `proxy.scrollTo` resolves an ambiguous target). Pin that every zero-state row id is
    /// unique with a populated recents ring, that the recents row is `recent.*`-namespaced, and that the
    /// catalog row still appears under Actions.
    func testZeroStateRowIDsUniqueWithRecents() {
        let (overlay, store) = makeCoordinator()
        // Populate the recents ring the way the store chokepoint does when these verbs run.
        store.recordRecentCommand(.closePane)
        store.recordRecentCommand(.newPane(.terminal))
        overlay.openPalette()

        let ids = overlay.rankedResults.map(\.id)
        XCTAssertEqual(
            Set(ids).count, ids.count,
            "every zero-state row id is unique — recents are namespaced so they can't collide with the catalog",
        )
        XCTAssertTrue(
            ids.contains("recent.action.newTerminalTab"),
            "the recent New-Tab row is namespaced into the recent.* id space",
        )
        XCTAssertTrue(
            ids.contains("action.newTerminalTab"),
            "the catalog New-Tab row still appears under Actions with its bare id",
        )
    }

    /// The namespaced recents row is cosmetic only — its `action` is the catalog verb, so accepting it still
    /// mutates the store. The zero-state now LEADS with WORKING DIRECTORY (Copy Path), so the MRU recents row
    /// is no longer index 0; locate it and pin that running it performs the New-Tab action.
    func testNamespacedRecentRowStillRunsCatalogAction() throws {
        let (overlay, store) = makeCoordinator()
        store.recordRecentCommand(.newPane(.terminal))
        overlay.openPalette()

        let recentIndex = try XCTUnwrap(
            overlay.selectableResults.firstIndex { $0.id == "recent.action.newTerminalTab" },
            "the namespaced MRU recents row is present among the selectable zero-state rows",
        )
        let before = store.tree.activeSession?.tabs.count ?? 0
        overlay.paletteSelection = recentIndex
        overlay.acceptSelected()
        let after = store.tree.activeSession?.tabs.count ?? 0
        XCTAssertEqual(after, before + 1, "accepting the namespaced recents row still runs the catalog New-Tab verb")
    }

    // MARK: - The ⌘⇧P palette is VERBS-ONLY (no filter chips, no jump-to sources)

    /// ⌘⇧P is the Command Palette (verbs) — the per-domain filter chips + the Tabs/Files/Conversations/Repos
    /// jump-to belong to Open Quickly (⌘⇧O), now a SEPARATE surface. Pin that command mode mixes ONLY
    /// the action sources (`availableFilters == [.actions]`) and that no jump-to row or section leaks in —
    /// even with a second pane a Tabs source WOULD have surfaced. Fails on a palette that still registered the
    /// Tabs/Files multi-source providers (the dead `multiSource` mixer branch) under ⌘⇧P.
    func testCommandPaletteIsVerbsOnlyWithNoFilterChips() {
        let (overlay, store) = makeCoordinator()
        store.newTab(kind: .terminal) // a 2nd pane a Tabs jump-to source WOULD surface — proves it's excluded

        overlay.openPalette(mode: .command)

        XCTAssertEqual(
            overlay.mixer?.availableFilters, [.actions],
            "only the Actions category sources are mixed under ⌘⇧P (no Tabs/Files/Conversations/Repos)",
        )

        // No jump-to section separators, and every selectable zero-state row is an action verb.
        let separatorTitles = Set(overlay.rankedResults.filter(\.item.isSeparator).map(\.item.title))
        XCTAssertFalse(separatorTitles.contains("Tabs"), "no Tabs section under ⌘⇧P")
        XCTAssertFalse(separatorTitles.contains("Files"), "no Files section under ⌘⇧P")
        XCTAssertFalse(separatorTitles.contains("Conversations"), "no Conversations section under ⌘⇧P")
        for row in overlay.selectableResults {
            XCTAssertEqual(row.filter, .actions, "row \(row.id) is a verb, not a jump-to result")
            XCTAssertFalse(row.id.hasPrefix("tab."), "row \(row.id) is not a Tabs jump-to row")
        }
    }

    /// "grouped by section": the verbs-only zero-state LEADS with the WORKING DIRECTORY section (which
    /// owns the cwd badge in the view) carrying the client-side Copy Path row, and the catalog is grouped into
    /// multiple categories. Also pins that the removed Details-panel / Git-window rows stay gone. Fails on the
    /// old flat catalog.
    func testZeroStateLeadsWithWorkingDirectoryAndGroupsByCategory() throws {
        let (overlay, _) = makeCoordinator()
        overlay.openPalette()

        let firstSeparator = try XCTUnwrap(
            overlay.rankedResults.first(where: \.item.isSeparator),
            "the zero-state opens with a section header",
        )
        XCTAssertEqual(
            firstSeparator.item.title, PaletteCategory.workingDirectory.label,
            "the palette LEADS with the WORKING DIRECTORY section (it owns the cwd badge)",
        )

        // The Copy Path row sits in the Working Directory category with the doc.on.doc icon.
        let copyPath = try XCTUnwrap(
            ActionsPaletteSource.catalog.first { $0.id == "action.copyPath" },
            "the catalog has a client-side Copy Path row",
        )
        XCTAssertEqual(copyPath.category, .workingDirectory)
        XCTAssertEqual(copyPath.icon, "doc.on.doc")

        // The retired inspector-era rows stay gone: Details: Info / Toggle Details Panel (the panel) and
        // Git Status (the auxiliary window, removed with it).
        for retired in ["action.detailsInfo", "action.toggleInspector", "action.gitStatus"] {
            XCTAssertNil(
                ActionsPaletteSource.catalog.first { $0.id == retired },
                "the removed \(retired) palette row is gone",
            )
        }

        // The catalog spans more than one category (it is no longer one flat "Actions" list).
        let categories = Set(ActionsPaletteSource.catalog.compactMap(\.category))
        XCTAssertTrue(
            categories.isSuperset(of: [.workingDirectory, .pane, .tab, .view, .settings]),
            "the catalog is grouped across multiple categories, not one flat Actions list",
        )
    }

    // MARK: - The keyboard selection stays valid when the query narrows (the clamp fix)

    /// The bug: the selection index isn't reset when the query changes, so after a query NARROWS (fewer ranked
    /// rows) a parked index points past the end — the highlight vanishes and ↩ becomes a silent no-op
    /// (`acceptSelected` guards `selection < rows.count`). The fix resets the selection to the first row on
    /// every query change. FAILS on the un-fixed coordinator: the parked index survives the narrowing (out of
    /// range), so the clamp assertion trips AND ↩ runs nothing (tab count unchanged).
    func testSelectionResetsWhenQueryNarrowsSoReturnStillActivates() {
        let (overlay, store) = makeCoordinator()
        overlay.openPalette()

        // Broad query → several selectable rows; park the highlight on the LAST one.
        overlay.paletteQuery = "a"
        let broad = overlay.selectableResults.count
        XCTAssertGreaterThan(broad, 2, "the broad query yields several rows to park a high index on")
        overlay.paletteSelection = broad - 1

        // Narrow to a query with strictly fewer rows — the parked index is now out of range.
        overlay.paletteQuery = "New Tab"
        let narrow = overlay.selectableResults.count
        XCTAssertGreaterThanOrEqual(narrow, 1, "the narrowed query still has a row to run")
        XCTAssertLessThan(narrow, broad, "the narrowed query has fewer rows than the parked index (broad-1 ≥ narrow)")

        // The fix: the selection is clamped back into range on the query change.
        XCTAssertTrue(
            overlay.paletteSelection >= 0 && overlay.paletteSelection < narrow,
            "the selection lands on a valid row after the query narrowed (fails on the un-fixed coordinator)",
        )

        // …and ↩ activates the highlighted action (the top New-Tab row) instead of silently doing nothing.
        XCTAssertEqual(
            overlay.selectableResults.first?.id, "action.newTerminalTab",
            "the narrowed query's top row is the New-Tab verb",
        )
        let before = store.tree.activeSession?.tabs.count ?? 0
        overlay.acceptSelected()
        let after = store.tree.activeSession?.tabs.count ?? 0
        XCTAssertEqual(after, before + 1, "↩ runs the highlighted action after the query narrowed (no silent no-op)")
    }

    // MARK: - ⌘↩ keep-open chaining vs plain ↩ close

    /// `acceptSelectedKeepingOpen()` (the ⌘↩ chord) RUNS the selected `.store` row but leaves the palette
    /// open so the user can chain; plain `acceptSelected()` (↩) runs AND closes. Pin both — the prior `run`
    /// always closed, so keep-open would fail against the un-factored coordinator.
    func testAcceptKeepOpenChains() {
        let (overlay, store) = makeCoordinator()
        overlay.openPalette()
        overlay.paletteQuery = "New Tab"
        overlay.paletteSelection = 0

        // Sanity: the selected row is the New-Tab action (a `.store` mutation), not a separator/overlay row.
        XCTAssertEqual(
            overlay.selectableResults.first?.id,
            "action.newTerminalTab",
            "the 'New Tab' query selects the New-Tab action row",
        )

        let before = store.tree.activeSession?.tabs.count ?? 0
        overlay.acceptSelectedKeepingOpen()
        XCTAssertTrue(overlay.paletteVisible, "⌘↩ keep-open leaves the palette open for chaining")
        let afterKeepOpen = store.tree.activeSession?.tabs.count ?? 0
        XCTAssertEqual(
            afterKeepOpen,
            before + 1,
            "the selected .store action still ran under keep-open (a new tab was added)",
        )

        // Plain ↩ on the still-selected row runs once more AND closes.
        overlay.acceptSelected()
        XCTAssertFalse(overlay.paletteVisible, "plain ↩ runs the action and closes the palette")
        let afterClose = store.tree.activeSession?.tabs.count ?? 0
        XCTAssertEqual(afterClose, afterKeepOpen + 1, "plain ↩ also ran the action exactly once")
    }

    // MARK: - Keyboard audit: "Open Settings" routes through the injected openSettings action

    /// The palette "Open Settings" row + the agent footer's settings hook both call
    /// `overlay.openSettings()`, which invokes the injected `openSettingsAction` (the app binds it to the SwiftUI
    /// `openSettings` environment action → the stock Settings scene) rather than merely flipping a
    /// `settingsVisible` flag no view observes. Pin that `openSettings()` fires the
    /// closure AND that running the "Open Settings" palette row routes through it. REVERT-TO-CONFIRM-FAIL:
    /// restore `openSettings()` to set a flag instead of calling `openSettingsAction` and `fired` stays 0.
    func testOpenSettingsFiresInjectedAction() throws {
        let (overlay, _) = makeCoordinator()
        var fired = 0
        overlay.openSettingsAction = { fired += 1 }

        overlay.openSettings()
        XCTAssertEqual(fired, 1, "openSettings() invokes the injected openSettings action")

        // The palette "Open Settings" row (PaletteAction.openSettings) routes through openSettings().
        let row = try XCTUnwrap(
            ActionsPaletteSource.catalog.first { $0.id == "action.openSettings" },
            "the palette catalog has an Open Settings row",
        )
        overlay.run(row)
        XCTAssertEqual(fired, 2, "running the Open Settings palette row also opens Settings via the action")
    }

    /// With no action injected (tests / previews / a pre-`onAppear` scene) `openSettings()` is a graceful
    /// no-op — never a trap, never a crash.
    func testOpenSettingsIsGracefulNoOpWithoutInjectedAction() {
        let (overlay, _) = makeCoordinator()
        overlay.openSettings() // must not crash with no action bound
    }

    /// The ⌘/ toggle the app threads is `overlay.toggleCheatSheet()`. Pin open/close parity.
    func testToggleCheatSheetOpensAndCloses() {
        let (overlay, _) = makeCoordinator()
        XCTAssertFalse(overlay.cheatSheetVisible)
        overlay.toggleCheatSheet()
        XCTAssertTrue(overlay.cheatSheetVisible, "⌘/ opens the cheat sheet")
        overlay.toggleCheatSheet()
        XCTAssertFalse(overlay.cheatSheetVisible, "⌘/ again closes it")
    }

    // MARK: - The Open-Quickly picker state (the ⌘⇧O / ⌘J closures the app threads)

    /// ⌘⇧O is `overlay.toggleOpenQuickly(filter: .all)`. Pin that the first press opens the picker on the
    /// merged `.all` list and the second closes it — the SAME closure the dispatcher fires each press. The
    /// picker starts hidden and defaults to `.all` (the ⌘⇧O entry). Fails on a coordinator that still owns the
    /// legacy `jumpToVisible`/`toggleJumpTo()` (no filter) instead of the Open-Quickly state.
    func testToggleOpenQuicklyOpensAtAllAndCloses() {
        let (overlay, _) = makeCoordinator()
        XCTAssertFalse(overlay.openQuicklyVisible, "the picker starts hidden")
        XCTAssertEqual(overlay.openQuicklyFilter, .all, "it defaults to the merged All pill")

        overlay.toggleOpenQuickly(filter: .all)
        XCTAssertTrue(overlay.openQuicklyVisible, "⌘⇧O opens the picker")
        XCTAssertEqual(overlay.openQuicklyFilter, .all, "⌘⇧O lands on All")

        overlay.toggleOpenQuickly(filter: .all)
        XCTAssertFalse(overlay.openQuicklyVisible, "⌘⇧O again closes the picker")
    }

    /// ⌘J is re-pointed to `overlay.toggleOpenQuickly(filter: .current)` — the folded-in Jump-To. Pin
    /// that it opens the picker pre-selected on the `.current` pill (NOT `.all`), so the focused-pane links +
    /// command index show first. Fails if ⌘J opened to the wrong pill or didn't carry the filter through.
    func testToggleOpenQuicklyCurrentOpensOnTheCurrentPill() {
        let (overlay, _) = makeCoordinator()
        overlay.toggleOpenQuickly(filter: .current)
        XCTAssertTrue(overlay.openQuicklyVisible, "⌘J opens the picker")
        XCTAssertEqual(overlay.openQuicklyFilter, .current, "⌘J lands on the Current pill (the folded Jump-To)")
    }

    /// `openOpenQuickly(filter:)` presents at a pill; `setOpenQuicklyFilter(_:)` switches the pill WITHOUT
    /// closing (the Tab/⇧Tab cycle + the picker-local pill chords drive it). Pin both, plus `closeOpenQuickly`.
    func testSetOpenQuicklyFilterSwitchesPillWithoutClosing() {
        let (overlay, _) = makeCoordinator()
        overlay.openOpenQuickly(filter: .all)
        XCTAssertTrue(overlay.openQuicklyVisible)

        overlay.setOpenQuicklyFilter(.folders)
        XCTAssertEqual(overlay.openQuicklyFilter, .folders, "the pill switched")
        XCTAssertTrue(overlay.openQuicklyVisible, "switching the pill does NOT close the picker")

        overlay.setOpenQuicklyFilter(.agents)
        XCTAssertEqual(overlay.openQuicklyFilter, .agents)
        XCTAssertTrue(overlay.openQuicklyVisible)

        overlay.closeOpenQuickly()
        XCTAssertFalse(overlay.openQuicklyVisible, "closeOpenQuickly dismisses the picker")
    }

    /// The app constructs a client-side `FolderFrecencyStore` and attaches it like the store. Pin that
    /// `attach(folders:)` wires the reference the Open-Quickly Folders pill reads. A held-strong store
    /// is required because the coordinator keeps it weakly (the app owns it).
    func testAttachFoldersStoreWiresTheReference() {
        let (overlay, _) = makeCoordinator()
        XCTAssertNil(overlay.folders, "no Folders store until the app attaches one")

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oq-folders-\(UUID().uuidString).json")
        let folders = FolderFrecencyStore(fileURL: tempURL)
        overlay.attach(folders: folders)
        XCTAssertTrue(overlay.folders === folders, "attach(folders:) wires the app-owned frecency store")
    }

    // MARK: - The ⇧⌘F Global Search overlay flag

    /// The ⇧⌘F toggle the app threads into the key dispatcher + the View menu is `overlay.toggleGlobalSearch()`.
    /// Pin that it opens, that `openGlobalSearch()`/`closeGlobalSearch()` flip the flag, and that the dispatcher
    /// firing the SAME closure each press toggles cleanly (the wiring the app's closure depends on).
    func testToggleGlobalSearchOpensAndCloses() {
        let (overlay, _) = makeCoordinator()
        XCTAssertFalse(overlay.globalSearchVisible, "the Global Search surface starts hidden")

        overlay.toggleGlobalSearch()
        XCTAssertTrue(overlay.globalSearchVisible, "the first ⇧⌘F toggle opens Global Search")
        overlay.toggleGlobalSearch()
        XCTAssertFalse(overlay.globalSearchVisible, "the second ⇧⌘F toggle closes it")

        overlay.openGlobalSearch()
        XCTAssertTrue(overlay.globalSearchVisible, "openGlobalSearch() presents the surface")
        overlay.closeGlobalSearch()
        XCTAssertFalse(overlay.globalSearchVisible, "closeGlobalSearch() dismisses it")
    }

    /// Global Search is a NON-scrimmed full surface, so it must be EXCLUDED from
    /// `anyModalVisible` (else the host would dim the workspace behind it). Pin that opening it does NOT flip the
    /// modal gate — this FAILS if a refactor folds `globalSearchVisible` into `anyModalVisible`.
    func testGlobalSearchIsNotAModal() {
        let (overlay, _) = makeCoordinator()
        XCTAssertFalse(overlay.anyModalVisible)
        overlay.openGlobalSearch()
        XCTAssertTrue(overlay.globalSearchVisible, "the surface is up")
        XCTAssertFalse(
            overlay.anyModalVisible,
            "Global Search is a non-scrimmed surface — it must not register as a focus-stealing modal",
        )
    }

    /// `openGlobalSearch(seed:)` with a non-empty selection seed runs the store search so the surface shows
    /// results immediately (⇧⌘F pre-fills with the current selection), and the store retains the seed as the
    /// live query. A nil/empty seed leaves the store's last query untouched (it restores the prior results).
    func testOpenGlobalSearchSeedRunsTheStoreSearch() {
        let (overlay, store) = makeCoordinator()
        XCTAssertEqual(store.globalSearchQuery, "", "no search has run yet")

        overlay.openGlobalSearch(seed: "needle")
        XCTAssertTrue(overlay.globalSearchVisible)
        XCTAssertEqual(store.globalSearchQuery, "needle", "a seed runs the store search with that query")
        XCTAssertNotNil(store.globalSearch, "the seeded run populated the in-memory results")

        overlay.closeGlobalSearch()
        overlay.openGlobalSearch(seed: "   ")
        XCTAssertEqual(
            store.globalSearchQuery, "needle",
            "a blank seed does NOT clobber the retained query (⇧⌘F restores the last results)",
        )
    }

    // MARK: - The cheat sheet's data source (categories + glyph chips)

    /// `KeyboardCheatSheetView` renders ``WorkspaceBindingRegistry/groupedForDisplay`` as one section per
    /// category. Pin the four categories in their fixed display order — a reorder / dropped section would
    /// silently rearrange (or hide) a whole chunk of the cheat sheet.
    func testCheatSheetDataCoversCategories() {
        let categories = WorkspaceBindingRegistry.groupedForDisplay.map(\.category)
        XCTAssertEqual(
            categories,
            [.panes, .tabs, .focus, .view],
            "the cheat sheet renders the four categories in their fixed display order",
        )
        // No section is empty (every category contributes at least one row) — an empty group is dropped by
        // `groupedForDisplay`, so the count matching the category list proves none collapsed to nothing.
        XCTAssertTrue(
            WorkspaceBindingRegistry.groupedForDisplay.allSatisfy { !$0.bindings.isEmpty },
            "every rendered section has at least one binding row",
        )
    }

    /// The chip-rendering contract the view depends on: a chord-bearing row resolves a non-empty glyph from
    /// the registry (the chips), while the chord-LESS rows render NO chip. Those are the collapsed ⌘1…⌘9
    /// representative + chord-less Rename Tab + chord-less Close Tab (⌘⇧W was re-scoped onto Close Window,
    /// leaving Close Tab reachable only via the ⌘W cascade / palette, see DECISIONS.md) + the three view
    /// toggles `Read Only` + `Secure Keyboard Entry` + `Vi Mode Key Hints` + the `Pin Window` toggle —
    /// all palette/menu-only, `chord: nil` (bindable in Settings → Keybindings; Pin Window pinned chord-less
    /// by `WorkspaceBindingRoutingTests`). The representative bakes its hint into its title instead. The trap:
    /// `glyph(for:)` of the representative's stand-in `.selectTab(1)` action resolves the REAL ⌘1 binding, so
    /// the view MUST gate on the row's own `chord` (not the action's glyph) or it stamps a "⌘1" chip onto the
    /// "Select Tab (⌘1…⌘9)" row.
    func testCheatSheetGlyphChipsGateOnRowChord() {
        let rows = WorkspaceBindingRegistry.groupedForDisplay.flatMap(\.bindings)

        // The chord-less rows are EXACTLY the representative + Rename Tab + Close Tab + the three view
        // toggles + the Hint to Reveal verb + the Pin Window toggle (all palette/menu-only, no key).
        let chordLessIDs = Set(rows.filter { $0.chord == nil }.map(\.id))
        XCTAssertEqual(
            chordLessIDs,
            [
                "tab.selectN", "pane.rename", "tab.close",
                "view.readOnly", "view.secureKeyboardEntry", "view.viKeyHints",
                // Hint to Reveal in Finder is chord-less.
                "view.hintReveal",
                // Pin Window is chord-less (the "View ▸ Pin Window" toggle ships no default chord).
                "view.pinWindow",
                // Release Stuck Input is chord-less (the remote-GUI escape hatch —
                // palette/menu-only; pinned by `TreeCommandRoutingTests`).
                "view.releaseStuckInput",
            ],
            "the no-chip rows: collapsed select-tab representative + chord-less Rename/Close Tab "
                + "+ the three E17 view toggles + E10 Hint to Reveal + E19 Pin Window",
        )

        // Every chord-bearing row resolves a non-empty glyph (the chips) — no drift between display + chord.
        for row in rows where row.chord != nil {
            let glyph = WorkspaceBindingRegistry.glyph(for: row.action)
            XCTAssertNotNil(glyph, "the chord-bearing row \(row.id) resolves a glyph for its chip(s)")
            XCTAssertFalse(glyph?.isEmpty ?? true, "the glyph for \(row.id) is non-empty")
        }

        // The representative carries its range in the title and has no chord — yet its action's glyph resolves
        // the real ⌘1 binding, which is exactly why the view gates on `chord == nil` (no chip) here.
        let representative = WorkspaceBindingRegistry.selectTabRepresentative
        XCTAssertNil(representative.chord, "the ⌘1…⌘9 representative has no single chord (renders no chip)")
        XCTAssertTrue(
            representative.title.contains("⌘1") && representative.title.contains("⌘9"),
            "the representative bakes the ⌘1…⌘9 range into its title",
        )
        XCTAssertEqual(
            WorkspaceBindingRegistry.glyph(for: representative.action),
            "⌘1",
            "the representative's stand-in action resolves the real ⌘1 binding — proving the chord gate is needed",
        )
    }

    // MARK: - The pill onTap / openConnect() route opens the connect overlay

    /// `WorkspaceRootView.openConnect()` (the iOS pill `onTap`) calls `overlay.openConnect()`. Pin the flag.
    func testOpenConnectShowsConnectOverlay() {
        let (overlay, _) = makeCoordinator()
        XCTAssertFalse(overlay.connectVisible)
        overlay.openConnect()
        XCTAssertTrue(overlay.connectVisible, "the connection pill's openConnect() shows the Connect overlay")
        overlay.closeConnect()
        XCTAssertFalse(overlay.connectVisible)
    }

    // MARK: - The injected `connectionTarget` seam resolves the live host

    /// The app injects `overlay.connectionTarget = { appConnection?.target ?? .default }` so the
    /// remote-window picker queries the live host. Pin that a non-default injected target flows through.
    func testConnectionTargetInjectionResolves() {
        let overlay = OverlayCoordinator()
        XCTAssertEqual(
            overlay.connectionTarget().host,
            ConnectionTarget.default.host,
            "the default seam resolves the default host",
        )
        let custom = ConnectionTarget(host: "10.0.0.7", port: 7000)
        overlay.connectionTarget = { custom }
        XCTAssertEqual(
            overlay.connectionTarget(),
            custom,
            "the app-injected connectionTarget closure resolves the live target",
        )
    }

    // MARK: - The store→toast emitters' model (de-dupe + cap)

    /// The emitters push a `Toast` with a stable `pane.<key>` id so a newer event REPLACES the prior
    /// one for that pane, and the stack is capped at 4 (oldest evicted). Pin both at the model level — the
    /// emitters in `SlopDeskClientApp` depend on exactly this behaviour.
    func testToastEmittersDeDupeAndCap() {
        let overlay = OverlayCoordinator()
        // Five DISTINCT panes → cap evicts the oldest, leaving the 4 most recent.
        for index in 0..<5 {
            overlay.pushToast(Toast(id: "pane.\(index)", title: "build \(index)"))
        }
        XCTAssertEqual(overlay.toasts.count, 4, "the toast stack is capped at 4")
        XCTAssertEqual(
            overlay.toasts.map(\.id),
            ["pane.1", "pane.2", "pane.3", "pane.4"],
            "the oldest toast (pane.0) is evicted; newest-last order is preserved",
        )

        // A newer event for an existing pane id REPLACES it (the stable-id de-dupe the emitters rely on),
        // moving it to newest-last with the updated content — not a second card.
        overlay.pushToast(Toast(id: "pane.2", flavor: .attention, title: "build 2 (updated)"))
        XCTAssertEqual(overlay.toasts.count, 4, "a same-id push de-dupes rather than growing the stack")
        XCTAssertEqual(
            overlay.toasts.map(\.id),
            ["pane.1", "pane.3", "pane.4", "pane.2"],
            "the re-pushed pane.2 moves to newest-last",
        )
        XCTAssertEqual(overlay.toasts.last?.title, "build 2 (updated)", "the newer content wins")
        XCTAssertEqual(overlay.toasts.last?.flavor, .attention, "the newer flavour wins")
    }

    /// `dismissToast` removes exactly the targeted card (the X button / auto-dismiss timer path
    /// ToastStackView drives).
    func testDismissToastRemovesOnlyThatCard() {
        let overlay = OverlayCoordinator()
        overlay.pushToast(Toast(id: "a", title: "A"))
        overlay.pushToast(Toast(id: "b", title: "B"))
        overlay.dismissToast("a")
        XCTAssertEqual(overlay.toasts.map(\.id), ["b"], "only the dismissed card is removed")
    }

    // MARK: - The ⌘⌥J Peek & Reply overlay state (the closures the app threads)

    /// ⌘⌥J is `overlay.togglePeekReply()`. Pin the HONEST gate: it does NOTHING when no pane needs attention
    /// (no empty card), and OPENS over the blocked pane once one does — exactly the routing contract "the
    /// toggle closure itself no-ops when nothing needs attention". This FAILS on a naive `peekReplyVisible
    /// .toggle()` that would flash an empty card on a calm workspace (the no-attention assertion trips).
    func testTogglePeekReplyOnlyOpensWhenAPaneNeedsAttention() throws {
        let (overlay, store) = makeCoordinator()
        XCTAssertFalse(overlay.peekReplyVisible, "the Peek & Reply card starts hidden")

        overlay.togglePeekReply()
        XCTAssertFalse(overlay.peekReplyVisible, "⌘⌥J does nothing when no pane needs attention (no empty card)")

        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.setAgentStatus(.needsPermission, for: pane)
        overlay.togglePeekReply()
        XCTAssertTrue(overlay.peekReplyVisible, "⌘⌥J opens the card once a pane needs attention")
        XCTAssertEqual(overlay.peekReplyTarget(), pane, "the card targets the blocked pane")

        overlay.togglePeekReply()
        XCTAssertFalse(overlay.peekReplyVisible, "⌘⌥J again closes the card")
    }

    /// A delivered reply ADVANCES to the next pane needing attention (excluding the just-answered one, which
    /// may still report blocked until the host re-reports) and CLOSES when none is left — the
    /// answer-then-advance flow. Two blocked panes: the focused one is answered first, the advance lands the
    /// other, and answering it closes the card. FAILS on a card that re-targeted the same (still-blocked)
    /// pane (no exclusion) or never closed.
    func testDeliverPeekReplyAdvancesPastAnsweredThenCloses() throws {
        let (overlay, store) = makeCoordinator()
        let first = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.newTab(kind: .terminal) // focus moves to the new (second) pane
        let second = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        XCTAssertNotEqual(first, second)
        store.setAgentStatus(.needsPermission, for: first)
        store.setAgentStatus(.needsPermission, for: second)

        overlay.openPeekReply()
        XCTAssertTrue(overlay.peekReplyVisible)
        XCTAssertEqual(overlay.peekReplyTarget(), second, "the focused blocked pane is answered first")

        overlay.deliverPeekReply("approve\n", to: second)
        XCTAssertTrue(overlay.peekReplyVisible, "another pane still needs attention → the card stays open")
        XCTAssertEqual(
            overlay.peekReplyTarget(), first,
            "the advance excludes the just-answered pane and targets the next blocked one",
        )

        overlay.deliverPeekReply("approve\n", to: first)
        XCTAssertFalse(overlay.peekReplyVisible, "answering the last blocked pane closes the card")
    }

    /// A delivered reply publishes the window-level "REPLY SENT · <pane title>" notice — the delivery
    /// cue that makes a submit distinguishable from a skip once the card advances/closes. The detail
    /// names WHICH pane got the reply (the one doubt the advance leaves).
    func testDeliverPeekReplyPublishesReplySentNotice() throws {
        let (overlay, store) = makeCoordinator()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.setAgentStatus(.needsPermission, for: pane)
        store.renamePane(pane, to: "build-agent")
        overlay.openPeekReply()

        overlay.deliverPeekReply("approve\n", to: pane)
        let notice = try XCTUnwrap(overlay.notice, "the delivery publishes a notice")
        XCTAssertEqual(notice.label, "REPLY SENT")
        XCTAssertEqual(notice.detail, "build-agent", "the detail names the answered pane")
    }

    // MARK: - The window-level notice chip (`noteNotice` — tab-close undo cue et al.)

    /// `noteNotice` publishes with a FRESH epoch each time (a successor retargets the mounted chip's
    /// dwell task instead of expiring on the old timer), and `clearNotice` dismisses idempotently —
    /// the exact contract the copy receipt pinned, kept in lockstep for the generic twin.
    func testNoteNoticePublishesFreshEpochsAndClearIsIdempotent() throws {
        let overlay = OverlayCoordinator()
        overlay.noteNotice(label: "TAB CLOSED", detail: "⇧⌘T REOPENS")
        let first = try XCTUnwrap(overlay.notice)
        XCTAssertEqual(first.accessibilityText, "TAB CLOSED · ⇧⌘T REOPENS")

        overlay.noteNotice(label: "TAB CLOSED", detail: "⇧⌘T REOPENS")
        let second = try XCTUnwrap(overlay.notice)
        XCTAssertNotEqual(first.epoch, second.epoch, "a successor notice gets a fresh dwell identity")

        overlay.clearNotice()
        XCTAssertNil(overlay.notice)
        overlay.clearNotice() // idempotent
        XCTAssertNil(overlay.notice)
    }

    /// The store's tab-close hook is what the app wires to `noteNotice` — pin the wiring shape the app
    /// uses (a recorded reopenable close ⇒ exactly one notice, speaking the ⇧⌘T affordance).
    func testTabCloseRecordedWiringPublishesTheUndoCue() throws {
        let (overlay, store) = makeCoordinator()
        store.onTabCloseRecorded = { [weak overlay] in
            overlay?.noteNotice(label: "TAB CLOSED", detail: "⇧⌘T REOPENS")
        }
        store.newTab(kind: .terminal) // a second tab so the close leaves the workspace alive
        let closing = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)

        store.closeTab(closing)
        XCTAssertEqual(overlay.notice?.accessibilityText, "TAB CLOSED · ⇧⌘T REOPENS")
    }

    /// Closing resets the advance-exclusion so a REOPEN re-targets a still-blocked pane (rather than carrying
    /// a stale exclusion that would make the reopened card target nothing). FAILS if `closePeekReply` leaves
    /// `peekReplyExcluding` populated.
    func testClosePeekReplyResetsExclusionSoReopenReTargets() throws {
        let (overlay, store) = makeCoordinator()
        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.setAgentStatus(.needsPermission, for: pane)

        overlay.openPeekReply()
        overlay.advancePeekReply(answered: pane) // excludes the only pane → no target → the card auto-closes
        XCTAssertFalse(overlay.peekReplyVisible, "advancing past the only blocked pane closes the card")
        XCTAssertTrue(overlay.peekReplyExcluding.isEmpty, "close clears the advance-exclusion set")

        overlay.openPeekReply()
        XCTAssertTrue(overlay.peekReplyVisible, "reopening with a still-blocked pane presents the card again")
        XCTAssertEqual(
            overlay.peekReplyTarget(), pane,
            "the reopen re-targets the still-blocked pane (the exclusion was reset on close)",
        )
    }

    /// The Peek & Reply card is a centered, SCRIMMED modal, so it MUST register in `anyModalVisible` (the
    /// `OverlayHostView` hit-testing gate). FAILS if `peekReplyVisible` is not folded into the gate.
    func testPeekReplyRegistersAsAModal() throws {
        let (overlay, store) = makeCoordinator()
        XCTAssertFalse(overlay.anyModalVisible, "nothing up ⇒ the host passes clicks through")

        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.setAgentStatus(.needsPermission, for: pane)
        overlay.openPeekReply()
        XCTAssertTrue(overlay.peekReplyVisible, "the card is up")
        XCTAssertTrue(
            overlay.anyModalVisible,
            "Peek & Reply is a scrimmed modal — it registers in the hit-testing gate",
        )
        overlay.closePeekReply()
        XCTAssertFalse(overlay.anyModalVisible)
    }

    // MARK: - The `anyModalVisible` hit-testing gate the OverlayHostView reads

    /// `OverlayHostView.allowsHitTesting(anyModalVisible || !toasts.isEmpty)` — the host is transparent to
    /// clicks until a modal is up. Pin that `anyModalVisible` tracks EXACTLY the five scrimmed panels (palette
    /// / cheat sheet / connect / remote picker / Open-Quickly) and that a toast is NOT a modal (it is gated
    /// separately) — a regression that folded a toast (or dropped a panel) into the gate would swallow
    /// workspace clicks or fail to.
    func testAnyModalVisibleReflectsModalFlagsButNotToasts() {
        let (overlay, _) = makeCoordinator()
        XCTAssertFalse(overlay.anyModalVisible, "nothing up ⇒ the host passes clicks through")

        overlay.openPalette()
        XCTAssertTrue(overlay.anyModalVisible, "the palette is a modal")
        overlay.closePalette()
        XCTAssertFalse(overlay.anyModalVisible)

        overlay.openCheatSheet()
        XCTAssertTrue(overlay.anyModalVisible, "the cheat sheet is a modal")
        overlay.closeCheatSheet()
        XCTAssertFalse(overlay.anyModalVisible)

        overlay.openConnect()
        XCTAssertTrue(overlay.anyModalVisible, "the connect editor is a modal")
        overlay.closeConnect()
        XCTAssertFalse(overlay.anyModalVisible)

        overlay.openRemotePicker()
        XCTAssertTrue(overlay.anyModalVisible, "the remote-window picker is a modal")
        overlay.closeRemotePicker()
        XCTAssertFalse(overlay.anyModalVisible)

        // The Open-Quickly picker is a centered, SCRIMMED modal (it folded in Jump-To), so it
        // MUST register here. Fails if `openQuicklyVisible` is not folded into `anyModalVisible`.
        overlay.openOpenQuickly()
        XCTAssertTrue(overlay.anyModalVisible, "the Open-Quickly picker is a modal")
        overlay.closeOpenQuickly()
        XCTAssertFalse(overlay.anyModalVisible)

        // A toast alone must NOT make the layer modal (it is gated by `!toasts.isEmpty`, separately).
        overlay.pushToast(Toast(id: "x", title: "build done"))
        XCTAssertFalse(overlay.anyModalVisible, "a toast is not a focus-stealing modal")
    }

    // MARK: - The keyboard-capture gate the app's `isOverlayCapturingKeys` closure reads

    /// `capturesKeyboardWhileVisible` is the SINGLE source of truth the app's `isOverlayCapturingKeys` gate
    /// reads so the global NSEvent dispatcher YIELDS modeled chords to a focused overlay. Pin that it tracks
    /// EVERY keyboard-owning overlay: Open-Quickly, Peek & Reply, AND the four
    /// SCRIMMED modals (palette / cheat sheet / connect / remote picker). The NSEvent monitor PREEMPTS the
    /// responder chain, so sheet-presented panels can't rely on it alone; ⌘W/⌘T/⌘2 would destructively mutate
    /// the BACKGROUND tree behind their scrim without this gate.
    func testCapturesKeyboardWhileVisibleFoldsInKeyboardOwningOverlays() throws {
        let (overlay, store) = makeCoordinator()
        XCTAssertFalse(overlay.capturesKeyboardWhileVisible, "nothing up ⇒ the dispatcher owns chords normally")

        overlay.openOpenQuickly()
        XCTAssertTrue(overlay.capturesKeyboardWhileVisible, "the Open-Quickly picker owns the keyboard")
        overlay.closeOpenQuickly()
        XCTAssertFalse(overlay.capturesKeyboardWhileVisible)

        let pane = try XCTUnwrap(store.tree.allPaneIDs().first)
        store.setAgentStatus(.needsPermission, for: pane)
        overlay.openPeekReply()
        XCTAssertTrue(overlay.capturesKeyboardWhileVisible, "the Peek & Reply card owns the keyboard")
        overlay.closePeekReply()
        XCTAssertFalse(overlay.capturesKeyboardWhileVisible)

        // The scrimmed panels are in the gate: the NSEvent monitor preempts the
        // responder chain, so palette / cheat-sheet / connect / remote-picker must trip it or ⌘W/⌘T/⌘2
        // destructively mutates the background tree. (Pinned deeper by DispatcherOverlayYieldTests.)
        overlay.openPalette()
        XCTAssertTrue(overlay.capturesKeyboardWhileVisible, "the palette scrim owns ⌘-chords via the dispatcher gate")
        overlay.closePalette()
    }

    // MARK: - A picked window opens a STAGE tab + closes the picker

    /// `RemoteWindowPickerModal` routes a pick through `coordinator.openRemoteWindow(_:)` (NOT the in-pane
    /// `pick()→open()`). Pin that it opens a `.remoteGUI` STAGE tab pre-bound to the picked window AND
    /// closes the modal — the app-global path the modal depends on (the Stage re-scope: the split tree is
    /// terminal-only, so the pick never touches the tab strip).
    func testOpenRemoteWindowOpensStageTabAndCloses() throws {
        let (overlay, store) = makeCoordinator()
        overlay.openRemotePicker()
        XCTAssertTrue(overlay.remotePickerVisible, "openRemotePicker presents the modal")
        XCTAssertNotNil(overlay.remotePickerModel, "a fresh discovery model is built per open")

        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let summary = RemoteWindowSummary(
            windowID: 4242, appName: "Safari", title: "Docs", width: 1200, height: 800,
        )
        overlay.openRemoteWindow(summary)

        XCTAssertFalse(overlay.remotePickerVisible, "picking a window closes the modal")
        XCTAssertNil(overlay.remotePickerModel, "the per-open model is released on close")

        let session = try XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session.tabs.count, tabsBefore, "the tree's tab strip is untouched")
        let newPane = try XCTUnwrap(session.activeStagePane, "the picked window's stage tab is selected")
        XCTAssertEqual(session.stagePanes, [newPane], "a stage tab was opened for the picked window")
        XCTAssertEqual(session.specs[newPane]?.kind, .remoteGUI, "the new pane is a remote-GUI pane")
        XCTAssertEqual(
            session.specs[newPane]?.video?.windowID, 4242,
            "the new pane is pre-bound to the picked host window id",
        )
    }

    // MARK: - The host's toggled-state predicate reflects live chrome

    #if canImport(SwiftUI)
    /// `OverlayHostView.toggledState(for:)` is the pure predicate the host hands the palette so the ✓ gutter
    /// tracks the real panel visibility. Pin that the Toggle-Tabs-Panel row shows ✓ exactly when the sidebar is
    /// visible (`!sidebarCollapsed`), and a non-toggle row never does — test the predicate, not the view.
    func testToggledStateTracksSidebarVisibility() throws {
        let (_, store) = makeCoordinator()
        let chrome = WorkspaceChromeState()
        let predicate = OverlayHostView.toggledState(for: chrome, store: store)
        let sidebarRow = try XCTUnwrap(
            ActionsPaletteSource.catalog.first { $0.id == "action.toggleSidebar" },
            "the catalog has the Toggle Tabs Panel row",
        )
        let plainRow = try XCTUnwrap(
            ActionsPaletteSource.catalog.first { $0.id == "action.newTerminalTab" },
            "the catalog has the New Tab row",
        )

        chrome.sidebarCollapsed = false
        XCTAssertTrue(predicate(sidebarRow), "sidebar visible ⇒ ✓ on Toggle Tabs Panel")
        XCTAssertFalse(predicate(plainRow), "a non-toggle row never shows ✓")

        chrome.sidebarCollapsed = true
        XCTAssertFalse(predicate(sidebarRow), "sidebar collapsed ⇒ no ✓")
    }

    /// The CLOSED loop (the gap the predicate-only test above leaves): RUNNING the "Toggle Tabs Panel" row
    /// through the coordinator must flip the SAME `chrome.sidebarCollapsed` the ✓ predicate reads.
    /// Wires `toggleSidebar` to the live chrome exactly as `WorkspaceRootView` does, then asserts the
    /// predicate flips after `run`. FAILS on the old wiring (the row ran `store.toggleSidebarCollapsed()`, a
    /// dead flag the ✓ never reads — the predicate would never move).
    func testRunningToggleSidebarRowFlipsTheLiveChromeTheCheckmarkReads() throws {
        let (overlay, store) = makeCoordinator()
        let chrome = WorkspaceChromeState()
        // Bound the way the root view binds it (`overlay.toggleSidebar = { chrome.toggleSidebar() }`).
        overlay.toggleSidebar = { [chrome] in chrome.toggleSidebar() }
        let predicate = OverlayHostView.toggledState(for: chrome, store: store)
        let sidebarRow = try XCTUnwrap(
            ActionsPaletteSource.catalog.first { $0.id == "action.toggleSidebar" },
            "the catalog has the Toggle Tabs Panel row",
        )

        chrome.sidebarCollapsed = false
        let storeFlagBefore = store.sidebarCollapsed
        XCTAssertTrue(predicate(sidebarRow), "precondition: sidebar visible ⇒ ✓ shown")

        overlay.run(sidebarRow)

        XCTAssertFalse(
            predicate(sidebarRow),
            "running Toggle Tabs Panel collapsed the LIVE chrome the ✓ reads ⇒ ✓ now off",
        )
        XCTAssertTrue(chrome.sidebarCollapsed, "the live chrome flag the split reads was toggled")
        XCTAssertEqual(
            store.sidebarCollapsed, storeFlagBefore,
            "the dead `store.sidebarCollapsed` is NOT touched (the row no longer fires the legacy flag)",
        )
    }
    #endif
}

// MARK: - MountTestPaneSession (the headless store double for this suite)

/// The tiniest `PaneSessionHandle` satisfying the store's `makeSession` seam without opening a socket or
/// touching video — so a tree-model ``WorkspaceStore`` materializes for the coordinator tests. Mirrors
/// `FakePaneSession` (in the WorkspaceCore test target, out of reach here) down to the `PaneSessionIDAdopting`
/// adoption the reconcile invariant needs, and the explicit `@MainActor` conformance markers on
/// `PaneSessionHandle` / `Identifiable`. Without those markers the `Identifiable.id` requirement is
/// nonisolated while the `@MainActor` class's `id` getter is isolated, which Swift 6 strict concurrency flags
/// as a data-race-crossing conformance (#ConformanceIsolation).
@MainActor
final class MountTestPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false

    init(_ spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind.isVideo { isVideoActive = active } }
    // Sync witnesses legally satisfy the `async` protocol requirements (same as the canonical
    // `FakePaneSession`) and avoid the `async_without_await` strict-lint rule on the empty fake bodies.
    func pause() {}
    func resume() {}
    func teardown() {}
}
