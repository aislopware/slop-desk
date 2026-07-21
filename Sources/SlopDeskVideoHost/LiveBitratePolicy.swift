import Foundation

/// PURE resolution-aware live-bitrate policy for the HEVC encoder.
///
/// WHY: the flat 12 Mbps live default (doc 18 §E) was MEASURED at 1080p@1×. A 2× HiDPI virtual
/// display quadruples the encoded pixels (a window captures at points×2, e.g. 2816×1778) while the
/// budget stays at 12 Mbps. With the hard `DataRateLimits` cap AND the `MaxAllowedFrameQP` ceiling
/// both binding, a heavy scroll frame can't fit at the ceiling QP → VideoToolbox DROPS it → scroll
/// and content-change stutter. A dropped frame IS the stutter; the cure is enough bits that motion
/// frames fit.
///
/// WHAT: size the live budget to the ACTUAL encoded pixel throughput (area × fps) at a fixed
/// bits-per-pixel-per-frame density, so any window at any `captureScale` is provisioned proportionally.
/// The configured `--bitrate` acts as a FLOOR (an explicit higher value is still honoured); LAN/NetBird
/// bandwidth is ample, so the resolution-derived value wins for any window from ~1080p up.
///
/// Pure Int/Double arithmetic — unit-tested. (The `VideoEncoder` it feeds is HW-gated and never
/// instantiated in a test; this keeps the bitrate decision headlessly verifiable.)
public enum LiveBitratePolicy {
    /// Bits per pixel per frame. 0.25: 1920·1080·60·0.25 ≈ 31.1 Mbps at 1080p60, scaling to
    /// ≈75 Mbps at a 2816×1778@60 HiDPI window. HW-calibrated (2026-07-21, RTT 5–8 ms link): this is
    /// the ceiling that lets the budget-adaptive sharp QP ceiling (`VideoEncoder.sharpQPCeiling`)
    /// hold QP≤38 through a hard 1080p60 scroll with ZERO VT drops — at the old 0.15 (18.7 Mbps)
    /// the same scroll either blurred to QP 51 or dropped 97 frames/18s when the QP was capped.
    /// This is the CEILING, not the wire rate: the ABR (`LiveCongestionController`) still cuts the
    /// live target on loss/RTT, so a constrained WAN never sees these bits.
    ///
    /// MOTION-SMOOTHNESS: frame SIZE is the dominant smoothness lever (HW A/B) — a LOWER
    /// `SLOPDESK_BPP` shrinks motion frames (smooth scroll, coarser DURING motion only — natural
    /// motion blur), while the crisp static refresh (`encodeLiveCrispKeyframe`) restores razor-sharp
    /// text the instant the screen goes still. The delta send-pace floor + budget-adaptive QP
    /// ceiling absorb the variance a denser budget adds, so 0.25 no longer buys judder on a clean
    /// link the way it did before those shipped.
    public static let bitsPerPixelPerFrame: Double = {
        if let s = ProcessInfo.processInfo.environment["SLOPDESK_BPP"], let v = Double(s), v > 0,
           v <= 1.0 { return v }
        return 0.25
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
