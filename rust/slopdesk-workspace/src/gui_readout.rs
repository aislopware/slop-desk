//! What a video (PATH 2) pane SAYS: five telemetry rows, three number formatters, a stall caption,
//! a placeholder, two choice labels, one unit conversion, and the marks and the bar an upload
//! wears.
//!
//! All of it lived in `GuiPaneReadout`, a Swift enum one floor under two renderers — an `AppKit`
//! canvas and a `UIKit` one. Nothing in it names a view type, and the rule the repo runs on says
//! that makes it Rust's: what is here is arithmetic over an `Option` and a sentence to put in front
//! of somebody, which is the same shape [`crate::status_pill`] and [`crate::command_navigator`]
//! already crossed for.
//!
//! ## EVERY READING IS ABSENT, NEVER WRONG
//!
//! The one law this module has. A stat with no sample yet prints [`ABSENT`] rather than `0`, and a
//! stall with no epoch prints `RECONNECTING` with no age rather than `· 0S`. A zero that means "no
//! reading" is the single lie an instrument readout must not tell — a stalled encoder and a link
//! nothing has measured are different facts, and only one of them is good news. That is why
//! [`Telemetry`] is ten `Option`s and not ten numbers with a convention.
//!
//! ## A COLOUR DOES NOT CROSS, AND A SYMBOL NAME DOES
//!
//! [`upload_tint`] answers an [`UploadTint`] and never a colour: this layer sits below the design
//! floor and draws nothing, so what crosses is the SEMANTIC and each framework looks up its own
//! token. Only the branch descends, which is the part that could ever be wrong. An SF Symbol name
//! is the opposite case — it is data, not drawing — so [`upload_glyph`] hands the name over and the
//! renderer spells `Image(systemName:)`.
//!
//! ## THE UPLOAD BAR IS THE ONE PLACE A `f64` MUST LAND ON THE SWIFT BIT
//!
//! [`upload_fraction`] is the only arithmetic here whose answer used to be computed in Swift and is
//! now computed here, so `CLAUDE.md`'s bit-exactness rule bites on it directly. It is kept in the
//! shape Swift evaluated: two `u64`→`f64` conversions, ONE division of those two values with
//! nothing folded into it, and `f64::min` as the ceiling. No reciprocal multiply and no
//! `mul_add` — a fused multiply-add rounds once where the original rounded twice, which is exactly
//! the divergence the crate's `suboptimal_flops` opt-out exists to prevent. The zero-total branch
//! runs BEFORE the division, so no operand of the `min` can be `NaN` and Rust's and Swift's `min`
//! cannot reach the one input they disagree about. The function's own doc spells each step out.
//!
//! ## THE CLOCK STAYS OUTSIDE
//!
//! [`stall_caption`] takes ELAPSED SECONDS, not two instants. The caller owns the clock, exactly as
//! [`crate::pane_facts`]'s ladder does — a caption that read the wall clock could not be tested at
//! a chosen moment, and the whole of what this one says is a subtraction.
//!
//! ## The formatters are `printf`'s, on purpose
//!
//! Every number below was `String(format: "%.1f", …)` in the Swift this replaces, and `{:.1}` is
//! byte-identical to it for every value a stream can produce: both convert the exact binary value
//! and both break a tie to even. The tests pin that rather than assume it. The one place the two
//! diverge is `inf` / `nan`, which Rust spells `inf` / `NaN` and C spells `inf` / `nan` —
//! deliberately not special-cased, because no measurement on this path can be either and a branch
//! for it would be a rule nothing produces.

/// The em dash that stands for "no reading yet".
///
/// One spelling, so a row cannot invent its own. It is U+2014 and not a hyphen: the readout is set
/// in a monospaced face where a hyphen reads as a minus sign, and a minus in front of a latency is
/// a measurement rather than an absence.
pub const ABSENT: &str = "—";

/// One sample of everything the five stat rows print — the host's announced cadence, the client's
/// own ~1 Hz and ~2 Hz measurements, and the latest hold.
///
/// Bundled as ONE value rather than ten arguments because they are one sample: the rows group them
/// by WHAT IS MEASURED, not by which callback delivered them, and a caller that can hand over half
/// a sample is a caller that can mix two.
///
/// EVERY FIELD IS `Option` AND MEANS IT. `None` is "no reading yet"; a `Some(0)` is a measured
/// zero, which is a completely different sentence.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Telemetry {
    /// Host-announced stream cadence, in frames per second.
    pub stream_fps: Option<i64>,
    /// Client-measured payload bitrate, in kilobits per second.
    pub stream_kbps: Option<i64>,
    /// The ~2 Hz mirror's received frame rate.
    pub stats_fps: Option<f64>,
    /// How many frames the presentation pacer is holding.
    pub stats_pacer_depth: Option<i64>,
    /// Frames per second the error correction recovered.
    pub stats_fec_per_sec: Option<f64>,
    /// Frames per second lost past recovery.
    pub stats_unrecovered_per_sec: Option<f64>,
    /// Round-trip time, in milliseconds.
    pub stats_rtt_ms: Option<f64>,
    /// Host-side encode time, in milliseconds.
    pub stats_encode_ms: Option<f64>,
    /// Client-side decode time, in milliseconds.
    pub stats_decode_ms: Option<f64>,
    /// How long the newest frame has been held, in milliseconds.
    pub stats_hold_ms: Option<i64>,
}

