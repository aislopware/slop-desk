// PaneMoveAffordance — the "grab the pane and move it" affordance.
//
// A short drag handle (a `-` pill) is revealed near the TOP of a pane on hover; you grab it to move the
// pane. Adapted to the remote-app rule: the drag mutates NOTHING in the store — it only
// updates a view-local `PaneMoveDrag` that drives an overlay. Only on release does `SplitContainer` commit
// exactly ONE store op, so the layout / terminal-grid / remote-window redraw fires once, not per drag frame.
//
// The drop is not just a swap. The cursor's position over the canvas resolves to a `PaneDropZone`:
//   • CENTER of a target pane  → SWAP the two panes (the original behaviour).
//   • an EDGE band of a target  → RE-SPLIT: the dragged pane becomes a new column (left/right) or row
//     (top/bottom) beside the target — dropping a side-by-side pair on each other's TOP/BOTTOM edge turns
//     the side-by-side (`.horizontal`) split into a stacked (`.vertical`) one — the re-orientation between
//     side-by-side and stacked layout the user asked for.
//   • the CONTAINER's outer gutter → DOCK: the pane becomes a full-span column/row on that whole edge.
// Each zone draws a visually distinct preview so the committed action reads before release.
//
// Hit-test footprint: the handle view fills its leaf but only a SHORT top strip is hit-testable (a `Spacer`
// fills the rest and passes clicks through to the terminal below it in the ZStack). The strip senses hover
// (to reveal the pill) and owns the drag gesture. SYSTEM / design-token colours only.
//
// The drag block's shared VALUE vocabulary is no longer here. `PaneDropZone`, `PaneMoveDrag`,
// `PaneDropMetrics`, `PaneDropGeometry` and `PanePointer` are `SlopDeskClientCore`'s — none of them
// names a view, and each is asked by surfaces in two targets (docs/56 §3). What this file keeps is
// what a drawing has to keep: the SwiftUI coordinate space the gesture reports in, the two things the
// canvas drag needs a platform for — `panePointer(_:)` (there is no `PointerStyle` on iOS at all) and
// `PaneMoveEscapeMonitor` (a drag holds no first responder, so reading its cancel key is a local
// `NSEvent` monitor on the Mac and a first responder over the canvas on the phone — one behaviour,
// two mechanisms) — and the DRAWINGS themselves, which is all a view is owed.
//
// The drawings do not own their numbers either. The ghost chip's capsule is ``Slate/DropChip``'s
// (increment 56e) and the grab pill's geometry is ``Slate/GrabPill``'s (stage F batch P6), because
// each of the two is drawn a second time somewhere this file cannot reach — the chip by the
// cross-window `NSPanel`, the pill by the satellite window's own strip — and in both cases the two
// drawings are compared by a user inside a SINGLE drag. What is left here is which shape goes where.
//
// `PaneMoveEscapeMonitor` is a MOUNT now and nothing else. The Mac's monitor itself — an
// `NSEvent.addLocalMonitorForEvents` install/remove pair and the FFI call that names the cancel key —
// was a `Coordinator` on a representable whose `makeNSView` returned a bare `NSView()`, i.e. a
// lifetime SwiftUI had no other place to hang. It is `SlopDeskClientCore`'s
// ``PaneMoveEscapeMonitorController`` now, by increment 54's ruling on this file's twin: a `CGEvent`
// tap draws nothing, so the direction was never up — and neither does an `NSEvent` monitor. What is
// left here is the arm/disarm the AppKit canvas will do with no view at all.
//
// That list used to be the whole of it and was not: four `static func`s of rect math stayed behind
// on `PaneMoveOverlay` for another increment, because they were members of a `View` and the census
// that emptied this file counted files and import edges. They are `PaneDropGeometry`'s preview half
// now (docs/56 increment 56c), and the rule the miss states is §3's own: the unit is the
// DECLARATION. A `some View` is a view; a `CGRect` returned by a method on one is not.

#if canImport(SwiftUI)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

/// The shared coordinate space the move gesture reports its location in — `SplitContainer` names its
/// compositor ZStack with this so a gesture location lines up 1:1 with the solver's leaf rects.
enum PaneMoveSpace {
    static let name = "slopdesk.splitspace"
}

