// RailRowsBuilder — the pure mapping from the live WorkspaceStore tree → the rail's `[RailRow]` (V1
// "Panes" granularity: one row per visible pane of the active session's tabs). Kept pure + static so
// AislopdeskClientUITests can pin the mapping (selection, title/subtitle, agent status) without a view.

import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import Foundation

/// The data a single rail row binds to (derived from a pane within the active session's tabs). A pure value
/// type — kept with the builder logic (it previously lived in the deleted `TabRow` view, but carries no view
/// / design-system coupling). The native rail in L1+ rebuilds the row VIEW over this same model.
struct RailRow: Identifiable, Equatable {
    let id: PaneID
    let tabID: TabID
    let kind: PaneKind
    let title: String
    /// The row's muted second line (``SlateTabRow`` subtitle). Kind-generic ``PaneSpec/railSubtitle`` (E21
    /// WI-5): a terminal's cwd, or a video pane's host-app/window label; `nil` ⇒ a single-line row.
    let subtitle: String?
    let status: ClaudeStatus
    /// The 1-based tab shortcut number — the ⌘1…⌘9 target = tab index+1 (E6 WI-2). Split-tab panes share
    /// the same `#N` (it is a TAB number, not a pane number), per the per-pane→per-tab mapping (plan Design #1).
    let tabNumber: Int
    /// The single fused status badge for the row (E6 WI-1 `TabBadgeResolver`), or `nil` when all-clear.
    let badge: TabBadgeKind?
    /// The coarse host-reported foreground-process name (wire type 26), shown trailing on the active row; `nil`
    /// when the host has not reported one.
    let processLabel: String?
    /// Whether this pane's input gate is READ-ONLY (E17 ES-E17-1 / WI-3) — read from the store's convergent
    /// ``WorkspaceStore/paneReadOnly`` set so the sidebar lock indicator and the pane's `🔒 READ ONLY ×` pill
    /// share one source of truth. Drives ``SlateTabRow``'s trailing lock glyph.
    let readOnly: Bool
    /// Selected = the row's tab is active AND this pane is the tab's active pane.
    let isSelected: Bool
}

enum RailRowsBuilder {
    /// Build the rail rows for the active session. One row per visible (non-floating) pane of each tab,
    /// in tab order then pre-order pane order. `selected` = the tab is active AND the pane is that tab's
    /// active pane. Agent status comes from the store's per-pane mirror (`.none` ⇒ plain terminal).
    @MainActor
    static func rows(for store: WorkspaceStore) -> [RailRow] {
        guard let session = store.tree.activeSession else { return [] }
        // FIX 1: observe the flash-decay tick so the rail re-renders ONCE at the completion flash-window
        // boundary. `completionFreshness(forPane:)` below reads the wall clock at build time (NOT an
        // `@Observable` dependency); without this read a quiet completed pane would never re-render and its
        // brief `.completed` checkmark would stick. The store bumps the tick after `completedFlashWindow`
        // to invalidate the observing rail, so the row decays to the `.finished` dot on its own.
        _ = store.completionFlashTick
        let activeTabIndex = session.activeTabIndex
        var out: [RailRow] = []
        for (tabIndex, tab) in session.tabs.enumerated() {
            let tabIsActive = tabIndex == activeTabIndex
            // E20 ES-E20-3: a MANUAL `tab badge --kind` override (if any) is rendered on the tab's
            // REPRESENTATIVE (active) pane row — the badge is per-tab, so it lands on the one row that
            // stands in for the tab (the same representative `tab list` reports). Resolved once per tab.
            let representativePane = tab.activePane ?? tab.allPaneIDs().first
            let manualBadge = store.tabBadgeOverride(for: tab.id)
            // E21 ES-E21-2/-4: enumerate the FULL pane set (`tab.allPaneIDs()` = tree + floating layer), not
            // just `tab.root.allPaneIDs()`, so a floated pane (incl. a floated `.remoteGUI` remote window)
            // stays a first-class peer in the sidebar rail — matching OpenQuickly, which uses `tab.allPaneIDs()`.
            for paneID in tab.allPaneIDs() {
                let spec = session.specs[paneID]
                let kind = spec?.kind ?? .terminal
                // A TERMINAL row's line 1 is its cwd's FOLDER NAME (`aislopdesk`), not the generic
                // "Terminal" / raw shell title — an explicit user rename still wins (see `rowTitle`).
                let title = Self.rowTitle(kind: kind, spec: spec)
                // Line 2: a terminal shows its git line (branch ↑/↓ · N changed) when the store has a
                // summary for a repo cwd, else the kind-generic ``PaneSpec/railSubtitle`` — a terminal's
                // plain cwd, or (for a `.remoteGUI`/`.systemDialog` video pane, which has no shell cwd)
                // the host-side window's owning app name (falling back to the window title). So a remote
                // window reads as a labelled WINDOW (title on line 1, host app on line 2) rather than a
                // bare single line. (The coarse video-CONNECTION dot is deferred:
                // `PaneConnectionStatus.from` returns `.none` for a video pane by design, and surfacing a live
                // phase needs a `RemoteWindowModel`→store→row thread that would widen this WI past the gate;
                // recorded as an E21 §7 follow-up.)
                let gitLine = kind == .terminal ? store.paneGitSummary[paneID]?.compactLine : nil
                let subtitle = gitLine ?? spec?.railSubtitle
                let status = store.paneAgentStatus[paneID] ?? .none
                let isSelected = tabIsActive && tab.activePane == paneID
                // E6 WI-2: the `⌘N` is the TAB shortcut number (1-based), the trailing label is the host's
                // coarse foreground process, and the row carries ONE fused badge from the pure resolver.
                let processLabel = store.paneForegroundProcess[paneID]
                // E13 WI-3 + Progress cluster: the SOURCE-AWARE gating masks the resolver inputs by source so
                // the agent toggles (per-pane override beats the global default) and the command "TAB BADGE"
                // toggles gate their OWN badge families independently — a program's busy / OSC 9;4 progress
                // spinner and an OSC 9;4;2 progress error are never silenced by an agent toggle. Freshness
                // decays the clean-completion badge (store owns the clock); the resolver stays pure.
                let gatedBadge = TabBadgeGating.resolve(
                    agent: status,
                    completion: store.panePendingCompletion[paneID],
                    isBusy: store.paneIsBusy(paneID),
                    foregroundProcess: processLabel,
                    completionFreshness: store.completionFreshness(forPane: paneID),
                    progress: store.progress(for: paneID),
                    agentGates: store.agentBadgeGates(for: paneID),
                    commandGates: store.commandBadgeGates,
                )
                // E20 ES-E20-3: an explicit `tab badge --kind` override wins for the representative row,
                // bypassing the agent-badge gates (it is an explicit CLI affordance, not an agent signal).
                let badge = (paneID == representativePane ? manualBadge : nil) ?? gatedBadge
                out.append(RailRow(
                    id: paneID,
                    tabID: tab.id,
                    kind: kind,
                    title: title,
                    subtitle: subtitle,
                    status: status,
                    tabNumber: tabIndex + 1,
                    badge: badge,
                    processLabel: processLabel,
                    readOnly: store.isReadOnly(for: paneID),
                    isSelected: isSelected,
                ))
            }
        }
        return out
    }

