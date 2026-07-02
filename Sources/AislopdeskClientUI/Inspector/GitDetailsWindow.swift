// GitDetailsWindow — the Git details as a REAL auxiliary window (macOS), opened from the palette / View
// menu "Git Status" (the keyboard-centric entry — the inspector Details panel that used to carry a
// git-summary launcher row is REMOVED). The earlier sheet and popover cuts both read wrong (the sheet's
// NavigationStack chrome dropped its buttons into a clunky bottom bar; the popover felt like a transient
// peek when the user wants a persistent surface). A real `NSWindow` gets genuinely native chrome for
// free: a system titlebar carrying the branch (`.navigationTitle` → `window.title` via
// `NSHostingController.sceneBridgingOptions`), the deltas + remote as the `window.subtitle`, a REAL
// unified `NSToolbar` hosting the Refresh button, ⌘W/resize/miniaturize, and it stays up next to the
// workspace instead of blocking it.
//
// One window PER PANE (`GitDetailsWindowPresenter`, keyed by `PaneID`): re-invoking the command for the
// focused pane REBINDS + refreshes its model and fronts the existing window. The presenter also OWNS the
// per-pane `PaneMetadataModel`s (the old inspector column's job): one model per pane, so a slow refresh
// for a pane you left can never clobber the pane you switched to. The window watches its pane's liveness
// off the store and closes itself when the pane is gone (a dead pane must not keep a live-looking window).

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
    /// The live store + the pane this window belongs to — read so the body OBSERVES the pane's liveness
    /// (`store.handle(for:)` goes `nil` when the pane closes) and the window closes itself with it.
    let store: WorkspaceStore
    let pane: PaneID

    /// True while the toolbar refresh's metadata round-trip is in flight (drives the button's spinner).
    @State private var refreshing = false

    /// Whether this window's pane still exists. Read in the body (via `.onChange`) so the `@Observable`
    /// store registry re-evaluates it — the close-on-pane-death signal now that no inspector prunes.
    private var paneAlive: Bool { store.handle(for: pane) != nil }

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
            // Close with the pane: a dead pane must not keep a live-looking status window (the removed
            // inspector column used to prune these; the window now watches its own pane).
            .onChange(of: paneAlive) { _, alive in
                if !alive { GitDetailsWindowPresenter.close(pane: pane) }
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

/// Opens / fronts the per-pane Git details window, and OWNS the per-pane `PaneMetadataModel`s (the removed
/// inspector column used to mint + prune them). Plain AppKit window management (the app has ONE
/// SwiftUI `WindowGroup` — the workspace shell — and the pane's live `PaneMetadataModel` is presenter
/// state that a value-routed SwiftUI window scene could not reach), retained here keyed by pane and
/// released when the user closes the window / the pane dies.
@MainActor
enum GitDetailsWindowPresenter {
    private static var controllers: [PaneID: NSWindowController] = [:]
    /// The per-window close-notification tokens — removed (and unregistered) when the window closes.
    private static var closeObservers: [PaneID: NSObjectProtocol] = [:]
    /// PER-PANE decoded host metadata: one model per pane a Git window has shown, so a slow `refresh()`
    /// for the pane you left can never clobber the pane you switched to (the old inspector-column
    /// invariant). Kept across window closes (re-opening shows the retained data instantly, then
    /// refreshes); dropped when the pane dies (`close(pane:)`).
    private static var models: [PaneID: PaneMetadataModel] = [:]

    /// The palette / View-menu / bound-chord entry ("Git Status"): resolve the ACTIVE pane, bind (or
    /// re-bind — a warm reconnect mints no new façade but the status may have moved) its metadata model to
    /// the pane's live `MetadataClient`, kick a refresh, and show/front its window. No focused pane, or a
    /// pane with no live session, is a graceful no-op — never a trap.
    static func showForActivePane(store: WorkspaceStore) {
        guard let pane = store.tree.activeSession?.activeTab?.activePane else { return }
        let model = models[pane] ?? PaneMetadataModel()
        models[pane] = model
        let client = (store.handle(for: pane) as? LivePaneSession)?.connection?.activeMetadataClient
        model.setClient(client)
        if client != nil {
            Task { await model.refresh() }
        }
        show(model: model, pane: pane, store: store)
    }

    /// Shows the Git window for `pane`, fronting the existing one on a repeat invocation (the model is
    /// per-pane and long-lived, so the open window always renders the pane's CURRENT status).
    static func show(model: PaneMetadataModel, pane: PaneID, store: WorkspaceStore) {
        if let existing = controllers[pane] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: GitDetailsWindowRoot(model: model, store: store, pane: pane))
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

    /// Closes the window of a pane that no longer exists (called from the window root's own liveness
    /// watch) and drops the pane's retained model — a dead pane must not keep a live-looking status
    /// window, and its model would never be re-bound.
    static func close(pane: PaneID) {
        controllers.removeValue(forKey: pane)?.close()
        models.removeValue(forKey: pane)?.setClient(nil)
    }
}
#endif
