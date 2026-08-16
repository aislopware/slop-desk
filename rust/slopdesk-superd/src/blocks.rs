//! What the segmenter found, kept and reported: the live half of the command-block tap.
//!
//! [`crate::commandblocks`] is the pure reader — bytes in, blocks out, no memory of what it already
//! said. This is the part that runs beside a live pane: it feeds each chunk through the segmenter,
//! decides which of the resulting changes are worth telling anyone about, and holds each finished
//! command's output so it can be fetched later by index.
//!
//! ## Why the retained output lives HERE and not in hostd
//!
//! hostd held this ring until stage 21, and lost it on every rebuild. A client that reattached
//! after `make host-restart` — 0.2 s — got an empty Commands panel for a session whose shell had
//! never stopped running, because the blocks, their exit codes and their captured output had all
//! been in the address space that was replaced. superd is the process that survives that, and it is
//! already the one holding the bytes, so keeping them here costs nothing that was not already being
//! paid and removes the only reason the panel could go blank.
//!
//! The cost is bounded twice over, and both bounds came with the ring: a block count and a total
//! byte ceiling, evicting oldest-first, on top of the segmenter's own per-block output cap. A
//! session that runs for a week retains the same amount as a session that has run for a minute.
//!
//! ## What is NOT decided here
//!
//! The wire. This module says a block's metadata changed, or that a synthetic badge should go up;
//! turning either into a frame is hostd's, exactly as it is for [`crate::sniffer`]. superd does not
//! know the protocol and must not learn it to do this job.

use std::collections::HashMap;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;

use crate::commandblocks::{CommandBlock, CommandBlockSegmenter, SyntheticProgress};

/// Default ceiling on how many finished blocks keep their output.
pub const DEFAULT_MAX_BLOCKS: usize = 64;

/// Default ceiling on the retained output bytes across all held blocks, 8 MiB.
///
/// A second bound rather than a redundant one: 64 blocks at the segmenter's 256 KiB per-block cap
/// would otherwise pin 16 MiB per pane.
pub const DEFAULT_MAX_TOTAL_OUTPUT_BYTES: usize = 8 * 1024 * 1024;

/// The wire-relevant facts about one block — and, being the whole of what is reported, also the
/// dedup key: a change here is exactly what earns a fresh report.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BlockMeta {
    /// The block's index in emission order.
    pub index: u32,
    /// The command's `$?`, when the shell reported one.
    pub exit_code: Option<i32>,
    /// The measured `C`→`D` milliseconds, absent while the command is still running.
    pub duration_ms: Option<u32>,
    /// Whether the matching `D` has arrived.
    pub complete: bool,
    /// How many output bytes are held for this block.
    pub output_len: u32,
    /// The typed command line.
    pub command_text: String,
    /// The block's prompt-row ordinal, `0` when unknown.
    pub prompt_ordinal: u32,
}

/// One thing that happened in a chunk, worth telling hostd about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlockEvent {
    /// A block was created, changed, or finished.
    Meta(BlockMeta),
    /// A synthetic progress badge should go up or come down for a slow command.
    Progress(SyntheticProgress),
}

/// One finished block joined with its metadata — what the agent-control verbs read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlBlock {
    /// The block's index.
    pub index: u32,
    /// The typed command line, as last reported.
    pub command_text: String,
    /// The command's `$?`, when the shell reported one.
    pub exit_code: Option<i32>,
    /// The measured `C`→`D` milliseconds.
    pub duration_ms: Option<u32>,
    /// Whether the block closed on its own `D` rather than on a fresh prompt.
    pub complete: bool,
    /// The retained output bytes.
    pub output: Vec<u8>,
}

/// The JSON one block's metadata crosses the socket as.
///
/// Tagged `kind` even though a snapshot is nothing but blocks, so that ONE decoder on hostd's side
/// reads a block wherever it turns up — inside a live `0x05` batch beside a progress badge, or in a
/// reattach snapshot. Two shapes for one fact is how the two drift.
///
/// `exitCode` and `durationMS` are ALWAYS present, carrying `null` when absent, so that a missing
/// key and an absent value are never told apart by which build wrote the frame.
///
/// ```json
/// {"kind":"block","index":3,"exitCode":0,"durationMS":42,"complete":true,"outputLen":19,
///  "commandText":"ls -la","promptOrdinal":7}
/// ```
impl serde::Serialize for BlockMeta {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap as _;

