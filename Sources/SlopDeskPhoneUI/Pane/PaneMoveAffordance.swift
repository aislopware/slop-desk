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
// what a drawing has to keep: the SwiftUI coordinate space the gesture reports in, the two mounts the
// canvas drag needs — `panePointer(_:)`, which draws nothing here and says on itself why it is still
// a modifier, and `PaneMoveEscapeMonitor`, which hangs a first responder over the canvas because a
// drag holds none of its own — and the DRAWINGS themselves, which is all a view is owed.
//
// The drawings do not own their numbers either. The ghost chip's capsule is ``Slate/DropChip``'s
// (increment 56e) and the grab pill's geometry is ``Slate/GrabPill``'s (stage F batch P6), because
// each of the two is drawn a second time in `SlopDeskMacUI`, which this file cannot see — the chip by
// the cross-window panel, the pill by the satellite window's own strip. A rung spelled on both sides
// of a framework boundary has nothing to compare itself against, so it drifts silently and the two
// drawings of one gesture stop matching. What is left here is which shape goes where.
//
// That list used to be the whole of it and was not: four `static func`s of rect math stayed behind
// on `PaneMoveOverlay` for another increment, because they were members of a `View` and the census
// that emptied this file counted files and import edges. They are `PaneDropGeometry`'s preview half
// now (docs/56 increment 56c), and the rule the miss states is §3's own: the unit is the
// DECLARATION. A `some View` is a view; a `CGRect` returned by a method on one is not.

#if os(iOS)
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

// MARK: - The pointer vocabulary

