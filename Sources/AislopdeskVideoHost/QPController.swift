import AislopdeskVideoProtocol
import Foundation

/// Link-adaptive constant-QP controller (own rate control, 2026-06-18) — native Swift, the single
/// source of truth for the integer AIMD-on-QP law.
///
/// VideoToolbox's `AverageBitRate` VBR banks unused budget while idle, then slams the QP on the frames
/// after a post-idle burst (the "idle → hard-scroll → blur" clawback). Pinning a CONSTANT QP per frame
/// removes the clawback; this small integer AIMD drives that constant QP from the link's own congestion
/// verdict so it still adapts: congested → coarsen fast (smaller frames, fit the degraded link); clean
/// → sharpen one step per interval. Value struct (`Equatable`), serialised by the session actor.
///
/// NOTE: QP is INVERSE quality, so the AIMD senses flip vs a bitrate controller — congestion RAISES Q.
struct QPController: Equatable {
    /// Sharpest (lowest) QP on a clean link. `AISLOPDESK_QP_SHARP` (default 26 — the HW-validated
    /// "khá là ok" constant-QP value; not sharper, to keep frame sizes / drops bounded on WiFi).
    static let qSharp: Int = envInt("AISLOPDESK_QP_SHARP", 26, min: 1, max: 51)
    /// Coarsest (highest) QP under sustained congestion. `AISLOPDESK_QP_COARSE` (default 40).
    static let qCoarse: Int = envInt("AISLOPDESK_QP_COARSE", 40, min: 1, max: 51)
    /// QP increase per congested report (coarsen fast). `AISLOPDESK_QP_UP_STEP` (default 3).
    static let upStep: Int = envInt("AISLOPDESK_QP_UP_STEP", 3, min: 1, max: 50)
    /// Clean reports per one-QP sharpen (ease back slowly). `AISLOPDESK_QP_DOWN_INTERVAL` (default 4).
    static let downInterval: Int = envInt("AISLOPDESK_QP_DOWN_INTERVAL", 4, min: 1, max: 10000)

    /// Parse + CLAMP an int config value to `[min, max]`, falling back to `def`. Resolves through
    /// ``EnvConfig`` (ProcessInfo env → overlay) instead of `ProcessInfo` directly — W12 — so a GUI
    /// setting can override it. With an EMPTY overlay `EnvConfig.string(key)` is byte-identical to the
    /// previous `ProcessInfo.processInfo.environment[key]`, so this site (and the golden corpus that
    /// pins these defaults) is unchanged. NOTE: this site CLAMPS out-of-range values (it does not reject
    /// them), distinct from `LiveCongestionController`'s validate-then-default — that law stays here.
    static func envInt(_ key: String, _ def: Int, min lo: Int, max hi: Int) -> Int {
        guard let s = EnvConfig.string(key), let v = Int(s) else { return def }
        return Swift.max(lo, Swift.min(hi, v))
    }

    // The sanitized config knobs (a hostile value can never invert the QP range — see `init`).
    // Stored verbatim — equality is by config+state.
    private let qSharpV: Int
    private let qCoarseV: Int
    private let upStepV: Int
    private let downIntervalV: Int
    /// The current constant QP.
    private(set) var q: Int
    /// The clean-report streak persisted between steps.
    private var cleanStreak: Int

    /// Production wiring: bounds from the env knobs, seeded at `seedQ` (clamped into the range).
    init(seedQ: Int) {
        self.init(
            qSharp: Self.qSharp, qCoarse: Self.qCoarse, upStep: Self.upStep,
            downInterval: Self.downInterval, seedQ: seedQ,
        )
    }

    /// Explicit bounds (production + tests). Sanitises (`QPs into 1...51`, `qSharp <= qCoarse`,
    /// `upStep >= 1`, `downInterval >= 1`) and clamps the seed into `[qSharp, qCoarse]`. Mirrors
    /// `QpConfig::sanitized` + `QpController::new` exactly.
    init(qSharp: Int, qCoarse: Int, upStep: Int, downInterval: Int, seedQ: Int) {
        // sanitize: a hostile env value can never invert or escape the QP range.
        let sharp = Swift.max(1, Swift.min(51, qSharp))
        let coarse = Swift.max(sharp, Swift.min(51, qCoarse))
        qSharpV = sharp
        qCoarseV = coarse
        upStepV = Swift.max(1, upStep)
        downIntervalV = Swift.max(1, downInterval)
        // seed clamped into [qSharp, qCoarse].
        q = Swift.max(sharp, Swift.min(coarse, seedQ))
        cleanStreak = 0
    }

    /// Folds one report's congestion verdict and returns the (possibly unchanged) new QP. Congested →
    /// coarsen fast toward `qCoarse`; clean → sharpen one step per `downInterval` clean reports.
    /// Native integer AIMD — mirrors `QpController::decide` exactly.
    @discardableResult
    mutating func decide(congested: Bool) -> Int {
        if congested {
            q = Swift.min(q + upStepV, qCoarseV)
            cleanStreak = 0
        } else {
            cleanStreak += 1
            if cleanStreak >= downIntervalV {
                q = Swift.max(q - 1, qSharpV)
                cleanStreak = 0
            }
        }
        return q
    }
}
