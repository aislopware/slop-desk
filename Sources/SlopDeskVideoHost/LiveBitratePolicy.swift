import CSlopDeskFFI
import Foundation
import SlopDeskVideoProtocol

/// The Swift face of `rust/slopdesk-video`'s `live_bitrate`, reached through the door of the same name.
///
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
/// The arithmetic is the crate's: separate multiplies (never fused) and half-away-from-zero
/// rounding, because the budget is what the encoder's QP ceiling is sized against and a contracted
/// multiply-add would move it by a bit on one machine and not another.
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
    ///
    /// The knob is read once, and PARSED by the door: a value outside `(0, 1]` is a typo rather than
    /// an intent, so it falls back to the default instead of being clamped.
    ///
    /// Read through ``EnvConfig`` (ProcessInfo → settings overlay), not off `ProcessInfo` directly.
    /// It WAS direct, which made this the one video knob a Settings write could not move: the value
    /// reached the sidecar, folded into the overlay, and was then read past. Nothing catches that by
    /// testing, because an empty overlay makes the two spellings byte-identical — which is exactly
    /// how the same bug survived in six governor knobs until 2026-08-22 (`FPSGovernor.swift`).
    public static let bitsPerPixelPerFrame: Double = {
        let raw = EnvConfig.string("SLOPDESK_BPP") ?? ""
        return Array(raw.utf8).withUnsafeBufferPointer { bytes in
            slopdesk_live_bitrate_bits_per_pixel(bytes.baseAddress, bytes.count)
        }
    }()

    /// Absolute lower bound so a tiny window never starves the encoder — the same floor
    /// `VideoEncoder.init` clamps to, spelled once, on the far side of the door.
    public static var minimumBitrate: Int { Int(slopdesk_live_bitrate_defaults().minimum_bitrate) }

    /// Resolution-aware target bitrate (bits/sec) for an encoder of `pixelWidth × pixelHeight` at
    /// `fps`. Never below `floor` (the configured `--bitrate`, so an explicit higher cap is honoured)
    /// and never below ``minimumBitrate``. Degenerate (zero/negative) dimensions and fps are
    /// clamped to 1.
    public static func targetBitrate(pixelWidth: Int, pixelHeight: Int, fps: Int, floor: Int) -> Int {
        Int(slopdesk_live_bitrate_target(
            Int64(pixelWidth), Int64(pixelHeight), Int64(fps), Int64(floor), bitsPerPixelPerFrame,
        ))
    }
}
