//! Adaptive FEC (WF-4) — a port of Swift `AdaptiveFECPolicy`.
//!
//! Two PURE concerns:
//!  * **wire codec** — [`group_size`] maps a 3-bit on-wire tier to the group size both
//!    ends must use; used by the host packetizer AND the client reassembler.
//!  * **loss→tier decision** (host only) — [`tier`] / [`next_tier_state`] pick the tier
//!    from the EWMA loss with hysteresis, a one-step-per-call clamp, a relax dwell, and
//!    a sticky-relax window after an unrecovered loss.
//!
//! Tier 0 means "use the endpoint's configured default group size" (NOT a hardcoded 5)
//! and its flag bits are all-zero, so an unflagged host is byte-identical to today.

/// The default on-wire tier. Routes to the endpoint's configured `fec.group_size()` on
/// both ends; its flag bits are all-zero.
pub const DEFAULT_TIER: u8 = 0;

/// How many consecutive relax-demanding reports must accumulate before the tier steps
/// DOWN one level (escalation stays immediate). ~12s at the ~2/s netstats cadence.
pub const RELAX_DWELL_REPORTS: i32 = 24;

/// After any report carrying unrecovered loss, the relax dwell is DOUBLED for this many
/// reports. `2 × dwell` by construction (a shorter window could never gate a streak).
pub const STICKY_RELAX_WINDOW_REPORTS: i32 = 2 * RELAX_DWELL_REPORTS;

/// Maps a wire tier index to the FEC group size both ends must use, or `None` for the
/// OFF (no-parity) tier.
///
/// TOTAL over every `u8` — a malformed tier off a corrupt fragment
/// can never trap; unknown indices fall back to `default_group_size`.
///
/// * tier 0 → `default` (g5 in prod) — flag bits 3-5 = 0.
/// * tier 1 → `None` (OFF, no parity).
/// * tier 2 → 10 (light, ~10%).
/// * tier 3 → 3 (heavy, ~33%).
/// * tier 4 → 2 (severe, 50%).
/// * tier 5,6,7 and any other → `default` (reserved → safe, forward-compatible).
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

/// Pure resolution of the OFF-tier escape hatch (`AISLOPDESK_FEC_ALLOW_OFF=1`), testable
/// without process state.
#[must_use]
pub fn allow_off_tier(env_value: Option<&str>) -> bool {
    env_value == Some("1")
}

/// Reads the OFF-tier escape hatch from the live process environment.
#[must_use]
pub fn allow_off_tier_from_env() -> bool {
    allow_off_tier(std::env::var("AISLOPDESK_FEC_ALLOW_OFF").ok().as_deref())
}

/// Internal redundancy LEVEL (0 = least redundancy … 4 = most): 0=OFF, 1=g10, 2=g5
/// (default), 3=g3, 4=g2. The wire tier numbering is NOT the redundancy order (tier 0
/// must be g5 for byte-identity), so these maps translate between them.
#[allow(clippy::match_same_arms)] // explicit documentary mapping (mirrors the Swift table).
const fn level_for_tier(tier: u8) -> i32 {
    match tier {
        1 => 0, // OFF
        2 => 1, // g10
        0 => 2, // g5 (default)
        3 => 3, // g3
        4 => 4, // g2
        _ => 2, // reserved → default/g5 level
    }
}

#[allow(clippy::match_same_arms)] // explicit documentary mapping (mirrors the Swift table).
const fn tier_for_level(level: i32) -> u8 {
    match level {
        0 => 1, // OFF
        1 => 2, // g10
        2 => 0, // g5 (default)
        3 => 3, // g3
        4 => 4, // g2
        _ => 0, // clamp → default
    }
}

#[allow(clippy::bool_to_int_with_if)] // explicit form documents the floor LEVELS, not a cast.
const fn relax_floor_level(allow_off: bool) -> i32 {
    if allow_off {
        0
    } else {
        1
    }
}

/// The redundancy level the loss demands, given the current level. Hysteretic:
/// asymmetric up/down thresholds create a dead-band so a loss oscillating around a
/// boundary does not flap the tier.
#[allow(clippy::bool_to_int_with_if)] // a threshold LADDER reads clearer than a cast on the tail arms.
fn target_level(loss: f64, current: i32) -> i32 {
    let up_level = if loss >= 0.10 {
        4
    } else if loss >= 0.05 {
        3
    } else if loss >= 0.02 {
        2
    } else if loss >= 0.005 {
        1
    } else {
        0
    };

    let down_level = if loss < 0.002 {
        0
    } else if loss < 0.012 {
        1
    } else if loss < 0.035 {
        2
    } else if loss < 0.08 {
        3
    } else {
        4
    };

    if up_level > current {
        up_level // loss has risen → demand more redundancy
    } else if down_level < current {
        down_level // loss low enough → relax
    } else {
        current // dead-band → hold
    }
}

