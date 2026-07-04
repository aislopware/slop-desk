// GlassPanel — the ONE floating-overlay glass shell (design-craft pass, 2026-07-04). Ghostty's shipped
// command-palette recipe (macos/Sources/Features/Command Palette/CommandPalette.swift), adapted to the
// Slate canvas: an `.ultraThinMaterial` frost with the THEME card colour composited over it via
// `.blendMode(.color)` inside one `compositingGroup` — the frost keeps the material's luminosity but
// inherits the theme's HUE, so a floating panel reads as "this theme's glass" (warm over Ristretto,
// violet over Classic) instead of a flat gray material puck that ignores the canvas under it. The ring
// is the system `tertiaryLabel` at 0.75 (Ghostty's exact stroke — auto-adapts to appearance/vibrancy,
// never a hand-picked gray), and the shadow follows the FLOATING recipe: LARGE blur relative to a small
// downward offset (y = radius × 0.4 ≈ Ghostty's 32/12) — big-blur/small-offset is what separates
// "genuinely floats" from "card with a shadow slapped on" (Zed reserves shadows for exactly this tier:
// transient surfaces ABOVE the layout; pane cards in the layout keep their own gentle treatment).
//
// Callers pick the radius/shadow for their size class (palette 12/32 → pills 6/6); `ringed: false` is
// for surfaces that carry their OWN ring (ViModePill's visual-mode accent swap) or deliberately none
// (the find bar's pixel-pinned borderless card).

#if canImport(SwiftUI)
import SwiftUI

/// Shared glass-shell constants — public so a caller that draws its OWN ring (`ringed: false`, e.g. the
/// vi pill's visual-mode accent swap) can still use the standard ring tone for its resting state.
enum GlassPanel {
    /// Ghostty's panel ring: the system tertiary label tone at 0.75 — adapts to light/dark + vibrancy.
    static var ring: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor).opacity(0.75)
        #else
        Color(uiColor: .tertiaryLabel).opacity(0.75)
        #endif
    }
}

private struct GlassPanelModifier: ViewModifier {
    var radius: CGFloat
    var shadowRadius: CGFloat
    var ringed: Bool

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    // Theme-hue tint: `.color` blend keeps the frost's luminosity, takes the theme's hue —
                    // Ghostty's tinted-glass trick, keyed to OUR live canvas theme.
                    Rectangle().fill(Slate.Surface.card).blendMode(.color)
                }
                .compositingGroup()
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if ringed {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(GlassPanel.ring, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: shadowRadius, x: 0, y: shadowRadius * 0.4)
    }
}

extension View {
    /// The floating-overlay glass shell: theme-tinted frost + system hairline ring + big-blur/small-offset
    /// shadow. See `GlassPanel.swift` header for the recipe provenance.
    func glassPanel(radius: CGFloat, shadowRadius: CGFloat, ringed: Bool = true) -> some View {
        modifier(GlassPanelModifier(radius: radius, shadowRadius: shadowRadius, ringed: ringed))
    }
}
#endif