// MARK: - The pointer vocabulary, drawn once

extension View {
    /// Draw `pointer` while the cursor is over this view — and nothing at all where there is no
    /// cursor to draw for.
    ///
    /// The truth-at-the-clamp rule lives HERE rather than at the seams: a seam that can still move
    /// both ways and a DEAD seam that can move neither both keep the two-way glyph. There is no
    /// "cannot resize" pointer, and a plain arrow over a seam reads as a dead zone rather than as a
    /// seam sitting on its floor.
    func panePointer(_ pointer: PanePointer) -> some View {
        #if os(macOS)
        // Flat on purpose: the specific direction pairs first, then the bare case as the two-way
        // fallback for (true, true) and (false, false) alike.
        let style: PointerStyle =
            switch pointer {
            case .grabIdle: .grabIdle
            case .grabActive: .grabActive
            case .columnResize(toLeading: true, toTrailing: false): .columnResize(directions: .leading)
            case .columnResize(toLeading: false, toTrailing: true): .columnResize(directions: .trailing)
            case .columnResize: .columnResize
            case .rowResize(toUp: true, toDown: false): .rowResize(directions: .up)
            case .rowResize(toUp: false, toDown: true): .rowResize(directions: .down)
            case .rowResize: .rowResize
            }
        return pointerStyle(style)
        #else
        return self
        #endif
    }
}

// The `PaneDropRegister.Mark` → `SFSymbol` table used to sit here. It is `Slate/PaneDropChipArt.swift`
// now (increment 56e): the cross-window capsule it also fed became AppKit, so a table that could stay in
// one renderer while both chips were SwiftUI would have had to be spelled twice the moment one of them
// was not. See that file for why the floor is the right home rather than either half.

/// The per-leaf top grab handle. Reveals a `-` pill on hover; the drag reports its live cursor location to
/// `SplitContainer` (which resolves the zone + commits on `.onEnded`).
struct PaneMoveHandle: View {
    /// This leaf's on-screen size (the handle fills it; only the top strip is interactive).
    let leafSize: CGSize
    /// Whether THIS leaf is the one currently being dragged (drives the pill's active styling + cursor).
    let isDragging: Bool
    /// Live drag callbacks — locations are in the `PaneMoveSpace.name` coordinate space.
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    /// A plain tap on the strip focuses the pane (so the top strip is not a focus dead-zone).
    let onTap: () -> Void
    /// Fires when the gesture goes inactive WITHOUT `onEnded` having run — a cancel, a system interrupt,
    /// or this very handle's view being torn out of the `ForEach` mid-drag (the pane it belongs to closed
    /// while the mouse button was still down). Safe to treat as idempotent: on a normal release both this
    /// and `onEnded` fire, but `onEnded`'s commit reads its own captured location, not caller state, so
    /// this running first (or twice) never drops or reorders the commit.
    var onInterrupted: () -> Void = {}

    /// Whether this leaf renders UNTHEMED content (a `.desktop` video stream): the bare
    /// tertiary pill tuned to the terminal palette disappears over an arbitrary — usually light —
    /// streamed desktop, so the pill gains a small `Surface.face` plate (the same chip voice as the
    /// rest of the over-video chrome). Terminal leaves keep the flat pill.
    var contentIsUnthemed: Bool = false

    @State private var hovering = false
    /// `true` for the duration of the gesture. SwiftUI auto-resets `@GestureState` on end/cancel/interrupt
    /// — including this view being removed from its `ForEach` mid-drag — so `onInterrupted` can NEVER be
    /// skipped the way a bare `.onEnded` closure can (see `PaneDivider`'s identical safety net).
    @GestureState private var dragActive = false

    private var revealed: Bool { hovering || isDragging }

