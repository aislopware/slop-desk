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
/// moves). Hue + fill + stroke style carry the state; the silhouette never changes. The readings speak
/// the app's own dialect rather than stock indicator shapes (no dashed spinner, no recording-dot halo,
/// no ✕ glyph):
///   • `resting`  → muted plain ring (at rest, no colour spent);
///   • `working`  → the COMET arc — one luminous arc with a fading tail sweeping the ring;
///   • `awaiting` → solid ring whose centre dot BLINKS on the terminal cursor's cadence — the pane is
///                  a prompt waiting for input (a hard on/off cut, exactly like a block cursor);
///   • `done`     → the small FILLED circle (the quiet unread-finish dot — same family, full fill);
///   • `error`    → the ring itself BROKEN — a static gap bitten out of the circle.
/// All motion rides the WALL CLOCK (phase derived from absolute time) so a rail re-render lands
/// mid-cycle instead of restarting it. Pure SwiftUI; no video/capture (hang-safety #6).
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
    /// The comet's arc span as a fraction of the circle (~110°).
    private static let cometSpan: Double = 0.3
    /// Seconds per comet revolution — brisk enough to read as live, slow enough to stay calm.
    private static let cometPeriod: Double = 1.4
    /// Seconds per awaiting blink phase — the classic terminal cursor cadence.
    private static let blinkBeat: Double = 0.53
    /// The error ring's missing fraction (~50° bitten out of the circle).
    private static let breakGap: Double = 0.14

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
                brokenRing
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

    /// The comet working reading: ONE arc whose tail fades to nothing, sweeping the ring continuously.
    /// The tail's angular gradient lives in the shape's own space, so the whole comet — bright head,
    /// vanishing tail — rotates as a unit. Phase comes off the wall clock, so a re-mount lands
    /// mid-revolution instead of restarting it.
    private var workingRing: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.cometPeriod) / Self.cometPeriod
            Circle()
                .trim(from: 0, to: Self.cometSpan)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [tint.opacity(0), tint]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * Self.cometSpan),
                    ),
                    style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round),
                )
                .frame(width: Self.diameter, height: Self.diameter)
                .rotationEffect(.degrees(phase * 360 - 90))
        }
    }

    /// The awaiting reading: the solid ring holds steady while the centre dot blinks — a hard on/off
    /// cut on the terminal cursor's cadence. An awaiting pane IS a prompt with the cursor parked at it;
    /// the badge borrows exactly that signal instead of a generic pulse.
    private var awaitingRing: some View {
        TimelineView(.periodic(from: .now, by: Self.blinkBeat)) { timeline in
            let on = Int(timeline.date.timeIntervalSinceReferenceDate / Self.blinkBeat).isMultiple(of: 2)
            ZStack {
                solidRing
                if on {
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
            }
        }
    }

    /// The error reading: the circle itself broken — a gap bitten out of the ring, held static (it
    /// waits on you). Rotated so the gap sits at the top-right; round caps keep the broken ends crisp.
    private var brokenRing: some View {
        Circle()
            .trim(from: Self.breakGap, to: 1)
            .stroke(tint, style: StrokeStyle(lineWidth: Self.stroke, lineCap: .round))
            .frame(width: Self.diameter, height: Self.diameter)
            .rotationEffect(.degrees(-70))
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