    /// The row's LINE-1 title. A `.terminal` pane titles itself by its working directory's FOLDER NAME
    /// (`/Volumes/…/aislopdesk` → `aislopdesk`) — the identity a coding tool actually navigates by — with
    /// two escapes: an EXPLICIT user rename always wins (a custom `title` that is neither the registry
    /// default nor the shell-title auto-promotion), and a pane with no known cwd yet falls back to the
    /// old shell-title chain. Non-terminal kinds keep the E21 chain (`lastKnownTitle ?? title`)
    /// unchanged. Pure + static so the mapping is unit-pinned without a view.
    static func rowTitle(kind: PaneKind, spec: PaneSpec?) -> String {
        let fallback = spec?.lastKnownTitle ?? spec?.title ?? ""
        guard kind == .terminal, let spec else { return fallback }
        // Renamed = a non-empty custom title that is neither the registry default ("Terminal") nor the
        // load-time auto-promotion of the shell title (`title == lastKnownTitle`, see
        // `WorkspacePersistence.loadTree()`).
        let defaultTitle = PaneChooserRegistry.option(for: .terminal).title
        if !spec.title.isEmpty, spec.title != defaultTitle, spec.title != spec.lastKnownTitle {
            return spec.title
        }
        return cwdFolderName(spec.lastKnownCwd) ?? fallback
    }

    /// The display folder name of a cwd: its last path component (`/a/b/repo` → `repo`, trailing-slash
    /// tolerant), the root as `/`, a bare `~` kept as-is. `nil` for `nil`/blank so the caller falls back
    /// — never an empty title.
    static func cwdFolderName(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        var path = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { return "/" }
        let leaf = path.split(separator: "/").last.map(String.init) ?? path
        return leaf.isEmpty ? nil : leaf
    }

