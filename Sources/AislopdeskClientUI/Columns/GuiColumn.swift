// GuiColumn — the RIGHT remote-windows column (the TabSide partition). The terminal workspace (sidebar +
// content) owns the left; this column owns the `.remoteGUI` tabs' pane area (`SplitContainer(side: .gui)`,
// the same identity-preserving compositor the terminal column uses, so a column-collapse / tab switch never
// tears down a live video surface). PURE CONTENT since the window-dock removal (2026-07-04): switching
// between open remote windows is the sidebar's Windows section; browsing/opening host windows is the
// Remote-Window picker (the sidebar footer's window `+`, the empty state below, the palette). macOS-only —
// iOS keeps the single-region shell.

#if os(macOS)
import AislopdeskWorkspaceCore
import SwiftUI

struct GuiColumn: View {
    let store: WorkspaceStore
    /// Opens the Remote-Window picker modal (``OverlayCoordinator/openRemotePicker()``) — the empty-state
    /// affordance. No-op default keeps the column standalone-mountable in previews.
    var onOpenPicker: () -> Void = {}

    /// The GUI side's tabs — the pane-area empty-state gate.
    private var guiTabs: [AislopdeskWorkspaceCore.Tab] {
        store.tree.activeSession?.tabs(on: .gui) ?? []
    }

    var body: some View {
        paneArea
            // CARD-ON-GLASS (2026-07-04 v3): same half-gap margin as ContentColumn — the remote-window
            // card floats on the shared `WindowGlassBackdrop` (rendered by macDetail behind both
            // columns); the video card TOP-ALIGNS with the terminal card (no header band above it).
            .padding(Slate.Metric.paneGap / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Pane area (the GUI side's compositor / empty state)

    private var paneArea: some View {
        Group {
            if guiTabs.isEmpty {
                ContentUnavailableView {
                    Label("No Remote Windows", systemImage: "macwindow")
                } description: {
                    Text("Browse the host's open windows and stream one here.")
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
#endif