        let mut map = serializer.serialize_map(Some(8))?;
        map.serialize_entry("kind", "block")?;
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

/// The JSON one block event crosses the socket as — a block, or a badge.
///
/// Hand-written for the same reason [`crate::sniffer::SniffEvent`]'s is: serde cannot
/// internally-tag an enum whose variants are newtypes, and the failure is a RUN-time one, on the
/// hot path, per chunk.
///
/// ```json
/// {"kind":"progress","state":"indeterminate"}
/// ```
impl serde::Serialize for BlockEvent {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap as _;

        match *self {
            // Delegated rather than repeated: a snapshot serialises the same object without the
            // event wrapper, and two copies of the key names is one rename away from a silent skew.
            Self::Meta(ref meta) => meta.serialize(serializer),
            Self::Progress(state) => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("kind", "progress")?;
                map.serialize_entry("state", match state {
                    SyntheticProgress::Indeterminate => "indeterminate",
                    SyntheticProgress::Clear => "clear",
                })?;
                map.end()
            },
        }
    }
}

/// A finished block as the agent-control verbs read it, with its output base64'd.
///
/// Base64 rather than a binary frame because this is a fetch a person asked for — a click on a
/// block, or a ctl `last-output` — not a stream. One block is capped at 256 KiB by the segmenter,
/// so the encoded worst case sits an order of magnitude under the frame ceiling, and the reply
/// stays one JSON object that every existing decode path already handles.
impl serde::Serialize for ControlBlock {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap as _;

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

/// Standard base64 with padding — the encoding the client's JSON reply carries retained output in.
///
/// The `base64` crate rather than the twenty lines this used to be: the decoder in
/// [`crate::sniffer`] reads the same engine, so there is one codec in this binary instead of an
/// encoder and a decoder written separately and agreeing by inspection.
#[must_use]
pub fn base64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

/// One retained block's output.
#[derive(Debug, Clone)]
struct Held {
    index: u32,
    output: Vec<u8>,
}

/// The per-pane block tap: segmenter, output ring, and the record of what was last reported.
#[derive(Debug, Clone)]
pub struct BlockTracker {
    segmenter: CommandBlockSegmenter,
    max_blocks: usize,
    max_total_output_bytes: usize,
    /// Insertion-ordered, oldest first — eviction order is the whole reason this is not a map.
    held: Vec<Held>,
    total_output_bytes: usize,
    /// The metadata last reported per index, for both running and finished blocks. Pruned with the
    /// ring, so it is bounded by the same two ceilings.
    last_reported: HashMap<u32, BlockMeta>,
}

impl BlockTracker {
    /// A fresh tap.
    ///
    /// A zero bound would mean "retain nothing", which no caller can plausibly want, so each falls
    /// back to its default rather than silently turning retention off.
    #[must_use]
    pub fn new(
        auto_progress_prefixes: Vec<String>,
        output_cap: usize,
        max_blocks: usize,
        max_total_output_bytes: usize,
    ) -> Self {
        Self {
            segmenter: CommandBlockSegmenter::new(output_cap, auto_progress_prefixes),
            max_blocks: if max_blocks == 0 {
                DEFAULT_MAX_BLOCKS
            } else {
                max_blocks
            },
            max_total_output_bytes: if max_total_output_bytes == 0 {
                DEFAULT_MAX_TOTAL_OUTPUT_BYTES
            } else {
                max_total_output_bytes
            },
            held: Vec::new(),
            total_output_bytes: 0,
            last_reported: HashMap::new(),
        }
    }

