// The adaptive playout-delay law for the client's deadline presentation pacer, as the Swift face of
// `rust/slopdesk-video`'s `playout`, reached through `rust/slopdesk-ffi`'s `video_policy` door.
//
// A FIXED playout buffer is wrong across links — a clean LAN (tiny jitter) wastes latency while a
// jittery WAN underruns and stutters. The law maps a measured jitter scalar to a target buffer
// `clamp(k·jitter + base, [floor, ceil])`, then steps toward it grow-fast / shrink-slow so a
// transient spike decays over several ticks (no latency ratchet).
//
// THE FMA TRAP, and the reason the arithmetic is not spelled here twice: `k * jitter + base` must
// be a SEPARATE multiply then add — never fused — for the low bits to match the
// `aisd_adaptive_playout_step_ms` reference ABI. That, the ordered clamps, the NaN-ignoring maxima
// and the seconds/milliseconds domain change are all Rust's. This file holds the units at the edge
// and nothing else: jitter in seconds, every other knob and the answer in milliseconds.

import CSlopDeskFFI

/// The hysteretic playout-buffer law. The caller resolves the env knobs and passes them in, so this
/// stays deterministic; the Swift shell holds only the last value (`prevPlayoutMs`).
public enum AdaptivePlayoutPolicy {
    /// Coefficient on the measured jitter (slightly `< 1`); the RFC3550 mean-deviation
    /// underestimates the peak, but `+ base` and smoothing make `0.8` sufficient at the validated
    /// link.
    public static let defaultK = 0.8
    /// Constant floor term (seconds) added before the clamp — a near-zero-jitter cold start still
    /// seeds a real buffer (never present-on-arrival).
    public static let defaultBaseSeconds = 0.004
    /// Minimum playout (seconds). MUST stay `> 0` — a zero buffer exposes raw jitter to the eye.
    public static let defaultFloorSeconds = 0.004
    /// Maximum playout (seconds) — caps the latency a pathological link can add.
    public static let defaultCeilSeconds = 0.035

    /// One hysteretic step of the playout delay (milliseconds): maps live `jitterSeconds` to the
    /// target `clamp(k·jitter + base, [floor, ceil])` and steps `prevPlayoutMs` toward it —
    /// grow-fast, shrink-slow (≤ `shrinkStepMs` down per call).
    ///
    /// Every knob is clamped into its band on the far side and a non-finite one falls back to its
    /// default, so a missing or hostile environment variable cannot widen the buffer past its
    /// ceiling. Matches the `aisd_adaptive_playout_step_ms` ABI.
    public static func stepMs(
        jitterSeconds: Double,
        prevPlayoutMs: Double,
        shrinkStepMs: Double,
        k: Double,
        baseMs: Double,
        floorMs: Double,
        ceilMs: Double,
    ) -> Double {
        slopdesk_playout_step_ms(jitterSeconds, prevPlayoutMs, shrinkStepMs, k, baseMs, floorMs, ceilMs)
    }
}
