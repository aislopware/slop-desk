// GuiColumn — the RIGHT remote-windows column (the TabSide partition). The terminal workspace (sidebar +
// content) owns the left; this column owns the `.remoteGUI` tabs: a top WINDOW DOCK (macOS-dock-like —
// one tile per host window with the app icon + title + a running dot on the open ones, plus the `+`
// that opens the Remote-Window picker) over the GUI side's pane area (`SplitContainer(side: .gui)`, the
// same identity-preserving compositor the terminal column uses, so a column-collapse / tab switch never
// tears down a live video surface). The dock polls the host's shareable-window list over the SAME
// discovery seam the picker uses (every `dockPollGap` while connected — the host coalesces concurrent
// list answers, and `AppLaunchMonitor` already polls this cadence for layout triggers). macOS-only —
// iOS keeps the single-region shell. Slate tokens only (the ds-leaks ratchet).

#if os(macOS)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct GuiColumn: View {
    let store: WorkspaceStore
    /// The app-global connection — the dock's discovery target (host + UDP ports) and its "poll only
    /// while connected" gate. Optional so the column stays standalone-mountable in previews.
    var connection: AppConnection?
    /// The shared chrome — gates the dock poll off while THIS column is collapsed (a hidden dock needs
    /// no window list; a collapsed split item keeps the hosting view mounted, so `.task` alone can't
    /// tell). `nil` (previews) polls whenever connected.
    var chrome: WorkspaceChromeState?
    /// Opens the Remote-Window picker modal (``OverlayCoordinator/openRemotePicker()``) — the `+` /
    /// empty-state affordance. No-op default keeps the column standalone-mountable in previews.
    var onOpenPicker: () -> Void = {}

    /// The host's shareable windows, refreshed by the dock poll (empty until the first reply / while
    /// disconnected — open tabs still get tiles from the tree, so the dock is never blank with tabs open).
    @State private var hostWindows: [RemoteWindowSummary] = []

    /// The dock's poll cadence — matches ``AppLaunchMonitor``'s discovery rhythm; the host's
    /// `ListAnswerGuard` coalesces concurrent answers, so this stays cheap.
    private static let dockPollGap: Duration = .seconds(4)

    /// The GUI side's tabs — the dock's "open" set + the pane-area empty-state gate.
    private var guiTabs: [AislopdeskWorkspaceCore.Tab] {
        store.tree.activeSession?.tabs(on: .gui) ?? []
    }

    /// The tile that reads selected — the side's DISPLAYED tab (the active tab when focus is here, else
    /// the column's remembered last-active GUI tab).
    private var shownTabID: TabID? { store.displayedTabID(on: .gui) }

    var body: some View {
        VStack(spacing: 0) {
            dockHeader
            Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
            paneArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Slate.Surface.window)
        // The dock poll: refresh the host-window list every `dockPollGap` while this column is VISIBLE
        // (a collapsed split item keeps the hosting view mounted, so the loop itself gates on the chrome
        // flag), skipping the query while disconnected (the seam would only time out). Keying the task on
        // the collapse flag restarts the loop on a reveal, so expanding the column refreshes immediately
        // instead of waiting out a sleeping tick.
        .task(id: chrome?.guiCollapsed ?? false) {
            while !Task.isCancelled {
                if chrome?.guiCollapsed != true {
                    await refreshDock()
                }
                try? await Task.sleep(for: Self.dockPollGap)
            }
        }
    }

    // MARK: Dock header (the window dock + the `+`)

    private var dockHeader: some View {
        HStack(alignment: .center, spacing: Slate.Metric.space1) {
            WindowDockStrip(
                items: WindowDockModel.items(windows: hostWindows, session: store.tree.activeSession),
                selectedTabID: shownTabID,
                onSelect: { activate($0) },
            )
            Spacer(minLength: 0)
            SlatePlateButton(symbol: .plus) { onOpenPicker() }
                .help("Open a remote window…")
                .accessibilityLabel("Open a remote window")
                .padding(.trailing, Slate.Metric.space2)
        }
        .padding(.bottom, Slate.Metric.space1)
    }

    /// One dock poll: query the host's shareable windows over the picker's discovery seam. Skipped while
    /// disconnected / no seam (headless) — the stale list is kept (better a slightly-old dock than a
    /// blank one on a transient reconnect).
    private func refreshDock() async {
        guard let connection, case .connected = connection.status,
              let query = RemoteWindowDiscovery.shared else { return }
        let t = connection.target
        hostWindows = await query(t.host, t.mediaPort, t.cursorPort)
    }

    /// Dock-tile click: an OPEN tile focuses its tab (keyboard focus moves to this column); a closed one
    /// opens a NEW remote-window tab streaming that host window (the side derivation lands it here).
    private func activate(_ item: WindowDockItem) {
        if let tabID = item.tabID {
            store.selectTab(id: tabID)
            if let session = store.tree.activeSession,
               let tab = session.tabs.first(where: { $0.id == tabID }),
               let pane = tab.activePane ?? tab.allPaneIDs().first
            {
                store.focusPaneTree(pane)
            }
        } else if let windowID = item.windowID {
            store.newRemoteWindowTab(windowID: windowID, title: item.title, appName: item.appName)
        }
    }

    // MARK: Pane area (the GUI side's compositor / empty state)

    private var paneArea: some View {
        Group {
            if guiTabs.isEmpty {
                ContentUnavailableView {
                    Label("No Remote Windows", systemImage: "macwindow")
                } description: {
                    Text("Pick a window from the dock above, or browse the full list.")
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
