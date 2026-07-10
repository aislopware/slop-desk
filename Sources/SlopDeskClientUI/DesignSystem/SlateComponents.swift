// SlateComponents — the reusable chrome component kit on the token layer (REBUILD-V2, L9).
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
/// at rest). This removed the last Pow `changeEffect` in the design system.
struct SlateStatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// The AGENT-working indicator (MERIDIAN L3 exception — "animation is reserved for sustained live signals"):
/// a smooth "comet" arc, a ~260° stroked ring whose angular gradient fades solid→transparent (the comet tail)
/// and rotates continuously. This premium vector spinner replaced the `ProgressView`/braille rings and is
/// reserved for a WORKING AI agent — a plain command uses the quiet muted dot instead — so a spinning arc
/// always means "the agent is thinking". Rotation rides the WALL CLOCK via ``TimelineView`` (no `@State`), so
/// a list re-render — the rail rebuilds on every store tick — can't reset the spin. It stays within `size`, so
/// swapping it for a settled dot never shifts a tab row's height. Pure SwiftUI; no video/capture (hang-safety #6).
struct SlateCometArc: View {
    let color: Color
    var size: CGFloat = 13
    var lineWidth: CGFloat = 1.6
    /// Seconds per full revolution.
    private let period: Double = 1.1

    var body: some View {
        TimelineView(.animation) { timeline in
            // A continuous 0…360° sweep from the wall clock (separate `/` then `*` — no fused multiply-add).
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            let angle = t / period * 360
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    AngularGradient(gradient: Gradient(colors: [color.opacity(0), color]), center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round),
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(angle))
        }
    }
}

/// The AWAITING-INPUT attention indicator (the MERIDIAN L3 live-signal exception): a steady filled core dot
/// plus ONE halo ring that expands and fades on a gentle loop — a soft "ping" that draws the eye for the
/// most-urgent state WITHOUT the constant motion of a spinner. The halo's peak scale is capped so it stays
/// inside the badge box, so it never shifts a row's height. Wall-clock driven (``TimelineView``) so a
/// re-render can't reset the loop. Pure SwiftUI; no video/capture (hang-safety #6).
struct SlatePingDot: View {
    let color: Color
    var size: CGFloat = 8
    /// Seconds per ping.
    private let period: Double = 1.5

    var body: some View {
        TimelineView(.animation) { timeline in
            // 0…1 loop phase from the wall clock (separate `/` `*` `-` — no fused multiply-add).
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            ZStack {
                Circle()
                    .stroke(color, lineWidth: 1.2)
                    .frame(width: size, height: size)
                    .scaleEffect(1.0 + 0.85 * phase)
                    .opacity(0.55 * (1 - phase))
                Circle()
                    .fill(color)
                    .frame(width: size * 0.7, height: size * 0.7)
            }
        }
    }
}

/// The LIVE-dot indicator (the MERIDIAN L3 live-signal exception): a steady filled core dot with an arc
/// ring spinning around it. The core is EXACTLY the static ``SlateStatusDot`` size — the ring is added
/// OUTSIDE, so a state flipping between live and settled never changes the dot the eye is tracking.
///
/// The ring is the classic indeterminate motion: the HEAD advances at constant speed while the arc's
/// length breathes between short and long on an incommensurate period — so the TAIL chases and falls
/// back, and the ring never looks like a static wheel (2026-07-10: a fixed-length arc read as
/// monotonous). Uniform colour, no gradient (a faded tail's end cap read as a detached dot). Two
/// wearers: a WORKING agent (status amber) and an OSC 9;4 progress load (muted). Both phases ride the
/// WALL CLOCK (``TimelineView`` — a rail re-render can't reset them) and stay within `ringSize`. Pure
/// SwiftUI; no video/capture (hang-safety #6).
struct SlateOrbitDot: View {
    let color: Color
    /// The core dot — matches the static badge dot so live↔settled never resizes the dot itself.
    var dotSize: CGFloat = 8
    /// The spinner ring's outer diameter (the ring orbits OUTSIDE the core; must fit the badge box).
    var ringSize: CGFloat = 14
    var lineWidth: CGFloat = 1.2
    /// Seconds per full head revolution.
    private let spinPeriod: Double = 1.2
    /// Seconds per grow→shrink breath. Deliberately incommensurate with `spinPeriod` so the two phases
    /// drift against each other and the motion never settles into a visible repeat.
    private let breathePeriod: Double = 1.7
    /// The arc length's range, as fractions of the full circle.
    private let minSweep = 0.18, maxSweep = 0.72

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: dotSize, height: dotSize)
            TimelineView(.animation) { timeline in
                // Two wall-clock phases (separate `/` `*` `+` ops throughout — no fused multiply-add):
                // the head sweeps 0…360° uniformly; the sweep length breathes on a cosine.
                let now = timeline.date.timeIntervalSinceReferenceDate
                let spinT = now.truncatingRemainder(dividingBy: spinPeriod)
                let head = spinT / spinPeriod * 360
                let breatheT = now.truncatingRemainder(dividingBy: breathePeriod)
                let breathe = (1 - cos(breatheT / breathePeriod * 2 * .pi)) / 2 // 0…1…0
                let sweep = minSweep + (maxSweep - minSweep) * breathe
                // Anchor the HEAD to the uniform sweep (arc spans [head − sweep, head]): growing extends
                // the tail backwards, shrinking reels it in — the tail chases, the head never stutters.
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .frame(width: ringSize - lineWidth, height: ringSize - lineWidth)
                    .rotationEffect(.degrees(head - sweep * 360))
            }
        }
        .frame(width: ringSize, height: ringSize)
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