    /// Feeds one outbound chunk and answers what changed, deduped.
    ///
    /// The still-open block is reported too, so a command shows up as running the moment it starts
    /// rather than when it ends.
    pub fn ingest(&mut self, chunk: &[u8], now_ms: i64) -> Vec<BlockEvent> {
        let closed = self.segmenter.ingest(chunk, now_ms);
        let mut events: Vec<BlockEvent> = self
            .segmenter
            .drain_auto_progress()
            .into_iter()
            .map(BlockEvent::Progress)
            .collect();
        for block in closed {
            // Report before retaining, so the dedup compares against what was last SAID rather than
            // against the state being written in the same breath.
            if let Some(meta) = self.report_if_changed(&block) {
                events.push(BlockEvent::Meta(meta));
            }
            self.store(block);
        }
        if let Some(open) = self.segmenter.peek_open_block()
            && let Some(meta) = self.report_if_changed(&open)
        {
            events.push(BlockEvent::Meta(meta));
        }
        events
    }

    /// Everything this tap still knows, in ascending index order.
    ///
    /// What a reattaching client is backfilled from. Block metadata does not ride the replayed
    /// output stream — only raw bytes do — so without this a returning client shows an empty
    /// Commands panel for a session whose every block superd still holds.
    #[must_use]
    pub fn snapshot(&self) -> Vec<BlockMeta> {
        let mut indices: Vec<u32> = self.last_reported.keys().copied().collect();
        indices.sort_unstable();
        indices
            .iter()
            .filter_map(|index| self.last_reported.get(index).cloned())
            .collect()
    }

    /// A finished block's retained output, or `None` once it has been evicted or if it never was.
    #[must_use]
    pub fn output(&self, index: u32) -> Option<&[u8]> {
        self.held
            .iter()
            .find(|held| held.index == index)
            .map(|held| held.output.as_slice())
    }

    /// The last `limit` retained blocks, oldest first, each joined with its metadata.
    ///
    /// The ring holds only CLOSED blocks, but a closed block is not necessarily a complete one: a
    /// command interrupted by a fresh prompt closes without ever seeing its `D`.
    #[must_use]
    pub fn recent(&self, limit: usize) -> Vec<ControlBlock> {
        if limit == 0 {
            return Vec::new();
        }
        let start = self.held.len().saturating_sub(limit);
        self.held
            .get(start..)
            .unwrap_or_default()
            .iter()
            .map(|held| {
                let meta = self.last_reported.get(&held.index);
                ControlBlock {
                    index: held.index,
                    command_text: meta.map(|meta| meta.command_text.clone()).unwrap_or_default(),
                    exit_code: meta.and_then(|meta| meta.exit_code),
                    duration_ms: meta.and_then(|meta| meta.duration_ms),
                    complete: meta.is_none_or(|meta| meta.complete),
                    output: held.output.clone(),
                }
            })
            .collect()
    }

    /// A snapshot of the still-running block, or `None` at an idle prompt.
    #[must_use]
    pub fn open_block(&self) -> Option<CommandBlock> {
        self.segmenter.peek_open_block()
    }

    /// The index the NEXT command typed at this prompt will close under — the `run --wait`
    /// baseline.
    ///
    /// A command already EXECUTING will consume the segmenter's next index itself when it closes,
    /// so a fresh one lands past it. An idle prompt, or a block still in its command phase (which
    /// is discarded without consuming an index), lands exactly on it.
    #[must_use]
    pub fn expected_next_index(&self) -> u32 {
        let running = u64::from(self.segmenter.peek_open_block().is_some());
        let base = self.segmenter.next_block_index().saturating_add(running);
        u32::try_from(base).unwrap_or(u32::MAX)
    }

    /// Builds a block's metadata and answers it only if it MEANINGFULLY differs from what was last
    /// reported for that index. Records the new metadata either way.
    ///
    /// The churn guard: a running block deliberately leaves its growing `output_len` out of the
    /// comparison. Including it would report the same block on every chunk of a command that prints
    /// steadily, for no gain — a client gates the copy affordance on completion and has no use for
    /// a live byte count. So a running block is reported once when it opens (and again if its
    /// command text fills in late), and the completion report carries the exact final numbers. The
    /// latest length is still RECORDED, so the running→finished transition is never missed.
    fn report_if_changed(&mut self, block: &CommandBlock) -> Option<BlockMeta> {
        let meta = BlockMeta {
            index: u32::try_from(block.index).unwrap_or(u32::MAX),
            exit_code: block.exit_code,
            duration_ms: block.duration_ms,
            complete: block.complete,
            output_len: u32::try_from(block.output.len()).unwrap_or(u32::MAX),
            command_text: block.command_text.clone(),
            prompt_ordinal: u32::try_from(block.prompt_ordinal).unwrap_or(u32::MAX),
        };
        let worth_saying = self
            .last_reported
            .get(&meta.index)
            .is_none_or(|last| meaningfully_changed(last, &meta));
        let index = meta.index;
        let answer = worth_saying.then(|| meta.clone());
        let _ignored = self.last_reported.insert(index, meta);
        answer
    }

