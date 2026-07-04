// SlateComponents — small reusable chrome components, styled NATIVELY (system semantic styles; the Slate
// token layer is retiring from chrome — native-chrome migration, 2026-07-03): a status dot (with an
// optional Pow glow on change) and the `.slateCard()` inset-card surface modifier. See also SlateControls
// (`SlatePlateButton`).

#if canImport(SwiftUI)
import Pow
import SFSafeSymbols
import SwiftUI

/// A small status dot. When `glowKey` is supplied it briefly glows (Pow) whenever the key changes. When
/// `breathing` is on, the dot carries a slow opacity pulse — the "alive" cue for an ONGOING healthy
/// state (a live connection), never a static one.
struct SlateStatusDot: View {
    let color: Color
    var size: CGFloat = 7
    /// An Equatable key (e.g. the status label) — a change triggers the glow. `nil` ⇒ no animation.
    var glowKey: String?
    /// Slow "I'm alive" breathing loop (design-craft pass, 2026-07-04). ONLY for genuinely ONGOING states
    /// (connected/streaming) — a looped ambient animation on a static state is noise, not signal (the
    /// animation-frequency rule). A degraded state should pass `false` so its stillness itself reads as
    /// "not healthy" beside the live dot.
    var breathing = false

    var body: some View {
        let dot = Circle().fill(color).frame(width: size, height: size)
            .modifier(BreathingModifier(active: breathing))
        if let glowKey {
            dot.changeEffect(.glow(color: color), value: glowKey)
        } else {
            dot
        }
    }
}

/// The breathing loop behind ``SlateStatusDot/breathing``: a slow opacity-only pulse (`easeInOut` 1.4s,
/// autoreversing forever) — the recording-indicator idiom. Deliberately NO scale: a size oscillation
/// inside a fixed pill reads as the dot popping in and out of its container (user verdict 2026-07-04:
/// "buồn cười"), while an opacity pulse reads as glow. Gated on Reduce Motion — the loop collapses to a
/// static dot when the user asked for stillness. Value-keyed off one flip so turning `active` off
/// settles the dot back to rest with a short non-repeating ease.
private struct BreathingModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inhaled = false

    func body(content: Content) -> some View {
        let animating = active && !reduceMotion
        content
            .opacity(animating ? (inhaled ? 1.0 : 0.55) : 1)
            .animation(
                animating
                    ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: inhaled,
            )
            .task(id: animating) { inhaled = animating }
    }
}

/// A "card" surface: a faint system fill, hairline separator border, rounded corners. The inset-content
/// idiom (command output, detail boxes). Use `.slateCard()` on any view.
private struct SlateCardModifier: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1),
            )
    }
}

extension View {
    /// Wraps the view in a card surface (faint fill + hairline border + rounded corners).
    func slateCard(radius: CGFloat = 6) -> some View {
        modifier(SlateCardModifier(radius: radius))
    }
}
#endif