/// What a remote-GUI pane is showing: the live surface, the entry form, or the cap-gated
/// placeholder.
///
/// The bytes are the near side's own enum order, mirrored by its marshalling helper — `live` is `0`
/// because it is the case the pane spends its life in, not because anything downstream reads the
/// number.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Display {
    /// The live surface — admitted to a cap slot, its decode stack may run.
    #[default]
    Live,
    /// The endpoint entry FORM: not configured yet, or configured with a slot still free.
    EntryForm,
    /// The cap-saturated placeholder: configured, and admission was refused by the live-stream cap.
    Gated,
}

impl Display {
    /// Every case, in the near side's declaration order — which is the byte each crosses as.
    pub const ALL: [Self; 3] = [Self::Live, Self::EntryForm, Self::Gated];

    /// The case a code names.
    ///
    /// An unnamed code reads as [`Display::Live`], and the choice is the conservative one: the only
    /// branch below is `gated` vs everything else, so a byte this build cannot name lands on the
    /// neutral word rather than accusing a cap that may not be saturated.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::EntryForm,
            2 => Self::Gated,
            _ => Self::Live,
        }
    }

    /// This case's own code.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Live => 0,
            Self::EntryForm => 1,
            Self::Gated => 2,
        }
    }
}

/// Where one drag-drop upload has got to.
///
/// Mirrors the near side's three-case phase, byte for byte and in its declaration order.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum UploadPhase {
    /// In flight.
    #[default]
    Sending,
    /// Finished, and the bytes landed.
    Completed,
    /// Finished, and they did not.
    Failed,
}

impl UploadPhase {
    /// Every phase, in the near side's declaration order — which is the byte each crosses as.
    pub const ALL: [Self; 3] = [Self::Sending, Self::Completed, Self::Failed];

    /// The phase a code names.
    ///
    /// An unnamed code reads as [`UploadPhase::Sending`], which is the only safe default here: both
    /// other cases claim the transfer SETTLED, and a row that says "done" for a byte this build
    /// cannot name would report a completion that never happened.
    #[must_use]
    pub const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::Completed,
            2 => Self::Failed,
            _ => Self::Sending,
        }
    }

    /// This phase's own code.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Sending => 0,
            Self::Completed => 1,
            Self::Failed => 2,
        }
    }
}

/// Which tone an upload row's glyph wears. A SEMANTIC, not a colour — see the module header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UploadTint {
    /// The resting icon tone: in flight, nothing to report yet.
    Icon,
    /// The accent: settled, either way. Completion and failure share it because the GLYPH already
    /// says which, and a second colour axis would be the same fact twice.
    Accent,
}

impl UploadTint {
    /// This tone's own code, as the near side's semantic enum orders them.
    #[must_use]
    pub const fn code(self) -> u8 {
        match self {
            Self::Icon => 0,
            Self::Accent => 1,
        }
    }
}

/// The five telemetry rows, top-down, exactly as the in-pane readout stacks them.
///
/// Grouped by WHAT IS BEING MEASURED rather than by where the number came from: what the host is
/// sending, what this client is receiving, what the error correction is costing, where the latency
/// sits, and how stale the newest frame is. Five rather than ten because a reader scanning a
/// readout scans PAIRS — a rate against its depth, a recovery against its loss — and a row per
/// number would make every comparison a saccade.
#[must_use]
pub fn stat_rows(stats: &Telemetry) -> [String; 5] {
    [
        format!(
            "{} FPS · {} MBPS",
            stats
                .stream_fps
                .map_or_else(|| ABSENT.to_owned(), |fps| fps.to_string()),
            mbps_label(stats.stream_kbps),
        ),
        format!(
            "RX {} FPS · DEPTH {}",
            stats
                .stats_fps
                .map_or_else(|| ABSENT.to_owned(), |fps| format!("{fps:.0}")),
            stats
                .stats_pacer_depth
                .map_or_else(|| ABSENT.to_owned(), |depth| depth.to_string()),
        ),
        format!(
            "FEC {} · LOST {}",
            per_sec_label(stats.stats_fec_per_sec),
            per_sec_label(stats.stats_unrecovered_per_sec),
        ),
        format!(
            "RTT {} · ENC {} · DEC {}",
            ms_label(stats.stats_rtt_ms),
            ms_label(stats.stats_encode_ms),
            ms_label(stats.stats_decode_ms),
        ),
        format!(
            "HOLD {} MS",
            stats
                .stats_hold_ms
                .map_or_else(|| ABSENT.to_owned(), |hold| hold.to_string()),
        ),
    ]
}

