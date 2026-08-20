// RailRowBuilderTests — pins the enrichment of `RailRow`: every rail row carries the 1-based
// tab shortcut number (`#N`), the host-reported foreground-process label, and the single fused status badge
// from the pure `TabBadgeResolver`, in addition to the title/cwd-subtitle the filter narrows on.
//
// Headless: a tree-model `WorkspaceStore` over the tiny `RecordingPaneSession` fake (no socket, no video,
// no Metal/SCStream — per the hang-safety rule). The badge inputs are seeded through the store's PUBLIC
// mutators (`setAgentStatus` / `setCompletionBadge` / `setForegroundProcess`) so the test never touches a
// real `LivePaneSession`. Each assertion fails on a `RailRow` that carries none of these
// fields, so none is tautological.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

@MainActor
final class RailRowBuilderTests: XCTestCase {
    /// A headless tree-model store over the fake session (mirrors `OverlayCoordinatorMountTests`).
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
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

    // MARK: - cwd folder-name title + relative-cwd subtitle + the reused title+subtitle filter

    /// A pane sitting AT its section key (here the cwd fallback — key == cwd) carries NEITHER the
    /// folder-name title (it would restate the section header; line 1 stays empty ⇒ the view's
    /// generic) NOR a subtitle. `filtered` still narrows by the hidden cwd key, so the row stays
    /// searchable by path even with no visible chrome naming it.
    func testSubtitleCwdAndFilter() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/project-alpha", for: pane)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertEqual(rows[0].title, "", "at its own root the folder name is the SECTION's — line 1 stays empty")
        XCTAssertNil(rows[0].subtitle, "at the section key (key == cwd) line 2 is absent")
        XCTAssertTrue(RailRowsBuilder.filtered(rows, query: "term").isEmpty)
        // Hidden-cwd match — the path still finds the row though nothing visible carries it.
        XCTAssertEqual(RailRowsBuilder.filtered(rows, query: "project-alpha").map(\.id), [pane])
        // No match anywhere.
        XCTAssertTrue(RailRowsBuilder.filtered(rows, query: "zzz-nope").isEmpty)
    }

    /// The relative-cwd subtitle rule (``PaneSpec/railSubtitle(cwd:liveTitle:projectKey:)``): a
    /// pane INSIDE its project's subtree shows the path RELATIVE to the key, a pane AT the key shows
    /// nothing, and a pane whose cwd fell OUTSIDE the key's subtree (stale key across an
    /// un-re-pushed `cd`) falls back to the full cwd — hiding the location would lie. Fails on the
    /// pre-fix builder (subtitle was the git line / unconditional `railSubtitle`).
    func testSubtitleIsCwdRelativeToProjectKey() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setProjectKey("/repo/root", for: pane)

        store.setLastKnownCwd("/repo/root", for: pane)
        XCTAssertNil(RailRowsBuilder.rows(for: store)[0].subtitle, "at the project root → no line 2")

        store.setLastKnownCwd("/repo/root/packages/api", for: pane)
        XCTAssertEqual(
            RailRowsBuilder.rows(for: store)[0].subtitle, "packages/api",
            "inside the subtree → the path relative to the project root",
        )

        store.setLastKnownCwd("/elsewhere/scratch", for: pane)
        XCTAssertEqual(
            RailRowsBuilder.rows(for: store)[0].subtitle, "/elsewhere/scratch",
            "outside the key's subtree → the full cwd (never hide a location the header doesn't cover)",
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
        store.setProjectKey("/Users/me/project-alpha", for: pane)
        store.setLastKnownCwd("/Users/me/project-alpha/sub", for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        store.setAgentLabel("Allow Bash(npm install)?", for: pane)

        let row = RailRowsBuilder.rows(for: store)[0]
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        XCTAssertEqual(chrome.question, "Allow Bash(npm install)?", "the blocking prompt surfaces as the question")
        XCTAssertEqual(
            chrome.subtitle, "sub",
            "subtitle keeps resolving the relative-cwd line — the question never overwrites it",
        )
        XCTAssertEqual(
            row.subtitle, "sub",
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
        store.setProjectKey("/srv/app", for: pane)
        store.setLastKnownCwd("/srv/app/web", for: pane)
        store.setAgentStatus(.needsPermission, for: pane)
        store.setAgentLabel("Allow Bash(rm -rf build)?", for: pane)
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertNotNil(RailRowsBuilder.liveChrome(for: row, store: store).question, "blocked with a label")

        store.setAgentStatus(.idle, for: pane)
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        XCTAssertNil(chrome.question, "unblocking reverts the question")
        XCTAssertEqual(chrome.subtitle, "web", "subtitle was never touched by the block/unblock cycle")
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
        let renamed = PaneSpec(kind: .terminal, title: "build box", userRenamed: true)
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(kind: .terminal, spec: renamed, cwd: "/srv/app"), "build box",
        )

        let unnamed = PaneSpec(kind: .terminal, title: "Terminal")
        XCTAssertEqual(RailRowsBuilder.rowTitle(kind: .terminal, spec: unnamed, cwd: "/srv/app"), "app")

        // A spec title that happens to equal the shell's live title is NOT a rename — folder name wins.
        let promoted = PaneSpec(kind: .terminal, title: "zsh — slopdesk")
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(
                kind: .terminal, spec: promoted, cwd: "/srv/app", liveTitle: "zsh — slopdesk",
            ),
            "app",
        )

        let noCwd = PaneSpec(kind: .terminal, title: "Terminal")
        XCTAssertEqual(RailRowsBuilder.rowTitle(kind: .terminal, spec: noCwd), "Terminal")

        // Non-terminal kinds keep the title-fallback chain untouched.
        let video = PaneSpec(kind: .desktop, title: "Docs")
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(kind: .desktop, spec: video, liveTitle: "Docs — Safari"),
            "Docs — Safari",
        )
    }

    /// Regression: a `title != liveTitle` heuristic MISFIRES once a shell emits a SECOND
    /// OSC title — `title` stays the first title while the live one advances, so the
    /// stale promoted title would latch as a phantom "rename". With the explicit `userRenamed` flag (false here),
    /// the FOLDER NAME wins. Revert-to-confirm-fail: that heuristic returns "zsh — proj-v1" for this spec.
    func testRowTitleDoesNotMisfireAsRenameWhenShellEmitsSecondOSCTitle() {
        let secondTitle = PaneSpec(kind: .terminal, title: "zsh — proj-v1", userRenamed: false)
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(
                kind: .terminal, spec: secondTitle, cwd: "/srv/app", liveTitle: "zsh — proj-v2",
            ),
            "app",
            "a shell's changing OSC title is NOT a user rename — the folder name still titles the pane",
        )
    }

    /// The trailing-SLOT label keeps a bare shell's name — the slot answers "what is this pane
    /// running", so an idle `zsh` row reads "zsh" there — while sharing the basename/argv0 cleanup
    /// with the TITLE resolver (which still suppresses shells).
    func testSlotProcessNameKeepsBareShells() {
        XCTAssertEqual(RailRowsBuilder.slotProcessName("zsh"), "zsh")
        XCTAssertEqual(RailRowsBuilder.slotProcessName("-zsh"), "zsh", "login-shell argv0 dash dropped")
        XCTAssertEqual(RailRowsBuilder.slotProcessName("/bin/bash"), "bash", "basenamed")
        XCTAssertEqual(RailRowsBuilder.slotProcessName("/usr/local/bin/npm"), "npm")
        XCTAssertNil(RailRowsBuilder.slotProcessName(nil))
        XCTAssertNil(RailRowsBuilder.slotProcessName("  "))
        // The TITLE resolver keeps its suppression — the split is deliberate.
        XCTAssertNil(RailRowsBuilder.processDisplayName("zsh"))
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
        let withCwd = PaneSpec(kind: .terminal, title: "Terminal")
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(kind: .terminal, spec: withCwd, cwd: "/srv/app", processLabel: "vim"),
            "app",
            "the cwd folder name is the primary identity; the process fallback is only for a cwd-less pane",
        )
    }

    /// A pane sitting AT its project root titles by its foreground PROGRAM, never by the folder name
    /// the section header already carries; an idle shell yields "" (the view's kind-generic reads).
    func testRowTitleAtProjectRootIsTheProgramNotTheFolder() {
        let atRoot = PaneSpec(kind: .terminal, title: "zsh — app")

        XCTAssertEqual(
            RailRowsBuilder.rowTitle(
                kind: .terminal, spec: atRoot, cwd: "/srv/app",
                processLabel: "claude", projectKey: "/srv/app",
            ),
            "claude",
            "at the project root the folder name would restate the section header — the program titles the row",
        )
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(
                kind: .terminal, spec: atRoot, cwd: "/srv/app",
                processLabel: "-zsh", projectKey: "/srv/app",
            ),
            "",
            "an idle shell at root yields empty (⇒ the view's generic), NOT the OSC shell title restating the place",
        )
        // Trailing-slash / whitespace forms of the same root still count as AT root.
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(
                kind: .terminal, spec: atRoot, cwd: "/srv/app",
                processLabel: "vim", projectKey: "/srv/app/",
            ),
            "vim",
        )
        // A STRAYED pane (cwd inside the project subtree) keeps the folder-name identity.
        let strayed = PaneSpec(kind: .terminal, title: "Terminal")
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(
                kind: .terminal, spec: strayed, cwd: "/srv/app/packages/api",
                processLabel: "claude", projectKey: "/srv/app",
            ),
            "api",
        )
        // An explicit rename still beats the at-root rung.
        let renamed = PaneSpec(kind: .terminal, title: "build box", userRenamed: true)
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(
                kind: .terminal, spec: renamed, cwd: "/srv/app",
                processLabel: "claude", projectKey: "/srv/app",
            ),
            "build box",
        )
        // The titlebar call sites omit the key — the folder name stays the window-title identity.
        XCTAssertEqual(
            RailRowsBuilder.rowTitle(
                kind: .terminal, spec: atRoot, cwd: "/srv/app", processLabel: "claude",
            ),
            "app",
        )
    }

    /// The empty-title view fallback: the pane's most recent command that ran ≥ 1 s
    /// (``RailRowsBuilder/commandTitleMinDurationMS``) titles the idle row — REGARDLESS of exit
    /// (the history identity, not an alarm; exit status stays the badge's + tooltip's story).
    /// Sub-threshold blocks are SKIPPED, not title-clearing — a quick `ls` after a long build
    /// leaves the build's title standing — and a still-running block (no duration yet) never
    /// titles HERE (the live RUNNING rung of ``liveRowTitle`` covers it from the open block).
    func testLastCommandTitlePicksLastLongRunningCommand() {
        let build = CommandBlock(
            index: 0, commandText: "make check", exitCode: 0, durationMS: 94000, complete: true,
        )
        let quickLs = CommandBlock(index: 1, commandText: "ls", exitCode: 0, durationMS: 40, complete: true)
        XCTAssertEqual(RailRowsBuilder.lastCommandTitle(blocks: [build, quickLs]), "make check")

        let failed = CommandBlock(
            index: 2, commandText: "npm test", exitCode: 1, durationMS: 1000, complete: true,
        )
        XCTAssertEqual(
            RailRowsBuilder.lastCommandTitle(blocks: [build, quickLs, failed]), "npm test",
            "exit status is irrelevant to the title, and exactly the 1 s threshold qualifies",
        )

        let running = CommandBlock(index: 3, commandText: "sleep 99", complete: false)
        XCTAssertEqual(
            RailRowsBuilder.lastCommandTitle(blocks: [build, running]), "make check",
            "a still-running block has no duration — the RUNNING rung titles it, not this scan",
        )

        // A block INTERRUPTED by a nested prompt (complete == false, duration stamped) is finished.
        let interrupted = CommandBlock(index: 4, commandText: "ssh box", durationMS: 8000, complete: false)
        XCTAssertEqual(RailRowsBuilder.lastCommandTitle(blocks: [interrupted]), "ssh box")

        let blank = CommandBlock(index: 5, commandText: "   ", exitCode: 0, durationMS: 9000, complete: true)
        XCTAssertEqual(
            RailRowsBuilder.lastCommandTitle(blocks: [build, blank]), "make check",
            "a blank command line is skipped, not title-clearing",
        )

        XCTAssertNil(RailRowsBuilder.lastCommandTitle(blocks: [quickLs]))
        XCTAssertNil(RailRowsBuilder.lastCommandTitle(blocks: []))
    }

    /// The live leaf's ONE title chain (shared by the macOS + iOS rows): rename → agent-session
    /// INTENT (wire 36) → structural title → RUNNING command → last executed command →
    /// cwd folder name → kind-generic fallback.
    func testLiveRowTitlePrecedence() {
        let lint = CommandBlock(
            index: 0, commandText: "make lint", exitCode: 0, durationMS: 94000, complete: true,
        )

        // An agent row titles by its session intent over the shared process name.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "claude", userRenamed: false, isAgent: true,
                intent: "fix the flaky CI test", runningCommand: nil, processTitle: nil, blocks: [],
                kind: .terminal, fallback: "Terminal",
            ),
            "fix the flaky CI test",
        )
        // An explicit rename still beats the intent.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "release box", userRenamed: true, isAgent: true,
                intent: "fix the flaky CI test", runningCommand: nil, processTitle: nil, blocks: [],
                kind: .terminal, fallback: "Terminal",
            ),
            "release box",
        )
        // A NON-agent row never reads an intent (a stale mirror can't title a plain shell).
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "", userRenamed: false, isAgent: false,
                intent: "fix the flaky CI test", runningCommand: nil, processTitle: nil, blocks: [],
                kind: .terminal, fallback: "Terminal",
            ),
            "Terminal",
        )
        // A "rename" equal to the kind-generic fallback carries no identity and NEVER wins — it is
        // the accidentally committed seed of the pre-guard inline-rename field (blur froze the
        // resting "Terminal" as a sticky rename in persisted specs); the live chain stays in charge
        // so the agent intent can title the row again.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "Terminal", userRenamed: true, isAgent: true,
                intent: "fix the flaky CI test", runningCommand: nil, processTitle: nil, blocks: [],
                kind: .terminal, fallback: "Terminal",
            ),
            "fix the flaky CI test",
        )
        // A blank/whitespace intent falls through to the structural title.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "claude", userRenamed: false, isAgent: true,
                intent: "   ", runningCommand: nil, processTitle: nil, blocks: [], kind: .terminal,
                fallback: "Terminal",
            ),
            "claude",
        )
        // The RUNNING command beats the finished history — "what is this pane doing RIGHT NOW".
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: "make check", processTitle: nil, blocks: [lint],
                kind: .terminal, fallback: "Terminal",
            ),
            "make check",
        )
        // A bare foreground-PROGRAM structural title (the at-root running pane) upgrades in place
        // to the full running command line — the same fact with its arguments back.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "sleep", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: "sleep 30 && make", processTitle: "sleep",
                blocks: [], kind: .terminal, fallback: "Terminal",
            ),
            "sleep 30 && make",
        )
        // A FOLDER structural title is an identity, not a program echo — it never yields to the
        // running command (the subtitle carries the location; the running line rides the tooltip).
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "api", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: "make check", processTitle: "make",
                blocks: [], kind: .terminal, fallback: "Terminal",
            ),
            "api",
        )
        // Idle: the last executed command titles the row, regardless of its exit.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: nil, processTitle: nil, blocks: [lint], kind: .terminal,
                fallback: "Terminal",
            ),
            "make lint",
        )
        // A blank history reads the cwd FOLDER NAME before the kind-generic fallback — the at-root
        // idle shell titles by its basepath (an identity, even when it restates the section header)
        // rather than the meaningless "Terminal".
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: nil, processTitle: nil, blocks: [], kind: .terminal,
                cwdTitle: "slop-desk", fallback: "Terminal",
            ),
            "slop-desk",
        )
        // The last executed command still beats the basepath — history says more than place.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: nil, processTitle: nil, blocks: [lint], kind: .terminal,
                cwdTitle: "slop-desk", fallback: "Terminal",
            ),
            "make lint",
        )
        // Only a pane with NO cwd yet keeps the kind-generic fallback.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: nil, processTitle: nil, blocks: [], kind: .terminal,
                cwdTitle: nil, fallback: "Terminal",
            ),
            "Terminal",
        )
    }

    /// A FRESH program-set OSC title out-ranks the raw command line wherever the RUNNING rung would
    /// title the row — nvim's "main.swift - NVIM" says more than `vi .` — while a program that sets
    /// no title keeps the command line, and a FOLDER structural title still never yields.
    func testLiveRowTitleProgramTitleBeatsRunningCommand() {
        // Bare-running rung (empty structural title): the program's title wins.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: "vi .", programTitle: "main.swift - NVIM",
                processTitle: nil, blocks: [], kind: .terminal, fallback: "Terminal",
            ),
            "main.swift - NVIM",
        )
        // The at-root upgrade branch (structural == program name): same precedence.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "nvim", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: "vi .", programTitle: "main.swift - NVIM",
                processTitle: "nvim", blocks: [], kind: .terminal, fallback: "Terminal",
            ),
            "main.swift - NVIM",
        )
        // No program title → the running command line titles as before.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: "vi .", programTitle: nil,
                processTitle: nil, blocks: [], kind: .terminal, fallback: "Terminal",
            ),
            "vi .",
        )
        // A FOLDER structural title is an identity — it yields to neither the running command nor
        // the program's title.
        XCTAssertEqual(
            RailRowsBuilder.liveRowTitle(
                structuralTitle: "api", userRenamed: false, isAgent: false,
                intent: nil, runningCommand: "vi .", programTitle: "main.swift - NVIM",
                processTitle: "nvim", blocks: [], kind: .terminal, fallback: "Terminal",
            ),
            "api",
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

    // MARK: - The desktop lives in its OWN window (docs/DECISIONS.md 2026-07-22) — not in the rail

    /// A `.desktop` pane is born detached (its dedicated window) — the rail lists TABS, so the
    /// desktop never gets a row. ⌥⌘N / the palette "Remote Desktop" verb is its reveal path.
    func testDesktopPanesAreNotRailRows() {
        let store = makeStore()
        let desktop = store.openDesktopWindow()

        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertNil(rows.first { $0.id == desktop }, "the desktop window is not a rail row")
        XCTAssertNotNil(store.handle(for: desktop), "yet its stream session is live (detached)")
    }

    /// The ⌘K jump-to-pane palette enumerates TAB panes — the desktop (its own window) is not among
    /// them; a tree terminal pane still is.
    func testJumpPaletteListsTreePanesButNotTheDesktopWindow() throws {
        let store = makeStore()
        let desktop = store.openDesktopWindow()
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let terminal = try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)

        let paletteIDs = TabsPaletteSource.snapshot(store)
            .candidates(query: "")
            .map(\.id)
        XCTAssertTrue(
            paletteIDs.contains("tab.\(terminal.raw.uuidString)"),
            "a tree pane stays in the ⌘K jump-to-pane palette",
        )
        XCTAssertFalse(
            paletteIDs.contains("tab.\(desktop.raw.uuidString)"),
            "the desktop window is revealed by ⌥⌘N, not the tab jumper",
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
    /// in section 1, the lone `…/beta` tab in section 2 — sections A→Z, rows inside one in creation order.
    func testSectionedByProjectBucketsRowsIntoAlphabeticalSections() {
        let store = makeThreeProjectStore()
        let sections = RailRowsBuilder.sectionedByProject(
            RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        XCTAssertEqual(sections.map(\.header), ["alpha", "beta"], "section headers are the cwd basenames")
        XCTAssertEqual(sections[0].rows.map(\.tabNumber), [1, 2], "both alpha tabs share section 1")
        XCTAssertEqual(sections[1].rows.map(\.tabNumber), [3], "the lone beta tab is section 2")
    }

    /// THE ALPHABETICAL SECTION ORDER (user-directed 2026-08-10). A project's slot is a fact about its
    /// NAME, not about when you happened to open it: three tabs created zulu → alpha → mid draw as
    /// alpha, mid, zulu. Rows keep creation order INSIDE a section — only the sections move. FAILS on
    /// the old first-appearance bucketing (which draws zulu first because it was opened first).
    func testSectionedByProjectOrdersSectionsAlphabeticallyNotByCreation() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.newTab(kind: .terminal, launchGrace: .zero)
        let seeded = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/Users/me/zulu", for: seeded[0].id)
        store.setLastKnownCwd("/Users/me/alpha", for: seeded[1].id)
        store.setLastKnownCwd("/Users/me/mid", for: seeded[2].id)

        let sections = RailRowsBuilder.sectionedByProject(
            RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        XCTAssertEqual(sections.map(\.header), ["alpha", "mid", "zulu"], "sections sort A→Z")
        XCTAssertEqual(
            sections.map { $0.rows.map(\.tabNumber) }, [[2], [3], [1]],
            "the tab numbers are still creation-order — it is the SECTIONS that moved, not the rows",
        )
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

    /// THE CROSS-LAYER INVARIANT. The sidebar sections pane ROWS here in ClientUI; the tab-close rule
    /// sections TABs in the applier (`successorAfterClosing` → `projectGroupedTabOrder`). Both now run
    /// `TabOrderingEngine.bucketedByProject`, and the reason that matters is this: the order tabs first
    /// APPEAR in the rendered rail must equal the order the close rule walks — otherwise "focus the
    /// neighbouring tab" names a tab that is nowhere near the closed one on screen, which is exactly the
    /// bug this pins against.
    ///
    /// Shaped like the report: a tab in alpha, a tab in beta, then ⌘T back in alpha — which APPENDS past
    /// beta in `session.tabs` but DRAWS in alpha's section. A creation-order reading gives
    /// `[alpha1, beta, alpha2]`; the rail draws `[alpha1, alpha2, beta]`.
    func testTabDisplayOrderMatchesTheOrderTabsAppearInTheRail() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.newTab(kind: .terminal, launchGrace: .zero)
        let seeded = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/Users/me/alpha", for: seeded[0].id)
        store.setLastKnownCwd("/Users/me/beta", for: seeded[1].id)
        store.setLastKnownCwd("/Users/me/alpha", for: seeded[2].id)

        let rows = RailRowsBuilder.rows(for: store)
        let drawn = RailRowsBuilder
            .sectionedByProject(rows, tabOrder: store.flatOrderedTabIDs(), query: "")
            .flatMap { $0.rows.map(\.tabID) }
            .reduce(into: [TabID]()) { order, tab in if !order.contains(tab) { order.append(tab) } }

        // The close rule's reading, built from the store's own per-pane key lookup rather than the rows.
        var representative: [TabID: PaneID] = [:]
        for row in rows where representative[row.tabID] == nil { representative[row.tabID] = row.id }
        let walked = TabOrderingEngine.projectGroupedTabOrder(store.flatOrderedTabIDs()) { tab in
            representative[tab].flatMap { store.paneProjectKey($0) }
        }

        XCTAssertEqual(walked, drawn, "the close rule must walk the order the sidebar actually drew")
        XCTAssertNotEqual(
            walked, store.flatOrderedTabIDs(),
            "and that order is NOT creation order here — otherwise this fixture proves nothing",
        )
        var number: [TabID: Int] = [:]
        for row in rows where number[row.tabID] == nil { number[row.tabID] = row.tabNumber }
        XCTAssertEqual(
            drawn.map { number[$0] }, [1, 3, 2],
            "the ⌘T tab (#3) draws beside its own project's tab #1, ahead of beta's tab #2",
        )
    }

    /// THE ⌘-DIGIT TWIN of the invariant above: `WorkspaceStore.displayOrderedPaneIDs()` — the order
    /// ⌘1…⌘9 counts and the ⌘-held number hints display — must equal the pane order the rendered rail
    /// actually draws (its sections flattened). Two hand-rolled readings of "the drawn order" would be
    /// free to drift, and the drift would show up as a hint digit that focuses a different row than the
    /// one it was printed on. Built on the same ⌘T-back-into-alpha shape whose drawn order ≠ creation
    /// order, so a creation-order `displayOrderedPaneIDs` fails loudly.
    func testDisplayOrderedPaneIDsMatchesTheRenderedRailOrder() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        store.newTab(kind: .terminal, launchGrace: .zero)
        let seeded = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/Users/me/alpha", for: seeded[0].id)
        store.setLastKnownCwd("/Users/me/beta", for: seeded[1].id)
        store.setLastKnownCwd("/Users/me/alpha", for: seeded[2].id)

        let drawn = RailRowsBuilder
            .sectionedByProject(
                RailRowsBuilder.rows(for: store), tabOrder: store.flatOrderedTabIDs(), query: "",
            )
            .flatMap { $0.rows.map(\.id) }

        XCTAssertEqual(store.displayOrderedPaneIDs(), drawn, "⌘-digits count the drawn rail order")
        XCTAssertNotEqual(
            drawn, store.flatOrderedPaneIDs(),
            "and that order is NOT creation order here — otherwise this fixture proves nothing",
        )
        XCTAssertEqual(
            drawn.map { store.shortcutNumber(for: $0) }, [1, 2, 3],
            "each drawn row's hint digit is its 1-based drawn position",
        )
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
    /// bucket, which sorts LAST behind every named project; the query filter still composes and drops an
    /// all-filtered section.
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
    /// sections (they sort on their header — never focus/recency). Two single-pane tabs in different
    /// projects keep their A→Z layout regardless of which is focused.
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
        XCTAssertEqual(headers(), ["alpha", "beta"], "A→Z section layout")
        store.selectTab(1)
        XCTAssertEqual(
            headers(), ["alpha", "beta"],
            "section order stays put across a tab switch — alphabetical, never focus-derived",
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

    /// An at-root row's VISIBLE subtitle is ABSENT (the section header names the place), yet the row
    /// stays searchable BY PATH via the hidden `cwd` key. Fails on a builder whose filter only matches
    /// title + subtitle, so a path query against an at-root row returns nothing.
    func testFilterMatchesCwdEvenWhenSubtitleIsAbsent() {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/worktrees/feature-x/myapp", for: pane)
        let rows = RailRowsBuilder.rows(for: store)
        XCTAssertNil(rows[0].subtitle, "at the section key (cwd fallback) the visible subtitle is absent")
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

    /// Two same-named worktrees (`…/feature-a/myapp` vs `…/feature-b/myapp`) are two distinct project
    /// keys ⇒ two SECTIONS sharing one basename — the collision is broken on the section HEADER
    /// (`feature-a/myapp` vs `feature-b/myapp`), since the header is the place identity now (the
    /// at-root rows themselves stay program-titled). Fails on a sectioner that leaves both headers
    /// reading the bare `myapp`.
    func testCollidingWorktreeHeadersDisambiguatedByParentSegment() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero) // 2nd tab
        let rows0 = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/work/feature-a/myapp", for: rows0[0].id)
        store.setLastKnownCwd("/work/feature-b/myapp", for: rows0[1].id)
        let rows = RailRowsBuilder.rows(for: store)
        let sections = RailRowsBuilder.sectionedByProject(rows, tabOrder: rows.map(\.tabID), query: "")
        XCTAssertEqual(
            sections.map(\.header), ["feature-a/myapp", "feature-b/myapp"],
            "the header collision is broken by each key's parent segment",
        )
        XCTAssertEqual(rows.map(\.title), ["", ""], "the at-root rows never repeat the folder name")
    }

    /// A UNIQUE section basename is left bare — header disambiguation only fires on an actual collision.
    func testUniqueSectionHeaderNotQualified() {
        let store = makeStore()
        store.newTab(kind: .terminal, launchGrace: .zero)
        let rows0 = RailRowsBuilder.rows(for: store)
        store.setLastKnownCwd("/work/alpha", for: rows0[0].id)
        store.setLastKnownCwd("/work/beta", for: rows0[1].id)
        let rows = RailRowsBuilder.rows(for: store)
        let sections = RailRowsBuilder.sectionedByProject(rows, tabOrder: rows.map(\.tabID), query: "")
        XCTAssertEqual(sections.map(\.header), ["alpha", "beta"], "unique headers are not parent-qualified")
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

    /// A row with no parent to name keeps its colliding title: two identical rows are a smaller
    /// problem than one row wearing a label that means nothing.
    func testRootLevelCollisionIsLeftVerbatim() {
        let row = { (cwd: String) in
            RailRow(
                id: PaneID(), tabID: TabID(), kind: .terminal, title: "repo", subtitle: nil, status: .none,
                tabNumber: 1, badge: nil, processLabel: nil, readOnly: false, cwd: cwd,
                isEditing: false, isSelected: false,
            )
        }
        let out = RailRowsBuilder.disambiguated([row("/repo"), row("/a/b/repo")])
        XCTAssertEqual(out[0].title, "repo", "no parent segment to qualify with")
        XCTAssertEqual(out[1].title, "b/repo")
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

    /// End-to-end through the store: a rename committed via `renamePane` WINS over the derived title in
    /// the rail (`rowTitle` precedence), and clearing the pending state closes the field.
    func testRenameCommitWinsOverFolderNameInRail() throws {
        let store = makeStore()
        let pane = paneID(store, row: 0)
        store.setLastKnownCwd("/Users/me/project-x", for: pane)
        XCTAssertEqual(RailRowsBuilder.rows(for: store)[0].title, "", "at-root ⇒ empty (generic) before rename")
        let tab = try XCTUnwrap(store.tree.activeSession?.activeTab?.id)
        store.requestRenameTab(tab)
        store.renamePane(pane, to: "deploy box")
        store.clearTabRenameRequest()
        let row = RailRowsBuilder.rows(for: store)[0]
        XCTAssertEqual(row.title, "deploy box", "the rename wins over the folder name")
        XCTAssertFalse(row.isEditing, "the field is closed after commit")
    }
}
