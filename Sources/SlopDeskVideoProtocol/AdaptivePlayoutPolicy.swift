// Adaptive playout-delay policy for the client's deadline presentation pacer — sizes the
// jitter-absorption buffer to the LIVE measured network jitter instead of a fixed constant.
//
// Native-Swift port of the former `slopdesk-core::adaptive_playout` (the all-Swift migration
// deletes the Rust core + FFI boundary). A FIXED playout buffer is wrong across links — a clean LAN
// (tiny jitter) wastes latency while a jittery WAN underruns and stutters. This maps a measured
// jitter scalar to a target buffer `clamp(k·jitter + base, [floor, ceil])`, then steps toward it
// grow-fast / shrink-slow so a transient spike decays over several ticks (no latency ratchet).
//
// THE FMA TRAP: `k * jitter + base` is computed as a SEPARATE multiply then add — never a fused
// multiply-add — so the low bits match the reference exactly. Pure scalar arithmetic in the SECONDS
// domain; the public `stepMs` entry mirrors the old `aisd_adaptive_playout_step_ms` ABI (jitter in
// seconds; prev/shrink/base/floor/ceil in milliseconds; returns milliseconds).

/// The hysteretic playout-buffer law. The caller resolves the env knobs and passes them in, so this
/// stays deterministic; the Swift shell holds only the last value (`prevPlayoutMs`).
public enum AdaptivePlayoutPolicy {
    /// Coefficient on the measured jitter (slightly `< 1`); the RFC3550 mean-deviation underestimates
    /// the peak, but `+ base` and smoothing make `0.8` sufficient at the validated link.
    public static let defaultK = 0.8
    /// Constant floor term (seconds) added before the clamp — a near-zero-jitter cold start still
    /// seeds a real buffer (never present-on-arrival).
    public static let defaultBaseSeconds = 0.004
    /// Minimum playout (seconds). MUST stay `> 0` — a zero buffer exposes raw jitter to the eye.
    public static let defaultFloorSeconds = 0.004
    /// Maximum playout (seconds) — caps the latency a pathological link can add.
    public static let defaultCeilSeconds = 0.035

    /// The tunable shape of the playout law, all in the seconds domain. Built from the ms knobs with
    /// each clamped to a sane band and `ceil >= floor` guaranteed; a non-finite knob → its default.
    struct Config {
        let k: Double
        let baseSeconds: Double
        let floorSeconds: Double
        let ceilSeconds: Double

        init(k: Double, baseMs: Double, floorMs: Double, ceilMs: Double) {
            self.k = k.isFinite ? Self.clamp(k, 0.0, 4.0) : defaultK
            baseSeconds = baseMs.isFinite ? Self.clamp(baseMs / 1000.0, 0.0, 0.05) : defaultBaseSeconds
            let floor = floorMs.isFinite ? Self.clamp(floorMs / 1000.0, 0.001, 0.05) : defaultFloorSeconds
            floorSeconds = floor
            let ceilRaw = ceilMs.isFinite ? Self.clamp(ceilMs / 1000.0, 0.001, 0.2) : defaultCeilSeconds
            // `f64::max` (NaN-ignoring) — both operands finite here.
            ceilSeconds = Double.maximum(ceilRaw, floor)
        }

        /// Ordered clamp matching Rust `f64::clamp` (bounds are finite constants ⇒ `lo <= hi`).
        static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
            if value < lo { return lo }
            if value > hi { return hi }
            return value
        }
    }

    /// The TARGET playout (seconds) for a measured `jitterSeconds`: `clamp(k·jitter + base, [floor, ceil])`.
    /// A non-finite or negative jitter falls back to the floor (a bad sample must never inflate the buffer).
    static func targetSeconds(jitterSeconds: Double, config: Config) -> Double {
        if !jitterSeconds.isFinite || jitterSeconds < 0.0 {
            return config.floorSeconds
        }
        // keep mul+add separate — FMA breaks bit-exact parity
        let scaled = config.k * jitterSeconds
        let raw = scaled + config.baseSeconds
        return Config.clamp(raw, config.floorSeconds, config.ceilSeconds)
    }

    /// One hysteretic step toward the target (seconds): GROW immediately to a larger target, but
    /// SHRINK by at most `shrinkStepSeconds` per call. A non-finite `prev` re-seeds at the floor.
    static func stepSeconds(
        jitterSeconds: Double,
        prevSeconds: Double,
        shrinkStepSeconds: Double,
        config: Config,
    ) -> Double {
        let target = targetSeconds(jitterSeconds: jitterSeconds, config: config)
        let prev = prevSeconds.isFinite
            ? Config.clamp(prevSeconds, config.floorSeconds, config.ceilSeconds)
            : config.floorSeconds
        if target >= prev {
            return target // grow fast (also covers the cold start seeded at the floor)
        }
        let step = shrinkStepSeconds.isFinite ? Double.maximum(shrinkStepSeconds, 0.0) : 0.0
        return Double.maximum(prev - step, target) // shrink slow
    }

    /// One hysteretic step of the playout delay (milliseconds): maps live `jitterSeconds` to the
    /// target `clamp(k·jitter + base, [floor, ceil])` and steps `prevPlayoutMs` toward it — grow-fast,
    /// shrink-slow (≤ `shrinkStepMs` down per call). Mirrors the old `aisd_adaptive_playout_step_ms`.
    public static func stepMs(
        jitterSeconds: Double,
        prevPlayoutMs: Double,
        shrinkStepMs: Double,
        k: Double,
        baseMs: Double,
        floorMs: Double,
        ceilMs: Double,
    ) -> Double {
        let config = Config(k: k, baseMs: baseMs, floorMs: floorMs, ceilMs: ceilMs)
        let next = stepSeconds(
            jitterSeconds: jitterSeconds,
            prevSeconds: prevPlayoutMs / 1000.0,
            shrinkStepSeconds: shrinkStepMs / 1000.0,
            config: config,
        )
        return next * 1000.0
    }
}