/// Mbps at the surface from kbps on the wire, one decimal. [`ABSENT`] until the first measurement
/// lands.
///
/// The divisor is 1000 and not 1024: a bitrate is decimal everywhere it is quoted — by the encoder,
/// by the ABR ceiling, by the picker one panel over — and a readout that used the binary prefix
/// would print a number the control bar cannot set.
#[must_use]
pub fn mbps_label(kbps: Option<i64>) -> String {
    kbps.map_or_else(
        || ABSENT.to_owned(),
        |kbps| {
            #[expect(
                clippy::cast_precision_loss,
                reason = "the near side's `Double(kbps)` is this same widening; a bitrate that could lose a \
                          bit at 2^53 kbps is nine petabits a second"
            )]
            let mbps = kbps as f64 / 1000.0;
            format!("{mbps:.1}")
        },
    )
}

/// A per-second rate, one decimal, with its unit attached.
///
/// The unit rides INSIDE the answer here and not in the row label, unlike [`ms_label`], so that an
/// absent one still reads as a rate (`—/S`) rather than as a missing word. `FEC —` would look like
/// a broken sentence; `FEC —/S` looks like an instrument waiting for its first sample.
#[must_use]
pub fn per_sec_label(value: Option<f64>) -> String {
    value.map_or_else(|| format!("{ABSENT}/S"), |value| format!("{value:.1}/S"))
}

/// A millisecond duration, one decimal. The unit lives in the row label, not here — three of these
/// share one `RTT … · ENC … · DEC …` line and repeating `MS` on each would be the same word thrice.
#[must_use]
pub fn ms_label(value: Option<f64>) -> String {
    value.map_or_else(|| ABSENT.to_owned(), |value| format!("{value:.1}"))
}

/// The stall caption: `RECONNECTING` while the stall's epoch is unknown, `RECONNECTING · 12S` once
/// it is.
///
/// The drained (desaturated) last frame already says "this is the past" — MERIDIAN L1, colour is
/// live data — so the caption carries only what the material cannot: that recovery is running, and
/// how OLD the frozen frame is.
///
/// `elapsed` is SECONDS SINCE the stall began, supplied by the caller because only the caller has a
/// clock. Two clauses earn their comment:
///
/// - **It floors rather than rounds.** A stall is twelve seconds old until it is thirteen; rounding
///   would make the caption say `13S` half a second before it was true.
/// - **The age clamps at zero.** A client whose clock has drifted behind the host's hands over a
///   negative elapsed, and `· -3S` would read as a countdown to something.
#[must_use]
pub fn stall_caption(elapsed: Option<f64>) -> String {
    let Some(elapsed) = elapsed else {
        return "RECONNECTING".to_owned();
    };
    // `f64 as i64` saturates in Rust, so an absurd elapsed lands on `i64::MAX` rather than being
    // undefined — and the floor below has already run, so this truncation removes nothing.
    #[expect(
        clippy::cast_possible_truncation,
        reason = "the saturating float→int cast is the clamp; a stall older than i64::MAX seconds has a \
                  caption nobody will read"
    )]
    let age = (elapsed.floor() as i64).max(0);
    format!("RECONNECTING · {age}S")
}

/// What the non-live placeholder says.
///
/// The cap-gated state names its own CAUSE — two live streams is a deliberate ceiling, so "paused"
/// without the reason would read as a failure and send somebody looking for a broken encoder. Every
/// other state says the pane's noun and stops, because the entry form under it is already the
/// explanation.
#[must_use]
pub const fn placeholder_label(display: Display) -> &'static str {
    match display {
        Display::Gated => "Video paused — too many live streams",
        Display::Live | Display::EntryForm => "desktop",
    }
}

/// An fps choice's label. `0` is not "0 fps", it is the ABSENCE of a cap — the host's own governor,
/// unclamped — and a picker that printed the digit would read as "cap the stream at zero frames".
#[must_use]
pub fn fps_choice_label(fps: i64) -> String {
    if fps == 0 {
        return "Auto".to_owned();
    }
    fps.to_string()
}

