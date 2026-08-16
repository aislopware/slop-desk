//! Recognising a two-finger "swipe between pages" flick in the forwarded scroll stream, and
//! answering with the history-navigation direction it should be TRANSLATED into.
//!
//! ## Why a translation exists at all
//!
//! A synthetic phased scroll can NEVER trigger a browser's own swipe-back. Chromium's history
//! swiper needs real touch data on the trackpad path, or routes into the Magic-Mouse track-swipe
//! API, and both reject posted scroll events; Safari behaves the same, probe-verified across six
//! field variants — phases, scroll count, may-begin, momentum tail, and gesture brackets. So the
//! host watches the stream it is already injecting and fires the universal keyboard equivalent.
//!
//! ## Three decision points, matching how real page-swipes distribute their energy
//!
//! 1. **Lift.** A decisive flick that spent enough travel on glass fires immediately. The
//!    completed-gesture shape is what gates out content pans: a navigation flick is short and
//!    decisively horizontal, while a horizontal CONTENT pan runs longer or drifts vertically.
//! 2. **Momentum confirmation.** The harder the flick, the SHORTER the fingers stay on glass — most
//!    of a sharp flick's displacement arrives in the momentum tail, so an on-glass-only recogniser
//!    rejects exactly the most emphatic swipes. A lift that was dominant and quick but short of the
//!    fire bar therefore ARMS a brief coast window, and the momentum deltas confirm or expire it.
//!    Momentum can only ever CONFIRM what the on-glass segment armed, so the tails of ordinary pans
//!    still cannot navigate.
//! 3. **The slow deliberate swipe.** Natively a page-swipe works at ANY speed — the peel tracks the
//!    fingers and commits at release — so duration alone must not disqualify. Past the flick window
//!    the lift demands COMMITMENT instead of speed, as a graduated SURFACE rather than steps (see
//!    [`slow_required_travel`]). Page content state — is the content at its horizontal edge, can it
//!    scroll at all — is what native browsers arbitrate with, and that stays invisible remotely, so
//!    commitment is the only proxy left. Slow gestures never ARM: momentum confirmation is a flick
//!    mechanism, and a slow lift has no tail.
//!
//! ## Loss tolerance
//!
//! The input channel is fire-and-forget UDP and scroll datagrams are sent once, so a lost `began`
//! is synthesised from the first continuous `changed`, and a lost `ended` from the first momentum
//! event — momentum means the fingers demonstrably lifted. The channel can also DUPLICATE and
//! REORDER, hence two hardenings: a post-fire REFRACTORY window, without which a reordered on-glass
//! straggler would form a fresh candidate that the gesture's own momentum tail fires AGAIN; and the
//! rule that a synthesised candidate never ARMS momentum confirmation.

use std::cmp::Ordering;
use std::collections::BTreeSet;

use crate::swipe_nav::SwipeDirection;

/// Horizontal dominance: the horizontal travel must be at least this multiple of the vertical.
///
/// Cuts diagonal pans, and is re-checked at momentum confirmation over the combined sums, so a
/// coast that curves vertical dies too.
pub const DOMINANCE: f64 = 3.0;

/// The dominance the slow tier asks for.
///
/// Stricter than the flick's: over a long gesture the hand has time to wander, and a
/// two-dimensional content exploration does wander, while a deliberate slow navigation swipe is a
/// clean line.
pub const SLOW_DOMINANCE: f64 = 4.0;

/// The slow tier's dominance FLOOR: below this nothing fires at any travel.
///
/// Between here and [`SLOW_DOMINANCE`] the required travel interpolates. Native decides the axis at
/// ONSET and then forgives drift, whereas a whole-gesture ratio re-taxes every later wobble — field
/// traces of deliberate swipes at 2.3× and 3.8× were both rejected by a step rule. Travel buys that
/// tolerance: at 2× the shorter gestures still reject, so a modest diagonal nudge cannot ride the
/// relaxation. The ratio deliberately does NOT scale with the fire-travel knob.
pub const SLOW_RELAXED_DOMINANCE: f64 = 2.0;

/// The began-to-ended duration (seconds) separating the FLICK tier from the SLOW tier. It also
/// gates ARMING, so a long gesture's momentum tail can never navigate.
pub const FLICK_MAX_DURATION: f64 = 0.45;

/// The end of the GRACE RAMP past the flick seam.
///
/// Between [`FLICK_MAX_DURATION`] and here the requirement eases in from the flick bar to the full
/// slow bar: a lift 100 ms past the window must not face DOUBLE the travel. At the top of the ramp
/// the rule equals the full-dominance band exactly, so behaviour past it is unchanged.
pub const SLOW_GRACE_MAX_DURATION: f64 = 0.70;

/// How long after a lift momentum may still confirm. Momentum begins within a frame of the lift, so
/// this only has to absorb wire jitter plus a few coalesced momentum emits.
pub const MOMENTUM_WINDOW: f64 = 0.25;

/// How long after a fire no NEW candidate may start.
///
/// The input channel can REORDER: an on-glass `changed` of the gesture that just fired can arrive
/// after its `ended` did, and without this quiet window that straggler synthesises a fresh
/// candidate which the same gesture's momentum tail then fires again — two pages back from one
/// flick. A human re-flick needs longer than this to lift, re-place and travel, so nothing
/// legitimate is eaten.
pub const REFRACTORY: f64 = 0.25;

/// The default fire-travel knob, in points.
pub const DEFAULT_FIRE_TRAVEL: f64 = 80.0;

