// TabSwitcherOverlay — the ⌃⇥ switcher's face: a floating card listing the session's tabs in
// MOST-RECENTLY-USED order with the provisional highlight marked.
//
// Presented as a plain always-mounted `.overlay` rather than a `.sheet`, unlike every other surface in
// `OverlayHostView`. A sheet is the wrong instrument here: it animates in over ~0.3s and takes key focus,
// but this overlay's whole lifetime is the length of a held ⌃ — often under 200ms — and stealing focus
// mid-gesture would break the `flagsChanged` release that commits it. It renders nothing when the store's
// `tabSwitcher` is nil, so at rest it costs a branch.
//
// It is a READOUT, not a control: the dispatcher owns the gesture (open / step / commit / cancel), and this
// view has no gestures, no buttons, and no state of its own. Clicking through it is impossible because it
// never accepts hits.
//
// `Slate.*` tokens ONLY (raw font/radius literals fail `scripts/check-ds-leaks.sh`). No AppKit — this
// compiles for iOS with the rest of `SlopDeskClientUI`, where the switcher is simply never opened.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct TabSwitcherOverlay: View {
    let store: WorkspaceStore

    /// One rendered row: the tab's ⌘-number, its title, and whether the highlight is on it.
    private struct Row: Identifiable {
        let id: TabID
        let number: Int
        let title: String
        let isHighlighted: Bool
    }

    var body: some View {
        if let switcher = store.tabSwitcher {
            card(rows(for: switcher))
                // A readout never takes hits: the gesture lives entirely on the keyboard, and swallowing a
                // click here would strand a user who reached for the workspace behind it.
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func card(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: Slate.Metric.space1) {
            ForEach(rows) { row in
                HStack(spacing: Slate.Metric.space2) {
                    // The ⌘-number, so the switcher doubles as a reminder that ⌘N jumps straight here.
                    Text("\(row.number)")
                        .font(.system(size: Slate.Typeface.small, design: .monospaced))
                        .foregroundStyle(Slate.Text.tertiary)
                        .frame(minWidth: Slate.Metric.space3, alignment: .trailing)
                    Text(row.title)
                        .font(.system(size: Slate.Typeface.body))
                        .foregroundStyle(row.isHighlighted ? Slate.Text.primary : Slate.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Slate.Metric.space3)
                .frame(height: Slate.Metric.heightRow)
                .background(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusItem)
                        .fill(row.isHighlighted ? Slate.State.selected : .clear),
                )
            }
        }
        .padding(Slate.Metric.space2)
        .frame(width: cardWidth)
        .slateCard(radius: Slate.Metric.radiusCard, fill: Slate.Surface.raised)
        .shadow(color: Slate.State.shadow, radius: Slate.Metric.space2, y: Slate.Metric.space1)
    }

    /// Wide enough for a folder-name title without wrapping, narrow enough to read as a switcher rather
    /// than a panel — the toast card's width, so the two floating surfaces share one measure.
    private let cardWidth: CGFloat = 340

    /// Maps the frozen candidate ring onto rows. The ORDER is the switcher's, not the tab bar's — that is
    /// the point of the surface: it shows recency, which the tab bar cannot.
    private func rows(for switcher: TabSwitcher) -> [Row] {
        let tabs = store.tree.activeSession?.tabs ?? []
        return switcher.candidates.enumerated().compactMap { index, id -> Row? in
            guard let position = tabs.firstIndex(where: { $0.id == id }) else { return nil }
            return Row(
                id: id,
                number: position + 1,
                title: title(of: tabs[position]),
                isHighlighted: index == switcher.highlightIndex,
            )
        }
    }

    /// A tab's display name, resolved through the SAME `RailRowsBuilder.rowTitle` the sidebar rail and the
    /// titlebar chip read — so a tab reads identically wherever it is named. An explicit rename wins; then
    /// the active pane's cwd folder name; then its foreground program.
    /// `SlopDeskWorkspaceModel.Tab` spelled out: SwiftUI ships its own `Tab` type, so the bare name is
    /// ambiguous in a view file.
    private func title(of tab: SlopDeskWorkspaceModel.Tab) -> String {
        if !tab.title.isEmpty { return tab.title }
        guard let pane = tab.activePane else { return "Tab" }
        let spec = store.tree.activeSession?.specs[pane]
        let kind = spec?.kind ?? .terminal
        let cwd = store.paneCwd(for: pane)
        let titledByProcess = RailStructureKey.titledByProcess(kind: kind, spec: spec, cwd: cwd)
        let resolved = RailRowsBuilder.rowTitle(
            kind: kind, spec: spec, cwd: cwd, liveTitle: store.liveProgramTitle(for: pane),
            processLabel: titledByProcess ? store.paneForegroundProcess[pane] : nil,
        )
        return resolved.isEmpty ? "Tab" : resolved
    }
}
#endif
