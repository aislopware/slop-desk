//! Adaptive FEC — `Sources/SlopDeskVideoProtocol/AdaptiveFECPolicy.swift`.
//!
//! Two concerns that only look like one:
//!
//! * **the WIRE CODEC** — [`group_size`] and [`parity_count`] map the 3-bit on-wire tier index,
//!   carried in the spare bits of the fragment flags byte, to the group size and parity
//!   multiplicity BOTH ends must use. Host packetizer and client reassembler read the same tables;
//!   they are TOTAL over every `u8`, so a tier off a corrupt fragment can never trap.
//! * **the LOSS→TIER DECISION** — [`tier_for_loss`] and [`next_tier_state`], host-only, pick the
//!   tier from the EWMA loss with hysteresis, a one-step clamp, and a relax dwell.
//!
//! ## The signalling invariant
//!
//! Tier 0 means "use the endpoint's CONFIGURED default group size", NOT a hardcoded 5. Production
//! runs `k = 5` on both ends, so tier 0 is byte-identical to the pre-adaptive wire, and with the
//! adaptive gate off the host always sends tier 0 — the spare flag bits stay zero and every frame
//! is the same bytes it was before any of this existed.
//!
//! ## The wire tier numbering is NOT the redundancy order
//!
//! Tier 0 has to be the default group size for that byte-identity, so it sits in the MIDDLE of the
//! redundancy ladder. The decision code therefore works in an internal LEVEL (0 = least redundancy
//! … 4 = most) and translates at the edges. Getting these two orders confused is the single easiest
//! way to break this file, which is why the level maps are private and the tier maps are the only
//! public surface.
//!
//! Pinned by the `adaptiveGroupSize` and `adaptiveTier` golden vectors.

/// The default on-wire tier. Its flag bits are all zero, so a host that always sends it produces
/// the pre-adaptive wire byte for byte.
pub const DEFAULT_TIER: u8 = 0;

/// Parity tier: `m = 2`, the least overhead, for a clean link.
pub const PARITY_TIER_CLEAN: u8 = 5;
/// Parity tier: `m = 3`, the baseline.
pub const PARITY_TIER_NORMAL: u8 = 6;
/// Parity tier: `m = 5`, heavy recovery during a loss burst.
pub const PARITY_TIER_BURST: u8 = 7;

/// How many CONSECUTIVE relax-demanding reports must accumulate before the tier steps DOWN one
/// level. Escalation stays immediate.
///
/// Naive one-step-per-report relax flaps badly on a real 4G path: mobile loss arrives in BURSTS
/// seconds apart and the EWMA decays below the relax thresholds between them, so relax walks back
/// to OFF in about a second and every burst lands on an unprotected stream — measured at 224 tier
/// changes in one session, cycling OFF→g10→g5→g10→OFF every ~8 s with 118 unrecovered frames.
/// Requiring about twelve seconds of consecutively clean reports keeps g10 armed BETWEEN bursts
/// while a genuinely clean path still relaxes, just slower.
///
/// ⚠️ CADENCE-COUPLED: the host steps this once per client stats report, and that timer fires every
/// 50 ms — about 20/s, not the ~2/s an earlier version assumed. So twelve seconds is 240 reports.
/// If that cadence changes, re-derive: `RELAX_DWELL_REPORTS ≈ 12 s / report interval`.
pub const RELAX_DWELL_REPORTS: u32 = 240;

/// After a report carrying unrecovered loss, the relax dwell is DOUBLED for this many reports.
///
/// A report with unrecovered loss proves the CURRENT redundancy was insufficient, and relaxing soon
/// after is exactly the measured blip-every-2.6-seconds failure. The window is `2 × dwell` BY
/// CONSTRUCTION: a shorter one would close before a streak could reach the doubled dwell, reducing
/// the whole mechanism to a one-report delay.
pub const STICKY_RELAX_WINDOW_REPORTS: u32 = 2 * RELAX_DWELL_REPORTS;