/// A bitrate choice's label, with its unit. Same `0 → Auto` rule, for the same reason one axis
/// over.
#[must_use]
pub fn mbps_choice_label(mbps: i64) -> String {
    if mbps == 0 {
        return "Auto".to_owned();
    }
    format!("{mbps} Mb")
}

/// Mbps at the surface, bps on the model and the wire.
///
/// Integer division on purpose: the picker offers whole Mbps only, so a value that is not one is a
/// value the picker cannot show, and truncating is how it says so. Rounding would make a 12.5 Mbps
/// ceiling select a 13 Mb row that does not exist.
#[must_use]
#[expect(
    clippy::integer_division,
    reason = "the truncation IS the answer — the picker has no fractional row to land on"
)]
pub const fn mbps_from_bps(bps: i64) -> i64 {
    bps / 1_000_000
}

/// The inverse. `0` stays `0`, which is Auto on both sides of the conversion — the case a
/// `max(1, …)` would quietly break.
///
/// SATURATING, not wrapping: a panic crossing the C boundary aborts the process (`docs/55` §4b), so
/// a hostile or corrupt Mbps has to land on a legal number. Nothing the picker offers is within
/// nine orders of magnitude of the ceiling.
#[must_use]
pub const fn bps_from_mbps(mbps: i64) -> i64 {
    mbps.saturating_mul(1_000_000)
}

/// Whether any LATCHED pane mode is engaged — the states whose accent tint the control bar carries
/// as status lights, and which the COLLAPSED chip inherits so no latched mode is ever invisible.
///
/// The stats readout is deliberately absent from this list: its own visibility is its status light,
/// and counting it would leave the chip lit for a panel the user can already see.
///
/// The two caps are `!= 0` rather than `> 0` because `0` is Auto on both, and a negative cap is a
/// corrupt setting that is still not Auto — a chip that stayed dark for one would hide a stream
/// nobody can explain.
#[must_use]
pub const fn has_latched_mode(
    immersive: bool,
    viewport_locked: bool,
    audio_enabled: bool,
    stream_fps_cap: i64,
    stream_bitrate_ceiling_bps: i64,
) -> bool {
    immersive || viewport_locked || audio_enabled || stream_fps_cap != 0 || stream_bitrate_ceiling_bps != 0
}

/// The video activation task's IDENTITY: re-run cap admission when this session changes (a mount),
/// when a sibling frees a slot, or when visibility flips.
///
/// Three components and not two. Under keep-all-mounted a pane returning to screen is never
/// remounted, so a key that ignored visibility would leave it waiting for a remount that will never
/// come — it would re-request its slot only after something else in the tree moved.
///
/// A STRING rather than a hash: the near side feeds it to a task identity that compares for
/// equality, and three numbers joined by a separator that none of them can contain is an injective
/// encoding, where any packing into one integer would not be.
#[must_use]
pub fn activation_key(pane_hash: i64, promotion_generation: i64, is_visible: bool) -> String {
    format!("{pane_hash}:{promotion_generation}:{}", u8::from(is_visible))
}

/// The upload row's glyph NAME: rising while it sends, a settled check on success, a warning
/// triangle on failure.
///
/// An SF Symbol name is data, so the phase→mark mapping is here and the drawing is not.
#[must_use]
pub const fn upload_glyph(phase: UploadPhase) -> &'static str {
    match phase {
        UploadPhase::Sending => "arrow.up.circle",
        UploadPhase::Completed => "checkmark.circle.fill",
        UploadPhase::Failed => "exclamationmark.triangle.fill",
    }
}

/// The upload row's TONE. Settled either way takes the accent; the glyph carries which.
#[must_use]
pub const fn upload_tint(phase: UploadPhase) -> UploadTint {
    match phase {
        UploadPhase::Sending => UploadTint::Icon,
        UploadPhase::Completed | UploadPhase::Failed => UploadTint::Accent,
    }
}

/// Whether an upload has SETTLED — the cue the coordinator schedules its row's dismissal on.
///
/// Failure settles as surely as success does. A row that lingered because the transfer ended badly
/// would be the one row on the overlay that never goes away.
#[must_use]
pub const fn upload_is_settled(phase: UploadPhase) -> bool {
    !matches!(phase, UploadPhase::Sending)
}

