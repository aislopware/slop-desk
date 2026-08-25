//! The `0x04` body: what a pane's shell said OUT OF BAND in the chunk riding with it.
//!
//! ```json
//! {"events":[{"kind":"title","value":"~/src"},{"kind":"status","state":"idle",
//!             "exitCode":0,"durationMS":42}]}
//! ```
//!
//! ## Why both directions are here
//!
//! They were in two languages. superd hand-wrote the `serialize_entry` maps in `sniffer.rs`; hostd
//! hand-wrote the matching subscripts in `SniffedEvent.swift`. Nothing compared the two spellings
//! and nothing could — each end's suite read only its own end — so `state` renamed on one side
//! passed BOTH suites while every finished command decoded as still running and the spinner never
//! came down (`docs/51` §6.13). `slopdesk-invariants` carried five claims whose whole job was to
//! compare the two alphabets textually. They are not needed against one alphabet.
//!
//! ## Why it is still hand-written
//!
//! The Rust shape is newtype variants (`Title(String)`), and serde cannot internally-tag one of
//! those: the derive compiles and fails at RUN time, per chunk, on the hot path. Writing the map
//! out also pins the key names here rather than in a `rename_all` two types away.
//!
//! ## Validate-then-drop, one member at a time
//!
//! A member this build cannot read becomes [`SniffEvent::Unknown`], never a failed batch: a newer
//! superd inventing a kind must not take the titles and exit codes beside it down as well. The
//! ENVELOPE is the only thing whose absence loses everything, and that is what `None` from
//! [`decode_batch`] means.

use std::fmt;

use serde::de::{IgnoredAny, MapAccess, Visitor};
use serde::ser::SerializeMap as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// What the shell reported about the foreground command.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CommandStatus {
    /// A command began executing.
    Running,
    /// The shell is at a prompt, with the finished command's code and duration when it had one.
    Idle {
        /// The command's `$?`, when the shell reported one.
        exit_code: Option<i32>,
        /// The measured milliseconds it ran.
        duration_ms: u32,
    },
}

/// Something the shell said out of band.
///
/// Deliberately NOT wire messages. The events are what the shell SAID; a wire message is what a
/// client is TOLD, and those are the same thing for a title and are not for a cwd (host-gated,
/// resolved into a project key) or a notification (dropped while an agent's hook already banners
/// the edge). Keeping the two vocabularies apart is what lets hostd's `MuxChannelSession` make
/// those decisions in one place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SniffEvent {
    /// A new window title, already deduplicated against the last one emitted.
    Title(String),
    /// A real terminal bell.
    Bell,
    /// A command started or finished.
    Status(CommandStatus),
    /// The shell's working directory, verified local and percent-decoded.
    Cwd(String),
    /// A desktop notification.
    Notification {
        /// The title, empty when the source gave only a body.
        title: String,
        /// The body.
        body: String,
    },
    /// The BODY of an OSC 9;4 progress sequence, verbatim after the `9;`.
    ///
    /// Handed up unparsed on purpose, at both ends: the progress vocabulary belongs to
    /// `ProgressOSCParser`, which already owns it, and a second copy of that grammar inside the
    /// byte reader is exactly the drift this crate exists to remove. A body that does not parse is
    /// dropped by the owner — it was progress either way, never a notification.
    ProgressBody(String),
    /// A kind this build has no name for — or a known kind carrying a VALUE it cannot name, which
    /// today means only `status` with an unrecognised `state`.
    ///
    /// Kept rather than dropped so the batch stays countable and a skew is visible to a test, never
    /// acted on. Never produced by the sniffer; it exists only on the reading side.
    Unknown {
        /// The `kind` as written, or `""` when the member carried none.
        kind: String,
    },
}

/// The `kind` values, spelled once. Compared, never constructed by hand.
mod kind {
    pub(super) const TITLE: &str = "title";
    pub(super) const CWD: &str = "cwd";
    pub(super) const PROGRESS: &str = "progress";
    pub(super) const BELL: &str = "bell";
    pub(super) const NOTIFICATION: &str = "notification";
    pub(super) const STATUS: &str = "status";
}

/// The two `state` values a `status` member carries.
mod state {
    pub(super) const RUNNING: &str = "running";
    pub(super) const IDLE: &str = "idle";
}

