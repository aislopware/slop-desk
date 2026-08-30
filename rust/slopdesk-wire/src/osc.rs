//! The OSC vocabulary that survives the trip across the wire: the `OSC 9;4` progress subtype and
//! the `OSC 777` watch-finish banner.
//!
//! Two halves of one conversation live here on purpose. The host *parses* `OSC 9;4` out of a
//! child's output stream and forwards the raw state byte as
//! [`WireMessage::Progress`](crate::message::WireMessage::Progress); the `slopdesk watch` wrapper
//! *emits* exactly those bytes into its controlling terminal so the host will pick them up. In
//! Swift the parser was in `SlopDeskProtocol` and the emitter in `SlopDeskCLICore`, two modules
//! apart, and nothing checked that one produced what the other accepted. Here they are adjacent and
//! the round-trip is a test.
//!
//! ## Validate-then-drop
//! Everything parsed here came out of a PTY a foreign program was writing to. An unknown state
//! discriminant, a non-integer percent, a malformed field count — each returns `None` so the caller
//! emits nothing, rather than trusting a byte it does not understand. The percent is *clamped* to
//! `0..=100` rather than rejected, because an out-of-range percentage is a rendering question and
//! not a protocol violation.

/// `ESC`, the escape that opens every sequence here.
const ESC: u8 = 0x1B;
/// `BEL`, the OSC terminator the ConEmu/iTerm2 spec examples use (`\a`).
const BEL: u8 = 0x07;

/// The semantic state of an `OSC 9;4` taskbar-style progress indicator, shared host and client.
///
/// iTerm2 / `ConEmu` / winget emit `ESC ] 9 ; 4 ; <state> [ ; <pct> ] <terminator>` to drive a
/// per-window progress bar. The wire carries the RAW byte, so the codec stays a faithful round-trip
/// and the golden vector is stable; this is where the *client* clamps it.
///
/// States `4` (paused/warning) and `5` (finished-with-exit) are deliberately absent: `4` has no
/// render surface, and `5` maps onto the existing OSC-133-D command-status path, which already
/// carries the exit code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum ProgressState {
    /// `OSC 9;4;0` — clear the indicator; the command finished reporting progress.
    Clear = 0,
    /// `OSC 9;4;1;<pct>` — a DETERMINATE value, where the percent is meaningful.
    InProgress = 1,
    /// `OSC 9;4;2[;<pct>]` — an ERROR state, held red at the value it failed on.
    Error = 2,
    /// `OSC 9;4;3` — an INDETERMINATE busy spinner, with no meaningful percent.
    Indeterminate = 3,
}

impl ProgressState {
    /// Validate-then-drop construction from a raw wire byte.
    ///
    /// A known discriminant (`0`/`1`/`2`/`3`) maps to its case; any other value returns `None` so
    /// the consumer DROPS the update. The decoder carries the raw byte verbatim (forward-tolerant);
    /// this is the clamp.
    #[must_use]
    pub const fn from_wire(raw: u8) -> Option<Self> {
        match raw {
            0 => Some(Self::Clear),
            1 => Some(Self::InProgress),
            2 => Some(Self::Error),
            3 => Some(Self::Indeterminate),
            _ => None,
        }
    }

    /// The raw wire byte for this state.
    #[must_use]
    pub const fn to_wire(self) -> u8 {
        self as u8
    }

    /// The finish state a wrapped command's exit code calls for: a clean `0` CLEARS the indicator,
    /// any non-zero holds an [`Error`](Self::Error) badge. A signal-terminated child arrives here
    /// as the caller's `128 + signo`, so it reads as an error too.
    #[must_use]
    pub const fn for_exit_code(exit_code: i32) -> Self {
        if exit_code == 0 { Self::Clear } else { Self::Error }
    }
}

/// A validated `OSC 9;4` progress update.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ProgressUpdate {
    /// The validated state.
    pub state: ProgressState,
    /// The percentage, clamped into `0..=100`. Zero for the states that carry none.
    pub percent: u8,
}

/// Parses the OSC-9 remainder AFTER the leading `9;` — `"4;1;40"`, `"4;3"`, `"4;2;80"`, `"4;0"`.
///
/// Canonical progress is exactly `4;<state>` or `4;<state>;<pct>`. A bare `"4"`, an empty state
/// field (`"4;"`), extra trailing fields, an unknown state discriminant or a non-integer percent
/// all return `None` — the host then emits nothing. Empty subsequences are KEPT in the split, which
/// is what catches `"4;"` instead of silently coalescing it away.
#[must_use]
pub fn parse_progress(body: &str) -> Option<ProgressUpdate> {
    let mut fields = body.split(';');
    if fields.next()? != "4" {
        return None;
    }
    let state = ProgressState::from_wire(fields.next()?.parse::<u8>().ok()?)?;
    let percent = match fields.next() {
        // Absent (clear / indeterminate) → 0.
        None => 0,
        // Present: a garbled percent is suspect, so it drops the whole update; a valid one out of
        // range is merely clamped.
        Some(raw) => raw.parse::<i64>().ok()?.clamp(0, 100).try_into().ok()?,
    };
    // Anything past the percent means this is not the canonical shape.
    if fields.next().is_some() {
        return None;
    }
    Some(ProgressUpdate { state, percent })
}

