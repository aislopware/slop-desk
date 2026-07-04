// SlateComponents — small reusable chrome components, styled NATIVELY (system semantic styles; the Slate
// token layer is retiring from chrome — native-chrome migration, 2026-07-03): a status dot (with an
// optional Pow glow on change) and the `.slateCard()` inset-card surface modifier. See also SlateControls
// (`SlatePlateButton`).

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
