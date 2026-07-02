// CompositorPaneCard — the UNIFIED leaf compositor (E21 WI-6 / F4 / ES-E21-3). It renders BOTH a flush tiled
// pane AND an in-app floating card from ONE `SplitContainer` `ForEach`, switching ONLY the chrome + placement
// by a per-leaf `isFloating` flag — the hosted `PaneContainer` sits at the SAME structural position in either
// mode, so a float↔embed membership move keeps the pane's SwiftUI identity (and its terminal / `.remoteGUI`
// video surface) ALIVE.
//
// WHY ONE VIEW (the F4 fix): tiled panes and floating cards used to live in TWO sibling `ForEach`es. `.id`
// only dedups WITHIN one `ForEach`, so a pane moving between them was handed a NEW identity → the hosted
// surface was dismantled + rebuilt (a `.remoteGUI` stream RECONNECTS + black-flashes — contradicting
// DECISIONS.md WI-6 "a floated remote window keeps streaming across float/move/resize/embed"). Merging both
// into ``SplitTreeRenderModel/Layout/compositorLeaves`` — one keyed list — keeps the move within one
// collection. To preserve identity ACROSS the `isFloating` toggle, the card NEVER wraps `PaneContainer` in an
// `if`/`else` (a `_ConditionalContent` branch flip resets state): the chrome is applied as layout-stable
// modifiers (a title strip whose height collapses to 0, an opacity-gated border/shadow/clip) so the child is
// the same structural node either way.
//
// A floating pane overlays the tiled split layout, so — UNLIKE the flush, borderless tiled pane — it reads
// as a CARD: a rounded surface (radius + `Slate.Line.card` hairline border + a faint `Slate.State.shadow`
// drop shadow) with a slim top grab strip carrying the pane title + embed/close controls. A tiled pane
// collapses all of that to nothing (0-height strip, 0 radius, transparent border/shadow), so its rendering is
// visually identical to the old bare `PaneContainer`.
//
// KIND-GENERIC by construction: the card hosts the SAME `PaneContainer` the tiled layout mounts, so a
// terminal AND a `.remoteGUI` / `.systemDialog` video pane all float for free (the
// "remote window floats" acceptance is satisfied with no kind branch here).
//
// ONE-SURFACE / NO-TEARDOWN invariant (the load-bearing rule): the card NEVER reconstructs the hosted surface
// across panes (`SplitContainer` keys each card `.id(PaneID)` AND `PaneContainer` is keyed `.id(PaneID)`
// inside), and the float drag/resize gestures hold the LIVE frame in `@GestureState` — the store is untouched
// until `.onEnded`, so the terminal-grid / remote-window redraw (a reconcile) fires exactly ONCE on release,
// never per drag frame (the same remote-app rule the pane-divider + pane-move affordances follow). The live
// preview clamps with the SAME `WorkspaceTreeOps.clampFloatingFrame` the store commit uses, so the card never
// jumps on release.
//
// No AppKit child window / no PiP (E19 deferred that): this is a pure SwiftUI overlay inside the split
// container's compositor ZStack. SYSTEM / Slate tokens only.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct CompositorPaneCard: View {
    let store: WorkspaceStore
    let paneID: PaneID
    /// The solved placement rect for this leaf (top-left origin, in the `SplitContainer` compositor's
    /// coordinate space): the solver tile rect when tiled, or the clamped `floatingLeaves` rect when floating.
    /// The committed frame the card draws at when no float gesture is active.
    let frame: CGRect
    /// Whether this leaf floats (card chrome + drag/resize gestures + bounds-clamped live preview) or tiles
    /// (flush, borderless, fixed to `frame`). The ONLY thing that differs between the two modes — the hosted
    /// `PaneContainer` is the same structural node either way, so flipping this never tears down the surface.
    let isFloating: Bool
    /// Whether this leaf is the active tab's active pane (drives the focus dim, exactly like a tiled pane).
    let isFocused: Bool
    /// Whether this leaf is currently ON-SCREEN (its tab is active AND it is not zoom-hidden). Forwarded to
    /// ``PaneContainer`` → ``GuiLeafView`` to drive the video activation lifecycle off visibility instead of
    /// the (never-firing under keep-all-mounted) `onDisappear`. Defaults to `true` for callers that don't gate.
    var isVisible: Bool = true
    /// The full container bounds the live drag/resize preview clamps into — the SAME rect the store reports
    /// via ``WorkspaceStore/updateFloatingBounds(_:)``, so the in-flight preview and the committed clamp share
    /// one coordinate space (no jump on release). Unused while tiled.
    let containerBounds: CGRect
    /// EAGER/STATIC render path for headless ImageRenderer snapshots — renders the card, skips the gestures.
    var staticMirror: Bool = false

    /// The live MOVE preview (grab-strip drag), reset to `.zero` automatically when the gesture ends — so the
    /// card snaps back to the freshly-committed `frame` on release with no extra state to clear.
    @GestureState private var moveTranslation: CGSize = .zero
    /// The live RESIZE preview (bottom-right corner drag), reset to `.zero` automatically on gesture end.
    @GestureState private var resizeTranslation: CGSize = .zero

    /// The slim top grab strip / title-bar height (when floating; collapses to 0 when tiled).
    private let titleBarHeight: CGFloat = 26
    /// The bottom-right resize grip's square size.
    private let resizeGrip: CGFloat = 16
    /// The card corner radius when floating; 0 (a plain rectangle) when tiled so a tiled pane stays flush.
    private var radius: CGFloat { isFloating ? Slate.Metric.radiusCard : 0 }

    /// Whether a float drag (move or resize) is currently in flight — bumps the card's z-order so a grabbed
    /// card draws above any overlapping neighbour while it moves (the store commits the real raise on release).
    /// Always `false` while tiled (the gestures are disabled, so the translations never leave `.zero`).
    private var isInteracting: Bool { isFloating && (moveTranslation != .zero || resizeTranslation != .zero) }

    /// The frame to draw RIGHT NOW. A TILED leaf is fixed to its solved `frame` (no gesture preview). A
    /// FLOATING leaf adds any in-flight move/resize preview, clamped into the container with the SAME floor +
    /// edge clamp the store applies on commit (so no release jump).
    private var liveFrame: CGRect {
        guard isFloating else { return frame }
        var rect = frame
        rect.origin.x += moveTranslation.width
        rect.origin.y += moveTranslation.height
        rect.size.width += resizeTranslation.width
        rect.size.height += resizeTranslation.height
        return WorkspaceTreeOps.clampFloatingFrame(rect, in: containerBounds)
    }

    /// The pane title (host/window title for a `.remoteGUI`, shell title for a terminal), from the active
    /// session's spec table — preferring the LIVE ``PaneSpec/lastKnownTitle`` (the OSC 0/2 / page title the
    /// rail, titlebar, and status bar all bind to) over the static spec `title`, so the floating card's grab
    /// strip tracks the live title instead of the stale launch title. A generic fallback when empty so the
    /// strip is never blank.
    private var title: String {
        let spec = store.tree.activeSession?.specs[paneID]
        if let live = spec?.lastKnownTitle, !live.isEmpty { return live }
        let resolved = spec?.title ?? ""
        return resolved.isEmpty ? "Floating pane" : resolved
    }

    var body: some View {
        card
            .frame(width: liveFrame.width, height: liveFrame.height)
            .position(x: liveFrame.midX, y: liveFrame.midY)
            // Z-ORDER (F4): one `ForEach` mixes tiled + floating leaves, so declaration order alone can't keep
            // floats on top of the dividers / move-handle layers (those are declared AFTER the panes). A tiled
            // leaf sits at the base (0); a float rides above the chrome layers (`SplitContainer` keeps dividers
            // < move < `floatZBase`), and a dragged float pops above its float neighbours.
            .zIndex(zIndex)
    }

    /// The pane's z-index in the `SplitContainer` compositor ZStack. Tiled = base; floating = above the
    /// divider / move-handle layers; a dragged float = one above its float siblings.
    private var zIndex: Double {
        guard isFloating else { return 0 }
        return isInteracting ? SplitContainer.floatZBase + 1 : SplitContainer.floatZBase
    }

    private var card: some View {
        VStack(spacing: 0) {
            // The grab strip collapses to 0 height (and stops drawing / hit-testing) when tiled, so the hosted
            // `PaneContainer` below stays at the SAME structural slot — flipping `isFloating` never remounts it.
            titleBar
                .frame(height: isFloating ? titleBarHeight : 0, alignment: .top)
                .opacity(isFloating ? 1 : 0)
                .clipped()
                .allowsHitTesting(isFloating && !staticMirror)
            Rectangle()
                .fill(Slate.Line.card)
                .frame(height: isFloating ? Slate.Metric.hairline : 0)
                .opacity(isFloating ? 1 : 0)
            PaneContainer(
                store: store,
                paneID: paneID,
                isFocused: isFocused,
                isVisible: isVisible,
                // The content's live size IS the resize signal `PaneContainer`'s scrim keys off — during a
                // corner-resize drag this changes each frame, so the surface shows the calm "resizing" scrim
                // until the committed reflow lands (a move drag / a tiled pane keeps it constant → no scrim).
                size: contentSize,
                staticMirror: staticMirror,
            )
            .id(paneID) // identity hazard: never reuse a hosted surface across panes
        }
        // The card surface / border / shadow / rounded clip are FLOATING-only chrome, gated by opacity (never
        // an `if`, which would restructure the subtree) so the tiled pane reads as the old flush, borderless
        // panel. `radius == 0` when tiled makes the clip a plain rectangle (a visual no-op over the solver rect).
        .background(Slate.Surface.card.opacity(isFloating ? 1 : 0))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Slate.Line.card, lineWidth: Slate.Metric.cardBorderWidth)
                .opacity(isFloating ? 1 : 0),
        )
        .shadow(color: isFloating ? Slate.State.shadow : .clear, radius: isFloating ? 12 : 0, y: isFloating ? 4 : 0)
        .overlay(alignment: .bottomTrailing) {
            resizeHandle
                .opacity(isFloating ? 1 : 0)
                .allowsHitTesting(isFloating && !staticMirror)
        }
    }

    /// The content area below the grab strip + hairline — the size handed to the hosted `PaneContainer`. While
    /// tiled the strip + hairline are 0-height so the content fills the whole leaf. Uses the ordered,
    /// NaN-faithful `CGFloat.maximum` (the house float idiom — never a bare `<`/`>` clamp).
    private var contentSize: CGSize {
        let chrome = isFloating ? titleBarHeight + Slate.Metric.hairline : 0
        return CGSize(
            width: CGFloat.maximum(0, liveFrame.width),
            height: CGFloat.maximum(0, liveFrame.height - chrome),
        )
    }

    // MARK: - Grab strip (move)

    private var titleBar: some View {
        HStack(spacing: Slate.Metric.space2) {
            Text(title)
                .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                .foregroundStyle(Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Slate.Metric.space2)
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
        .padding(.horizontal, Slate.Metric.space2)
        .frame(maxWidth: .infinity)
        .frame(height: titleBarHeight)
        .background(Slate.Surface.element)
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
            .fill(Slate.Text.tertiary)
            .frame(width: resizeGrip, height: resizeGrip)
            .padding(Slate.Metric.space1)
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
