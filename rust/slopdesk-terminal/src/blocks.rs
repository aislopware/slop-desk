//! The per-pane command blocks: one record per command the shell ran, as the CLIENT knows them.
//!
//! The host segments the byte stream into blocks and pushes METADATA only — index, command text,
//! exit code, duration, output length. The captured output bytes stay on the host until something
//! asks for one, which is why the control channel does not drown in command output and why this
//! module has a request registry as well as a ring.
//!
//! ## What is here and what is not
//!
//! Here: the ring and its bound, the status a block derives from `complete` and `exit_code`, the
//! bookmark set and its eviction, the jump-to-failed cursor walk, and the coalescing/generation
//! rules that decide whether an output request goes on the wire. All of it is a fold a test can
//! drive directly.
//!
//! Not here: the callbacks the request registry fans out to, and the symbol and label strings the
//! rows display. Both belong to the surface that owns them; a second copy of a UI string is a
//! drift, not a port.

use std::collections::{BTreeMap, BTreeSet};

/// The ring cap, mirroring the host's own 64-block ring.
///
/// The client must never hold a block the host already dropped — asking for such a block's output
/// gets an empty reply, and a row that can only ever fail to copy is worse than no row. Eviction
/// takes the OLDEST.
pub const MAX_BLOCKS: usize = 64;

/// Cap on bookmarks per pane, so a session running for a week cannot grow the set without bound.
/// Over the cap the oldest-inserted bookmark goes, FIFO.
pub const MAX_BOOKMARKS: usize = 256;

/// One command's record.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CommandBlock {
    /// The 0-based index in the host segmenter's lifetime. The upsert key AND the output-request
    /// key, stable for as long as the block lives.
    pub index: u32,
    /// The typed command line with no prompt, as the host segmented it. Empty while still forming.
    pub command_text: String,
    /// The command's `$?` once it finished. `None` while running, or when the shell reported none.
    pub exit_code: Option<i32>,
    /// Host-measured wall-clock milliseconds from start to finish. `None` while still running.
    pub duration_ms: Option<u32>,
    /// Set once the matching OSC 133 `D` arrived.
    pub complete: bool,
    /// How many output bytes the host currently holds — the size hint and the has-output gate.
    pub output_len: u32,
    /// The block's 1-based PROMPT-CYCLE ordinal: the count of OSC 133 `A` marks at its start,
    /// including the blockless empty-Enter and Ctrl-C cycles. The anchor an outline jump lands on.
    /// `0` means unknown — a mid-stream join — and such a block is skipped rather than mis-landed.
    pub prompt_ordinal: u32,
}

/// What a block's `complete` and `exit_code` add up to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BlockStatus {
    /// No OSC 133 `D` yet — the spinner state.
    Running,
    /// Finished at exit 0, or with no code reported at all, which is treated as success.
    Succeeded,
    /// Finished at a non-zero code.
    Failed(i32),
}

impl CommandBlock {
    /// The derived status.
    ///
    /// A block INTERRUPTED by a new prompt — a nested shell or an `ssh` emitting its own OSC 133
    /// `A`/`B` with no `D` — is closed on the host with `complete == false` but a stamped duration.
    /// So "has a duration" counts as finished, or that row spins `running…` forever. A block that
    /// is genuinely still running always arrives with no duration.
    #[must_use]
    pub const fn status(&self) -> BlockStatus {
        if !self.complete && self.duration_ms.is_none() {
            return BlockStatus::Running;
        }
        match self.exit_code {
            None | Some(0) => BlockStatus::Succeeded,
            Some(code) => BlockStatus::Failed(code),
        }
    }

    /// Whether this block FAILED: finished, with a reported non-zero code.
    ///
    /// A running block is never failed and a finished exit-0 block is a success. The one predicate
    /// the "Failed" filter and jump-to-failed both read, so they cannot disagree.
    #[must_use]
    pub const fn is_failed(&self) -> bool {
        matches!(self.status(), BlockStatus::Failed(_))
    }

    /// The duration formatted compactly — `"340ms"`, `"1.3s"` — or `None` while running.
    ///
    /// Seconds carry one decimal so the chip's width cannot jitter as a long command ticks.
    #[must_use]
    pub fn duration_label(&self) -> Option<String> {
        let ms = self.duration_ms?;
        Some(if ms >= 1000 {
            format!("{:.1}s", f64::from(ms) / 1000.0)
        } else {
            format!("{ms}ms")
        })
    }
}

/// The navigator's filter segment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum BlockNavigatorFilter {
    /// Every block held.
    #[default]
    All,
    /// Only finished non-zero exits — jump-to-error.
    Failed,
    /// Only the starred set.
    Bookmarked,
}

