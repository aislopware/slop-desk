import AislopdeskProtocol
import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E11 WI-3 (ES-E11-1..4): the PURE Open-Quickly model — the `⌘⇧O` multi-source switcher's taxonomy +
/// merge/rank/section/cycle/quick-pick logic, with zero SwiftUI/store coupling. These pin:
/// - the pill set (SSH + Recipes are product cuts — no enum case exists for either);
/// - the per-filter pill metadata (label / icon / picker-chord) + the `.all` default;
/// - `nextFilter`/`prevFilter` Tab cycling that WRAPS the pill ring;
/// - `sectioned` merging sources under ALL-CAPS headers in `.all` (empty sources omitted) vs a single
///   section in a specific filter (always present, so the view can render the honest empty-state);
/// - the injected-scorer ranking (drop non-matches, score-descending, STABLE tie-break, blank query =
///   zero-state) — reusing the same contract as `JumpToModel.filtered`;
/// - `selectable` flattening sections to the navigable/quick-pick row list (headers skipped);
/// - `quickPickIndex` mapping the 1-based `⌘1–9` chord onto a 0-based visible row (with `⌘0`/out-of-range
///   rejected);
/// - the source builders: Agents is **Claude-only** (carry-over), Folders maps name+path, Current wraps
///   `JumpToItem` acts verbatim.
///
/// Each assertion is revert-to-confirm-fail: it fails on a model that re-adds an SSH or Recipes pill, fails
/// to wrap the cycle, emits an empty `.all` header, mis-orders a tie, mis-maps `⌘1–9`, or lets a non-Claude
/// agent session through.
final class OpenQuicklyModelTests: XCTestCase {
    // MARK: - Fixtures

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A minimal item with an explicit fuzzy haystack and a placeholder act (Recent reopen) — enough to
    /// exercise the merge/rank/section/select logic without leaning on a specific source builder.
    private func item(
        _ id: String,
        _ title: String,
        kind: OpenQuicklyKind = .command,
        search: String? = nil,
    ) -> OpenQuicklyItem {
        OpenQuicklyItem(
            id: id,
            kind: kind,
            title: title,
            subtitle: nil,
            timestamp: nil,
            searchText: search ?? title,
            act: .reopenRecentTab(index: 0),
        )
    }

    /// A deterministic, fzf-shaped stand-in scorer (subsequence; an EARLIER first-match scores higher), the
    /// same shape `JumpToModelTests` uses — exercises the model's filter+order contract without pulling the
    /// view-module `FuzzyMatcher` into the headless test.
    private func subsequenceScore(_ query: String, _ haystack: String) -> Int? {
        let h = Array(haystack.lowercased())
        var hi = 0
        var firstMatch: Int?
        for qc in query.lowercased() {
            var found = false
            while hi < h.count {
                if h[hi] == qc {
                    if firstMatch == nil { firstMatch = hi }
                    hi += 1
                    found = true
                    break
                }
                hi += 1
            }
            if !found { return nil }
        }
        return 1000 - (firstMatch ?? 0)
    }

    // MARK: - Pill taxonomy (ES-E11-1)

    /// REVERT-TO-CONFIRM-FAIL: re-adding an SSH or Recipes case grows `allCases` past 6; dropping a live
    /// pill fails the order assertion.
    func testPickerPillsOrderExcludesSSHAndRecipes() {
        XCTAssertEqual(
            OpenQuicklyFilter.pickerPills,
            [.all, .opened, .recent, .folders, .agents, .current],
        )
        XCTAssertEqual(
            OpenQuicklyFilter.pickerPills.map(\.label),
            ["All", "Opened", "Recent", "Folders", "Agents", "Current"],
        )
        let labels = OpenQuicklyFilter.pickerPills.map(\.label)
        XCTAssertFalse(labels.contains("SSH"), "the SSH pill is a deliberate product cut")
        XCTAssertFalse(labels.contains("Recipes"), "the Recipes pill was removed with the recipe feature")
        // Both are structural cuts (no enum case).
        XCTAssertEqual(OpenQuicklyFilter.allCases.count, 6)
    }

    func testDefaultFilterIsAll() {
        XCTAssertEqual(OpenQuicklyFilter.defaultFilter, .all, "⌘⇧O opens to the merged All list")
        XCTAssertEqual(OpenQuicklyFilter.pickerPills.first, .all)
    }

