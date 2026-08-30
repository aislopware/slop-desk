//! The encoder's rate-control state machine: what to write to the session, and when.
//!
//! This is the half of `VideoEncoder.swift` that was never testable and never tested. It has three
//! writers — the capture thread encoding a frame, the host actor actuating a new bitrate or
//! quantiser, and the crisp/compact brackets that relax the session for exactly one intra frame —
//! and they contend over seven fields. Every rule about that contention lived as a comment beside a
//! `VTSessionSetProperty` call in a class whose constructor hangs without a window server, so the
//! rules could only ever be read, never run.
//!
//! Here they are a plain value that answers PLANS. Nothing in this module calls `VideoToolbox`,
//! allocates a session or takes a lock: it is given the frame's facts and answers which properties
//! its caller must write. The caller — `slopdesk-ffi`, holding the one mutex — issues them. That
//! split is what lets a test drive a bracket, an actuator and a frame in any interleaving at all.
//!
//! ## The three invariants the interleavings turn on
//! 1. **A bracket owns the quantiser.** While `bracket_depth > 0` no frame writes
//!    `MaxAllowedFrameQP`, because the bracket relaxed it on purpose and a frame would undo that
//!    mid-intra.
//! 2. **A bracket's restore is the ONLY writer of a rate that landed during it.** An actuator that
//!    fires mid-bracket updates the target and issues NOTHING; if the restore did not re-apply both
//!    rate knobs from its own fresh read, that change would be lost until the next one.
//! 3. **A restore clears the frame dedup.** [`Writes`] are deduplicated against the last quantiser
//!    actually applied, so a restore that put a different value on the session without clearing the
//!    memo would make the next frame believe its own value was already there.
//!
//! Each is a comment in the Swift. Each is a test below.

use crate::encoder_ceiling::DropRelief;
use crate::encoder_config::{CRISP_DATA_RATE_MAX_BYTES, Config, QP_MAX, QP_MIN, const_qp_for_frame};

/// The session properties a caller must write, and what to.
///
/// A `None` field is a property to LEAVE ALONE, which is a different instruction from writing the
/// value it already holds: the hot path's whole point is that a static stream writes nothing at
/// all, and every write is a `CFNumber` bridge plus a framework round trip at sixty frames a
/// second.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Writes {
    /// `MaxAllowedFrameQP`.
    pub max_qp: Option<i32>,
    /// `MinAllowedFrameQP`.
    pub min_qp: Option<i32>,
    /// `AverageBitRate`, in bits per second.
    pub average_bitrate: Option<i64>,
    /// `DataRateLimits`, as the `[maxBytes, seconds]` pair the framework expects.
    pub data_rate: Option<(i64, f64)>,
}

impl Writes {
    /// Whether there is nothing at all to do — the static-stream hot path.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.max_qp.is_none()
            && self.min_qp.is_none()
            && self.average_bitrate.is_none()
            && self.data_rate.is_none()
    }
}

/// When a bracket's relaxed configuration goes back.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Restore {
    /// After the second drain, by calling [`EncoderState::end_bracket`]. The caller must do it.
    Immediate,
    /// At the START of the next encode, by [`EncoderState::settle_pending_compact`], with no drain.
    ///
    /// Draining costs ~115 ms of blocked capture queue per drain (HW-measured: 24 stalls over
    /// 100 ms), and under a lossy-WAN recovery-IDR storm at roughly six intra frames a second those
    /// drains ARE the scroll judder. The compact frame is small enough to finish under the relaxed
    /// configuration within the ~16 ms before the next delta, so deferring costs nothing and saves
    /// both drains.
    Deferred,
}

/// One relax-encode-restore bracket, as a plan.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bracket {
    /// Writes that settle a PRIOR deferred compact bracket. Issue these first, before any drain.
    ///
    /// Present whenever a lazy compact frame was encoded and no live frame has run since. Both
    /// bracket entries settle one, because two overlapping relaxed configurations would restore the
    /// wrong one.
    pub settle: Option<Writes>,
    /// Whether to drain in-flight frames BEFORE `relax`, and again after the encode.
    ///
    /// The first drain makes prior frames finish under the LIVE configuration rather than the
    /// relaxed one; the second makes this frame finish under the relaxed one rather than the
    /// restored one. Restoring first is what silently produced a soft "crisp" refresh.
    pub drain: bool,
    /// The relaxed configuration for exactly this one intra frame.
    pub relax: Writes,
    /// How the relaxed configuration goes back.
    pub restore: Restore,
}

/// The staged long-term-reference tokens a client has acknowledged.
///
/// Separate from [`EncoderState`] because it is written from a different thread on a different
/// cadence — the host actor's recovery arm, not the capture thread — and sharing one lock would put
/// an acknowledgement behind a frame's quantiser decision for no reason.
#[derive(Clone, Debug, Default)]
pub struct AckedTokens {
    staged: Vec<i64>,
}

