// The link-adaptive constant-QP law, as the Swift face of `rust/slopdesk-video`'s `qp_control`,
// reached through `rust/slopdesk-ffi`'s `rate_control` door.
//
// ## What is not here any more
//
// The sanitising that stops a hostile knob inverting the QP range, the seed clamp, the integer AIMD
// itself and the clean-streak bookkeeping behind it. All Rust's, in a crate that forbids `unsafe`.
//
// ## What stays, and why it has to
//
// WHERE the knobs come from. They resolve through ``EnvConfig`` — ProcessInfo env, then the settings
// overlay — so a GUI setting can beat an environment variable, and that overlay is Swift's. The door
// is handed the resolved text and parses it; it never reads an environment of its own.
//
// ## Why this crosses by value and not as a handle
//
// The owner keeps a `QPController` in a `var`, takes a copy out, folds a report into the copy and
// writes it back, and compares it against `nil`. A handle would make two of those copies alias one
// allocation behind the type system's back. So the fold crosses whole: config and state in, state
// out, nothing allocated on either side.

import CSlopDeskFFI
import SlopDeskVideoProtocol

/// Link-adaptive constant-QP controller: an integer AIMD driving the encoder's constant quantiser
/// from the link's own congestion verdict.
///
/// VideoToolbox's `AverageBitRate` VBR banks unused budget while idle, then slams the QP on the
/// frames after a post-idle burst — the "idle → hard-scroll → blur" clawback. Pinning a CONSTANT QP
/// per frame removes it; this keeps that constant adaptive. Value struct (`Equatable`), serialised
/// by the session actor.
///
/// NOTE: QP is INVERSE quality, so the AIMD senses flip against a bitrate controller — congestion
/// RAISES Q.
struct QPController: Equatable {
    /// The tuned defaults each knob falls back to, asked of the door rather than retyped.
    ///
    /// The four were hardware-validated together, so they are one table and `qp_control.rs` holds
    /// it. A copy here would agree until the day someone retunes `sharp` in Rust — and then this
    /// host would go on encoding at the old operating point with nothing to show for it: no build
    /// error, no failing test, just a different picture. That is the two-spellings shape
    /// `docs/55` §8 catalogues.
    private static let fallbacks = slopdesk_qp_config_default()

    /// Sharpest (lowest) QP on a clean link, from `SLOPDESK_QP_SHARP` — the HW-validated
    /// constant-QP value judged good enough; not sharper, to keep frame sizes and drops bounded on
    /// WiFi.
    static let qSharp: Int = envInt("SLOPDESK_QP_SHARP", Int(fallbacks.sharp), min: 1, max: 51)
    /// Coarsest (highest) QP under sustained congestion, from `SLOPDESK_QP_COARSE`.
    static let qCoarse: Int = envInt("SLOPDESK_QP_COARSE", Int(fallbacks.coarse), min: 1, max: 51)
    /// QP increase per congested report — coarsen fast — from `SLOPDESK_QP_UP_STEP`.
    static let upStep: Int = envInt("SLOPDESK_QP_UP_STEP", Int(fallbacks.up_step), min: 1, max: 50)
    /// Clean reports per one-QP sharpen — ease back slowly — from `SLOPDESK_QP_DOWN_INTERVAL`.
    static let downInterval: Int = envInt(
        "SLOPDESK_QP_DOWN_INTERVAL", Int(fallbacks.down_interval), min: 1, max: 10000,
    )

    /// Parse + CLAMP an int config value to `[min, max]`, falling back to `def`. The lookup resolves
    /// through ``EnvConfig`` (ProcessInfo env → overlay) instead of `ProcessInfo` directly, so a GUI
    /// setting can override it; with an EMPTY overlay `EnvConfig.string(key)` is byte-identical to
    /// `ProcessInfo.processInfo.environment[key]`, so this site — and the golden corpus that pins
    /// these defaults — is unaffected. The parse and the clamp are the door's; CLAMPING rather than
    /// rejecting is deliberate, and distinct from `LiveCongestionController`'s validate-then-default.
    static func envInt(_ key: String, _ def: Int, min lo: Int, max hi: Int) -> Int {
        let raw = EnvConfig.string(key)
        var text = raw ?? ""
        let answer = text.withUTF8 {
            slopdesk_qp_clamped_int(
                $0.baseAddress, $0.count, raw != nil, Int32(def), Int32(lo), Int32(hi),
            )
        }
        return Int(answer)
    }

    /// The sanitised knobs and the two numbers behind the next decision, exactly as they cross.
    private var state: SlopDeskQpController

    /// Production wiring: bounds from the env knobs, seeded at `seedQ` (clamped into the range).
    init(seedQ: Int) {
        self.init(
            qSharp: Self.qSharp, qCoarse: Self.qCoarse, upStep: Self.upStep,
            downInterval: Self.downInterval, seedQ: seedQ,
        )
    }

    /// Explicit bounds (production + tests). The door sanitises them and clamps the seed into the
    /// range that results, so a hostile value can never invert or escape it.
    init(qSharp: Int, qCoarse: Int, upStep: Int, downInterval: Int, seedQ: Int) {
        state = slopdesk_qp_new(
            SlopDeskQpConfig(
                sharp: Int32(clamping: qSharp), coarse: Int32(clamping: qCoarse),
                up_step: Int32(clamping: upStep), down_interval: Int32(clamping: downInterval),
            ),
            Int32(clamping: seedQ),
        )
    }

    /// The current constant QP.
    var q: Int { Int(state.q) }

    /// Folds one report's congestion verdict and returns the (possibly unchanged) new QP. Congested →
    /// coarsen fast toward `qCoarse`; clean → sharpen one step per `downInterval` clean reports.
    @discardableResult
    mutating func decide(congested: Bool) -> Int {
        state = slopdesk_qp_decide(state, congested)
        return Int(state.q)
    }

    /// Equality is by config AND state, as it was: two controllers that agree on the knobs but not
    /// on the streak will diverge on the next clean report. The C struct cannot synthesise this, so
    /// the six numbers are named — the same six the door folds over.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.q == rhs.state.q
            && lhs.state.clean_streak == rhs.state.clean_streak
            && lhs.state.config.sharp == rhs.state.config.sharp
            && lhs.state.config.coarse == rhs.state.config.coarse
            && lhs.state.config.up_step == rhs.state.config.up_step
            && lhs.state.config.down_interval == rhs.state.config.down_interval
    }
}
