// AmbientPalette — the pure reduction step of the ambient light engine (design-craft pass, big-swing A,
// 2026-07-04). The video renderer reads back a tiny downsample of the live decoded frame (a handful of
// RGB pixels, ≤2 Hz); THIS type turns those raw samples into at most two glow colours plus a strength.
// It is deliberately a pure value type in WorkspaceCore so the taste logic is unit-tested headlessly —
// the Metal side only ever does the dumb readback (hang-safety rule: renderer types are compile-only).
//
// Taste contract (mirrors the TV bias-light idiom):
// - A colourful frame (movie, syntax-highlighted editor, warm terminal theme) produces a vivid,
//   NORMALIZED hue — the glow keeps the hue but the VIEW decides how dim to paint it.
// - A grey/white frame (blank IDE, PDF, plain shell) produces `strength ≈ 0`: a white app must never
//   flood the canvas with white light. Strength ramps on the frame's peak saturation.
// - A near-black frame also decays strength — no glow hallucinated out of noise.

public struct AmbientPalette: Equatable, Sendable {
    /// The most saturated representative hue of the frame, normalized to a vivid tone.
    public let primary: VideoPaneTint
    /// The frame's overall average colour (dimmer, used as the far falloff of the glow).
    public let secondary: VideoPaneTint
    /// 0…1 — how visible the glow may be. 0 for grey/white/black content.
    public let strength: Double

    public init(primary: VideoPaneTint, secondary: VideoPaneTint, strength: Double) {
        self.primary = primary
        self.secondary = secondary
        self.strength = strength
    }

    /// Reduces raw downsample pixels to a palette. Returns `nil` when there is nothing usable
    /// (no samples, or every sample non-finite) — validate-then-drop, never trap on garbage.
    public static func reduce(samples: [VideoPaneTint]) -> Self? {
        var best: VideoPaneTint?
        var bestScore = -1.0
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0.0
        var peakSaturation = 0.0
        var peakLuma = 0.0

        for sample in samples {
            guard sample.red.isFinite, sample.green.isFinite, sample.blue.isFinite else { continue }
            let r = clamp01(sample.red), g = clamp01(sample.green), b = clamp01(sample.blue)
            sumR += r
            sumG += g
            sumB += b
            count += 1

            let hi = Double.maximum(r, Double.maximum(g, b))
            let lo = Double.minimum(r, Double.minimum(g, b))
            let saturation = hi > 0 ? (hi - lo) / hi : 0
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            peakSaturation = Double.maximum(peakSaturation, saturation)
            peakLuma = Double.maximum(peakLuma, luma)

            // Prefer saturated-and-not-too-dark pixels as the hue carrier; the sqrt keeps a dim but
            // saturated pixel competitive against a bright washed-out one.
            let score = saturation * (luma < 0 ? 0 : luma.squareRoot())
            if score > bestScore {
                bestScore = score
                best = VideoPaneTint(red: r, green: g, blue: b)
            }
        }
        guard count > 0, let carrier = best else { return nil }

        let average = VideoPaneTint(red: sumR / count, green: sumG / count, blue: sumB / count)

        // Strength: ramp in over peak saturation 0.06→0.30 (grey UI stays dark), then decay if the
        // whole frame is near-black (peak luma below 0.04 → nothing real to reflect).
        let saturationRamp = clamp01((peakSaturation - 0.06) / 0.24)
        let lumaRamp = clamp01(peakLuma / 0.04)
        let strength = saturationRamp * lumaRamp

        return Self(
            primary: normalizeVivid(carrier),
            secondary: average,
            strength: strength,
        )
    }

    /// Scales the carrier so its brightest channel hits 0.85 — the glow keeps the HUE while the view
    /// controls brightness via opacity. A black carrier passes through unchanged (strength gates it).
    private static func normalizeVivid(_ tint: VideoPaneTint) -> VideoPaneTint {
        let hi = Double.maximum(tint.red, Double.maximum(tint.green, tint.blue))
        guard hi > 0.001 else { return tint }
        let scale = 0.85 / hi
        return VideoPaneTint(
            red: clamp01(tint.red * scale),
            green: clamp01(tint.green * scale),
            blue: clamp01(tint.blue * scale),
        )
    }

    private static func clamp01(_ value: Double) -> Double {
        Double.minimum(Double.maximum(value, 0), 1)
    }
}
