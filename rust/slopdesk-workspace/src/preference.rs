//! What the preference SURFACE decides, once the file has already been resolved.
//!
//! The settings themselves are `slopdesk-settings`: every key, its domain, its default, and the
//! resolver that reads a `config.toml` against that table. Nothing here restates any of that — a
//! rule in this module never learns a PATH, never holds a default and never repairs a token,
//! because all three of those are answered one crate down before a value reaches this side at all.
//!
//! What is left is the three decisions the app makes ABOUT its own preference surface, none of
//! which a config file can state:
//!
//! - [`state_suite_source`] — which `UserDefaults` store this process binds. Not a setting: the
//!   four keys it backs are things the app LEARNED (a window frame, a panel width), and which store
//!   they land in is decided by whether this process is a test worker.
//! - [`zoom`] and [`effective_font_size`] — the runtime font-size band ⌘± moves inside. Also not a
//!   setting: the size the FILE may state is `terminal.font-size`, whose domain is the table's
//!   (`4.0..=96.0`); this is the much narrower band a KEY PRESS may reach, and it is deliberately
//!   ephemeral — zooming is a thing you do to read a stack trace, not a preference you are stating.
//! - [`hint_patterns`] — the zip of the two parallel Hint Mode lists. The file carries the regexes
//!   and their actions as two arrays rather than an array of tables, because the common case (a
//!   pattern with no action) would otherwise be noisier to write than the whole feature is worth.
//!   So the pairing is this side's rule, and it has three cases the file's shape cannot express.
//!
//! ## Nothing here learns a string
//!
//! [`hint_patterns`] is handed one EMPTINESS flag per entry of each list and answers [`HintSlot`]s
//! — positions into the pattern list the caller still holds — for the same reason
//! [`push`](crate::store_rollup::push) is handed roles: a regex and its action template are the
//! user's own text, the rule reads exactly one bit of each, and marshalling them across to have
//! them handed back unchanged would be the whole cost of the feature for nothing.
//!
//! [`state_suite_source`] is the same shape at a different width: it answers WHICH of the three
//! candidates wins, and the caller reads back the name it already had.

/// Which store this process binds its per-session STATE to.
///
/// A verdict rather than a name: the two candidate names are the caller's — one is derived from its
/// own pid, the other is a value out of its own environment — and this rule reads no character of
/// either beyond whether the second is empty.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SuiteSource {
    /// The system's standard domain. What the shipping app binds, and what an empty or absent
    /// environment override falls back to.
    Standard,
    /// A per-process throwaway suite, because this process is an `XCTest` worker.
    TestProcess,
    /// The suite an automation run named in the environment.
    Environment,
}

/// Which suite wins, given the two things that can ask for one.
///
/// The `XCTest` per-process suite goes FIRST, outright: `swift test --parallel` runs many xctest
/// processes that all share one standard domain through `cfprefsd`, so state written in one worker
/// races a read in another — and a stray automation variable exported in a developer's shell must
/// never be able to collapse those workers back onto a single domain.
///
/// An EMPTY environment value is no value. `FOO="${BAR}"` with `BAR` unset is how a shell delivers
/// one by accident, and a store named the empty string is not one anybody meant to name. That is
/// also why the absent case and the empty case answer the same thing here rather than being told
/// apart: they are the same decision, so a presence flag would name a distinction nothing
/// downstream could act on.
#[must_use]
pub const fn state_suite_source(under_test: bool, named: Option<&str>) -> SuiteSource {
    if under_test {
        SuiteSource::TestProcess
    } else if names_a_suite(named) {
        SuiteSource::Environment
    } else {
        SuiteSource::Standard
    }
}

/// Whether an environment value NAMES a suite. An absent one does not, and neither does an empty
/// one — the two are the same decision, which is why they are not told apart.
const fn names_a_suite(named: Option<&str>) -> bool {
    match named {
        Some(name) => !name.is_empty(),
        None => false,
    }
}

/// The smallest point size ⌘- can reach.
pub const FONT_SIZE_MIN: f64 = 8.0;

