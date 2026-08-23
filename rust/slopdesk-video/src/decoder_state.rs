//! Every decision the client's decoder makes, with no decoder anywhere near it.
//!
//! The Swift original had these interleaved with the `VTDecompressionSession` calls, which is why
//! three of the four carried a test seam — a `cachedParameterSetsForTesting` getter and a
//! `seedCachedParameterSetsForTesting` setter existed solely so a test could model a configured
//! decoder without creating a session. They are gone: here the state IS the value, and a test
//! builds one by calling the constructor.
//!
//! Four decisions live here, and the reason each is a decision rather than a call:
//!
//! 1. **Whether a keyframe is worth rebuilding the session for.** The heartbeat IDR arrives about
//!    once a second and every forced-recovery IDR arrives on demand, and on a steady stream all of
//!    them carry byte-identical parameter sets. Rebuilding for each would be a teardown and a
//!    warmup once a second on a healthy stream.
//! 2. **What a hard failure does to that cache.** It clears it, and that is the whole difference
//!    between a recoverable decoder and a permanently frozen pane: on a fixed-capture-size stream
//!    the recovery IDR carries the SAME sets, so a cache that survived the failure would answer "no
//!    rebuild needed" and hand the next frame to the same malfunctioning session, forever.
//! 3. **What an empty frame means.** `client_view`'s [`FrameDecodability`] already owned this one,
//!    and it is threaded through here rather than re-decided.
//! 4. **How the decode wall folds.** A first sample seeds the average whole; later ones fold at a
//!    fixed weight. Seeding rather than starting from zero is what keeps the stats HUD from showing
//!    a warmup ramp that no decode ever took.

use crate::client_view::FrameDecodability;
use crate::hevc_parameter_sets::ParameterSets;

/// The EWMA weight the decode wall folds at — the encode pacer's, so the two axes of the stats HUD
/// have the same memory and a reader can compare them.
///
/// About a four-frame memory: `0.25` weights the newest sample a quarter and the running average
/// three quarters, so a single slow decode moves the reading without redrawing it.
pub const DECODE_EWMA_ALPHA: f64 = 0.25;

/// Folds one decode-wall sample into a running average, in milliseconds.
///
/// The FIRST sample seeds the average whole rather than folding against zero. Folding against zero
/// would show a quarter of the real figure on the first decode and take a dozen frames to climb,
/// which reads as a decoder warming up and is really just an average that started in the wrong
/// place.
#[must_use]
pub fn fold_decode_ewma(current: f64, sample_ms: f64) -> f64 {
    if current > 0.0 {
        let kept = current * (1.0 - DECODE_EWMA_ALPHA);
        let added = sample_ms * DECODE_EWMA_ALPHA;
        kept + added
    } else {
        sample_ms
    }
}

/// Whether `SLOPDESK_DISPLAY_IMMEDIATE` leaves present-on-decode on. Default ON; `=0` turns it off.
///
/// The knob exists because the behaviour was cloned from a competitor's decoder rather than
/// derived, so it ships with a way back. What it does is stamp every sample "emit the instant you
/// decode it" rather than letting the decoder hold it for reorder — belt and braces over the
/// encoder's own `AllowFrameReordering false`, and the failure it prevents is silent: a decoder
/// that still advertised reorder capacity would hold the frame inside a SYNCHRONOUS decode, and the
/// caller would see a call that succeeded and produced no pixels.
pub fn display_immediate(read: &dyn Fn(&str) -> Option<String>) -> bool {
    // The project's default-ON idiom, verbatim: only an explicit `0` turns it off, so an empty or
    // misspelt value leaves the safe behaviour in place rather than silently disabling it.
    read("SLOPDESK_DISPLAY_IMMEDIATE").as_deref() != Some("0")
}

/// What the caller must do before it can hand a frame to the decoder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Admission {
    /// Drop it and say nothing. An empty DELTA: the reassembler's loss recovery covers a real gap,
    /// and one empty fragment does not warrant a re-anchor.
    Drop,
    /// Ask the host for a fresh keyframe, WITHOUT tearing the session down. An empty keyframe, or a
    /// delta that arrived before anything configured the session.
    NeedKeyframe,
    /// Rebuild the session from these parameter sets, then submit.
    Configure(ParameterSets),
    /// Submit against the running session.
    Submit,
}