/// Picks the next wire tier from the EWMA loss and the previous tier, with hysteresis
/// and a strict one-level-per-call clamp (anti-flap).
///
/// Relaxation floors at level 1 (g10)
/// unless `allow_off`. (The plain decider; production uses [`next_tier_state`].)
#[must_use]
pub fn tier(loss: f64, previous_tier: u8, allow_off: bool) -> u8 {
    let current = level_for_tier(previous_tier);
    let target = target_level(loss, current).max(relax_floor_level(allow_off));
    let stepped = match target.cmp(&current) {
        std::cmp::Ordering::Greater => current + 1,
        std::cmp::Ordering::Less => current - 1,
        std::cmp::Ordering::Equal => current,
    };
    tier_for_level(stepped)
}

/// Tier decision state for the dwell-gated variant: the current wire tier, the count of
/// consecutive relax-demanding reports, and the sticky-relax countdown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TierState {
    /// Current wire tier.
    pub tier: u8,
    /// Consecutive reports that demanded relaxation.
    pub relax_streak: i32,
    /// Reports remaining in the sticky-relax (doubled-dwell) window; 0 = inactive.
    pub sticky_relax_remaining: i32,
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
    /// Builds an explicit tier state.
    #[must_use]
    pub const fn new(tier: u8, relax_streak: i32, sticky_relax_remaining: i32) -> Self {
        Self {
            tier,
            relax_streak,
            sticky_relax_remaining,
        }
    }
}

/// Dwell-gated tier step — the production entry point.
///
/// Escalation is immediate (one step,
/// resets the relax streak); relaxation is counted across consecutive relax-demanding
/// reports and applied only when the streak reaches the effective dwell (doubled while a
/// sticky window from a recent unrecovered loss is open). Any non-relax report resets the
/// streak. Relaxation floors at level 1 (g10) unless `allow_off`.
#[must_use]
pub fn next_tier_state(
    loss: f64,
    state: TierState,
    dwell: i32,
    allow_off: bool,
    saw_unrecovered_loss: bool,
) -> TierState {
    let sticky = if saw_unrecovered_loss {
        STICKY_RELAX_WINDOW_REPORTS
    } else {
        (state.sticky_relax_remaining - 1).max(0)
    };
    let effective_dwell = if sticky > 0 { 2 * dwell } else { dwell };
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_size_wire_table() {
        assert_eq!(group_size(0, 5), Some(5));
        assert_eq!(group_size(1, 5), None);
        assert_eq!(group_size(2, 5), Some(10));
        assert_eq!(group_size(3, 5), Some(3));
        assert_eq!(group_size(4, 5), Some(2));
        // reserved + any other → default
        assert_eq!(group_size(5, 5), Some(5));
        assert_eq!(group_size(200, 7), Some(7));
    }

    #[test]
    fn escalation_is_immediate_one_step() {
        // From tier 0 (level 2 = g5), a 10% loss demands level 4; one step → level 3 = tier 3.
        assert_eq!(tier(0.10, 0, false), 3);
    }

    #[test]
    fn relax_floors_at_g10_by_default() {
        // From tier 2 (level 1 = g10) on a clean link, default floor blocks OFF → stays g10.
        assert_eq!(tier(0.0, 2, false), 2);
        // With the escape hatch, it can relax to OFF (level 0 = tier 1).
        assert_eq!(tier(0.0, 2, true), 1);
    }

    #[test]
    fn dead_band_holds() {
        // tier 0 = level 2; a loss inside the dead-band (0.012..0.02) holds.
        assert_eq!(tier(0.015, 0, false), 0);
    }

    #[test]
    fn dwell_gates_relaxation() {
        // Start at g5 (tier 0, level 2). Clean reports should relax to g10 (tier 2) only
        // after RELAX_DWELL_REPORTS consecutive relax-demanding reports.
        let mut state = TierState::default();
        for _ in 0..(RELAX_DWELL_REPORTS - 1) {
            state = next_tier_state(0.0, state, RELAX_DWELL_REPORTS, false, false);
            assert_eq!(state.tier, 0, "should still hold before dwell elapses");
        }
        state = next_tier_state(0.0, state, RELAX_DWELL_REPORTS, false, false);
        assert_eq!(state.tier, 2, "relaxes one level after dwell");
    }

    #[test]
    fn unrecovered_loss_doubles_dwell() {
        let armed = next_tier_state(0.0, TierState::default(), RELAX_DWELL_REPORTS, false, true);
        assert_eq!(armed.sticky_relax_remaining, STICKY_RELAX_WINDOW_REPORTS);
    }

    #[test]
    fn escalation_resets_relax_streak() {
        let mut state = TierState::new(0, 10, 0);
        // a report demanding escalation resets the streak to 0.
        state = next_tier_state(0.10, state, RELAX_DWELL_REPORTS, false, false);
        assert_eq!(state.relax_streak, 0);
        assert_eq!(state.tier, 3);
    }
}
