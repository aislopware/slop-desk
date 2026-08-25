//! The `0x05` body and the block-reading replies: what superd's command-block tap found.
//!
//! ```json
//! {"blocks":[{"kind":"block","index":3,"exitCode":0,"durationMS":42,"complete":true,
//!             "outputLen":19,"commandText":"ls -la","promptOrdinal":7},
//!            {"kind":"progress","state":"indeterminate"}]}
//! ```
//!
//! ## Why both directions are here
//!
//! [`crate::sniffwire`]'s reason, exactly, and the same file pair: superd hand-wrote three
//! `serialize_entry` maps in `blocks.rs`, hostd hand-wrote the matching `CodingKey` enums in
//! `BlockEvent.swift`, and nothing compared them. A renamed `commandText` filled the Commands panel
//! with blank rows and failed nothing (`docs/51` §6.14).
//!
//! ## What is NOT here
//!
//! The tap. The ring, the eviction, the dedup and the segmenter stay in `slopdesk-superd` — this is
//! what the answers LOOK like on the wire, not how they are decided. The split is the one the
//! module it came from already drew: "this module says a block's metadata changed; turning that
//! into a frame is the protocol's".
//!
//! ## One tolerance this is deliberately GREATER in than the Swift it replaces
//!
//! `BlockMetadata`'s synthesised Swift decode required `index`, `complete`, `outputLen`,
//! `commandText` and `promptOrdinal`, so a `block` member missing any of them threw — and the throw
//! escaped the array decode and lost the WHOLE batch, which is the exact failure the hand-written
//! `kind` dispatch beside it existed to prevent. Rule 1 says a field is never removed, so this was
//! unreachable rather than harmless; here every scalar defaults, which extends the ruling that was
//! already made one line above it to the case nobody had noticed was on the other side of it.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::ser::SerializeMap as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Default ceiling on how many finished blocks keep their output.
pub const DEFAULT_MAX_BLOCKS: usize = 64;

/// Default ceiling on the retained output bytes across all held blocks, 8 MiB.
///
/// A second bound rather than a redundant one: 64 blocks at the segmenter's 256 KiB per-block cap
/// would otherwise pin 16 MiB per pane.
pub const DEFAULT_MAX_TOTAL_OUTPUT_BYTES: usize = 8 * 1024 * 1024;

/// A synthetic progress badge superd decided to drive for a configured slow command.
///
/// The two states the feature has, and no more: it never reports a percentage, because it does not
/// know one — which is precisely what an indeterminate badge is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SyntheticProgress {
    /// A slow command started — show an indeterminate spinner.
    Indeterminate,
    /// Its block closed — clear the spinner.
    Clear,
}

/// The wire-relevant facts about one block — and, being the whole of what is reported, also the
/// dedup key: a change here is exactly what earns a fresh report.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct BlockMeta {
    /// The block's index in emission order.
    pub index: u32,
    /// The command's `$?`, when the shell reported one.
    #[serde(rename = "exitCode")]
    pub exit_code: Option<i32>,
    /// The measured `C`→`D` milliseconds, absent while the command is still running.
    #[serde(rename = "durationMS")]
    pub duration_ms: Option<u32>,
    /// Whether the matching `D` has arrived.
    pub complete: bool,
    /// How many output bytes are held for this block.
    #[serde(rename = "outputLen")]
    pub output_len: u32,
    /// The typed command line.
    #[serde(rename = "commandText")]
    pub command_text: String,
    /// The block's prompt-row ordinal, `0` when unknown.
    #[serde(rename = "promptOrdinal")]
    pub prompt_ordinal: u32,
}

/// The JSON one block's metadata crosses the socket as.
///
/// Tagged `kind` even though a snapshot is nothing but blocks, so that ONE decoder reads a block
/// wherever it turns up — inside a live `0x05` batch beside a progress badge, or in a reattach
/// snapshot. Two shapes for one fact is how the two drift.
///
/// `exitCode` and `durationMS` are ALWAYS present, carrying `null` when absent, so that a missing
/// key and an absent value are never told apart by which build wrote the frame. That is why this
/// half is hand-written where the `Deserialize` above is derived: a derive would honour
/// `skip_serializing_if` habits it was never given, and the always-null is the behaviour, not an
/// accident of the shape.
impl Serialize for BlockMeta {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(8))?;
        map.serialize_entry("kind", kind::BLOCK)?;
        map.serialize_entry("index", &self.index)?;
        map.serialize_entry("exitCode", &self.exit_code)?;
        map.serialize_entry("durationMS", &self.duration_ms)?;
        map.serialize_entry("complete", &self.complete)?;
        map.serialize_entry("outputLen", &self.output_len)?;
        map.serialize_entry("commandText", &self.command_text)?;
        map.serialize_entry("promptOrdinal", &self.prompt_ordinal)?;
        map.end()
    }
}

