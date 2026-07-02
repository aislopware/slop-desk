// GitDetailsWindow — the Git details as a REAL auxiliary window (macOS). The Info tab's git-summary row
// opens the full `GitStatusView` here; the earlier sheet and popover cuts both read wrong (the sheet's
// NavigationStack chrome dropped its buttons into a clunky bottom bar; the popover felt like a transient
// peek when the user wants a persistent surface). A real `NSWindow` gets genuinely native chrome for
// free: a system titlebar carrying the branch (`.navigationTitle` → `window.title` via
// `NSHostingController.sceneBridgingOptions`), the deltas + remote as the `window.subtitle`, a REAL
// unified `NSToolbar` hosting the Refresh button, ⌘W/resize/miniaturize, and it stays up next to the
// workspace instead of blocking it.
//
// One window PER PANE (`GitDetailsWindowPresenter`, keyed by `PaneID`): re-invoking the row for the same
// pane fronts the existing window; closing releases it; the inspector's pane-prune closes windows whose
// pane is gone (a dead pane must not keep a live-looking status window).

#if os(macOS) && canImport(SwiftUI)
import AislopdeskWorkspaceCore
import AppKit
import SwiftUI

/// The window's SwiftUI root: `GitStatusView` under scene-bridged native chrome. `.navigationTitle` /
/// `.navigationSubtitle` / `.toolbar` land on the REAL titlebar (the hosting controller opts into
/// `[.title, .toolbars]`), so the branch + deltas + remote read exactly like a system document window.
struct GitDetailsWindowRoot: View {
    /// The pane's decoded host metadata — its `gitStatus` + the `gitDiff`/`refresh` verbs.
    let model: PaneMetadataModel

    /// True while the toolbar refresh's metadata round-trip is in flight (drives the button's spinner).
    @State private var refreshing = false

    /// The window title: "Git — <branch>" (the branch alone is too anonymous in the Window menu),
    /// falling back to a generic "Git Status" while the pane has no repo/metadata.
    private var title: String {
        guard let status = model.gitStatus, status.hasRepo else { return "Git Status" }
        return "Git — \(status.branch.isEmpty ? "detached" : status.branch)"
    }

    /// The titlebar subtitle: ahead/behind deltas + the remote URL.
    private var subtitle: String {
        guard let status = model.gitStatus, status.hasRepo else { return "" }
        var parts: [String] = []
        if status.ahead != 0 { parts.append("↑\(status.ahead)") }
        if status.behind != 0 { parts.append("↓\(status.behind)") }
        if !status.remoteURL.isEmpty { parts.append(status.remoteURL) }
        return parts.joined(separator: "  ")
    }

    var body: some View {
        GitStatusView(model: model)
            .background(Slate.Surface.content)
            .frame(minWidth: 460, idealWidth: 560, minHeight: 320, idealHeight: 480)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    refreshButton
                }
            }
    }

    /// The toolbar refresh action — with CLICK FEEDBACK: the icon yields to a small spinner while the
    /// metadata round-trip is in flight (and the button disarms), so a click never reads as a no-op.
    private var refreshButton: some View {
        Button {
            refreshing = true
            Task {
                await model.refresh()
                refreshing = false
            }
        } label: {
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .disabled(!model.isConnected || refreshing)
        .help("Refresh git status")
    }
}

/// Opens / fronts the per-pane Git details window. Plain AppKit window management (the app has ONE
/// SwiftUI `WindowGroup` — the workspace shell — and the pane's live `PaneMetadataModel` is inspector
/// state that a value-routed SwiftUI window scene could not reach), retained here keyed by pane and
/// released when the user closes the window.
@MainActor
enum GitDetailsWindowPresenter {
    private static var controllers: [PaneID: NSWindowController] = [:]
    /// The per-window close-notification tokens — removed (and unregistered) when the window closes.
    private static var closeObservers: [PaneID: NSObjectProtocol] = [:]

    /// Shows the Git window for `pane`, fronting the existing one on a repeat invocation (the model is
    /// per-pane and long-lived, so the open window always renders the pane's CURRENT status).
    static func show(model: PaneMetadataModel, pane: PaneID) {
        if let existing = controllers[pane] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: GitDetailsWindowRoot(model: model))
        // Bridge the SwiftUI chrome onto the REAL window: `.navigationTitle`/`.navigationSubtitle` drive
        // `window.title`/`.subtitle`, `.toolbar` becomes a genuine unified `NSToolbar`.
        hosting.sceneBridgingOptions = [.title, .toolbars]

        let window = NSWindow(contentViewController: hosting)
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 560, height: 480))
        // The workspace theme decides light/dark for the whole surface (the window is not inside the
        // themed WindowGroup, so it would otherwise follow the OS appearance and could render a light
        // titlebar over dark themed content).
        window.appearance = NSAppearance(named: Slate.theme.isLight ? .aqua : .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        controllers[pane] = controller

        // Release on close — observe rather than a delegate so the hosting controller keeps whatever
        // delegation SwiftUI's bridging installs.
        closeObservers[pane] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main,
        ) { _ in
            Task { @MainActor in
                controllers.removeValue(forKey: pane)
                if let token = closeObservers.removeValue(forKey: pane) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window of a pane that no longer exists (called from the inspector's model prune) —
    /// a dead pane must not keep a live-looking status window.
    static func close(pane: PaneID) {
        controllers.removeValue(forKey: pane)?.close()
    }
}
#endif