/// How full an upload's progress bar is drawn, in `0..=1`.
///
/// The three answers, and none of them is arithmetic:
///
/// * **Completed reads FULL, whatever the counters say.** A transfer whose size was never reported
///   — a stream, a zero-byte file — would otherwise finish at an empty bar. The phase is the
///   authority on being done; the byte counts are only how far along it got.
/// * **A total of zero reads EMPTY while sending.** There is no fraction of an unknown size, and
///   the alternative is a division by zero. An indeterminate bar is the renderer's business.
/// * **Otherwise `sent / total`, ceilinged at 1.** A host that over-reports — a retransmit counted
///   twice — must not push the bar past its track.
///
/// ## Why this is bit-identical to the Swift it replaces
///
/// `CLAUDE.md` requires it, so the expression is kept in exactly the shape Swift evaluated:
///
/// * The two `u64`→`f64` conversions are IEEE-754 "convert to nearest, ties to even" in both
///   languages, so a count past 2^53 rounds to the same `f64` on both sides rather than to two
///   neighbours.
/// * ONE division, of those two converted values, with nothing folded into it — no reciprocal
///   multiply, no fused multiply-add. `a / b` rounds once and that is the only rounding here.
/// * The ceiling is `f64::min`, which is Swift's `min` for these operands: `total > 0` is checked
///   first, so neither side of the comparison can be `NaN` and the two functions' only documented
///   disagreement — what they do with a `NaN` argument — is unreachable.
#[must_use]
pub fn upload_fraction(phase: UploadPhase, sent_bytes: u64, total_bytes: u64) -> f64 {
    if matches!(phase, UploadPhase::Completed) {
        return 1.0;
    }
    if total_bytes == 0 {
        return 0.0;
    }
    #[expect(
        clippy::cast_precision_loss,
        reason = "the Swift this replaces converted the same two counts the same way, and a byte count past \
                  2^53 rounds identically on both sides"
    )]
    let ratio = sent_bytes as f64 / total_bytes as f64;
    ratio.min(1.0)
}

#[cfg(test)]
mod tests {
    use super::{
        ABSENT, Display, Telemetry, UploadPhase, UploadTint, activation_key, bps_from_mbps, fps_choice_label,
        has_latched_mode, mbps_choice_label, mbps_from_bps, mbps_label, ms_label, per_sec_label,
        placeholder_label, stall_caption, stat_rows, upload_fraction, upload_glyph, upload_is_settled,
        upload_tint,
    };

    /// The exact sample the deleted Swift suite measured, printing the exact five rows it pinned.
    #[test]
    fn a_fully_measured_stream_prints_all_five_rows_with_their_units() {
        let rows = stat_rows(&Telemetry {
            stream_fps: Some(60),
            stream_kbps: Some(12500),
            stats_fps: Some(59.6),
            stats_pacer_depth: Some(3),
            stats_fec_per_sec: Some(1.24),
            stats_unrecovered_per_sec: Some(0.0),
            stats_rtt_ms: Some(8.04),
            stats_encode_ms: Some(2.5),
            stats_decode_ms: Some(1.1),
            stats_hold_ms: Some(16),
        });
        assert_eq!(rows[0], "60 FPS · 12.5 MBPS");
        assert_eq!(
            rows[1], "RX 60 FPS · DEPTH 3",
            "the received rate rounds to whole frames"
        );
        assert_eq!(rows[2], "FEC 1.2/S · LOST 0.0/S");
        assert_eq!(rows[3], "RTT 8.0 · ENC 2.5 · DEC 1.1");
        assert_eq!(rows[4], "HOLD 16 MS");
    }

    /// THE LAW: a pane whose stream has produced no sample yet says so, in every slot. A `0` here
    /// would read as a measured zero — a stalled encoder, a lossless link — which is a different
    /// and much better-sounding fact than "no reading".
    #[test]
    fn an_unmeasured_stream_prints_the_em_dash_everywhere() {
        let rows = stat_rows(&Telemetry::default());
        assert_eq!(rows[0], "— FPS · — MBPS");
        assert_eq!(rows[1], "RX — FPS · DEPTH —");
        assert_eq!(
            rows[2], "FEC —/S · LOST —/S",
            "an absent RATE still reads as a rate"
        );
        assert_eq!(rows[3], "RTT — · ENC — · DEC —");
        assert_eq!(rows[4], "HOLD — MS");
    }

    /// A MEASURED zero is not an absence, in every slot that can hold one. This is the regression
    /// the law above exists to catch, so it is asserted from the other side too.
    #[test]
    fn a_measured_zero_prints_as_a_number_and_never_as_the_dash() {
        let rows = stat_rows(&Telemetry {
            stream_fps: Some(0),
            stream_kbps: Some(0),
            stats_fps: Some(0.0),
            stats_pacer_depth: Some(0),
            stats_fec_per_sec: Some(0.0),
            stats_unrecovered_per_sec: Some(0.0),
            stats_rtt_ms: Some(0.0),
            stats_encode_ms: Some(0.0),
            stats_decode_ms: Some(0.0),
            stats_hold_ms: Some(0),
        });
        assert_eq!(rows[0], "0 FPS · 0.0 MBPS");
        assert_eq!(rows[1], "RX 0 FPS · DEPTH 0");
        assert_eq!(rows[2], "FEC 0.0/S · LOST 0.0/S");
        assert_eq!(rows[3], "RTT 0.0 · ENC 0.0 · DEC 0.0");
        assert_eq!(rows[4], "HOLD 0 MS");
        for row in stat_rows(&Telemetry::default()) {
            assert!(row.contains(ABSENT), "{row}");
        }
    }

