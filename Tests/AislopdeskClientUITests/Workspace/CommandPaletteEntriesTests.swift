import XCTest
@testable import AislopdeskClientUI
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Pins the command-palette catalog + per-pane entry builder: the "Reconnect Pane" command surfaces
/// and ranks under "recon", and `buildPaneEntries` emits one jump-to-pane entry per canvas pane,
/// subtitled by its owning group (single-canvas model — there is no tab layer). Pure seams — the fuzzy
/// scorer and `buildPaneEntries` are tested directly, no SwiftUI render. `.reconnectPane` / `.renamePane`
/// command routing is asserted against the store via `apply(_:to:)` with the `FakePaneSession` seam.
@MainActor
final class CommandPaletteEntriesTests: XCTestCase {
    #if canImport(SwiftUI)

    // MARK: - Catalog contains Reconnect Pane + fuzzy ranks it

    func testCatalogContainsReconnectPane() {
        let hasReconnect = CommandPaletteView.commandCatalog.contains { $0.command == .reconnectPane }
        XCTAssertTrue(hasReconnect, "the palette catalog must offer Reconnect Pane")
    }

    func testFocusedPaneVerbsAreHiddenOnAnEmptyCanvas() {
        let withFocus = CommandPaletteView.visibleCommands(hasFocusedPane: true).map(\.command)
        let noFocus = CommandPaletteView.visibleCommands(hasFocusedPane: false).map(\.command)
        // With a focused pane every verb shows.
        XCTAssertTrue(withFocus.contains(.closePane))
        XCTAssertTrue(withFocus.contains(.renamePane))
        // With none, the focused-pane verbs are dropped…
        XCTAssertFalse(noFocus.contains(.closePane), "no pane to close on an empty canvas")
        XCTAssertFalse(noFocus.contains(.renamePane))
        XCTAssertFalse(noFocus.contains(.duplicatePane))
        XCTAssertFalse(noFocus.contains(.toggleZoom))
        // …but creation / global verbs still show.
        XCTAssertTrue(noFocus.contains(.newPane(.terminal)))
        XCTAssertTrue(noFocus.contains(.toggleOverview))
        XCTAssertTrue(noFocus.contains(.manageSnippets))
    }

    func testRequiresFocusedPanePredicate() {
        XCTAssertTrue(WorkspaceCommand.closePane.requiresFocusedPane)
        XCTAssertTrue(WorkspaceCommand.reconnectPane.requiresFocusedPane)
        XCTAssertFalse(WorkspaceCommand.newPaneDefault.requiresFocusedPane)
        XCTAssertFalse(WorkspaceCommand.selectAllPanes.requiresFocusedPane)
    }

    func testFuzzyRanksReconnectForReconQuery() {
        // "recon" is a contiguous-prefix subsequence of "Reconnect Pane" ⇒ a positive (high) score.
        let score = CommandPaletteView.fuzzyScore(query: "recon", in: "Reconnect Pane")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
        // A non-subsequence query does not match.
        XCTAssertNil(CommandPaletteView.fuzzyScore(query: "xyz", in: "Reconnect Pane"))
    }

    func testFuzzyRewardsWordStartsOverMidWordMatches() throws {
        // "np" → "New Pane" (both letters begin a word) ranks above a mid-word scatter.
        let wordStarts = try XCTUnwrap(CommandPaletteView.fuzzyScore(query: "np", in: "New Pane"))
        let midWord = try XCTUnwrap(CommandPaletteView.fuzzyScore(query: "np", in: "Unzip")) // n@1, p@4, mid-word
        XCTAssertGreaterThan(wordStarts, midWord)
        // A single letter at a word start beats the same letter buried mid-word.
        XCTAssertGreaterThan(
            try XCTUnwrap(CommandPaletteView.fuzzyScore(query: "p", in: "Pane")),
            try XCTUnwrap(CommandPaletteView.fuzzyScore(query: "p", in: "Snap")),
        )
    }

    func testFuzzyPenalisesScatteredMatches() throws {
        // A tight (contiguous) match scores higher than the same letters spread far apart.
        let tight = try XCTUnwrap(CommandPaletteView.fuzzyScore(query: "ab", in: "ab"))
        let scattered = try XCTUnwrap(CommandPaletteView.fuzzyScore(query: "ab", in: "axxxxb"))
        XCTAssertGreaterThan(tight, scattered)
        XCTAssertNotNil(CommandPaletteView.fuzzyScore(query: "ab", in: "axxxxb"), "still matches, just lower")
    }

    // MARK: - Keyword aliases (the verbs people actually type)