    var body: some View {
        VStack(spacing: 0) {
            strip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Every number below is ``Slate/GrabPill``'s, and for the reason that file's header states: the
    /// satellite window's strip draws the SAME pill, and the drag that starts on it ends on this one.
    /// A user crossing back from a detached window compares the two inside one gesture.
    private var strip: some View {
        ZStack {
            // Over a video stream the pill sits on a small opaque plate — tertiary-on-anything is
            // otherwise invisible on a light streamed desktop. The plate carries the hairline +
            // shadow (chip voice); the pill itself keeps the exact terminal styling.
            if contentIsUnthemed {
                Capsule(style: .continuous)
                    .fill(Slate.Surface.face)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Slate.Line.subtle, lineWidth: Slate.Metric.hairline),
                    )
                    .frame(width: Slate.GrabPill.plateWidth, height: Slate.GrabPill.plateHeight)
                    .slateShadow(.chip)
                    .opacity(revealed ? 1 : 0)
                    .scaleEffect(hovering && !isDragging ? Slate.GrabPill.hoverScale : 1)
            }
            Capsule()
                .fill(isDragging ? Slate.State.accent : Slate.Text.tertiary)
                .frame(width: Slate.GrabPill.barWidth, height: Slate.GrabPill.barHeight)
                .opacity(revealed ? 1 : 0)
                .scaleEffect(hovering && !isDragging ? Slate.GrabPill.hoverScale : 1)
        }
        .frame(
            width: Slate.GrabPill.stripWidth(forLeafWidth: leafSize.width),
            height: Slate.GrabPill.stripHeight,
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .panePointer(isDragging ? .grabActive : .grabIdle)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named(PaneMoveSpace.name))
                .updating($dragActive) { _, state, _ in state = true }
                .onChanged { onChanged($0.location) }
                .onEnded { onEnded($0.location) },
        )
        .onTapGesture { onTap() }
        .animation(Slate.Anim.dividerHover, value: revealed)
        // Fires on end AND on a cancel/teardown (`dragActive` resets either way) — the safety net a
        // bare `.onEnded` cannot provide.
        .onChange(of: dragActive) { wasActive, active in
            if wasActive, !active { onInterrupted() }
        }
    }
}