/// The per-pane store: an ordered, bounded ring of blocks plus the bookmark set over it.
#[derive(Debug, Clone, Default)]
pub struct BlockRing {
    blocks: Vec<CommandBlock>,
    first_seen: BTreeMap<u32, i64>,
    bookmark_order: Vec<u32>,
    bookmarked: BTreeSet<u32>,
}

impl BlockRing {
    /// An empty ring.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            blocks: Vec::new(),
            first_seen: BTreeMap::new(),
            bookmark_order: Vec::new(),
            bookmarked: BTreeSet::new(),
        }
    }

    /// The blocks in index order, oldest first.
    #[must_use]
    pub fn blocks(&self) -> &[CommandBlock] {
        &self.blocks
    }

    /// The newest-first blocks matching `filter`.
    #[must_use]
    pub fn filtered(&self, filter: BlockNavigatorFilter) -> Vec<&CommandBlock> {
        self.blocks
            .iter()
            .rev()
            .filter(|block| {
                match filter {
                    BlockNavigatorFilter::All => true,
                    BlockNavigatorFilter::Failed => block.is_failed(),
                    BlockNavigatorFilter::Bookmarked => self.bookmarked.contains(&block.index),
                }
            })
            .collect()
    }

    /// The block at `index`, or `None` when it was never seen or has been evicted.
    #[must_use]
    pub fn block(&self, index: u32) -> Option<&CommandBlock> {
        self.blocks.iter().find(|block| block.index == index)
    }

    /// When `index` was FIRST seen, on whatever clock the caller passed to
    /// [`upsert`](Self::upsert).
    ///
    /// Captured once, on the upsert that introduced the index — a later running→complete update
    /// does not move it — and dropped with the block on eviction. It is the client's receive
    /// time rather than the host's because the two differ by the link RTT and there is no
    /// timestamp on the wire to use instead.
    #[must_use]
    pub fn first_seen(&self, index: u32) -> Option<i64> {
        self.first_seen.get(&index).copied()
    }

    /// Upserts a block: a new index inserts in index order, a known index replaces in place.
    ///
    /// The host emits ascending indices, but nothing here depends on that — a lower index arriving
    /// late still lands in its ordered slot. Past [`MAX_BLOCKS`] the oldest is evicted, taking its
    /// first-seen stamp with it.
    pub fn upsert(&mut self, block: CommandBlock, now: i64) {
        let index = block.index;
        if let Some(slot) = self.blocks.iter_mut().find(|held| held.index == index) {
            *slot = block;
            return;
        }
        self.first_seen.insert(index, now);
        let insert_at = self
            .blocks
            .iter()
            .position(|held| held.index > index)
            .unwrap_or(self.blocks.len());
        self.blocks.insert(insert_at, block);
        while self.blocks.len() > MAX_BLOCKS {
            let evicted = self.blocks.remove(0);
            self.first_seen.remove(&evicted.index);
        }
    }

    /// Whether `index` is bookmarked.
    #[must_use]
    pub fn is_bookmarked(&self, index: u32) -> bool {
        self.bookmarked.contains(&index)
    }

    /// The bookmarked indices.
    #[must_use]
    pub const fn bookmarks(&self) -> &BTreeSet<u32> {
        &self.bookmarked
    }

    /// Toggles `index`'s bookmark and answers the resulting set, for the caller to persist.
    ///
    /// Two toggles return to where they started. Adding past [`MAX_BOOKMARKS`] evicts the
    /// oldest-inserted, so the cap is a bound and not a refusal.
    pub fn toggle_bookmark(&mut self, index: u32) -> &BTreeSet<u32> {
        if self.bookmarked.remove(&index) {
            self.bookmark_order.retain(|held| *held != index);
        } else {
            self.bookmarked.insert(index);
            self.bookmark_order.push(index);
            while self.bookmark_order.len() > MAX_BOOKMARKS {
                let evicted = self.bookmark_order.remove(0);
                self.bookmarked.remove(&evicted);
            }
        }
        &self.bookmarked
    }

    /// SEEDS the bookmark set from persistence on attach.
    ///
    /// A restore, not an edit, so the caller should not persist the result back. Duplicates
    /// collapse and a corrupt over-long set is trimmed to the first [`MAX_BOOKMARKS`] in the
    /// caller's order, which is also the order future FIFO eviction will use.
    pub fn set_bookmarks(&mut self, indices: &[u32]) {
        self.bookmark_order.clear();
        self.bookmarked.clear();
        for &index in indices {
            if self.bookmark_order.len() >= MAX_BOOKMARKS {
                break;
            }
            if self.bookmarked.insert(index) {
                self.bookmark_order.push(index);
            }
        }
    }

    /// Clears the blocks, their stamps and the bookmarks — a reconnect's blocks are a dead
    /// session's.
    ///
    /// The bookmarks go WITHOUT reporting a change, because a reset must not overwrite the
    /// persisted set with an empty one: persistence keys by the session scope, not the pane, so
    /// a within-launch reconnect leaves the stored set alone and re-seeds from it on the next
    /// attach.
    pub fn reset(&mut self) {
        self.blocks.clear();
        self.first_seen.clear();
        self.bookmark_order.clear();
        self.bookmarked.clear();
    }
}