/// `ESC ] 9 ; 4 ; <state> BEL` for one canonical progress state.
///
/// The digit is the validated discriminant, so this can never emit a state the host would drop.
#[must_use]
pub fn progress_bytes(state: ProgressState) -> Vec<u8> {
    let mut out = vec![ESC, b']', b'9', b';', b'4', b';'];
    out.push(b'0'.saturating_add(state.to_wire()));
    out.push(BEL);
    out
}

/// The `ESC ] 9 ; 4 ; 3 BEL` INDETERMINATE spinner `slopdesk watch` emits when a wrapped command
/// starts.
#[must_use]
pub fn spinner_bytes() -> Vec<u8> {
    progress_bytes(ProgressState::Indeterminate)
}

/// The finish badge for an exit code: clear on `0`, error otherwise.
///
/// Never the determinate `1;<pct>` form — `watch` has no percentage, only running / done / failed.
#[must_use]
pub fn finish_bytes(exit_code: i32) -> Vec<u8> {
    progress_bytes(ProgressState::for_exit_code(exit_code))
}

/// `ESC ] 9 ; <message> BEL` — the iTerm2/`ConEmu` free-text desktop-notification form the host
/// already parses into a notification with an empty title.
///
/// An empty message yields NO bytes: the host would drop an empty body anyway, and emitting nothing
/// keeps the wrapper from writing a no-op escape.
#[must_use]
pub fn notification_bytes(message: &str) -> Vec<u8> {
    if message.is_empty() {
        return Vec::new();
    }
    let mut out = vec![ESC, b']', b'9', b';'];
    out.extend_from_slice(message.as_bytes());
    out.push(BEL);
    out
}

/// The private sentinel that routes a `slopdesk watch` finish banner to the dedicated "Notify on
/// Watch Finish" toggle rather than the generic notification master switch.
///
/// Framed with `US` (`0x1F`, unit separator) so it can never collide with a real child-set title,
/// and carrying no `;` so the OSC-777 field split preserves it intact as a single title.
pub const WATCH_NOTIFICATION_MARKER: &str = "\u{1F}slopdesk:watch-finish\u{1F}";

/// Whether a notification's TITLE is the watch sentinel — the parse-back of
/// [`watch_finish_notification_bytes`].
///
/// The marker is the WHOLE title rather than a prefix, so recognising it is the same comparison in
/// both directions and a banner routed by it has no title text left to show.
#[must_use]
pub fn is_watch_notification(title: &str) -> bool {
    title == WATCH_NOTIFICATION_MARKER
}

/// The watch-FINISH banner: `ESC ] 777 ; notify ; <marker> ; <message> BEL`.
///
/// The host parses this into an ordinary notification whose title is the marker — no new wire — and
/// the client's classifier recognises the marker, strips it, and routes the banner to the watch
/// toggle. An empty message yields no bytes; `-q`/`--quiet` suppresses locally by never calling
/// this at all.
#[must_use]
pub fn watch_finish_notification_bytes(message: &str) -> Vec<u8> {
    if message.is_empty() {
        return Vec::new();
    }
    let mut out = vec![ESC, b']'];
    out.extend_from_slice(b"777;notify;");
    out.extend_from_slice(WATCH_NOTIFICATION_MARKER.as_bytes());
    out.push(b';');
    out.extend_from_slice(message.as_bytes());
    out.push(BEL);
    out
}

