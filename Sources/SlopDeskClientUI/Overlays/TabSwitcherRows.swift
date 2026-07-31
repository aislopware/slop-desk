// TabSwitcherRows — what one ⌃⇥ switcher row SAYS, resolved off the live store.
//
// The switcher used to print `RailRowsBuilder.rowTitle` with no project key, which for a coding
// workspace resolves to the cwd's FOLDER NAME on nearly every row. Three panes opened in one repo then
// read `slopdesk` / `slopdesk` / `slopdesk`: the ring was ordered by recency but named by place, so the
// one thing the surface exists to answer — WHICH of these am I flipping to — was the one thing it did
// not say.
//
// The fix is the sidebar's own division of labour. The PROJECT is a section header, said once; a ROW is
// one line carrying only what differs — the pane's identity, then a quiet note for the sub-path it
// strayed into and the pane count when the tab is split. Identity comes from
// ``RailRowsBuilder/liveRowTitle(...)`` — the SAME chain the sidebar row and the window title read, so a
// pane is named identically wherever it is named, and a fix to the chain reaches all three.
//
// ⚠️ A header is a RUN BOUNDARY, not a re-sort. The display order is the frozen ring's (recency), because
// that is the order ⇥ steps in — grouping the rows by project would make the highlight jump around the
// card. So a header is emitted wherever consecutive rows change project, and one project can head more
// than one run. In the case this round was opened for — several panes in ONE repo — that is exactly one
// header over a clean list.
//
// Pure composers (`header` / `relativePath` / `note` / `items`) so the wording and the header runs are
// unit-pinned without a view; the one `@MainActor` entry is the store read.

import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// One rendered switcher row: a tab, named by its representative (active) pane.
struct TabSwitcherRow: Identifiable, Equatable {
    let id: TabID
    /// The tab's ⌘-number (1-based position in the tab bar) — the switcher doubles as a reminder that
    /// ⌘N jumps straight here.
    let number: Int
    /// The pane's identity — the only thing on the line that has to be read.
    let title: String
    /// The quiet remainder: the sub-path below the project, the pane count when the tab is split.
    /// `nil` for the common at-root single-pane tab.
    let note: String?
    /// The project this row sits in — the header text, carried per row so ``TabSwitcherRowsBuilder/items(_:)``
    /// can find the boundaries.
    let project: String?
    let isHighlighted: Bool
}

/// The card's display list: section headers interleaved with rows, in ring order.
struct TabSwitcherItem: Identifiable, Equatable {
    enum Content: Equatable {
        case section(String)
        case row(TabSwitcherRow)
    }

    /// Position in the display list. A plain index because a project may head more than one run, so its
    /// NAME is not unique and cannot be the identity.
    let id: Int
    let content: Content
}

enum TabSwitcherRowsBuilder {
    /// The four store reads every part of a row needs, taken ONCE per row: what the pane is, where it
    /// is, which project owns it, and the title its program asserted.
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

    /// The card's full display list for `switcher` — the one call a view makes.
    @MainActor
    static func items(for switcher: TabSwitcher, store: WorkspaceStore) -> [TabSwitcherItem] {
        items(rows(for: switcher, store: store))
    }