/// The next or previous FAILED block from a cursor, over a NEWEST-FIRST list.
///
/// "Forward" steps toward later positions in that list, which is toward OLDER blocks. `from_index`
/// of `None` starts just off the matching end, so a first forward jump lands on the newest failure.
/// A cursor sitting ON a failed block advances PAST it, so repeated jumps walk every failure
/// instead of sticking to one. A cursor naming a block that has been evicted also starts from the
/// end. Never wraps: running out of blocks in that direction answers `None`.
#[must_use]
pub fn adjacent_failed<'a>(
    newest_first: &[&'a CommandBlock],
    from_index: Option<u32>,
    forward: bool,
) -> Option<&'a CommandBlock> {
    let cursor = from_index.and_then(|index| newest_first.iter().position(|block| block.index == index));
    if forward {
        let start = cursor.map_or(0, |position| position + 1);
        newest_first
            .get(start..)?
            .iter()
            .find(|block| block.is_failed())
            .copied()
    } else {
        let end = cursor.unwrap_or(newest_first.len());
        newest_first
            .get(..end)?
            .iter()
            .rev()
            .find(|block| block.is_failed())
            .copied()
    }
}

/// How far back the re-anchor jump reaches before counting forward.
///
/// Larger than any scrollback a prompt ordinal can name, which is the point: it lands the cursor at
/// the OLDEST prompt whatever the scrollback holds, so the forward count below starts from a known
/// position rather than from wherever the viewport happened to be.
pub const JUMP_RE_ANCHOR_DELTA: u32 = 32_000;

/// The largest single forward hop the terminal's own binding accepts.
pub const JUMP_MAX_STEP: u32 = 32_000;

/// The sequence of binding actions that lands the viewport on a prompt ordinal.
///
/// Absolute positioning built out of a RELATIVE binding: scroll to the bottom, reach back past
/// every prompt there could be, then count forward. `ordinal` is 1-based and the re-anchor already
/// sits on the first prompt, so the count is one short of it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct JumpPlan {
    /// The forward hops, each within [`JUMP_MAX_STEP`]. Empty means the re-anchor already landed.
    pub hops: Vec<u32>,
}

/// The hops that land on `ordinal`, or `None` when there is nothing to land on.
///
/// A zero ordinal is a mid-stream join — the host stamped no prompt ordinal for that block — and
/// there is no position to jump to, which is different from "jump nowhere".
#[must_use]
pub fn jump_plan(ordinal: u32) -> Option<JumpPlan> {
    if ordinal == 0 {
        return None;
    }
    let mut remaining = ordinal - 1;
    let mut hops = Vec::new();
    while remaining > 0 {
        let hop = remaining.min(JUMP_MAX_STEP);
        hops.push(hop);
        remaining -= hop;
    }
    Some(JumpPlan { hops })
}

/// What [`OutputRequests::request`] decided.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OutputRequest {
    /// Nothing was in flight for this index — put the request on the wire. Carries the generation
    /// this send armed, which a timeout must quote back.
    Send(u64),
    /// A request for this index is already in flight, so this one rides along on it. Carries the
    /// generation the live request armed, which the rider shares.
    Coalesced(u64),
}

impl OutputRequest {
    /// The generation, whichever arm this is.
    #[must_use]
    pub const fn generation(self) -> u64 {
        match self {
            Self::Send(generation) | Self::Coalesced(generation) => generation,
        }
    }
}

/// The in-flight output requests, one slot per block index.
///
/// Two rules live here and both exist to stop a copy spinner spinning forever. Concurrent requests
/// for the SAME block COALESCE onto one wire request, so ten clicks do not send ten frames. And
/// each fresh send bumps a per-index GENERATION, so a timeout armed for an earlier request cannot
/// resolve a later one: the second copy of a block opens a new slot with a newer token, and the
/// first copy's parked timer quotes a stale one and is ignored.
#[derive(Debug, Clone, Default)]
pub struct OutputRequests {
    pending: BTreeSet<u32>,
    generation: BTreeMap<u32, u64>,
}

