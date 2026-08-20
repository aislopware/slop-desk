// StatusDotView — the SwiftUI renderers of the shared status mark.
//
// WHAT a mark is (``StatusDot``'s geometry, ``StatusMark``'s silhouette set, ``StatusDotStyle``'s
// resolved pair, ``AgentSpinner``'s wandering tempo and ``BrailleCell``'s walk) is `SlopDeskSlate`,
// below both renderers. What is here is one of the two: `SlopDeskMacUI` draws the same values as
// `NSView`s (`MacStatusMarkView`, `MacAgentSpinnerView` — docs/56 stage D), so a state edge cannot
// mean one thing in the rail and another in a hosted card. See `SlateStatusMark.swift` for every
// design note behind the numbers.

#if os(iOS)
import SFSafeSymbols
import SlopDeskSlate
import SwiftUI

/// The mark itself. Only the spinner carries a timeline; every other state is drawn once and holds
/// still. AX-hidden: the row title's accessibility value already speaks the same state, so the mark
/// never double-announces.
///
/// `internal` again, and back on time. It was `package` for ONE caller —
/// `SlopDeskMacUI/RailStatusMarks`, the titlebar band's cluster, which was still hosted SwiftUI —
/// under a comment promising the widening would be collected the moment that cluster became
/// `MacStatusMarkView`s. It did (docs/56 increment 46), so this did too: a widened access level that
/// outlives its caller reads exactly like one that still has it.
///
/// The Mac now draws every one of its marks in AppKit. This is the PHONE's renderer, with one caller
/// (``NavigatorColumn``), and it does not expire — after the Stage D rename this target is the
/// phone's and a SwiftUI mark is what it should have.
struct StatusDotView: View {
    let style: StatusDotStyle

    init(style: StatusDotStyle) { self.style = style }

    var body: some View {
        mark
            // ONE footprint for every mark, so ring rows, spinning rows and symbol rows share the
            // column's centre line.
            .frame(width: StatusDot.footprint, height: StatusDot.footprint)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        if let system = style.mark.systemSymbol {
            // A system symbol at otty's configuration for it — the artwork is Apple's, so this is
            // the EXACT drawing otty mounts rather than a redraw of it.
            Image(systemSymbol: system.symbol)
                .font(.system(size: system.size, weight: StatusDot.symbolWeight))
                .foregroundStyle(style.ink)
        } else {
            switch style.mark {
            case .working:
                // A frozen cell holds at phase 0 — the SAME still Reduce Motion asks for, through
                // the same one parameter, so a disabled slot and an accessibility freeze can never
                // become two different drawings of "not moving".
                AgentSpinnerView(ink: style.ink, pinnedPhase: style.frozen ? 0 : nil)
            case .awaiting:
                VectorIconView(icon: OttyIcon.hand, side: StatusDot.handSide, ink: style.ink)
            default:
                DottedRing()
                    .fill(style.ink)
                    .frame(width: StatusDot.ringDiameter, height: StatusDot.ringDiameter)
            }
        }
    }
}

/// The agent-presence ring: ``StatusDot/ringDotCount`` DOTS spaced evenly round a circle, the first
/// at 12 o'clock. A `Shape` rather than a stack of circles so the ring has one definition every
/// reading of it must share — and so it is a `Path`, which can be filled, hit-tested and scaled
/// like any other.
///
/// ⚠️ It was a DASHED ring until 2026-08-10 (lucide `circle-dashed`, stroked with a 0.6-fill dash
/// pattern), replaced on the user's instruction by dots standing further apart than those dashes did.
/// A dash is a fragment of a line that happens to be curved; a dot is its own shape, and at this size
/// that is the difference between a ring that looks broken and a ring that looks made of parts.
///
/// The dot size scales with the rect, so a magnified still is a true redraw rather than a blown-up
/// 10pt bitmap — the same lesson ``AgentSpinner`` learned about `scaleEffect`. The geometry itself is
/// ``StatusDot/ringDotFrame(_:in:)``'s (docs/56 batch 3), one floor down and shared with the Mac's
/// `MacStatusMarkView.drawRing`; this `Shape` only turns those frames into a `Path`.
struct DottedRing: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<StatusDot.ringDotCount {
            path.addEllipse(in: StatusDot.ringDotFrame(index, in: rect))
        }
        return path
    }
}