/// Env-gated multi-loss Reed-Solomon activation — the `SLOPDESK_FEC_M` / `SLOPDESK_FEC_K` pair.
///
/// Default `m == 1` is the production XOR-equivalent, byte-identical wire. `m >= 2` activates a
/// true `[k + m, k]` code recovering up to `m` losses PER GROUP, which `m == 1` provably cannot.
///
/// **DEPLOY TOGETHER.** With `m > 1` the parity-fragment COUNT PER GROUP changes on the wire. Host
/// and client must read the SAME values and ship as one unit: a host emitting `m` shards to a
/// reassembler built for a different `m` mis-maps the parity boundary and silently fails to repair.
/// Tier 0 with `m == 1` stays the mixed-fleet interop baseline.
pub mod multi_loss {
    /// Lowest permitted parity-shard count.
    pub const M_MIN: usize = 1;
    /// Highest permitted parity-shard count. Eight is conservative — already heavy redundancy —
    /// and the GF(2^8) bound `k + m <= 255` is enforced jointly below.
    pub const M_MAX: usize = 8;
    /// Lowest permitted fixed data-group size. A one-data-shard group is degenerate.
    pub const K_MIN: usize = 2;
    /// Highest permitted fixed data-group size, well inside MTU-bound fragment counts.
    pub const K_MAX: usize = 64;
    /// The group size used when multi-loss is active but `SLOPDESK_FEC_K` is unset.
    pub const DEFAULT_K: usize = 5;

    /// PURE resolution of `SLOPDESK_FEC_M`: parse, default 1, clamp.
    ///
    /// A non-numeric or out-of-range value clamps to the nearest bound rather than failing — this
    /// runs at process start on both ends and must never be the thing that stops a session.
    #[must_use]
    pub fn resolve_parity_count(raw: Option<&str>) -> usize {
        let Some(parsed) = raw.and_then(|text| text.parse::<i64>().ok()) else {
            return 1;
        };
        let clamped = parsed.clamp(
            i64::try_from(M_MIN).unwrap_or(i64::MAX),
            i64::try_from(M_MAX).unwrap_or(i64::MAX),
        );
        usize::try_from(clamped).unwrap_or(M_MIN)
    }

    /// PURE resolution of `SLOPDESK_FEC_K`: parse, default [`DEFAULT_K`], clamp, then field-cap.
    ///
    /// The cap keeps `k + m <= 255` — the GF(2^8) field bound — for the resolved `m`. With `m == 1`
    /// it is inert, since `k <= 64` already satisfies it.
    #[must_use]
    pub fn resolve_group_size(raw_k: Option<&str>, raw_m: Option<&str>) -> usize {
        let m = resolve_parity_count(raw_m);
        let parsed = raw_k.and_then(|text| text.parse::<i64>().ok());
        let clamped = parsed.map_or(DEFAULT_K, |value| {
            let bounded = value.clamp(
                i64::try_from(K_MIN).unwrap_or(i64::MAX),
                i64::try_from(K_MAX).unwrap_or(i64::MAX),
            );
            usize::try_from(bounded).unwrap_or(K_MIN)
        });
        clamped.min(255 - m)
    }

    /// Whether multi-loss recovery is active for a resolved `m`.
    #[must_use]
    pub const fn is_active(parity_count: usize) -> bool {
        parity_count >= 2
    }
}

/// Maps a wire tier to the FEC group size both ends must use, or `None` for the OFF (no-parity)
/// tier.
///
/// TOTAL over every `u8`: the flags byte carries only three bits, but a corrupt fragment can
/// present any value and an unknown tier must fall back to the default, never trap.
///
/// | tier | group size |
/// | --- | --- |
/// | 0 | `default` — the default AND adaptive-medium slot; bits 3-5 all zero |
/// | 1 | `None` — OFF, overhead removed on a clean link |
/// | 2 | 10 — light, about 10% overhead |
/// | 3 | 3 — heavy, about 33% |
/// | 4 | 2 — severe, 50% |
/// | 5, 6, 7, anything else | `default` — reserved, so forward-compatible |
#[must_use]
pub const fn group_size(tier: u8, default_group_size: usize) -> Option<usize> {
    match tier {
        1 => None,
        2 => Some(10),
        3 => Some(3),
        4 => Some(2),
        _ => Some(default_group_size),
    }
}