/// The drag overlay drawn ABOVE the panes while a move is in flight: a zone-specific drop preview, the
/// dashed "lifted" outline on the source, and a ghost chip pinned to the cursor. Purely visual
/// (`allowsHitTesting(false)` at the call site).
struct PaneMoveOverlay: View {
    let drag: PaneMoveDrag
    /// Leaf rects (solver space == `PaneMoveSpace.name`), keyed by pane.
    let frames: [PaneID: CGRect]
    /// The whole compositor bound — the DOCK rail spans its edges.
    let container: CGRect
    /// The dragged pane's title for the ghost chip (falls back to a generic label).
    let sourceTitle: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            zonePreview
            sourceOutline
            ghostChip
                .position(x: drag.location.x, y: drag.location.y)
        }
    }

    // MARK: Zone-specific drop preview

    /// A distinct identity per resolved zone (incl. each re-split EDGE) so a zone change CROSS-FADES rather
    /// than interpolating the half-pane slab's frame across the pane — animating the slab's frame across
    /// edges would sweep a big rectangle around the pane, which reads as heavy; a quick opacity snap stays
    /// out of the way.
    private var zoneKey: String {
        switch drag.zone {
        case .none: "none"
        case let .swap(target): "swap-\(target)"
        case let .resplit(target, edge): "resplit-\(target)-\(edge.rawValue)"
        case let .dock(edge): "dock-\(edge.rawValue)"
        }
    }

    private var zonePreview: some View {
        zoneShape
            .id(zoneKey)
            .transition(.opacity)
    }

    @ViewBuilder
    private var zoneShape: some View {
        switch drag.zone {
        case .none:
            EmptyView()
        case let .swap(target):
            if let rect = frames[target] { Self.washPreview(rect) }
        case let .resplit(target, edge):
            if let rect = frames[target] { Self.slabPreview(in: rect, edge: edge) }
        case let .dock(edge):
            Self.railPreview(in: container, edge: edge)
        }
    }

    // The three zone previews are `static` — kept callable from outside the drag gesture so any
    // future drop overlay draws the SAME visual language (one drop vocabulary).

    /// SWAP / whole-area wash: a wash + border over the WHOLE rect — "this entire area".
    static func washPreview(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
            .fill(Slate.State.accentMuted)
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(Slate.State.accent, lineWidth: 2),
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    /// RE-SPLIT: an accent SLAB over the drop-side HALF of the target, with a bright seam line on the inner
    /// boundary where the new divider lands — the user literally sees a column vs a row form.
    static func slabPreview(in rect: CGRect, edge: PaneDropEdge) -> some View {
        let slab = PaneDropGeometry.slabRect(in: rect, edge: edge)
        let seam = PaneDropGeometry.seamSize(slab, edge: edge)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                .fill(Slate.State.accentMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                        .strokeBorder(Slate.State.accent.opacity(0.7), lineWidth: 1.5),
                )
                .frame(width: slab.width, height: slab.height)
                .position(x: slab.midX, y: slab.midY)
            // The seam: an accent bar on the slab's INNER edge (the would-be new divider).
            Capsule()
                .fill(Slate.State.accent)
                .frame(width: seam.width, height: seam.height)
                .position(PaneDropGeometry.seamCenter(slab, edge: edge))
        }
    }

    /// DOCK: a full-length accent RAIL pinned to the whole container edge — "full span, tab-wide", visually
    /// distinct from the per-pane half-slab.
    static func railPreview(in container: CGRect, edge: PaneDropEdge) -> some View {
        let rail = PaneDropGeometry.railRect(in: container, edge: edge)
        return RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
            .fill(Slate.State.accentMuted)
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(Slate.State.accent, lineWidth: 2),
            )
            .frame(width: rail.width, height: rail.height)
            .position(x: rail.midX, y: rail.midY)
    }

    // MARK: Source + cursor chrome

    private var sourceOutline: some View {
        Group {
            if let rect = frames[drag.source] {
                RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                    .strokeBorder(
                        Slate.State.accent.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]),
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// The in-canvas twin of ``MacPaneDragChipPanel``'s capsule. Every number below is
    /// ``Slate/DropChip``'s, and that is not tidiness — both chips can be on screen in one drag (this one
    /// while the cursor is over the canvas, the panel's the moment it leaves), so a user can compare
    /// them directly and any drift reads as a glitch.
    private var ghostChip: some View {
        HStack(spacing: Slate.DropChip.glyphGap) {
            Image(systemSymbol: PaneDropRegister.mark(for: drag.zone).symbol)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            Text(PaneDropRegister.label(for: drag.zone, title: sourceTitle))
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(drag.zone == .none ? Slate.Text.tertiary : Slate.Text.primary)
        .padding(.horizontal, Slate.DropChip.padH)
        .padding(.vertical, Slate.DropChip.padV)
        .background(
            Capsule(style: .continuous)
                .fill(Slate.Surface.face)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            drag.zone == .none
                                ? Slate.Text.tertiary.opacity(Slate.DropChip.cancelRim)
                                : Slate.State.accent,
                            lineWidth: Slate.Metric.hairline,
                        ),
                ),
        )
        .slateShadow(.ghost)
        .fixedSize()
    }

    // The RECTS these previews are drawn at are ``PaneDropGeometry``'s, not this view's. They were
    // four `static func`s here, under a banner that already called them "pure rect math", and they
    // survived docs/56 increment 54's sweep only because that sweep counted IMPORT EDGES: a method
    // on a `View` is not a view, but nothing that is not one can reach it. The resolver that decides
    // WHICH zone a point is in already lived below; the arithmetic that turns that answer back into
    // a rectangle now does too, so the preview cannot promise a shape the commit does not make.
    //
    // The chip's WORDING and its MARK are ``PaneDropRegister``'s, not this view's — the cross-window
    // panel says the same things in the same voice, and the two were spelled separately until the
    // register was minted. `ghostChip` above asks it directly; there is nothing left to state here.
}

// MARK: - Escape-to-cancel