/// The slow tier's GRADUATED commitment SURFACE, shared by the lift decision and the live-candidate
/// mirror so client feedback can never disagree with the fire.
///
/// Returns the horizontal travel this candidate must reach to fire, or `None` when its dominance is
/// under the 2× floor, where no travel fires. ONE joint interpolation replaces an earlier
/// two-branch step rule, because both step cliffs ate real field swipes that were retried right
/// after. The band's cheap-end ANCHOR eases along the seam fraction — clamped to `0..=1` — from 3×
/// dominance at `fire_travel` to 4× at `slow_fire_travel`. At or above the anchor the requirement
/// IS the anchor's travel; between the anchor and the fixed 2× floor it interpolates linearly
/// toward `slow_relaxed_travel`. So at the seam a 3× ratio needs exactly the flick bar, continuous
/// with the flick tier; at the top of the ramp the endpoints are the old ones exactly; and the
/// surface is continuous in BOTH axes. An earlier cut combined a duration ramp and a ratio band
/// with a minimum, whose independently-gated branches FOLD along their crossing — the requirement
/// jumped from 120 to 180 points across two milliseconds at 3.5×. A joint surface is the only shape
/// with no cliff anywhere.
#[must_use]
pub fn slow_required_travel(
    duration: f64,
    sum_x: f64,
    sum_y: f64,
    fire_travel: f64,
    slow_fire_travel: f64,
    slow_relaxed_travel: f64,
) -> Option<f64> {
    // `x / 0` is infinity, so a purely horizontal gesture passes every dominance; `0 / 0` is NaN,
    // so the guard fails and a zero-travel candidate — which could not reach any threshold anyway —
    // falls out here.
    let ratio = sum_x.abs() / sum_y.abs();
    let Some(order) = ratio.partial_cmp(&SLOW_RELAXED_DOMINANCE) else {
        return None; // NaN: no travel at all
    };
    if order == Ordering::Less {
        return None;
    }
    let grace_span = SLOW_GRACE_MAX_DURATION - FLICK_MAX_DURATION;
    let grace_raw = (duration - FLICK_MAX_DURATION) / grace_span;
    #[expect(
        clippy::manual_clamp,
        reason = "the NaN-ignoring IEEE max-then-min pair folds a NaN to a bound, where `clamp` would \
                  propagate it into every threshold below"
    )]
    let fraction = grace_raw.max(0.0).min(1.0);
    let anchor_dominance = DOMINANCE + fraction * (SLOW_DOMINANCE - DOMINANCE);
    let anchor_ease = fraction * (slow_fire_travel - fire_travel);
    let anchor_travel = fire_travel + anchor_ease;
    if ratio >= anchor_dominance {
        return Some(anchor_travel);
    }
    let span = anchor_dominance - SLOW_RELAXED_DOMINANCE;
    let shortfall = (anchor_dominance - ratio) / span;
    let floor_ease = shortfall * (slow_relaxed_travel - anchor_travel);
    Some(anchor_travel + floor_ease)
}

/// A live, read-only view of the in-flight candidate, for client-side gesture feedback.
///
/// The client runs its own recogniser over the SAME event stream it forwards — raw, before
/// coalescing — but coalescing SUMS same-phase deltas and preserves the boundary markers, so the
/// two instances reach the same sums and the same verdicts. Feedback driven from here therefore
/// predicts what the host will do, without a round trip.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LiveCandidate {
    /// The direction a fire would take, from the sign of the horizontal travel so far.
    pub direction: SwipeDirection,
    /// The signed horizontal travel so far, in points, including momentum while coasting.
    pub travel_x: f64,
    /// How far along the live tier's fire threshold the gesture is, in `0.0..=1.0`. Zero while the
    /// tier's dominance fails: feedback must never promise a fire the lift would reject.
    pub progress: f64,
    /// Whether a lift right now would fire. Always false while coasting — the fingers are already
    /// up, and momentum confirmation is the only decision left.
    pub would_fire_at_lift: bool,
    /// Whether the candidate is armed and coasting, awaiting momentum confirmation.
    pub coasting: bool,
}

/// The recogniser. A pure value: the injector feeds it the already-coalesced events it posts.
#[expect(
    clippy::struct_excessive_bools,
    reason = "two knobs and three candidate-state flags; a gesture is either tracking, coasting or idle, \
              and packing that into an enum would hide that `synthesised` qualifies both"
)]
#[derive(Debug, Clone, PartialEq)]
pub struct SwipeNavRecognizer {
    /// The on-glass horizontal travel that fires at lift with no momentum needed.
    fire_travel: f64,
    /// The on-glass travel that ARMS momentum confirmation at lift; below it the gesture is jitter.
    arm_travel: f64,
    /// The combined on-glass and momentum travel that fires an armed candidate.
    confirm_travel: f64,
    /// The travel that fires a SLOW deliberate swipe at lift.
    slow_fire_travel: f64,
    /// The travel from which the slow tier's dominance requirement relaxes to the floor.
    slow_relaxed_travel: f64,
    /// Whether the slow tier is on. With it off, a lift past the flick window rejects on duration.
    slow_swipe: bool,
    /// Whether to record a per-gesture decision trace.
    trace: bool,
    /// The pending trace line, if any.
    trace_line: Option<String>,
    /// Whether a candidate is live with the fingers on the glass.
    tracking: bool,
    /// Whether an armed candidate is coasting, awaiting momentum.
    coasting: bool,
    /// Whether the live candidate was SYNTHESISED from a `changed` whose `began` never arrived.
    ///
    /// Such a candidate may fire at lift on full-strength evidence, but must never ARM: a reordered
    /// straggler from a REJECTED pan would otherwise form a near-empty candidate that the pan's big
    /// momentum tail "confirms" into a navigation.
    synthesised: bool,
    /// When the live candidate started.
    started_at: f64,
    /// When the coast window closes.
    coast_deadline: f64,
    /// When a direction last fired — the refractory window's anchor.
    fired_at: f64,
    /// The accumulated horizontal travel.
    sum_x: f64,
    /// The accumulated vertical travel.
    sum_y: f64,
    /// The last momentum event accumulated during a coast, for raw-UDP duplicate rejection.
    last_momentum: Option<(f64, f64, u8)>,
}

