// WorkspaceTabStrip — the tabs, laid HORIZONTALLY in the titlebar band, for the state where the
// sidebar is hidden (user-directed 2026-08-09).
//
// Collapsing the navigator used to cost the whole tab list: the panes were still there and still
// switchable by chord, but nothing on screen said which ones existed or which one was live. The
// strip is that list rotated 90° into the band the island's top moat already reserves — so hiding
// the sidebar buys back its width without giving up the one thing it was for.
//
// It is the SAME model as the sidebar, deliberately: the same memoized rows, the same By-Project
// sectioning, and the same project ISLANDS (``SlateProjectIsland``) — a contiguous run of tabs
// belonging to one project shares that project's tinted bed, so a tab keeps its project's colour
// exactly the way a sidebar row does. Selection stays the compact island stamped out of the terminal
// glass. Nothing here invents a second vocabulary for tabs; the axis is all that changed.
//
// What the horizontal form gives up is the second register: no git line, no cwd subtitle, no
// process label. A chip is a title, its status mark and its bed. The band is 40pt tall and the
// chips share it with the window controls — there is room for identity, not for readouts, and the
// readouts are one ⌘⇧L away.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct WorkspaceTabStrip: View {
    let store: WorkspaceStore
    /// The memoized structural rows — the SAME array the sidebar renders, so the two surfaces can
    /// never disagree about which panes exist or what order they are in.
    let rows: [RailRow]
    let onSelect: (PaneID) -> Void

    /// The chip's own height — one rung under the sidebar row (`heightTabRow`), because the band
    /// also carries the traffic lights and a full-height chip crowded them.
    private static let chipHeight = Slate.Metric.heightControl

    /// The selection plate's morph namespace, shared by every chip in the strip so the plate TRAVELS
    /// between tabs. The strip's own namespace, not the sidebar's: only one of the two is ever
    /// mounted, and a plate cannot travel to a row that does not exist.
    @Namespace private var selectionMorph

    var body: some View {
        let sections = RailRowsBuilder.sectionedByProject(
            rows, tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        ScrollView(.horizontal) {
            HStack(spacing: Slate.Metric.space2) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    island(section)
                }
            }
            .padding(.horizontal, Slate.Metric.space1)
            // The morph's transaction — same contract as the sidebar list's: the plate can only
            // travel inside an animated transaction, and the chips that flip `active` are leaves
            // this body does not otherwise re-render.
            .animation(
                Slate.Anim.selectionMorph,
                value: store.tree.activeSession?.activeTab?.activePane,
            )
        }
        .scrollIndicators(.hidden)
        // Exactly the bed's own height — 24 chip + 2×4 inset = 32 — which the titlebar then centres
        // in the 40pt band, leaving 4pt of ground above and below (user-directed 2026-08-09). The
        // beds used to spend a full `space2` and fill the band edge to edge, reading as a painted
        // header rather than as the sidebar's bed rotated.
        .frame(height: Self.chipHeight + 2 * Slate.Metric.space1)
    }

    /// One project's run of tabs on its own bed. A keyless section still gets a bed (the neutral
    /// one) so the strip's rhythm does not break where a video pane sits between two projects.
    private func island(_ section: RailRowGroup) -> some View {
        SlateProjectIsland(projectKey: section.projectKey, verticalInset: Slate.Metric.space1) {
            HStack(spacing: Slate.Metric.space1) {
                ForEach(section.rows) { row in
                    TabStripChip(
                        store: store, row: row, morph: selectionMorph,
                        onSelect: { onSelect(row.id) },
                    )
                    .id(row.leafIdentity)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One LIVE chip. Same contract as ``SidebarLiveRow``: the STRUCTURAL identity rides the memoized
/// ``RailRow`` while selection, the fused badge and the shown title are read fresh HERE — so a
/// status tick or a focus change repaints this leaf and never the strip above it. Reading selection
/// in the leaf is not an optimisation: an init-param `active` inside a lazy container leaves the
/// previously selected chip lit next to the new one.
private struct TabStripChip: View {
    let store: WorkspaceStore
    let row: RailRow
    /// The strip's shared selection-morph namespace — see ``SlateCompactIsland/morph``.
    let morph: Namespace.ID
    let onSelect: () -> Void

    @State private var hovering = false

    /// A chip never grows past this, however long a running command's title runs — one wide tab must
    /// not push every other tab out of the band.
    private static let maxWidth: CGFloat = 160

    var body: some View {
        // The flash-decay tick at LEAF scope, exactly as the sidebar row observes it — a quiet
        // completed pane must still re-render at the flash-window boundary.
        // swiftlint:disable:next redundant_discardable_let
        let _ = store.completionFlashTick
        let active = row.id == store.tree.activeSession?.activeTab?.activePane
        let chrome = RailRowsBuilder.liveChrome(for: row, store: store)
        let title = RailRowsBuilder.liveTitle(
            for: row, chrome: chrome, store: store,
            fallback: PaneChooserRegistry.option(for: row.kind).title,
        )
        // The otty agent-integration look: only an AGENT session's title wears the leading `✳`.
        // Gated exactly as the sidebar row gates it — an unconditional mark put the glyph on every
        // plain shell.
        let agent = RailRowsBuilder.isAgentSession(
            status: chrome.status, processLabel: chrome.processLabel,
        )
        let mark = StatusPresentation.statusDot(
            working: chrome.status == .working,
            badge: chrome.badge,
            agentIdle: chrome.status == .idle,
            agentFinish: RailRowsBuilder.finishIsAgents(
                badge: chrome.badge, status: chrome.status,
                unseenDone: store.paneUnseenDone.contains(row.id),
            ),
        )
        SlateCompactIsland(selected: active, hovering: hovering, morph: morph) {
            HStack(spacing: Slate.Metric.space1) {
                Text.nerdAware(
                    agent ? RailRowsBuilder.agentMarkedTitle(title) : title,
                    size: Slate.Typeface.footnote,
                )
                .font(.system(
                    size: Slate.Typeface.footnote,
                    weight: active || attention(chrome.badge) ? .medium : .regular,
                ))
                .foregroundStyle(active ? Slate.Text.primary : Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                if let mark { StatusDotView(style: mark) }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .frame(height: Slate.Metric.heightControl)
        }
        .frame(maxWidth: Self.maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .animation(Slate.Anim.smallFade, value: active)
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// The same weight step the sidebar row spends: a state that WAITS on you reads bold, and the
    /// mark's hue beside it says which state.
    private func attention(_ badge: TabBadgeKind?) -> Bool {
        guard let badge else { return false }
        return StatusPresentation.attentionInk(badge) != nil
    }
}
#endif
