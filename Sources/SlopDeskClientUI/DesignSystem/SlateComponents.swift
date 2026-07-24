// SlateComponents — the reusable chrome component kit on the token layer.
//
// Small, composable pieces factored out of the chrome so every surface stays consistent and new views are
// quick to assemble: a status dot, the one-shape `StatusRing` instrument, a key/value row, a pill/badge,
// and an `.slateCard()` surface modifier.
// All built on `Slate.*` tokens + `SlateTheme`. See also SlateControls (`SlatePlateButton`), SlateRow
// (`SlateListRow` / `SlateSectionHeader`) and SlateMonogram (the host-identity plate).

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// A small status dot. State changes are a HARD CUT by design (MERIDIAN L3: a dot never glows, pops or
/// pulses on a state flip — animation is reserved for sustained "live" signals, of which there are none
/// at rest). Don't reach for a Pow `changeEffect` here — none exist in the design system and a state
/// flip must stay a hard cut.
struct SlateStatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// The ONE-SHAPE status instrument: every lifecycle state renders as a READING of the SAME circle —
/// Ø12, fixed centre in a 16pt box — so a state edge reads as one gauge changing its reading, never an
/// icon swap (different silhouettes trading places in one box read as a jump even though the box never
/// moves). Hue + fill + stroke style carry the state; the silhouette never changes:
///   • `resting`  → muted plain ring (at rest, no colour spent);
///   • `working`  → the DASHED ring (8 segments) with one lead segment ticking forward in discrete
///                  steps — a mechanical escapement, not a smooth spinner;
///   • `awaiting` → solid ring + filled centre dot, plus ONE stepped halo pulse per cycle (act-now);
///   • `done`     → the small FILLED circle (the quiet unread-finish dot — same family, full fill);
///   • `error`    → solid ring + inner cross (broken, static — it waits on you).
/// All motion rides the WALL CLOCK on stepped `TimelineView` schedules — a rail re-render can't reset
/// the phase, and frames advance in discrete steps (never an eased "breathing" pulse). Pure SwiftUI;
/// no video/capture (hang-safety #6).
struct StatusRing: View {
    enum Reading: Equatable {
        case resting
        case working
        case awaiting
        case done
        case error
    }

    let reading: Reading
    let tint: Color

    /// The shared geometry — one registration for every reading, so transitions can't jump.
    private static let box: CGFloat = 16
    private static let diameter: CGFloat = 12
    private static let stroke: CGFloat = 1.5
    private static let mutedStroke: CGFloat = 1.2
    /// The done fill — the quiet finish dot's established size.
    private static let doneDiameter: CGFloat = 7
    /// Seconds per escapement step (8 segments ⇒ one full revolution every 1.6s).
    private static let workingBeat: Double = 0.2
    /// Seconds per awaiting halo cycle: the pulse spends the first half stepping outward, then holds
    /// invisible — one front-loaded "pulse of life" per cycle, not a continuous halo.
    private static let haloPeriod: Double = 2.0

    var body: some View {
        ZStack {
            switch reading {
            case .resting: mutedRing
            case .working: workingRing
            case .awaiting: awaitingRing
            case .done:
                Circle().fill(tint)
                    .frame(width: Self.doneDiameter, height: Self.doneDiameter)
            case .error:
                solidRing
                crossMark
            }
        }
        .frame(width: Self.box, height: Self.box)
    }

    private var solidRing: some View {
        Circle()
            .stroke(tint, lineWidth: Self.stroke)
            .frame(width: Self.diameter, height: Self.diameter)
    }

    private var mutedRing: some View {
        Circle()
            .stroke(tint, lineWidth: Self.mutedStroke)
            .frame(width: Self.diameter, height: Self.diameter)
    }

