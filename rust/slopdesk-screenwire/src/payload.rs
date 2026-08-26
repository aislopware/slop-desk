//! The two JSON bodies a reply carries, and the state alphabet they share.
//!
//! The frame layer above is bytes and integers; these are the payloads inside it. They live here
//! for the reason everything else in this crate does — both ends need them, and screend is only one
//! of the two. screend SERIALIZES a [`Snapshot`] and a [`Verdict`] into a reply body; a client
//! DESERIALIZES the same two out of it. Defined once, the round trip is a test rather than an
//! agreement two files keep by review, which is the property `docs/DECISIONS.md` recorded when the
//! client end moved into Rust.
//!
//! They were screend's, in `model.rs` and `detect.rs`, deriving `Serialize` and nothing else —
//! which was sufficient for exactly as long as the only decoder was Swift's `Decodable`. Hostd's
//! client is Rust now, so the missing half had to come from somewhere, and screend's crate is not
//! the somewhere: it carries `regex`, `toml` and a per-byte screen model, so linking it to get a
//! struct definition would drag the ENGINE into the app the daemon exists to keep it out of.
//!
//! `camelCase` on the wire throughout, matching every other JSON payload the daemon answers with.

/// The rendered-screen dump. `lines` has exactly `rows` entries, each with trailing whitespace
/// trimmed (the cursor may sit past a line's trimmed end).
#[derive(Clone, PartialEq, Eq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    /// Grid height.
    pub rows: usize,
    /// Grid width.
    pub cols: usize,
    /// Cursor row (0-based).
    pub cursor_row: usize,
    /// Cursor column (0-based).
    pub cursor_col: usize,
    /// DECTCEM.
    pub cursor_visible: bool,
    /// Whether the alt screen is active.
    pub alt_screen: bool,
    /// One trimmed string per row.
    pub lines: Vec<String>,
}

// There is deliberately no `detection_text()` here. herdr's detection text — trailing blank rows
// dropped, `\n`-joined, one trailing newline — is DERIVED from `lines`, and the manifest engine
// that consumes it lives in Swift (`SlopDeskAgentDetect`). Computing it on both sides of the socket
// would be one rule written twice in two languages, free to drift; it is written once, in
// `ScreenSnapshot.detectionText`.

/// The four-way state a rule resolves to (herdr `AgentState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default, Hash)]
#[serde(rename_all = "lowercase")]
pub enum State {
    /// Agent finished, prompt visible, nothing happening.
    Idle,
    /// Actively processing.
    Working,
    /// Needs human input.
    Blocked,
    /// Plain shell / unrecognised — or a `skip_state_update` freeze rule.
    #[default]
    Unknown,
}

impl State {
    /// The wire spelling, which is also the TOML spelling.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Blocked => "blocked",
            Self::Unknown => "unknown",
        }
    }
}

/// The engine's verdict, plus the two sync-frame facts hostd's timeout is keyed on.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
#[expect(
    clippy::struct_excessive_bools,
    reason = "four independent screen claims; a bitfield would need a second name for each"
)]
pub struct Verdict {
    /// The four-way state.
    pub state: State,
    /// A FREEZE rule matched (transcript viewer, model picker): publish nothing, hold the previous
    /// status.
    pub skip_state_update: bool,
    /// The screen literally shows an idle prompt box. This is the ONE screen claim strong enough
    /// to clear an authoritative hook block, which is why the tear guards exist.
    pub visible_idle: bool,
    /// The screen literally shows a live blocker form.
    pub visible_blocker: bool,
    /// The screen literally shows a live spinner.
    pub visible_working: bool,
    /// The winning rule's id, or `null` on a fallback.
    pub matched_rule_id: Option<String>,
    /// herdr's fallback-reason constant when no rule matched a known agent.
    pub fallback_reason: Option<String>,
    /// TRUE when the fed bytes end inside an OPEN synchronized update — the grid is half a frame.
    pub frame_open: bool,
    /// Bumped every time a frame opens. hostd's over-long-frame deadline is keyed on this.
    pub frame_generation: u64,
}

