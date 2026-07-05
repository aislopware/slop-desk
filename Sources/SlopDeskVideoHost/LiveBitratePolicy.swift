import Foundation

/// PURE resolution-aware live-bitrate policy for the HEVC encoder (2026-06-08 — scroll-smoothness fix).
///
/// WHY: the flat 12 Mbps live default (doc 18 §E) was MEASURED at 1080p@1×. Feature #1's 2× HiDPI
/// virtual display quadrupled the encoded pixels (a window now captures at points×2, e.g. 2816×1778)
/// but left the budget at 12 Mbps. With the hard `DataRateLimits` cap AND the `MaxAllowedFrameQP`
/// ceiling both binding, a heavy scroll frame could not fit at the ceiling QP → VideoToolbox DROPPED
/// it → the "scroll/content-change not smooth" stutter the user reported (sharpness was already fixed).
/// A dropped frame IS the stutter; the cure is enough bits that motion frames fit.
///
/// WHAT: size the live budget to the ACTUAL encoded pixel throughput (area × fps) at a fixed
/// bits-per-pixel-per-frame density, so any window at any `captureScale` is provisioned proportionally.
/// The configured `--bitrate` acts as a FLOOR (an explicit higher value is still honoured); LAN/NetBird
/// bandwidth is ample, so the resolution-derived value wins for any window from ~1080p up.
///
/// Pure Int/Double arithmetic — unit-tested. (The `VideoEncoder` it feeds is HW-gated and never
/// instantiated in a test; this keeps the bitrate decision headlessly verifiable.)
public enum LiveBitratePolicy {
    /// Bits per pixel per frame. 0.15 ≈ the proven-good density bumped a notch for motion headroom:
    /// 1920·1080·60·0.15 ≈ 18.7 Mbps at 1080p60, scaling to ≈45 Mbps at a 2816×1778@60 HiDPI window.
    ///
    /// MOTION-SMOOTHNESS A/B (2026-06-08): at 2× the 0.15 density makes a fast-scroll frame balloon to
    /// 50–280 KB — a wildly VARIABLE per-frame transmit/decode time that the client's (no-jitter-buffer)
    /// vsync pacer turns into judder ("giật"). HW A/B proved frame SIZE is the dominant lever: dropping
    /// to 1× (¼ the bytes) made scroll markedly smoother. So this is now env-tunable (`SLOPDESK_BPP`) to
    /// dial the smooth↔sharp balance WITHOUT a rebuild: a LOWER bpp shrinks motion frames toward 1× size
    /// (smooth scroll, coarser DURING motion only — natural motion blur), while the crisp static refresh
    /// (`encodeLiveCrispKeyframe`) restores razor-sharp text the instant the screen goes still. With the
    /// `MaxAllowedFrameQP=40` ceiling a leaner budget COARSENS motion frames, never drops them.
    public static let bitsPerPixelPerFrame: Double = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_BPP"], let v = Double(s), v > 0,
           v <= 1.0 { return v }
        return 0.15
    }()

    /// Absolute lower bound so a tiny window never starves the encoder (matches `VideoEncoder.init`'s
    /// own `max(1_000_000, …)` clamp).
    public static let minimumBitrate = 1_000_000

    /// Resolution-aware target bitrate (bits/sec) for an encoder of `pixelWidth × pixelHeight` at
    /// `fps`. Never below `floor` (the configured `--bitrate`, so an explicit higher cap is honoured)
    /// and never below ``minimumBitrate``. Degenerate (zero/negative) dimensions and fps are
    /// clamped to 1.
    public static func targetBitrate(pixelWidth: Int, pixelHeight: Int, fps: Int, floor: Int) -> Int {
        let px = max(1, pixelWidth)
        let py = max(1, pixelHeight)
        let rate = max(1, fps)
        // keep mul+add separate — FMA breaks bit-exact parity (pure multiplies here; round half-away
        // matches Rust `f64::round`, which Swift `.rounded()` reproduces).
        let bits = Double(px) * Double(py) * Double(rate) * bitsPerPixelPerFrame
        let resolution = Int(bits.rounded())
        return max(max(minimumBitrate, floor), resolution)
    }
}
