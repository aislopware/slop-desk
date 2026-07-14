// RailRowBuilderTests — pins the enrichment of `RailRow`: every rail row carries the 1-based
// tab shortcut number (`#N`), the host-reported foreground-process label, and the single fused status badge
// from the pure `TabBadgeResolver`, in addition to the title/cwd-subtitle the filter narrows on.
//
// Headless: a tree-model `WorkspaceStore` over the tiny `MountTestPaneSession` fake (no socket, no video,
// no Metal/SCStream — per the hang-safety rule). The badge inputs are seeded through the store's PUBLIC
// mutators (`setAgentStatus` / `setCompletionBadge` / `setForegroundProcess`) so the test never touches a
// real `LivePaneSession`. Each assertion fails on a `RailRow` that carries none of these
// fields, so none is tautological.

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

    /// Both panes of a SPLIT tab share the SAME `#N` (it is a tab number, not a pane number).
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

    // MARK: - Manual `tab badge --kind` override on the representative row

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

    // MARK: - The read-only lock flag (sidebar indicator ⟂ pane pill, one source of truth)

    /// A row's `readOnly` mirrors the store's convergent ``WorkspaceStore/paneReadOnly`` set, so the sidebar
    /// lock glyph and the pane's `🔒 READ ONLY ×` pill read ONE truth. Locking the pane lights the flag;
    /// unlocking clears it. Fails on a `RailRow` with no `readOnly` field (⇒ won't compile) and on a
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

    // MARK: - Blocked rows show the question, kept OUT of `subtitle`

    /// While a pane is blocked (`.needsPermission`) AND the store carries a host label for it, `chrome.question`
    /// resolves to that label — but `chrome.subtitle` (the plain git/cwd line) is UNTOUCHED, proving the
    /// question travels as a separate field rather than overwriting the memoized search corpus. Fails on a
    /// builder that has no `question` field or that folds the label into `subtitle`.
    func testChromeQuestionResolvesWhileBlockedWithoutTouchingSubtitle() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/project-alpha", for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        store.setAgentLabel("Allow Bash(npm install)?", for: pane)

        let row = RailRowsBuilder.rows(for: store)[0]
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        XCTAssertEqual(chrome.question, "Allow Bash(npm install)?", "the blocking prompt surfaces as the question")
        XCTAssertEqual(
            chrome.subtitle, "/Users/me/project-alpha",
            "subtitle keeps resolving the plain cwd line — the question never overwrites it",
        )
        XCTAssertEqual(
            row.subtitle, "/Users/me/project-alpha",
            "the memoized structural RailRow.subtitle never carries the question either",
        )
    }

    /// Not blocked (idle/none/working/done) never surfaces a question even with a stale label on record.
    func testChromeQuestionNilWhenNotBlocked() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setAgentLabel("Allow Bash(npm install)?", for: pane)
        // No `.needsPermission` was ever set — status stays `.none`.
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertNil(RailRowsBuilder.liveChrome(for: row, store: store).question)

        store.setAgentStatus(.working, for: pane)
        XCTAssertNil(RailRowsBuilder.liveChrome(for: row, store: store).question, "working is not blocked")

        store.setAgentStatus(.done, for: pane)
        XCTAssertNil(RailRowsBuilder.liveChrome(for: row, store: store).question, "done is not blocked")
    }

    /// The label-race window: status flips to `.needsPermission` before the host label lands. `question` stays
    /// `nil` (the row keeps its plain subtitle) until the label actually arrives, then resolves — the swap
    /// predicate for the caller's truncation mode must key on THIS, not on `status == .needsPermission` alone.
    func testChromeQuestionNilDuringLabelRaceThenResolvesOnArrival() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/srv/app", for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertNil(
            RailRowsBuilder.liveChrome(for: row, store: store).question,
            "blocked with no label yet — the race window keeps the row on its plain subtitle",
        )

        store.setAgentLabel("Allow Write(/srv/app/config.yml)?", for: pane)
        XCTAssertEqual(
            RailRowsBuilder.liveChrome(for: row, store: store).question, "Allow Write(/srv/app/config.yml)?",
            "the label landing resolves the question",
        )
    }

    /// Unblocking reverts `question` to `nil` on the very next chrome read — hard cut, same slot — while
    /// `subtitle` is unaffected across the whole cycle.
    func testChromeQuestionRevertsOnUnblock() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/srv/app", for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        store.setAgentLabel("Allow Bash(rm -rf build)?", for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertNotNil(RailRowsBuilder.liveChrome(for: row, store: store).question, "blocked with a label")

        store.setAgentStatus(.idle, for: pane)
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        XCTAssertNil(chrome.question, "unblocking reverts the question")
        XCTAssertEqual(chrome.subtitle, "/srv/app", "subtitle was never touched by the block/unblock cycle")
    }

    /// The question is kept OUT of the memoized, structural ``RailRow`` entirely (it lives only on the
    /// volatile ``RailRowsBuilder/RailRowChrome``), so ``RailRowsBuilder/filtered(_:query:)`` — which narrows
    /// over the structural rows — can never match a blocked row by its question text, only by its ordinary
    /// title/subtitle/cwd/processLabel. Widening the search key would require putting agent status/label into
    /// the memo's structural fingerprint, reintroducing the O(panes) rebuild-per-status-tick the memo exists
    /// to prevent — deliberately not done.
    func testBlockedRowNotSearchableByQuestionText() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/srv/app", for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        store.setAgentLabel("Allow Bash(npm install)?", for: pane)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertTrue(
            RailRowsBuilder.filtered(rows, query: "npm install").isEmpty,
            "the question text is not part of the structural row's search key",
        )
        XCTAssertEqual(
            RailRowsBuilder.filtered(rows, query: "app").map(\.id), [pane],
            "the ordinary cwd/title search key still matches",
        )
    }

    /// The title precedence for a terminal row: an EXPLICIT rename beats the folder name, the folder
    /// name beats the shell-title chain, and a cwd-less pane keeps the old fallback ("Terminal").
    func testRowTitlePrecedence() {
        // A rename rides the explicit `userRenamed` flag (set by `renamePane`), not a title-vs-cwd
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

        // Non-terminal kinds keep the title-fallback chain untouched.
        let video = PaneSpec(kind: .remoteGUI, title: "Docs", lastKnownTitle: "Docs — Safari")
        XCTAssertEqual(RailRowsBuilder.rowTitle(kind: .remoteGUI, spec: video), "Docs — Safari")
    }

    /// Regression: a `title != lastKnownTitle` heuristic MISFIRES once a shell emits a SECOND
    /// OSC title — `title` stays the load-time-promoted first title while `lastKnownTitle` advances, so the
    /// stale promoted title would latch as a phantom "rename". With the explicit `userRenamed` flag (false here),
    /// the FOLDER NAME wins. Revert-to-confirm-fail: that heuristic returns "zsh — proj-v1" for this spec.
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

    /// A cwd-less pane running a real foreground program titles itself by that program (host wire type
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

    // MARK: - `.remoteGUI` panes are the RIGHT rail's rows, never the left rail's

    /// The left rail tracks TERMINAL panes only: an open remote window's one home is the right rail
    /// (`HostWindowsColumn` — streamed marker / focus state / drag-to-move), so the builder must skip
    /// `.remoteGUI` panes entirely — a whole-tab window AND one split beside a terminal sibling. The
    /// terminal rows around it are untouched. Fails on the old builder, which listed the same pane in
    /// two sidebars.
    func testRemoteWindowPanesAreNotRailRows() throws {
        let store = makeStore()
        let remote = try XCTUnwrap(store.openWindowInStage(windowID: 4242, title: "Docs", appName: "Safari"))

        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertNil(
            rows.first { $0.id == remote },
            "a staged remote window has no left-rail row (its one home is the right rail / Stage strip)",
        )
        XCTAssertTrue(rows.allSatisfy { $0.kind != .remoteGUI }, "no `.remoteGUI` row survives the builder")
    }

    /// Skipping window panes in the RAIL must not touch the ⌘K jump-to-pane palette, which enumerates
    /// panes itself — a remote window stays jumpable even though it is no longer listed on the left.
    func testRemoteWindowPanesStayInTheJumpPalette() throws {
        let store = makeStore()
        let remote = try XCTUnwrap(store.openWindowInStage(windowID: 7777, title: "Docs", appName: "Safari"))
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)

        let paletteIDs = TabsPaletteSource.snapshot(store)
            .candidates(query: "")
            .map(\.id)
        XCTAssertTrue(
            paletteIDs.contains("tab.\(remote.raw.uuidString)"),
            "a remote window must stay in the ⌘K jump-to-pane palette",
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

    // MARK: - Path-searchable row + collision disambiguation

    /// A git-repo row's VISIBLE subtitle is the git line (not the path), yet the row stays searchable BY PATH
    /// via the hidden `cwd` key. Fails on a builder whose filter only matches title + subtitle, so a path
    /// query against a git row returns nothing.
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
    /// by their parent segment, so the sidebar shows `feature-a/myapp` vs `feature-b/myapp` — a
    /// worktree-distinctiveness fix. Fails on a builder that leaves both rows reading the bare `myapp`.
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

    // MARK: - The row exposes inline-rename mode

    /// A pending tab-rename lights the `isEditing` flag on that tab's REPRESENTATIVE (active) pane row only;
    /// clearing the pending state closes it. Fails on a `RailRow` with no `isEditing` field.
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