    /// Interleave section headers into `rows` wherever the project CHANGES between consecutive rows.
    /// A row with no project at all (a video pane, a shell whose cwd has not landed) heads nothing —
    /// it simply continues the run above it rather than opening an "Other" section the ring's order
    /// would scatter. Pure so the run rule is unit-pinned.
    static func items(_ rows: [TabSwitcherRow]) -> [TabSwitcherItem] {
        var out: [TabSwitcherItem] = []
        var current: String?
        for row in rows {
            if let project = row.project, project != current {
                current = project
                out.append(TabSwitcherItem(id: out.count, content: .section(project)))
            }
            out.append(TabSwitcherItem(id: out.count, content: .row(row)))
        }
        return out
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
            let project = facts.kind == .terminal
                ? header(projectKey: facts.projectKey, cwd: facts.cwd)
                : nil
            return TabSwitcherRow(
                id: id,
                number: position + 1,
                title: title(tab: tab, facts: facts, chrome: chrome, project: project, store: store),
                note: facts.kind == .terminal
                    ? note(
                        projectKey: facts.projectKey, cwd: facts.cwd,
                        paneCount: tab.allPaneIDs().count,
                    )
                    : facts.spec?.railSubtitle(cwd: facts.cwd, liveTitle: facts.liveTitle),
                project: project,
                isHighlighted: index == switcher.highlightIndex,
            )
        }
    }

    /// The row's LINE. An explicit TAB rename wins outright (the user named this tab; nothing the pane
    /// is doing outranks that), then the pane's live identity chain — the same one ``NavigatorColumn``
    /// hands its rows, so the switcher and the sidebar can never call one pane two things.
    ///
    /// `projectKey` IS passed to the structural rung on purpose: at the project root that yields the
    /// PROGRAM rather than the folder name, and an idle shell's empty result then falls through to the
    /// running command / last command / folder name. That fall-through is what tells two panes of one
    /// repo apart.
    ///
    /// The last rung of that chain is the folder name, which under a section header is the header said
    /// twice — so a row that lands there yields to its program instead (`zsh`, the sidebar's metadata
    /// slot). Only when even that is unknown does the row restate the folder, because a blank line says
    /// less than a redundant one.
    @MainActor
    private static func title(
        tab: SlopDeskWorkspaceModel.Tab, facts: PaneFacts, chrome: RailRowsBuilder.RailRowChrome,
        project: String?, store: WorkspaceStore,
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
        let resolved = RailRowsBuilder.liveRowTitle(
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
        return unrepeated(resolved, header: project, processLabel: chrome.processLabel)
    }

    /// A title that only restates its section header yields to the pane's program. Pure so the rule is
    /// unit-pinned.
    static func unrepeated(_ title: String, header: String?, processLabel: String?) -> String {
        guard let header, title == header else { return title }
        return RailRowsBuilder.slotProcessName(processLabel) ?? title
    }

    /// The SECTION a terminal pane belongs to: its project's folder name, or — for a pane with no
    /// project key yet — its own folder name, so it still lands under a place rather than nowhere.
    /// `nil` when there is no cwd at all. Pure.
    static func header(projectKey: String?, cwd: String?) -> String? {
        guard let key = TabOrderingEngine.normalizedProjectKey(projectKey) else {
            return RailRowsBuilder.cwdFolderName(cwd)
        }
        return TabOrderingEngine.projectSectionHeader(for: key)
    }

    /// Where the pane sits BELOW its project root, or `nil` at the root itself (the header already said
    /// it). A cwd OUTSIDE the key's subtree — a stale key across an un-re-pushed `cd` — gives its own
    /// folder name instead: hiding the location would lie, and a relative path cannot be formed. Pure.
    static func relativePath(projectKey: String?, cwd: String?) -> String? {
        guard let key = TabOrderingEngine.normalizedProjectKey(projectKey),
              var path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == key { return nil }
        if path.hasPrefix(key + "/") { return String(path.dropFirst(key.count + 1)) }
        return RailRowsBuilder.cwdFolderName(path)
    }

    /// The row's quiet remainder: the sub-path, then the pane count when the tab is SPLIT. The count is
    /// the other half of the user's question — a tab in `slopdesk` holding three panes is not the same
    /// destination as a tab in `slopdesk` holding one, and only this can say so. A single-pane tab at
    /// its root has no note at all, which is the common row and the reason the list reads quiet. Pure.
    static func note(projectKey: String?, cwd: String?, paneCount: Int) -> String? {
        var parts: [String] = []
        if let relative = relativePath(projectKey: projectKey, cwd: cwd) { parts.append(relative) }
        if paneCount > 1 { parts.append("\(paneCount) panes") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
