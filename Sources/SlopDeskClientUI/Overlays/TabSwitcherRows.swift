// TabSwitcherRows — what one ⌃⇥ switcher row SAYS, resolved off the live store.
//
// The switcher used to print `RailRowsBuilder.rowTitle` with no project key, which for a coding
// workspace resolves to the cwd's FOLDER NAME on nearly every row. Three panes opened in one repo then
// read `slopdesk` / `slopdesk` / `slopdesk`: the ring was ordered by recency but named by place, so the
// one thing the surface exists to answer — WHICH of these am I flipping to — was the one thing it did
// not say.
//
// So a row now speaks in two registers, the sidebar's split: line 1 is the pane's IDENTITY (the agent's
// task intent, the running command, the program), line 2 is its PLACE (project, plus the sub-path when
// the pane strayed from the root, plus the pane count when the tab is split). Identity comes from
// ``RailRowsBuilder/liveRowTitle(...)`` — the SAME chain the sidebar row and the window title read, so a
// pane is named identically wherever it is named, and a fix to the chain reaches all three.
//
// Pure `place` / `detail` / `slot` composers so the wording is unit-pinned without a view; the one
// `@MainActor` entry is the store read.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// One rendered switcher row: a tab, named by its representative (active) pane.
struct TabSwitcherRow: Identifiable, Equatable {
    let id: TabID
    /// The tab's ⌘-number (1-based position in the tab bar) — the switcher doubles as a reminder that
    /// ⌘N jumps straight here.
    let number: Int
    /// SF Symbol name for the pane's kind, read from ``PaneChooserRegistry`` (the one registry the
    /// sidebar's iOS rows and the pane chooser share).
    let symbol: String
    /// Line 1 — the pane's identity.
    let title: String
    /// Line 2 — where it is, and how many panes the tab holds. `nil` ⇒ a single-line row.
    let detail: String?
    /// The trailing program label (`zsh`, `claude`, `make`), or `nil` when the title already says it.
    let slot: String?
    let isHighlighted: Bool
}

enum TabSwitcherRowsBuilder {
    /// The four store reads every part of a row needs, taken ONCE per row: what the pane is, where it
    /// is, which project owns it, and the title its program asserted. Bundled because the title / place
    /// / symbol resolvers each want a different subset and threading seven loose values through them is
    /// how the same pane ends up read twice with two answers.
    @MainActor
    private struct PaneFacts {
        let pane: PaneID
        let spec: PaneSpec?
        let kind: PaneKind
        let cwd: String?
        let liveTitle: String?
        let projectKey: String?

        init(pane: PaneID, spec: PaneSpec?, store: WorkspaceStore) {
            self.pane = pane
            self.spec = spec
            kind = spec?.kind ?? .terminal
            cwd = store.paneCwd(for: pane)
            liveTitle = store.liveProgramTitle(for: pane)
            projectKey = kind == .terminal ? store.paneProjectKey(pane) : nil
        }
    }

    /// Resolve the frozen candidate ring into rows. The ORDER is the switcher's (recency), not the tab
    /// bar's — that is the point of the surface. A candidate whose tab has been closed under the held ⌃
    /// is dropped, matching ``WorkspaceStore/commitTabSwitcher()``, which refuses to commit onto one.
    @MainActor
    static func rows(for switcher: TabSwitcher, store: WorkspaceStore) -> [TabSwitcherRow] {
        guard let session = store.tree.activeSession else { return [] }
        return switcher.candidates.enumerated().compactMap { index, id -> TabSwitcherRow? in
            guard let position = session.tabs.firstIndex(where: { $0.id == id }) else { return nil }
            let tab = session.tabs[position]
            guard let pane = tab.activePane ?? tab.allPaneIDs().first else { return nil }
            let facts = PaneFacts(pane: pane, spec: session.specs[pane], store: store)
            // The pane's volatile chrome through the sidebar's ONE resolver — the badge it returns is
            // what gates the running-command rung below (a fast `ls` must not flash into the title).
            let chrome = RailRowsBuilder.chrome(
                paneID: pane, kind: facts.kind, spec: facts.spec, tabID: tab.id,
                representativePane: pane, manualBadge: store.tabBadgeOverride(for: tab.id), store: store,
            )
            let paneName = title(tab: tab, facts: facts, chrome: chrome, store: store)
            let panePlace = facts.kind == .terminal
                ? place(projectKey: facts.projectKey, cwd: facts.cwd)
                : facts.spec?.railSubtitle(cwd: facts.cwd, liveTitle: facts.liveTitle)
            return TabSwitcherRow(
                id: id,
                number: position + 1,
                symbol: PaneChooserRegistry.option(for: facts.kind).symbol,
                title: paneName,
                detail: detail(place: panePlace, paneCount: tab.allPaneIDs().count),
                slot: slot(processLabel: chrome.processLabel, title: paneName),
                isHighlighted: index == switcher.highlightIndex,
            )
        }
    }

