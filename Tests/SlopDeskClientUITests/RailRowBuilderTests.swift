// RailRowBuilderTests — pins the E6 WI-2 enrichment of `RailRow`: every rail row now carries the 1-based
// tab shortcut number (`#N`), the host-reported foreground-process label, and the single fused status badge
// from the pure `TabBadgeResolver`, in addition to the title/cwd-subtitle the filter narrows on.
//
// Headless: a tree-model `WorkspaceStore` over the tiny `MountTestPaneSession` fake (no socket, no video,
// no Metal/SCStream — per the hang-safety rule). The badge inputs are seeded through the store's PUBLIC
// mutators (`setAgentStatus` / `setCompletionBadge` / `setForegroundProcess`) so the test never touches a
// real `LivePaneSession`. Each assertion fails on the pre-WI-2 `RailRow` (which carried none of these
// fields), so none is tautological.

import XCTest
@testable import SlopDeskClientUI
@testable import SlopDeskWorkspaceCore

@MainActor
final class RailRowBuilderTests: XCTestCase {
    /// A headless tree-model store over the fake session (mirrors `OverlayCoordinatorMountTests`).
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { MountTestPaneSession($0) })
    }

    /// The pane id of the row at `index` in the freshly-built rail (the rows are rebuilt each call so a
    /// caller reads the LATEST derived value after seeding the store).
    private func paneID(_ store: WorkspaceStore, row index: Int) -> PaneID {
        RailRowsBuilder.rows(for: store)[index].id
    }

    // MARK: - `#N` (the tab shortcut number)

    /// Every row carries the 1-based index of its TAB within the session (the ⌘1…⌘9 target), in tab order.
    func testTabNumberIsOneBasedTabIndex() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // 2nd tab
        store.newTab(kind: .terminal, launchGrace: .zero) // 3rd tab
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 3, "one single-pane tab each → three rows")
        XCTAssertEqual(rows.map(\.tabNumber), [1, 2, 3], "tabNumber == tabIndex + 1 in tab order")
    }

    /// Both panes of a SPLIT tab share the SAME `#N` (it is a tab number, not a pane number — plan Design #1).
    func testSplitTabPanesShareTabNumber() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // a 2nd tab so the split tab is `#1` and `#2` differ
        // Split the active tab into two panes.
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        // The split tab now contributes two rows; group rows by their tabID and assert each tab's rows share
        // one tabNumber.
        let byTab = Dictionary(grouping: rows, by: \.tabID)
        for (_, tabRows) in byTab {
            let numbers = Set(tabRows.map(\.tabNumber))
            XCTAssertEqual(numbers.count, 1, "all panes of a tab carry that tab's single #N")
        }
    }

    // MARK: - Badge fusion (the pure `TabBadgeResolver` reached through the row)

    /// A fresh pane (no agent status, no completion, no foreground process, idle shell) is all-clear → no badge.
    func testAllClearRowHasNoBadge() {
        let store = makeStore()
        XCTAssertNil(RailRowsBuilder.rows(for: store)[0].badge)
    }

    /// A blocked agent (`needsPermission`) surfaces the highest-urgency `.awaitingInput` badge.
    func testAwaitingInputBadgeFromBlockedAgent() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setAgentStatus(.needsPermission, for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .awaitingInput)
    }

    /// A failed command (`.failure` completion) surfaces the `.error` badge.
    func testErrorBadgeFromFailureCompletion() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setCompletionBadge(.failure, for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .error)
    }

    /// A JUST-completed clean exit (`.success`) surfaces the brief `.completed` checkmark flash — the
    /// stamp is fresh (the rows build microseconds later, inside the flash window).
    func testCompletedBadgeFromFreshSuccessCompletion() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setCompletionBadge(.success, for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .completed)
    }

    /// A SETTLED clean exit (the `.success` landed longer ago than the flash window) surfaces the
    /// persistent `.finished` accent dot — proving the settled unread-output marker is reachable end-to-end
    /// through the rail (NOT a perpetual checkmark). The stamp is injected in the past so the row settles.
    func testFinishedAccentDotFromSettledSuccessCompletion() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        let stale = Date().addingTimeInterval(-(WorkspaceStore.completedFlashWindow + 5))
        store.setCompletionBadge(.success, for: pane, at: stale)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .finished)
    }

    /// Most-urgent wins: a blocked agent beats a failure completion on the same pane.
    func testAwaitingInputBeatsError() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setCompletionBadge(.failure, for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].badge, .awaitingInput)
    }

    // MARK: - E20 ES-E20-3: manual `tab badge --kind` override on the representative row

    /// A manual tab-badge override (the store seam the `tab badge --kind` CLI writes) renders on the tab's
    /// REPRESENTATIVE pane row, winning over the derived badge — proving the command is no longer a no-op
    /// end-to-end through the rail. Fails on the pre-fix builder, which never consulted the override.
    func testManualTabBadgeOverrideShowsOnRepresentativeRow() {
        let store = makeStore()
        let tab = RailRowsBuilder.rows(for: store)[0].tabID
        XCTAssertNil(RailRowsBuilder.rows(for: store)[0].badge, "all-clear before any override")

        store.setTabBadgeOverride(.error, for: tab)
        XCTAssertEqual(
            RailRowsBuilder.rows(for: store)[0].badge, .error,
            "the manual override surfaces on the tab's representative row",
        )

        store.setTabBadgeOverride(nil, for: tab)
        XCTAssertNil(RailRowsBuilder.rows(for: store)[0].badge, "clearing the override returns to all-clear")
    }

    /// The manual override BYPASSES the per-pane agent-badge gates (it is an explicit CLI affordance, not an
    /// agent signal): with the pane's `whileProcessing` gate OFF — which would suppress an AGENT-derived
    /// `.running` spinner — a manual `.running` override still renders. Fails if the override were routed through
    /// `TabBadgeGating.resolve`.
    func testManualTabBadgeOverrideBypassesAgentBadgeGates() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        let tab = RailRowsBuilder.rows(for: store)[0].tabID
        store.setAgentBadgeOverride(
            AgentBadgeGates(badgeWhileProcessing: false, badgeWhenComplete: true, badgeWhenAwaitingInput: true),
            for: pane,
        )
        store.setTabBadgeOverride(.running, for: tab)
        XCTAssertEqual(
            RailRowsBuilder.rows(for: store)[0].badge, .running,
            "an explicit manual override is not subject to the agent-badge gates",
        )
    }

    /// The override is strictly per-tab: badging tab #1 leaves tab #2's row unbadged.
    func testManualTabBadgeOverrideIsPerTab() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // a 2nd tab
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 2)
        store.setTabBadgeOverride(.error, for: rows[0].tabID)

        let after = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(after.first { $0.tabID == rows[0].tabID }?.badge, .error, "tab #1 shows the override")
        XCTAssertNil(after.first { $0.tabID == rows[1].tabID }?.badge, "tab #2 is untouched")
    }

    /// In a SPLIT tab the override renders on the REPRESENTATIVE (active) pane row ONLY, not its sibling —
    /// one badge per tab, matching the per-tab badge model and the `tab list` representative.
    func testManualTabBadgeOverrideOnlyOnRepresentativePaneOfSplitTab() {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 2, "the split tab contributes two pane rows")
        store.setTabBadgeOverride(.error, for: rows[0].tabID)

        let after = RailRowsBuilder.rows(for: store)
        let representative = store.tree.activeSession?.activeTab?.activePane
        let badged = after.filter { $0.badge == .error }
        XCTAssertEqual(badged.count, 1, "exactly one row carries the per-tab override")
        XCTAssertEqual(badged.first?.id, representative, "and it is the tab's representative (active) pane row")
    }

    // MARK: - Foreground-process label + privilege badges

    /// The row mirrors the host-reported foreground process and classifies a `caffeinate` session (at rest)
    /// into the coffee badge.
    func testCaffeinateProcessLabelAndBadge() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("caffeinate", for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertEqual(row.processLabel, "caffeinate")
        XCTAssertEqual(row.badge, .caffeinate)
    }

    /// A `sudo` foreground (by lowercased basename of a full path) classifies into the shield badge.
    func testSudoProcessBadgeByBasename() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("/usr/bin/sudo", for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertEqual(row.processLabel, "/usr/bin/sudo", "the label is the verbatim host string")
        XCTAssertEqual(row.badge, .sudo)
    }

    /// A plain process (e.g. `zsh`) shows as the trailing label but is NOT a privilege badge.
    func testPlainProcessLabelNoBadge() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("/bin/zsh", for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertEqual(row.processLabel, "/bin/zsh")
        XCTAssertNil(row.badge, "zsh is not in the privilege allow-set")
    }

    /// An empty / whitespace-only foreground name removes the mirror (treated as "no process").
    func testEmptyForegroundProcessClearsLabel() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("caffeinate", for: pane)
        store.setForegroundProcess("   ", for: pane)
        XCTAssertNil(store.paneForegroundProcess[pane])
        XCTAssertNil(RailRowsBuilder.rows(for: store)[0].processLabel)
    }

    /// A closed pane's foreground-process mirror is pruned on reconcile (no unbounded growth / stale label).
    func testForegroundProcessPrunedWhenTabCloses() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 2)
        let pane = rows[1].id
        let tab = rows[1].tabID
        store.setForegroundProcess("caffeinate", for: pane)
        XCTAssertEqual(store.paneForegroundProcess[pane], "caffeinate")
        store.closeTab(tab)
        XCTAssertNil(
            store.paneForegroundProcess[pane],
            "a closed pane's foreground-process mirror must drop out on the reconcile prune",
        )
    }

    // MARK: - E17 WI-3: the read-only lock flag (sidebar indicator ⟂ pane pill, one source of truth)

    /// A row's `readOnly` mirrors the store's convergent ``WorkspaceStore/paneReadOnly`` set, so the sidebar
    /// lock glyph and the pane's `🔒 READ ONLY ×` pill read ONE truth. Locking the pane lights the flag;
    /// unlocking clears it. Fails on the pre-WI-3 `RailRow` (no `readOnly` field ⇒ won't compile) and on a
    /// build that derived the flag from anything but the store set (the assertion checks the row against the
    /// store's `isReadOnly(for:)`, not against its own input).
    func testReadOnlyFlagMirrorsTheStoreSet() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        XCTAssertFalse(RailRowsBuilder.rows(for: store)[0].readOnly, "a fresh pane is editable → no lock")

        store.setPaneReadOnly(pane, true)
        XCTAssertTrue(store.isReadOnly(for: pane), "the store recorded the lock in its convergent set")
        XCTAssertTrue(RailRowsBuilder.rows(for: store)[0].readOnly, "and the row surfaces it for the lock glyph")

        store.setPaneReadOnly(pane, false)
        XCTAssertFalse(RailRowsBuilder.rows(for: store)[0].readOnly, "unlocking clears the row flag")
    }

    /// The lock is strictly per-pane: locking one pane of a split tab leaves its sibling's row unlocked
    /// (splitting gives a fresh editable pane; the read-only state does not propagate to siblings).
    func testReadOnlyFlagIsPerPane() {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows.count, 2, "the split tab contributes two pane rows")

        store.setPaneReadOnly(rows[0].id, true)
        let after = RailRowsBuilder.rows(for: store)
        XCTAssertTrue(after.first { $0.id == rows[0].id }?.readOnly ?? false, "the locked pane's row shows the lock")
        XCTAssertFalse(after.first { $0.id == rows[1].id }?.readOnly ?? true, "its sibling row stays unlocked")
    }

    // MARK: - cwd folder-name title + git-line/cwd subtitle + the reused title+subtitle filter

    /// A terminal row with a known cwd titles itself by the cwd's FOLDER NAME (line 1) and keeps the
    /// full cwd as the subtitle (line 2) while no git summary is cached; `filtered` narrows by BOTH.
    /// Fails on the pre-fix builder (line 1 was the generic "Terminal").
    func testSubtitleCwdAndFilter() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/project-alpha", for: pane)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows[0].title, "project-alpha", "line 1 is the cwd folder name, not 'Terminal'")
        XCTAssertEqual(rows[0].subtitle, "/Users/me/project-alpha")
        // The generic default no longer matches anything (the title IS the folder name now).
        XCTAssertTrue(RailRowsBuilder.filtered(rows, query: "term").isEmpty)
        // Folder-name/title + cwd/subtitle match.
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "project-alpha").map(\.id), [pane])
        // No match anywhere.
        XCTAssertTrue(RailRowsBuilder.filtered(rows, query: "zzz-nope").isEmpty)
    }

    /// A cached ``PaneGitSummary`` upgrades the terminal row's second line from the raw cwd to the
    /// compact git line; a non-repo summary keeps the cwd fallback. Fails on the pre-fix builder
    /// (subtitle was unconditionally `railSubtitle`).
    func testGitSummaryUpgradesSubtitleToGitLine() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/project-alpha", for: pane)
        store.paneGitSummary[pane] = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 1, behind: 0, changedCount: 3, modified: 3,
        )
        XCTAssertEqual(
            RailRowsBuilder.rows(for: store)[0].subtitle, "main ↑1 !3",
            "line 2 is the compact git line when the cwd is a repo",
        )
        store.paneGitSummary[pane] = PaneGitSummary(
            hasRepo: false, branch: "", ahead: 0, behind: 0, changedCount: 0,
        )
        XCTAssertEqual(
            RailRowsBuilder.rows(for: store)[0].subtitle, "/Users/me/project-alpha",
            "a non-repo cwd falls back to the plain path subtitle",
        )
    }

    /// The title precedence for a terminal row: an EXPLICIT rename beats the folder name, the folder
    /// name beats the shell-title chain, and a cwd-less pane keeps the old fallback ("Terminal").
    func testRowTitlePrecedence() {
        // B2: a rename now rides the explicit `userRenamed` flag (set by `renamePane`), not a title-vs-cwd
        // heuristic — so the folder name is overridden only for a genuinely user-renamed pane.
        let renamed = PaneSpec(kind: .terminal, title: "build box", lastKnownCwd: "/srv/app", userRenamed: true)
        XCTAssertEqual(RailRowsBuilder.rowTitle(kind: .terminal, spec: renamed), "build box")

        let unnamed = PaneSpec(kind: .terminal, title: "Terminal", lastKnownCwd: "/srv/app")
        XCTAssertEqual(RailRowsBuilder.rowTitle(kind: .terminal, spec: unnamed), "app")

        // The load-time auto-promotion (`title == lastKnownTitle`) is NOT a rename — folder name wins.
        let promoted = PaneSpec(
            kind: .terminal, title: "zsh — slopdesk", lastKnownCwd: "/srv/app",
            lastKnownTitle: "zsh — slopdesk",
        )
        XCTAssertEqual(RailRowsBuilder.rowTitle(kind: .terminal, spec: promoted), "app")

        let noCwd = PaneSpec(kind: .terminal, title: "Terminal")
        XCTAssertEqual(RailRowsBuilder.rowTitle(kind: .terminal, spec: noCwd), "Terminal")

        // Non-terminal kinds keep the E21 chain untouched.
        let video = PaneSpec(kind: .remoteGUI, title: "Docs", lastKnownTitle: "Docs — Safari")
        XCTAssertEqual(RailRowsBuilder.rowTitle(kind: .remoteGUI, spec: video), "Docs — Safari")
    }

    /// B2 regression: the OLD heuristic (`title != lastKnownTitle`) MISFIRED once a shell emitted a SECOND
    /// OSC title — `title` stayed the load-time-promoted first title while `lastKnownTitle` advanced, so the
    /// stale promoted title latched as a phantom "rename". With the explicit `userRenamed` flag (false here),
    /// the FOLDER NAME wins. Revert-to-confirm-fail: the pre-B2 code returned "zsh — proj-v1" for this spec.
    func testRowTitleDoesNotMisfireAsRenameWhenShellEmitsSecondOSCTitle() {
        let secondTitle = PaneSpec(
            kind: .terminal, title: "zsh — proj-v1", lastKnownCwd: "/srv/app",
            lastKnownTitle: "zsh — proj-v2", userRenamed: false,
        )
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(kind: .terminal, spec: secondTitle), "app",
            "a shell's changing OSC title is NOT a user rename — the folder name still titles the pane",
        )
    }

    /// A4: a cwd-less pane running a real foreground program titles itself by that program (host wire type
    /// 26), while a bare login shell is suppressed (titling a pane "zsh" is no better than "Terminal").
    func testRowTitleFallsBackToForegroundProcessWhenNoCwd() {
        let spec = PaneSpec(kind: .terminal, title: "Terminal") // no cwd, no live title

        XCTAssertEqual(
            RailRowsBuilder.rowTitle(kind: .terminal, spec: spec, processLabel: "vim"), "vim",
            "a real foreground program names the pane when the cwd is not known yet",
        )
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(kind: .terminal, spec: spec, processLabel: "/usr/local/bin/npm"), "npm",
            "the process label is basenamed",
        )
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(kind: .terminal, spec: spec, processLabel: "-zsh"), "Terminal",
            "a bare login shell is suppressed — it falls through to the generic chain, not \"zsh\"",
        )
        // A known cwd still beats the process fallback.
        let withCwd = PaneSpec(kind: .terminal, title: "Terminal", lastKnownCwd: "/srv/app")
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(kind: .terminal, spec: withCwd, processLabel: "vim"), "app",
            "the cwd folder name is the primary identity; the process fallback is only for a cwd-less pane",
        )
    }

    /// The folder-name helper: leaf extraction, trailing-slash tolerance, root, blank → nil.
    func testCwdFolderName() {
        XCTAssertEqual(RailRowsBuilder.cwdFolderName("/Users/dev/slop-desk"), "slop-desk")
        XCTAssertEqual(RailRowsBuilder.cwdFolderName("/srv/app/"), "app")
        XCTAssertEqual(RailRowsBuilder.cwdFolderName("/"), "/")
        XCTAssertEqual(RailRowsBuilder.cwdFolderName("~"), "~")
        XCTAssertNil(RailRowsBuilder.cwdFolderName("   "))
        XCTAssertNil(RailRowsBuilder.cwdFolderName(nil))
    }

    // MARK: - E21 WI-5: a `.remoteGUI` pane reads as a labelled window in the rail

    /// A remote-window (`.remoteGUI`) pane is a first-class rail peer: its row carries the host-side APP name
    /// as the muted second line — a video pane has no shell cwd, so the pre-E21-WI-5 builder (`spec?.lastKnownCwd`)
    /// produced a `nil` subtitle (a bare single-line window row). The window title stays on line 1, and the
    /// read-only lock flag still mirrors the store's convergent set kind-generically. Fails on the pre-WI-5
    /// builder (nil video subtitle), so it is not tautological.
    func testRemoteWindowRowGetsHostAppSubtitleAndLock() throws {
        let store = makeStore()
        let video = store.newRemoteWindowTab(windowID: 4242, title: "Docs", appName: "Safari")

        let row = try XCTUnwrap(
            RailRowsBuilder.rows(for: store).first { $0.id == video },
            "the minted remote-window pane is enumerated as a first-class rail row",
        )
        XCTAssertEqual(row.kind, .remoteGUI, "the row keeps its video kind")
        XCTAssertEqual(row.title, "Docs", "line 1 is the window title")
        XCTAssertEqual(row.subtitle, "Safari", "line 2 is the host-side app name (was nil pre-WI-5)")
        XCTAssertFalse(row.readOnly, "a fresh remote window is writable")

        store.setPaneReadOnly(video, true)
        let locked = try XCTUnwrap(RailRowsBuilder.rows(for: store).first { $0.id == video })
        XCTAssertTrue(locked.readOnly, "the read-only lock flag is kind-generic on a video pane")
    }

    // MARK: - E21 ES-E21-2/-4: a split `.remoteGUI` pane stays a first-class peer (rail + palette)

    /// A `.remoteGUI` remote window sharing its tab with a terminal sibling must NOT vanish from the
    /// sidebar rail or the ⌘K jump-to-pane palette — ES-E21-2 ("a remote window must appear in palette …
    /// the sidebar") and the ES-E21-4 peer-drop sweep. Asserts it remains in BOTH `RailRowsBuilder.rows`
    /// and `TabsPaletteSource.snapshot(...).candidates`.
    func testSplitRemoteWindowStaysInRailAndPalette() {
        let store = makeStore()
        let remote = store.newRemoteWindowTab(windowID: 7777, title: "Docs", appName: "Safari")
        // Add a terminal sibling so the remote pane is one of several leaves in its tab.
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        store.focusPaneTree(remote)

        // Rail: the remote pane is still a row.
        XCTAssertNotNil(
            RailRowsBuilder.rows(for: store).first { $0.id == remote },
            "a split remote window must stay in the sidebar rail (ES-E21-2)",
        )

        // Palette: the remote pane is still a jump-to-pane candidate.
        let paletteIDs = TabsPaletteSource.snapshot(store)
            .candidates(query: "")
            .map(\.id)
        XCTAssertTrue(
            paletteIDs.contains("tab.\(remote.raw.uuidString)"),
            "a split remote window must stay in the ⌘K jump-to-pane palette (ES-E21-2)",
        )
    }

    // MARK: - The always-on By-Project sectioning (search filter × per-pane project buckets)

    /// A three-tab store with two distinct project cwds. Tabs 1+2 share `…/alpha`, tab 3 is `…/beta`.
    private func makeThreeProjectStore() -> WorkspaceStore {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // tab 2
        store.newTab(kind: .terminal, launchGrace: .zero) // tab 3
        let rows = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/Users/me/alpha", for: rows[0].id)
        store.setLastKnownCwd("/Users/me/alpha", for: rows[1].id)
        store.setLastKnownCwd("/Users/me/beta", for: rows[2].id)
        return store
    }

    /// The survivors bucket into project sections (basename headers): the two `…/alpha` tabs land together
    /// in section 1, the lone `…/beta` tab in section 2 — first-appearance (creation) order.
    func testSectionedByProjectBucketsRowsByCreationOrder() {
        let store = makeThreeProjectStore()
        let sections = RailRowsBuilder.sectionedByProject(
            RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        XCTAssertEqual(sections.map(\.header), ["alpha", "beta"], "section headers are the cwd basenames")
        XCTAssertEqual(sections[0].rows.map(\.tabNumber), [1, 2], "both alpha tabs share section 1")
        XCTAssertEqual(sections[1].rows.map(\.tabNumber), [3], "the lone beta tab is section 2")
    }

    /// The search filter composes with the grouping: a query that only matches the `beta` cwd drops the
    /// entire `alpha` section (no empty header survives). Fails on a naive map that kept zero-row sections.
    func testSectionedDropsEmptySectionAfterFilter() {
        let store = makeThreeProjectStore()
        let sections = RailRowsBuilder.sectionedByProject(
            RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "beta",
        )
        XCTAssertEqual(sections.map(\.header), ["beta"], "the alpha section filters out entirely → dropped")
        XCTAssertEqual(sections[0].rows.map(\.tabNumber), [3])
    }

    /// A HOST-pushed project key (wire type 34 → `setProjectKey`) re-buckets the pane by the pushed repo
    /// root instead of the cwd fallback — the end-to-end store → row → section path for the host key.
    func testSectionedByProjectUsesHostPushedKeyOverCwd() {
        let store = makeThreeProjectStore()
        let beta = RailRowsBuilder.rows(for: store)[2].id
        store.setProjectKey("/work/monorepo", for: beta)
        let sections = RailRowsBuilder.sectionedByProject(
            RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        XCTAssertEqual(
            sections.map(\.header), ["alpha", "monorepo"],
            "the host-pushed key wins over the cwd-derived section for that pane",
        )
        XCTAssertEqual(sections.last?.rows.map(\.id), [beta])
    }

    // MARK: - Per-pane By-Project sectioning (the split-tab "group name flickers with focus" bug)

    /// A SPLIT tab whose two panes are in DIFFERENT projects must land its panes in their RESPECTIVE project
    /// sections — and that placement must be FOCUS-INDEPENDENT. The old tab-level grouping keyed the WHOLE
    /// tab by `tab.activePane`, so focusing pane A titled the section by A's cwd and focusing pane B flipped
    /// it to B's cwd (the reported flicker). `sectionedByProject` buckets each pane by ITS OWN `projectKey`,
    /// so both the membership and the headers are identical regardless of which pane is focused. FAILS on any
    /// tab-level implementation (both panes collapse into one focus-dependent section).
    func testByProjectSectioningIsPerPaneAndFocusIndependent() {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let rows0 = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows0.count, 2, "one split tab → two pane rows in one tab")
        let paneA = rows0[0].id
        let paneB = rows0[1].id
        store.setLastKnownCwd("/Users/me/alpha", for: paneA)
        store.setLastKnownCwd("/Users/me/beta", for: paneB)

        func sections() -> [RailRowGroup] {
            RailRowsBuilder.sectionedByProject(
                RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
            )
        }

        store.focusPaneTree(paneA)
        let withA = sections()
        XCTAssertEqual(withA.map(\.header), ["alpha", "beta"], "each pane buckets into its OWN project section")
        XCTAssertEqual(withA.first { $0.header == "alpha" }?.rows.map(\.id), [paneA], "pane A → alpha section")
        XCTAssertEqual(withA.first { $0.header == "beta" }?.rows.map(\.id), [paneB], "pane B → beta section")

        store.focusPaneTree(paneB)
        let withB = sections()
        XCTAssertEqual(withB.map(\.header), withA.map(\.header), "section headers do NOT flicker with focus")
        XCTAssertEqual(withB.first { $0.header == "alpha" }?.rows.map(\.id), [paneA], "pane A stays in alpha")
        XCTAssertEqual(withB.first { $0.header == "beta" }?.rows.map(\.id), [paneB], "pane B stays in beta")
    }

    /// A single-pane tab is UNCHANGED by the per-pane path (its one pane == the tab's project): three
    /// single-pane tabs across two projects yield the same two sections the tab-level path produced.
    func testByProjectSectioningSinglePaneTabsMatchTabLevel() {
        let store = makeThreeProjectStore()
        let sections = RailRowsBuilder.sectionedByProject(
            RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        XCTAssertEqual(sections.map(\.header), ["alpha", "beta"], "single-pane tabs group exactly as before")
        XCTAssertEqual(sections[0].rows.map(\.tabNumber), [1, 2], "both alpha tabs in section 1")
        XCTAssertEqual(sections[1].rows.map(\.tabNumber), [3], "the lone beta tab in section 2")
    }

    /// A pane with no project key (a video pane, or a cwd-less terminal) lands in the deterministic "Other"
    /// bucket, ordered by first appearance; the query filter still composes and drops an all-filtered section.
    func testByProjectSectioningKeylessPaneGoesToOther() {
        let store = makeThreeProjectStore()
        // Blank tab-3's cwd so its pane is keyless → "Other" (tab 3 is the third single-pane row).
        let beta = RailRowsBuilder.rows(for: store)[2].id
        store.setLastKnownCwd("", for: beta)
        let sections = RailRowsBuilder.sectionedByProject(
            RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        XCTAssertEqual(sections.map(\.header), ["alpha", "Other"], "the keyless pane falls into Other, last")
        XCTAssertEqual(sections.last?.rows.map(\.id), [beta])
    }

    /// By-Project SECTION order is STABLE across a tab switch: selecting a tab must NOT reorder the
    /// sections (they follow first-appearance in `session.tabs` — creation order — never focus/recency).
    /// Two single-pane tabs in different projects keep their creation-order section layout regardless of
    /// which is focused.
    func testByProjectSectionOrderStableAcrossTabSwitch() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // two single-pane tabs
        let rows0 = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/work/alpha", for: rows0[0].id)
        store.setLastKnownCwd("/work/beta", for: rows0[1].id)

        func headers() -> [String?] {
            RailRowsBuilder.sectionedByProject(
                RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
            ).map(\.header)
        }

        store.selectTab(0)
        XCTAssertEqual(headers(), ["alpha", "beta"], "creation-order section layout")
        store.selectTab(1)
        XCTAssertEqual(
            headers(), ["alpha", "beta"],
            "section order stays put across a tab switch — creation order, never focus-derived",
        )
    }

    /// Two panes in the SAME directory reported with an inconsistent trailing slash (`/work/api` vs
    /// `/work/api/` — e.g. a git toplevel vs an OSC-7 `$PWD`, or a `.path` policy) must land in ONE section,
    /// not two identically-titled "api" sections. `normalizedProjectKey` strips the trailing slash before
    /// bucketing. FAILS on the un-normalized key (two distinct dictionary keys → two "api" sections).
    func testByProjectMergesTrailingSlashKeys() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let rows0 = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/work/api", for: rows0[0].id)
        store.setLastKnownCwd("/work/api/", for: rows0[1].id)
        let sections = RailRowsBuilder.sectionedByProject(
            RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        XCTAssertEqual(sections.map(\.header), ["api"], "trailing-slash variants merge into one section")
        XCTAssertEqual(sections[0].rows.count, 2, "both panes land in the single api section")
    }

    // MARK: - C3 BUG A: path-searchable row + collision disambiguation

    /// A git-repo row's VISIBLE subtitle is the git line (not the path), yet the row stays searchable BY PATH
    /// via the hidden `cwd` key — the C3 BUG A fix. Fails on the pre-fix builder, whose filter only matched
    /// title + subtitle, so a path query against a git row returned nothing.
    func testFilterMatchesCwdEvenWhenSubtitleIsGitLine() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/worktrees/feature-x/myapp", for: pane)
        store.paneGitSummary[pane] = PaneGitSummary(
            hasRepo: true, branch: "main", ahead: 0, behind: 0, changedCount: 1, modified: 1,
        )
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows[0].subtitle, "main !1", "the visible subtitle is the git line, not the path")
        XCTAssertEqual(rows[0].cwd, "/Users/me/worktrees/feature-x/myapp", "the raw cwd rides as a hidden key")
        // The path segment is searchable even though it is nowhere in the visible chrome.
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "feature-x").map(\.id), [pane])
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "worktrees").map(\.id), [pane])
    }

    /// The filter also matches the foreground process label (part of the hidden search key).
    func testFilterMatchesProcessLabel() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setForegroundProcess("btop", for: pane)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "btop").map(\.id), [pane])
    }

    /// Two panes whose cwd folder name COLLIDES (`…/feature-a/myapp` vs `…/feature-b/myapp`) are disambiguated
    /// by their parent segment, so the sidebar shows `feature-a/myapp` vs `feature-b/myapp` — the C3 BUG A
    /// worktree-distinctiveness fix. Fails on the pre-fix builder (both rows read the bare `myapp`).
    func testCollidingFolderNamesDisambiguatedByParentSegment() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // 2nd tab
        let rows0 = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/work/feature-a/myapp", for: rows0[0].id)
        store.setLastKnownCwd("/work/feature-b/myapp", for: rows0[1].id)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows[0].title, "feature-a/myapp", "the collision is broken by the parent segment")
        XCTAssertEqual(rows[1].title, "feature-b/myapp")
    }

    /// A UNIQUE folder name is left bare — disambiguation only fires on an actual collision.
    func testUniqueFolderNameNotQualified() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let rows0 = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/work/alpha", for: rows0[0].id)
        store.setLastKnownCwd("/work/beta", for: rows0[1].id)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows[0].title, "alpha", "a unique title is not parent-qualified")
        XCTAssertEqual(rows[1].title, "beta")
    }

    /// An EXPLICIT rename that collides with a folder-name title is left verbatim (only folder-derived titles
    /// are qualified) — the rename is the user's chosen label, not a path leaf.
    func testExplicitRenameNotParentQualifiedOnCollision() {
        // Both rows would read "myapp": one via folder name, one via an explicit rename.
        let a = RailRow(
            id: PaneID(), tabID: TabID(), kind: .terminal, title: "myapp", subtitle: nil, status: .none,
            tabNumber: 1, badge: nil, processLabel: nil, readOnly: false, cwd: "/work/x/myapp",
            isEditing: false, isSelected: false,
        )
        let b = RailRow(
            id: PaneID(), tabID: TabID(), kind: .terminal, title: "myapp", subtitle: nil, status: .none,
            tabNumber: 2, badge: nil, processLabel: nil, readOnly: false, cwd: "/work/other/place",
            isEditing: false, isSelected: false,
        )
        let out = RailRowsBuilder.disambiguated([a, b])
        XCTAssertEqual(out[0].title, "x/myapp", "the folder-name row is parent-qualified")
        XCTAssertEqual(out[1].title, "myapp", "the explicit rename (cwd folder ≠ title) is left verbatim")
    }

    /// The pure parent-qualifier helper: qualifies a folder-name title, declines an explicit rename / a
    /// root-level path / a blank cwd.
    func testParentQualifiedTitleHelper() {
        XCTAssertEqual(RailRowsBuilder.parentQualifiedTitle(cwd: "/a/b/repo", title: "repo"), "b/repo")
        XCTAssertNil(RailRowsBuilder.parentQualifiedTitle(cwd: "/a/b/repo", title: "renamed"), "not the folder name")
        XCTAssertNil(RailRowsBuilder.parentQualifiedTitle(cwd: "/repo", title: "repo"), "no parent segment")
        XCTAssertNil(RailRowsBuilder.parentQualifiedTitle(cwd: nil, title: "repo"))
    }

    // MARK: - C3 BUG B: the row exposes inline-rename mode

    /// A pending tab-rename lights the `isEditing` flag on that tab's REPRESENTATIVE (active) pane row only;
    /// clearing the pending state closes it. Fails on the pre-C3 `RailRow` (no `isEditing` field).
    func testPendingTabRenameExposesEditingOnRepresentativeRow() throws {
        let store = makeStore()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let representative = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
        let tab = RailRowsBuilder.rows(for: store)[0].tabID

        XCTAssertFalse(RailRowsBuilder.rows(for: store).contains(where: \.isEditing), "no row edits at rest")
        store.requestRenameTab(tab)
        let editing = RailRowsBuilder.rows(for: store).filter(\.isEditing)
        XCTAssertEqual(editing.count, 1, "exactly one row (the representative pane) opens its rename field")
        XCTAssertEqual(editing.first?.id, representative, "and it is the tab's representative (active) pane row")

        store.clearTabRenameRequest()
        XCTAssertFalse(RailRowsBuilder.rows(for: store).contains(where: \.isEditing), "clearing closes the field")
    }

    /// End-to-end through the store: a rename committed via `renamePane` WINS over the cwd folder-name title in
    /// the rail (`rowTitle` precedence), and clearing the pending state closes the field.
    func testRenameCommitWinsOverFolderNameInRail() throws {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/project-x", for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].title, "project-x", "folder name before rename")
        let tab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        store.requestRenameTab(tab)
        store.renamePane(pane, to: "deploy box")
        store.clearTabRenameRequest()
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertEqual(row.title, "deploy box", "the rename wins over the folder name")
        XCTAssertFalse(row.isEditing, "the field is closed after commit")
    }
}