impl OutputRequests {
    /// An empty registry.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            pending: BTreeSet::new(),
            generation: BTreeMap::new(),
        }
    }

    /// Opens or joins a request for `index`.
    pub fn request(&mut self, index: u32) -> OutputRequest {
        if self.pending.contains(&index) {
            return OutputRequest::Coalesced(self.generation.get(&index).copied().unwrap_or(0));
        }
        let generation = self.generation.get(&index).copied().unwrap_or(0).wrapping_add(1);
        self.generation.insert(index, generation);
        self.pending.insert(index);
        OutputRequest::Send(generation)
    }

    /// Whether a request for `index` is still in flight.
    #[must_use]
    pub fn is_pending(&self, index: u32) -> bool {
        self.pending.contains(&index)
    }

    /// The generation a live request for `index` armed, or `None` when nothing is in flight.
    #[must_use]
    pub fn current_generation(&self, index: u32) -> Option<u64> {
        self.pending
            .contains(&index)
            .then(|| self.generation.get(&index).copied().unwrap_or(0))?
            .into()
    }

    /// Closes the slot for `index` because a reply arrived. `false` when there was nothing pending
    /// — a stray or late reply is dropped, not an error.
    pub fn resolve(&mut self, index: u32) -> bool {
        self.pending.remove(&index)
    }

    /// Closes the slot for `index` because a timer fired.
    ///
    /// `generation` of `Some` fires ONLY if that token is still live, which is what keeps a stale
    /// timer from killing a later request; `None` times out whatever is pending. `false` means the
    /// timer was stale or the request had already resolved — in both cases, a no-op.
    pub fn time_out(&mut self, index: u32, generation: Option<u64>) -> bool {
        if let Some(quoted) = generation
            && self.generation.get(&index).copied() != Some(quoted)
        {
            return false;
        }
        self.pending.remove(&index)
    }

    /// Abandons every in-flight request, answering the indices that were stranded so the caller can
    /// resolve each as unavailable rather than leaving a continuation parked forever.
    ///
    /// The generations are KEPT: a slot reopened after a reset must still get a strictly newer
    /// token than any timer left over from before it.
    pub fn reset(&mut self) -> Vec<u32> {
        core::mem::take(&mut self.pending).into_iter().collect()
    }
}

/// The bytes that RE-RUN a captured command, or `None` for one with nothing in it.
///
/// A block's `command_text` is what the shell already ran, and "Re-run Command" replays it by
/// injecting these bytes as ordinary keystrokes (wire type 3, `.input`). Nothing on the host or the
/// wire changes: the host sees a person typing.
///
/// ## Why this is deliberately not the send-keys path
///
/// A user-authored launch preset goes through the send-keys token parser, because macro text is
/// what that field IS. A captured command must not, and the difference is security-critical in both
/// directions. A command may literally contain the substrings `<Enter>` or `<cr>` — `echo
/// "<Enter>"` is a command a person runs — and routing it through the parser would turn that
/// literal text into a control byte, so the replay would not be the thing that ran. It is also an
/// injection hazard, because a block's text is downstream of host output and therefore
/// attacker-influenced. So the command crosses VERBATIM as its own UTF-8 and nothing in it is
/// interpreted.
///
/// ## The three rules about newlines
///
/// **Exactly one trailing `0x0A`.** Whatever trailing CR/LF run the host's segmenter left on the
/// text is stripped first and a single newline is appended, so a command captured with its newline
/// already attached executes once instead of twice.
///
/// **Middle newlines survive.** A multi-line command is one the user typed as one; replaying it
/// with the interior newlines rewritten would replay a different command.
///
/// **Empty or whitespace-only answers `None`.** A bare newline at a prompt only redraws the prompt,
/// which is a confusing no-op rather than a re-run, so nothing is sent at all.
///
/// ## Two traps this inherited, one of which does not exist in Rust
///
/// The Swift this replaces trimmed the trailing run at the BYTE level and said so in a comment,
/// because Swift clusters `"\r\n"` into ONE `Character`: a `Character`-based trim would strip that
/// cluster as a unit against a `"\n"` pattern and miss it, so `"make\r\n"` came out with a double
/// newline and ran twice. Rust has no such trap — `char` is a scalar, `\r` and `\n` are two of
/// them, and both are ASCII so a scalar trim and a byte trim cannot disagree inside UTF-8. The
/// reason is recorded because the Swift comment explaining it goes away with the Swift, and the
/// next person to simplify this needs to know which language the hazard belonged to.
///
/// The whitespace SET is the trap that does survive, and it does not survive as a match. Swift's
/// `.whitespacesAndNewlines` is Foundation's own set, and it contains U+200B ZERO WIDTH SPACE,
/// which Unicode does not give the `White_Space` property and which Rust's `char::is_whitespace`
/// therefore does not report. Left to `str::trim` a command of nothing but zero-width spaces would
/// stop being a no-op and start injecting an invisible line into the shell. So the predicate below
/// names Foundation's set explicitly rather than assuming the two agree.
#[must_use]
pub fn rerun_bytes(command_text: &str) -> Option<Vec<u8>> {
    // `all` over an empty iterator is `true`, so the empty command falls out here with the
    // whitespace-only ones — which is right, and is what the Swift's `.isEmpty` on a trimmed string
    // did by a longer route.
    if command_text.chars().all(is_foundation_whitespace) {
        return None;
    }
    let mut bytes = command_text.trim_end_matches(['\r', '\n']).as_bytes().to_vec();
    bytes.push(b'\n');
    Some(bytes)
}

