// SatellitePaneWindows — the macOS "detach pane into its own window" surface.
//
// A DETACHED pane (``WorkspaceStore/detachedPanes``) lives outside every tab's split tree but keeps its
// spec + live registry handle (reconcile counts detached ids as desired). This file materializes that
// state as real windows: ``SatelliteWindowsCoordinator`` diffs one plain-AppKit `NSWindowController` per
// detached pane into existence/away, each hosting the SAME ``PaneContainer`` leaf UI the split tree
// mounts — so the terminal ring-replays into a fresh surface and a video pane re-hellos, while the
// PTY / host session never dies.
//
// Deliberately PURE AppKit (never a second SwiftUI `WindowGroup`): the app's chord dispatcher /
// close-gate / pin actuator are single-window singletons keyed to the ONE workspace window captured via
// `.introspect(.window)` — a scene-created sibling would be re-captured and corrupt them. A plain
// `NSWindowController` is invisible to that machinery; ``SatellitePaneWindow`` is the marker class the
// few key-window-sensitive actuators (menu Close Window) check so they act on "the window I'm looking
// at" instead of the hidden main window.
//
// CLOSE = REATTACH, never destroy: `windowShouldClose` folds the pane back into its tab (origin tab when
// alive) and vetoes the AppKit close — the store mutation drops the pane from `detachedPanes`, and the
// coordinator's diff performs the one real window teardown. A PTY exit / explicit pane close routes
// through `closePaneTree` → `closeDetachedPane`, which also leaves via the same diff.

#if os(macOS) && canImport(SwiftUI)
import AppKit
import SlopDeskWorkspaceCore
import SwiftUI

// MARK: - SatellitePaneWindow (marker class)

/// The satellite `NSWindow` subclass — a MARKER: key-window-sensitive actuators (`overlayCoordinator
/// .closeWindow`, the menu Close Window item) test `NSApp.keyWindow is SatellitePaneWindow` to target
/// the satellite the user is looking at instead of the captured main workspace window.
final class SatellitePaneWindow: NSWindow {}

// MARK: - Key-state relay (window key ⇄ pane focus)

/// Relays the satellite window's key state into its SwiftUI root: `isKey` drives ``PaneContainer``'s
/// `isFocused` — for a video pane that gates pointer/keycode forwarding (`RemotePaneContext.isActive`),
/// so a background satellite never fights the main window (or another satellite) for host input.
@MainActor
@Observable
final class SatelliteWindowKeyState {
    var isKey = false
}

// MARK: - Root view

/// The satellite window's content: the SAME leaf UI a split-tree slot mounts (``PaneContainer`` routes
/// terminal / video by kind), sized by the window, focused iff the window is key, always on-screen
/// (`isVisible: true` — a satellite has no tab to hide behind; miniaturizing keeps streaming, v1).
struct SatellitePaneRootView: View {
    let store: WorkspaceStore
    let paneID: PaneID
    let keyState: SatelliteWindowKeyState

    var body: some View {
        GeometryReader { proxy in
            PaneContainer(
                store: store,
                paneID: paneID,
                isFocused: keyState.isKey,
                isVisible: true,
                size: proxy.size,
            )
        }
        .background(Slate.Surface.face)
        .ignoresSafeArea()
    }
}

// MARK: - Per-pane window controller

/// One satellite window: a titled/closable/resizable `NSWindow` whose content is an `NSHostingView`
/// over ``SatellitePaneRootView``. Close (X / ⌘W via menu) REATTACHES — `windowShouldClose` runs the
/// store op and returns `false`; the coordinator's diff (observing ``WorkspaceStore/detachedPanes``)
/// then closes the window for real, keeping ONE teardown path for every exit (reattach, pane close,
/// session close).
@MainActor
final class SatellitePaneWindowController: NSWindowController, NSWindowDelegate {
    let paneID: PaneID
    private weak var store: WorkspaceStore?
    private let keyState = SatelliteWindowKeyState()
    /// `true` while the coordinator itself is closing the window (the pane already left
    /// `detachedPanes`) — `windowShouldClose` must let THAT close pass instead of re-running reattach.
    private var closingFromCoordinator = false

