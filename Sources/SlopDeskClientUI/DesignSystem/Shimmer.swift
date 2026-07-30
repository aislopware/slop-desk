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
        /// The band's width as a fraction of the run. Wide enough that a short title ("api") is
        /// lit as a whole rather than sliced.
        static let widthFraction: CGFloat = 0.45
        /// …and never narrower than this, so a long title still gets a band with a readable ramp
        /// instead of a hairline.
        static let minimumWidth: CGFloat = 60

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
            let width = proxy.size.width
            let band = Slate.Shimmer.bandWidth(for: width)
            LinearGradient(
                stops: Slate.Shimmer.stops, startPoint: .leading, endPoint: .trailing,
            )
            .frame(width: band)
            // Starts fully off the leading edge and ends fully off the trailing one, so every lap
            // begins and ends with the run evenly lit — no flash at the wrap.
            .offset(x: -band + (pinnedPhase ?? phase) * (width + band))
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