    func testPickerChordKeysMatchSlateSpec() {
        XCTAssertEqual(OpenQuicklyFilter.all.pickerChordKey, "0")
        XCTAssertEqual(OpenQuicklyFilter.opened.pickerChordKey, "w")
        XCTAssertEqual(OpenQuicklyFilter.recent.pickerChordKey, "r")
        XCTAssertEqual(OpenQuicklyFilter.folders.pickerChordKey, "z")
        XCTAssertEqual(OpenQuicklyFilter.agents.pickerChordKey, "g")
        XCTAssertEqual(OpenQuicklyFilter.current.pickerChordKey, "j")
        let keys = OpenQuicklyFilter.pickerPills.map(\.pickerChordKey)
        XCTAssertEqual(Set(keys).count, keys.count, "the per-pill picker chords are collision-free")
    }

    func testEverySectionHeaderIsAllCaps() {
        for filter in OpenQuicklyFilter.allCases {
            XCTAssertEqual(filter.sectionHeader, filter.label.uppercased())
        }
        XCTAssertEqual(OpenQuicklyFilter.opened.sectionHeader, "OPENED")
    }

    // MARK: - Filter cycling (ES-E11-2)

    func testNextFilterWrapsForward() {
        XCTAssertEqual(OpenQuicklyModel.nextFilter(.all), .opened)
        XCTAssertEqual(OpenQuicklyModel.nextFilter(.folders), .agents)
        XCTAssertEqual(OpenQuicklyModel.nextFilter(.current), .all, "Tab wraps from the last pill to the first")
    }

    func testPrevFilterWrapsBackward() {
        XCTAssertEqual(OpenQuicklyModel.prevFilter(.opened), .all)
        XCTAssertEqual(OpenQuicklyModel.prevFilter(.all), .current, "⇧Tab wraps from the first pill to the last")
    }

    // MARK: - sectioned: merge + headers (ES-E11-2)

    func testSectionedAllMergesSourcesUnderAllCapsHeadersInCanonicalOrder() {
        let sources: [OpenQuicklyFilter: [OpenQuicklyItem]] = [
            .current: [item("c1", "gamma", kind: .command)],
            .opened: [item("p1", "alpha", kind: .pane)],
            .folders: [item("f1", "beta", kind: .folder)],
        ]
        let sections = OpenQuicklyModel.sectioned(sources: sources, filter: .all, query: "", score: subsequenceScore)
        // Sections follow the canonical .all order (opened, recent, folders, agents, current), NOT dict order.
        XCTAssertEqual(sections.map(\.filter), [.opened, .folders, .current])
        XCTAssertEqual(sections.map(\.header), ["OPENED", "FOLDERS", "CURRENT"])
        XCTAssertEqual(sections.first?.items.map(\.title), ["alpha"])
    }

    func testSectionedAllOmitsEmptySources() {
        let sources: [OpenQuicklyFilter: [OpenQuicklyItem]] = [
            .opened: [],
            .recent: [],
            .folders: [item("f1", "beta", kind: .folder)],
        ]
        let sections = OpenQuicklyModel.sectioned(sources: sources, filter: .all, query: "", score: subsequenceScore)
        XCTAssertEqual(sections.map(\.filter), [.folders], "an empty source contributes no header to the All list")
    }

    func testSectionedSpecificFilterReturnsSingleSection() {
        let sources: [OpenQuicklyFilter: [OpenQuicklyItem]] = [
            .opened: [item("p1", "a", kind: .pane), item("p2", "b", kind: .pane)],
            .folders: [item("f1", "x", kind: .folder)],
        ]
        let sections = OpenQuicklyModel.sectioned(sources: sources, filter: .opened, query: "", score: subsequenceScore)
        XCTAssertEqual(sections.count, 1, "a specific pill shows only its own source")
        XCTAssertEqual(sections.first?.filter, .opened)
        XCTAssertEqual(sections.first?.items.count, 2)
    }