    init(store: WorkspaceStore, paneID: PaneID, title: String, decorate: (AnyView) -> AnyView) {
        self.store = store
        self.paneID = paneID
        let window = SatellitePaneWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = title
        window.minSize = NSSize(width: 400, height: 300)
        // The workspace window must survive every satellite: an `NSWindowController`-owned window
        // released on close mid-diff double-frees; the coordinator owns the lifetime instead.
        window.isReleasedWhenClosed = false
        let root = SatellitePaneRootView(store: store, paneID: paneID, keyState: keyState)
        window.contentView = NSHostingView(rootView: decorate(AnyView(root)))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Closes the window on the coordinator's behalf (the pane already left the detached set) —
    /// flagged so `windowShouldClose` passes it through instead of re-running reattach.
    func closeFromCoordinator() {
        closingFromCoordinator = true
        close()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_: NSWindow) -> Bool {
        if closingFromCoordinator { return true }
        // User-initiated close = REATTACH (non-destructive; the pane folds back into its tab). Veto the
        // AppKit close — the store mutation drives the coordinator diff, which closes via
        // `closeFromCoordinator()`. If the store is gone (teardown race) allow the close.
        guard let store else { return true }
        store.reattachPane(paneID)
        return false
    }

    func windowDidBecomeKey(_: Notification) {
        keyState.isKey = true
    }

    func windowDidResignKey(_: Notification) {
        keyState.isKey = false
    }
}

// MARK: - Coordinator (detachedPanes ⇄ NSWindows diff)

/// Diffs ``WorkspaceStore/detachedPanes`` into satellite windows: opens a controller per newly-detached
/// pane, closes the controller of any pane that left the set (reattached or closed). Driven by the
/// scene's `.onChange(of: store.detachedPanes)` (plus one initial sync) — the store stays headless; only
/// this app layer touches AppKit windows.
@MainActor
final class SatelliteWindowsCoordinator {
    private var controllers: [PaneID: SatellitePaneWindowController] = [:]
    /// Cascade origin so a burst of detaches doesn't stack windows exactly on top of each other.
    private var cascadeStep = 0

    /// One sync pass. `decorate` wraps each window's root with the scene-level environment (theme tint /
    /// colour scheme / preferences / overlay coordinator) — an `NSHostingView` root inherits NOTHING from
    /// the main scene, so the app supplies the injection exactly once here.
    func sync(_ detached: [DetachedPane], store: WorkspaceStore, decorate: (AnyView) -> AnyView) {
        let desired = Set(detached.map(\.pane))

        // Close windows whose pane reattached or closed for real.
        for (paneID, controller) in controllers where !desired.contains(paneID) {
            controllers.removeValue(forKey: paneID)
            controller.closeFromCoordinator()
        }

        // Open a window per newly-detached pane, cascaded off centre.
        for entry in detached where controllers[entry.pane] == nil {
            let title = store.tree.spec(for: entry.pane)?.title ?? "Detached Pane"
            let controller = SatellitePaneWindowController(
                store: store, paneID: entry.pane, title: title, decorate: decorate,
            )
            if let window = controller.window {
                cascadeStep = (cascadeStep + 1) % 8
                let offset = CGFloat(cascadeStep) * 28
                window.setFrameTopLeftPoint(NSPoint(
                    x: window.frame.minX + offset,
                    y: window.frame.maxY - offset,
                ))
            }
            controllers[entry.pane] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }

        // Keep titles fresh on re-syncs (a rename / video rebind updates the spec title).
        for (paneID, controller) in controllers {
            if let title = store.tree.spec(for: paneID)?.title, controller.window?.title != title {
                controller.window?.title = title
            }
        }
    }
}
#endif
