// SatellitePaneContent — what a satellite window SHOWS, and the seam the window reaches it through.
//
// A DETACHED pane (``WorkspaceStore/detachedPanes``) lives outside every tab's split tree but keeps its
// spec + live registry handle. The WINDOWS that carry it are pure AppKit and live in `SlopDeskMacUI`
// (`SatellitePaneWindows.swift`); what is here is the CONTENT they mount — the same ``PaneContainer``
// leaf UI a split slot mounts, so the terminal ring-replays into a fresh surface and a video pane
// re-hellos while the PTY / host session never dies.
//
// The window target sits above this one, so it cannot name a SwiftUI view here: ``SatellitePaneHost``
// hands it a mounted `NSView` instead — the same seam the split shell's columns come over, and it dies
// the day this leaf UI is AppKit too.

#if os(macOS) && canImport(SwiftUI)
import AppKit
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

// MARK: - Key-state relay (window key ⇄ pane focus)

/// Relays the satellite window's key state into its SwiftUI root: `isKey` drives ``PaneContainer``'s
/// `isFocused` — for a video pane that gates pointer/keycode forwarding (`RemotePaneContext.isActive`),
/// so a background satellite never fights the main window (or another satellite) for host input.
@MainActor
@Observable
package final class SatelliteWindowKeyState {
    package init() {}

    package var isKey = false
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
        .background(Slate.Surface.terminal)
        // A satellite IS glass edge-to-edge (no island margin — the window frame is the frame), so
        // the whole root adopts the glass polarity like the main window's island subtree.
        .environment(\.colorScheme, Slate.glassColorScheme)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            // A `.desktop` satellite has NO merge-back affordance — the desktop never joins a tab
            // (docs/DECISIONS.md 2026-07-22), so the grab strip would be a dead gesture.
            if let paneDrag, store.tree.spec(for: paneID)?.kind != .desktop {
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
                        .slateShadow(.chip)
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

// MARK: - The seam the window mounts it through

/// One satellite window's content, mounted. `decorate` wraps the root with the scene-level environment
/// (theme tint / colour scheme / preferences / overlay coordinator) — an `NSHostingView` root inherits
/// NOTHING from the main scene, so the app supplies that injection once per window.
@MainActor
package enum SatellitePaneHost {
    package static func contentView(
        store: WorkspaceStore,
        paneID: PaneID,
        keyState: SatelliteWindowKeyState,
        paneDrag: PaneDragCoordinator?,
        decorate: (AnyView) -> AnyView,
    ) -> NSView {
        let root = SatellitePaneRootView(store: store, paneID: paneID, keyState: keyState, paneDrag: paneDrag)
        return NSHostingView(rootView: decorate(AnyView(root)))
    }
}
#endif