    /// Retains a finished block's output, replacing any prior record for that index, then evicts
    /// oldest-first until both bounds hold again.
    fn store(&mut self, block: CommandBlock) {
        let index = u32::try_from(block.index).unwrap_or(u32::MAX);
        if let Some(existing) = self.held.iter_mut().find(|held| held.index == index) {
            self.total_output_bytes = self.total_output_bytes.saturating_sub(existing.output.len());
            existing.output = block.output;
            self.total_output_bytes = self.total_output_bytes.saturating_add(existing.output.len());
        } else {
            self.total_output_bytes = self.total_output_bytes.saturating_add(block.output.len());
            self.held.push(Held {
                index,
                output: block.output,
            });
        }
        self.evict_to_bounds();
    }

    /// Evicts oldest-first until both ceilings hold.
    ///
    /// The most recent block is always kept even when it alone exceeds the byte ceiling, so a
    /// single huge command is still fetchable — the segmenter has already capped it at 256 KiB,
    /// so this cannot be unbounded. An evicted block's dedup record goes with it; indices are
    /// monotonic, so it can never recur, and the map stays bounded by the ring.
    fn evict_to_bounds(&mut self) {
        while self.held.len() > self.max_blocks && !self.held.is_empty() {
            self.evict_oldest();
        }
        while self.total_output_bytes > self.max_total_output_bytes && self.held.len() > 1 {
            self.evict_oldest();
        }
    }

    fn evict_oldest(&mut self) {
        if self.held.is_empty() {
            return;
        }
        let gone = self.held.remove(0);
        self.total_output_bytes = self.total_output_bytes.saturating_sub(gone.output.len());
        let _ignored = self.last_reported.remove(&gone.index);
    }
}

/// Whether moving from `last` to `next` is worth a fresh report.
///
/// A finished block compares on every field — the completion report has to be exact. Two running
/// states ignore `output_len`, which is the per-chunk churn the guard exists to suppress.
fn meaningfully_changed(last: &BlockMeta, next: &BlockMeta) -> bool {
    if next.complete || last.complete {
        return last != next;
    }
    last.exit_code != next.exit_code
        || last.duration_ms != next.duration_ms
        || last.command_text != next.command_text
        || last.prompt_ordinal != next.prompt_ordinal
}

#[cfg(test)]
#[expect(
    clippy::expect_used,
    clippy::indexing_slicing,
    reason = "a panic in a test is the failure report, not a runtime fault"
)]
mod tests {
    use super::{BlockEvent, BlockTracker, SyntheticProgress};

    /// A whole command, as the shim's marks spell it.
    fn command(text: &str, output: &str, exit: &str) -> Vec<u8> {
        format!("\x1B]133;A\x07prompt$ \x1B]133;B\x07{text}\n\x1B]133;C\x07{output}\x1B]133;D;{exit}\x07")
            .into_bytes()
    }

    fn tracker() -> BlockTracker {
        BlockTracker::new(Vec::new(), 0, 0, 0)
    }

    fn metas(events: &[BlockEvent]) -> Vec<&super::BlockMeta> {
        events
            .iter()
            .filter_map(|event| {
                match *event {
                    BlockEvent::Meta(ref meta) => Some(meta),
                    BlockEvent::Progress(_) => None,
                }
            })
            .collect()
    }

    #[test]
    fn a_finished_command_is_reported_once_with_its_exit_code_and_retained_output() {
        let mut tracker = tracker();
        let events = tracker.ingest(&command("ls", "a.txt\n", "0"), 1_000);
        let reported = metas(&events);
        assert_eq!(reported.len(), 1, "one closed block, one report");
        assert_eq!(reported[0].command_text, "ls");
        assert_eq!(reported[0].exit_code, Some(0));
        assert!(reported[0].complete);
        assert_eq!(tracker.output(0), Some(b"a.txt\n".as_slice()));
    }

