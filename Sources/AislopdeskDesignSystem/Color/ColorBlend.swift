// ColorBlend — verbatim port of Warp's `internal_colors` blend math
// (warp-tokens-color.md §0, sources `crates/warp_core/src/ui/color/mod.rs` + `blend.rs`).
//
// This is the load-bearing arithmetic of the whole derived-token system: every surface, overlay,
// border, hover/pressed state, and secondary/disabled text color is `bg.blend(fg|accent @ N%)`.
// Reproduce the FORMULA (incl. its `ceil` ratio rounding), not the gray approximations — the
// resolved bytes follow this rounding exactly (warp-tokens-color.md §3b note).
//
// Float-math discipline (CLAUDE.md convention #2): keep separate `*` + `+`, never fuse into
// `addingProduct`/`fma`; use ordered min/max, not a bare `<`/`>` ternary.

import Foundation

public extension ColorU {
    /// `coloru_with_opacity(c, pct)` — set the ALPHA from a percent (0...100). rgb unchanged.
    /// `a' = c.a * pct / 100` (warp-tokens-color.md §0, `mod.rs:51-54`). `Opacity` is a percent,
    /// NOT a 0...255 alpha. Out-of-range percents are clamped to 0...100 (validate-then-drop).
    func withOpacity(_ pct: Int) -> ColorU {
        let clamped = Swift.max(0, Swift.min(100, pct))
        // c.a * pct / 100, integer-exact for the percent domain (matches Rust `as u8` truncation).
        let newA = UInt8((Int(a) * clamped) / 100)
        return ColorU(r: r, g: g, b: b, a: newA)
    }

    /// `ColorU::blend(self, other)` — straight-alpha src-over: `self` is the background, `other` is
    /// the overlay painted on top (warp-tokens-color.md §0, `blend.rs:18-47`).
    ///
    ///   ratio = ceil(other.a / 255 * 100) / 100          // overlay coverage, quantized to 1%
    ///   out_channel = c_bg * (1 - ratio) + c_over * ratio
    ///   out_alpha   = OPAQUE if bg opaque, else mean(bg.a, over.a)
    ///
    /// Short-circuits (in Warp's order): bg fully transparent OR overlay opaque → overlay;
    /// overlay fully transparent → bg.
    func blend(_ overlay: ColorU) -> ColorU {
        // Short-circuits first (blend.rs:23-31).
        if a == 0 { return overlay } // bg fully transparent → overlay
        if overlay.a == Self.opaque { return overlay } // overlay opaque → overlay
        if overlay.a == 0 { return self } // overlay fully transparent → bg

        // ratio = ceil(over.a / 255 * 100) / 100.
        // over.a/255*100 is the overlay alpha as a percent; ceil to whole percent, /100 back to 0...1.
        let pct = (Double(overlay.a) / 255.0) * 100.0
        let ratio = pct.rounded(.up) / 100.0
        let inv = 1.0 - ratio

        let outR = Self.mix(Double(r), Double(overlay.r), inv: inv, ratio: ratio)
        let outG = Self.mix(Double(g), Double(overlay.g), inv: inv, ratio: ratio)
        let outB = Self.mix(Double(b), Double(overlay.b), inv: inv, ratio: ratio)

        // alpha: OPAQUE if bg opaque, else per-channel mean (blend.rs:41-45).
        let outA: UInt8 = a == Self.opaque
            ? Self.opaque
            : UInt8((Int(a) + Int(overlay.a)) / 2)

        return ColorU(r: outR, g: outG, b: outB, a: outA)
    }

    /// `mid_coloru(c1, c2)` — per-channel arithmetic mean, alpha forced OPAQUE (gradient midpoint).
    /// (warp-tokens-color.md §0, `mod.rs:59-64`.)
    func mid(_ other: ColorU) -> ColorU {
        ColorU(
            r: UInt8((Int(r) + Int(other.r)) / 2),
            g: UInt8((Int(g) + Int(other.g)) / 2),
            b: UInt8((Int(b) + Int(other.b)) / 2),
            a: Self.opaque,
        )
    }

    /// `darken(c)` — ×0.48 per channel, ceil (factor `1 - 0.52`). (warp-tokens-color.md §0, `mod.rs:67,71-77`.)
    func darkened() -> ColorU {
        ColorU(
            r: Self.scaleCeil(r, by: 0.48),
            g: Self.scaleCeil(g, by: 0.48),
            b: Self.scaleCeil(b, by: 0.48),
            a: a,
        )
    }

    /// `lighten(c)` — adds `0.5 * (255 - channel)` per channel. (warp-tokens-color.md §0, `mod.rs:68,80-90`.)
    func lightened() -> ColorU {
        ColorU(
            r: Self.addHalfHeadroom(r),
            g: Self.addHalfHeadroom(g),
            b: Self.addHalfHeadroom(b),
            a: a,
        )
    }

    // MARK: - Channel helpers (kept as separate `*` + `+`, never fused)

    private static func mix(_ bg: Double, _ over: Double, inv: Double, ratio: Double) -> UInt8 {
        // out = bg*inv + over*ratio  — DELIBERATELY two ops, no fma (CLAUDE.md #2).
        let lhs = bg * inv
        let rhs = over * ratio
        let sum = lhs + rhs
        // pathfinder rounds the blended f32 channel to the nearest u8 (so fg@10% over #000 →
        // 255*0.1 = 25.5 → 26 = 0x1A, matching the spec's #1A1A1A). Clamp for safety.
        let clamped = Swift.max(0.0, Swift.min(255.0, sum.rounded()))
        return UInt8(clamped)
    }

    private static func scaleCeil(_ channel: UInt8, by factor: Double) -> UInt8 {
        let scaled = (Double(channel) * factor).rounded(.up)
        return UInt8(Swift.max(0.0, Swift.min(255.0, scaled)))
    }

    private static func addHalfHeadroom(_ channel: UInt8) -> UInt8 {
        let headroom = 255.0 - Double(channel)
        let added = Double(channel) + headroom * 0.5
        return UInt8(Swift.max(0.0, Swift.min(255.0, added.rounded())))
    }
}
