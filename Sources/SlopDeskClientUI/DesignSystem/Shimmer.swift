// Shimmer — a highlight band travelling across a view's OWN glyphs, for the one row in the rail
// whose work is happening right now.
//
// The rail already says "this agent is generating" with the trailing spinner. The shimmer says the
// same thing about the ROW rather than about the mark column: a title that moves is a title you find
// without scanning the right edge for a 14pt wheel, which matters most on the surface where several
// agents run at once. It spends no hue to do it — the band is the title's own ink at full strength
// over the same ink held slightly back, so a shimmering row reads as the SAME title, lit.
//
// ⚠️ It is deliberately a MASK over the text, not a recolour: the glyphs keep their exact shape,
// weight and ink, and nothing about the row's layout moves. A settled rail stays absolutely still —
// only the raw `.working` row is allowed this (docs/DECISIONS.md rounds 19, 22, 23).

#if canImport(SwiftUI)
import SwiftUI

extension Slate {
    /// The travelling-highlight tokens. One definition, so the rail and anything that follows it
    /// shimmer at one speed and one contrast.
    enum Shimmer {
        /// Seconds for the band to cross the whole run once. Slow enough to read as a sweep rather
        /// than a flicker, and slower than the spinner's own turn so the two never lock into a beat.
        static let period: Double = 1.9
        /// What the run is worth OUTSIDE the band. ⚠️ Rendered at 0.55 the unlit title sat BELOW
        /// the resting rows' secondary ink, so for most of every lap the row doing the work read
        /// dimmer than the ones asleep — backwards. The floor is "still brighter than resting".
        static let base: Double = 0.7
        /// The band's width as a fraction of the run. ⚠️ It must stay WELL under the run: shipped
        /// first at 0.45 with a 60pt floor, which on the rail's short titles (a project name, a
        /// bare `api`) covered the whole run — so the title blinked on and off instead of being
        /// swept, and the wrap read as a jerk back to the start rather than a band leaving.
        static let widthFraction: CGFloat = 0.35
        /// …and never narrower than this, so the ramp is still a ramp on a very short run.
        static let minimumWidth: CGFloat = 16

        /// The band, as fractions of its own width: dark at both ends, full in the middle. The
        /// quarter stops are the ramp — two stops alone give a hard-edged wedge that reads as a
        /// rendering fault rather than a sweep.
        static var stops: [Gradient.Stop] {
            [
                Gradient.Stop(color: .clear, location: 0),
                Gradient.Stop(color: .white.opacity(0.5), location: 0.25),
                Gradient.Stop(color: .white, location: 0.5),
                Gradient.Stop(color: .white.opacity(0.5), location: 0.75),
                Gradient.Stop(color: .clear, location: 1),
            ]
        }

        /// The band's width for a run of `width` points.
        static func bandWidth(for width: CGFloat) -> CGFloat {
            CGFloat.maximum(minimumWidth, width * widthFraction)
        }

        /// Where the band's LEADING edge sits at `phase` of one pass across a run of `runWidth`.
        /// A pass starts fully off the head and ends fully off the tail, so the band creeps IN and
        /// creeps OUT — it is never simply switched on.
        ///
        /// ⚠️⚠️ This MUST stay monotonic in `phase`, and `offset(0)` must differ from `offset(1)`.
        /// SwiftUI animates the RESULTING offset between the transaction's endpoints — it does not
        /// sample this function over time. A wrapped phase (`phase - phase.rounded(.down)`, tried
        /// once to make a mid-pass restart seamless) makes both endpoints identical, so the
        /// interpolation becomes a no-op and the shimmer silently STOPS EXISTING. It still compiles,
        /// still passes every pinned-phase render, and is invisible until someone looks at the app.
        static func offset(phase: CGFloat, runWidth: CGFloat) -> CGFloat {
            let band = bandWidth(for: runWidth)
            return -band + phase * (runWidth + band)
        }
    }
}

extension View {
    /// Sweep a highlight across this view's own glyphs while `active`.
    ///
    /// Inert when `active` is false and under Reduce Motion — and dropping it there costs NOTHING,
    /// because the state it emphasises is already said by the row's trailing mark. That is the whole
    /// reason this may be a pure decoration: it is the second voice on a fact, never the only one.
    ///
    /// - Parameter phase: pins the band at one point of its lap (`0...1`) instead of animating it.
    ///   The snapshot harness's seam — a mark that says "now" can only be judged by watching it, and
    ///   watching it means rendering the same view at chosen instants rather than a mock of it.
    func slateShimmer(_ active: Bool, phase: CGFloat? = nil) -> some View {
        modifier(SlateShimmer(active: active, pinnedPhase: phase))
    }
}

/// The travelling highlight. Two copies of the content: one held back to ``Slate/Shimmer/base``, one
/// at full strength showing only through the band. Both are the SAME view, so the glyphs can't
/// disagree about shape, weight or position.
private struct SlateShimmer: ViewModifier {
    let active: Bool
    /// Non-nil pins the band and runs no animation — see ``SwiftUI/View/slateShimmer(_:phase:)``.
    let pinnedPhase: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if active, !reduceMotion {
            content
                .opacity(Slate.Shimmer.base)
                .overlay { band(over: content) }
                .onAppear { if pinnedPhase == nil { run() } }
                // A recycled row (the rail rebuilds on every workspace edit) must restart the lap
                // rather than inherit a stale one.
                .onChange(of: active) { _, working in
                    if working, pinnedPhase == nil { run() }
                }
        } else {
            content
        }
    }

    private func band(over content: Content) -> some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: Slate.Shimmer.stops, startPoint: .leading, endPoint: .trailing,
            )
            .frame(width: Slate.Shimmer.bandWidth(for: proxy.size.width))
            .offset(x: Slate.Shimmer.offset(
                phase: pinnedPhase ?? phase, runWidth: proxy.size.width,
            ))
        }
        .mask(content)
        .allowsHitTesting(false)
    }

    private func run() {
        phase = 0
        withAnimation(.linear(duration: Slate.Shimmer.period).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
#endif
