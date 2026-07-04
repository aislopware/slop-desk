// SlateComponents — the reusable chrome component kit on the token layer (REBUILD-V2, L9).
//
// Small, composable pieces factored out of the chrome so every surface stays consistent and new views are
// quick to assemble: a status dot (with an optional Pow glow on change), a key/value row, a pill/badge, and
// an `.slateCard()` surface modifier. All built on `Slate.*` tokens + `SlateTheme`. See also SlateControls
// (`SlatePlateButton`) and SlateRow (`SlateSidebarRow` / `SlateSectionHeader`).

#if canImport(SwiftUI)
import Pow
import SFSafeSymbols
import SwiftUI

/// A small status dot. When `glowKey` is supplied it briefly glows (Pow) whenever the key changes.
struct SlateStatusDot: View {
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
        .background(Slate.Surface.element, in: Capsule())
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
        fill: Color = Slate.Surface.element,
    ) -> some View {
        modifier(SlateCardModifier(radius: radius, fill: fill))
    }
}
#endif