/// The most recent acknowledgements to keep. The encoder only needs the CURRENT acknowledged set,
/// and acknowledgements arrive while no frame is encoding — a capture stall stages without bound.
const MAX_STAGED_TOKENS: usize = 32;

impl AckedTokens {
    /// An empty set.
    #[must_use]
    pub const fn new() -> Self {
        Self { staged: Vec::new() }
    }

    /// Stages a token, deduplicated and bounded. Answers whether it was new.
    pub fn stage(&mut self, token: i64) -> bool {
        if self.staged.contains(&token) {
            return false;
        }
        self.staged.push(token);
        if self.staged.len() > MAX_STAGED_TOKENS {
            let excess = self.staged.len() - MAX_STAGED_TOKENS;
            self.staged.drain(0..excess);
        }
        true
    }

    /// Drops every staged token, because an intra frame just shipped.
    ///
    /// An IDR clears the decoder's picture buffer, long-term references included — that is the HEVC
    /// specification, not a policy — so an acknowledgement staged before it describes a reference
    /// the client no longer holds, and feeding it to a later encode names a picture that is gone.
    pub fn clear(&mut self) {
        self.staged.clear();
    }

    /// Takes the staged set, leaving it empty.
    pub fn drain(&mut self) -> Vec<i64> {
        core::mem::take(&mut self.staged)
    }

    /// How many are staged.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.staged.len()
    }

    /// Whether none are staged.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.staged.is_empty()
    }
}

/// Every mutable rate-control decision the encoder makes, and none of the calls.
///
/// Deliberately NOT `Copy`, though every field is a scalar. This is a state machine whose whole
/// contract is that one instance is advanced in order — a silent copy taken at a `&mut` call site
/// would advance a duplicate, and the drop-relief integrator, the bracket depth and the write memo
/// would all diverge from the session they describe with nothing to see at the copy.
#[derive(Clone, Debug)]
#[expect(
    missing_copy_implementations,
    reason = "a copied state machine diverges from its session"
)]
pub struct EncoderState {
    config: Config,
    /// The immutable ceiling; the live target is clamped to it and never exceeds it.
    ceiling_bitrate: i64,
    width: i64,
    height: i64,
    fps: i64,

    live_bitrate: i64,
    live_qp_ceiling: i32,
    live_const_qp: i32,
    link_congested: bool,
    drop_relief: DropRelief,
    /// The quantiser last actually written, or `None` when a bracket restore invalidated the memo.
    last_applied_qp: Option<i32>,
    bracket_depth: u32,
    pending_compact_restore: bool,
}

impl EncoderState {
    /// Seeds the state for a session of this geometry at this ceiling.
    ///
    /// The live target starts AT the ceiling — the controller only ever lowers from there — and the
    /// quantiser ceiling starts at whatever that target's budget affords, so the very first frame
    /// is already at the right operating point rather than adapting into it.
    #[must_use]
    pub fn new(config: Config, ceiling_bitrate: i64, width: i64, height: i64, fps: i64) -> Self {
        let ceiling_bitrate = config.clamp_target(ceiling_bitrate, i64::MAX);
        let fps = fps.max(1);
        Self {
            config,
            ceiling_bitrate,
            width,
            height,
            fps,
            live_bitrate: ceiling_bitrate,
            live_qp_ceiling: config.budget_ceiling(ceiling_bitrate, width, height, fps),
            live_const_qp: config.const_qp.unwrap_or(QP_MIN),
            link_congested: false,
            drop_relief: DropRelief::new(),
            last_applied_qp: None,
            bracket_depth: 0,
            pending_compact_restore: false,
        }
    }

    /// The controller's current target, in bits per second.
    #[must_use]
    pub const fn live_bitrate(&self) -> i64 {
        self.live_bitrate
    }

    /// Whether a relaxed bracket currently owns the quantiser property.
    #[must_use]
    pub const fn in_bracket(&self) -> bool {
        self.bracket_depth > 0
    }

    /// The extra quantiser the drop-feedback integrator is currently asking for.
    ///
    /// Readable because it is the one number that explains a ceiling the operator did not ask for:
    /// a stream sitting well above its budget-derived ceiling is a stream that has been dropping,
    /// and without this the host's log can only say what the ceiling is, not why.
    #[must_use]
    pub const fn drop_relief(&self) -> i32 {
        self.drop_relief.relief()
    }

    /// The effective quantiser ceiling every restore and every default-regime frame writes.
    ///
    /// The budget-derived ceiling plus the drop-feedback relief, composed UP TO the static worst
    /// case and never past it. Under a pinned ceiling the budget half equals the bound already, so
    /// relief composes to the same number and the pinned value is honoured verbatim — which is why
    /// there is no separate pinned path.
    #[must_use]
    pub fn current_qp_ceiling(&self) -> i32 {
        self.config
            .max_allowed_frame_qp
            .min(self.live_qp_ceiling.saturating_add(self.drop_relief.relief()))
    }

