// SlateComponents — the reusable chrome component kit on the token layer.
//
// Small, composable pieces factored out of the chrome so every surface stays consistent and new views are
// quick to assemble: a status dot, a key/value row, a pill/badge, and an `.slateCard()` surface modifier.
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

/// The ONE-SHAPE status instrument, in the Linear fill-fraction vocabulary: every lifecycle state is
/// the SAME circle — Ø12, fixed centre in a 16pt box — varying only HOW MUCH of it is drawn/filled
/// (the `◌ ○ ◔ ◉ ●` terminal-glyph ladder), never its silhouette:
///   • `working`  → the DASHED ring (8 dashes, dash:gap 1:1 — a true `◌` glyph). The GEOMETRY is
///                  static; the whole glyph flickers between two opacity plateaus on a stepped ramp
///                  (discrete frames, e-ink-refresh cadence) — nothing rotates, nothing breathes;
///   • `awaiting` → ring + filled centre dot (`◉`) — armed, waiting on you. Static;
///   • `pie`      → ring + a centre pie wedge swept to the REAL 0…1 fraction (`◔` at 25%) — an
///                  OSC 9;4 command's progress drawn as geometry, not decoration;
///   • `hollow`   → the bare ring (`○`) — a command is running, nothing more to say;
///   • `done`     → the FILLED disc with a knocked-out check (`●` + ✓) — the terminal state earns the
///                  only solid fill;
///   • `error`    → the filled disc with a knocked-out cross — same weight as done: an outcome;
///   • `glyph`    → a small SF-symbol in the muted ring (the at-rest privilege markers).
/// The one animation rides the WALL CLOCK on a stepped `TimelineView` schedule — a re-render can't
/// reset its phase, and frames advance in hard steps (T3's `steps(10)` duty-cycle, never an eased
/// pulse). Pure SwiftUI; no video/capture (hang-safety #6).
struct StatusRing: View {
    enum Reading: Equatable {
        case working
        case awaiting
        case done
        case error
        case hollow
        /// The 0…1 progress sweep; `nil` (an indeterminate report) draws the bare ring.
        case pie(Double?)
        case glyph(String)
    }

    let reading: Reading
    let tint: Color

    /// The shared geometry — one registration for every reading, so transitions can't jump.
    private static let box: CGFloat = 16
    private static let diameter: CGFloat = 12
    private static let stroke: CGFloat = 1.5
    private static let mutedStroke: CGFloat = 1.2
    /// The pie wedge's radius — Linear's fill sits well inside the ring (their 3.5 : 6), so the sweep
    /// reads as a gauge needle area, not a second ring.
    private static let pieRadius: CGFloat = 3.5
    /// The working flicker's duty cycle (T3's `sidebar-working-text` timing): one 3.4s period holding
    /// full strength for a third, dipping to the low plateau for a third, with stepped ramps between.
    private static let flickerPeriod: Double = 3.4
    /// The flicker's re-render cadence — 20 discrete frames per period (the two ramps get ~3 hard
    /// steps each; the plateaus hold).
    private static let flickerBeat: Double = 0.17
    /// The flicker's low plateau.
    private static let flickerFloor: Double = 0.75

    var body: some View {
        ZStack {
            switch reading {
            case .working: workingRing
            case .awaiting:
                solidRing
                Circle().fill(tint).frame(width: 5, height: 5)
            case .done:
                filledDisc
                checkMark
            case .error:
                filledDisc
                crossMark
            case .hollow:
                mutedRing
            case let .pie(fraction):
                mutedRing
                if let fraction { pieWedge(fraction) }
            case let .glyph(name):
                mutedRing
                Image(systemName: name)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .scaleEffect(0.68)
                    .foregroundStyle(tint)
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

    private var filledDisc: some View {
        Circle()
            .fill(tint)
            .frame(width: Self.diameter, height: Self.diameter)
    }

    /// The working `◌`: 8 dashes at dash:gap 1:1 (each dash 22.5°, each gap 22.5° — the icon-family
    /// proportion; a thinner gap collapses into a "cracked circle" at this size), one dash centred at
    /// 12 o'clock. The geometry never moves — the whole glyph flickers through ``flickerOpacity(at:)``.
    private var workingRing: some View {
        TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: Self.flickerBeat)) { timeline in
            dashedRing.opacity(Self.flickerOpacity(at: timeline.date))
        }
    }

    private var dashedRing: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Circle()
                    .trim(from: Double(index) / 8.0, to: Double(index) / 8.0 + 1.0 / 16.0)
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        // −90° puts trim 0 at 12 o'clock; the extra −11.25° centres dash 0 ON 12 o'clock.
        .rotationEffect(.degrees(-101.25))
    }

    /// The stepped duty-cycle opacity (T3's recipe verbatim: hold 1.0 through 36%, step down to the
    /// 0.75 plateau by 50%, hold through 86%, step back up). Ramps quantize to hard 1/10 steps —
    /// discrete frames, no easing — and the phase rides the wall clock from a fixed epoch, so every
    /// working ring in the sidebar flickers in unison and a re-mount lands mid-cycle.
    static func flickerOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: flickerPeriod) / flickerPeriod
        let depth = 1.0 - flickerFloor
        switch phase {
        case ..<0.36: return 1.0
        case ..<0.50:
            let step = ((phase - 0.36) / 0.14 * 10).rounded(.down) / 10
            return 1.0 - depth * step
        case ..<0.86: return flickerFloor
        default:
            let step = ((phase - 0.86) / 0.14 * 10).rounded(.down) / 10
            return flickerFloor + depth * step
        }
    }

    /// The determinate pie wedge: a solid sector swept clockwise from 12 o'clock to `fraction` of the
    /// full turn, at the inner ``pieRadius`` — progress as filled AREA inside the constant ring.
    private func pieWedge(_ fraction: Double) -> some View {
        let sweep = Double.minimum(Double.maximum(fraction, 0), 1)
        return Path { path in
            let centre = CGPoint(x: Self.box / 2, y: Self.box / 2)
            path.move(to: centre)
            path.addArc(
                center: centre,
                radius: Self.pieRadius,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + sweep * 360),
                clockwise: false,
            )
            path.closeSubpath()
        }
        .fill(tint)
        .frame(width: Self.box, height: Self.box)
    }

    /// The knocked-out check of the `done` disc — drawn in the ground tone so it reads as a cut-out,
    /// in the ring's own 16pt space so its optical centre matches every other reading's.
    private var checkMark: some View {
        Path { path in
            path.move(to: CGPoint(x: 5.4, y: 8.3))
            path.addLine(to: CGPoint(x: 7.3, y: 10.1))
            path.addLine(to: CGPoint(x: 10.6, y: 6.3))
        }
        .stroke(
            Slate.Surface.ground,
            style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round, lineJoin: .round),
        )
        .frame(width: Self.box, height: Self.box)
    }

    /// The knocked-out cross of the `error` disc.
    private var crossMark: some View {
        Path { path in
            path.move(to: CGPoint(x: 6.3, y: 6.3))
            path.addLine(to: CGPoint(x: 9.7, y: 9.7))
            path.move(to: CGPoint(x: 9.7, y: 6.3))
            path.addLine(to: CGPoint(x: 6.3, y: 9.7))
        }
        .stroke(Slate.Surface.ground, style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
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