impl Verdict {
    /// No agent in the foreground — the screen says nothing about anyone.
    ///
    /// The two verdicts that DO say something — the one a matching rule produces and the
    /// known-agent idle fallback — stayed in screend, because each names something only the
    /// engine has: a `Rule`, and herdr's fallback-reason constant. A wire type that had to know
    /// either would be the engine leaking through the payload.
    #[must_use]
    pub const fn none() -> Self {
        Self {
            state: State::Unknown,
            skip_state_update: false,
            visible_idle: false,
            visible_blocker: false,
            visible_working: false,
            matched_rule_id: None,
            fallback_reason: None,
            frame_open: false,
            frame_generation: 0,
        }
    }
}

impl Default for Verdict {
    fn default() -> Self {
        Self::none()
    }
}

/// Encodes a payload into a reply body.
///
/// The daemon's half of the round trip, here rather than in screend so that the pair is one
/// function apart and a test can close it.
///
/// # Errors
/// `serde_json::Error` only for a type whose `Serialize` fails, which neither of these two can.
pub fn encode_body<T: serde::Serialize>(payload: &T) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(payload)
}

/// Decodes a `snapshot` reply body.
///
/// # Errors
/// `serde_json::Error` when the body is not a [`Snapshot`] — a screend of a different build, or a
/// status the caller should have branched on first.
pub fn decode_snapshot(body: &[u8]) -> Result<Snapshot, serde_json::Error> {
    serde_json::from_slice(body)
}

/// Decodes a `detect` reply body.
///
/// # Errors
/// `serde_json::Error` when the body is not a [`Verdict`], on the same two grounds as
/// [`decode_snapshot`].
pub fn decode_verdict(body: &[u8]) -> Result<Verdict, serde_json::Error> {
    serde_json::from_slice(body)
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::{Snapshot, State, Verdict, decode_snapshot, decode_verdict, encode_body};

    #[test]
    fn a_snapshot_survives_the_round_trip() {
        let snapshot = Snapshot {
            rows: 2,
            cols: 4,
            cursor_row: 1,
            cursor_col: 3,
            cursor_visible: true,
            alt_screen: false,
            lines: vec!["ab".to_owned(), String::new()],
        };
        let body = encode_body(&snapshot).expect("a snapshot serialises");
        let json = String::from_utf8(body.clone()).expect("json is utf-8");
        assert!(json.contains("\"cursorRow\":1"), "camelCase on the wire: {json}");
        assert_eq!(decode_snapshot(&body).expect("the body it just wrote"), snapshot);
    }

    #[test]
    fn a_verdict_survives_the_round_trip() {
        let verdict = Verdict {
            state: State::Blocked,
            visible_blocker: true,
            matched_rule_id: Some("claude.blocker".to_owned()),
            frame_generation: 7,
            ..Verdict::none()
        };
        let body = encode_body(&verdict).expect("a verdict serialises");
        let json = String::from_utf8(body.clone()).expect("json is utf-8");
        assert!(
            json.contains("\"state\":\"blocked\"") && json.contains("\"skipStateUpdate\":false"),
            "the alphabet is lowercase and the keys camelCase: {json}"
        );
        assert_eq!(decode_verdict(&body).expect("the body it just wrote"), verdict);
    }

    #[test]
    fn every_state_spells_itself_the_way_it_serialises() {
        for state in [State::Idle, State::Working, State::Blocked, State::Unknown] {
            let body = encode_body(&state).expect("a state serialises");
            let json = String::from_utf8(body).expect("json is utf-8");
            assert_eq!(json, format!("\"{}\"", state.label()));
            assert_eq!(
                serde_json::from_str::<State>(&json).expect("the text it just wrote"),
                state
            );
        }
    }

    #[test]
    fn a_body_of_the_wrong_shape_is_an_error_and_not_a_panic() {
        assert!(decode_snapshot(b"{}").is_err());
        assert!(decode_verdict(b"not json").is_err());
    }
}