/// The client decoder's whole state: what the live session was built from, and how it is running.
///
/// `parameter_sets` being `Some` is exactly "there is a live session", which is why the two are one
/// field rather than two that can disagree. The Swift carried them separately — a `session`, a
/// `formatDescription` and a `currentParameterSets` — and one path set the description without the
/// sets specifically so a later identical keyframe would not wrongly reuse it. That path does not
/// exist here because the disagreement it defended against cannot be spelled.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DecoderState {
    parameter_sets: Option<ParameterSets>,
    decode_ms_ewma: f64,
}

impl DecoderState {
    /// A decoder that has never configured and never decoded.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The parameter sets the live session was built from, or `None` when there is no session.
    #[must_use]
    pub const fn parameter_sets(&self) -> Option<&ParameterSets> {
        self.parameter_sets.as_ref()
    }

    /// The decode-wall average in milliseconds; `0` when nothing has decoded yet.
    #[must_use]
    pub const fn decode_ms_ewma(&self) -> f64 {
        self.decode_ms_ewma
    }

    /// Folds one decode-wall sample.
    pub fn note_decode_wall(&mut self, sample_ms: f64) {
        self.decode_ms_ewma = fold_decode_ewma(self.decode_ms_ewma, sample_ms);
    }

    /// What to do with a frame, given its keyframe flag and — if it is one — the sets it carries.
    ///
    /// `carried` is what [`crate::hevc_parameter_sets::extract`] found, which is `None` both for a
    /// delta and for a keyframe whose sets are incomplete. The two are not the same thing, and the
    /// keyframe flag is what tells them apart: an incomplete keyframe cannot configure anything, so
    /// it falls through to the running session if there is one and asks for another if there is
    /// not.
    #[must_use]
    pub fn admit(&self, keyframe: bool, byte_count: usize, carried: Option<&ParameterSets>) -> Admission {
        match FrameDecodability::classify(keyframe, byte_count) {
            FrameDecodability::DropSilently => return Admission::Drop,
            FrameDecodability::RequestKeyframe => return Admission::NeedKeyframe,
            FrameDecodability::Decodable => {},
        }
        if let Some(sets) = carried
            && self.parameter_sets.as_ref() != Some(sets)
        {
            return Admission::Configure(sets.clone());
        }
        if self.parameter_sets.is_some() {
            Admission::Submit
        } else {
            // A delta before any anchor. Not a failure — a client that joined a live stream mid-GOP
            // is in exactly this state — so it asks rather than tearing anything down.
            Admission::NeedKeyframe
        }
    }

    /// Records that a session was built from `sets` and is now live.
    ///
    /// Called only AFTER the build succeeded, so a failed configure leaves the cache describing the
    /// session that is actually running — which for a first configure is none at all.
    pub fn configured(&mut self, sets: ParameterSets) {
        self.parameter_sets = Some(sets);
    }

    /// Records a HARD failure: the session is gone and the next keyframe must rebuild.
    ///
    /// Clearing the cache is the point. On a fixed-capture-size stream the recovery keyframe
    /// carries byte-identical sets, so a cache that survived would answer [`Admission::Submit`]
    /// and hand the next frame to the session that just failed — permanently, since nothing
    /// else ever clears it. The Swift original had this, and its comment recorded the freeze it
    /// was written to fix.
    pub fn invalidated(&mut self) {
        self.parameter_sets = None;
    }
}

#[cfg(test)]
mod tests {
    use super::{Admission, DECODE_EWMA_ALPHA, DecoderState, display_immediate, fold_decode_ewma};
    use crate::hevc_parameter_sets::ParameterSets;

    fn sets(vps: u8, sps: u8, pps: u8) -> ParameterSets {
        ParameterSets {
            vps: vec![vps],
            sps: vec![sps],
            pps: vec![pps],
        }
    }

    fn configured() -> DecoderState {
        let mut state = DecoderState::new();
        state.configured(sets(0x40, 0x42, 0x44));
        state
    }

    /// The first sample IS the average. A fold against zero would report a quarter of the real
    /// figure and climb for a dozen frames, which reads as a warmup no decode ever took.
    #[test]
    fn the_first_sample_seeds_the_average_whole() {
        assert!((fold_decode_ewma(0.0, 1.2) - 1.2).abs() < f64::EPSILON);
    }

    /// Later samples fold at the weight, and the arithmetic is the one the encode pacer uses.
    #[test]
    fn later_samples_fold_at_the_shared_weight() {
        let kept = 1.2 * (1.0 - DECODE_EWMA_ALPHA);
        let added = 4.0 * DECODE_EWMA_ALPHA;
        assert!((fold_decode_ewma(1.2, 4.0) - (kept + added)).abs() < f64::EPSILON);
    }