    /// The rate-control values a freshly created session must be given.
    ///
    /// Read from the LIVE target rather than the ceiling so a session rebuilt mid-stream — a resize
    /// — comes up at the controller's current rate instead of jumping back to the ceiling and
    /// having to be cut down again.
    #[must_use]
    pub fn creation_writes(&self) -> Writes {
        Writes {
            max_qp: Some(self.current_qp_ceiling()),
            // Deliberately absent: the first frame's own regime writes `Min`, and writing it here
            // would pin a floor before the const-QP controller has seen a single network report.
            min_qp: None,
            average_bitrate: Some(self.live_bitrate),
            data_rate: Some(self.config.hard_cap(self.live_bitrate)),
        }
    }

    /// Actuates a new target bitrate. Answers whether it changed, and what to write.
    ///
    /// The target is clamped into `[minimum, ceiling]`, and the budget-derived quantiser ceiling
    /// follows it: sharp while the budget can carry motion, relaxed toward the worst case as it
    /// thins, so the encoder coarsens instead of dropping.
    ///
    /// The quantiser ceiling is NOT written here even though it just moved. The encode entry is the
    /// single writer of that property — it composes the budget ceiling with the drop relief and
    /// deduplicates per frame — and a second writer would flip-flop the property against the
    /// relief-composed value on every actuator tick.
    pub fn set_live_bitrate(&mut self, target: i64) -> (bool, Writes) {
        let clamped = self.config.clamp_target(target, self.ceiling_bitrate);
        // Computed before the fields move, and stored whether or not the rate itself changed: the
        // ceiling is a function of the clamped target, so an unchanged target cannot move it.
        self.live_qp_ceiling = self
            .config
            .budget_ceiling(clamped, self.width, self.height, self.fps);
        let changed = clamped != self.live_bitrate;
        self.live_bitrate = clamped;
        if !changed || self.in_bracket() {
            // Mid-bracket, the active bracket's restore re-reads the live rate and applies it. This
            // is the ONLY place that rate would otherwise be written, which is why the restore
            // writes BOTH knobs from one fresh read rather than only the one it relaxed.
            return (changed, Writes::default());
        }
        (changed, Writes {
            average_bitrate: Some(clamped),
            data_rate: Some(self.config.hard_cap(clamped)),
            ..Writes::default()
        })
    }

    /// Actuates the link controller's current constant quantiser. Answers whether it changed.
    ///
    /// A no-op unless const-QP mode is engaged. Nothing is written here: clearing the memo is what
    /// makes the next live frame re-pin `Min` and `Max`, which keeps this callable from the host
    /// actor on every network report for the cost of a comparison.
    pub fn set_const_qp(&mut self, q: i32) -> bool {
        if self.config.const_qp.is_none() {
            return false;
        }
        let clamped = q.clamp(QP_MIN, QP_MAX);
        let changed = clamped != self.live_const_qp;
        self.live_const_qp = clamped;
        if changed {
            self.last_applied_qp = None;
        }
        changed
    }

    /// Records the controller's congestion verdict. Answers whether it changed.
    ///
    /// On a CLEAN link the decouple band holds `Min` at the sharp floor, so the cheaply skip-coded
    /// static region stays crisp while only the moving body coarsens. On a CONGESTED one `Min` is
    /// re-pinned to `Max`, so a scroll frame stays small rather than fattening for sharpness the
    /// link cannot deliver.
    pub const fn set_link_congested(&mut self, congested: bool) -> bool {
        if self.config.const_qp.is_none() {
            return false;
        }
        let changed = congested != self.link_congested;
        self.link_congested = congested;
        if changed {
            self.last_applied_qp = None;
        }
        changed
    }

    /// Puts a relaxed bracket's configuration back and clears the frame memo.
    ///
    /// Both rate knobs are written from ONE fresh read of the live target, not from whatever the
    /// bracket happened to relax. A crisp bracket only widened the hard cap and a compact one only
    /// lowered the average, but an actuator that landed mid-bracket wrote NEITHER — so restoring
    /// only the relaxed knob leaves the other stale, and a stale hard cap lets a complex frame
    /// overrun a congestion back-off that had already been decided.
    pub fn end_bracket(&mut self) -> Writes {
        self.bracket_depth = self.bracket_depth.saturating_sub(1);
        // The bracket put a different quantiser on the session, so the memo describes a value that
        // is no longer there; the next frame must re-apply its own.
        self.last_applied_qp = None;
        let live = self.live_bitrate;
        Writes {
            max_qp: Some(self.current_qp_ceiling()),
            min_qp: None,
            average_bitrate: Some(live),
            data_rate: Some(self.config.hard_cap(live)),
        }
    }

    /// Settles a deferred compact bracket, if one is outstanding. Called at the START of every
    /// encode so a relaxed configuration can never bleed past its single intra frame.
    pub fn settle_pending_compact(&mut self) -> Option<Writes> {
        if !self.pending_compact_restore {
            return None;
        }
        self.pending_compact_restore = false;
        Some(self.end_bracket())
    }