/// One thing that happened in a chunk, worth telling hostd about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlockEvent {
    /// A block was created, changed, or finished. Already deduped by superd: a running command that
    /// prints steadily is reported once, not once per chunk.
    Meta(BlockMeta),
    /// A synthetic progress badge should go up or come down for a slow command.
    Progress(SyntheticProgress),
    /// A kind this build has no name for, or a `progress` carrying a state it cannot name.
    ///
    /// Kept rather than dropped so the batch stays countable and a skew is visible to a test, never
    /// acted on. Never produced by the tap; it exists only on the reading side.
    Unknown {
        /// The `kind` as written, or `""` when the member carried none.
        kind: String,
    },
}

/// The `kind` values, spelled once. Compared, never constructed by hand.
mod kind {
    pub(super) const BLOCK: &str = "block";
    pub(super) const PROGRESS: &str = "progress";
}

/// The JSON one block event crosses the socket as — a block, or a badge.
///
/// Hand-written for the same reason [`crate::sniffwire::SniffEvent`]'s is: serde cannot
/// internally-tag an enum whose variants are newtypes, and the failure is a RUN-time one, on the
/// hot path, per chunk.
impl Serialize for BlockEvent {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match *self {
            // Delegated rather than repeated: a snapshot serialises the same object without the
            // event wrapper, and two copies of the key names is one rename away from a silent skew.
            Self::Meta(ref meta) => meta.serialize(serializer),
            Self::Progress(state) => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("kind", kind::PROGRESS)?;
                map.serialize_entry("state", &state)?;
                map.end()
            },
            Self::Unknown { ref kind } => {
                let mut map = serializer.serialize_map(Some(1))?;
                map.serialize_entry("kind", kind)?;
                map.end()
            },
        }
    }
}

/// A member's tag read alongside the block it may be, in one pass.
///
/// One gather rather than a re-visit, because JSON objects have no key order: `state` may precede
/// `kind`, and a decoder that dispatched on `kind` as it arrived would have to buffer anyway. The
/// block half is `flatten`ed rather than re-listed — a second copy of those seven key names, twenty
/// lines from the first, is the drift this whole module exists to end.
#[derive(Deserialize)]
struct Member {
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    state: Option<String>,
    #[serde(flatten)]
    meta: BlockMeta,
}

impl<'de> Deserialize<'de> for BlockEvent {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let member = Member::deserialize(deserializer)?;
        let kind = member.kind.unwrap_or_default();
        Ok(match kind.as_str() {
            kind::BLOCK => Self::Meta(member.meta),
            // A badge state a NEWER superd knows stays visible as a skew rather than being guessed
            // at: guessing `clear` for an unknown state takes down a spinner that should be up, and
            // guessing the other way leaves one up forever.
            kind::PROGRESS => {
                match member.state.as_deref() {
                    Some("indeterminate") => Self::Progress(SyntheticProgress::Indeterminate),
                    Some("clear") => Self::Progress(SyntheticProgress::Clear),
                    _ => Self::Unknown { kind },
                }
            },
            _ => Self::Unknown { kind },
        })
    }
}

/// One finished block joined with its metadata — what the agent-control verbs read.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct ControlBlock {
    /// The block's index.
    pub index: u32,
    /// The typed command line, as last reported.
    #[serde(rename = "commandText")]
    pub command_text: String,
    /// The command's `$?`, when the shell reported one.
    #[serde(rename = "exitCode")]
    pub exit_code: Option<i32>,
    /// The measured `C`→`D` milliseconds.
    #[serde(rename = "durationMS")]
    pub duration_ms: Option<u32>,
    /// Whether the block closed on its own `D` rather than on a fresh prompt.
    ///
    /// Defaults to TRUE when the key is absent, unlike every other scalar here, and that asymmetry
    /// is the Swift decode's, kept: the ring holds only closed blocks, so a record whose build did
    /// not spell this is a finished one, and defaulting it false would leave a spinner up on a
    /// command that ended before anybody asked.
    pub complete: bool,
    /// The retained output bytes.
    ///
    /// Base64 on the wire, because this is a fetch a person asked for — a click on a block, or a
    /// ctl `last-output` — rather than a stream. One block is capped at 256 KiB by the segmenter,
    /// so the encoded worst case sits an order of magnitude under the frame ceiling.
    #[serde(deserialize_with = "base64_bytes")]
    pub output: Vec<u8>,
}