/// The recogniser's whole state, for a caller that STORES it rather than owning it.
///
/// Everything but the trace line, which is an ANSWER rather than state: it is recorded at a
/// decision and popped by the next call, so a caller that carries the state between calls has
/// already taken it. A restored recogniser therefore starts with none pending.
#[expect(
    clippy::struct_excessive_bools,
    reason = "it is the recogniser's own flags, one for one — collapsing them here would make the carried \
              state disagree in shape with the thing it carries"
)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecognizerState {
    /// The on-glass travel that fires at lift.
    pub fire_travel: f64,
    /// The on-glass travel that arms momentum confirmation.
    pub arm_travel: f64,
    /// The combined travel that fires an armed candidate.
    pub confirm_travel: f64,
    /// The travel that fires a slow deliberate swipe.
    pub slow_fire_travel: f64,
    /// The travel from which the slow tier's dominance relaxes to the floor.
    pub slow_relaxed_travel: f64,
    /// When the live candidate started.
    pub started_at: f64,
    /// When the coast window closes.
    pub coast_deadline: f64,
    /// When a direction last fired.
    pub fired_at: f64,
    /// The accumulated horizontal travel.
    pub sum_x: f64,
    /// The accumulated vertical travel.
    pub sum_y: f64,
    /// The last momentum event accumulated during a coast, for duplicate rejection.
    pub last_momentum: Option<(f64, f64, u8)>,
    /// Whether the slow tier is on.
    pub slow_swipe: bool,
    /// Whether to record a per-gesture decision trace.
    pub trace: bool,
    /// Whether a candidate is live with the fingers on the glass.
    pub tracking: bool,
    /// Whether an armed candidate is coasting.
    pub coasting: bool,
    /// Whether the live candidate was synthesised from a `changed` whose `began` never arrived.
    pub synthesised: bool,
}

impl Default for SwipeNavRecognizer {
    fn default() -> Self {
        Self::new(DEFAULT_FIRE_TRAVEL, true, false)
    }
}

impl SwipeNavRecognizer {
    /// A recogniser whose whole threshold family scales from `fire_travel`.
    ///
    /// Arming sits at 0.3× — below that is jitter — momentum confirmation at 1.5×, since an armed
    /// candidate must show real combined travel; the slow tier at 2×, because past the duration
    /// boundary only commitment discriminates; and the slow tier's relaxed-dominance line at 3×.
    #[must_use]
    pub fn new(fire_travel: f64, slow_swipe: bool, trace: bool) -> Self {
        Self {
            fire_travel,
            arm_travel: fire_travel * 0.3,
            confirm_travel: fire_travel * 1.5,
            slow_fire_travel: fire_travel * 2.0,
            slow_relaxed_travel: fire_travel * 3.0,
            slow_swipe,
            trace,
            trace_line: None,
            tracking: false,
            coasting: false,
            synthesised: false,
            started_at: 0.0,
            coast_deadline: 0.0,
            fired_at: f64::NEG_INFINITY,
            sum_x: 0.0,
            sum_y: 0.0,
            last_momentum: None,
        }
    }

    /// The whole state, for a caller that carries it between calls.
    #[must_use]
    pub const fn state(&self) -> RecognizerState {
        RecognizerState {
            fire_travel: self.fire_travel,
            arm_travel: self.arm_travel,
            confirm_travel: self.confirm_travel,
            slow_fire_travel: self.slow_fire_travel,
            slow_relaxed_travel: self.slow_relaxed_travel,
            started_at: self.started_at,
            coast_deadline: self.coast_deadline,
            fired_at: self.fired_at,
            sum_x: self.sum_x,
            sum_y: self.sum_y,
            last_momentum: self.last_momentum,
            slow_swipe: self.slow_swipe,
            trace: self.trace,
            tracking: self.tracking,
            coasting: self.coasting,
            synthesised: self.synthesised,
        }
    }

    /// The recogniser a carried state describes.
    ///
    /// The threshold family is taken as given rather than re-derived from `fire_travel`: it was
    /// derived once, at construction, and deriving it twice would invite the two passes to
    /// disagree. No trace line is pending — see [`RecognizerState`].
    #[must_use]
    pub const fn restored(state: RecognizerState) -> Self {
        Self {
            fire_travel: state.fire_travel,
            arm_travel: state.arm_travel,
            confirm_travel: state.confirm_travel,
            slow_fire_travel: state.slow_fire_travel,
            slow_relaxed_travel: state.slow_relaxed_travel,
            slow_swipe: state.slow_swipe,
            trace: state.trace,
            trace_line: None,
            tracking: state.tracking,
            coasting: state.coasting,
            synthesised: state.synthesised,
            started_at: state.started_at,
            coast_deadline: state.coast_deadline,
            fired_at: state.fired_at,
            sum_x: state.sum_x,
            sum_y: state.sum_y,
            last_momentum: state.last_momentum,
        }
    }

    /// The on-glass travel that fires at lift, as configured.
    #[must_use]
    pub const fn fire_travel(&self) -> f64 {
        self.fire_travel
    }

    /// The combined travel an armed candidate must reach for momentum to confirm it.
    #[must_use]
    pub const fn confirm_travel(&self) -> f64 {
        self.confirm_travel
    }

    /// Feeds one forwarded scroll event, returning a direction exactly when a gesture qualifies —
    /// at lift, or at momentum confirmation of an armed lift.
    ///
    /// `now` is the host's arrival clock. Wire events carry no timestamps, and arrival time tracks
    /// the gesture closely enough for the sub-second budgets here.
    pub fn ingest(
        &mut self,
        dx: f64,
        dy: f64,
        scroll_phase: u8,
        momentum_phase: u8,
        continuous: bool,
        now: f64,
    ) -> Option<SwipeDirection> {
        // Momentum means the fingers are OFF the glass — the phases are mutually exclusive.
        if momentum_phase != 0 {
            return self.ingest_momentum(dx, dy, momentum_phase, now);
        }
        match scroll_phase {
            // A fresh candidate. A real gesture only: a wheel notch carries phase 0.
            1 => {
                if now - self.fired_at < REFRACTORY {
                    return None;
                }
                self.tracking = continuous;
                self.synthesised = false;
                self.coasting = false; // a new gesture obsoletes any armed predecessor
                self.started_at = now;
                self.sum_x = dx;
                self.sum_y = dy;
                None
            },
            2 => {
                if !self.tracking {
                    // While an ARMED candidate coasts, an on-glass `changed` is a reordered or
                    // duplicated straggler of the gesture that just armed — synthesising from it
                    // would clobber the arm, and its kept sums, right before the genuine momentum
                    // confirms. Ignore it while the coast window is live; past the deadline the arm
                    // is stale, so release it and let the synthesis below run normally.
                    if self.coasting {
                        if now <= self.coast_deadline {
                            return None;
                        }
                        self.coasting = false;
                    }
                    // The `began` datagram was lost. A continuous `changed` can only come from a
                    // live gesture, so synthesise the start here — the duration comes out a touch
                    // short, which only biases the duration gate toward permitting.
                    if !continuous || now - self.fired_at < REFRACTORY {
                        return None;
                    }
                    self.tracking = true;
                    self.synthesised = true;
                    self.coasting = false;
                    self.started_at = now;
                    self.sum_x = 0.0;
                    self.sum_y = 0.0;
                }
                self.sum_x += dx;
                self.sum_y += dy;
                None
            },
            // The lift decision.
            4 => {
                if !self.tracking {
                    return None;
                }
                self.sum_x += dx;
                self.sum_y += dy;
                self.lift_decision(now)
            },
            // Cancelled: the OS or the client abandoned the gesture, and it must never fire.
            8 => {
                self.reset();
                None
            },
            // A wheel notch, a may-begin, or something unknown — not part of a candidate.
            _ => None,
        }
    }