/// The human-readable "Notify on Watch Finish" message for a finished command.
///
/// It starts with `watch: ` so the body can never begin with the `4;` progress subtype the host
/// carves out of free-text `OSC 9` — otherwise a body like `4;…` would be silently swallowed as a
/// progress update. The command is rendered space-joined; a failure appends the exit code.
#[must_use]
pub fn watch_finish_message(command: &[String], exit_code: i32) -> String {
    let label = if command.is_empty() {
        "command".to_owned()
    } else {
        command.join(" ")
    };
    if exit_code == 0 {
        format!("watch: {label} finished")
    } else {
        format!("watch: {label} failed (exit {exit_code})")
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use super::{
        ProgressState, WATCH_NOTIFICATION_MARKER, finish_bytes, notification_bytes, parse_progress,
        progress_bytes, spinner_bytes, watch_finish_message, watch_finish_notification_bytes,
    };

    #[test]
    fn every_canonical_state_round_trips_through_the_wire_byte() {
        for state in [
            ProgressState::Clear,
            ProgressState::InProgress,
            ProgressState::Error,
            ProgressState::Indeterminate,
        ] {
            assert_eq!(ProgressState::from_wire(state.to_wire()), Some(state));
        }
    }

    #[test]
    fn an_unknown_discriminant_is_dropped_rather_than_guessed() {
        for raw in 4..=u8::MAX {
            assert_eq!(ProgressState::from_wire(raw), None, "{raw}");
        }
    }

    #[test]
    fn the_two_canonical_shapes_parse() {
        let update = parse_progress("4;3").expect("indeterminate parses");
        assert_eq!(update.state, ProgressState::Indeterminate);
        assert_eq!(update.percent, 0);

        let update = parse_progress("4;1;40").expect("determinate parses");
        assert_eq!(update.state, ProgressState::InProgress);
        assert_eq!(update.percent, 40);
    }

    #[test]
    fn an_out_of_range_percent_is_clamped_but_a_garbled_one_drops_the_update() {
        assert_eq!(parse_progress("4;1;900").expect("clamped").percent, 100);
        assert_eq!(parse_progress("4;1;-5").expect("clamped").percent, 0);
        assert_eq!(parse_progress("4;1;fifty"), None);
    }

    #[test]
    fn a_non_canonical_shape_drops() {
        // A bare subtype, an empty state field, a foreign subtype, extra fields, and empty input.
        for body in ["4", "4;", "9;4;1", "4;1;40;60", "", ";"] {
            assert_eq!(parse_progress(body), None, "{body:?}");
        }
    }

    #[test]
    fn a_state_past_the_carried_range_drops_rather_than_rendering() {
        // `5` is finished-with-exit, which rides the OSC-133-D path instead.
        assert_eq!(parse_progress("4;5"), None);
        assert_eq!(parse_progress("4;4"), None);
    }

    #[test]
    fn what_the_watch_wrapper_emits_is_what_the_host_parses() {
        for state in [
            ProgressState::Clear,
            ProgressState::InProgress,
            ProgressState::Error,
            ProgressState::Indeterminate,
        ] {
            let bytes = progress_bytes(state);
            let body = core::str::from_utf8(bytes.get(2..bytes.len().saturating_sub(1)).expect("body"))
                .expect("ascii");
            let remainder = body.strip_prefix("9;").expect("osc 9 prefix");
            assert_eq!(parse_progress(remainder).expect("round trip").state, state);
        }
    }

    #[test]
    fn the_spinner_and_the_finish_badges_are_the_documented_sequences() {
        assert_eq!(spinner_bytes(), b"\x1B]9;4;3\x07");
        assert_eq!(finish_bytes(0), b"\x1B]9;4;0\x07");
        assert_eq!(finish_bytes(1), b"\x1B]9;4;2\x07");
        // A signal-terminated child arrives as 128 + signo and reads as a failure.
        assert_eq!(finish_bytes(139), b"\x1B]9;4;2\x07");
    }

    #[test]
    fn an_empty_notification_writes_nothing_at_all() {
        assert!(notification_bytes("").is_empty());
        assert!(watch_finish_notification_bytes("").is_empty());
    }

    #[test]
    fn the_free_text_notification_is_the_osc_9_form() {
        assert_eq!(notification_bytes("build done"), b"\x1B]9;build done\x07");
    }

    #[test]
    fn the_watch_banner_carries_the_marker_as_its_own_title_field() {
        let bytes = watch_finish_notification_bytes("watch: make finished");
        let text = String::from_utf8(bytes).expect("ascii + utf8 body");
        let body = text
            .strip_prefix("\x1B]777;notify;")
            .and_then(|rest| rest.strip_suffix('\u{7}'))
            .expect("osc 777 framing");
        let (title, message) = body.split_once(';').expect("title then message");
        assert_eq!(title, WATCH_NOTIFICATION_MARKER);
        assert_eq!(message, "watch: make finished");
    }

    #[test]
    fn the_marker_can_never_be_split_by_the_field_separator() {
        assert!(!WATCH_NOTIFICATION_MARKER.contains(';'));
    }

    #[test]
    fn a_message_containing_semicolons_stays_whole_in_the_body() {
        let bytes = watch_finish_notification_bytes("watch: a;b;c failed (exit 2)");
        let text = String::from_utf8(bytes).expect("utf8");
        // maxSplits 3 on the host side: everything after the title is the body, semicolons
        // included.
        assert!(text.ends_with("watch: a;b;c failed (exit 2)\u{7}"));
    }

    #[test]
    fn the_finish_message_never_begins_with_the_progress_subtype() {
        let owned = |parts: &[&str]| parts.iter().map(|part| (*part).to_owned()).collect::<Vec<_>>();
        assert_eq!(
            watch_finish_message(&owned(&["make", "test"]), 0),
            "watch: make test finished"
        );
        assert_eq!(
            watch_finish_message(&owned(&["make", "test"]), 2),
            "watch: make test failed (exit 2)"
        );
        // Even a command that literally spells the subtype stays behind the `watch: ` prefix.
        assert!(watch_finish_message(&owned(&["4;1;50"]), 0).starts_with("watch: "));
        assert_eq!(watch_finish_message(&[], 0), "watch: command finished");
    }
}
