// FloatingPaneCard — the in-app floating-pane RENDERER (E21 WI-6 / ES-E21-3). The one genuine net-new
// view of E21: the float DOMAIN (`WorkspaceTreeOps.toggleFloating`/`moveFloating`/`resizeFloating`/
// `raiseFloating`/clamp + the store wrappers + `SplitTreeRenderModel.floatingLeaves`) was already built and
// unit-tested; only the view that draws a floating leaf and feeds the gestures back to the store was
// missing. This is that view.
//
// A floating pane overlays the tiled split layout, so — UNLIKE the flush, borderless tiled pane — it reads
// as a CARD: an otty rounded surface (radius + `Otty.Line.card` hairline border + a faint `Otty.State.shadow`
// drop shadow) with a slim top grab strip carrying the pane title + embed/close controls.
//
// KIND-GENERIC by construction: the card hosts the SAME `PaneContainer` the tiled `SplitContainer` mounts,
// so a terminal, a local web pane, AND a `.remoteGUI` / `.systemDialog` video pane all float for free (the
// "remote window floats" acceptance is satisfied with no kind branch here).
//
// ONE-SURFACE / NO-TEARDOWN invariant (the load-bearing rule): the card NEVER reconstructs the hosted
// surface across panes (`SplitContainer` keys each card `.id(PaneID)`), and the drag/resize gestures hold
// the LIVE frame in `@GestureState` — the store is untouched until `.onEnded`, so the terminal-grid /
// remote-window redraw (a reconcile) fires exactly ONCE on release, never per drag frame (the same remote-app
// rule the pane-divider + pane-move affordances follow). The live preview clamps with the SAME
// `WorkspaceTreeOps.clampFloatingFrame` the store commit uses, so the card never jumps on release.
//
// No AppKit child window / no PiP (E19 deferred that): this is a pure SwiftUI overlay inside the split
// container's compositor ZStack. SYSTEM / Otty tokens only.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct FloatingPaneCard: View {
    let store: WorkspaceStore
    let paneID: PaneID
    /// The solved + clamped placement rect from ``SplitTreeRenderModel/Layout/floatingLeaves`` (top-left
    /// origin, in the `SplitContainer` compositor's coordinate space). The committed frame the card draws at
    /// when no gesture is active.
    let frame: CGRect
    /// Whether this float is the active tab's active pane (drives the focus dim, exactly like a tiled pane).
    let isFocused: Bool
    /// The full container bounds the live drag/resize preview clamps into — the SAME rect the store reports
    /// via ``WorkspaceStore/updateFloatingBounds(_:)``, so the in-flight preview and the committed clamp share
    /// one coordinate space (no jump on release).
    let containerBounds: CGRect
    /// EAGER/STATIC render path for headless ImageRenderer snapshots — renders the card, skips the gestures.
    var staticMirror: Bool = false

    /// The live MOVE preview (grab-strip drag), reset to `.zero` automatically when the gesture ends — so the
    /// card snaps back to the freshly-committed `frame` on release with no extra state to clear.
    @GestureState private var moveTranslation: CGSize = .zero
    /// The live RESIZE preview (bottom-right corner drag), reset to `.zero` automatically on gesture end.
    @GestureState private var resizeTranslation: CGSize = .zero

    /// The slim top grab strip / title-bar height.
    private let titleBarHeight: CGFloat = 26
    /// The bottom-right resize grip's square size.
    private let resizeGrip: CGFloat = 16
    private var radius: CGFloat { Otty.Metric.radiusCard }

    /// Whether a drag (move or resize) is currently in flight — bumps the card's z-order so a grabbed card
    /// draws above any overlapping neighbour while it moves (the store commits the real raise on release).
    private var isInteracting: Bool { moveTranslation != .zero || resizeTranslation != .zero }

    /// The frame to draw RIGHT NOW: the committed `frame` plus any in-flight move/resize preview, clamped
    /// into the container with the SAME floor + edge clamp the store applies on commit (so no release jump).
    private var liveFrame: CGRect {
        var rect = frame
        rect.origin.x += moveTranslation.width
        rect.origin.y += moveTranslation.height
        rect.size.width += resizeTranslation.width
        rect.size.height += resizeTranslation.height
        return WorkspaceTreeOps.clampFloatingFrame(rect, in: containerBounds)
    }

    /// The pane title (host/window title for a `.remoteGUI`, shell title for a terminal), from the active
    /// session's spec table — a generic fallback when empty so the strip is never blank.
    private var title: String {
        let resolved = store.tree.activeSession?.specs[paneID]?.title ?? ""
        return resolved.isEmpty ? "Floating pane" : resolved
    }

    var body: some View {
        card
            .frame(width: liveFrame.width, height: liveFrame.height)
            .position(x: liveFrame.midX, y: liveFrame.midY)
            // Raise-on-grab (visual): a card being dragged jumps above its neighbours; otherwise the ZStack
            // declaration order (= `floatingPanes` z-order, last topmost) governs. The store performs the
            // real `raiseFloating` on focus/move commit, so this is purely the in-flight pop.
            .zIndex(isInteracting ? 1 : 0)
    }

    private var card: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle()
                .fill(Otty.Line.card)
                .frame(height: Otty.Metric.hairline)
            PaneContainer(
                store: store,
                paneID: paneID,
                isFocused: isFocused,
                // The content's live size IS the resize signal `PaneContainer`'s scrim keys off — during a
                // corner-resize drag this changes each frame, so the surface shows the calm "resizing" scrim
                // until the committed reflow lands (a move drag keeps it constant → no scrim).
                size: contentSize,
                staticMirror: staticMirror,
            )
            .id(paneID) // identity hazard: never reuse a hosted surface across panes
        }
        .background(Otty.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Otty.Line.card, lineWidth: Otty.Metric.cardBorderWidth),
        )
        .shadow(color: Otty.State.shadow, radius: 12, y: 4)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
    }

    /// The content area below the grab strip + hairline — the size handed to the hosted `PaneContainer`. Uses
    /// the ordered, NaN-faithful `CGFloat.maximum` (the house float idiom — never a bare `<`/`>` clamp).
    private var contentSize: CGSize {
        CGSize(
            width: CGFloat.maximum(0, liveFrame.width),
            height: CGFloat.maximum(0, liveFrame.height - titleBarHeight - Otty.Metric.hairline),
        )
    }

    // MARK: - Grab strip (move)

    private var titleBar: some View {
        HStack(spacing: Otty.Metric.space2) {
            Text(title)
                .font(.system(size: Otty.Typeface.footnote, weight: .medium))
                .foregroundStyle(Otty.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Otty.Metric.space2)
            // Embed: drop the float back into the tiled grid (the store re-inserts it next to where focus was).
            PlateIconButton(symbol: .pipExit, size: 11, plate: 20) {
                guard !staticMirror else { return }
                store.embedFloating(paneID)
            }
            // Close: drop the float (and its spec) via the shared close path.
            PlateIconButton(symbol: .xmark, size: 11, plate: 20) {
                guard !staticMirror else { return }
                store.closeFloating(paneID)
            }
        }
        .padding(.horizontal, Otty.Metric.space2)
        .frame(maxWidth: .infinity)
        .frame(height: titleBarHeight)
        .background(Otty.Surface.element)
        .contentShape(Rectangle())
        // A plain click on the strip focuses (+ raises) the pane without a move.
        .onTapGesture { if !staticMirror { store.focusPaneTree(paneID) } }
        .gesture(moveGesture)
        #if os(macOS)
            .pointerStyle(moveTranslation == .zero ? .grabIdle : .grabActive)
        #endif
    }

    /// The grab-strip move gesture: live preview in `@GestureState`, ONE store commit on release. The
    /// committed origin is `frame.origin + translation` (un-clamped); `store.moveFloating` raises + focuses
    /// the card then clamps it into the float viewport, mirroring the live preview's clamp.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($moveTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard !staticMirror else { return }
                let origin = CGPoint(
                    x: frame.origin.x + value.translation.width,
                    y: frame.origin.y + value.translation.height,
                )
                store.moveFloating(paneID, to: origin)
            }
    }

    // MARK: - Resize grip (bottom-right corner)

    private var resizeHandle: some View {
        ResizeGrip()
            .fill(Otty.Text.tertiary)
            .frame(width: resizeGrip, height: resizeGrip)
            .padding(Otty.Metric.space1)
            .contentShape(Rectangle())
            .gesture(resizeGesture)
        #if os(macOS)
            .pointerStyle(.frameResize(position: .bottomTrailing))
        #endif
    }

    /// The corner resize gesture: keeps the top-left origin fixed, grows/shrinks width+height by the drag
    /// translation, live-previewed in `@GestureState`, committed ONCE on release through `store.resizeFloating`
    /// (which applies the min-size floor + bounds clamp — identical to the live preview).
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($resizeTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard !staticMirror else { return }
                let resized = CGRect(
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.width + value.translation.width,
                    height: frame.height + value.translation.height,
                )
                store.resizeFloating(paneID, to: resized)
            }
    }
}

/// A small bottom-right corner grip — three diagonal hatches, the conventional "drag to resize" affordance.
private struct ResizeGrip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Three parallel diagonals fanning out from the bottom-right corner (closest = longest).
        let insets: [CGFloat] = [rect.width, rect.width * 0.62, rect.width * 0.28]
        for inset in insets {
            path.move(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
        }
        return path.strokedPath(StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}
#endif