    /// Pops the pending per-gesture decision trace, which is only recorded when tracing is on.
    pub const fn take_trace_line(&mut self) -> Option<String> {
        self.trace_line.take()
    }

    /// The live candidate, or `None` when there is none: idle, refractory, no horizontal travel, or
    /// just decided.
    ///
    /// Tier selection mirrors the lift decision exactly — duration picks flick against slow, the
    /// slow tier vanishes with the kill switch off, and each tier applies its own dominance before
    /// reporting any progress.
    #[must_use]
    pub fn live_candidate(&self, now: f64) -> Option<LiveCandidate> {
        if self.tracking {
            if self.sum_x == 0.0 {
                return None;
            }
            let direction = self.direction();
            let duration = now - self.started_at;
            let flick_tier = duration <= FLICK_MAX_DURATION;
            if !flick_tier && !self.slow_swipe {
                // Past the flick window with the slow tier off, the lift can only reject on
                // duration, so the feedback retracts instead of promising.
                return Some(self.retracted(direction));
            }
            if flick_tier {
                let dominant = self.sum_x.abs() >= DOMINANCE * self.sum_y.abs();
                return Some(LiveCandidate {
                    direction,
                    travel_x: self.sum_x,
                    progress: if dominant {
                        (self.sum_x.abs() / self.fire_travel).min(1.0)
                    } else {
                        0.0
                    },
                    would_fire_at_lift: dominant && self.sum_x.abs() >= self.fire_travel,
                    coasting: false,
                });
            }
            // The slow tier's graduated commitment surface: the fill tracks the travel this exact
            // duration-and-dominance point must actually reach, so it never promises more than the
            // lift would honour, and under the floor it stays dark however big the travel.
            let Some(required) = self.slow_required(duration) else {
                return Some(self.retracted(direction));
            };
            return Some(LiveCandidate {
                direction,
                travel_x: self.sum_x,
                progress: (self.sum_x.abs() / required).min(1.0),
                would_fire_at_lift: self.sum_x.abs() >= required,
                coasting: false,
            });
        }
        if self.coasting {
            if now > self.coast_deadline || self.sum_x == 0.0 {
                return None;
            }
            let dominant = self.sum_x.abs() >= DOMINANCE * self.sum_y.abs();
            return Some(LiveCandidate {
                direction: self.direction(),
                travel_x: self.sum_x,
                progress: if dominant {
                    (self.sum_x.abs() / self.confirm_travel).min(1.0)
                } else {
                    0.0
                },
                would_fire_at_lift: false,
                coasting: true,
            });
        }
        None
    }

    /// The candidate a tier has nothing to promise about: direction only, no progress.
    const fn retracted(&self, direction: SwipeDirection) -> LiveCandidate {
        LiveCandidate {
            direction,
            travel_x: self.sum_x,
            progress: 0.0,
            would_fire_at_lift: false,
            coasting: false,
        }
    }

    /// The direction the accumulated horizontal travel points.
    const fn direction(&self) -> SwipeDirection {
        if self.sum_x > 0.0 {
            SwipeDirection::Back
        } else {
            SwipeDirection::Forward
        }
    }

    /// This candidate's slow-tier requirement at `duration`.
    fn slow_required(&self, duration: f64) -> Option<f64> {
        slow_required_travel(
            duration,
            self.sum_x,
            self.sum_y,
            self.fire_travel,
            self.slow_fire_travel,
            self.slow_relaxed_travel,
        )
    }

    /// A momentum event: synthesise the lift if `ended` was lost, then let the coast window
    /// accumulate confirmation evidence for an armed candidate.
    fn ingest_momentum(&mut self, dx: f64, dy: f64, momentum_phase: u8, now: f64) -> Option<SwipeDirection> {
        if self.tracking {
            // Only a momentum BEGIN may prove a lost `ended`: it is the OS's own lift marker, and
            // the planner emits it uncoalesced. A continue or end arriving while STILL tracking is
            // a reordered straggler from the PREVIOUS gesture's tail, and synthesising a lift from
            // it would CHOP a live content pan into flick-shaped segments that fire — reproduced in
            // review, where a 700 ms pan plus one stray continue navigated. Ignore it; the
            // candidate lives on.
            if momentum_phase != 1 {
                return None;
            }
            // The `ended` datagram was lost, and momentum-begin proves the lift. Decide now.
            if let Some(fired) = self.lift_decision(now) {
                return Some(fired);
            }
        }
        if !self.coasting {
            return None;
        }
        if now > self.coast_deadline {
            self.emit_trace(format!(
                "coast expired Σ=({},{})",
                whole(self.sum_x),
                whole(self.sum_y)
            ));
            self.reset();
            return None;
        }
        // Raw-UDP DUPLICATE rejection: the momentum-begin emit is a planner boundary, uncoalesced,
        // so its wire duplicate arrives verbatim, and double-counting it could shove a marginal
        // armed candidate over the confirm bar. An exactly identical consecutive momentum event is
        // dropped — a real decay curve never repeats bytes back to back, and losing one plateau
        // sample would cost a few points at most.
        // The equality is bit-for-bit on purpose: this is a duplicate-datagram test, not a
        // comparison of two computed quantities.
        if self.last_momentum == Some((dx, dy, momentum_phase)) {
            return None;
        }
        self.last_momentum = Some((dx, dy, momentum_phase));
        // Post-lift evidence, which accumulates even when this same event synthesised the lift
        // above: it happened after the fingers left the glass either way.
        self.sum_x += dx;
        self.sum_y += dy;
        if self.sum_x.abs() >= self.confirm_travel && self.sum_x.abs() >= DOMINANCE * self.sum_y.abs() {
            let fired = self.direction();
            self.emit_trace(format!(
                "momentum confirm Σ=({},{}) → FIRE {fired:?}",
                whole(self.sum_x),
                whole(self.sum_y),
            ));
            self.fired_at = now;
            self.reset();
            return Some(fired);
        }
        if momentum_phase == 3 {
            // Momentum end: no more evidence is coming.
            self.emit_trace(format!(
                "coast ended short Σ=({},{}) need {}",
                whole(self.sum_x),
                whole(self.sum_y),
                whole(self.confirm_travel),
            ));
            self.reset();
        }
        None
    }