/// Whether a scalar is one Foundation's `.whitespacesAndNewlines` contains.
///
/// That is Unicode's `White_Space` property — which is what [`char::is_whitespace`] answers — plus
/// U+200B, which Foundation includes and Unicode does not. See [`rerun_bytes`] for why the one
/// scalar of difference is worth naming rather than rounding off.
const fn is_foundation_whitespace(scalar: char) -> bool {
    scalar.is_whitespace() || scalar == '\u{200B}'
}

#[cfg(test)]
mod jump_plan_tests {
    use super::{JUMP_MAX_STEP, jump_plan};

    #[test]
    fn a_mid_stream_join_has_no_position_to_land_on() {
        assert!(
            jump_plan(0).is_none(),
            "the host stamped no prompt ordinal for that block"
        );
    }

    /// The hops for `ordinal`, or an empty vec — which is also the honest answer for a plan that
    /// asks for none, so every assertion below states the hops it expects rather than the shape.
    fn hops(ordinal: u32) -> Vec<u32> {
        jump_plan(ordinal).map(|plan| plan.hops).unwrap_or_default()
    }

    #[test]
    fn the_first_prompt_is_where_the_re_anchor_already_is() {
        assert!(
            jump_plan(1).is_some(),
            "ordinal 1 is a position, it just needs no hop"
        );
        assert_eq!(hops(1), Vec::<u32>::new());
    }

    #[test]
    fn the_count_is_one_short_of_the_ordinal() {
        assert_eq!(hops(5), vec![4]);
    }