impl Serialize for SniffEvent {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        /// One `{"kind": …, "value": …}` object — the shape three of the variants share.
        fn value_of<S: Serializer>(serializer: S, kind: &str, value: &str) -> Result<S::Ok, S::Error> {
            let mut map = serializer.serialize_map(Some(2))?;
            map.serialize_entry("kind", kind)?;
            map.serialize_entry("value", value)?;
            map.end()
        }

        match *self {
            Self::Title(ref value) => value_of(serializer, kind::TITLE, value),
            Self::Cwd(ref value) => value_of(serializer, kind::CWD, value),
            Self::ProgressBody(ref value) => value_of(serializer, kind::PROGRESS, value),
            Self::Bell => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry("kind", kind::BELL)?;
                map.end()
            },
            Self::Status(CommandStatus::Running) => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("kind", kind::STATUS)?;
                map.serialize_entry("state", state::RUNNING)?;
                map.end()
            },
            Self::Status(CommandStatus::Idle {
                exit_code,
                duration_ms,
            }) => {
                let mut map = serializer.serialize_map(Some(4))?;
                map.serialize_entry("kind", kind::STATUS)?;
                map.serialize_entry("state", state::IDLE)?;
                // Always present, `null` for the code-less `D`: the receiver latches an exit only
                // when it is a number, and a missing key and a null one must not be told apart by
                // whether this build happened to skip it.
                map.serialize_entry("exitCode", &exit_code)?;
                map.serialize_entry("durationMS", &duration_ms)?;
                map.end()
            },
            Self::Notification { ref title, ref body } => {
                let mut map = serializer.serialize_map(Some(3))?;
                map.serialize_entry("kind", kind::NOTIFICATION)?;
                map.serialize_entry("title", title)?;
                map.serialize_entry("body", body)?;
                map.end()
            },
            // Round-tripped rather than dropped, so a batch that crossed two builds still counts
            // the same both ways. Nothing on the writing side constructs this.
            Self::Unknown { ref kind } => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry("kind", kind)?;
                map.end()
            },
        }
    }
}

/// Everything one member may carry, gathered in a single pass before anything is decided.
///
/// Gathered rather than branched on `kind` as it arrives, because JSON objects have no key order
/// and `state` may precede `kind`. Unknown keys are consumed as [`IgnoredAny`] — rule 1.
#[derive(Default)]
struct Member {
    kind: Option<String>,
    value: Option<String>,
    title: Option<String>,
    body: Option<String>,
    state: Option<String>,
    exit_code: Option<i64>,
    duration_ms: Option<i64>,
}

impl<'de> Deserialize<'de> for SniffEvent {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct MemberVisitor;

        impl<'de> Visitor<'de> for MemberVisitor {
            type Value = SniffEvent;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a sniffed-event object")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<SniffEvent, A::Error> {
                let mut member = Member::default();
                while let Some(key) = map.next_key::<std::borrow::Cow<'de, str>>()? {
                    match key.as_ref() {
                        "kind" => member.kind = map.next_value()?,
                        "value" => member.value = map.next_value()?,
                        "title" => member.title = map.next_value()?,
                        "body" => member.body = map.next_value()?,
                        "state" => member.state = map.next_value()?,
                        "exitCode" => member.exit_code = map.next_value()?,
                        "durationMS" => member.duration_ms = map.next_value()?,
                        _ => drop(map.next_value::<IgnoredAny>()?),
                    }
                }
                Ok(member.into_event())
            }
        }

        deserializer.deserialize_map(MemberVisitor)
    }
}