impl Default for ControlBlock {
    fn default() -> Self {
        Self {
            index: 0,
            command_text: String::new(),
            exit_code: None,
            duration_ms: None,
            complete: true,
            output: Vec::new(),
        }
    }
}

/// A finished block as the agent-control verbs read it, with its output base64'd.
impl Serialize for ControlBlock {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(6))?;
        map.serialize_entry("index", &self.index)?;
        map.serialize_entry("commandText", &self.command_text)?;
        map.serialize_entry("exitCode", &self.exit_code)?;
        map.serialize_entry("durationMS", &self.duration_ms)?;
        map.serialize_entry("complete", &self.complete)?;
        map.serialize_entry("output", &base64(&self.output))?;
        map.end()
    }
}

/// Standard base64 with padding — the encoding a JSON reply carries retained output in.
#[must_use]
pub fn base64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

/// The bytes a base64 string carries, or none of them.
///
/// Validate-then-drop: bytes that will not decode would be a transcript that silently lies, so an
/// unusable body becomes an empty one rather than a guess at what was meant.
#[must_use]
pub fn unbase64(encoded: &str) -> Vec<u8> {
    STANDARD.decode(encoded).unwrap_or_default()
}

/// [`unbase64`], as a serde field adapter.
fn base64_bytes<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
    let encoded = <std::borrow::Cow<'de, str>>::deserialize(deserializer)?;
    Ok(unbase64(&encoded))
}

/// The `0x05` body's envelope. One key, and the whole batch is lost if it moves.
///
/// `Cow` for [`crate::sniffwire`]'s reason: one declaration serves the writer that borrows and the
/// reader that owns, so the envelope key is spelled once.
#[derive(Debug, Serialize, Deserialize)]
struct Batch<'a> {
    blocks: std::borrow::Cow<'a, [BlockEvent]>,
}