    /// The churn guard, and the reason it is worth having: a command that prints steadily would
    /// otherwise produce one report per 32 KiB read for its whole run.
    #[test]
    fn a_running_command_is_reported_once_however_much_it_prints() {
        let mut tracker = tracker();
        let opening = tracker.ingest(b"\x1B]133;A\x07$ \x1B]133;B\x07tail -f log\n\x1B]133;C\x07", 0);
        assert_eq!(metas(&opening).len(), 1, "the block opens with one report");
        assert!(!metas(&opening)[0].complete);

        for _ignored in 0..8 {
            let quiet = tracker.ingest(b"another line of output\n", 0);
            assert!(metas(&quiet).is_empty(), "output growth alone says nothing new");
        }

        let closing = tracker.ingest(b"\x1B]133;D;1\x07", 40);
        let closed = metas(&closing);
        assert_eq!(closed.len(), 1);
        assert!(closed[0].complete, "the completion is never suppressed");
        assert_eq!(closed[0].exit_code, Some(1));
        assert_eq!(closed[0].duration_ms, Some(40));
        assert!(
            closed[0].output_len > 0,
            "and it carries the final length exactly"
        );
    }

    #[test]
    fn a_configured_slow_command_raises_and_clears_a_synthetic_badge() {
        let mut configured = BlockTracker::new(vec!["git push".to_owned()], 0, 0, 0);
        let opening = configured.ingest(
            b"\x1B]133;A\x07$ \x1B]133;B\x07git push origin main\n\x1B]133;C\x07",
            0,
        );
        assert!(opening.contains(&BlockEvent::Progress(SyntheticProgress::Indeterminate)));
        let closing = configured.ingest(b"\x1B]133;D;0\x07", 10);
        assert!(closing.contains(&BlockEvent::Progress(SyntheticProgress::Clear)));

        let mut unconfigured = tracker();
        let events = unconfigured.ingest(&command("git push origin main", "", "0"), 0);
        assert!(
            !events
                .iter()
                .any(|event| matches!(*event, BlockEvent::Progress(_))),
            "an empty prefix list is the feature turned off"
        );
    }

    #[test]
    fn the_ring_evicts_oldest_first_on_the_count_bound() {
        let mut tracker = BlockTracker::new(Vec::new(), 0, 2, 0);
        for index in 0..4_u32 {
            let _ignored = tracker.ingest(&command(&format!("cmd{index}"), "out", "0"), 0);
        }
        assert!(tracker.output(0).is_none(), "the oldest is gone");
        assert!(tracker.output(1).is_none());
        assert_eq!(tracker.output(2), Some(b"out".as_slice()));
        assert_eq!(tracker.output(3), Some(b"out".as_slice()));
        // And the dedup record went with it, so the map cannot outgrow the ring.
        assert_eq!(
            tracker
                .snapshot()
                .iter()
                .map(|meta| meta.index)
                .collect::<Vec<_>>(),
            vec![2, 3]
        );
    }

    /// The byte ceiling keeps the most recent block whatever its size — an unfetchable newest block
    /// would be the one case a user actually notices.
    #[test]
    fn the_byte_bound_evicts_but_never_to_nothing() {
        let mut tracker = BlockTracker::new(Vec::new(), 0, 64, 8);
        let _ignored = tracker.ingest(&command("a", "0123456789", "0"), 0);
        let _ignored = tracker.ingest(&command("b", "0123456789", "0"), 0);
        assert!(tracker.output(0).is_none());
        assert_eq!(tracker.output(1), Some(b"0123456789".as_slice()));
    }

    #[test]
    fn a_reattach_snapshot_lists_every_block_still_known_in_index_order() {
        let mut tracker = tracker();
        let _ignored = tracker.ingest(&command("one", "x", "0"), 0);
        let _ignored = tracker.ingest(&command("two", "y", "3"), 0);
        let snapshot = tracker.snapshot();
        assert_eq!(
            snapshot
                .iter()
                .map(|meta| meta.command_text.as_str())
                .collect::<Vec<_>>(),
            vec!["one", "two"]
        );
        assert_eq!(snapshot[1].exit_code, Some(3));
    }

