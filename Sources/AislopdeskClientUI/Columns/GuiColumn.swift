// GuiColumn — the RIGHT remote-windows column (the TabSide partition). The terminal workspace (sidebar +
// content) owns the left; this column owns the `.remoteGUI` tabs: a top WINDOW STRIP (one chip per open
// remote-window tab — select / close — plus the `+` that opens the Remote-Window picker) over the GUI
// side's pane area (`SplitContainer(side: .gui)`, the same identity-preserving compositor the terminal
// column uses, so a column-collapse / tab switch never tears down a live video surface). macOS-only —
// iOS keeps the single-region shell. Slate tokens only (the ds-leaks ratchet).

#if os(macOS)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct GuiColumn: View {
    let store: WorkspaceStore
    /// Opens the Remote-Window picker modal (``OverlayCoordinator/openRemotePicker()``) — the `+` /
    /// empty-state affordance. No-op default keeps the column standalone-mountable in previews.
    var onOpenPicker: () -> Void = {}

    /// The GUI side's tabs (the strip's chips), in tab-bar order.
    private var guiTabs: [AislopdeskWorkspaceCore.Tab] {
        store.tree.activeSession?.tabs(on: .gui) ?? []
    }

    /// The chip that reads selected — the side's DISPLAYED tab (the active tab when focus is here, else
    /// the column's remembered last-active GUI tab).
    private var shownTabID: TabID? { store.displayedTabID(on: .gui) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Slate.Metric.titlebarHeight) // the traffic-light / titlebar strip
            windowStrip
            Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
            paneArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Slate.Surface.window)
    }

    // MARK: Window strip (the GUI side's tab chips + the `+`)

    private var windowStrip: some View {
        HStack(spacing: Slate.Metric.space1) {
            Text("WINDOWS")
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Slate.State.header)
            ScrollView(.horizontal) {
                HStack(spacing: Slate.Metric.space1) {
                    ForEach(guiTabs) { tab in
                        WindowTabChip(
                            title: chipTitle(for: tab),
                            selected: tab.id == shownTabID,
                            onSelect: { select(tab) },
                            onClose: { store.closeTab(tab.id) },
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
            PlateIconButton(symbol: .plus) { onOpenPicker() }
                .help("Open a remote window…")
                .accessibilityLabel("Open a remote window")
        }
        .padding(.horizontal, Slate.Metric.space3)
        .padding(.bottom, 6)
    }

    /// A chip's label: the tab's representative (active) pane spec title — the window title the pick
    /// committed (or the app name when the window was untitled).
    private func chipTitle(for tab: AislopdeskWorkspaceCore.Tab) -> String {
        guard let session = store.tree.activeSession,
              let pane = tab.activePane ?? tab.allPaneIDs().first,
              let spec = session.specs[pane]
        else { return "Window" }
        let title = spec.lastKnownTitle ?? spec.title
        return title.isEmpty ? "Window" : title
    }

    /// Select a chip: make its tab active (keyboard focus moves to this column) and focus its pane.
    private func select(_ tab: AislopdeskWorkspaceCore.Tab) {
        store.selectTab(id: tab.id)
        if let pane = tab.activePane ?? tab.allPaneIDs().first {
            store.focusPaneTree(pane)
        }
    }

    // MARK: Pane area (the GUI side's compositor / empty state)

    private var paneArea: some View {
        Group {
            if guiTabs.isEmpty {
                ContentUnavailableView {
                    Label("No Remote Windows", systemImage: "macwindow")
                } description: {
                    Text("Stream a window from the connected Mac.")
                } actions: {
                    Button("Open Remote Window…") { onOpenPicker() }
                }
            } else {
                SplitContainer(store: store, side: .gui)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One window-strip chip: the remote-window tab's title, a flat rounded plate (selected = card fill +
/// active border, like a `SlateTabRow`), with a hover-revealed close `×`.
private struct WindowTabChip: View {
    let title: String
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Slate.Metric.space1) {
                Image(systemSymbol: .macwindow)
                    .font(.system(size: Slate.Typeface.small))
                    .foregroundStyle(Slate.Text.icon)
                Text(title)
                    .font(.system(size: Slate.Typeface.body, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Slate.Text.primary : Slate.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hover {
                    Button(action: onClose) {
                        Image(systemSymbol: .xmark)
                            .font(.system(size: Slate.Typeface.small, weight: .semibold))
                            .foregroundStyle(Slate.Text.icon)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(title)")
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .frame(height: 24)
            .background(
                selected ? AnyShapeStyle(Slate.Surface.card) : AnyShapeStyle(hover ? Slate.State.hover : .clear),
                in: .rect(cornerRadius: Slate.Metric.radiusTab),
            )
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusTab)
                    .strokeBorder(selected ? Slate.Line.active : .clear, lineWidth: Slate.Metric.hairline),
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Slate.Anim.smallFade, value: hover)
        .help(title)
    }
}
#endif