    func testSectionedSpecificFilterEmptySourceStillYieldsSectionForEmptyState() {
        // Folders with nothing visited yet: the section is still emitted (with no items) so the view can
        // render the honest "No folders yet" empty-state instead of a blank panel.
        let sections = OpenQuicklyModel.sectioned(sources: [:], filter: .folders, query: "", score: subsequenceScore)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.filter, .folders)
        XCTAssertTrue(sections.first?.items.isEmpty ?? false)
    }

    func testSectionedAllAllEmptyYieldsNoSections() {
        let sections = OpenQuicklyModel.sectioned(sources: [:], filter: .all, query: "", score: subsequenceScore)
        XCTAssertTrue(sections.isEmpty, "an all-empty All list shows the global empty-state, no stray headers")
    }

    // MARK: - sectioned: rank within a section (ES-E11-2)

    func testSectionedRanksAndDropsNonMatchesWithinSection() {
        let sources: [OpenQuicklyFilter: [OpenQuicklyItem]] = [
            .current: [
                item("c1", "git status", search: "git status"), // "gs": g@0 (front) → high
                item("c2", "regis status", search: "regis status"), // "gs": g@3 → lower
                item("c3", "ls", search: "ls"), // no "g" → dropped
            ],
        ]
        let sections = OpenQuicklyModel.sectioned(
            sources: sources,
            filter: .current,
            query: "gs",
            score: subsequenceScore,
        )
        XCTAssertEqual(
            sections.first?.items.map(\.title),
            ["git status", "regis status"],
            "drops 'ls'; the front-loaded match ranks first",
        )
    }

    func testSectionedStableTieKeepsSourceOrder() {
        let sources: [OpenQuicklyFilter: [OpenQuicklyItem]] = [
            .current: [
                item("c1", "abc one", search: "abc one"),
                item("c2", "abc two", search: "abc two"),
            ],
        ]
        let sections = OpenQuicklyModel.sectioned(
            sources: sources,
            filter: .current,
            query: "abc",
            score: subsequenceScore,
        )
        XCTAssertEqual(
            sections.first?.items.map(\.title),
            ["abc one", "abc two"],
            "equal scores keep the original assembly order",
        )
    }

    func testSectionedBlankQueryIsZeroStateSourceOrder() {
        let sources: [OpenQuicklyFilter: [OpenQuicklyItem]] = [
            .current: [
                item("c1", "zeta"),
                item("c2", "alpha"),
            ],
        ]
        let sections = OpenQuicklyModel.sectioned(
            sources: sources,
            filter: .current,
            query: "   ",
            score: subsequenceScore,
        )
        XCTAssertEqual(
            sections.first?.items.map(\.title),
            ["zeta", "alpha"],
            "a blank query is the zero-state: every row, original order (no re-rank)",
        )
    }

    // MARK: - selectable + quick-pick (ES-E11-2 / ES-E11-3)

    func testSelectableFlattensSectionsInOrderSkippingHeaders() {
        let sources: [OpenQuicklyFilter: [OpenQuicklyItem]] = [
            .opened: [item("p1", "a", kind: .pane)],
            .folders: [item("f1", "b", kind: .folder), item("f2", "c", kind: .folder)],
        ]
        let sections = OpenQuicklyModel.sectioned(sources: sources, filter: .all, query: "", score: subsequenceScore)
        let rows = OpenQuicklyModel.selectable(sections)
        XCTAssertEqual(
            rows.map(\.title),
            ["a", "b", "c"],
            "selectable = section items concatenated; headers are not rows",
        )
    }

    func testQuickPickIndexMapsOneBasedChordToZeroBasedRow() {
        let rows = [item("1", "a"), item("2", "b"), item("3", "c")]
        XCTAssertEqual(OpenQuicklyModel.quickPickIndex(1, in: rows), 0)
        XCTAssertEqual(OpenQuicklyModel.quickPickIndex(3, in: rows), 2)
        XCTAssertEqual(
            OpenQuicklyModel.quickPickIndex(2, in: rows).map { rows[$0].title },
            "b",
            "the mapped index addresses the matching visible row",
        )
    }

    func testQuickPickIndexRejectsZeroAndOutOfRange() {
        let rows = [item("1", "a"), item("2", "b")]
        XCTAssertNil(OpenQuicklyModel.quickPickIndex(0, in: rows), "⌘0 is the All pill chord, never a quick-pick")
        XCTAssertNil(OpenQuicklyModel.quickPickIndex(3, in: rows), "past the visible rows → no pick")
        XCTAssertNil(OpenQuicklyModel.quickPickIndex(10, in: rows), "only ⌘1–9 are quick-pick chords")
    }

    // MARK: - clampedSelection: arrow / page / Home / End navigation

    func testClampedSelectionMovesAndClampsToBounds() {
        // Arrow (±1) within range.
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 2, delta: 1, count: 10), 3)
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 2, delta: -1, count: 10), 1)
        // Clamp at the top/bottom edges (no wrap, no underflow/overflow).
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 0, delta: -1, count: 10), 0)
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 9, delta: 1, count: 10), 9)
    }

    func testClampedSelectionPagesAndHomeEndClampWithinList() {
        // PageDown by a page (e.g. step 9) from the top lands mid-list; a second page clamps to the last row.
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 0, delta: 9, count: 30), 9)
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 9, delta: 9, count: 30), 18)
        XCTAssertEqual(
            OpenQuicklyModel.clampedSelection(current: 25, delta: 9, count: 30),
            29,
            "PageDown clamps to last",
        )
        // PageUp by a page from below the page step clamps to the first row, never negative.
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 4, delta: -9, count: 30), 0, "PageUp clamps to first")
        // Home = delta 0 from index 0; End = delta count-1 from index 0 → the last row.
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 0, delta: 0, count: 30), 0, "Home → first row")
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 0, delta: 30 - 1, count: 30), 29, "End → last row")
    }

    func testClampedSelectionEmptyListPinsToZero() {
        XCTAssertEqual(OpenQuicklyModel.clampedSelection(current: 5, delta: -9, count: 0), 0)
        XCTAssertEqual(
            OpenQuicklyModel.clampedSelection(current: 0, delta: 0, count: 0),
            0,
            "Home on an empty list is 0",
        )
        XCTAssertEqual(
            OpenQuicklyModel.clampedSelection(current: 0, delta: -1, count: 0),
            0,
            "End on an empty list is 0",
        )
    }

    // MARK: - rankActions: the ⌘K Actions popover fuzzy filter

    /// A titled stand-in for `LinkActionActuator.RowAction` (which lives in the view module): rankActions is
    /// generic over the action type via the injected `title` projection, so it ranks any titled value.
    private struct FakeAction: Equatable { let title: String }

    func testRankActionsEmptyQueryReturnsAllInOrder() {
        let actions = [FakeAction(title: "Reopen Tab"), FakeAction(title: "Copy CWD Path")]
        let out = OpenQuicklyModel.rankActions(actions, query: "  ", title: { $0.title }, score: subsequenceScore)
        XCTAssertEqual(out, actions, "a blank query is the zero-state — every action, table order preserved")
    }

    func testRankActionsFiltersAndRanksByTitle() {
        let actions = [
            FakeAction(title: "Reveal in Finder"), // "cp": no 'c' before a 'p' subsequence → dropped
            FakeAction(title: "Copy Path"), // "cp": c@0 (front) → high
            FakeAction(title: "Reopen Closed Pane"), // "cp": c@7 → lower than Copy Path
        ]
        let out = OpenQuicklyModel.rankActions(actions, query: "cp", title: { $0.title }, score: subsequenceScore)
        XCTAssertEqual(
            out.map(\.title),
            ["Copy Path", "Reopen Closed Pane"],
            "non-matches dropped; a front-anchored match outranks a later one",
        )
    }

    func testRankActionsStableTieBreakKeepsOriginalOrder() {
        // Two equal-scoring titles (both 'x' at index 0) keep their original relative order (stable sort).
        let actions = [FakeAction(title: "x-alpha"), FakeAction(title: "x-beta")]
        let out = OpenQuicklyModel.rankActions(actions, query: "x", title: { $0.title }, score: subsequenceScore)
        XCTAssertEqual(out.map(\.title), ["x-alpha", "x-beta"])
    }

    // MARK: - Agents builder: Claude-only (ES-E11-4)

    func testAgentItemsDropNonClaudeKinds() {
        let sessions = [
            MetadataCodec.AgentSessionInfo(agentKindByte: 0, id: "c1", title: "Refactor", cwd: "/p", mtimeMS: 2000),
            MetadataCodec.AgentSessionInfo(agentKindByte: 1, id: "x1", title: "Codex run", cwd: "/p", mtimeMS: 3000),
            MetadataCodec.AgentSessionInfo(agentKindByte: 2, id: "o1", title: "OpenCode run", cwd: "/p", mtimeMS: 4000),
        ]
        let items = OpenQuicklyModel.agentItems(from: sessions)
        XCTAssertEqual(items.count, 1, "Agents = Claude Code ONLY (carry-over) — codex/opencode are dropped")
        XCTAssertEqual(items.first?.title, "Refactor")
        XCTAssertEqual(items.first?.kind, .agent)
        XCTAssertEqual(items.first?.subtitle, "/p")
        XCTAssertEqual(items.first?.timestamp, Date(timeIntervalSince1970: 2.0), "mtimeMS → seconds timestamp")
        if case let .resumeAgent(sessionID, cwd) = items.first?.act {
            XCTAssertEqual(sessionID, "c1")
            XCTAssertEqual(cwd, "/p")
        } else {
            XCTFail("an agent row resumes its session")
        }
    }

    func testAgentItemsFallBackTitleAndDropEmptyMeta() {
        let untitled = [
            MetadataCodec.AgentSessionInfo(agentKindByte: 0, id: "sess-42", title: "", cwd: "", mtimeMS: -1),
        ]
        let items = OpenQuicklyModel.agentItems(from: untitled)
        XCTAssertEqual(items.first?.title, "sess-42", "an empty title falls back to the session id")
        XCTAssertNil(items.first?.timestamp, "a non-positive mtime carries no timestamp")
        XCTAssertNil(items.first?.subtitle, "an empty cwd is no subtitle, not a blank one")
    }

    // MARK: - Folders builder (ES-E11-4)

    func testFolderItemsMapNameAndFullPath() {
        let entries = [FolderEntry(path: "/Users/abc/Workplace/myproject", accessCount: 3, lastAccess: t0)]
        let items = OpenQuicklyModel.folderItems(from: entries)
        XCTAssertEqual(items.first?.kind, .folder)
        XCTAssertEqual(items.first?.title, "myproject", "the display title is the last path component")
        XCTAssertEqual(items.first?.subtitle, "/Users/abc/Workplace/myproject")
        XCTAssertEqual(items.first?.searchText, "/Users/abc/Workplace/myproject", "the full path is the fuzzy haystack")
        XCTAssertEqual(items.first?.timestamp, t0)
        if case let .openFolder(path) = items.first?.act {
            XCTAssertEqual(path, "/Users/abc/Workplace/myproject")
        } else {
            XCTFail("a folder row opens its path")
        }
    }

    func testFolderItemsHandleTrailingSlashAndRoot() {
        let trailed = OpenQuicklyModel.folderItems(
            from: [FolderEntry(path: "/var/log/", accessCount: 1, lastAccess: t0)],
        )
        XCTAssertEqual(trailed.first?.title, "log", "a trailing slash does not blank the display name")
        let root = OpenQuicklyModel.folderItems(from: [FolderEntry(path: "/", accessCount: 1, lastAccess: t0)])
        XCTAssertEqual(root.first?.title, "/", "the root path keeps a non-empty display name")
    }

    // MARK: - Current builder (reuses JumpToModel — ES-E11-2 / ES-E11-3)

    func testCurrentItemsWrapJumpToActsVerbatim() {
        let jump = JumpToModel.items(
            links: [
                DetectedLink(row: 0, colStart: 0, colEnd: 14, kind: .url, raw: "https://x.test", resolvedAbsolute: nil),
            ],
            blocks: [BlockSummary(index: 5, commandText: "make build", firstSeen: t0)],
        )
        let items = OpenQuicklyModel.currentItems(from: jump)
        XCTAssertEqual(items.count, 2, "one row per Jump-To item (link first, then the command block)")
        XCTAssertEqual(items[0].kind, .url)
        XCTAssertEqual(items[0].title, "https://x.test")
        XCTAssertEqual(items[1].kind, .command)
        XCTAssertEqual(items[1].title, "make build")
        XCTAssertEqual(items[1].timestamp, t0, "the block's first-seen timestamp is preserved")
        if case let .jumpTo(act) = items[1].act, case let .block(index) = act {
            XCTAssertEqual(index, 5, "the Jump-To act is wrapped verbatim, not re-derived")
        } else {
            XCTFail("a current row wraps its underlying JumpToItem.Act")
        }
    }

    // MARK: - Kind badges / symbols / mapping

    func testKindBadgesArePinned() {
        XCTAssertEqual(OpenQuicklyKind.pane.badge, "Pane")
        XCTAssertEqual(OpenQuicklyKind.folder.badge, "Folder")
        XCTAssertEqual(OpenQuicklyKind.agent.badge, "Agent")
        XCTAssertEqual(OpenQuicklyKind.recentTab.badge, "Tab")
        XCTAssertEqual(OpenQuicklyKind.command.badge, "Cmd")
        XCTAssertEqual(OpenQuicklyKind.prompt.badge, "Prompt")
        XCTAssertEqual(OpenQuicklyKind.path.badge, "Path")
        XCTAssertEqual(OpenQuicklyKind.url.badge, "URL")
        XCTAssertEqual(OpenQuicklyKind.fileURL.badge, "File")
    }

    func testEveryKindHasASymbol() {
        for kind in OpenQuicklyKind.allCases {
            XCTAssertFalse(kind.symbol.isEmpty, "\(kind) must name an SF Symbol for its leading icon")
        }
    }

    func testJumpToKindMapsOntoOpenQuicklyKind() {
        XCTAssertEqual(OpenQuicklyKind(jumpTo: .path), .path)
        XCTAssertEqual(OpenQuicklyKind(jumpTo: .url), .url)
        XCTAssertEqual(OpenQuicklyKind(jumpTo: .fileURL), .fileURL)
        XCTAssertEqual(OpenQuicklyKind(jumpTo: .command), .command)
        XCTAssertEqual(OpenQuicklyKind(jumpTo: .prompt), .prompt)
    }

    // MARK: - Opened / Recent factories (ES-E11-2)

    func testPaneItemFactory() {
        let pid = PaneID(raw: UUID())
        let pane = OpenQuicklyModel.paneItem(paneID: pid, title: "zsh", cwd: "/work")
        XCTAssertEqual(pane.kind, .pane)
        XCTAssertEqual(pane.title, "zsh")
        XCTAssertEqual(pane.subtitle, "/work")
        XCTAssertTrue(
            pane.searchText.contains("zsh") && pane.searchText.contains("/work"),
            "title + cwd are both matchable",
        )
        if case let .focusPane(id) = pane.act {
            XCTAssertEqual(id, pid, "↩ on an Opened row focuses that exact pane")
        } else {
            XCTFail("an Opened row focuses its pane")
        }
    }

    func testRecentTabItemFactory() {
        let recent = OpenQuicklyModel.recentTabItem(index: 2, title: "build", cwd: nil)
        XCTAssertEqual(recent.kind, .recentTab)
        XCTAssertEqual(recent.subtitle, nil)
        if case let .reopenRecentTab(index) = recent.act {
            XCTAssertEqual(index, 2, "a Recent row reopens the closed tab at its LIFO index")
        } else {
            XCTFail("a Recent row reopens its closed tab")
        }
    }

    // MARK: - Composite source builders (whole-tree / whole-LIFO — E11 WI-6)

    /// Builds a one-leaf tab + its spec for the Opened/Recent enumeration fixtures.
    private func leafTab(
        title: String,
        paneTitle: String,
        lastKnownTitle: String? = nil,
        cwd: String? = nil,
    ) -> (Tab, PaneID, PaneSpec) {
        let pid = PaneID(raw: UUID())
        var spec = PaneSpec(kind: .terminal, title: paneTitle)
        spec.lastKnownTitle = lastKnownTitle
        spec.lastKnownCwd = cwd
        let tab = Tab(title: title, root: .leaf(pid), activePane: pid)
        return (tab, pid, spec)
    }

    func testOpenedItemsEnumeratesEveryLivePaneAcrossSessionsAndTabs() {
        let (tabA, pidA, specA) = leafTab(title: "A", paneTitle: "zsh", lastKnownTitle: "vim", cwd: "/work/a")
        let (tabB, pidB, specB) = leafTab(title: "B", paneTitle: "bash", cwd: "")
        let session = Session(
            name: "s1",
            tabs: [tabA, tabB],
            specs: [pidA: specA, pidB: specB],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)

        let items = OpenQuicklyModel.openedItems(from: tree)
        XCTAssertEqual(items.count, 2, "one Opened row per live pane across every session → tab")
        XCTAssertEqual(items.map(\.kind), [.pane, .pane])
        XCTAssertEqual(items[0].title, "vim", "lastKnownTitle wins over the spec title")
        XCTAssertEqual(items[0].subtitle, "/work/a")
        XCTAssertEqual(items[1].title, "bash", "no lastKnownTitle ⇒ the spec title")
        XCTAssertNil(items[1].subtitle, "an empty cwd is no subtitle, not a blank one")
        if case let .focusPane(id) = items[0].act {
            XCTAssertEqual(id, pidA, "↩ on an Opened row focuses that exact pane")
        } else {
            XCTFail("an Opened row focuses its pane")
        }
    }

    func testOpenedItemsTitleFallsBackToGenericWhenSpecMissing() {
        // A leaf with no spec in the side table (a transient invariant gap) still yields a labelled row.
        let pid = PaneID(raw: UUID())
        let tab = Tab(title: "", root: .leaf(pid), activePane: pid)
        let session = Session(name: "s", tabs: [tab], specs: [:])
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let items = OpenQuicklyModel.openedItems(from: tree)
        XCTAssertEqual(items.first?.title, "Pane", "a spec-less pane never renders a blank row")
    }

    func testRecentItemsAreNewestFirstWithLifoIndex() {
        // recentlyClosedTabs is appended OLDEST→newest; the rows must come back newest-first, index 0 on top.
        let (oldTab, oldPid, oldSpec) = leafTab(title: "old", paneTitle: "zsh", cwd: "/old")
        let (newTab, newPid, newSpec) = leafTab(title: "new", paneTitle: "zsh", cwd: "/new")
        let records = [
            RecentlyClosedTab(tab: oldTab, specs: [oldPid: oldSpec], sessionID: nil),
            RecentlyClosedTab(tab: newTab, specs: [newPid: newSpec], sessionID: nil),
        ]
        let items = OpenQuicklyModel.recentItems(from: records)
        XCTAssertEqual(items.map(\.title), ["new", "old"], "the most-recently-closed tab is first")
        XCTAssertEqual(items[0].subtitle, "/new")
        if case let .reopenRecentTab(index) = items[0].act {
            XCTAssertEqual(index, 0, "the top Recent row is LIFO index 0 (the one reopenLastClosedPane pops)")
        } else {
            XCTFail("a Recent row reopens its closed tab")
        }
        if case let .reopenRecentTab(index) = items[1].act {
            XCTAssertEqual(index, 1, "deeper Recent rows carry their LIFO distance")
        } else {
            XCTFail("a Recent row reopens its closed tab")
        }
    }

    func testRecentItemsTitleFallsBackToActivePaneThenGeneric() {
        let pid = PaneID(raw: UUID())
        var spec = PaneSpec(kind: .terminal, title: "")
        spec.lastKnownTitle = "claude"
        let tab = Tab(title: "", root: .leaf(pid), activePane: pid)
        let records = [RecentlyClosedTab(tab: tab, specs: [pid: spec], sessionID: nil)]
        XCTAssertEqual(
            OpenQuicklyModel.recentItems(from: records).first?.title,
            "claude",
            "an empty tab title falls back to the active pane's last-known title",
        )

        let bare = PaneID(raw: UUID())
        let bareTab = Tab(title: "", root: .leaf(bare), activePane: bare)
        let bareRecords = [RecentlyClosedTab(tab: bareTab, specs: [:], sessionID: nil)]
        XCTAssertEqual(
            OpenQuicklyModel.recentItems(from: bareRecords).first?.title,
            "Tab",
            "no title anywhere ⇒ the generic 'Tab' label, never a blank row",
        )
    }

    // MARK: - E21 WI-2: remote-window / system-dialog differentiation in the Opened list

    /// A backing terminal pane (the default `paneKind`) keeps the GENERIC pane chrome — the split glyph, the
    /// "Pane" badge, and a cwd subtitle. Pins the un-changed path so the WI-2 differentiation can be added
    /// without regressing the common terminal row. Revert-to-confirm-fail: a model that always emitted the
    /// window glyph/badge would fail here.
    func testPaneItemBackingTerminalKeepsGenericPaneChrome() {
        let pid = PaneID(raw: UUID())
        let row = OpenQuicklyModel.paneItem(paneID: pid, title: "zsh", cwd: "/work")
        XCTAssertEqual(row.kind, .pane)
        XCTAssertEqual(row.paneKind, .terminal, "the default backing kind is a terminal")
        XCTAssertEqual(row.badge, "Pane", "a terminal pane is a generic 'Pane', not a window")
        XCTAssertEqual(row.symbol, "rectangle.split.2x1", "a terminal pane keeps the split glyph")
        XCTAssertEqual(row.subtitle, "/work", "a terminal pane's subtitle is its cwd")
    }

    /// A `.remoteGUI` backing pane reads as a WINDOW: the window glyph (`display`), a "Window" badge, and the
    /// kind-generic `.focusPane` `Act` (`↩` focuses it exactly as a terminal row). With NO app name threaded
    /// AND no cwd, the subtitle is NIL — a single line, never an echo of the window title already on line 1
    /// (Batch-4 item 4: the host app shows on line 2 ONLY when it is distinct; a window-title "fallback" would
    /// merely duplicate line 1). The host-app subtitle for a real binding is covered by
    /// `RemoteGUIFirstClassPeerTests.testOpenedItemsDifferentiatesTheRemoteWindowRow` (appName threaded).
    func testPaneItemRemoteGUIReadsAsAWindow() {
        let pid = PaneID(raw: UUID())
        let row = OpenQuicklyModel.paneItem(paneID: pid, title: "Safari — GitHub", cwd: nil, paneKind: .remoteGUI)
        XCTAssertEqual(row.kind, .pane, "the row kind stays `.pane` so the Act is the kind-generic focus")
        XCTAssertEqual(row.paneKind, .remoteGUI)
        XCTAssertEqual(row.badge, "Window", "a `.remoteGUI` pane is badged a 'Window', not a 'Pane'")
        XCTAssertEqual(row.symbol, "display", "a remote window uses the window glyph, not the split glyph")
        XCTAssertNil(row.subtitle, "no app name + no cwd ⇒ single line, never an echo of the window title")
        if case let .focusPane(id) = row.act {
            XCTAssertEqual(id, pid, "↩ on a remote-window row still focuses that exact pane")
        } else {
            XCTFail("a remote-window Opened row focuses its pane")
        }
    }

    /// The auto `.systemDialog` video pane is differentiated too — the same window glyph, but a "Dialog" badge
    /// (it streams a host SYSTEM prompt, not a user-picked window). Total mapping: both video kinds are windows.
    /// With no app name threaded the subtitle is nil (single line, no window-title echo — item 4).
    func testPaneItemSystemDialogReadsAsADialog() {
        let pid = PaneID(raw: UUID())
        let row = OpenQuicklyModel.paneItem(paneID: pid, title: "Authenticate", cwd: nil, paneKind: .systemDialog)
        XCTAssertEqual(row.paneKind, .systemDialog)
        XCTAssertEqual(row.badge, "Dialog", "a `.systemDialog` pane is badged a 'Dialog'")
        XCTAssertEqual(row.symbol, "display", "a dialog window uses the window glyph")
        XCTAssertNil(row.subtitle, "no app name + no cwd ⇒ single line, never an echo of the dialog title")
    }

    /// A real cwd always wins over the host/window-title fallback (defensive — a video pane normally reports no
    /// cwd, but the subtitle must never silently drop a working directory if one is present).
    func testPaneItemVideoCwdWinsOverWindowSubtitle() {
        let pid = PaneID(raw: UUID())
        let row = OpenQuicklyModel.paneItem(paneID: pid, title: "Safari", cwd: "/tmp/x", paneKind: .remoteGUI)
        XCTAssertEqual(row.subtitle, "/tmp/x", "a present cwd takes precedence over the window-title fallback")
    }

    /// Only the VIDEO kinds are windows — a non-video, non-terminal pane (`.chooser`) keeps the generic
    /// pane glyph/badge and, with no cwd, carries NO subtitle (no window-title fallback). Pins that the
    /// differentiation is keyed on ``PaneKind/isVideo``, not "anything that is not a terminal".
    func testPaneItemNonVideoKindsKeepGenericPaneChrome() {
        let chooser = OpenQuicklyModel.paneItem(
            paneID: PaneID(raw: UUID()),
            title: "Choose…",
            cwd: nil,
            paneKind: .chooser,
        )
        XCTAssertEqual(chooser.badge, "Pane", "a chooser pane is not a window")
        XCTAssertEqual(chooser.symbol, "rectangle.split.2x1", "a chooser pane keeps the generic pane glyph")
        XCTAssertNil(chooser.subtitle, "a non-video pane with no cwd carries no subtitle (no window-title fallback)")
    }

    /// `openedItems` threads `spec.kind` so a mixed tree yields a differentiated row per pane: the terminal row
    /// keeps its generic chrome + cwd; the `.remoteGUI` row reads as a window (glyph + "Window" badge + a
    /// host/window subtitle). End-to-end pin of the WI-2 thread. Revert-to-confirm-fail: dropping the `paneKind:`
    /// argument in `openedItems` reverts the video row to "Pane"/split/nil and fails the window assertions.
    func testOpenedItemsDifferentiatesVideoPanesFromTerminalPanes() {
        let termID = PaneID(raw: UUID())
        let videoID = PaneID(raw: UUID())
        var termSpec = PaneSpec(kind: .terminal, title: "zsh")
        termSpec.lastKnownCwd = "/work/proj"
        let videoSpec = PaneSpec(
            kind: .remoteGUI,
            title: "Safari — GitHub",
            video: VideoEndpoint(windowID: 5, title: "Safari — GitHub", appName: "Safari"),
        )
        let termTab = Tab(title: "T", root: .leaf(termID), activePane: termID)
        let videoTab = Tab(title: "V", root: .leaf(videoID), activePane: videoID)
        let session = Session(name: "s", tabs: [termTab, videoTab], specs: [termID: termSpec, videoID: videoSpec])
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)

        let items = OpenQuicklyModel.openedItems(from: tree)
        XCTAssertEqual(items.count, 2, "one Opened row per live pane — the terminal AND the remote window")
        let termRow = items.first { $0.act == .focusPane(termID) }
        let videoRow = items.first { $0.act == .focusPane(videoID) }

        XCTAssertEqual(termRow?.badge, "Pane", "the terminal row keeps the generic pane badge")
        XCTAssertEqual(termRow?.symbol, "rectangle.split.2x1", "the terminal row keeps the split glyph")
        XCTAssertEqual(termRow?.subtitle, "/work/proj", "the terminal row's subtitle is its cwd")

        XCTAssertEqual(videoRow?.kind, .pane, "the video row's OpenQuicklyKind stays `.pane` (kind-generic Act)")
        XCTAssertEqual(videoRow?.paneKind, .remoteGUI, "openedItems threaded the spec's `.remoteGUI` kind")
        XCTAssertEqual(videoRow?.badge, "Window", "the `.remoteGUI` row is badged a 'Window'")
        XCTAssertEqual(videoRow?.symbol, "display", "the `.remoteGUI` row uses the window glyph")
        // F2: no cwd ⇒ the subtitle is the host-side APP name (line 2), NOT an echo of the window title on
        // line 1. Pre-fix `paneRowSubtitle` returned the title, printing identical text on both lines.
        XCTAssertEqual(videoRow?.subtitle, "Safari", "no cwd ⇒ the host app name is the subtitle (not the title)")
        XCTAssertNotEqual(videoRow?.subtitle, videoRow?.title, "F2: the subtitle must not echo the row title")
    }
}