/// The largest point size ⌘+ can reach.
///
/// This band is NOT `terminal.font-size`'s domain, which is the key table's (`4.0..=96.0`) and
/// belongs to what a reader may write in their own file. This is the narrower one a key press may
/// walk to, and the two are allowed to differ: a file that states `2.0` is a file that meant it,
/// where a chord held down against the edge is somebody leaning on a key.
pub const FONT_SIZE_MAX: f64 = 32.0;

/// How many points one press of ⌘+ or ⌘- moves.
pub const FONT_SIZE_STEP: f64 = 1.0;

/// `size` held inside the zoom band, NaN-faithfully.
///
/// [`f64::max`] and [`f64::min`] rather than a `<`/`>` ternary or [`f64::clamp`], and the
/// difference is not cosmetic: both of these are IEEE-ordered, so a `NaN` takes the bound rather
/// than propagating through it, and `f64::clamp` would additionally assert its own arguments are
/// ordered. The answer is therefore always a finite point size inside the band, for EVERY input —
/// which is what lets [`zoom`] below compare two of them by subtraction.
#[must_use]
pub const fn clamp_font_size(size: f64) -> f64 {
    f64::max(FONT_SIZE_MIN, f64::min(FONT_SIZE_MAX, size))
}

/// The size the terminal is drawing at: what the file states, plus whatever ⌘± has moved it by,
/// held inside the band.
#[must_use]
pub fn effective_font_size(configured: f64, delta: f64) -> f64 {
    clamp_font_size(configured + delta)
}

/// One press of the three zoom chords.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Zoom {
    /// ⌘+ / ⌘= — one step bigger.
    In,
    /// ⌘- — one step smaller.
    Out,
    /// ⌘0 — back to the size the config file states.
    Reset,
}

/// The NEW runtime delta one press lands on, or `None` when the press moves nothing.
///
/// `None` is the load-bearing half. A ⌘± held down against the edge of the band would otherwise
/// re-publish an identical terminal configuration on every repeat, and the broadcaster bumps its
/// generation UNCONDITIONALLY — so every one of those would rebuild each live terminal's config and
/// re-measure its grid. The refusal is what keeps a held key from becoming a flashing window.
///
/// ⌘0 refuses the same way for the same reason: a reset at a delta of zero has nothing to reset.
#[must_use]
pub fn zoom(configured: f64, delta: f64, press: Zoom) -> Option<f64> {
    let effective = effective_font_size(configured, delta);
    match press {
        Zoom::Reset => (delta != 0.0).then_some(0.0),
        Zoom::In => landed(configured, effective, effective + FONT_SIZE_STEP),
        Zoom::Out => landed(configured, effective, effective - FONT_SIZE_STEP),
    }
}

/// The delta that puts the terminal at `requested`, or `None` when `requested` clamps back to where
/// it already is.
///
/// The comparison is a SUBTRACTION against zero rather than an equality between two sizes, and it
/// is the same predicate: [`clamp_font_size`] answers inside `[FONT_SIZE_MIN, FONT_SIZE_MAX]` for
/// every input — a NaN takes a bound rather than propagating — so both sides here are finite, and
/// the difference of two finite doubles is zero exactly when they are equal.
fn landed(configured: f64, effective: f64, requested: f64) -> Option<f64> {
    let clamped = clamp_font_size(requested);
    let step = clamped - effective;
    (step != 0.0).then_some(clamped - configured)
}

/// One resolved Hint Mode pattern, as a POSITION in the caller's own pattern list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HintSlot {
    /// Which entry of `controls.hint-patterns` this slot's regex is.
    pub pattern: usize,
    /// Whether the entry of `controls.hint-pattern-actions` at the SAME index carries a template.
    pub has_action: bool,
}