    /// Opens the CRISP bracket: a near-lossless static refresh.
    ///
    /// The hard rate cap widens so it does not DROP the much larger intra frame, and the quantiser
    /// ceiling drops to visually transparent. Under const-QP the floor comes down with it: the live
    /// path pins `Min` at the const-QP floor, and a crisp `Max` below that floor would ask the
    /// framework for `Min > Max`.
    pub fn begin_crisp(&mut self) -> Bracket {
        let settle = self.settle_pending_compact();
        self.bracket_depth = self.bracket_depth.saturating_add(1);
        Bracket {
            settle,
            drain: true,
            relax: Writes {
                max_qp: Some(self.config.crisp_qp),
                min_qp: self.config.const_qp.map(|_| self.config.crisp_qp),
                average_bitrate: None,
                data_rate: Some(self.config.data_rate_limits(CRISP_DATA_RATE_MAX_BYTES)),
            },
            restore: Restore::Immediate,
        }
    }

    /// Opens the COMPACT bracket: a recovery or heartbeat intra frame small enough to survive a
    /// burst.
    ///
    /// The exact inverse of [`Self::begin_crisp`] — the ceiling RISES and the target FALLS — so the
    /// framework shrinks the forced intra frame by coarsening it rather than by dropping it.
    pub fn begin_compact(&mut self) -> Bracket {
        let settle = self.settle_pending_compact();
        self.bracket_depth = self.bracket_depth.saturating_add(1);
        let lazy = self.config.compact_lazy_restore;
        self.pending_compact_restore = lazy;
        Bracket {
            settle,
            drain: !lazy,
            relax: Writes {
                max_qp: Some(self.config.compact_qp),
                min_qp: None,
                average_bitrate: Some(self.config.compact_bitrate),
                data_rate: None,
            },
            restore: if lazy {
                Restore::Deferred
            } else {
                Restore::Immediate
            },
        }
    }

    /// The quantiser writes for ONE live frame, in whichever of the three regimes is engaged.
    ///
    /// `drops` is how many frames the framework dropped since the last call; `per_frame_max_qp` is
    /// the capturer's content-driven ceiling, absent when adaptive quantisation is off.
    ///
    /// Every regime deduplicates against the last value actually applied, and every regime declines
    /// entirely while a bracket owns the property. A static stream therefore writes NOTHING per
    /// frame, which is the point: the alternative is a bridge and a framework round trip sixty
    /// times a second to set a value that is already set.
    pub fn frame_writes(&mut self, per_frame_max_qp: Option<i32>, drops: i64) -> Writes {
        // Folded unconditionally, before any regime decides anything, though only the default
        // regime READS it. The Swift folded inside that regime's arm and drained its drop counter
        // there too, so under const-QP or per-frame adaptation the counter accumulated for the life
        // of the process and nothing ever emptied it. Folding here is what makes `drops` an input
        // rather than a buried counter, and it is what lets [`Self::drop_relief`] answer honestly
        // in every regime — which is the number a host log needs to explain a coarse
        // stream.
        let relief = self.drop_relief.fold(drops);

        if let Some(_engaged) = self.config.const_qp {
            let floor = self.live_const_qp;
            let q = const_qp_for_frame(floor, per_frame_max_qp);
            let Some(writes) = self.pin(q) else {
                return Writes::default();
            };
            // Holding `Min` at the sharp floor is what keeps the static region crisp while the
            // moving body coarsens, and re-pinning it to `Max` is what keeps a scroll frame small
            // when the link cannot carry the wider band. Decouple off and congestion both pin.
            let min_qp = if self.config.qp_decouple && !self.link_congested {
                floor
            } else {
                q
            };
            return Writes {
                min_qp: Some(min_qp),
                ..writes
            };
        }

        if let Some(q) = per_frame_max_qp {
            return self.pin(q).unwrap_or_default();
        }

        // The default regime: the budget-derived ceiling lifted by the drop relief, which attacks
        // fast and decays slowly, so a burst of drops coarsens the NEXT frames rather than letting
        // them drop too.
        let q = self
            .config
            .max_allowed_frame_qp
            .min(self.live_qp_ceiling.saturating_add(relief));
        self.pin(q).unwrap_or_default()
    }