    /// One absent field does not make its NEIGHBOURS absent — the rows interleave four formatters
    /// and a dropped `Option` in any of them would be invisible in a fully-measured sample.
    #[test]
    fn each_slot_goes_absent_on_its_own() {
        let half = Telemetry {
            stream_kbps: Some(2000),
            stats_pacer_depth: Some(2),
            stats_unrecovered_per_sec: Some(4.5),
            stats_encode_ms: Some(3.0),
            stats_hold_ms: Some(8),
            ..Telemetry::default()
        };
        let rows = stat_rows(&half);
        assert_eq!(rows[0], "— FPS · 2.0 MBPS");
        assert_eq!(rows[1], "RX — FPS · DEPTH 2");
        assert_eq!(rows[2], "FEC —/S · LOST 4.5/S");
        assert_eq!(rows[3], "RTT — · ENC 3.0 · DEC —");
        assert_eq!(rows[4], "HOLD 8 MS");
    }

    /// kbps on the wire, Mbps at the surface — the one conversion the readout does, pinned at the
    /// exact strings the deleted `String(format: "%.1f", …)` produced.
    #[test]
    fn the_bitrate_row_converts_to_mbps() {
        assert_eq!(mbps_label(Some(0)), "0.0");
        assert_eq!(mbps_label(Some(999)), "1.0");
        assert_eq!(mbps_label(Some(20000)), "20.0");
        assert_eq!(mbps_label(Some(12500)), "12.5");
        assert_eq!(mbps_label(None), ABSENT);
    }

    /// The rounding is `printf`'s: exact conversion of the binary value, ties broken to EVEN.
    ///
    /// Every literal below is what Darwin's `%.1f` / `%.0f` answers. If one of these ever fails,
    /// the two implementations have diverged and the fix is in the formatter — never in this
    /// test, which is the only thing standing between a port and a readout that disagrees with
    /// itself.
    #[test]
    fn the_formatters_round_the_way_printf_does() {
        assert_eq!(ms_label(Some(0.25)), "0.2", "an exact tie breaks to even");
        assert_eq!(ms_label(Some(0.35)), "0.3", "0.35 is below the tie in binary");
        assert_eq!(ms_label(Some(0.75)), "0.8");
        assert_eq!(
            ms_label(Some(1.05)),
            "1.1",
            "…and 1.05 is above it, so it goes the other way"
        );
        assert_eq!(ms_label(Some(2.675)), "2.7");
        assert_eq!(
            ms_label(Some(-0.04)),
            "-0.0",
            "a negative zero keeps its sign, as `%.1f` does"
        );
        let ties = Telemetry {
            stats_fps: Some(2.5),
            ..Telemetry::default()
        };
        assert!(
            stat_rows(&ties)[1].starts_with("RX 2 FPS"),
            "%.0f breaks 2.5 to even"
        );
        let odd = Telemetry {
            stats_fps: Some(3.5),
            ..Telemetry::default()
        };
        assert!(
            stat_rows(&odd)[1].starts_with("RX 4 FPS"),
            "…and 3.5 the other way"
        );
    }

    /// An absent RATE still reads as a rate, where an absent DURATION reads as a bare dash — the
    /// unit's home differs per formatter and that is the whole difference between the two.
    #[test]
    fn a_rate_keeps_its_unit_when_a_duration_does_not() {
        assert_eq!(per_sec_label(None), "—/S");
        assert_eq!(per_sec_label(Some(0.0)), "0.0/S");
        assert_eq!(per_sec_label(Some(1.24)), "1.2/S");
        assert_eq!(ms_label(None), "—");
        assert_eq!(ms_label(Some(8.04)), "8.0");
    }

    /// The caption carries only what the drained frame cannot. With no epoch it says the first half
    /// and stops.
    #[test]
    fn the_stall_caption_ticks_and_floors_at_zero() {
        assert_eq!(stall_caption(None), "RECONNECTING");
        assert_eq!(
            stall_caption(Some(12.7)),
            "RECONNECTING · 12S",
            "the age truncates — a stall is 12 seconds old until it is 13"
        );
        assert_eq!(stall_caption(Some(0.0)), "RECONNECTING · 0S");
        assert_eq!(
            stall_caption(Some(-5.0)),
            "RECONNECTING · 0S",
            "a clock skew must never print a negative age"
        );
        assert_eq!(
            stall_caption(Some(-0.5)),
            "RECONNECTING · 0S",
            "…including one that floors to -1 rather than to a negative integer"
        );
    }