    /// The dashed working ring: 8 fixed segments; the LEAD segment renders at full strength and advances
    /// one slot per beat off the wall clock — motion by discrete step, no rotation tween, so the ring
    /// reads as a ticking mechanism and a re-mount lands mid-cycle instead of restarting it.
    private var workingRing: some View {
        TimelineView(.periodic(from: .now, by: Self.workingBeat)) { timeline in
            let lead = Int(timeline.date.timeIntervalSinceReferenceDate / Self.workingBeat) % 8
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    segment(index)
                        .stroke(
                            tint.opacity(index == lead ? 1 : 0.35),
                            style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round),
                        )
                }
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .rotationEffect(.degrees(-90)) // segment 0 starts at 12 o'clock
        }
    }

    /// One of the 8 dashed-ring segments — a trimmed circle slice with a small fixed gap on each side.
    private func segment(_ index: Int) -> some Shape {
        let slice = 1.0 / 8.0
        let gap = 0.018
        return Circle().trim(from: Double(index) * slice + gap, to: Double(index + 1) * slice - gap)
    }

    /// The awaiting reading: the solid ring + centre dot at rest, with one halo pulse per cycle that
    /// expands in 8 DISCRETE steps across the first half of the cycle and holds invisible for the rest.
    /// The halo peaks at the box edge, so it never bleeds into the neighbouring column.
    private var awaitingRing: some View {
        TimelineView(.periodic(from: .now, by: Self.haloPeriod / 16)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.haloPeriod) / Self.haloPeriod
            ZStack {
                if phase < 0.5 {
                    // Quantized 0…7/8 ramp — each frame is a hard step (no easing between them). The
                    // 0.24 gain caps the peak at ×1.21: the halo's stroked outer edge (13.2pt × 1.21 ≈
                    // 16pt) reaches exactly the box, never past it.
                    let step = (phase * 16).rounded(.down) / 8
                    Circle()
                        .stroke(tint, lineWidth: Self.mutedStroke)
                        .frame(width: Self.diameter, height: Self.diameter)
                        .scaleEffect(1 + step * 0.24)
                        .opacity(0.5 - 0.5 * step)
                }
                solidRing
                Circle().fill(tint).frame(width: 5, height: 5)
            }
        }
    }

    /// The inner cross of the `error` reading — drawn in the ring's own 16pt space so its optical centre
    /// matches every other reading's.
    private var crossMark: some View {
        Path { path in
            path.move(to: CGPoint(x: 6.2, y: 6.2))
            path.addLine(to: CGPoint(x: 9.8, y: 9.8))
            path.move(to: CGPoint(x: 9.8, y: 6.2))
            path.addLine(to: CGPoint(x: 6.2, y: 9.8))
        }
        .stroke(tint, style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
        .frame(width: Self.box, height: Self.box)
    }
}

/// A compact label/value row: a secondary label on the left, a trailing primary value.
struct SlateKeyValueRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Slate.Metric.space2) {
            Text(label)
                .foregroundStyle(Slate.Text.secondary)
            Spacer(minLength: Slate.Metric.space2)
            value()
                .foregroundStyle(Slate.Text.primary)
        }
    }
}

/// A small pill / badge — optional leading symbol + text, on the theme's element surface with a hairline.
struct SlatePill: View {
    var symbol: SFSymbol?
    let text: String
    var tint: Color = Slate.Text.secondary

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            if let symbol {
                Image(systemSymbol: symbol)
            }
            Text(text)
        }
        .font(.system(size: Slate.Typeface.footnote))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, 2)
        .background(Slate.Surface.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Slate.Line.subtle, lineWidth: 1))
    }
}

/// A "card" surface: element background, hairline border, rounded corners. The floating-card idiom
/// for inset content (command output, detail boxes). Use `.slateCard()` on any view.
private struct SlateCardModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Slate.Line.subtle, lineWidth: 1),
            )
    }
}

extension View {
    /// Wraps the view in a card surface (element fill + hairline border + rounded corners).
    func slateCard(
        radius: CGFloat = Slate.Metric.radiusControl,
        fill: Color = Slate.Surface.raised,
    ) -> some View {
        modifier(SlateCardModifier(radius: radius, fill: fill))
    }
}
#endif