    /// The lift decision: fire outright on one tier or the other, arm momentum confirmation, or
    /// reject. Duration picks the tier, and dominance gates every outcome — an armed candidate is
    /// always a plausible flick already.
    fn lift_decision(&mut self, now: f64) -> Option<SwipeDirection> {
        self.tracking = false;
        let duration = now - self.started_at;
        let stats = format!(
            "dur={}ms Σ=({},{})",
            whole(duration * 1000.0),
            whole(self.sum_x),
            whole(self.sum_y),
        );
        if duration > FLICK_MAX_DURATION {
            return self.slow_lift_decision(now, duration, &stats);
        }
        if self.sum_x.abs() < DOMINANCE * self.sum_y.abs() {
            self.emit_trace(format!("lift {stats} → reject dominance"));
            self.reset();
            return None;
        }
        if self.sum_x.abs() >= self.fire_travel {
            let fired = self.direction();
            self.emit_trace(format!("lift {stats} → FIRE {fired:?}"));
            self.fired_at = now;
            self.reset();
            return Some(fired);
        }
        if self.sum_x.abs() >= self.arm_travel {
            if self.synthesised {
                self.emit_trace(format!("lift {stats} → reject (synthesised candidate can't arm)"));
                self.reset();
                return None;
            }
            self.coasting = true;
            self.coast_deadline = now + MOMENTUM_WINDOW;
            self.emit_trace(format!(
                "lift {stats} → armed (confirm ≥{})",
                whole(self.confirm_travel)
            ));
            return None; // the sums are KEPT: momentum confirms over the combined travel
        }
        self.emit_trace(format!(
            "lift {stats} → reject travel (<{})",
            whole(self.arm_travel)
        ));
        self.reset();
        None
    }

    /// The slow tier: a lift past the flick window fires on the graduated commitment surface, with
    /// no upper duration bound, or rejects outright.
    ///
    /// It never ARMS. Momentum confirmation exists for flicks whose energy went into the tail; a
    /// slow lift has none, and letting a long gesture coast would hand content-pan tails a path to
    /// navigate again.
    fn slow_lift_decision(&mut self, now: f64, duration: f64, stats: &str) -> Option<SwipeDirection> {
        if !self.slow_swipe {
            self.emit_trace(format!("lift {stats} → reject duration (slow tier off)"));
            self.reset();
            return None;
        }
        let required = self.slow_required(duration);
        match required {
            Some(required) if self.sum_x.abs() >= required => {
                let fired = self.direction();
                self.emit_trace(format!("lift {stats} → FIRE {fired:?} (slow)"));
                self.fired_at = now;
                self.reset();
                Some(fired)
            },
            // Name the NEAREST miss, so a field trace steers the right knob: a candidate with
            // acceptable dominance that failed on TRAVEL should say how much THIS point needed,
            // because labelling it "dominance" would send the tuning the wrong way.
            Some(required) => {
                self.emit_trace(format!(
                    "lift {stats} → reject slow travel (<{})",
                    whole(required.ceil()),
                ));
                self.reset();
                None
            },
            None => {
                self.emit_trace(format!("lift {stats} → reject slow dominance"));
                self.reset();
                None
            },
        }
    }

    /// Clears the candidate. `fired_at` deliberately survives — the refractory window outlives the
    /// candidate that set it.
    const fn reset(&mut self) {
        self.tracking = false;
        self.coasting = false;
        self.synthesised = false;
        self.sum_x = 0.0;
        self.sum_y = 0.0;
        self.last_momentum = None;
    }

    /// Records one decision line, when tracing is on.
    fn emit_trace(&mut self, line: String) {
        if self.trace {
            self.trace_line = Some(line);
        }
    }
}

/// The whole-point part of a value, for a trace line.
const fn whole(value: f64) -> i64 {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "a trace line's magnitudes are points and milliseconds; a value that could saturate an i64 \
                  is not a gesture"
    )]
    {
        value as i64
    }
}

/// Bundle ids where ⌘[ / ⌘] means history navigation.
///
/// The translation is ALLOW-LISTED rather than universal: the same chord is outdent/indent in an
/// editor, which is a TEXT EDIT, so an unknown frontmost app gets the scroll it already received
/// and nothing else. Extend at runtime via `SLOPDESK_SWIPE_NAV_APPS` without a rebuild.
pub const NAVIGABLE_APPS: [&str; 27] = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.apple.finder",
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "com.google.Chrome.canary",
    "org.chromium.Chromium",
    "company.thebrowser.Browser", // Arc
    "company.thebrowser.dia",
    "org.mozilla.firefox",
    "org.mozilla.nightly",
    "org.mozilla.firefoxdeveloperedition",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "com.microsoft.edgemac.Dev",
    "com.microsoft.edgemac.Canary",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.vivaldi.Vivaldi",
    "com.vivaldi.Vivaldi.snapshot",
    "com.operasoftware.Opera",
    "com.operasoftware.OperaNext", // Opera beta
    "com.operasoftware.OperaDeveloper",
    "com.kagi.kagimacOS", // Orion
    "app.zen-browser.zen",
];