/// Zip the two parallel Hint Mode lists, as slots into the pattern list.
///
/// Both arguments carry one EMPTINESS flag per entry, in the file's own order. Three cases, and
/// each one is a thing a hand-written file does:
///
/// - **An empty PATTERN is dropped.** An empty regex matches everything, so a stray `""` left in
///   the array while editing would label every character on screen.
/// - **An action list SHORTER than the pattern list** leaves the trailing patterns without one.
///   This is the common shape: actions are the exception, so a reader writes as many as they need
///   and stops.
/// - **An empty ACTION is no action**, exactly as an absent one is. A zero-length template and a
///   missing template behave identically at the actuation site, so telling them apart would name a
///   distinction nothing downstream can act on.
///
/// The index a slot names is the pattern's position in the ORIGINAL list, not in the answer — which
/// is what keeps the pairing intact across a dropped entry.
#[must_use]
pub fn hint_patterns(patterns_empty: &[bool], actions_empty: &[bool]) -> Vec<HintSlot> {
    patterns_empty
        .iter()
        .enumerate()
        .filter(|&(_, empty)| !*empty)
        .map(|(pattern, _)| {
            HintSlot {
                pattern,
                has_action: actions_empty.get(pattern).is_some_and(|empty| !*empty),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        FONT_SIZE_MAX, FONT_SIZE_MIN, HintSlot, SuiteSource, Zoom, clamp_font_size, effective_font_size,
        hint_patterns, state_suite_source, zoom,
    };

    /// The `XCTest` suite wins outright — an automation variable exported in a developer's shell
    /// must not be able to redirect a parallel worker's writes back onto one shared domain.
    #[test]
    fn the_test_process_suite_outranks_the_environment() {
        assert_eq!(state_suite_source(true, Some("run.42")), SuiteSource::TestProcess);
        assert_eq!(state_suite_source(true, None), SuiteSource::TestProcess);
    }

    /// Outside a test process the environment is read, and an empty value is no value.
    #[test]
    fn an_empty_environment_value_is_no_override() {
        assert_eq!(
            state_suite_source(false, Some("run.42")),
            SuiteSource::Environment
        );
        assert_eq!(state_suite_source(false, Some("")), SuiteSource::Standard);
        assert_eq!(state_suite_source(false, None), SuiteSource::Standard);
    }

    /// The band holds from both ends, and a value already inside it is untouched.
    #[test]
    fn the_zoom_band_holds_from_both_ends() {
        assert_eq!(clamp_font_size(2.0).to_bits(), FONT_SIZE_MIN.to_bits());
        assert_eq!(clamp_font_size(400.0).to_bits(), FONT_SIZE_MAX.to_bits());
        assert_eq!(clamp_font_size(13.5).to_bits(), 13.5_f64.to_bits());
        assert_eq!(clamp_font_size(FONT_SIZE_MIN).to_bits(), FONT_SIZE_MIN.to_bits());
        assert_eq!(clamp_font_size(FONT_SIZE_MAX).to_bits(), FONT_SIZE_MAX.to_bits());
    }

    /// A `NaN` takes a bound rather than propagating — the IEEE-ordered half of `f64::max`/`min`,
    /// which is why this is not a `<`/`>` ternary. A size that came back `NaN` would reach a font
    /// descriptor and put nothing at all on screen.
    #[test]
    fn a_nan_size_takes_the_bound() {
        assert_eq!(
            clamp_font_size(f64::NAN).to_bits(),
            FONT_SIZE_MAX.to_bits(),
            "min answers the non-NaN side, and max then keeps it"
        );
        assert!(!clamp_font_size(f64::NAN).is_nan());
        assert_eq!(clamp_font_size(f64::INFINITY).to_bits(), FONT_SIZE_MAX.to_bits());
        assert_eq!(
            clamp_font_size(f64::NEG_INFINITY).to_bits(),
            FONT_SIZE_MIN.to_bits()
        );
    }

    /// The effective size is the file's answer plus the runtime delta, and the band still holds.
    #[test]
    fn the_effective_size_folds_the_delta_in() {
        assert_eq!(effective_font_size(14.0, 0.0).to_bits(), 14.0_f64.to_bits());
        assert_eq!(effective_font_size(14.0, 3.0).to_bits(), 17.0_f64.to_bits());
        assert_eq!(
            effective_font_size(14.0, 100.0).to_bits(),
            FONT_SIZE_MAX.to_bits()
        );
    }

    /// One press moves one step, and the answer is the DELTA rather than the size — the store keeps
    /// the distance from the file's answer, so a reload that changes the file moves the zoomed size
    /// with it.
    #[test]
    fn one_press_moves_one_step() {
        assert_eq!(zoom(14.0, 0.0, Zoom::In), Some(1.0));
        assert_eq!(zoom(14.0, 0.0, Zoom::Out), Some(-1.0));
        assert_eq!(zoom(14.0, 1.0, Zoom::In), Some(2.0));
        assert_eq!(zoom(14.0, -1.0, Zoom::Out), Some(-2.0));
    }

    /// Held against either edge, a press moves NOTHING — which is what keeps a repeat from
    /// re-publishing an identical terminal configuration through a generation counter that bumps
    /// unconditionally.
    #[test]
    fn a_press_against_the_edge_refuses() {
        assert_eq!(zoom(FONT_SIZE_MAX, 0.0, Zoom::In), None);
        assert_eq!(zoom(FONT_SIZE_MIN, 0.0, Zoom::Out), None);
        assert_eq!(
            zoom(14.0, 100.0, Zoom::In),
            None,
            "a delta already past the top clamps to the top, which is where it already was"
        );
    }

    /// A press that arrives with the delta out past the band lands back INSIDE it, because the
    /// delta is recomputed from the clamped size rather than added to.
    #[test]
    fn a_press_pulls_an_out_of_band_delta_back() {
        assert_eq!(
            zoom(14.0, 100.0, Zoom::Out),
            Some(FONT_SIZE_MAX - 1.0 - 14.0),
            "the effective size was the ceiling, so one step down is one step below the ceiling"
        );
    }

    /// A file whose own size is outside the band still zooms relative to the CLAMPED reading.
    #[test]
    fn a_configured_size_outside_the_band_zooms_from_the_bound() {
        assert_eq!(
            zoom(96.0, 0.0, Zoom::Out),
            Some(FONT_SIZE_MAX - 1.0 - 96.0),
            "the effective size was the ceiling; the delta is what puts 96 there minus a step"
        );
        assert_eq!(zoom(96.0, 0.0, Zoom::In), None);
    }

    /// ⌘0 zeroes the delta, and refuses when there is nothing to reset.
    #[test]
    fn a_reset_refuses_when_nothing_is_zoomed() {
        assert_eq!(zoom(14.0, 4.0, Zoom::Reset), Some(0.0));
        assert_eq!(zoom(14.0, 0.0, Zoom::Reset), None);
        assert_eq!(
            zoom(96.0, 0.0, Zoom::Reset),
            None,
            "the delta is what a reset reads, never the clamped size"
        );
    }

    /// The three cases only a test states: a pair, a pattern whose action is missing entirely, and
    /// a pattern whose action is present but empty. An empty PATTERN is dropped, and the indices
    /// that survive are the ORIGINAL ones, which is what keeps the pairing across the drop.
    #[test]
    fn the_zip_survives_a_dropped_pattern() {
        // ["ERR-\d+", "", "TODO", "FIXME"] × ["open", "open", ""]
        let patterns = [false, true, false, false];
        let actions = [false, false, true];
        assert_eq!(hint_patterns(&patterns, &actions), vec![
            HintSlot {
                pattern: 0,
                has_action: true
            },
            HintSlot {
                pattern: 2,
                has_action: false
            },
            HintSlot {
                pattern: 3,
                has_action: false
            },
        ]);
    }

    /// An action list LONGER than the pattern list contributes nothing, and every-pattern-empty is
    /// an empty answer rather than a panic.
    #[test]
    fn a_longer_action_list_and_an_all_empty_one_are_both_answers() {
        assert_eq!(hint_patterns(&[false], &[false, false, false]), vec![HintSlot {
            pattern: 0,
            has_action: true
        }]);
        assert!(hint_patterns(&[true, true], &[false, false]).is_empty());
        assert!(hint_patterns(&[], &[]).is_empty());
        assert!(hint_patterns(&[], &[false]).is_empty());
    }
}