    #[test]
    fn a_count_past_the_binding_s_ceiling_is_chunked_and_still_sums() {
        let ordinal = JUMP_MAX_STEP * 2 + 7;
        let hops = hops(ordinal);
        assert_eq!(hops, vec![JUMP_MAX_STEP, JUMP_MAX_STEP, 6]);
        assert_eq!(
            hops.iter().sum::<u32>(),
            ordinal - 1,
            "the hops land exactly on the ordinal"
        );
        assert!(
            hops.iter().all(|hop| *hop <= JUMP_MAX_STEP),
            "no hop exceeds the binding's ceiling"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BlockNavigatorFilter, BlockRing, BlockStatus, CommandBlock, MAX_BLOCKS, MAX_BOOKMARKS, OutputRequest,
        OutputRequests, adjacent_failed, rerun_bytes,
    };

    fn block(index: u32, exit_code: Option<i32>, complete: bool) -> CommandBlock {
        CommandBlock {
            index,
            command_text: format!("cmd{index}"),
            exit_code,
            duration_ms: complete.then_some(10),
            complete,
            output_len: 0,
            prompt_ordinal: index + 1,
        }
    }

    fn ring(blocks: &[CommandBlock]) -> BlockRing {
        let mut ring = BlockRing::new();
        for (tick, block) in blocks.iter().enumerate() {
            ring.upsert(block.clone(), i64::try_from(tick).unwrap_or(0));
        }
        ring
    }

    #[test]
    fn a_block_runs_until_it_is_complete_or_carries_a_duration() {
        let mut running = block(0, None, false);
        running.duration_ms = None;
        assert_eq!(running.status(), BlockStatus::Running);
        assert!(!running.is_failed());
        // Interrupted by a nested shell's prompt: not complete, but stamped — so, finished.
        let mut interrupted = running;
        interrupted.duration_ms = Some(42);
        assert_eq!(interrupted.status(), BlockStatus::Succeeded);
    }

    #[test]
    fn a_missing_exit_code_on_a_finished_block_counts_as_success() {
        assert_eq!(block(0, None, true).status(), BlockStatus::Succeeded);
        assert_eq!(block(0, Some(0), true).status(), BlockStatus::Succeeded);
        assert_eq!(block(0, Some(137), true).status(), BlockStatus::Failed(137));
        assert!(block(0, Some(137), true).is_failed());
    }

    #[test]
    fn the_duration_label_switches_units_at_a_second() {
        let mut sample = block(0, Some(0), true);
        sample.duration_ms = None;
        assert_eq!(sample.duration_label(), None);
        sample.duration_ms = Some(0);
        assert_eq!(sample.duration_label().as_deref(), Some("0ms"));
        sample.duration_ms = Some(999);
        assert_eq!(sample.duration_label().as_deref(), Some("999ms"));
        sample.duration_ms = Some(1000);
        assert_eq!(sample.duration_label().as_deref(), Some("1.0s"));
        sample.duration_ms = Some(1349);
        assert_eq!(sample.duration_label().as_deref(), Some("1.3s"));
    }

    #[test]
    fn a_known_index_updates_in_place_without_moving_or_restamping_it() {
        let mut ring = ring(&[block(0, None, false), block(1, None, false)]);
        assert_eq!(ring.first_seen(0), Some(0));
        let mut finished = block(0, Some(2), true);
        finished.output_len = 900;
        ring.upsert(finished, 99);
        assert_eq!(ring.blocks().len(), 2);
        assert_eq!(
            ring.block(0).map(CommandBlock::status),
            Some(BlockStatus::Failed(2))
        );
        assert_eq!(ring.block(0).map(|block| block.output_len), Some(900));
        // The stamp is the FIRST sighting, not the latest update.
        assert_eq!(ring.first_seen(0), Some(0));
        assert_eq!(ring.blocks().last().map(|block| block.index), Some(1));
    }

    #[test]
    fn a_late_lower_index_still_lands_in_order() {
        let ring = ring(&[block(5, None, true), block(9, None, true), block(7, None, true)]);
        let order: Vec<u32> = ring.blocks().iter().map(|block| block.index).collect();
        assert_eq!(order, vec![5, 7, 9]);
    }

    #[test]
    fn the_ring_evicts_the_oldest_and_forgets_its_stamp() {
        let mut ring = BlockRing::new();
        for index in 0..u32::try_from(MAX_BLOCKS).unwrap_or(0) + 3 {
            ring.upsert(block(index, Some(0), true), i64::from(index));
        }
        assert_eq!(ring.blocks().len(), MAX_BLOCKS);
        assert_eq!(ring.block(0), None);
        assert_eq!(ring.first_seen(0), None);
        assert_eq!(ring.blocks().first().map(|block| block.index), Some(3));
        assert_eq!(ring.first_seen(3), Some(3));
    }

    #[test]
    fn the_navigator_reads_newest_first_and_each_filter_narrows_it() {
        let mut ring = ring(&[
            block(0, Some(0), true),
            block(1, Some(1), true),
            block(2, None, false),
        ]);
        ring.toggle_bookmark(0);
        let seen = |blocks: Vec<&CommandBlock>| -> Vec<u32> { blocks.iter().map(|b| b.index).collect() };
        assert_eq!(seen(ring.blocks().iter().rev().collect()), vec![2, 1, 0]);
        assert_eq!(seen(ring.filtered(BlockNavigatorFilter::All)), vec![2, 1, 0]);
        assert_eq!(seen(ring.filtered(BlockNavigatorFilter::Failed)), vec![1]);
        assert_eq!(seen(ring.filtered(BlockNavigatorFilter::Bookmarked)), vec![0]);
    }

    #[test]
    fn a_bookmark_toggles_back_and_the_cap_evicts_the_oldest_star() {
        let mut ring = BlockRing::new();
        assert!(ring.toggle_bookmark(7).contains(&7));
        assert!(ring.is_bookmarked(7));
        assert!(!ring.toggle_bookmark(7).contains(&7));
        for index in 0..u32::try_from(MAX_BOOKMARKS).unwrap_or(0) + 2 {
            ring.toggle_bookmark(index);
        }
        assert_eq!(ring.bookmarks().len(), MAX_BOOKMARKS);
        assert!(!ring.is_bookmarked(0), "the oldest star went first");
        assert!(!ring.is_bookmarked(1));
        assert!(ring.is_bookmarked(2));
    }

    #[test]
    fn seeding_bookmarks_collapses_duplicates_and_trims_a_corrupt_over_long_set() {
        let mut ring = BlockRing::new();
        ring.set_bookmarks(&[4, 4, 9]);
        assert_eq!(ring.bookmarks().len(), 2);
        let overlong: Vec<u32> = (0..u32::try_from(MAX_BOOKMARKS).unwrap_or(0) + 10).collect();
        ring.set_bookmarks(&overlong);
        assert_eq!(ring.bookmarks().len(), MAX_BOOKMARKS);
        assert!(ring.is_bookmarked(0), "the caller's order decides which survive");
        assert!(!ring.is_bookmarked(u32::try_from(MAX_BOOKMARKS).unwrap_or(0)));
    }

    #[test]
    fn a_reset_empties_the_blocks_the_stamps_and_the_stars() {
        let mut ring = ring(&[block(0, Some(1), true)]);
        ring.toggle_bookmark(0);
        ring.reset();
        assert!(ring.blocks().is_empty());
        assert_eq!(ring.first_seen(0), None);
        assert!(ring.bookmarks().is_empty());
        assert_eq!(ring.blocks().last(), None);
    }

    #[test]
    fn jump_to_failed_walks_every_failure_and_stops_at_both_ends() {
        // Newest-first: 4(ok) 3(fail) 2(ok) 1(fail) 0(ok).
        let ring = ring(&[
            block(0, Some(0), true),
            block(1, Some(1), true),
            block(2, Some(0), true),
            block(3, Some(2), true),
            block(4, Some(0), true),
        ]);
        let newest_first: Vec<&CommandBlock> = ring.blocks().iter().rev().collect();
        let step = |from: Option<u32>, forward: bool| {
            adjacent_failed(&newest_first, from, forward).map(|block| block.index)
        };
        // No cursor, forward → the newest failure.
        assert_eq!(step(None, true), Some(3));
        // On a failure, forward → PAST it, not itself.
        assert_eq!(step(Some(3), true), Some(1));
        assert_eq!(step(Some(1), true), None, "no wrap at the old end");
        // No cursor, backward → the oldest failure.
        assert_eq!(step(None, false), Some(1));
        assert_eq!(step(Some(1), false), Some(3));
        assert_eq!(step(Some(3), false), None, "no wrap at the new end");
    }

    #[test]
    fn an_evicted_cursor_starts_from_the_matching_end_and_an_empty_list_answers_nothing() {
        let ring = ring(&[block(0, Some(1), true), block(1, Some(0), true)]);
        let newest_first: Vec<&CommandBlock> = ring.blocks().iter().rev().collect();
        assert_eq!(
            adjacent_failed(&newest_first, Some(999), true).map(|block| block.index),
            Some(0)
        );
        assert_eq!(
            adjacent_failed(&newest_first, Some(999), false).map(|block| block.index),
            Some(0)
        );
        assert_eq!(adjacent_failed(&[], None, true), None);
        assert_eq!(adjacent_failed(&[], None, false), None);
    }

    #[test]
    fn a_list_with_no_failure_in_it_answers_nothing_either_way() {
        let ring = ring(&[block(0, Some(0), true), block(1, None, true)]);
        let newest_first: Vec<&CommandBlock> = ring.blocks().iter().rev().collect();
        assert_eq!(adjacent_failed(&newest_first, None, true), None);
        assert_eq!(adjacent_failed(&newest_first, None, false), None);
    }

    #[test]
    fn a_second_request_for_the_same_block_rides_the_first_rather_than_re_sending() {
        let mut requests = OutputRequests::new();
        assert_eq!(requests.request(3), OutputRequest::Send(1));
        assert_eq!(requests.request(3), OutputRequest::Coalesced(1));
        assert!(requests.is_pending(3));
        assert_eq!(requests.current_generation(3), Some(1));
        // A different index is its own slot with its own counter.
        assert_eq!(requests.request(4), OutputRequest::Send(1));
    }

    #[test]
    fn a_reply_closes_the_slot_and_a_stray_one_is_dropped() {
        let mut requests = OutputRequests::new();
        requests.request(3);
        assert!(requests.resolve(3));
        assert!(!requests.is_pending(3));
        assert_eq!(requests.current_generation(3), None);
        assert!(!requests.resolve(3), "a late second reply is not an error");
    }

    #[test]
    fn a_stale_timer_cannot_kill_the_request_that_replaced_the_one_it_armed_for() {
        let mut requests = OutputRequests::new();
        let first = requests.request(3).generation();
        assert!(requests.resolve(3));
        let second = requests.request(3).generation();
        assert!(second > first, "a reopened slot gets a strictly newer token");
        assert!(!requests.time_out(3, Some(first)), "the parked timer is stale");
        assert!(requests.is_pending(3), "and the live request survives it");
        assert!(requests.time_out(3, Some(second)));
        assert!(!requests.is_pending(3));
    }

    #[test]
    fn an_ungated_timeout_closes_whatever_is_pending_and_nothing_otherwise() {
        let mut requests = OutputRequests::new();
        requests.request(3);
        assert!(requests.time_out(3, None));
        assert!(!requests.time_out(3, None));
    }

    #[test]
    fn a_reset_strands_nothing_and_still_hands_out_newer_tokens_afterwards() {
        let mut requests = OutputRequests::new();
        let armed = requests.request(3).generation();
        requests.request(5);
        let mut stranded = requests.reset();
        stranded.sort_unstable();
        assert_eq!(stranded, vec![3, 5]);
        assert!(!requests.is_pending(3));
        // The generation survives the reset, so the pre-reset timer is still stale afterwards.
        let reopened = requests.request(3).generation();
        assert!(reopened > armed);
        assert!(!requests.time_out(3, Some(armed)));
        assert!(requests.is_pending(3));
    }

    /// The bytes of a re-run, as a string, for cases where reading UTF-8 is clearer than reading a
    /// byte array. Lossy so a malformed answer shows up as replacement characters in the failure
    /// message rather than as a panic inside the assertion's own autoclosure.
    fn rerun_text(command: &str) -> Option<String> {
        rerun_bytes(command).map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
    }

    #[test]
    fn a_plain_command_gets_exactly_one_trailing_newline_and_nothing_else() {
        assert_eq!(rerun_text("ls -la").as_deref(), Some("ls -la\n"));
    }

    #[test]
    fn a_literal_enter_token_crosses_verbatim_rather_than_becoming_a_control_byte() {
        // The load-bearing difference from a launch preset's user-authored macro text. If this ever
        // routed through the send-keys parser the answer would carry a 0x0D and not the text.
        let answer = rerun_bytes(r#"echo "<Enter>""#);
        assert_eq!(answer.as_deref(), Some(b"echo \"<Enter>\"\n".as_slice()));
        assert!(
            !answer.unwrap_or_default().contains(&0x0D),
            "no carriage return was synthesised from the token"
        );
    }

    #[test]
    fn a_trailing_newline_run_collapses_to_one_so_the_command_cannot_execute_twice() {
        assert_eq!(rerun_text("make\n").as_deref(), Some("make\n"));
        assert_eq!(
            rerun_text("make\r\n").as_deref(),
            Some("make\n"),
            "the CRLF the Swift's `Character` trim used to miss whole"
        );
        assert_eq!(rerun_text("make\n\n").as_deref(), Some("make\n"));
        assert_eq!(rerun_text("make\r\n\r\n").as_deref(), Some("make\n"));
    }

    #[test]
    fn an_empty_or_whitespace_only_command_sends_nothing_at_all() {
        assert_eq!(rerun_bytes(""), None);
        assert_eq!(rerun_bytes("   "), None);
        assert_eq!(rerun_bytes("\n"), None);
        assert_eq!(rerun_bytes(" \t\r\n "), None);
    }

    #[test]
    fn a_zero_width_space_only_command_is_blank_the_way_foundation_reads_it() {
        // The one scalar where `char::is_whitespace` and `.whitespacesAndNewlines` part company.
        // Reading it as printable would inject an invisible line at a prompt.
        assert_eq!(rerun_bytes("\u{200B}"), None);
        assert_eq!(rerun_bytes(" \u{200B}\t"), None);
        assert_eq!(
            rerun_text("a\u{200B}b").as_deref(),
            Some("a\u{200B}b\n"),
            "and one INSIDE a command is still part of the command"
        );
    }

    #[test]
    fn newlines_in_the_middle_are_the_command_and_survive_the_replay() {
        assert_eq!(
            rerun_text("for i in 1 2\ndo echo $i\ndone").as_deref(),
            Some("for i in 1 2\ndo echo $i\ndone\n"),
        );
        assert_eq!(rerun_text("a\nb\n").as_deref(), Some("a\nb\n"));
    }

    #[test]
    fn every_answer_ends_in_a_newline_so_an_empty_one_is_impossible() {
        // This is what lets the door spell "no answer" as a length of zero: a non-`None` answer is
        // never shorter than the single newline it always ends with.
        for command in ["ls", "a\nb", " x ", "\u{200B}x", "make\r\n"] {
            let answer = rerun_bytes(command).unwrap_or_default();
            assert_eq!(answer.last(), Some(&b'\n'), "{command:?} lost its newline");
            assert!(!answer.is_empty(), "{command:?} answered empty");
        }
    }
}