impl Member {
    /// The one place a gathered member becomes an event.
    ///
    /// A missing string is `""` rather than a refusal, which is what makes a member from a build
    /// that stopped sending an optional field decode instead of taking its batch down.
    fn into_event(self) -> SniffEvent {
        let kind = self.kind.unwrap_or_default();
        match kind.as_str() {
            kind::TITLE => SniffEvent::Title(self.value.unwrap_or_default()),
            kind::CWD => SniffEvent::Cwd(self.value.unwrap_or_default()),
            kind::PROGRESS => SniffEvent::ProgressBody(self.value.unwrap_or_default()),
            kind::BELL => SniffEvent::Bell,
            kind::NOTIFICATION => {
                SniffEvent::Notification {
                    title: self.title.unwrap_or_default(),
                    body: self.body.unwrap_or_default(),
                }
            },
            // BOTH literals are matched, and neither is inferred from the other's absence. Reading
            // "not idle" as running is what made a rename of either end silent: a superd that
            // renamed `idle` would have every finished command decode as still running, and the
            // spinner would never come down — with both suites green, because each end tested only
            // itself. A state this build cannot name now asserts NOTHING, which is the ruling
            // `BlockEvent` already makes about an unrecognised badge state and for the same reason:
            // guessing idle takes down a spinner that should be up, and guessing running leaves one
            // up forever. Asserting nothing still fails toward the visible side — the pane keeps the
            // state it had, so a finished command whose `idle` was renamed sits there spinning
            // rather than being quietly marked done.
            kind::STATUS => {
                match self.state.as_deref() {
                    Some(state::RUNNING) => SniffEvent::Status(CommandStatus::Running),
                    Some(state::IDLE) => {
                        SniffEvent::Status(CommandStatus::Idle {
                            // `exitCode` is always present and carries `null` for the code-less
                            // `D` — a missing key and an absent code are the same thing here.
                            exit_code: self.exit_code.and_then(|code| i32::try_from(code).ok()),
                            duration_ms: self
                                .duration_ms
                                .and_then(|ms| u32::try_from(ms).ok())
                                .unwrap_or_default(),
                        })
                    },
                    // `Unknown { kind: "status" }` is unambiguous: `status` is a kind this build
                    // DOES know, so it can only ever mean the STATE was the unreadable part.
                    _ => SniffEvent::Unknown { kind },
                }
            },
            _ => SniffEvent::Unknown { kind },
        }
    }
}

/// The `0x04` body's envelope. One key, and the whole batch is lost if it moves.
///
/// `Cow` so that ONE declaration serves both directions: the writer borrows the events it already
/// has, and the reader owns what it built. Two structs would put the envelope key back in two
/// places, which is the drift this module exists to end, one nesting level up from the members.
#[derive(Debug, Serialize, Deserialize)]
struct Batch<'a> {
    events: std::borrow::Cow<'a, [SniffEvent]>,
}

