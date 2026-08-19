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
// two mechanisms) — and the ONE place a `PaneDropRegister.Mark` becomes artwork, which both of this
// module's drop chips read so neither can grow a glyph table of its own.

#if canImport(SwiftUI)
import CSlopDeskFFI
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

// MARK: - The one place a drop MARK becomes artwork

extension PaneDropRegister.Mark {
    /// The SF Symbol this module draws for a drop mark. `SFSafeSymbols` is a dependency of this target
    /// and of `SlopDeskSlate`, deliberately not of `SlopDeskClientCore` — the register answers in
    /// outcomes and each renderer names its own artwork. Both of this module's drop chips (the canvas
    /// overlay's ghost chip below, and ``PaneDragChipPanel``'s cross-window capsule) come through here,
    /// so a new mark cannot reach one of them and miss the other.
    var symbol: SFSymbol {
        switch self {
        case .cancel: .xmark
        case .swap: .rectangle2Swap
        case .splitColumns: .rectangleSplit2x1
        case .splitRows: .rectangleSplit1x2
        case .beside: .rectangleStack
        case .newTab: .plusSquareOnSquare
        case .newWindow: .macwindow
        }
    }
}

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

    /// The grab strip is centred + width-limited so it covers minimal terminal real estate and never
    /// overlaps the side dividers. Short panes get a proportionally smaller strip.
    private var stripWidth: CGFloat { Double.minimum(160, Double.maximum(56, Double(leafSize.width) * 0.4)) }
    /// 14pt strip flush to the leaf's top edge → the pill's centre sits 7pt in, INSIDE the pane's
    /// top padding band. A 3pt inset + 22pt strip would put the pill at ~14pt — over the first line
    /// of terminal text, where it overlaps the pane's content.
    private let stripHeight: CGFloat = 14

    private var revealed: Bool { hovering || isDragging }

    var body: some View {
        VStack(spacing: 0) {
            strip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

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
                    .frame(width: 44, height: 10)
                    .slateShadow(.chip)
                    .opacity(revealed ? 1 : 0)
                    .scaleEffect(hovering && !isDragging ? 1.15 : 1)
            }
            Capsule()
                .fill(isDragging ? Slate.State.accent : Slate.Text.tertiary)
                .frame(width: 30, height: 4)
                .opacity(revealed ? 1 : 0)
                .scaleEffect(hovering && !isDragging ? 1.15 : 1)
        }
        .frame(width: stripWidth, height: stripHeight)
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
        let slab = Self.slabRect(in: rect, edge: edge)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                .fill(Slate.State.accentMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: Slate.Metric.radiusCard)
                        .strokeBorder(Slate.State.accent.opacity(0.7), lineWidth: 1.5),
                )
                .frame(width: slab.width, height: slab.height)
                .position(x: slab.midX, y: slab.midY)
            // The seam: a 3pt accent bar on the slab's INNER edge (the would-be new divider).
            Capsule()
                .fill(Slate.State.accent)
                .frame(width: Self.seamSize(slab, edge: edge).width, height: Self.seamSize(slab, edge: edge).height)
                .position(Self.seamCenter(slab, edge: edge))
        }
    }

    /// DOCK: a full-length accent RAIL pinned to the whole container edge — "full span, tab-wide", visually
    /// distinct from the per-pane half-slab.
    static func railPreview(in container: CGRect, edge: PaneDropEdge) -> some View {
        let rail = Self.railRect(in: container, edge: edge)
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

    private var ghostChip: some View {
        HStack(spacing: 6) {
            Image(systemSymbol: PaneDropRegister.mark(for: drag.zone).symbol)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
            Text(PaneDropRegister.label(for: drag.zone, title: sourceTitle))
                .font(.system(size: Slate.Typeface.base, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(drag.zone == .none ? Slate.Text.tertiary : Slate.Text.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Slate.Surface.face)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            drag.zone == .none ? Slate.Text.tertiary.opacity(0.4) : Slate.State.accent,
                            lineWidth: 1,
                        ),
                ),
        )
        .slateShadow(.ghost)
        .fixedSize()
    }

    // MARK: Geometry helpers (pure rect math)

    /// The drop-side HALF of `rect` for the re-split slab.
    static func slabRect(in rect: CGRect, edge: PaneDropEdge) -> CGRect {
        switch edge {
        case .left:
            CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right:
            CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top:
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom:
            CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }

    /// The seam bar's size — a thin bar along the slab's INNER edge (cross-axis full length).
    static func seamSize(_ slab: CGRect, edge: PaneDropEdge) -> CGSize {
        switch edge {
        case .left,
             .right:
            CGSize(width: 3, height: slab.height)
        case .top,
             .bottom:
            CGSize(width: slab.width, height: 3)
        }
    }

    /// The seam bar's centre — on the slab's inner boundary (the side facing the rest of the target).
    static func seamCenter(_ slab: CGRect, edge: PaneDropEdge) -> CGPoint {
        switch edge {
        case .left:
            CGPoint(x: slab.maxX, y: slab.midY)
        case .right:
            CGPoint(x: slab.minX, y: slab.midY)
        case .top:
            CGPoint(x: slab.midX, y: slab.maxY)
        case .bottom:
            CGPoint(x: slab.midX, y: slab.minY)
        }
    }

    /// The dock rail band along the whole container edge.
    static func railRect(in container: CGRect, edge: PaneDropEdge) -> CGRect {
        let thickness = Double.minimum(48, Double.minimum(Double(container.width), Double(container.height)) * 0.12)
        let t = CGFloat(thickness)
        switch edge {
        case .left:
            return CGRect(x: container.minX, y: container.minY, width: t, height: container.height)
        case .right:
            return CGRect(x: container.maxX - t, y: container.minY, width: t, height: container.height)
        case .top:
            return CGRect(x: container.minX, y: container.minY, width: container.width, height: t)
        case .bottom:
            return CGRect(x: container.minX, y: container.maxY - t, width: container.width, height: t)
        }
    }

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

#if os(macOS)
import AppKit

/// Escape-to-cancel for an in-flight pane-move drag. The drag is a plain `DragGesture` — it never takes
/// keyboard focus (the terminal surface underneath usually still holds it), so `.onExitCommand` /
/// `.onKeyPress(.escape)` (the idiom `ViModeOverlay`/`HintModeOverlay` use for THEIR cancel key) can
/// never reach it. Mirrors `KeybindingsEditorView`'s recorder monitor instead: a scoped `.keyDown` local
/// monitor installed only while the drag is live, so Escape cancels regardless of first-responder state
/// and the monitor never lingers to swallow a key once the drag ends.
struct PaneMoveEscapeMonitor: NSViewRepresentable {
    var isActive: Bool
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.onCancel = onCancel
        context.coordinator.isActive = isActive
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onCancel = onCancel
        context.coordinator.isActive = isActive
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator {
        var onCancel: () -> Void = {}
        private var monitor: Any?

        var isActive: Bool = false {
            didSet {
                guard isActive != oldValue else { return }
                if isActive { install() } else { teardown() }
            }
        }

        private func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // The cancel key is named by the crate that already has to know its number.
                guard slopdesk_key_capture_is_escape(event.keyCode) else { return event }
                onCancel()
                return nil // swallow — Escape cancels the drag, never types into the focused pane
            }
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
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