/// Parses the `SLOPDESK_SWIPE_NAV_APPS` extension list — comma-separated, whitespace-tolerant.
#[must_use]
pub fn extra_apps(raw: Option<&str>) -> BTreeSet<String> {
    raw.unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

/// The `SLOPDESK_SWIPE_NAV_TRAVEL` knob with its safety clamp: a typo must not make every scroll
/// navigate — too low — nor silently dead the feature — too high.
///
/// ONE parse shared by the injector's recogniser and the status push, so the client's feedback
/// mirror always sees the value the host actually operates on.
#[must_use]
pub fn fire_travel_from_env(raw: Option<&str>) -> f64 {
    let Some(parsed) = raw.and_then(|raw| raw.parse::<f64>().ok()) else {
        return DEFAULT_FIRE_TRAVEL;
    };
    if parsed.is_finite() && (20.0..=500.0).contains(&parsed) {
        parsed
    } else {
        DEFAULT_FIRE_TRAVEL
    }
}

/// Whether the swipe translation may drive this frontmost app. An absent bundle id is not
/// navigable: an app that cannot be identified cannot be allow-listed.
#[must_use]
pub fn is_navigable(bundle_id: Option<&str>, extra: &BTreeSet<String>) -> bool {
    let Some(bundle_id) = bundle_id else {
        return false;
    };
    NAVIGABLE_APPS.contains(&bundle_id) || extra.contains(bundle_id)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::float_cmp,
        reason = "the progress assertions are on values the law pinned to a bound — zero or one — which is \
                  the property under test"
    )]
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::collections::BTreeSet;

    use super::{
        DEFAULT_FIRE_TRAVEL, FLICK_MAX_DURATION, MOMENTUM_WINDOW, NAVIGABLE_APPS, REFRACTORY,
        SLOW_GRACE_MAX_DURATION, SwipeNavRecognizer, extra_apps, fire_travel_from_env, is_navigable,
        slow_required_travel,
    };
    use crate::swipe_nav::SwipeDirection;

    /// A gesture driven as the injector would drive it: a began, one changed, and a lift.
    fn flick(
        recognizer: &mut SwipeNavRecognizer,
        dx: f64,
        dy: f64,
        duration: f64,
        start: f64,
    ) -> Option<SwipeDirection> {
        assert_eq!(recognizer.ingest(0.0, 0.0, 1, 0, true, start), None);
        assert_eq!(
            recognizer.ingest(dx, dy, 2, 0, true, start + duration * 0.5),
            None
        );
        recognizer.ingest(0.0, 0.0, 4, 0, true, start + duration)
    }

    #[test]
    fn a_decisive_horizontal_flick_fires_at_lift() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(
            flick(&mut recognizer, 120.0, 10.0, 0.2, 10.0),
            Some(SwipeDirection::Back)
        );
        let mut other = SwipeNavRecognizer::default();
        assert_eq!(
            flick(&mut other, -120.0, 10.0, 0.2, 10.0),
            Some(SwipeDirection::Forward)
        );
    }

    #[test]
    fn a_diagonal_pan_is_rejected_however_far_it_travelled() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(flick(&mut recognizer, 300.0, 200.0, 0.2, 10.0), None);
    }

    #[test]
    fn a_short_flick_below_the_arm_bar_is_jitter() {
        let mut recognizer = SwipeNavRecognizer::default();
        // Under 0.3 × 80 points of travel.
        assert_eq!(flick(&mut recognizer, 20.0, 1.0, 0.1, 10.0), None);
        assert_eq!(recognizer.live_candidate(10.2), None, "and nothing is left armed");
    }

    /// The case an on-glass-only recogniser gets exactly backwards: the sharpest flicks spend most
    /// of their travel in the tail.
    #[test]
    fn a_sharp_flick_is_confirmed_by_its_momentum_tail() {
        let mut recognizer = SwipeNavRecognizer::default();
        // 60 points on glass: past the 24-point arm bar, short of the 80-point fire bar.
        assert_eq!(flick(&mut recognizer, 60.0, 2.0, 0.1, 10.0), None);
        let candidate = recognizer.live_candidate(10.15).expect("armed and coasting");
        assert!(candidate.coasting);
        assert!(!candidate.would_fire_at_lift, "the fingers are already up");
        // The tail carries it past the 120-point combined bar.
        assert_eq!(recognizer.ingest(30.0, 1.0, 0, 1, true, 10.12), None);
        assert_eq!(
            recognizer.ingest(40.0, 1.0, 0, 2, true, 10.14),
            Some(SwipeDirection::Back),
        );
    }

    #[test]
    fn an_armed_candidate_expires_when_no_momentum_arrives() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(flick(&mut recognizer, 60.0, 2.0, 0.1, 10.0), None);
        let late = 10.1 + MOMENTUM_WINDOW + 0.01;
        assert_eq!(
            recognizer.ingest(90.0, 1.0, 0, 2, true, late),
            None,
            "past the window"
        );
        assert_eq!(recognizer.live_candidate(late), None);
    }

    /// A coast that curves vertical is a pan, not a swipe.
    #[test]
    fn a_coast_that_curves_vertical_dies_at_confirmation() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(flick(&mut recognizer, 60.0, 2.0, 0.1, 10.0), None);
        assert_eq!(recognizer.ingest(70.0, 60.0, 0, 2, true, 10.12), None);
    }

    #[test]
    fn a_slow_deliberate_swipe_fires_on_commitment_rather_than_speed() {
        let mut recognizer = SwipeNavRecognizer::default();
        // Well past the flick window, clean line, past twice the flick bar.
        assert_eq!(
            flick(&mut recognizer, 200.0, 20.0, 0.9, 10.0),
            Some(SwipeDirection::Back)
        );
        // The same duration with a modest nudge does not.
        let mut modest = SwipeNavRecognizer::default();
        assert_eq!(flick(&mut modest, 100.0, 20.0, 0.9, 10.0), None);
    }

    #[test]
    fn a_slow_swipe_never_arms_its_tail() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(
            flick(&mut recognizer, 100.0, 5.0, 0.9, 10.0),
            None,
            "short of the slow bar"
        );
        // A big momentum tail after a slow lift must not navigate.
        assert_eq!(recognizer.ingest(300.0, 2.0, 0, 1, true, 10.92), None);
        assert_eq!(recognizer.ingest(300.0, 2.0, 0, 2, true, 10.94), None);
    }

    #[test]
    fn the_slow_tier_can_be_switched_off_entirely() {
        let mut recognizer = SwipeNavRecognizer::new(DEFAULT_FIRE_TRAVEL, false, false);
        assert_eq!(
            flick(&mut recognizer, 400.0, 5.0, 0.9, 10.0),
            None,
            "rejected on duration"
        );
        let live = recognizer.live_candidate(10.0);
        assert_eq!(live, None, "the candidate was decided and cleared");
    }

    /// The graduated surface is the whole point of the slow tier: no cliff anywhere.
    #[test]
    fn the_slow_requirement_is_continuous_across_the_seam_and_the_ratio() {
        let required = |duration: f64, sum_x: f64, sum_y: f64| {
            slow_required_travel(duration, sum_x, sum_y, 80.0, 160.0, 240.0)
        };
        // At the seam a 3× ratio asks exactly the flick bar, so the tiers meet.
        assert_eq!(required(FLICK_MAX_DURATION, 300.0, 100.0), Some(80.0));
        // At the top of the ramp the endpoints are the full slow bar and the relaxed line.
        assert_eq!(required(SLOW_GRACE_MAX_DURATION, 400.0, 100.0), Some(160.0));
        assert_eq!(required(SLOW_GRACE_MAX_DURATION, 200.0, 100.0), Some(240.0));
        // Under the floor nothing fires at any travel.
        assert_eq!(required(1.0, 190.0, 100.0), None);
        // And the surface never jumps: two milliseconds apart is two milliseconds' worth.
        let a = required(0.55, 350.0, 100.0).expect("above the floor");
        let b = required(0.552, 350.0, 100.0).expect("above the floor");
        assert!((a - b).abs() < 1.0, "{a} against {b}");
    }

    #[test]
    fn a_purely_horizontal_gesture_passes_every_dominance() {
        let required = slow_required_travel(1.0, 300.0, 0.0, 80.0, 160.0, 240.0);
        assert_eq!(required, Some(160.0), "an infinite ratio takes the anchor");
        // A gesture with no travel at all has no requirement to compare against.
        assert_eq!(slow_required_travel(1.0, 0.0, 0.0, 80.0, 160.0, 240.0), None);
    }

    /// A lost `began` must not make a real swipe "not count".
    #[test]
    fn a_lost_began_is_synthesised_from_the_first_continuous_changed() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(recognizer.ingest(120.0, 5.0, 2, 0, true, 10.0), None);
        assert_eq!(
            recognizer.ingest(0.0, 0.0, 4, 0, true, 10.1),
            Some(SwipeDirection::Back)
        );
    }

    /// …but a synthesised candidate must never arm, or a rejected pan's tail could navigate.
    #[test]
    fn a_synthesised_candidate_can_fire_but_never_arms() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(recognizer.ingest(60.0, 2.0, 2, 0, true, 10.0), None);
        assert_eq!(
            recognizer.ingest(0.0, 0.0, 4, 0, true, 10.1),
            None,
            "armable travel, but…"
        );
        assert_eq!(recognizer.live_candidate(10.12), None, "…nothing is coasting");
        assert_eq!(recognizer.ingest(300.0, 2.0, 0, 2, true, 10.12), None);
    }

    /// A lost `ended` is proved by momentum-begin — but only by momentum-begin.
    #[test]
    fn a_lost_ended_is_synthesised_from_momentum_begin_alone() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(recognizer.ingest(0.0, 0.0, 1, 0, true, 10.0), None);
        assert_eq!(recognizer.ingest(120.0, 5.0, 2, 0, true, 10.05), None);
        assert_eq!(
            recognizer.ingest(5.0, 0.0, 0, 1, true, 10.1),
            Some(SwipeDirection::Back)
        );

        // A stray continue while still tracking is a straggler from a previous tail, and must not
        // chop a live pan into flick-shaped segments.
        let mut panning = SwipeNavRecognizer::default();
        assert_eq!(panning.ingest(0.0, 0.0, 1, 0, true, 10.0), None);
        assert_eq!(panning.ingest(120.0, 5.0, 2, 0, true, 10.05), None);
        assert_eq!(
            panning.ingest(5.0, 0.0, 0, 2, true, 10.1),
            None,
            "a continue proves nothing"
        );
        assert!(panning.live_candidate(10.1).is_some(), "the candidate lives on");
    }

    /// Two pages back from one flick is the bug the refractory window exists to prevent.
    #[test]
    fn a_reordered_straggler_cannot_re_fire_after_a_fire() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(
            flick(&mut recognizer, 120.0, 5.0, 0.1, 10.0),
            Some(SwipeDirection::Back)
        );
        // The gesture's own on-glass straggler arrives late…
        assert_eq!(recognizer.ingest(60.0, 2.0, 2, 0, true, 10.12), None);
        // …and its momentum tail must not confirm anything.
        assert_eq!(recognizer.ingest(300.0, 2.0, 0, 2, true, 10.15), None);
        // Past the refractory window a genuine re-flick works again.
        let later = 10.1 + REFRACTORY + 0.01;
        assert_eq!(
            flick(&mut recognizer, 120.0, 5.0, 0.1, later),
            Some(SwipeDirection::Back)
        );
    }

    /// A duplicated momentum datagram must not push a marginal candidate over the bar.
    #[test]
    fn an_identical_consecutive_momentum_event_is_dropped() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(flick(&mut recognizer, 60.0, 2.0, 0.1, 10.0), None);
        assert_eq!(
            recognizer.ingest(55.0, 1.0, 0, 2, true, 10.12),
            None,
            "115 of 120"
        );
        assert_eq!(
            recognizer.ingest(55.0, 1.0, 0, 2, true, 10.13),
            None,
            "the dup is dropped"
        );
        // A genuinely different sample still confirms.
        assert_eq!(
            recognizer.ingest(10.0, 1.0, 0, 2, true, 10.14),
            Some(SwipeDirection::Back),
        );
    }

    #[test]
    fn a_cancelled_gesture_never_fires() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(recognizer.ingest(0.0, 0.0, 1, 0, true, 10.0), None);
        assert_eq!(recognizer.ingest(300.0, 5.0, 2, 0, true, 10.05), None);
        assert_eq!(recognizer.ingest(0.0, 0.0, 8, 0, true, 10.1), None);
        assert_eq!(
            recognizer.ingest(0.0, 0.0, 4, 0, true, 10.11),
            None,
            "nothing left to lift"
        );
    }

    #[test]
    fn a_wheel_notch_is_not_a_candidate() {
        let mut recognizer = SwipeNavRecognizer::default();
        // Phase 0 with no momentum: a mouse wheel, not a gesture.
        assert_eq!(recognizer.ingest(300.0, 0.0, 0, 0, false, 10.0), None);
        assert_eq!(recognizer.ingest(0.0, 0.0, 4, 0, false, 10.1), None);
        assert_eq!(recognizer.live_candidate(10.1), None);
    }

    /// The feedback mirror must never promise a fire the lift would reject.
    #[test]
    fn the_live_candidate_tracks_the_tier_it_would_be_judged_by() {
        let mut recognizer = SwipeNavRecognizer::default();
        assert_eq!(recognizer.ingest(0.0, 0.0, 1, 0, true, 10.0), None);
        assert_eq!(recognizer.ingest(40.0, 2.0, 2, 0, true, 10.05), None);
        let half = recognizer.live_candidate(10.06).expect("a live candidate");
        assert_eq!(half.direction, SwipeDirection::Back);
        assert_eq!(half.progress, 0.5, "40 of the 80-point flick bar");
        assert!(!half.would_fire_at_lift);

        assert_eq!(recognizer.ingest(60.0, 2.0, 2, 0, true, 10.07), None);
        let full = recognizer.live_candidate(10.08).expect("a live candidate");
        assert_eq!(full.progress, 1.0);
        assert!(full.would_fire_at_lift);

        // A vertical drift retracts the promise without ending the gesture.
        assert_eq!(recognizer.ingest(0.0, 200.0, 2, 0, true, 10.09), None);
        let drifted = recognizer.live_candidate(10.1).expect("a live candidate");
        assert_eq!(drifted.progress, 0.0, "dominance failed, so nothing is promised");
        assert!(!drifted.would_fire_at_lift);
    }

    #[test]
    fn only_allow_listed_apps_may_be_driven() {
        let none = BTreeSet::new();
        assert_eq!(
            NAVIGABLE_APPS.len(),
            27,
            "the list may grow deliberately, never shrink by accident"
        );
        assert!(is_navigable(Some("com.apple.Safari"), &none));
        // In an editor ⌘[ is outdent — a text edit — so an unknown app gets nothing.
        assert!(!is_navigable(Some("com.microsoft.VSCode"), &none));
        assert!(
            !is_navigable(None, &none),
            "an unidentifiable app is not allow-listed"
        );
        let extra = extra_apps(Some(" com.microsoft.VSCode , ,com.example.app "));
        assert!(is_navigable(Some("com.microsoft.VSCode"), &extra));
        assert_eq!(extra.len(), 2, "blank entries are dropped, whitespace trimmed");
        assert!(extra_apps(None).is_empty());
        assert!(
            !is_navigable(Some("com.apple.dt.Xcode"), &extra),
            "an extension list does not open the door to every editor"
        );
        for id in ["com.google.Chrome", "org.mozilla.firefox", "com.apple.finder"] {
            assert!(is_navigable(Some(id), &none), "{id}");
        }
        // Every browser's PRE-RELEASE channels ride the list too — Edge/Opera/Vivaldi's must not
        // be the silent exceptions the way Chrome's and Firefox's are covered. Exact-match
        // lookup, so casing matters.
        for id in [
            "com.microsoft.edgemac.Beta",
            "com.microsoft.edgemac.Dev",
            "com.microsoft.edgemac.Canary",
            "com.operasoftware.OperaNext",
            "com.operasoftware.OperaDeveloper",
            "com.vivaldi.Vivaldi.snapshot",
        ] {
            assert!(is_navigable(Some(id), &none), "{id}");
        }
    }

    #[test]
    fn the_travel_knob_falls_back_rather_than_taking_a_dangerous_value() {
        assert_eq!(fire_travel_from_env(Some("120")), 120.0);
        assert_eq!(fire_travel_from_env(None), DEFAULT_FIRE_TRAVEL);
        assert_eq!(fire_travel_from_env(Some("nonsense")), DEFAULT_FIRE_TRAVEL);
        assert_eq!(
            fire_travel_from_env(Some("2")),
            DEFAULT_FIRE_TRAVEL,
            "every scroll would fire"
        );
        assert_eq!(
            fire_travel_from_env(Some("5000")),
            DEFAULT_FIRE_TRAVEL,
            "silently dead"
        );
        assert_eq!(fire_travel_from_env(Some("inf")), DEFAULT_FIRE_TRAVEL);
        // REJECT-to-default, never clamp-to-nearest-bound: a value just outside the window is a
        // typo, and the [20, 500] acceptance is also what keeps the status message's `u16`
        // conversion total.
        for bad in ["", "nan", "-inf", "19.9", "0", "-5", "500.1", "1e9"] {
            assert_eq!(fire_travel_from_env(Some(bad)), DEFAULT_FIRE_TRAVEL, "{bad}");
        }
        assert_eq!(
            fire_travel_from_env(Some("20")),
            20.0,
            "the bounds themselves are allowed"
        );
        assert_eq!(fire_travel_from_env(Some("500")), 500.0);
    }

    #[test]
    fn a_trace_line_is_recorded_only_when_tracing_is_on() {
        let mut quiet = SwipeNavRecognizer::default();
        assert_eq!(
            flick(&mut quiet, 120.0, 5.0, 0.1, 10.0),
            Some(SwipeDirection::Back)
        );
        assert_eq!(quiet.take_trace_line(), None);

        let mut loud = SwipeNavRecognizer::new(DEFAULT_FIRE_TRAVEL, true, true);
        assert_eq!(
            flick(&mut loud, 120.0, 5.0, 0.1, 10.0),
            Some(SwipeDirection::Back)
        );
        let line = loud.take_trace_line().expect("a decision line");
        assert!(line.contains("FIRE"), "{line}");
        assert_eq!(loud.take_trace_line(), None, "popped exactly once");
    }
}