    /// Filter rows by a lower-cased search query against the title + subtitle (empty query ⇒ all).
    static func filtered(_ rows: [RailRow], query: String) -> [RailRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    /// Compose the sidebar search filter with the store-derived tab grouping (E6 WI-5): narrow `rows` by
    /// `query`, then bucket the survivors into sections following `groups` (``TabOrderingEngine`` tab order, as
    /// returned by ``WorkspaceStore/orderedTabGroups(now:)``). A group whose rows all filter out is DROPPED (no
    /// empty header). Pane order within a tab is preserved (`Dictionary(grouping:)` keeps element order). Pure +
    /// static so the navigator's glue is unit-testable without a SwiftUI view.
    static func sectioned(_ rows: [RailRow], groups: [OrderedTabGroup], query: String) -> [RailRowGroup] {
        let survivors = filtered(rows, query: query)
        let byTab = Dictionary(grouping: survivors, by: \.tabID)
        var out: [RailRowGroup] = []
        for group in groups {
            var groupRows: [RailRow] = []
            for tabID in group.tabIDs {
                groupRows.append(contentsOf: byTab[tabID] ?? [])
            }
            guard !groupRows.isEmpty else { continue }
            out.append(RailRowGroup(header: group.header, rows: groupRows))
        }
        return out
    }
}

/// One rendered sidebar section: an optional `header` (the group title, `nil` ⇒ the ungrouped flat list) and
/// the rows in render order. A pure value (`Equatable`) so ``RailRowsBuilder/sectioned(_:groups:query:)`` is
/// pinnable headlessly; the navigator wraps it in an `Identifiable` row for `ForEach`.
struct RailRowGroup: Equatable {
    let header: String?
    let rows: [RailRow]
}

/// The drag payload for a sidebar tab reorder (E6 WI-5, FIX 2): a row's TAB IDENTITY (a UUID string), NOT
/// its rendered index. Encoding identity is what makes the WYSIWYG drag correct under ``TabSort/updated``: a
/// completion can re-derive ``WorkspaceStore/orderedTabGroups(now:)`` and visually shuffle the rows WHILE a
/// drag is in flight, and an index-based payload would then drop whatever tab is NOW at the stale index. An
/// id payload instead resolves the dragged tab's CURRENT rendered position at drop time. Decoding is
/// validate-then-DROP: a payload that is not a parseable UUID, or not a LIVE tab id in the rendered order,
/// yields no move — so a foreign plaintext drag (e.g. an in-range numeric string from another app, which the
/// old `Int(payload)` decode would have ACCEPTED) triggers no reorder and no Sort→Manual flip. Pure + static
/// so the navigator's drag glue is unit-testable without a SwiftUI view.
enum TabDragPayload {
    /// Encode a row's tab identity as its `.draggable` payload string.
    static func encode(_ tabID: TabID) -> String { tabID.raw.uuidString }

    /// Resolve a dropped `payload` plus the drop `targetTabID` into the `(from, to)` RENDERED-position move,
    /// or `nil` to DROP the drag. `renderedOrder` is the LIVE flat sidebar order at drop time, so `from`
    /// follows the dragged tab's identity even if the order changed since the drag began. Dropped when the
    /// payload is unparseable / not a live tab, the target isn't shown, or it is a self-drop (`from == to`).
    static func resolveMove(
        payload: String, onto targetTabID: TabID, in renderedOrder: [TabID],
    ) -> (from: Int, to: Int)? {
        guard let uuid = UUID(uuidString: payload) else { return nil }
        guard let from = renderedOrder.firstIndex(of: TabID(raw: uuid)) else { return nil }
        guard let to = renderedOrder.firstIndex(of: targetTabID) else { return nil }
        guard from != to else { return nil }
        return (from, to)
    }
}

/// The pure placement model for the sidebar tab-reorder INSERTION-LINE indicator (E18 WI-7). The spec
/// (`user-interface__drag-and-drop.md`): dragging a rail tab shows "a thin insertion-line indicator [for]
/// the landing position between tabs". The navigator draws a 2pt accent rule on the TOP edge of the row a
/// reorder drag is hovering. This model resolves WHERE (which rendered index) that rule is anchored so the
/// decision is unit-pinned without a SwiftUI view (the live `isTargeted`/overlay render is a Phase-3 HW
/// target). It is purely additive to the reorder drag — it never changes the drop payload, the resolved
/// move, or the manual-reorder gate (``TabDragPayload`` owns those).
enum TabReorderInsertionLine {
    /// Width (points) of the insertion-line indicator — a thin 2pt accent rule.
    static let thickness: CGFloat = 2

    /// The rendered index whose TOP edge gets the insertion line, or `nil` to draw NOTHING. `hovering` is the
    /// tab id of the row the reorder drag is currently over (`nil` ⇒ no row targeted); `reorderEnabled` is
    /// the navigator's manual-reorder gate (off under an active grouping / a search filter, where a hand
    /// landing slot has no meaning — so NO landing rule is promised); `renderedOrder` is the LIVE flat
    /// sidebar order. Returns `nil` when reorder is gated off, no row is targeted, or the targeted row is not
    /// shown in the live order (a stale / filtered-out target) — never a stray rule against a hidden row.
    static func anchorIndex(
        hovering target: TabID?, reorderEnabled: Bool, in renderedOrder: [TabID],
    ) -> Int? {
        guard reorderEnabled, let target else { return nil }
        return renderedOrder.firstIndex(of: target)
    }
}