/// The batch as superd packs it into a [`crate::TAG_SNIFF`] frame.
///
/// Borrows rather than taking a `Vec`: this runs per chunk, and the events are already in one.
///
/// A serialisation error answers the empty batch rather than propagating. It cannot happen — every
/// branch of the impl above writes a map of strings and numbers into a `Vec` — and if it somehow
/// did, "nothing was said" is the answer that loses the least, because it is also the common case.
#[must_use]
pub fn encode_batch(events: &[SniffEvent]) -> Vec<u8> {
    let batch = Batch {
        events: std::borrow::Cow::Borrowed(events),
    };
    serde_json::to_vec(&batch).unwrap_or_else(|_ignored| br#"{"events":[]}"#.to_vec())
}

/// One `{"events": [...]}` body, as hostd reads it.
///
/// `None` only when the body is not the expected object at all — a member that cannot be read
/// becomes [`SniffEvent::Unknown`], never a thrown batch.
#[must_use]
pub fn decode_batch(json: &[u8]) -> Option<Vec<SniffEvent>> {
    serde_json::from_slice::<Batch<'_>>(json)
        .ok()
        .map(|batch| batch.events.into_owned())
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{CommandStatus, SniffEvent, decode_batch, encode_batch};

    fn round_trip(events: &[SniffEvent]) -> Vec<SniffEvent> {
        decode_batch(&encode_batch(events)).unwrap()
    }

    /// The shape the wire has carried since minor 5, pinned as a literal.
    ///
    /// This is the assertion that used to live in two suites in two languages and prove nothing
    /// jointly. Here it is the wire itself: every superd already running at somebody's login writes
    /// exactly these bytes, and a rename is a skew against THEM.
    #[test]
    fn every_event_serialises_to_the_shape_the_wire_has_always_carried() {
        let events = vec![
            SniffEvent::Title("~/src".to_owned()),
            SniffEvent::Cwd("/tmp".to_owned()),
            SniffEvent::ProgressBody("4;3;50".to_owned()),
            SniffEvent::Bell,
            SniffEvent::Status(CommandStatus::Running),
            SniffEvent::Status(CommandStatus::Idle {
                exit_code: Some(0),
                duration_ms: 42,
            }),
            SniffEvent::Status(CommandStatus::Idle {
                exit_code: None,
                duration_ms: 0,
            }),
            SniffEvent::Notification {
                title: "t".to_owned(),
                body: "b".to_owned(),
            },
        ];
        assert_eq!(
            String::from_utf8(encode_batch(&events)).unwrap(),
            concat!(
                r#"{"events":[{"kind":"title","value":"~/src"},{"kind":"cwd","value":"/tmp"},"#,
                r#"{"kind":"progress","value":"4;3;50"},{"kind":"bell"},"#,
                r#"{"kind":"status","state":"running"},"#,
                r#"{"kind":"status","state":"idle","exitCode":0,"durationMS":42},"#,
                r#"{"kind":"status","state":"idle","exitCode":null,"durationMS":0},"#,
                r#"{"kind":"notification","title":"t","body":"b"}]}"#,
            )
        );
        assert_eq!(round_trip(&events), events);
    }

    /// The §6.13 failure, from the reading side. Neither literal is inferred from the other's
    /// absence, so a state this build cannot name asserts NOTHING rather than guessing running.
    #[test]
    fn an_unknown_state_is_never_silently_read_as_running() {
        let batch = br#"{"events":[{"kind":"status","state":"suspended"}]}"#;
        assert_eq!(decode_batch(batch).unwrap(), vec![SniffEvent::Unknown {
            kind: "status".to_owned()
        }],);
    }

    /// One unreadable member must not take the batch down with it — the whole reason this decodes
    /// member by member rather than as a typed array.
    #[test]
    fn one_unknown_member_does_not_lose_the_titles_beside_it() {
        let batch = br#"{"events":[{"kind":"title","value":"a"},{"kind":"teleport","to":"mars"},
                        {"kind":"status","state":"idle","exitCode":3,"durationMS":7}]}"#;
        assert_eq!(decode_batch(batch).unwrap(), vec![
            SniffEvent::Title("a".to_owned()),
            SniffEvent::Unknown {
                kind: "teleport".to_owned()
            },
            SniffEvent::Status(CommandStatus::Idle {
                exit_code: Some(3),
                duration_ms: 7,
            }),
        ],);
    }

    /// Rule 1 both ways: a key a newer superd added is ignored, and a key it stopped sending
    /// defaults. A member with no `kind` at all is the degenerate case of the second.
    #[test]
    fn a_member_from_either_side_of_the_skew_still_decodes() {
        let batch = br#"{"events":[{"kind":"title","value":"a","futureKey":{"deep":[1]}},
                        {"kind":"title"},{"kind":"notification","body":"only"},{}]}"#;
        assert_eq!(decode_batch(batch).unwrap(), vec![
            SniffEvent::Title("a".to_owned()),
            SniffEvent::Title(String::new()),
            SniffEvent::Notification {
                title: String::new(),
                body: "only".to_owned(),
            },
            SniffEvent::Unknown { kind: String::new() },
        ],);
    }

    /// The envelope is the one thing whose loss is total — and the one thing that answers `None`.
    #[test]
    fn only_a_lost_envelope_loses_the_whole_batch() {
        assert!(decode_batch(b"").is_none());
        assert!(decode_batch(b"[]").is_none());
        assert!(decode_batch(br#"{"evets":[]}"#).is_none());
        assert!(decode_batch(br#"{"events":"nope"}"#).is_none());
        assert_eq!(decode_batch(br#"{"events":[]}"#).unwrap(), Vec::new());
    }

    /// A number a peer wrote that will not fit this build's field is dropped to the absent value
    /// rather than failing the member — the same ruling `exitCode: null` already gets.
    #[test]
    fn a_number_out_of_range_lands_on_the_absent_value() {
        let batch = br#"{"events":[{"kind":"status","state":"idle","exitCode":99999999999,
                        "durationMS":-1}]}"#;
        assert_eq!(decode_batch(batch).unwrap(), vec![SniffEvent::Status(
            CommandStatus::Idle {
                exit_code: None,
                duration_ms: 0,
            }
        )],);
    }
}
