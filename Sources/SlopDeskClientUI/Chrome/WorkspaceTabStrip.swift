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
// process label. A chip is a title, its status mark and its bed. The chips share one band row with
// the window controls — there is room for identity, not for readouts, and the readouts are one
// ⌘⇧L away.

#if canImport(SwiftUI)
import SlopDeskClientCore
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

    var body: some View {
        let sections = RailRowsBuilder.sectionedByProject(
            rows, tabOrder: store.flatOrderedTabIDs(), query: "",
        )
        // The beds are dealt for the RUN, not per section: two projects whose basenames hash alike
        // must not stand shoulder to shoulder in one colour, and only the ordered list knows that.
        // The strip's order is the sidebar's order rotated, so both surfaces deal identically.
        let deal = Slate.ProjectTint.Deal(keys: sections.map(\.projectKey))
        ScrollView(.horizontal) {
            HStack(spacing: Slate.Metric.space2) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    island(section, tint: deal[index])
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
        // Exactly one control tall — the bed IS its run of tabs, with no collar in either axis
        // (user-directed 2026-08-09). A collar made this the tallest row in the band, where every
        // other tab across the window is a plain control rung, and left a stub of tint hanging off
        // each end of a run. What separates two projects here is the gap between their beds.
        .frame(height: Self.chipHeight)
    }

    /// One project's run of tabs on its own bed. A keyless section still gets a bed (the neutral
    /// one) so the strip's rhythm does not break where a video pane sits between two projects.
    ///
    /// The run also OWNS its selection-morph namespace (``SlateMorphScope``), the same seam the
    /// sidebar's islands draw: the plate slides between two tabs of one project and ignites in place
    /// when it arrives from another (user-directed 2026-08-10). The two surfaces must agree — they
    /// render the same rows in the same order and only one is ever mounted, so a rule that held on
    /// one axis and not the other would read as the gesture changing when the sidebar is hidden.
    private func island(_ section: RailRowGroup, tint: Color) -> some View {
        SlateMorphScope { morph in
            SlateProjectIsland(tint: tint, verticalInset: 0, horizontalInset: 0) {
                HStack(spacing: Slate.Metric.space1) {
                    ForEach(section.rows) { row in
                        TabStripChip(
                            store: store, row: row, morph: morph,
                            onSelect: { onSelect(row.id) },
                        )
                        .id(row.leafIdentity)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One LIVE chip. Same contract as a navigator row: the STRUCTURAL identity rides the memoized
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
                    weight: attention(chrome.badge)
                        ? StatusPresentation.attentionWeight
                        : (active ? .medium : .regular),
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

    /// The same weight step the sidebar row spends (``StatusPresentation/attentionWeight``): a state
    /// that WAITS on you reads bold, and the mark's hue beside it says which state. The sidebar's
    /// urgent-title HUE deliberately stops there — this strip names the SPLITS of the tab you are
    /// already in, and its rows are one line apart from the mark that carries the hue.
    private func attention(_ badge: TabBadgeKind?) -> Bool {
        guard let badge else { return false }
        return StatusPresentation.attentionInk(badge) != nil
    }
}
#endif