// ⚠️ THE GATE ROUND THIS TYPE IS THE WHOLE GATE — the mount in `SplitContainer` carries none. The
// fact is one fact (a pane-move drag holds no first responder, so its cancel key has to be read by
// something other than a focused view), and it was spelled twice: here, and again around the
// `PaneMoveEscapeMonitor(...)` in the move layer. Two spellings of one fact is two places to fix
// when it changes and one place for it to drift, so the gate stays here and the mount stays plain.
//
// BOTH HALVES ARE REAL, and they run the same cancel: the Mac installs a local `NSEvent` monitor,
// the phone takes first responder for the length of the drag (``PaneMoveEscapeResponder``). The
// phone's half used to be a SINK that mounted and did nothing, and docs/56 increment 41 recorded
// that as what it was — a capability the phone was OWED (§3: "layout diverges; capability does
// not"), since an iPad with a hardware keyboard could not bail out of a drag it had started. What
// makes the two halves one implementation rather than two is the closure: neither knows what
// cancelling means, and the single mount in `SplitContainer` supplies it.
//
// THE MAC'S HALF IS NO LONGER THE MECHANISM, only its mount. The monitor descended to
// ``PaneMoveEscapeMonitorController`` — an `NSEvent` monitor draws nothing, and a representable whose
// `makeNSView` returns a bare `NSView()` is SwiftUI owning a LIFETIME, not a drawing (docs/56
// increment 54's ruling on `SystemKeyCaptureController`, applied to its twin). The phone's half stays
// a real view because ITS mechanism genuinely is one: a `UIView` that becomes first responder.

#if os(macOS)
import AppKit

/// The Mac's half, and it is a MOUNT rather than a mechanism: `SlopDeskClientCore`'s
/// ``PaneMoveEscapeMonitorController`` owns the local `.keyDown` monitor, the cancel key's number and the
/// install/remove balance, and this type exists only because SwiftUI has no way to give a non-drawing a
/// lifetime except by hanging it on a view. The `NSView` is empty on purpose — nothing here draws, and the
/// AppKit canvas will arm the same controller with no view at all.
///
/// Why a monitor is the mechanism in the first place: the drag is a plain `DragGesture` and never takes
/// keyboard focus (the terminal surface underneath usually still holds it), so `.onExitCommand` /
/// `.onKeyPress(.escape)` — the idiom `ViModeOverlay`/`HintModeOverlay` use for THEIR cancel key — can never
/// be delivered it. The controller's header carries the rest.
struct PaneMoveEscapeMonitor: NSViewRepresentable {
    var isActive: Bool
    var onCancel: () -> Void

    func makeCoordinator() -> PaneMoveEscapeMonitorController { PaneMoveEscapeMonitorController() }

    func makeNSView(context: Context) -> NSView {
        sync(context.coordinator)
        return NSView()
    }

    func updateNSView(_: NSView, context: Context) {
        sync(context.coordinator)
    }

    static func dismantleNSView(_: NSView, coordinator: PaneMoveEscapeMonitorController) {
        // The move layer is conditional in `SplitContainer`, so this can run WHILE the monitor is armed —
        // the drag closed its own pane. Disarming here is the half of the balance SwiftUI owns, and a
        // monitor that outlived it would swallow Escape for the whole app with nothing left to remove it.
        coordinator.disarm()
    }

    /// The whole body of this type: armed while a drag is in flight, disarmed the moment it is not. Runs on
    /// every drag FRAME, which is why the controller's `arm` is idempotent on the monitor and rebinding on
    /// the closure rather than the other way round.
    private func sync(_ monitor: PaneMoveEscapeMonitorController) {
        if isActive { monitor.arm(onCancel: onCancel) } else { monitor.disarm() }
    }
}

#else

/// The phone's half: a zero-sized `UIPress` responder that holds first responder for exactly as
/// long as the drag is in flight.
///
/// Same arming rule, same cancel closure, same "mounted unconditionally, armed by `isActive`"
/// lifetime as the Mac's half above. The mechanism differs because it must: UIKit has no local
/// event monitor, and `.onKeyPress(.escape)` — ``View/slateCancelKey(perform:)``'s phone half, which
/// every other cancel on this platform uses — wants keyboard focus, which is precisely what a
/// pane-move drag never takes. ``PaneMoveEscapeResponder`` is where that lives, and its header
/// carries the two things this shape has to answer for: what arms the grab, and what the keyboard
/// is handed back to.
struct PaneMoveEscapeMonitor: View {
    var isActive: Bool
    var onCancel: () -> Void

    var body: some View {
        PaneMoveEscapeResponder(isActive: isActive, onCancel: onCancel)
            // Zero-sized and touch-transparent, the ``KeybindingCaptureHost`` way: the drag's own
            // touches belong to the grab handle and the canvas, and a responder that took one would
            // be cancelling the gesture it exists to rescue.
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}
#endif
#endif