/// Maps a wire tier to the parity-shards-per-group `m` for this frame.
///
/// TOTAL over every `u8`, same reason as [`group_size`]. With the production single-parity codec
/// (`default_m == 1`) EVERY tier resolves to 1, so the m-tier slots stay byte-identical and there
/// is no mixed-fleet hazard.
///
/// | tier | `m` |
/// | --- | --- |
/// | 1 (OFF) | 1 — no parity is sent, so `m` is moot; pinned to the byte-identical 1 |
/// | 5 / 6 / 7, only when `default_m >= 2` | 2 / 3 / 5 — the clean/normal/burst ladder |
/// | anything else | `default_m` |
#[must_use]
pub const fn parity_count(tier: u8, default_m: usize) -> usize {
    if tier == 1 {
        return 1;
    }
    if default_m >= 2 {
        match tier {
            PARITY_TIER_CLEAN => return 2,
            PARITY_TIER_NORMAL => return 3,
            PARITY_TIER_BURST => return 5,
            _ => {},
        }
    }
    default_m
}

/// The wire tier the host must stamp on EVERY frame, given the active scheme.
///
/// With multi-loss active the tier is FORCED to [`DEFAULT_TIER`], whose mapping resolves to the
/// configured group size — exactly `k`. That is not a style choice: the `m > 1` Cauchy matrix has
/// `k` columns and the codec clamps a per-call group to `min(g, k)`, so the dynamic tiers (g2, g3,
/// g10, OFF) would feed the decoder a window the matrix was never built for and silently fail to
/// repair.
///
/// The adaptive-`m` ladder is the exception: it only ever emits tiers 5/6/7, all of which map to
/// the default group size, so those are safe to pass straight through.
#[must_use]
pub const fn wire_tier(adaptive_tier: u8, adaptive_m_enabled: bool, multi_loss_active: bool) -> u8 {
    if adaptive_m_enabled {
        return adaptive_tier;
    }
    if multi_loss_active {
        DEFAULT_TIER
    } else {
        adaptive_tier
    }
}

/// Picks the next wire tier from the EWMA loss and the previous tier.
///
/// Hysteresis plus a strict one-level-per-call clamp: relaxation on a sustained clean link is
/// GRADUAL, and a loss spike never jumps multiple levels. Relaxation floors at level 1 (g10) unless
/// `allow_off`.
///
/// The floor is measured, not cautious. On the live FPT↔Viettel path — 169 s, baseline loss
/// 0.1–0.6% — letting relax reach OFF produced 158 tier transitions including 18 to OFF, 102
/// unrecovered frame losses (1.1%) against 186 FEC-recovered, and 65 client decode failures,
/// roughly one every 2.6 s, each a visible blip. On a nonzero-baseline-loss path OFF is never safe;
/// the dwell only slows the walk there, it does not stop it. `SLOPDESK_FEC_ALLOW_OFF=1` re-enables
/// it for a genuinely loss-free LAN, and the tier-1 WIRE mapping is untouched either way, so an
/// OFF-tier frame from an old or flagged host still decodes.
#[must_use]
pub fn tier_for_loss(loss: f64, previous_tier: u8, allow_off: bool) -> u8 {
    let current = level_for_tier(previous_tier);
    let target = target_level(loss, current).max(relax_floor_level(allow_off));
    let stepped = match target.cmp(&current) {
        core::cmp::Ordering::Greater => current + 1,
        core::cmp::Ordering::Less => current - 1,
        core::cmp::Ordering::Equal => current,
    };
    tier_for_level(stepped)
}

/// Tier-decision state for the dwell-gated step: the current wire tier, the count of consecutive
/// relax-demanding reports, and the sticky-relax countdown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TierState {
    /// The current wire tier.
    pub tier: u8,
    /// Consecutive relax-demanding reports so far.
    pub relax_streak: u32,
    /// Reports left in the doubled-dwell window; 0 = inactive. Re-armed by any report with
    /// unrecovered loss, decaying by one per report.
    pub sticky_relax_remaining: u32,
}

impl Default for TierState {
    fn default() -> Self {
        Self {
            tier: DEFAULT_TIER,
            relax_streak: 0,
            sticky_relax_remaining: 0,
        }
    }
}

