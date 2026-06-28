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
    /// The row's muted second line (``OttyTabRow`` subtitle). Kind-generic ``PaneSpec/railSubtitle`` (E21
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
    /// share one source of truth. Drives ``OttyTabRow``'s trailing lock glyph.
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
            for paneID in tab.root.allPaneIDs() {
                let spec = session.specs[paneID]
                let kind = spec?.kind ?? .terminal
                let title = spec?.lastKnownTitle ?? spec?.title ?? ""
                // E21 WI-5: the second line is the kind-generic ``PaneSpec/railSubtitle`` — a terminal's cwd,
                // or (for a `.remoteGUI`/`.systemDialog` video pane, which has no shell cwd) the host-side
                // window's owning app name (falling back to the window title). So a remote window reads as a
                // labelled WINDOW (title on line 1, host app on line 2) rather than a bare single line, instead
                // of the pre-WI-5 always-nil cwd. The builder stays kind-generic — the policy lives in the pure
                // `PaneSpec` derivation, not a branch here. (The coarse video-CONNECTION dot is deferred:
                // `PaneConnectionStatus.from` returns `.none` for a video pane by design, and surfacing a live
                // phase needs a `RemoteWindowModel`→store→row thread that would widen this WI past the gate;
                // recorded as an E21 §7 follow-up.)
                let subtitle = spec?.railSubtitle
                let status = store.paneAgentStatus[paneID] ?? .none
                let isSelected = tabIsActive && tab.activePane == paneID
                // E6 WI-2: the `#N` is the TAB shortcut number (1-based), the trailing label is the host's
                // coarse foreground process, and the row carries ONE fused badge from the pure resolver.
                let processLabel = store.paneForegroundProcess[paneID]
                let resolvedBadge = TabBadgeResolver.badge(
                    agent: status,
                    completion: store.panePendingCompletion[paneID],
                    isBusy: store.paneIsBusy(paneID),
                    foregroundProcess: processLabel,
                    // Freshness decays the clean-completion badge from the brief `.completed` checkmark
                    // flash to the persistent `.finished` accent dot — the store owns the clock (ephemeral
                    // `completedAt` vs now), the resolver stays pure.
                    completionFreshness: store.completionFreshness(forPane: paneID),
                    // E14/K1: a live OSC 9;4 progress resolves to the `.running` spinner (in-progress /
                    // indeterminate) or `.error` (held-red `9;4;2`) via the EXISTING precedence — no new badge.
                    progress: store.progress(for: paneID),
                )
                // E13 WI-3: apply the otty "Agent Behaviour" badge toggles AFTER the pure resolver — a per-pane
                // override (the tab context-menu) beats the global default. `error`/`sudo`/`caffeinate` survive
                // the gate (never an agent-badge opt-out); `running`/`completed`/`finished`/`awaitingInput` drop
                // when their toggle is OFF.
                let badge = AgentBadgeGates.gated(resolvedBadge, by: store.agentBadgeGates(for: paneID))
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

/// The pure placement model for otty's sidebar tab-reorder INSERTION-LINE indicator (E18 WI-7). The spec
/// (`user-interface__drag-and-drop.md`): dragging a rail tab shows "a thin insertion-line indicator [for]
/// the landing position between tabs". The navigator draws a 2pt accent rule on the TOP edge of the row a
/// reorder drag is hovering. This model resolves WHERE (which rendered index) that rule is anchored so the
/// decision is unit-pinned without a SwiftUI view (the live `isTargeted`/overlay render is a Phase-3 HW
/// target). It is purely additive to the reorder drag — it never changes the drop payload, the resolved
/// move, or the manual-reorder gate (``TabDragPayload`` owns those).
enum TabReorderInsertionLine {
    /// Width (points) of the otty insertion-line indicator — a thin 2pt accent rule.
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