    /// The cap-gated placeholder names its OWN cause; every other state says the noun and stops.
    #[test]
    fn the_placeholder_names_the_cap_when_it_is_the_cap() {
        assert_eq!(
            placeholder_label(Display::Gated),
            "Video paused — too many live streams"
        );
        assert_eq!(placeholder_label(Display::EntryForm), "desktop");
        assert_eq!(placeholder_label(Display::Live), "desktop");
    }

    /// A display byte this build cannot name lands on the neutral word, never on the accusation.
    #[test]
    fn every_display_code_round_trips_and_an_unnamed_one_is_not_gated() {
        for display in Display::ALL {
            assert_eq!(Display::from_code(display.code()), display);
        }
        assert_eq!(Display::from_code(200), Display::Live);
        assert_eq!(placeholder_label(Display::from_code(200)), "desktop");
    }

    /// `0` IS NOT A QUANTITY on either axis — it is the absence of a cap, and both labels have to
    /// say so or the picker reads as "cap the stream at zero frames".
    #[test]
    fn zero_reads_as_auto_on_both_axes() {
        assert_eq!(fps_choice_label(0), "Auto");
        assert_eq!(mbps_choice_label(0), "Auto");
        assert_eq!(fps_choice_label(30), "30");
        assert_eq!(fps_choice_label(15), "15");
        assert_eq!(fps_choice_label(60), "60");
        assert_eq!(mbps_choice_label(20), "20 Mb");
        assert_eq!(mbps_choice_label(5), "5 Mb");
        assert_eq!(mbps_choice_label(50), "50 Mb");
    }

    /// The picker offers whole Mbps only, so the round trip through it is lossless for every value
    /// it can show — and `0` (Auto) stays `0` on both sides, the case a `max(1, …)` would break.
    #[test]
    fn the_mbps_round_trip_holds_for_every_offered_choice() {
        for mbps in [0_i64, 5, 10, 20, 50] {
            assert_eq!(mbps_from_bps(bps_from_mbps(mbps)), mbps);
        }
        assert_eq!(bps_from_mbps(0), 0, "Auto is Auto on both sides");
        assert_eq!(
            mbps_from_bps(12_500_000),
            12,
            "a value the picker cannot show truncates"
        );
        assert_eq!(
            mbps_from_bps(999_999),
            0,
            "…and one under a whole Mbps truncates to Auto"
        );
    }

    /// A hostile Mbps lands on a legal number rather than aborting the process across the boundary.
    #[test]
    fn the_conversion_saturates_rather_than_overflowing() {
        assert_eq!(bps_from_mbps(i64::MAX), i64::MAX);
        assert_eq!(bps_from_mbps(i64::MIN), i64::MIN);
        assert_eq!(
            mbps_from_bps(-12_500_000),
            -12,
            "truncation is toward zero, as Swift's is"
        );
    }

    /// EVERY latched mode has to reach the collapsed chip's tint, or folding the bar away hides a
    /// status light. Each is asserted on its own so a dropped clause fails here rather than in a
    /// user's "why is immersive still on" report.
    #[test]
    fn each_latched_mode_on_its_own_lights_the_chip() {
        assert!(
            !has_latched_mode(false, false, false, 0, 0),
            "a resting pane has no status light"
        );
        assert!(has_latched_mode(true, false, false, 0, 0));
        assert!(has_latched_mode(false, true, false, 0, 0));
        assert!(has_latched_mode(false, false, true, 0, 0));
        assert!(has_latched_mode(false, false, false, 30, 0));
        assert!(has_latched_mode(false, false, false, 0, 10_000_000));
        assert!(
            has_latched_mode(false, false, false, -1, 0),
            "a corrupt cap is still not Auto"
        );
    }

    /// The activation key has to MOVE on all three edges that should re-request a cap slot — a
    /// mount, a sibling freeing a slot, and a visibility flip — and settle on none of them.
    #[test]
    fn the_activation_key_moves_on_every_edge_that_should_re_request_a_slot() {
        let base = activation_key(7, 1, true);
        assert_eq!(base, "7:1:1");
        assert_ne!(base, activation_key(8, 1, true));
        assert_ne!(base, activation_key(7, 2, true));
        assert_ne!(
            base,
            activation_key(7, 1, false),
            "a pane returning to screen must re-request its slot immediately"
        );
        assert_eq!(
            base,
            activation_key(7, 1, true),
            "…and it settles, or admission re-runs on every body pass"
        );
        assert_eq!(
            activation_key(-3, 0, false),
            "-3:0:0",
            "a negative hash is a hash"
        );
    }