extension View {
    /// Draw the pointer this chrome asks for while the cursor is over it — which here is nothing at
    /// all, because SwiftUI spells no `PointerStyle` outside macOS.
    ///
    /// It survives being a no-op because the CALL SITES are where the decision is made, not where it
    /// is drawn: `PaneDivider` asks for a resize glyph and the handle below for a grab, both as a
    /// ``PanePointer``, and `MacPaneDivider.cursor(for:)` turns that same value into an `NSCursor`.
    /// Striking the calls here would leave the question asked in one renderer and unasked in the
    /// other, which is how two drawings of one affordance start disagreeing about what is grabbable.
    func panePointer(_: PanePointer) -> some View {
        self
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
    /// Whether THIS leaf is the one currently being dragged — and it is NOT only styling. It is the drag
    /// layer's own answer to "is this handle's move still live", so its withdrawal WHILE the gesture is
    /// still tracking is the cancel arriving as state (see the latch below). It drives the pill's active
    /// ink and the closed-hand cursor as a consequence of that, not the other way round.
    let isDragging: Bool
    /// Live drag callbacks — locations are in the `PaneMoveSpace.name` coordinate space.
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    /// A plain tap on the strip focuses the pane (so the top strip is not a focus dead-zone).
    let onTap: () -> Void
    /// Fires when the gesture ends having COMMITTED NOTHING — a cancel (Escape, with the release
    /// afterwards reporting nothing), or this very handle's view being torn out of the `ForEach` mid-drag
    /// so no release could ever reach it (the pane it belongs to closed while the button was still down).
    ///
    /// It does NOT fire on the success path, and that is the whole point of the name. It used to fire on
    /// EVERY end, because it hung off `dragActive`'s reset alone and that reset is what a normal release
    /// does too — so a callback called "interrupted" ran immediately after every committed drop, and its
    /// caller had to be written to survive being told the drop it had just committed was an interruption.
    /// A predicate that is true on both branches tells its reader nothing; this one is now the branch.
    var onInterrupted: () -> Void = {}

    /// Whether this leaf renders UNTHEMED content (a `.desktop` video stream): the bare
    /// tertiary pill tuned to the terminal palette disappears over an arbitrary — usually light —
    /// streamed desktop, so the pill gains a small `Surface.face` plate (the same chip voice as the
    /// rest of the over-video chrome). Terminal leaves keep the flat pill.
    var contentIsUnthemed: Bool = false

    @State private var hovering = false
    /// `true` for the duration of the gesture. SwiftUI auto-resets `@GestureState` on end/cancel/interrupt,
    /// so an ORDINARY release can never skip the end-cleanup the way a bare `.onEnded` closure can.
    ///
    /// It says nothing whatever about an UNMOUNTED drag, and this comment used to claim that it did — that
    /// the reset covered "this view being removed from its `ForEach` mid-drag", citing `PaneDivider` for a
    /// safety net that file no longer describes that way. The reset is observed through an `.onChange`
    /// that is part of this view, so an unmount DESTROYS the observer instead of firing it. That is why
    /// ``releaseDrag()`` is owed from `.onDisappear` as well, and why the latch below rather than this
    /// flag is what says whether there is anything left to release.
    @GestureState private var dragActive = false

    /// THE ONE LATCH, and both of this handle's guarantees are read off it, because both are the same
    /// sentence said twice: a drag is released EXACTLY ONCE per begin, and after a bail-out it reports
    /// nothing at all.
    ///
    /// The bail-out is what needs a third state rather than a Bool. SwiftUI cannot un-recognise a live
    /// `DragGesture` — there is no `cancel()`, and `.disabled(true)` applied mid-gesture does not retract
    /// a recogniser that is already tracking — so the cancel cannot be spelled "stop the gesture", only
    /// "stop REPORTING it", and that has to hold for every remaining event of the same press. Before this
    /// latch existed, Escape cleared the drag layer's `move` and nothing else: the very next mouse
    /// movement published a fresh `onChanged` that re-armed exactly what had just been cleared, and the
    /// release committed the landing the user had explicitly backed out of. A bail-out that un-bails on a
    /// tremor is worse than no bail-out, because by then the user has stopped watching the screen.
    ///
    /// It is also `PaneDivider`'s `startLead` in this file's terms — the "a begin is outstanding" bit that
    /// makes ``releaseDrag()`` idempotent — and the two were deliberately not kept apart. Two latches
    /// over one gesture would need a rule for every pair of their states, and three of those four pairs
    /// are unreachable; one value with three named cases has no unreachable pairs to reason about.
    /// `MacPaneMoveHandle` reached the same shape from the other side and calls it `Phase` too, minus the
    /// `.pressed` case AppKit needs because it has no `minimumDistance` and no `.onTapGesture`.
    @State private var phase = Phase.idle

    /// Where the gesture is. `.cancelled` is the state neither "dragging" nor "idle" can express: the
    /// button is still down, so the gesture is not over, and nothing more may be reported, so it is not
    /// running either.
    private enum Phase {
        case idle
        case dragging
        /// Escape was pressed (or the drag was interrupted from outside) and the button is still down.
        /// Absorbs every remaining event of the gesture; the release commits nothing.
        case cancelled
    }

    /// ``PaneGrabPill/isRevealed(input:hovering:isDragging:)``'s, not this view's, and the reason is
    /// the reason it was worth moving: this used to read `hovering || isDragging`, with `.onHover` the
    /// only writer of `hovering`, so on a phone the pill was never drawn and the move gesture had no
    /// door. A rule that decides whether a control EXISTS is not ink, and the two AppKit strips ask
    /// the same question from a target this one cannot see.
    private var revealed: Bool {
        PaneGrabPill.isRevealed(input: .touch, hovering: hovering, isDragging: isDragging)
    }

    /// How far the press must travel before it is a MOVE rather than a tap — and it is a FINGER's
    /// slop, not a mouse's. ``PaneGrabPill/minimumDragDistance(_:)`` says why 2pt was the wrong number
    /// on this half: a touch that lands and lifts wanders further than that, so the pointer's value
    /// turned nearly every tap on this strip into a drag and left `onTap` unreachable in exchange.
    private static let dragSlop = PaneGrabPill.minimumDragDistance(.touch)

    var body: some View {
        VStack(spacing: 0) {
            strip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Every number below is ``Slate/GrabPill``'s, and for the reason that file's header states: this
    /// is one affordance with more than one drawing, and the rungs are the only thing keeping them the
    /// same shape once no compiler can see both at once.
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
        // Still mounted, and not vestigially: an iPad with a trackpad keeps the hover GROWTH below,
        // which is feedback rather than discovery. What it no longer decides is whether the pill is
        // there at all — see ``revealed``.
        .onHover { hovering = $0 }
        .panePointer(isDragging ? .grabActive : .grabIdle)
        .gesture(
            DragGesture(minimumDistance: Self.dragSlop, coordinateSpace: .named(PaneMoveSpace.name))
                .updating($dragActive) { _, state, _ in state = true }
                // The begin is the FIRST frame past `minimumDistance` — SwiftUI has no separate began
                // callback — so it is spelled as the one `.idle` → `.dragging` transition, exactly the
                // way `PaneDivider` takes its anchor on the first change. A `.cancelled` gesture must
                // never come back through this door, which is why the transition is written out rather
                // than assigned unconditionally.
                .onChanged { value in
                    switch phase {
                    case .cancelled: return
                    case .idle: phase = .dragging
                    case .dragging: break
                    }
                    onChanged(value.location)
                }
                // The release commits, and BOTH halves of that sentence are conditional on the latch.
                // Suppressing `onChanged` alone would have left this arm free to commit whatever zone
                // the pointer happened to be over at the moment of the bail-out — the whole defect, one
                // event later. A cancelled release reports nothing here and is released by the
                // `dragActive` observer below, which owes it exactly one `onInterrupted` either way.
                .onEnded { value in
                    guard phase == .dragging else { return }
                    // Cleared BEFORE the commit, `PaneDivider`'s rule: `onEnded` can tear this very view
                    // out of the tree (a drop that closes this pane), and the `.onDisappear` that then
                    // fires must find nothing outstanding rather than report a committed drop as an
                    // interruption.
                    phase = .idle
                    onEnded(value.location)
                },
        )
        .onTapGesture { onTap() }
        .animation(Slate.Anim.dividerHover, value: revealed)
        // THE CANCEL, ARRIVING AS STATE RATHER THAN AS AN EVENT. This handle never reads Escape itself
        // and must not: the key is read by the ONE ``PaneMoveEscapeMonitor`` mounted with the move
        // layer, which holds first responder for the length of the drag — and a second grab of first
        // responder per handle would be N of them fighting over one keyboard, with whichever won
        // deciding for every pane. What reaches this view instead is the CONSEQUENCE of the cancel: the
        // drag layer clears its `move`, so `isDragging` — this handle's own input — goes false
        // underneath a gesture that is still tracking. Nothing else can do that mid-press, which is
        // what makes the withdrawal readable as the bail-out rather than as a repaint.
        //
        // `phase == .dragging` is the whole guard, and it is what separates this from a normal end: a
        // release clears the drag layer's `move` too, but only from inside `onEnded`, which has already
        // moved the phase to `.idle` by the time any observer can run. SwiftUI promises nothing about
        // whether that withdrawal lands in the same update as `@GestureState`'s reset or the next one,
        // and this guard does not care — a finished drag can never arm a latch the next one inherits.
        .onChange(of: isDragging) { wasDragging, nowDragging in
            guard wasDragging, !nowDragging, phase == .dragging else { return }
            phase = .cancelled
        }
        // The ordinary release: `@GestureState` resets on an end and on a system cancel alike, so this
        // covers the drag whose handle is still on screen when the button comes up.
        .onChange(of: dragActive) { _, active in
            if !active { releaseDrag() }
        }
        // THE TEARDOWN SAFETY NET, and it is not redundant with the observer above: that observer is
        // part of this view, so an unmount mid-drag destroys it INSTEAD of firing it. The header used to
        // claim the opposite. Every way this handle can vanish under a live drag ends here — the pane it
        // belongs to closes and `leaves` loses its `ForEach` row; the move layer's own
        // `leaves.count > 1 || paneDrag != nil` condition goes false; an evicted tab takes the whole
        // layer, descendants included — and a drag stranded that way leaves `drag.move` non-nil forever,
        // which wedges `.allowsHitTesting(move == nil || …)` on EVERY other handle in the workspace for
        // the rest of the session. Silently: no crash, no log, just pills that stop responding.
        .onDisappear { releaseDrag() }
    }

    /// The drag's end, spelled ONCE because three different events owe it: the gesture ending or
    /// cancelling, a release that arrives after a bail-out, and this view being torn out of the tree
    /// while the button is still down. `phase` is both the latch and the answer — anything but `.idle`
    /// means a begin is outstanding — and clearing it before the callback makes a second arrival in
    /// either order a no-op, so it does not matter which SwiftUI delivers first.
    ///
    /// A committed release never reaches the callback, because `onEnded` set `.idle` itself before
    /// committing: `onInterrupted` says nothing was committed, and it now means it. Nothing else needs
    /// unwinding here — the pill's accent, the closed-hand pointer and the overlay all hang off
    /// `isDragging`, and the Escape monitor arms and disarms off the same `move` the interruption
    /// clears, so one report puts every one of them back.
    private func releaseDrag() {
        guard phase != .idle else { return }
        phase = .idle
        onInterrupted()
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

    /// The in-canvas chip; `MacPaneDragChipPanel` is the same capsule drawn in an `NSPanel`. Every
    /// number below is ``Slate/DropChip``'s, and that is not tidiness — the two drawings sit in
    /// different frameworks now, so the rungs are the only thing left holding them to one shape.
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

// WHY THE CANCEL KEY NEEDS A VIEW AT ALL. A pane-move drag is a plain `DragGesture` and never takes
// keyboard focus — the terminal surface underneath usually still holds it — so `.onKeyPress(.escape)`,
// which ``View/slateCancelKey(perform:)`` wraps and every other cancel on this platform goes through,
// can never be delivered it: it wants a focused view and there is none. So the drag grabs first
// responder of its own for exactly as long as it is in flight, and hands it back on release.
//
// This half used to be a SINK that mounted and did nothing, and docs/56 increment 41 recorded that as
// what it was — a capability the phone was OWED (§3: "layout diverges; capability does not"), since an
// iPad with a hardware keyboard could not bail out of a drag it had started. What it still does not
// know is what cancelling MEANS: the closure comes from the single mount in `SplitContainer`, which is
// the only place that knows what the drag layer holds.
//
// WHAT THE CANCEL DOES NOT DO IS STOP THE GESTURE, and that gap was the defect. The monitor cannot
// reach the `DragGesture` on the handle: the closure the mount supplies clears the drag layer's
// `move` and there SwiftUI's story ends, because a live gesture cannot be un-recognised — there is
// no `cancel()` on one, and `.disabled(true)` does not retract a recogniser that is already tracking.
// So Escape used to clear state that the very next movement refilled, and the eventual release
// committed the landing the user had bailed out of. The handle closes that itself, off the signal it
// already has: ``PaneMoveHandle/isDragging`` going false underneath a gesture that is still tracking
// IS the cancel, and it latches the gesture inert until the press comes up. This type reads the key;
// the handle reads the consequence.

/// A zero-sized `UIPress` responder that holds first responder for exactly as long as the drag is in
/// flight — mounted unconditionally, armed by `isActive`.
///
/// A MOUNT rather than a mechanism: the responder itself is ``PaneMoveEscapeResponder``, and its
/// header carries the two things this shape has to answer for — what arms the grab, and what the
/// keyboard is handed back to when it lets go.
struct PaneMoveEscapeMonitor: View {
    var isActive: Bool
    var onCancel: () -> Void

    var body: some View {
        PaneMoveEscapeResponder(isActive: isActive, onCancel: onCancel)
            // Zero-sized and touch-transparent, the zero-sized-host way: the drag's own
            // touches belong to the grab handle and the canvas, and a responder that took one would
            // be cancelling the gesture it exists to rescue.
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}
#endif
