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

    /// Every number below is ``Slate/GrabPill``'s, the same rungs ``PaneMoveHandle`` reads, and this
    /// is the pair that file's move was made for: the drag that starts on THIS pill ends on one of
    /// those, so a user merging a satellite back into the canvas sees both inside one gesture. A pill
    /// that changed size on the way across would read as the thing they are holding changing shape.
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
                        .frame(width: Slate.GrabPill.plateWidth, height: Slate.GrabPill.plateHeight)
                        .slateShadow(.chip)
                        .opacity(revealed ? 1 : 0)
                        .scaleEffect(hovering && !dragging ? Slate.GrabPill.hoverScale : 1)
                }
                Capsule()
                    .fill(dragging ? Slate.State.accent : Slate.Text.tertiary)
                    .frame(width: Slate.GrabPill.barWidth, height: Slate.GrabPill.barHeight)
                    .opacity(revealed ? 1 : 0)
                    .scaleEffect(hovering && !dragging ? Slate.GrabPill.hoverScale : 1)
            }
            // The CEILING rung outright, not the canvas handle's clamp: a detached window is wide
            // enough that the leaf-share resolves here for any window worth detaching into, and a
            // strip measured off the WINDOW would grow with a resize while the pane inside it does
            // not. Named rather than repeated, so it cannot fall out of step with the clamp's top.
            .frame(width: Slate.GrabPill.stripWidthMax, height: Slate.GrabPill.stripHeight)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // Through ``PanePointer`` like every other piece of pane chrome, not `pointerStyle`
            // directly: this file is Mac-only so the raw call compiles, and that is exactly how the
            // rule grew a third spelling once already.
            .panePointer(dragging ? .grabActive : .grabIdle)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        dragging = true
                        coordinator.updateDetachedDrag(source: paneID)
                    }
                    .onEnded { _ in
                        dragging = false
                        // ONE store op on release, in the reattach family — the SAME four-case
                        // decision the canvas commits a spring-loaded landing through, asked once
                        // (``PaneDragCommit``). `.tearOff` and `.none` fall through it untouched,
                        // which is the honest answer here: the pane already is its own window, so
                        // releasing anywhere else keeps it one.
                        PaneDragCommit.commit(
                            coordinator.takeDestination(),
                            pane: paneID,
                            origin: .detached,
                            in: store,
                        )
                    },
            )
            .animation(Slate.Anim.dividerHover, value: revealed)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - The seam the window mounts it through

/// One satellite window's content, mounted. An `NSHostingView` root inherits NOTHING from the main
/// scene (the hosting-root environment trap), so the ONE key this subtree reads is applied here.
///
/// ⚠️ THE INJECTION BELONGS ON THIS SIDE OF THE SEAM, and increment 57a is where it moved. It used to
/// arrive as a `decorate: (AnyView) -> AnyView` closure the window target passed down — which meant
/// `SlopDeskMacUI` had to import the draining target for five lines that name no AppKit at all, purely
/// to spell `\.overlayCoordinator`'s modifier. The key is declared in THIS target and read by
/// ``PaneContainer``, also in this target; a caller one floor up was never the right place to say so.
/// The coordinator crosses as a plain value instead — `SlopDeskClientCore` is below both halves — and
/// the whole application is the one line below.
///
/// The parameter is NON-optional deliberately. The environment slot is `OverlayCoordinator?` because a
/// test or a preview may have none, but the satellite window always has one, and a defaulted-`nil`
/// parameter is exactly the shape that lets a future caller silently mount a pane whose drop toasts go
/// nowhere. It dies with increment 62, when the satellite's content becomes AppKit.
@MainActor
package enum SatellitePaneHost {
    package static func contentView(
        store: WorkspaceStore,
        paneID: PaneID,
        keyState: SatelliteWindowKeyState,
        paneDrag: PaneDragCoordinator?,
        overlay: OverlayCoordinator,
    ) -> NSView {
        let root = SatellitePaneRootView(store: store, paneID: paneID, keyState: keyState, paneDrag: paneDrag)
        return NSHostingView(rootView: root.overlayCoordinator(overlay))
    }
}
#endif
