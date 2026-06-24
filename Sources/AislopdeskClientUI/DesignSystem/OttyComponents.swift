// OttyComponents — the reusable otty chrome component kit on the token layer (REBUILD-V2, L9).
//
// Small, composable pieces factored out of the chrome so every surface stays consistent and new views are
// quick to assemble: a status dot (with an optional Pow glow on change), a key/value row, a pill/badge, and
// an `.ottyCard()` surface modifier. All built on `Otty.*` tokens + `OttyTheme`. See also OttyControls
// (`OttyPlateButton`) and OttyRow (`OttySidebarRow` / `OttySectionHeader`).

#if canImport(SwiftUI)
import Pow
import SFSafeSymbols
import SwiftUI

/// A small status dot. When `glowKey` is supplied it briefly glows (Pow) whenever the key changes.
struct OttyStatusDot: View {
    let color: Color
    var size: CGFloat = 7
    /// An Equatable key (e.g. the status label) — a change triggers the glow. `nil` ⇒ no animation.
    var glowKey: String?

    var body: some View {
        let dot = Circle().fill(color).frame(width: size, height: size)
        if let glowKey {
            dot.changeEffect(.glow(color: color), value: glowKey)
        } else {
            dot
        }
    }
}

/// A compact label/value row: a secondary label on the left, a trailing primary value.
struct OttyKeyValueRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Otty.Metric.space2) {
            Text(label)
                .foregroundStyle(Otty.Text.secondary)
            Spacer(minLength: Otty.Metric.space2)
            value()
                .foregroundStyle(Otty.Text.primary)
        }
    }
}

/// A small pill / badge — optional leading symbol + text, on the otty element surface with a hairline.
struct OttyPill: View {
    var symbol: SFSymbol?
    let text: String
    var tint: Color = Otty.Text.secondary

    var body: some View {
        HStack(spacing: Otty.Metric.space1) {
            if let symbol {
                Image(systemSymbol: symbol)
            }
            Text(text)
        }
        .font(.system(size: Otty.Typeface.footnote))
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, Otty.Metric.space2)
        .padding(.vertical, 2)
        .background(Otty.Surface.element, in: Capsule())
        .overlay(Capsule().strokeBorder(Otty.Line.subtle, lineWidth: 1))
    }
}

/// An otty "card" surface: element background, hairline border, rounded corners. The floating-card idiom
/// for inset content (command output, detail boxes). Use `.ottyCard()` on any view.
private struct OttyCardModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Otty.Line.subtle, lineWidth: 1),
            )
    }
}

extension View {
    /// Wraps the view in an otty card surface (element fill + hairline border + rounded corners).
    func ottyCard(
        radius: CGFloat = Otty.Metric.radiusControl,
        fill: Color = Otty.Surface.element,
    ) -> some View {
        modifier(OttyCardModifier(radius: radius, fill: fill))
    }
}
#endif
