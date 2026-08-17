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
///
/// The five defaults below are ASKED FOR, not transcribed: each `SLOPDESK_PLAYOUT_*` knob needs a
/// fallback at the environment site, the pacer takes the same value as a default argument, and the
/// law itself falls back to it when a knob arrives non-finite. Spelled by hand that is one law
/// tuned in one place and applied by three.
public enum AdaptivePlayoutPolicy {
    /// Coefficient on the measured jitter, slightly `< 1`; the RFC3550 mean-deviation underestimates
    /// the peak, but `+ base` and the smoothing make it enough at the validated link.
    public static let defaultK = slopdesk_playout_default_ms(0)
    /// Constant term (ms) added before the clamp — a near-zero-jitter cold start still seeds a real
    /// buffer rather than presenting on arrival.
    public static let defaultBaseMs = slopdesk_playout_default_ms(1)
    /// Minimum playout (ms). Stays `> 0` on the far side — a zero buffer exposes raw jitter.
    public static let defaultFloorMs = slopdesk_playout_default_ms(2)
    /// Maximum playout (ms) — caps the latency a pathological link can add.
    public static let defaultCeilMs = slopdesk_playout_default_ms(3)
    /// How much of the buffer one recompute may give back (ms): the SHRINK half of the hysteresis.
    public static let defaultShrinkStepMs = slopdesk_playout_default_ms(4)

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