impl TierState {
    /// Builds a state.
    #[must_use]
    pub const fn new(tier: u8, relax_streak: u32, sticky_relax_remaining: u32) -> Self {
        Self {
            tier,
            relax_streak,
            sticky_relax_remaining,
        }
    }
}

/// Dwell-gated tier step — the production entry point; [`tier_for_loss`] stays for tools and tests.
///
/// Escalation is an immediate one-step and resets the relax streak. Relaxation is counted across
/// consecutive relax-demanding reports and applied only when the streak reaches the EFFECTIVE
/// dwell, which is doubled while the sticky window from a recent unrecovered loss is open. Any
/// report that does not demand relaxation resets the streak, so a burst mid-dwell re-arms the full
/// wait.
#[must_use]
pub fn next_tier_state(
    loss: f64,
    state: TierState,
    dwell: u32,
    allow_off: bool,
    saw_unrecovered_loss: bool,
) -> TierState {
    let sticky = sticky_after(state.sticky_relax_remaining, saw_unrecovered_loss);
    let effective_dwell = effective_dwell(dwell, sticky);
    let current = level_for_tier(state.tier);
    let target = target_level(loss, current).max(relax_floor_level(allow_off));

    if target > current {
        return TierState::new(tier_for_level(current + 1), 0, sticky);
    }
    if target < current {
        let streak = state.relax_streak + 1;
        if streak >= effective_dwell.max(1) {
            return TierState::new(tier_for_level(current - 1), 0, sticky);
        }
        return TierState::new(state.tier, streak, sticky);
    }
    TierState::new(state.tier, 0, sticky)
}

/// Dwell-gated PARITY-tier step — the `m`-adaptive counterpart of [`next_tier_state`], over the
/// clean/normal/burst ladder (`m` = 2/3/5).
///
/// Same hysteresis, dwell and sticky-relax, with two differences that matter. The floor is the
/// CLEAN level, because this ladder has no OFF tier, so it takes no `allow_off`. And escalation
/// JUMPS straight to the demanded level rather than stepping — full parity by the next frame — with
/// a real dropped frame flooring the demand at NORMAL before the EWMA has even reacted.
#[must_use]
pub fn next_parity_tier_state(
    loss: f64,
    state: TierState,
    dwell: u32,
    saw_unrecovered_loss: bool,
) -> TierState {
    let sticky = sticky_after(state.sticky_relax_remaining, saw_unrecovered_loss);
    let effective_dwell = effective_dwell(dwell, sticky);
    let current = m_level_for_tier(state.tier);
    let demanded = m_target_level(loss, current);
    let target = if saw_unrecovered_loss {
        demanded.max(1)
    } else {
        demanded
    };

    if target > current {
        return TierState::new(tier_for_m_level(target), 0, sticky);
    }
    if target < current {
        let streak = state.relax_streak + 1;
        if streak >= effective_dwell.max(1) {
            return TierState::new(tier_for_m_level(current - 1), 0, sticky);
        }
        return TierState::new(state.tier, streak, sticky);
    }
    TierState::new(state.tier, 0, sticky)
}

const fn sticky_after(remaining: u32, saw_unrecovered_loss: bool) -> u32 {
    if saw_unrecovered_loss {
        STICKY_RELAX_WINDOW_REPORTS
    } else {
        remaining.saturating_sub(1)
    }
}

const fn effective_dwell(dwell: u32, sticky: u32) -> u32 {
    if sticky > 0 {
        dwell.saturating_mul(2)
    } else {
        dwell
    }
}

/// The lowest redundancy LEVEL the relax path may land on. Escalation is unaffected; it only ever
/// raises the level.
const fn relax_floor_level(allow_off: bool) -> usize {
    if allow_off { 0 } else { 1 }
}

/// Internal redundancy LEVEL, monotonic in loss: 0 = OFF, 1 = g10, 2 = g5 (the default), 3 = g3,
/// 4 = g2.
const fn level_for_tier(tier: u8) -> usize {
    match tier {
        1 => 0,
        2 => 1,
        3 => 3,
        4 => 4,
        // Tier 0 and every reserved tier are the default/g5 level.
        _ => 2,
    }
}