/// The THINKING mark, drawn in SwiftUI. Its whole cadence is ``AgentSpinner`` — this view only puts
/// the lit dots where ``BrailleCell/position(of:in:zoom:)`` says and inks them by
/// ``AgentSpinner/lit(_:hole:)``.
///
/// ⚠️ It is PURE SwiftUI, so `ImageRenderer` can rasterize it. The platform indicator could not be
/// rendered at all, which meant the one mark that moved was also the one mark no test could look at.
/// ⚠️ Reduce Motion freezes it — a frozen cell is still a distinct silhouette, so the state is never
/// lost, only the movement.
///
/// `internal` for the same reason ``StatusDotView`` is: the Mac draws its own spinner
/// (`MacAgentSpinnerView`, an `NSView`), so this one's only caller is in this target and its
/// `package` had outlived the cross-target reader it was widened for (docs/56 increment 46).
struct AgentSpinnerView: View {
    /// The lit dots' ink. The hole is this same ink taken down to ``StatusDot/holeFloor``.
    let ink: Color
    /// Multiplies the whole mark — the render rig's way of magnifying it without resampling.
    var zoom: CGFloat = 1
    /// Hold the hole at ONE point of its lap instead of running it. The render rig's only way to
    /// photograph a moving mark (a still of a wall-clock spinner catches an arbitrary moment, so a
    /// filmstrip of pinned phases is what a reviewer can actually read), and `0` is also what Reduce
    /// Motion asks for — one parameter, so the frozen mark a snapshot shows IS the one that ships.
    var pinnedPhase: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where in the shared wander this mount sits, rolled once and held for as long as the view keeps
    /// its identity (``StatusDot/tempoSeedSpan``). Every mark obeys the same tempo law; the seed is
    /// only an offset into it, so two panes are never hurrying and dwelling in step. `@State` rather
    /// than a computed roll because a fresh number on every re-render would make the hole jump, which
    /// is the exact defect the wall-clock phase exists to prevent.
    @State private var seed = Double.random(in: 0..<StatusDot.tempoSeedSpan)

    var body: some View {
        cell
            .frame(width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom)
    }

    @ViewBuilder private var cell: some View {
        if let pinnedPhase {
            dots(phase: pinnedPhase)
        } else if reduceMotion {
            dots(phase: 0)
        } else {
            // `.animation` schedules at the display's own refresh rate, so the hole slides at
            // 60/120 Hz rather than stepping — and the phase stays a pure function of the date.
            TimelineView(.animation) { timeline in
                dots(phase: AgentSpinner.phase(at: timeline.date, seed: seed))
            }
        }
    }

    private func dots(phase: Double) -> some View {
        let hole = phase * Double(BrailleCell.dotCount)
        let side = StatusDot.dotDiameter * zoom
        let box = CGSize(
            width: StatusDot.footprint * zoom, height: StatusDot.footprint * zoom,
        )
        return ZStack {
            ForEach(0..<BrailleCell.dotCount, id: \.self) { index in
                Circle()
                    .fill(ink.opacity(AgentSpinner.lit(index, hole: hole)))
                    .frame(width: side, height: side)
                    .position(BrailleCell.position(of: index, in: box, zoom: zoom))
            }
        }
        .frame(width: box.width, height: box.height)
    }
}

/// The PLATFORM's indeterminate circular progress indicator — the generic "this control is waiting"
/// spinner, in the 14pt box otty lays its own out in. NOT the agent's mark any more (that is
/// ``AgentSpinner``): what is left here is the ordinary busy affordance a button or a list row shows
/// while a request is in flight, where matching every other spinner on the device is the point, so
/// it is the system's `ProgressView` and not a drawing of one.
///
/// ⚠️ Reduce Motion is the PLATFORM's call here — the control makes it, which is half of why a
/// generic wait still uses it.
///
/// The ink is the chrome's own secondary, the same one every other quiet mark in these rows takes:
/// the wheel is furniture around the row's content, never the thing being read.
struct WorkingSpinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .tint(Slate.Text.secondary)
            // The small control is 16pt; otty's box is 14. Scaling the control (rather than clipping
            // a 16pt spinner into a 14pt frame) keeps the fins whole and the column exact.
            .scaleEffect(StatusDot.spinnerSide / StatusDot.smallControlSide)
            .frame(width: StatusDot.spinnerSide, height: StatusDot.spinnerSide)
    }
}
#endif