    /// The fuzzy haystack for a catalog command, mirroring `commandEntries` (title + keywords; commands
    /// have no subtitle).
    private func haystack(_ command: WorkspaceCommand) -> String {
        let item = CommandPaletteView.commandCatalog.first { $0.command == command }!
        return [item.title, item.keywords].compactMap(\.self).joined(separator: " ")
    }

    func testKeywordAliasesMatchCommonVerbs() {
        // None of these verbs appear in the command TITLE — they only resolve via the keyword synonyms.
        XCTAssertNotNil(
            CommandPaletteView.fuzzyScore(query: "sync", in: haystack(.toggleBroadcast)),
            "'sync' finds Broadcast Input",
        )
        XCTAssertNotNil(
            CommandPaletteView.fuzzyScore(query: "fullscreen", in: haystack(.toggleZoom)),
            "'fullscreen' finds Maximize Pane",
        )
        XCTAssertNotNil(
            CommandPaletteView.fuzzyScore(query: "split", in: haystack(.newPane(.terminal))),
            "'split' finds New Terminal Pane",
        )
        XCTAssertNotNil(
            CommandPaletteView.fuzzyScore(query: "mission control", in: haystack(.toggleOverview)),
            "'mission control' finds Overview",
        )
        XCTAssertNotNil(
            CommandPaletteView.fuzzyScore(query: "recenter", in: haystack(.centerAll)),
            "'recenter' finds Center on All",
        )
    }

    func testEveryCatalogCommandHasKeywords() {
        // Keyword synonyms are the discoverability layer; a command with none is a silent gap.
        for item in CommandPaletteView.commandCatalog {
            XCTAssertNotNil(item.keywords, "\(item.title) is missing fuzzy keyword aliases")
            XCTAssertFalse(item.keywords?.isEmpty ?? true, "\(item.title) has empty keyword aliases")
        }
    }

    // MARK: - Catalog covers the formerly menu-only verbs (align / distribute / save-layout)

    func testCatalogContainsArrangeAndSaveLayoutCommands() {
        let commands = CommandPaletteView.commandCatalog.map(\.command)
        XCTAssertTrue(commands.contains(.saveLayout), "Save Current Layout… runnable from ⌘K")
        XCTAssertTrue(commands.contains(.align(.left)), "Align Left runnable from ⌘K")
        XCTAssertTrue(commands.contains(.align(.centerVertical)))
        XCTAssertTrue(commands.contains(.distribute(horizontal: true)))
        XCTAssertTrue(commands.contains(.distribute(horizontal: false)))
        // All six align edges are present.
        for edge in AlignEdge.allCases {
            XCTAssertTrue(commands.contains(.align(edge)), "Align \(edge) is in the catalog")
        }
    }

    // MARK: - Recents entries (focused-pane visibility, mirroring the catalog filter)

    func testRecentEntriesHideFocusRequiringVerbsWhenNoFocusedPane() {
        // A focus-requiring verb run earlier (Close/Duplicate Pane) must not surface at the TOP of the
        // palette on an empty canvas, where selecting it is a graceful no-op that "reads as broken" — the
        // exact case the catalog section already hides via visibleCommands(hasFocusedPane:).
        let recents: [WorkspaceCommand] = [.closePane, .duplicatePane, .tidy, .centerAll]

        let withFocus = CommandPaletteView.buildRecentEntries(commands: recents, hasFocusedPane: true)
        XCTAssertTrue(withFocus.contains { $0.title == "Close Pane" }, "with a focused pane the verb shows")

        let noFocus = CommandPaletteView.buildRecentEntries(commands: recents, hasFocusedPane: false)
        XCTAssertFalse(noFocus.contains { $0.title == "Close Pane" }, "no focused pane → focus-verb hidden")
        XCTAssertFalse(noFocus.contains { $0.title == "Duplicate Pane" }, "…same for every focus-requiring verb")
        XCTAssertTrue(noFocus.contains { $0.title == "Tidy Layout" }, "a non-focus-requiring recent still shows")
        XCTAssertTrue(noFocus.contains { $0.title == "Center on All" })
    }

    // MARK: - Bookmark recall entries (jump to a named viewport from ⌘K)