const fn tier_for_level(level: usize) -> u8 {
    match level {
        0 => 1,
        1 => 2,
        3 => 3,
        4 => 4,
        // Level 2 and any clamp are the default tier.
        _ => 0,
    }
}

/// The redundancy level the loss demands, given the current level.
///
/// Hysteretic: asymmetric up and down thresholds create a dead-band, so a loss oscillating around a
/// boundary does not flap. Up at ≥0.005 → L1, ≥0.02 → L2, ≥0.05 → L3, ≥0.10 → L4; down at <0.002 →
/// L0, <0.012 → L1, <0.035 → L2, <0.08 → L3.
fn target_level(loss: f64, current: usize) -> usize {
    let up_level = level_from_thresholds(loss, &[0.005, 0.02, 0.05, 0.10]);
    let down_level = level_from_thresholds(loss, &[0.002, 0.012, 0.035, 0.08]);

    if up_level > current {
        up_level
    } else if down_level < current {
        down_level
    } else {
        current
    }
}

/// How many of `thresholds` — ascending — `loss` has reached. A ladder written as its own rungs:
/// the count IS the level, so an up-ladder and a down-ladder differ only in the numbers they carry.
fn level_from_thresholds(loss: f64, thresholds: &[f64]) -> usize {
    thresholds.iter().filter(|&&threshold| loss >= threshold).count()
}

/// Internal level for the parity-count ladder: 0 = clean (`m` 2, tier 5), 1 = normal (`m` 3, tier
/// 6), 2 = burst (`m` 5, tier 7). Any other tier — a corrupt read, or a group-size tier — maps to
/// the NORMAL baseline.
const fn m_level_for_tier(tier: u8) -> usize {
    match tier {
        PARITY_TIER_CLEAN => 0,
        PARITY_TIER_BURST => 2,
        _ => 1,
    }
}

const fn tier_for_m_level(level: usize) -> u8 {
    match level {
        0 => PARITY_TIER_CLEAN,
        2 => PARITY_TIER_BURST,
        _ => PARITY_TIER_NORMAL,
    }
}