    /// The shared deduplication: `None` when the value is already applied or a bracket owns the
    /// property, otherwise the write and a note that it is now the applied one.
    fn pin(&mut self, q: i32) -> Option<Writes> {
        if self.in_bracket() || self.last_applied_qp == Some(q) {
            return None;
        }
        self.last_applied_qp = Some(q);
        Some(Writes {
            max_qp: Some(q),
            ..Writes::default()
        })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{AckedTokens, EncoderState, MAX_STAGED_TOKENS, Restore, Writes};
    use crate::encoder_config::{CRISP_DATA_RATE_MAX_BYTES, Config, DEFAULT_BITRATE};
    use crate::live_bitrate::MINIMUM_BITRATE;

    fn config(pairs: &[(&str, &str)]) -> Config {
        let table: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect();
        Config::resolve(&move |key: &str| table.get(key).cloned(), None)
    }

    fn state(pairs: &[(&str, &str)]) -> EncoderState {
        EncoderState::new(config(pairs), DEFAULT_BITRATE, 1920, 1080, 60)
    }

    /// A fresh session is given both rate knobs and a quantiser ceiling, and NOT a floor: writing a
    /// floor before the controller has seen a report would pin one nothing chose.
    #[test]
    fn a_fresh_session_is_given_the_live_rate_and_no_floor() {
        let state = state(&[]);
        let writes = state.creation_writes();
        assert_eq!(writes.average_bitrate, Some(DEFAULT_BITRATE));
        assert_eq!(writes.data_rate, Some(state.config.hard_cap(DEFAULT_BITRATE)));
        assert_eq!(writes.max_qp, Some(state.current_qp_ceiling()));
        assert_eq!(writes.min_qp, None);
    }

    /// A rebuilt session comes up at the CONTROLLER's rate, not the ceiling — a resize mid-stream
    /// must not undo a congestion cut and force it to be re-decided.
    #[test]
    fn a_rebuilt_session_comes_up_at_the_controllers_rate_not_the_ceiling() {
        let mut state = state(&[]);
        let (changed, _) = state.set_live_bitrate(4_000_000);
        assert!(changed);
        assert_eq!(state.creation_writes().average_bitrate, Some(4_000_000));
    }

    /// The actuator clamps on both sides and never writes the quantiser ceiling, even though the
    /// ceiling it stores just moved — the encode entry is that property's single writer.
    #[test]
    fn the_actuator_clamps_both_ways_and_never_writes_the_quantiser() {
        let mut state = state(&[]);
        let (_, writes) = state.set_live_bitrate(i64::MAX);
        assert_eq!(state.live_bitrate(), DEFAULT_BITRATE);
        assert_eq!(writes, Writes::default(), "an unchanged rate writes nothing");

        let (changed, writes) = state.set_live_bitrate(-9);
        assert!(changed);
        assert_eq!(state.live_bitrate(), MINIMUM_BITRATE);
        assert_eq!(writes.average_bitrate, Some(MINIMUM_BITRATE));
        assert!(writes.data_rate.is_some());
        assert_eq!(writes.max_qp, None, "the frame path owns the quantiser ceiling");
    }

    /// INVARIANT 2. An actuation that lands mid-bracket writes NOTHING and is applied by the
    /// restore, from a fresh read — so the new rate reaches the session exactly once and is not
    /// lost until the next actuation.
    #[test]
    fn a_rate_that_lands_mid_bracket_is_applied_by_the_restore_and_not_lost() {
        let mut state = state(&[]);
        let bracket = state.begin_crisp();
        assert_eq!(bracket.restore, Restore::Immediate);

        let (changed, writes) = state.set_live_bitrate(3_000_000);
        assert!(changed, "the target still moves");
        assert_eq!(writes, Writes::default(), "but nothing is written mid-bracket");

        let restore = state.end_bracket();
        assert_eq!(restore.average_bitrate, Some(3_000_000));
        assert_eq!(restore.data_rate, Some(state.config.hard_cap(3_000_000)));
    }

    /// The restore writes BOTH rate knobs, not just the one the bracket relaxed. A crisp bracket
    /// only widened the hard cap; leaving the average stale there would strand a mid-bracket cut,
    /// and the compact case leaves a stale HARD cap, which lets a complex frame overrun a
    /// congestion back-off that had already been decided.
    #[test]
    fn every_restore_writes_both_rate_knobs_whichever_one_it_relaxed() {
        for lazy in ["1", "0"] {
            let mut state = state(&[("SLOPDESK_COMPACT_LAZY_RESTORE", lazy)]);
            let crisp = state.begin_crisp();
            assert_eq!(crisp.relax.average_bitrate, None, "crisp relaxes only the cap");
            let restore = state.end_bracket();
            assert!(restore.average_bitrate.is_some() && restore.data_rate.is_some());

            let compact = state.begin_compact();
            assert_eq!(compact.relax.data_rate, None, "compact relaxes only the average");
            let restore = match compact.restore {
                Restore::Immediate => state.end_bracket(),
                Restore::Deferred => state.settle_pending_compact().unwrap_or_default(),
            };
            assert!(restore.average_bitrate.is_some() && restore.data_rate.is_some());
        }
    }

    /// The crisp bracket widens the cap to the crisp budget and drops the ceiling to the crisp
    /// quantiser. It also drains — restoring before the frame has finished is what silently ships a
    /// SOFT "crisp" refresh, encoded at the live ceiling.
    #[test]
    fn the_crisp_bracket_widens_the_cap_and_sharpens_the_ceiling() {
        let mut state = state(&[]);
        let bracket = state.begin_crisp();
        assert!(bracket.drain);
        assert_eq!(bracket.relax.max_qp, Some(state.config.crisp_qp));
        assert_eq!(
            bracket.relax.data_rate,
            Some(state.config.data_rate_limits(CRISP_DATA_RATE_MAX_BYTES))
        );
        assert_eq!(
            bracket.relax.min_qp, None,
            "no floor to lower when const-QP is off"
        );
    }

    /// Under const-QP the crisp bracket lowers the FLOOR too, because the live path pins `Min` at
    /// the const-QP floor and a crisp `Max` below it would ask the framework for `Min > Max`.
    #[test]
    fn a_crisp_bracket_under_const_qp_lowers_the_floor_so_min_never_exceeds_max() {
        let mut state = state(&[("SLOPDESK_CONST_QP", "34")]);
        let bracket = state.begin_crisp();
        let (min, max) = (bracket.relax.min_qp, bracket.relax.max_qp);
        assert_eq!(min, Some(state.config.crisp_qp));
        assert_eq!(max, Some(state.config.crisp_qp));
        assert!(min <= max);
    }

    /// The compact bracket is the crisp one inverted: the ceiling RISES and the target FALLS, so
    /// the framework shrinks the forced intra frame by coarsening rather than by dropping.
    #[test]
    fn the_compact_bracket_is_the_crisp_one_inverted() {
        let mut state = state(&[]);
        let crisp = state.begin_crisp();
        let _ = state.end_bracket();
        let compact = state.begin_compact();
        let (crisp_qp, compact_qp) = (crisp.relax.max_qp, compact.relax.max_qp);
        assert!(
            crisp_qp.is_some() && compact_qp > crisp_qp,
            "{compact_qp:?} must coarsen past {crisp_qp:?}"
        );
        assert!(compact.relax.average_bitrate.unwrap_or(i64::MAX) < DEFAULT_BITRATE);
    }

    /// The default compact bracket DEFERS its restore and does not drain. Two drains at ~115 ms of
    /// blocked capture each, six times a second under a recovery storm, IS the scroll judder.
    #[test]
    fn the_default_compact_bracket_defers_its_restore_and_never_drains() {
        let mut state = state(&[]);
        let bracket = state.begin_compact();
        assert_eq!(bracket.restore, Restore::Deferred);
        assert!(!bracket.drain);
        assert!(
            state.in_bracket(),
            "the relaxed configuration is still on the session"
        );

        let restore = state.settle_pending_compact().unwrap_or_default();
        assert!(!restore.is_empty());
        assert!(!state.in_bracket());
        assert!(
            state.settle_pending_compact().is_none(),
            "settling twice is a no-op"
        );
    }

    /// Turning lazy restore off takes the drain-bracketed path, whose restore the caller issues.
    #[test]
    fn disabling_lazy_restore_takes_the_drain_bracketed_path() {
        let mut state = state(&[("SLOPDESK_COMPACT_LAZY_RESTORE", "0")]);
        let bracket = state.begin_compact();
        assert_eq!(bracket.restore, Restore::Immediate);
        assert!(bracket.drain);
        assert!(state.settle_pending_compact().is_none(), "nothing was deferred");
        let _ = state.end_bracket();
        assert!(!state.in_bracket());
    }

    /// A bracket opened while a deferred one is outstanding SETTLES it first. Two overlapping
    /// relaxed configurations would restore the wrong one, and the second restore would put the
    /// FIRST bracket's relaxed values back as if they were live.
    #[test]
    fn opening_a_bracket_settles_an_outstanding_deferred_one_first() {
        let mut state = state(&[]);
        let _ = state.begin_compact();
        let crisp = state.begin_crisp();
        let settle = crisp.settle.unwrap_or_default();
        assert!(!settle.is_empty(), "the compact bracket's restore rides in front");
        assert_eq!(settle.max_qp, Some(state.current_qp_ceiling()));
        assert!(state.settle_pending_compact().is_none());
        // Depth is back to exactly one — the crisp bracket's — so its restore fully unwinds.
        let _ = state.end_bracket();
        assert!(!state.in_bracket());
    }

    /// And a second compact settles the first, rather than nesting two deferred restores onto one
    /// flag where the second would be silently dropped.
    #[test]
    fn a_second_compact_settles_the_first_rather_than_nesting() {
        let mut state = state(&[]);
        let _ = state.begin_compact();
        let second = state.begin_compact();
        assert!(second.settle.is_some());
        let _ = state.settle_pending_compact();
        assert!(!state.in_bracket());
    }

    /// INVARIANT 1. No frame writes the quantiser while a bracket owns it, in ANY regime — a frame
    /// that did would undo the relaxation mid-intra and produce exactly the soft crisp frame or fat
    /// compact frame the bracket exists to prevent.
    #[test]
    fn no_regime_writes_the_quantiser_while_a_bracket_owns_it() {
        for env in [vec![], vec![("SLOPDESK_CONST_QP", "30")], vec![(
            "SLOPDESK_MAX_QP",
            "44",
        )]] {
            let mut state = state(&env);
            let _ = state.begin_crisp();
            for per_frame in [None, Some(20), Some(48)] {
                let writes = state.frame_writes(per_frame, 3);
                assert_eq!(writes, Writes::default(), "{env:?} / {per_frame:?}");
            }
        }
    }

    /// INVARIANT 3. A restore clears the memo, so the very next frame re-applies its own ceiling
    /// rather than believing the bracket's value is its own.
    #[test]
    fn a_restore_clears_the_memo_so_the_next_frame_re_applies_its_ceiling() {
        let mut state = state(&[]);
        let first = state.frame_writes(None, 0);
        assert!(first.max_qp.is_some(), "the first frame always applies");
        assert_eq!(
            state.frame_writes(None, 0),
            Writes::default(),
            "then it deduplicates"
        );

        let _ = state.begin_crisp();
        let _ = state.end_bracket();
        assert_eq!(
            state.frame_writes(None, 0).max_qp,
            first.max_qp,
            "re-applied, not deduplicated"
        );
    }

    /// The static hot path writes NOTHING per frame. Sixty times a second, the alternative is a
    /// bridge and a framework round trip to set a value that is already set.
    #[test]
    fn a_static_stream_writes_nothing_at_all_per_frame() {
        for env in [vec![], vec![("SLOPDESK_CONST_QP", "30")]] {
            let mut state = state(&env);
            assert!(
                !state.frame_writes(None, 0).is_empty(),
                "{env:?}: the first frame applies"
            );
            for _ in 0..600 {
                assert!(state.frame_writes(None, 0).is_empty(), "{env:?}");
            }
        }
    }

    /// Under const-QP a static frame pins `Min == Max == floor`; motion raises BOTH ends when the
    /// band is off. Pinning rather than merely capping is hardware-required: the const-QP bitrate
    /// backstop leaves the framework no budget pressure, so a ceiling alone never bites and the
    /// scroll frame stays fat.
    #[test]
    fn const_qp_pins_both_ends_when_the_band_is_off() {
        let mut state = state(&[("SLOPDESK_CONST_QP", "30"), ("SLOPDESK_QP_DECOUPLE", "0")]);
        let statik = state.frame_writes(None, 0);
        assert_eq!((statik.min_qp, statik.max_qp), (Some(30), Some(30)));
        let motion = state.frame_writes(Some(44), 0);
        assert_eq!((motion.min_qp, motion.max_qp), (Some(44), Some(44)));
    }

    /// With the band on and the link CLEAN, motion holds `Min` at the sharp floor so the cheaply
    /// skip-coded static region stays crisp while only the moving body coarsens.
    #[test]
    fn a_clean_link_holds_the_floor_sharp_while_only_the_body_coarsens() {
        let mut state = state(&[("SLOPDESK_CONST_QP", "30")]);
        let motion = state.frame_writes(Some(44), 0);
        assert_eq!((motion.min_qp, motion.max_qp), (Some(30), Some(44)));
    }

    /// Congestion collapses the band back onto `Max`, so a scroll frame stays small rather than
    /// fattening for a sharpness the link cannot carry. The verdict also clears the memo, so it
    /// takes effect on the NEXT frame rather than whenever the quantiser next happens to move.
    #[test]
    fn congestion_collapses_the_band_onto_the_ceiling_on_the_very_next_frame() {
        let mut state = state(&[("SLOPDESK_CONST_QP", "30")]);
        let clean = state.frame_writes(Some(44), 0);
        assert_eq!(clean.min_qp, Some(30));
        assert_eq!(
            state.frame_writes(Some(44), 0),
            Writes::default(),
            "deduplicated while nothing moves"
        );

        assert!(state.set_link_congested(true));
        let congested = state.frame_writes(Some(44), 0);
        assert_eq!((congested.min_qp, congested.max_qp), (Some(44), Some(44)));

        assert!(state.set_link_congested(false));
        let restored = state.frame_writes(Some(44), 0);
        assert_eq!(restored.min_qp, Some(30));
    }

    /// A motion ceiling BELOW the floor is clamped up to it: the floor is a sharpness guarantee,
    /// and a frame is never allowed to be sharper than the controller decided the link can
    /// carry.
    #[test]
    fn a_motion_ceiling_below_the_floor_never_sharpens_past_the_guarantee() {
        let mut state = state(&[("SLOPDESK_CONST_QP", "30")]);
        let writes = state.frame_writes(Some(12), 0);
        assert_eq!((writes.min_qp, writes.max_qp), (Some(30), Some(30)));
    }

    /// A const-QP nudge takes effect on the next frame, and both ends move with it.
    #[test]
    fn a_const_qp_nudge_re_pins_both_ends_on_the_next_frame() {
        let mut state = state(&[("SLOPDESK_CONST_QP", "30")]);
        let _ = state.frame_writes(None, 0);
        assert!(state.set_const_qp(41));
        let writes = state.frame_writes(None, 0);
        assert_eq!((writes.min_qp, writes.max_qp), (Some(41), Some(41)));
        assert!(!state.set_const_qp(41), "an unchanged nudge is a no-op");
    }

    /// The const-QP actuators are inert when the mode is off, so a host that calls them
    /// unconditionally cannot disturb the default regime.
    #[test]
    fn the_const_qp_actuators_are_inert_when_the_mode_is_off() {
        let mut state = state(&[]);
        assert!(!state.set_const_qp(20));
        assert!(!state.set_link_congested(true));
        let writes = state.frame_writes(None, 0);
        assert_eq!(writes.min_qp, None, "the default regime never writes a floor");
    }

    /// Drops lift the ceiling so the NEXT frames coarsen instead of dropping too, and the lift
    /// decays back once frames come clean.
    #[test]
    fn drops_lift_the_ceiling_and_the_lift_decays_when_frames_come_clean() {
        let mut state = state(&[]);
        let base = state.frame_writes(None, 0).max_qp.unwrap_or_default();
        let lifted = state.frame_writes(None, 8).max_qp.unwrap_or_default();
        assert!(lifted > base, "{lifted} should exceed {base}");

        let mut settled = lifted;
        for _ in 0..4_000 {
            if let Some(q) = state.frame_writes(None, 0).max_qp {
                settled = q;
            }
        }
        assert_eq!(settled, base, "the lift decays all the way back");
    }

    /// The relief integrates in EVERY regime, not only the one that reads it. The Swift folded it
    /// inside the default arm and drained its counter there, so under const-QP the drop counter
    /// accumulated for the life of the process and nothing ever emptied it — and the number a host
    /// log needs to explain a coarse stream read zero in exactly the mode most likely to produce
    /// one.
    #[test]
    fn the_relief_integrates_in_every_regime_even_the_ones_that_do_not_read_it() {
        for env in [vec![], vec![("SLOPDESK_CONST_QP", "30")], vec![(
            "SLOPDESK_MAX_QP",
            "44",
        )]] {
            let mut state = state(&env);
            assert_eq!(state.drop_relief(), 0, "{env:?}");
            for _ in 0..12 {
                let _ = state.frame_writes(Some(40), 4);
            }
            assert!(
                state.drop_relief() > 0,
                "{env:?}: the drops were integrated regardless"
            );
        }
    }

    /// The composed ceiling never passes the static worst case, whatever the relief has integrated.
    /// Under a PINNED ceiling that bound is the pinned value, which is what makes the pin verbatim.
    #[test]
    fn relief_can_never_lift_the_ceiling_past_the_pinned_bound() {
        let mut state = state(&[("SLOPDESK_MAX_QP", "38")]);
        for _ in 0..200 {
            let _ = state.frame_writes(None, 30);
            assert!(state.current_qp_ceiling() <= 38);
        }
        assert_eq!(state.frame_writes(None, 30).max_qp.unwrap_or(38), 38);
    }

    /// Lowering the target relaxes the budget-derived ceiling, so the encoder coarsens rather than
    /// dropping as the budget thins.
    #[test]
    fn a_thinner_budget_relaxes_the_ceiling_rather_than_forcing_drops() {
        let mut state = state(&[]);
        let rich = state.current_qp_ceiling();
        let _ = state.set_live_bitrate(MINIMUM_BITRATE);
        assert!(state.current_qp_ceiling() > rich);
    }

    /// A token is staged once, however many times it arrives — acknowledgements repeat while no
    /// frame is encoding.
    #[test]
    fn a_token_is_staged_once_however_often_it_arrives() {
        let mut tokens = AckedTokens::new();
        assert!(tokens.stage(7));
        assert!(!tokens.stage(7));
        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens.drain(), vec![7]);
        assert!(tokens.is_empty());
        assert!(tokens.drain().is_empty());
    }

    /// The staging list is BOUNDED and keeps the most RECENT: a capture stall stages without bound,
    /// and the encoder only needs the current acknowledged set.
    #[test]
    fn the_staging_list_is_bounded_and_keeps_the_most_recent() {
        let mut tokens = AckedTokens::new();
        for token in 0..200_i64 {
            assert!(tokens.stage(token));
            assert!(tokens.len() <= MAX_STAGED_TOKENS);
        }
        let staged = tokens.drain();
        assert_eq!(staged.len(), MAX_STAGED_TOKENS);
        let cap = i64::try_from(MAX_STAGED_TOKENS).unwrap_or(i64::MAX);
        assert_eq!(staged.first(), Some(&(200 - cap)));
        assert_eq!(staged.last(), Some(&199));
    }

    /// An intra frame clears every staged token. The picture buffer is flushed by the
    /// specification, long-term references included, so a pre-intra acknowledgement names a
    /// reference that is gone.
    #[test]
    fn an_intra_frame_clears_every_staged_token() {
        let mut tokens = AckedTokens::new();
        for token in 0..5 {
            assert!(tokens.stage(token));
        }
        tokens.clear();
        assert!(tokens.is_empty());
    }
}
