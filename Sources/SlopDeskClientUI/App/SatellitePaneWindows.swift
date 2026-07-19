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
/// A hover-revealed grab strip at the top is the MERGE-BACK affordance: drag it onto the main canvas
/// (insert beside / dock), a sidebar row, or the New-Tab slot — the same pill + drop vocabulary as the
/// in-canvas pane move.
struct SatellitePaneRootView: View {
    let store: WorkspaceStore
    let paneID: PaneID
    let keyState: SatelliteWindowKeyState
    /// The cross-container drag rendezvous — `nil` (previews / no wiring) hides the grab strip.
    var paneDrag: PaneDragCoordinator?

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
        .overlay(alignment: .top) {
            if let paneDrag {
                SatelliteDragStrip(store: store, paneID: paneID, coordinator: paneDrag)
            }
        }
    }
}

/// The satellite's top grab strip: the same hover-revealed `-` pill as ``PaneMoveHandle``, but the drag
/// tracks the GLOBAL mouse location (`NSEvent.mouseLocation`) — the destinations live in other windows,
/// so the local gesture coordinates are meaningless. Release commits ONE store op: reattach beside the
/// canvas target / dock at the canvas edge / beside a sidebar row's pane / into a fresh tab; anything
/// else cancels (the pane simply stays a satellite). Every path keeps the `PaneID`, so the live PTY /
/// video session survives and only the view remounts.
private struct SatelliteDragStrip: View {
    let store: WorkspaceStore
    let paneID: PaneID
    let coordinator: PaneDragCoordinator

    @State private var hovering = false
    @State private var dragging = false

    private var revealed: Bool { hovering || dragging }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Same contrast plate as `PaneMoveHandle.contentIsUnthemed`: a satellite usually
                // hosts a video stream, and the bare tertiary pill disappears over a light desktop.
                if store.tree.spec(for: paneID)?.kind.isVideo == true {
                    Capsule(style: .continuous)
                        .fill(Slate.Surface.face)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                        )
                        .frame(width: 44, height: 10)
                        .shadow(color: Slate.State.shadow, radius: 3, y: 1)
                        .opacity(revealed ? 1 : 0)
                        .scaleEffect(hovering && !dragging ? 1.15 : 1)
                }
                Capsule()
                    .fill(dragging ? Slate.State.accent : Slate.Text.tertiary)
                    .frame(width: 30, height: 4)
                    .opacity(revealed ? 1 : 0)
                    .scaleEffect(hovering && !dragging ? 1.15 : 1)
            }
            .frame(width: 160, height: 14)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(dragging ? .grabActive : .grabIdle)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        dragging = true
                        coordinator.updateDetachedDrag(source: paneID)
                    }
                    .onEnded { _ in
                        dragging = false
                        commit(coordinator.takeDestination())
                    },
            )
            .animation(Slate.Anim.dividerHover, value: revealed)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// ONE store op on release — the reattach twin of `SplitContainer.commitDestination`.
    private func commit(_ destination: PaneDragDestination) {
        switch destination {
        case let .canvas(.resplit(target, edge)):
            store.reattachPaneTree(paneID, beside: target, axis: edge.axis, before: edge.insertsBefore)
        case let .canvas(.dock(edge)):
            store.reattachPaneToActiveTabRootEdgeTree(paneID, edge: edge)
        case let .sidebarRow(anchor):
            store.reattachPaneTree(paneID, beside: anchor, axis: .horizontal, before: false)
        case .newTab:
            store.reattachPaneToNewTabTree(paneID)
        case .canvas,
             .tearOff,
             .none:
            break // already its own window — releasing anywhere else keeps it one
        }
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

    init(
        store: WorkspaceStore, paneID: PaneID, title: String, paneDrag: PaneDragCoordinator?,
        decorate: (AnyView) -> AnyView,
    ) {
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
        let root = SatellitePaneRootView(store: store, paneID: paneID, keyState: keyState, paneDrag: paneDrag)
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
        // Satellite focus truth (``WorkspaceStore/keySatellitePaneID``): a completion badge / desktop
        // notification for THIS pane must not fire while its window is the one the user is looking at.
        store?.noteSatelliteKey(paneID: paneID, isKey: true)
    }

    func windowDidResignKey(_: Notification) {
        keyState.isKey = false
        store?.noteSatelliteKey(paneID: paneID, isKey: false)
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
    /// the main scene, so the app supplies the injection exactly once here. `paneDrag` (optional) wires
    /// the grab strip into each satellite AND supplies the tear-off drop point: a pane detached by
    /// DRAGGING it out of the main window opens under the cursor, not in the centre-cascade.
    func sync(
        _ detached: [DetachedPane], store: WorkspaceStore, paneDrag: PaneDragCoordinator? = nil,
        decorate: (AnyView) -> AnyView,
    ) {
        let desired = Set(detached.map(\.pane))

        // Close windows whose pane reattached or closed for real.
        for (paneID, controller) in controllers where !desired.contains(paneID) {
            controllers.removeValue(forKey: paneID)
            controller.closeFromCoordinator()
        }

        // Open a window per newly-detached pane — at its recorded tear-off drop point when the detach
        // came from a drag, else cascaded off centre.
        for entry in detached where controllers[entry.pane] == nil {
            let title = store.tree.spec(for: entry.pane)?.title ?? "Detached Pane"
            let controller = SatellitePaneWindowController(
                store: store, paneID: entry.pane, title: title, paneDrag: paneDrag, decorate: decorate,
            )
            if let window = controller.window {
                if let drop = paneDrag?.takePlacement(for: entry.pane) {
                    // Land the window's top edge just above the drop point (screen coords are
                    // bottom-left origin), roughly centred on the cursor — the pane appears to settle
                    // where the user let go. AppKit clamps the frame onto the screen if the drop was
                    // near an edge.
                    window.setFrameTopLeftPoint(NSPoint(
                        x: drop.x - window.frame.width / 2,
                        y: drop.y + 24,
                    ))
                } else {
                    cascadeStep = (cascadeStep + 1) % 8
                    let offset = CGFloat(cascadeStep) * 28
                    window.setFrameTopLeftPoint(NSPoint(
                        x: window.frame.minX + offset,
                        y: window.frame.maxY - offset,
                    ))
                }
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

    /// Brings `paneID`'s satellite to the front (the ``WorkspaceStore/revealSatelliteWindow`` seam) —
    /// `openRemoteWindow` calls this instead of minting a duplicate live stream when the window is
    /// already detached. Returns `false` if no controller exists yet (e.g. this sync pass hasn't run).
    func reveal(_ paneID: PaneID) -> Bool {
        guard let controller = controllers[paneID] else { return false }
        controller.window?.makeKeyAndOrderFront(nil)
        return true
    }
}
#endif