/// The parity level the loss demands. Up at ≥0.005 → L1, ≥0.03 → L2; down at <0.002 → L0,
/// <0.02 → L1.
fn m_target_level(loss: f64, current: usize) -> usize {
    let up_level = level_from_thresholds(loss, &[0.005, 0.03]);
    let down_level = level_from_thresholds(loss, &[0.002, 0.02]);

    if up_level > current {
        up_level
    } else if down_level < current {
        down_level
    } else {
        current
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_TIER, PARITY_TIER_BURST, PARITY_TIER_CLEAN, PARITY_TIER_NORMAL, RELAX_DWELL_REPORTS,
        STICKY_RELAX_WINDOW_REPORTS, TierState, group_size, next_parity_tier_state, next_tier_state,
        parity_count, tier_for_loss, wire_tier,
    };
    use crate::adaptive_fec::multi_loss;

    #[test]
    fn the_group_size_table_is_total_over_every_byte() {
        for tier in 0..=u8::MAX {
            let answer = group_size(tier, 5);
            let expected = match tier {
                1 => None,
                2 => Some(10),
                3 => Some(3),
                4 => Some(2),
                _ => Some(5),
            };
            assert_eq!(answer, expected, "tier {tier}");
        }
    }

    #[test]
    fn every_tier_resolves_to_one_on_the_production_single_parity_codec() {
        // The mixed-fleet guarantee: with `default_m == 1` the m-tiers must be inert.
        for tier in 0..=u8::MAX {
            assert_eq!(parity_count(tier, 1), 1, "tier {tier}");
        }
    }

    #[test]
    fn the_m_ladder_only_wakes_up_on_a_multi_loss_codec() {
        assert_eq!(parity_count(PARITY_TIER_CLEAN, 3), 2);
        assert_eq!(parity_count(PARITY_TIER_NORMAL, 3), 3);
        assert_eq!(parity_count(PARITY_TIER_BURST, 3), 5);
        assert_eq!(parity_count(1, 3), 1, "the OFF tier pins to the byte-identical 1");
        assert_eq!(parity_count(0, 3), 3, "every other tier is the codec's own m");
    }

    #[test]
    fn multi_loss_forces_tier_zero_because_the_cauchy_matrix_has_exactly_k_columns() {
        assert_eq!(wire_tier(4, false, true), DEFAULT_TIER);
        assert_eq!(
            wire_tier(4, false, false),
            4,
            "single parity passes the tier through"
        );
        assert_eq!(wire_tier(PARITY_TIER_BURST, true, true), PARITY_TIER_BURST);
    }

    #[test]
    fn the_env_resolvers_clamp_rather_than_fail() {
        assert_eq!(multi_loss::resolve_parity_count(None), 1);
        assert_eq!(multi_loss::resolve_parity_count(Some("banana")), 1);
        assert_eq!(multi_loss::resolve_parity_count(Some("0")), multi_loss::M_MIN);
        assert_eq!(multi_loss::resolve_parity_count(Some("999")), multi_loss::M_MAX);
        assert_eq!(multi_loss::resolve_parity_count(Some("3")), 3);

        assert_eq!(multi_loss::resolve_group_size(None, None), multi_loss::DEFAULT_K);
        assert_eq!(multi_loss::resolve_group_size(Some("1"), None), multi_loss::K_MIN);
        assert_eq!(
            multi_loss::resolve_group_size(Some("999"), None),
            multi_loss::K_MAX
        );
        assert_eq!(multi_loss::resolve_group_size(Some("7"), Some("3")), 7);
        assert!(!multi_loss::is_active(1));
        assert!(multi_loss::is_active(2));
    }

    #[test]
    fn the_ladder_never_moves_more_than_one_level_per_call() {
        // A loss spike from the calmest tier must not jump to the most redundant one.
        let after_spike = tier_for_loss(0.9, 2, true);
        assert_eq!(
            after_spike, 0,
            "OFF(1) → g10(2) → g5(0): one step, landing on g10's successor"
        );
        let two_steps = tier_for_loss(0.9, after_spike, true);
        assert_eq!(two_steps, 3);
    }

    #[test]
    fn the_relax_path_floors_at_g10_unless_the_escape_hatch_is_set() {
        // From g10 (tier 2) on a perfectly clean link.
        assert_eq!(tier_for_loss(0.0, 2, false), 2, "the floor holds");
        assert_eq!(tier_for_loss(0.0, 2, true), 1, "the hatch reaches OFF");
    }

    #[test]
    fn a_preexisting_off_state_steps_up_when_the_floor_is_active() {
        assert_eq!(
            tier_for_loss(0.0, 1, false),
            2,
            "OFF is above the floor, so it climbs to g10"
        );
    }

    #[test]
    fn the_dead_band_holds_a_loss_that_oscillates_around_a_boundary() {
        // 0.015 is above the L1 down-threshold and below the L2 up-threshold from level 2.
        assert_eq!(tier_for_loss(0.015, DEFAULT_TIER, true), DEFAULT_TIER);
    }

    #[test]
    fn relaxation_waits_out_the_dwell_while_escalation_does_not() {
        let start = TierState::new(DEFAULT_TIER, 0, 0);
        let mut state = start;
        for report in 1..4 {
            state = next_tier_state(0.0, state, 4, true, false);
            assert_eq!(state.tier, DEFAULT_TIER, "report {report} must still be waiting");
            assert_eq!(state.relax_streak, report);
        }
        state = next_tier_state(0.0, state, 4, true, false);
        assert_eq!(
            state.tier, 2,
            "the fourth consecutive clean report steps down to g10"
        );
        assert_eq!(state.relax_streak, 0);

        // Escalation ignores the dwell entirely.
        let escalated = next_tier_state(0.9, start, 4, true, false);
        assert_eq!(escalated.tier, 3);
    }

    #[test]
    fn a_burst_mid_dwell_rearms_the_full_wait() {
        let mut state = TierState::new(DEFAULT_TIER, 0, 0);
        state = next_tier_state(0.0, state, 4, true, false);
        assert_eq!(state.relax_streak, 1);
        // A hold-demanding report resets the streak.
        state = next_tier_state(0.015, state, 4, true, false);
        assert_eq!(state.relax_streak, 0, "the wait starts over");
    }

    #[test]
    fn an_unrecovered_loss_doubles_the_dwell_for_the_sticky_window() {
        // The baseline: at dwell 2 with no sticky window, the SECOND clean report steps down.
        let mut plain = TierState::new(DEFAULT_TIER, 0, 0);
        plain = next_tier_state(0.0, plain, 2, true, false);
        assert_eq!(plain.tier, DEFAULT_TIER);
        plain = next_tier_state(0.0, plain, 2, true, false);
        assert_eq!(plain.tier, 2, "two reports are the undoubled dwell");

        // The same walk, but the first report also saw an unrecovered loss. That report counts
        // toward the streak AND arms the window, so the dwell it is measured against is 4.
        let mut state = next_tier_state(0.0, TierState::new(DEFAULT_TIER, 0, 0), 2, true, true);
        assert_eq!(state.sticky_relax_remaining, STICKY_RELAX_WINDOW_REPORTS);
        assert_eq!(state.relax_streak, 1);
        for report in 2..=3_u32 {
            state = next_tier_state(0.0, state, 2, true, false);
            assert_eq!(
                state.tier, DEFAULT_TIER,
                "report {report} is still inside the doubled dwell"
            );
            assert_eq!(state.relax_streak, report);
        }
        state = next_tier_state(0.0, state, 2, true, false);
        assert_eq!(state.tier, 2, "and it steps on the fourth");
    }

    #[test]
    fn the_sticky_window_decays_one_report_at_a_time() {
        let mut state = TierState::new(DEFAULT_TIER, 0, 3);
        state = next_tier_state(0.015, state, 4, true, false);
        assert_eq!(state.sticky_relax_remaining, 2);
        state = next_tier_state(0.015, state, 4, true, false);
        assert_eq!(state.sticky_relax_remaining, 1);
        state = next_tier_state(0.015, state, 4, true, false);
        assert_eq!(state.sticky_relax_remaining, 0);
        state = next_tier_state(0.015, state, 4, true, false);
        assert_eq!(
            state.sticky_relax_remaining, 0,
            "and it stays there rather than underflowing"
        );
    }

    #[test]
    fn the_parity_ladder_jumps_to_the_demanded_level_instead_of_stepping() {
        let clean = TierState::new(PARITY_TIER_CLEAN, 0, 0);
        let jumped = next_parity_tier_state(0.5, clean, 4, false);
        assert_eq!(jumped.tier, PARITY_TIER_BURST, "full parity by the next frame");
    }

    #[test]
    fn a_dropped_frame_floors_the_parity_demand_at_normal_before_the_ewma_reacts() {
        let clean = TierState::new(PARITY_TIER_CLEAN, 0, 0);
        let attacked = next_parity_tier_state(0.0, clean, 4, true);
        assert_eq!(attacked.tier, PARITY_TIER_NORMAL);
    }

    #[test]
    fn the_parity_ladder_floors_at_clean_and_has_no_off() {
        let mut state = TierState::new(PARITY_TIER_CLEAN, 0, 0);
        for _ in 0..10 {
            state = next_parity_tier_state(0.0, state, 1, false);
        }
        assert_eq!(state.tier, PARITY_TIER_CLEAN, "there is nothing below clean");
    }

    #[test]
    fn an_unknown_tier_reads_as_the_normal_parity_baseline() {
        let stray = TierState::new(200, 0, 0);
        // Level 1 already, and a loss inside the dead-band holds it there.
        assert_eq!(next_parity_tier_state(0.01, stray, 4, false).tier, 200);
        // A demand above the baseline moves it onto a real tier.
        assert_eq!(
            next_parity_tier_state(0.5, stray, 4, false).tier,
            PARITY_TIER_BURST
        );
    }

    #[test]
    fn the_dwell_constants_keep_their_derived_relationship() {
        assert_eq!(STICKY_RELAX_WINDOW_REPORTS, 2 * RELAX_DWELL_REPORTS);
        assert_eq!(RELAX_DWELL_REPORTS, 240, "12 s at the 50 ms report cadence");
    }
}
