// Contrast — WCAG relative-luminance + contrast-ratio helpers and the "pick the best foreground"
// chooser Warp uses for contrast-aware text (`pick_best_foreground_color`,
// `MinimumAllowedContrast::Text`; warp-tokens-color.md §3e, `color.rs:156-163`).
//
// Used to resolve the text tiers (main/sub/hint/disabled): `font_color(bg)` picks white-vs-theme-fg
// by contrast against the surface, then `Details` layers the opacity. On the default Dark theme
// (bg #000000) the high-contrast pick is the foreground white.
//
// Float-math discipline (CLAUDE.md #2): separate `*` + `+`, ordered min/max.

import Foundation

public extension ColorU {
    /// WCAG relative luminance in 0...1 (sRGB → linear, Rec.709 weights).
    /// `L = 0.2126 R + 0.7152 G + 0.0722 B` over linearized channels.
    var relativeLuminance: Double {
        let rl = Self.linearize(r)
        let gl = Self.linearize(g)
        let bl = Self.linearize(b)
        // Deliberately separate products + sums (no fma): each term computed then added.
        let wr = 0.2126 * rl
        let wg = 0.7152 * gl
        let wb = 0.0722 * bl
        let partial = wr + wg
        return partial + wb
    }

    /// WCAG contrast ratio between two opaque colors: `(Lhi + 0.05) / (Llo + 0.05)`, ≥ 1.
    func contrastRatio(against other: ColorU) -> Double {
        let l1 = relativeLuminance
        let l2 = other.relativeLuminance
        let hi = Swift.max(l1, l2)
        let lo = Swift.min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    private static func linearize(_ channel: UInt8) -> Double {
        let c = Double(channel) / 255.0
        if c <= 0.03928 {
            return c / 12.92
        }
        // ((c + 0.055) / 1.055) ^ 2.4
        let base = (c + 0.055) / 1.055
        return pow(base, 2.4)
    }
}

public enum Contrast {
    /// `pick_best_foreground_color` — choose whichever candidate has the higher contrast against
    /// `background` (warp-tokens-color.md §3e). Warp's real chooser also honors a minimum-contrast
    /// threshold; for the dark/light seed pairs we ship, max-contrast is the faithful selection.
    public static func pickBestForeground(
        on background: ColorU,
        candidates: [ColorU],
    ) -> ColorU {
        // Default to the first candidate (the theme foreground) so an empty/degenerate list never traps.
        guard var best = candidates.first else {
            return ColorU(u32: 0xFFFF_FFFF)
        }
        var bestRatio = best.contrastRatio(against: background)
        for c in candidates.dropFirst() {
            let r = c.contrastRatio(against: background)
            if r > bestRatio {
                bestRatio = r
                best = c
            }
        }
        return best
    }
}