/// The batch as superd packs it into a [`crate::TAG_BLOCKS`] frame.
///
/// An empty batch on a serialisation error, for [`crate::sniffwire::encode_batch`]'s reason.
#[must_use]
pub fn encode_batch(blocks: &[BlockEvent]) -> Vec<u8> {
    let batch = Batch {
        blocks: std::borrow::Cow::Borrowed(blocks),
    };
    serde_json::to_vec(&batch).unwrap_or_else(|_ignored| br#"{"blocks":[]}"#.to_vec())
}

/// One `{"blocks": [...]}` body, as hostd reads it.
///
/// `None` only when the body is not the expected object at all — a member that cannot be read
/// becomes [`BlockEvent::Unknown`], never a thrown batch.
#[must_use]
pub fn decode_batch(json: &[u8]) -> Option<Vec<BlockEvent>> {
    serde_json::from_slice::<Batch<'_>>(json)
        .ok()
        .map(|batch| batch.blocks.into_owned())
}

#[cfg(test)]
#[expect(
    clippy::unwrap_used,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{BlockEvent, BlockMeta, ControlBlock, SyntheticProgress, decode_batch, encode_batch};

    /// The shape the wire has carried since minor 6, pinned as a literal — the assertion that used
    /// to sit in two suites in two languages and prove nothing jointly.
    #[test]
    fn every_event_serialises_to_the_shape_the_wire_has_always_carried() {
        let meta = BlockMeta {
            index: 3,
            exit_code: Some(0),
            duration_ms: Some(42),
            complete: true,
            output_len: 19,
            command_text: "ls -la".to_owned(),
            prompt_ordinal: 7,
        };
        let events = vec![
            BlockEvent::Meta(meta),
            BlockEvent::Meta(BlockMeta::default()),
            BlockEvent::Progress(SyntheticProgress::Indeterminate),
            BlockEvent::Progress(SyntheticProgress::Clear),
        ];
        assert_eq!(
            String::from_utf8(encode_batch(&events)).unwrap(),
            concat!(
                r#"{"blocks":[{"kind":"block","index":3,"exitCode":0,"durationMS":42,"#,
                r#""complete":true,"outputLen":19,"commandText":"ls -la","promptOrdinal":7},"#,
                // The running shape: both absent values present as null, never as a missing key.
                r#"{"kind":"block","index":0,"exitCode":null,"durationMS":null,"complete":false,"#,
                r#""outputLen":0,"commandText":"","promptOrdinal":0},"#,
                r#"{"kind":"progress","state":"indeterminate"},"#,
                r#"{"kind":"progress","state":"clear"}]}"#,
            )
        );
        assert_eq!(decode_batch(&encode_batch(&events)).unwrap(), events);
    }

    /// A badge state this build cannot name asserts NOTHING rather than guessing — either guess
    /// leaves a spinner in the wrong place, and one of them leaves it there forever.
    #[test]
    fn an_unknown_badge_state_is_a_skew_and_not_a_guess() {
        let batch = br#"{"blocks":[{"kind":"progress","state":"paused"}]}"#;
        assert_eq!(decode_batch(batch).unwrap(), vec![BlockEvent::Unknown {
            kind: "progress".to_owned()
        }],);
    }

    /// One unreadable member must not take the exit codes beside it down.
    #[test]
    fn one_unknown_member_does_not_lose_the_blocks_beside_it() {
        let batch = br#"{"blocks":[{"kind":"teleport"},{"kind":"block","index":1,"complete":true,
                        "outputLen":2,"commandText":"ls","promptOrdinal":0,"futureKey":9},{}]}"#;
        assert_eq!(decode_batch(batch).unwrap(), vec![
            BlockEvent::Unknown {
                kind: "teleport".to_owned()
            },
            BlockEvent::Meta(BlockMeta {
                index: 1,
                exit_code: None,
                duration_ms: None,
                complete: true,
                output_len: 2,
                command_text: "ls".to_owned(),
                prompt_ordinal: 0,
            }),
            BlockEvent::Unknown { kind: String::new() },
        ],);
    }

    /// The envelope is the one thing whose loss is total.
    #[test]
    fn only_a_lost_envelope_loses_the_whole_batch() {
        assert!(decode_batch(b"").is_none());
        assert!(decode_batch(br#"{"blcks":[]}"#).is_none());
        assert_eq!(decode_batch(br#"{"blocks":[]}"#).unwrap(), Vec::new());
    }

    /// The control read's asymmetric default, and the base64 that a lying transcript rides on.
    #[test]
    fn a_control_block_defaults_complete_to_true_and_drops_unusable_bytes() {
        let block: ControlBlock = serde_json::from_str(r#"{"index":4,"output":"Zm9v"}"#).unwrap();
        assert_eq!(block.index, 4);
        assert_eq!(block.output, b"foo");
        assert!(block.complete, "the ring holds only closed blocks");

        let broken: ControlBlock = serde_json::from_str(r#"{"output":"not base64!!"}"#).unwrap();
        assert!(
            broken.output.is_empty(),
            "an unusable body is empty, never a guess"
        );

        let round_tripped: ControlBlock = serde_json::from_str(
            &serde_json::to_string(&ControlBlock {
                index: 9,
                command_text: "echo hi".to_owned(),
                exit_code: Some(1),
                duration_ms: Some(3),
                complete: false,
                output: vec![0, 255, 128],
            })
            .unwrap(),
        )
        .unwrap();
        assert_eq!(round_tripped.output, vec![0, 255, 128]);
        assert!(!round_tripped.complete, "a spelled false survives the default");
    }

    /// The RFC 4648 vectors, including every padding case — a block whose output decodes to the
    /// wrong bytes is a transcript that silently lies.
    #[test]
    fn the_base64_codec_pads_exactly_as_the_standard_says() {
        for (bytes, encoded) in [
            (b"".as_slice(), ""),
            (b"f", "Zg=="),
            (b"fo", "Zm8="),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg=="),
            (b"fooba", "Zm9vYmE="),
            (b"foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(super::base64(bytes), encoded);
            assert_eq!(super::unbase64(encoded), bytes);
        }
        // The whole byte range, so the alphabet's tail (`+` and `/`) is covered rather than assumed.
        let every: Vec<u8> = (0..=255_u8).collect();
        let encoded = super::base64(&every);
        assert_eq!(encoded.len(), 344);
        assert!(encoded.contains('+') && encoded.contains('/'));
        assert!(encoded.ends_with("/w=="));
        assert_eq!(super::unbase64(&encoded), every);
    }
}