    /// The separator makes the three components unambiguous: no component can contain a colon, so
    /// two different triples cannot spell one key.
    #[test]
    fn no_two_triples_share_an_activation_key() {
        assert_ne!(activation_key(11, 1, true), activation_key(1, 11, true));
        assert_ne!(activation_key(1, 12, false), activation_key(12, 1, false));
    }

    /// The GLYPH says which way a settled upload settled; the TONE only says that it did. Two
    /// colours for done-vs-failed would be the same fact twice.
    #[test]
    fn the_glyph_carries_the_outcome_and_the_tone_only_carries_settlement() {
        assert_eq!(upload_glyph(UploadPhase::Sending), "arrow.up.circle");
        assert_eq!(upload_glyph(UploadPhase::Completed), "checkmark.circle.fill");
        assert_eq!(upload_glyph(UploadPhase::Failed), "exclamationmark.triangle.fill");
        assert_eq!(upload_tint(UploadPhase::Sending), UploadTint::Icon);
        assert_eq!(upload_tint(UploadPhase::Completed), UploadTint::Accent);
        assert_eq!(upload_tint(UploadPhase::Failed), UploadTint::Accent);
        assert_eq!(UploadTint::Icon.code(), 0);
        assert_eq!(UploadTint::Accent.code(), 1);
    }

    /// A phase byte this build cannot name is still IN FLIGHT — never a completion that did not
    /// happen.
    #[test]
    fn every_phase_code_round_trips_and_an_unnamed_one_has_not_settled() {
        for phase in UploadPhase::ALL {
            assert_eq!(UploadPhase::from_code(phase.code()), phase);
        }
        assert_eq!(UploadPhase::from_code(9), UploadPhase::Sending);
        assert_eq!(upload_tint(UploadPhase::from_code(9)), UploadTint::Icon);
        assert_eq!(upload_glyph(UploadPhase::from_code(9)), "arrow.up.circle");
    }

    /// Ported from `RemoteWindowUploadTests`' three `fraction` cases and the `isSettled` half of
    /// them. Every branch, plus the two the Swift suite did not reach.
    #[test]
    fn the_bar_reads_full_when_done_empty_when_unmeasured_and_never_past_its_track() {
        // In flight, measured: the ratio.
        assert!((upload_fraction(UploadPhase::Sending, 25, 100) - 0.25).abs() < f64::EPSILON);
        assert!((upload_fraction(UploadPhase::Sending, 0, 100) - 0.0).abs() < f64::EPSILON);
        // Done with no size ever reported still reads FULL — the phase is the authority.
        assert!((upload_fraction(UploadPhase::Completed, 0, 0) - 1.0).abs() < f64::EPSILON);
        assert!((upload_fraction(UploadPhase::Completed, 3, 100) - 1.0).abs() < f64::EPSILON);
        // In flight with no size reads EMPTY rather than dividing by zero.
        assert!((upload_fraction(UploadPhase::Sending, 10, 0) - 0.0).abs() < f64::EPSILON);
        // A FAILED upload keeps its measured position: it settled, it did not complete.
        assert!((upload_fraction(UploadPhase::Failed, 40, 100) - 0.4).abs() < f64::EPSILON);
        assert!((upload_fraction(UploadPhase::Failed, 0, 0) - 0.0).abs() < f64::EPSILON);
        // An over-reporting host cannot push the bar past its track.
        assert!((upload_fraction(UploadPhase::Sending, 300, 100) - 1.0).abs() < f64::EPSILON);
        assert!((upload_fraction(UploadPhase::Sending, u64::MAX, 1) - 1.0).abs() < f64::EPSILON);
    }

    /// Failure settles as surely as success — the row that lingered on a failed transfer would be
    /// the one that never left the overlay.
    #[test]
    fn both_endings_settle_and_only_sending_does_not() {
        assert!(!upload_is_settled(UploadPhase::Sending));
        assert!(upload_is_settled(UploadPhase::Completed));
        assert!(upload_is_settled(UploadPhase::Failed));
        assert!(
            !upload_is_settled(UploadPhase::from_code(9)),
            "an unnamed phase has not settled, for the same reason it draws the sending glyph",
        );
    }

    /// Every glyph is a distinct mark. Two phases wearing one symbol would make the tone the only
    /// difference, which is precisely the axis this pair refuses to spend.
    #[test]
    fn no_two_phases_wear_the_same_glyph() {
        let glyphs: Vec<&str> = UploadPhase::ALL.into_iter().map(upload_glyph).collect();
        for (index, glyph) in glyphs.iter().enumerate() {
            assert!(
                !glyphs.iter().skip(index + 1).any(|other| other == glyph),
                "{glyph} is worn twice"
            );
        }
    }
}