    /// A steady stream of the same figure converges on it rather than drifting past.
    #[test]
    fn a_steady_stream_converges_on_what_it_is_fed() {
        let mut state = DecoderState::new();
        for _ in 0..200 {
            state.note_decode_wall(3.0);
        }
        assert!((state.decode_ms_ewma() - 3.0).abs() < 1e-9);
    }

    /// An empty DELTA is dropped in silence; an empty KEYFRAME asks for another. Neither touches
    /// the session, which is the difference between this triage and a decode failure.
    #[test]
    fn an_empty_frame_never_reaches_the_decoder() {
        let state = configured();
        assert_eq!(state.admit(false, 0, None), Admission::Drop);
        assert_eq!(state.admit(true, 0, None), Admission::NeedKeyframe);
    }

    /// A keyframe carrying the sets the session already runs SUBMITS. This is the heartbeat IDR,
    /// once a second, forever — and a rebuild here is a teardown and a warmup on a healthy stream.
    #[test]
    fn a_byte_identical_keyframe_does_not_rebuild_the_session() {
        let state = configured();
        assert_eq!(
            state.admit(true, 900, Some(&sets(0x40, 0x42, 0x44))),
            Admission::Submit
        );
    }

    /// Any one of the three sets differing rebuilds — a real resolution change moves the SPS, but
    /// the check is on all three, because a stream whose PPS changed and whose SPS did not is still
    /// a stream the running session cannot decode.
    #[test]
    fn a_difference_in_any_of_the_three_sets_rebuilds() {
        let state = configured();
        for changed in [
            sets(0x4F, 0x42, 0x44),
            sets(0x40, 0x4F, 0x44),
            sets(0x40, 0x42, 0x4F),
        ] {
            assert_eq!(
                state.admit(true, 900, Some(&changed)),
                Admission::Configure(changed.clone()),
                "{changed:?} should rebuild",
            );
        }
    }

    /// The invariant the whole cache exists for: a hard failure clears it, so the byte-identical
    /// recovery keyframe that follows REBUILDS instead of being handed to the session that failed.
    /// Without this the pane freezes permanently on a fixed-size stream, and nothing reports it.
    #[test]
    fn a_hard_failure_makes_the_identical_recovery_keyframe_rebuild() {
        let mut state = configured();
        let recovery = sets(0x40, 0x42, 0x44);
        assert_eq!(state.admit(true, 900, Some(&recovery)), Admission::Submit);
        state.invalidated();
        assert_eq!(state.parameter_sets(), None);
        assert_eq!(
            state.admit(true, 900, Some(&recovery)),
            Admission::Configure(recovery),
            "the same bytes must rebuild once the session is gone",
        );
    }

    /// A delta before any anchor ASKS rather than failing. A client joining a live stream mid-GOP
    /// is in exactly this state, and it is not an error — the host's recovery policy absorbs the
    /// request as a duplicate when it just sent one.
    #[test]
    fn a_delta_before_any_anchor_asks_for_one() {
        let state = DecoderState::new();
        assert_eq!(state.admit(false, 900, None), Admission::NeedKeyframe);
    }

    /// An INCOMPLETE keyframe — one whose sets could not all be found — is not a configure and not
    /// a drop. With a session running it submits, because the coded slice may still decode against
    /// it; with none it asks. The two cases are told apart by the cache, not by the flag.
    #[test]
    fn a_keyframe_whose_sets_are_incomplete_falls_through_rather_than_configuring() {
        assert_eq!(configured().admit(true, 900, None), Admission::Submit);
        assert_eq!(
            DecoderState::new().admit(true, 900, None),
            Admission::NeedKeyframe
        );
    }

    /// Present-on-decode is ON unless the knob is exactly `0` — the project's default-ON idiom, in
    /// which `false` is NOT an off-switch. Pinned because getting this backwards would silently
    /// hand the decoder its reorder buffer back, and the symptom is a synchronous decode that
    /// emits nothing.
    #[test]
    fn present_on_decode_is_on_unless_it_is_turned_off() {
        for (raw, expected) in [
            (None, true),
            (Some("1"), true),
            (Some(""), true),
            (Some("false"), true),
            (Some("0"), false),
        ] {
            let read = |_: &str| raw.map(str::to_owned);
            assert_eq!(display_immediate(&read), expected, "{raw:?}");
        }
    }
}