    #[test]
    fn the_control_surface_reads_the_ring_and_the_running_block() {
        let mut tracker = tracker();
        let _ignored = tracker.ingest(&command("first", "1", "0"), 0);
        let _ignored = tracker.ingest(&command("second", "2", "0"), 0);
        let recent = tracker.recent(1);
        assert_eq!(recent.len(), 1, "the limit is a tail, not a head");
        assert_eq!(recent[0].command_text, "second");
        assert_eq!(recent[0].output, b"2");
        assert!(tracker.recent(0).is_empty());

        assert!(
            tracker.open_block().is_none(),
            "an idle prompt is not a running command"
        );
        assert_eq!(tracker.expected_next_index(), 2);

        let _ignored = tracker.ingest(b"\x1B]133;A\x07$ \x1B]133;B\x07sleep 9\n\x1B]133;C\x07", 0);
        assert_eq!(
            tracker.open_block().map(|open| open.command_text),
            Some("sleep 9".to_owned())
        );
        assert_eq!(
            tracker.expected_next_index(),
            3,
            "a command already running consumes index 2 itself"
        );
    }

    /// The cross-language contract, pinned as a literal here and as the same literal in
    /// `SlopDeskHost`'s decode suite. A rename on either side is otherwise silent: hostd would
    /// decode a block with a missing field and the Commands panel would simply stop filling in,
    /// with nothing logged.
    #[test]
    fn every_event_serialises_to_the_shape_the_client_decodes() {
        let meta = super::BlockMeta {
            index: 3,
            exit_code: Some(0),
            duration_ms: Some(42),
            complete: true,
            output_len: 19,
            command_text: "ls -la".to_owned(),
            prompt_ordinal: 7,
        };
        assert_eq!(
            serde_json::to_string(&BlockEvent::Meta(meta)).expect("a block meta serialises"),
            r#"{"kind":"block","index":3,"exitCode":0,"durationMS":42,"complete":true,"outputLen":19,"commandText":"ls -la","promptOrdinal":7}"#
        );
        // The running shape: both absent values present as null, never as a missing key.
        assert_eq!(
            serde_json::to_string(&BlockEvent::Meta(super::BlockMeta::default()))
                .expect("a default serialises"),
            r#"{"kind":"block","index":0,"exitCode":null,"durationMS":null,"complete":false,"outputLen":0,"commandText":"","promptOrdinal":0}"#
        );
        assert_eq!(
            serde_json::to_string(&BlockEvent::Progress(SyntheticProgress::Indeterminate))
                .expect("a badge serialises"),
            r#"{"kind":"progress","state":"indeterminate"}"#
        );
        assert_eq!(
            serde_json::to_string(&BlockEvent::Progress(SyntheticProgress::Clear))
                .expect("a badge serialises"),
            r#"{"kind":"progress","state":"clear"}"#
        );
    }

    /// The RFC 4648 vectors, including every padding case — a hand-rolled codec earns its own pin,
    /// and a block whose output decodes to the wrong bytes is a transcript that silently lies.
    #[test]
    fn the_base64_encoder_pads_exactly_as_the_standard_says() {
        assert_eq!(super::base64(b""), "");
        assert_eq!(super::base64(b"f"), "Zg==");
        assert_eq!(super::base64(b"fo"), "Zm8=");
        assert_eq!(super::base64(b"foo"), "Zm9v");
        assert_eq!(super::base64(b"foob"), "Zm9vYg==");
        assert_eq!(super::base64(b"fooba"), "Zm9vYmE=");
        assert_eq!(super::base64(b"foobar"), "Zm9vYmFy");
        // The whole byte range, so the alphabet's tail (`+` and `/`) is covered rather than assumed.
        let every: Vec<u8> = (0..=255_u8).collect();
        let encoded = super::base64(&every);
        assert_eq!(encoded.len(), 344);
        assert!(encoded.contains('+') && encoded.contains('/'));
        assert!(encoded.ends_with("/w=="));
    }

    #[test]
    fn an_evicted_block_answers_nothing_rather_than_guessing() {
        let tracker = tracker();
        assert!(tracker.output(0).is_none());
        assert!(tracker.output(u32::MAX).is_none());
    }
}