    /// The row's LINE 1. An explicit TAB rename wins outright (the user named this tab; nothing the pane
    /// is doing outranks that), then the pane's live identity chain — the same one
    /// ``NavigatorColumn`` hands its rows, so the switcher and the sidebar can never call one pane two
    /// things.
    ///
    /// `projectKey` IS passed to the structural rung on purpose: at the project root that yields the
    /// PROGRAM rather than the folder name, and an idle shell's empty result then falls through to the
    /// running command / last command / folder name. That fall-through is what tells two panes of one
    /// repo apart.
    @MainActor
    private static func title(
        tab: SlopDeskWorkspaceModel.Tab, facts: PaneFacts, chrome: RailRowsBuilder.RailRowChrome,
        store: WorkspaceStore,
    ) -> String {
        if !tab.title.isEmpty { return tab.title }
        let structural = RailRowsBuilder.rowTitle(
            kind: facts.kind, spec: facts.spec, cwd: facts.cwd, liveTitle: facts.liveTitle,
            processLabel: chrome.processLabel, projectKey: facts.projectKey,
        )
        // Busy-badge-gated, exactly as the sidebar gates it: the command titles the row with the same
        // reveal that earns the busy mark, so sub-second chatter never renames anything.
        let running = chrome.badge == .commandRunning || chrome.badge == .commandBusy
            ? store.liveRunningCommand(
                for: facts.pane, processLabel: RailRowsBuilder.processDisplayName(chrome.processLabel),
            )
            : nil
        return RailRowsBuilder.liveRowTitle(
            structuralTitle: structural,
            userRenamed: facts.spec?.userRenamed == true,
            isAgent: RailRowsBuilder.isAgentSession(
                status: chrome.status, processLabel: chrome.processLabel,
            ),
            intent: store.paneAgentIntent[facts.pane],
            runningCommand: running,
            programTitle: RailRowsBuilder.strippedProgramTitle(facts.liveTitle),
            processTitle: RailRowsBuilder.processDisplayName(chrome.processLabel),
            blocks: store.commandBlocks(for: facts.pane),
            kind: facts.kind,
            cwdTitle: RailRowsBuilder.cwdFolderName(facts.cwd),
            fallback: PaneChooserRegistry.option(for: facts.kind).title,
        )
    }

    /// WHERE a terminal pane is, as the row prints it: the project's folder name, and — when the pane
    /// strayed INTO the project's subtree — the relative path after it (`slopdesk/packages/api`). A pane
    /// whose cwd sits OUTSIDE its key's subtree (a stale key across an un-re-pushed `cd`) falls back to
    /// its own folder name rather than claiming a project it left; a keyless pane keeps its folder name.
    /// `nil` only when there is no cwd at all. Pure so the wording is unit-pinned.
    static func place(projectKey: String?, cwd: String?) -> String? {
        guard let key = TabOrderingEngine.normalizedProjectKey(projectKey) else {
            return RailRowsBuilder.cwdFolderName(cwd)
        }
        let header = TabOrderingEngine.projectSectionHeader(for: key)
        guard var path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return header }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == key { return header }
        guard path.hasPrefix(key + "/") else { return RailRowsBuilder.cwdFolderName(path) }
        return "\(header)/\(path.dropFirst(key.count + 1))"
    }

    /// LINE 2 = the place, then the pane count when the tab is SPLIT. The count is the other half of the
    /// user's question: a tab that reads `slopdesk` and holds three panes is not the same destination as
    /// a tab that reads `slopdesk` and holds one, and only this line can say so. A single-pane tab omits
    /// it (`1 pane` on every row is noise). Pure.
    static func detail(place: String?, paneCount: Int) -> String? {
        var parts: [String] = []
        if let place, !place.isEmpty { parts.append(place) }
        if paneCount > 1 { parts.append("\(paneCount) panes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The trailing program label — the sidebar's metadata slot, which keeps a bare `zsh` (as a TITLE it
    /// says nothing, in the slot it answers "what is this pane running" for an idle shell). Suppressed
    /// when the title already carries it: a pane titled `zsh` must not print `zsh` twice, and a row
    /// titled `make check` needs no `make` beside it. Pure.
    static func slot(processLabel: String?, title: String) -> String? {
        guard let name = RailRowsBuilder.slotProcessName(processLabel) else { return nil }
        let lowered = title.lowercased()
        let label = name.lowercased()
        if lowered == label || lowered.hasPrefix(label + " ") { return nil }
        return name
    }
}