    func testBookmarkEntriesAppearForSavedBookmarks() {
        let pane = PaneID()
        let store = WorkspaceStore(
            restoring: Workspace(canvas: Canvas(items: [
                CanvasItem(
                    id: pane,
                    spec: PaneSpec(kind: .terminal, title: "p"),
                    frame: CGRect(x: 0, y: 0, width: 160, height: 120),
                    z: 0,
                ),
            ]), focusedPane: pane),
            makeSession: { FakePaneSession($0) }, liveVideoCap: 5,
        )
        store.saveBookmark(3) // names it after the focused pane's title
        let entries = CommandPaletteView.buildBookmarkEntries(workspace: store.workspace)
        XCTAssertTrue(
            entries.map(\.title).contains { $0.hasPrefix("Go to ") },
            "a saved bookmark surfaces a 'Go to …' row",
        )
        // And it carries the recall command for that slot.
        let entry = entries.first { $0.id == "bookmark.3" }
        XCTAssertNotNil(entry)
        if case let .command(cmd) = entry?.kind { XCTAssertEqual(cmd, .recallBookmark(3)) }
        else { XCTFail("bookmark entry must carry .recallBookmark") }
    }

    // MARK: - buildPaneEntries

    /// Every pane on the canvas yields exactly one jump-to-pane entry carrying its `PaneID`, titled by
    /// the leaf spec; an ungrouped pane is subtitled "Pane" while a grouped pane is "Pane in <group>".
    func testBuildPaneEntriesOneEntryPerPaneWithGroupSubtitle() {
        let groupedID = PaneID(), ungroupedID = PaneID()
        let group = PaneGroup(name: "Work")
        let workspace = Workspace.make(
            panes: [
                (groupedID, PaneSpec(kind: .terminal, title: "Left")),
                (ungroupedID, PaneSpec(kind: .claudeCode, title: "Right")),
            ],
            focused: groupedID,
            groups: [group],
        ).assigning(pane: groupedID, toGroup: group.id)

        let entries = CommandPaletteView.buildPaneEntries(workspace: workspace)

        XCTAssertEqual(entries.count, 2, "one entry per pane on the canvas")
        // Each entry carries its PaneID.
        let paneIDs: [PaneID] = entries.compactMap { entry in
            if case let .pane(p) = entry.kind { return p }
            return nil
        }
        XCTAssertEqual(Set(paneIDs), [groupedID, ungroupedID])
        // Titles come from the leaf specs.
        XCTAssertEqual(Set(entries.map(\.title)), ["Left", "Right"])
        // Subtitle reflects group membership.
        let byID = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (PaneID, String?)? in
            if case let .pane(p) = entry.kind { return (p, entry.subtitle) }
            return nil
        })
        XCTAssertEqual(byID[groupedID], "Pane in Work", "a grouped pane names its group")
        XCTAssertEqual(byID[ungroupedID], "Pane", "an ungrouped pane is plain 'Pane'")
    }

    #endif

    // MARK: - apply(.reconnectPane) routing

    /// `apply(.reconnectPane)` is a graceful no-op against the `FakePaneSession` seam (no live
    /// connection) — it must not trap and must not mutate the canvas / registry.
    func testApplyReconnectPaneIsSafeWithFakeSession() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let before = store.workspace
        let sessions = store.allSessions.count

        apply(.reconnectPane, to: store) // focused pane has a FakePaneSession (no connection) ⇒ no-op

        XCTAssertEqual(store.workspace, before, "reconnect must not mutate the canvas")
        XCTAssertEqual(store.allSessions.count, sessions, "reconnect must not touch the registry")
    }

    /// `apply(.reconnectPane)` with no focused pane is a graceful no-op (no target to reconnect).
    func testApplyReconnectPaneNoopWithNoFocusedPane() throws {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        try store.closePane(XCTUnwrap(store.focusedPane)) // close the only pane → empty canvas, no focus
        XCTAssertNil(store.focusedPane)
        apply(.reconnectPane, to: store) // must not trap
        XCTAssertNil(store.focusedPane)
    }

    // MARK: - apply(.renamePane) wiring

    /// `apply(.renamePane)` records the focused pane as the PENDING rename target — the sidebar opens
    /// its inline field on it (the root view reveals a collapsed sidebar column first), then consumes
    /// the request via `clearRenameRequest()`.
    func testApplyRenamePaneSetsPendingRenameToFocusedPane() {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        let focused = store.focusedPane
        XCTAssertNotNil(focused)
        apply(.renamePane, to: store)
        XCTAssertEqual(store.pendingRename, focused, "the focused pane is the pending rename target")
        store.clearRenameRequest()
        XCTAssertNil(store.pendingRename, "the sidebar consumes the request once its field opens")
    }

    /// With no focused pane, `apply(.renamePane)` is a graceful no-op (nothing to rename).
    func testApplyRenamePaneNoopWithNoFocusedPane() throws {
        let store = WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2)
        try store.closePane(XCTUnwrap(store.focusedPane)) // close the only pane → no focus
        XCTAssertNil(store.focusedPane)
        apply(.renamePane, to: store) // must not trap
        XCTAssertNil(store.pendingRename, "no focused pane → no rename request")
    }
}
