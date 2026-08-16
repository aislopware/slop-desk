//! Host-side replay buffer for lossless reconnect — an SlopDesk-native port of Eternal Terminal's
//! `BackedWriter` over plain TCP.
//!
//! **Pure logic**: no networking, no clock, no thread. It retains host→client `output` payloads
//! keyed by a monotonic `i64` seq until the client acks them, and produces the un-acked tail for
//! replay on reconnect.
//!
//! ## Why
//! iOS kills the TCP connection seconds after backgrounding. To resume **byte-exact** without tmux,
//! the host retains sent `output` payloads keyed by their monotonic `i64` seq; on reconnect the
//! client's `hello.last_received_seq` tells the host which tail to replay (`seq >
//! last_received_seq`). Equivalent to ET's byte-level `BackedWriter` seq, lifted to a
//! **per-message** seq (see `docs/20-wire-protocol.md`).
//!
//! **Only [`WireMessage::Output`] is sequenced and replayed.** Control messages
//! (resize/ack/title/bell/…) are lifecycle metadata, not retained: re-deriving size or re-sending a
//! title on reconnect is cheap and stateless; PTY output is the irreplaceable byte stream.
//!
//! ## Caps, gates, and the load-bearing invariant
//! - **[`ReplayBuffer::MAX_BACKUP_BYTES`] = 256 MiB** (4× ET `MAX_BACKUP_BYTES` — coding-tool hosts
//!   are ≥32 GB): the retained-byte ceiling we *aim* to stay under.
//! - **[`ReplayBuffer::OFFLINE_GATE_BYTES`] = 64 MiB**: while offline, once retained bytes reach
//!   this gate [`should_pause_drain`](ReplayBuffer::should_pause_drain) flips `true` (ET
//!   `SKIPPED`); below it the host keeps buffering (ET `BUFFERED_ONLY`).
//! - **INVARIANT — never silently drop un-acked data.** Dropping un-acked output to meet the 256
//!   MiB cap would break byte-exact resume (an unrecoverable client gap), so the buffer **never
//!   evicts un-acked entries**. Offline memory is bounded *instead* by
//!   [`should_pause_drain`](ReplayBuffer::should_pause_drain): when asserted, the host relay stops
//!   reading the PTY, so the kernel PTY buffer backpressures the shell and **no droppable output is
//!   produced**.
//! - **INVARIANT — dead-channel send = retain, never throw.** A retained entry is removed only by a
//!   client [`ack`](ReplayBuffer::ack), never by a failed wire send. The host relay retains the
//!   bytes BEFORE sending, so if a live send loses its channel the entry stays retained and is
//!   re-sent by the next [`replay`](ReplayBuffer::replay). A dead-channel send is therefore "client
//!   offline → replay later" with zero byte loss, not a fatal fault.
//! - **Slow-consumer case (online but acking slowly):** if retained bytes exceed the max-backup cap
//!   while online, the drain pauses *anyway* — still no drop; we hold until acks catch up.
//!
//! - Seq is **`i64`** (ET proto2 used int32, which truncates on very long sessions).
//! - **No crypto.** `WireGuard` already encrypts; the buffer stores raw bytes. Do not reintroduce
//!   ET's `libsodium` secretbox / nonce-reset layer here (docs/18 §H).
//!
//! The type is a plain value: the owning host relay holds it as stored state and mutates it under
//! its own lock, and the derived pause signal drives the PTY read-loop. Being pure state is what
//! makes its invariants exhaustively testable without a socket.

use std::sync::Arc;

use crate::message::WireMessage;
use crate::mux::MuxFlowControl;

/// A COLD-reattach scrollback cleaner.
///
/// The host injects an OSC-133 distiller that collapses the transient B→C line-editor churn
/// (completion menus, autosuggestions, per-keystroke redraws) to the committed command line.
pub type ScrollbackDistiller = Arc<dyn Fn(&[u8]) -> Vec<u8> + Send + Sync>;

/// Action signalled to the PTY relay as output is enqueued.
///
/// Mirrors ET's `BackedWriter` `BufferState`: [`BufferedOnly`](DrainState::BufferedOnly) = keep
/// draining/buffering; [`Skipped`](DrainState::Skipped) = stop draining (offline gate crossed) so
/// the kernel backpressures the shell instead of buffering unboundedly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum DrainState {
    /// Keep buffering and draining the PTY normally (below the gate, or online).
    #[default]
    BufferedOnly,
    /// Gate exceeded — pause draining the PTY until the client catches up / returns.
    Skipped,
}

/// One retained un-acked host→client output payload and its assigned seq.
#[derive(Debug, Clone)]
struct TailEntry {
    seq: i64,
    bytes: Vec<u8>,
    /// Running byte total over the tail STRICTLY BEFORE this entry, measured against
    /// [`ReplayBuffer::tail_cumulative_bytes`]. It is what makes
    /// [`ReplayBuffer::retained_bytes_above`] a binary search plus one subtraction instead of a
    /// walk that materialises payloads.
    cumulative_before: usize,
}

/// One acked entry kept for cold-reattach replay.
///
/// It carries NO cumulative label: the ring is acked history and never contributes to a
/// retained-bytes answer, so the split from [`TailEntry`] makes that structural rather than a
/// convention a future edit could break.
#[derive(Debug, Clone)]
struct RingEntry {
    seq: i64,
    bytes: Vec<u8>,
}

/// The raw material for a RENDERED-snapshot replay (docs/DECISIONS.md 2026-07-25 state-transfer).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SnapshotSource {
    /// Ring + un-acked tail concatenated, oldest-first — the screen-model composer's input. The
    /// COMPLETE retained history, even the portion a warm client already acked, because the
    /// composer needs every byte to reconstruct state.
    pub history: Vec<u8>,
    /// Seqs available to carry the rendered stream (strictly above `last_received_seq`).
    pub replay_seqs: Vec<i64>,
    /// Total bytes behind `replay_seqs` — the caller's "how much would a raw replay cost" input.
    pub replay_bytes: usize,
}

/// The frozen material for a detach-time ring fold.
///
/// It carries the acked ring's raw bytes, the seqs its canonical replacement may ride (the ORIGINAL
/// ring seqs — labels stay within the acked range so the seq order invariant holds), and the
/// generation guarding the splice.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RingFoldSource {
    /// The ring's bytes, oldest-first.
    pub bytes: Vec<u8>,
    /// The ring's seqs, oldest-first.
    pub seqs: Vec<i64>,
    /// The [`ReplayBuffer::ring_generation`] at capture time.
    pub generation: u64,
}

/// The retained output history of one pane: an un-acked live tail plus an acked scrollback ring.
#[derive(Clone)]
pub struct ReplayBuffer {
    /// Un-acked retained entries, ascending by seq (FIFO; oldest at the front).
    entries: Vec<TailEntry>,
    /// Scrollback ring: acked entries kept for cold-reattach replay, oldest-at-front.
    ///
    /// Bounded by `scrollback_bytes_cap`. Eviction is LINE-ALIGNED: when the oldest surviving entry
    /// would split a line, the cursor advances to the next `\n` so a cold replay never starts
    /// mid-escape-sequence. Separate from `entries` so the never-drop invariant on un-acked data is
    /// untouched.
    scrollback_ring: Vec<RingEntry>,
    /// Running byte total in `scrollback_ring`.
    scrollback_bytes: usize,
    /// Alt-screen re-opener carried across a ring-emptying eviction: when eviction drops the LAST
    /// ring entry while the cut is inside an open alt-screen segment, there is no head to repair
    /// yet — the opener attaches to the next acked bytes that enter the ring. Set only while
    /// the ring is empty (a non-empty ring is repaired in place, keeping the invariant that
    /// ring content is always a well-formed stream w.r.t. alt-screen segments).
    pending_alt_reopen: Option<Vec<u8>>,
    highest_seq: i64,
    acked_seq: i64,
    retained_bytes: usize,
    /// Monotonic byte total behind [`TailEntry::cumulative_before`]: the sum of every payload that
    /// has entered `entries`, never decremented by an ack. The subtrahend in
    /// [`retained_bytes_above`](Self::retained_bytes_above).
    tail_cumulative_bytes: usize,
    is_client_online: bool,
    max_backup_bytes_cap: usize,
    offline_gate_bytes_cap: usize,
    scrollback_bytes_cap: usize,
    ring_generation: u64,
    scrollback_distiller: Option<ScrollbackDistiller>,
}

/// The production caps, ring enabled, no distiller.
impl Default for ReplayBuffer {
    fn default() -> Self {
        Self::new()
    }
}

/// Sizes, not contents: a pane's retained history reaches 256 MiB of raw VT bytes, and a `Debug`
/// that printed it would be unreadable in a log and expensive to format.
#[expect(
    clippy::missing_fields_in_debug,
    reason = "the payload fields are deliberately summarised by length"
)]
impl core::fmt::Debug for ReplayBuffer {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("ReplayBuffer")
            .field("highest_seq", &self.highest_seq)
            .field("acked_seq", &self.acked_seq)
            .field("retained_bytes", &self.retained_bytes)
            .field("entries", &self.entries.len())
            .field("scrollback_entries", &self.scrollback_ring.len())
            .field("scrollback_bytes", &self.scrollback_bytes)
            .field("is_client_online", &self.is_client_online)
            .field("ring_generation", &self.ring_generation)
            .field("distilling", &self.scrollback_distiller.is_some())
            .finish()
    }
}

impl ReplayBuffer {
    /// Retained-byte ceiling: 256 MiB (4× ET `MAX_BACKUP_BYTES`).
    pub const MAX_BACKUP_BYTES: usize = 256 * 1024 * 1024;

    /// Offline buffering gate: 64 MiB. At/above this while offline, pause the PTY drain.
    pub const OFFLINE_GATE_BYTES: usize = 64 * 1024 * 1024;

    /// Default scrollback ring size: 64 MiB (override with `SLOPDESK_SCROLLBACK_BYTES`).
    ///
    /// Retains ACKED entries (history) separately from the un-acked live tail, so a cold-reattach
    /// replay can deliver the full visible scrollback to a fresh terminal — like
    /// `tmux attach-session`. Bounded, evicted line-aligned so a replay never starts
    /// mid-escape-sequence. Disable entirely with `SLOPDESK_SCROLLBACK_PERSIST=0`.
    pub const DEFAULT_SCROLLBACK_BYTES: usize = 64 * 1024 * 1024;

    /// The floor the re-chunker uses before clamping to the frame payload cap.
    const RECHUNK_FLOOR_BYTES: usize = 32 * 1024;

    /// A buffer at the production caps, with the scrollback ring enabled and no distiller.
    #[must_use]
    pub const fn new() -> Self {
        Self::with_caps(
            Self::MAX_BACKUP_BYTES,
            Self::OFFLINE_GATE_BYTES,
            Self::DEFAULT_SCROLLBACK_BYTES,
        )
    }

    /// A buffer at explicit caps — injectable so the read-loop-pause wiring can be
    /// integration-tested at a tiny cap (no 256 MiB allocation) and a deployment can tune them.
    ///
    /// The scrollback cap is independent of the backup cap: the ring holds ACKED history only, so
    /// it never contributes to [`retained_bytes`](Self::retained_bytes) or to the offline-gate
    /// / 256 MiB live-tail guarantees. `0` disables the ring.
    #[must_use]
    pub const fn with_caps(
        max_backup_bytes: usize,
        offline_gate_bytes: usize,
        scrollback_bytes: usize,
    ) -> Self {
        Self {
            entries: Vec::new(),
            scrollback_ring: Vec::new(),
            scrollback_bytes: 0,
            pending_alt_reopen: None,
            highest_seq: 0,
            acked_seq: 0,
            retained_bytes: 0,
            tail_cumulative_bytes: 0,
            is_client_online: true,
            max_backup_bytes_cap: max_backup_bytes,
            offline_gate_bytes_cap: offline_gate_bytes,
            scrollback_bytes_cap: scrollback_bytes,
            ring_generation: 0,
            scrollback_distiller: None,
        }
    }

    /// A buffer at the production backup caps with an explicit scrollback cap (`0` disables it).
    #[must_use]
    pub const fn with_scrollback(scrollback_bytes: usize) -> Self {
        Self::with_caps(Self::MAX_BACKUP_BYTES, Self::OFFLINE_GATE_BYTES, scrollback_bytes)
    }

    /// Attaches a cold-reattach scrollback cleaner.
    ///
    /// [`replay`](Self::replay) then runs it over the history portion of a cold replay. Without
    /// one, the ring replays raw. The un-acked live tail is transformed ONLY for a FRESH client
    /// (`last_received_seq == 0` — nothing rendered yet, so no byte-exact continuity to protect); a
    /// warm reconnect always gets the raw tail. [`messages`](Self::messages), the raw primitive for
    /// control-channel snapshots, is never touched.
    #[must_use]
    pub fn distilling(mut self, distiller: ScrollbackDistiller) -> Self {
        self.scrollback_distiller = Some(distiller);
        self
    }

    // MARK: Observation

    /// Highest seq assigned so far (the last produced `output.seq`). Starts at 0; the first output
    /// is seq 1.
    #[must_use]
    pub const fn highest_seq(&self) -> i64 {
        self.highest_seq
    }

    /// Highest contiguous seq the client has acked; entries up to here are released.
    #[must_use]
    pub const fn acked_seq(&self) -> i64 {
        self.acked_seq
    }

    /// Sum of payload lengths over all currently-retained (un-acked) entries.
    ///
    /// Maintained incrementally on every [`append`](Self::append) / [`ack`](Self::ack) — O(1) to
    /// read, always equal to the true retained total.
    #[must_use]
    pub const fn retained_bytes(&self) -> usize {
        self.retained_bytes
    }

    /// Whether the connection layer currently considers the client reachable.
    #[must_use]
    pub const fn is_client_online(&self) -> bool {
        self.is_client_online
    }

    /// Set by the transport when a channel becomes ready (`true`) or fails/cancels (`false`).
    /// Drives the offline gate via [`should_pause_drain`](Self::should_pause_drain).
    pub const fn set_client_online(&mut self, online: bool) {
        self.is_client_online = online;
    }

    /// This buffer's retained-byte ceiling.
    #[must_use]
    pub const fn max_backup_bytes_cap(&self) -> usize {
        self.max_backup_bytes_cap
    }

    /// This buffer's offline buffering gate.
    #[must_use]
    pub const fn offline_gate_bytes_cap(&self) -> usize {
        self.offline_gate_bytes_cap
    }

    /// This buffer's scrollback ring cap (`0` = ring disabled).
    #[must_use]
    pub const fn scrollback_bytes_cap(&self) -> usize {
        self.scrollback_bytes_cap
    }

    /// Monotonic mutation counter over the RING (acked history).
    ///
    /// A fold computed OUTSIDE the session's replay lock (the render is too expensive to hold it)
    /// only splices back in if the ring it rendered is still exactly the ring in the buffer — a
    /// stale fold is dropped, never merged. The un-acked tail is deliberately NOT covered: a
    /// fold never touches it.
    #[must_use]
    pub const fn ring_generation(&self) -> u64 {
        self.ring_generation
    }

    /// Number of entries currently in the scrollback ring.
    #[must_use]
    pub const fn scrollback_ring_len(&self) -> usize {
        self.scrollback_ring.len()
    }

    /// Total bytes currently in the scrollback ring.
    #[must_use]
    pub const fn scrollback_ring_bytes(&self) -> usize {
        self.scrollback_bytes
    }

    /// The seq values in the scrollback ring, oldest-first.
    #[must_use]
    pub fn scrollback_ring_seqs(&self) -> Vec<i64> {
        self.scrollback_ring.iter().map(|entry| entry.seq).collect()
    }

    /// The bytes of the oldest scrollback ring entry — what a cold replay starts with.
    #[must_use]
    pub fn scrollback_ring_oldest(&self) -> Option<&[u8]> {
        self.scrollback_ring.first().map(|entry| entry.bytes.as_slice())
    }

    // MARK: Derived signals

    /// Whether the PTY relay should **pause draining** right now.
    ///
    /// `true` when either the client is **offline** and retained bytes reached the offline gate
    /// (the ET `SKIPPED` state), or retained bytes reached the max-backup cap regardless of
    /// online state (the slow-consumer guard — still never drop un-acked data, hold the pause
    /// until acks drain).
    ///
    /// While `true` the host stops reading the PTY master, so the kernel PTY buffer fills and
    /// backpressures the child — no droppable output is generated. This is what bounds memory while
    /// honouring the never-drop invariant.
    #[must_use]
    pub const fn should_pause_drain(&self) -> bool {
        if self.retained_bytes >= self.max_backup_bytes_cap {
            return true;
        }
        !self.is_client_online && self.retained_bytes >= self.offline_gate_bytes_cap
    }

    /// The [`DrainState`] corresponding to [`should_pause_drain`](Self::should_pause_drain) (the ET
    /// vocabulary).
    #[must_use]
    pub const fn drain_state(&self) -> DrainState {
        if self.should_pause_drain() {
            DrainState::Skipped
        } else {
            DrainState::BufferedOnly
        }
    }

    // MARK: Producing

    /// Appends a host→client output payload, assigning it the next monotonic seq (`highest_seq +
    /// 1`, starting at 1), and retains it until acked. Returns the assigned seq.
    pub fn append(&mut self, bytes: Vec<u8>) -> i64 {
        self.highest_seq += 1;
        let length = bytes.len();
        self.entries.push(TailEntry {
            seq: self.highest_seq,
            bytes,
            cumulative_before: self.tail_cumulative_bytes,
        });
        self.tail_cumulative_bytes += length;
        self.retained_bytes += length;
        self.highest_seq
    }

    /// [`append`](Self::append) plus the resulting [`DrainState`] — the form the host relay uses to
    /// act on backpressure in the same call.
    pub fn enqueue_output(&mut self, bytes: Vec<u8>) -> (i64, DrainState) {
        let seq = self.append(bytes);
        (seq, self.drain_state())
    }

    /// Retained (un-acked) bytes with `seq > seq` — how far behind the head a subscriber that has
    /// confirmed up to `seq` actually is.
    ///
    /// O(log n) and COPY-FREE: `entries` is ascending by seq, so one partition point finds the
    /// first entry above the cursor and the answer is a subtraction of two running totals. The
    /// "bytes above S" primitives ([`messages`](Self::messages) /
    /// [`snapshot_source`](Self::snapshot_source)) materialise every payload — up to the 256
    /// MiB ceiling — which is not something a per-ack lag check can afford under the owner's
    /// replay lock.
    ///
    /// A cursor at or past the head answers 0, and a cursor BELOW the retained window answers the
    /// whole retained tail (the acked prefix is gone; it is not lag any more).
    #[must_use]
    pub fn retained_bytes_above(&self, seq: i64) -> usize {
        let first_above = self.entries.partition_point(|entry| entry.seq <= seq);
        self.entries
            .get(first_above)
            .map_or(0, |entry| self.tail_cumulative_bytes - entry.cumulative_before)
    }

    // MARK: Releasing

    /// Records a client ack, dropping retained entries with `seq <= up_to` and updating
    /// [`retained_bytes`](Self::retained_bytes).
    ///
    /// Idempotent and monotonic: a stale/duplicate ack is a no-op; the acked seq only advances.
    /// Acking past [`highest_seq`](Self::highest_seq) clears everything but CLAMPS the acked seq to
    /// it: the ack arrives unvalidated off the wire ([`WireMessage::Ack`]), and an unclamped
    /// far-future value (e.g. `i64::MAX` from a buggy or corrupt peer) would make every later
    /// legitimate ack fall into the no-op branch, so nothing is ever released again — appends
    /// accumulate to the max-backup cap and the drain wedges permanently.
    ///
    /// When the ring is enabled the acked prefix is MOVED into it (for cold-reattach replay) rather
    /// than discarded, and the ring is trimmed to its cap line-aligned. The un-acked side updates
    /// as in the pre-scrollback behaviour — the never-drop invariant is preserved.
    pub fn ack(&mut self, up_to: i64) {
        // Clamp untrusted wire input: an ack can never legitimately exceed what we produced.
        let clamped = up_to.min(self.highest_seq);
        if clamped <= self.acked_seq {
            return;
        }
        self.acked_seq = clamped;
        let drop_count = self.entries.partition_point(|entry| entry.seq <= clamped);
        if drop_count == 0 {
            return;
        }
        // The acked prefix is about to move into the ring (or be discarded) — any in-flight
        // detach-time fold rendered a ring that no longer matches.
        self.ring_generation += 1;
        // Bulk drain, not a per-entry remove-first loop: the latter is O(k*n) memmoves under the
        // shared replay lock.
        let released: Vec<TailEntry> = self.entries.drain(..drop_count).collect();
        let released_bytes: usize = released.iter().map(|entry| entry.bytes.len()).sum();
        if self.scrollback_bytes_cap > 0 {
            let ring_was_empty = self.scrollback_ring.is_empty();
            for entry in released {
                self.scrollback_bytes += entry.bytes.len();
                self.scrollback_ring.push(RingEntry {
                    seq: entry.seq,
                    bytes: entry.bytes,
                });
            }
            // A prior eviction emptied the ring mid-alt-segment: these are the first surviving bytes,
            // so the re-opener lands here — BEFORE the eviction below, whose cut scan must see the
            // opener to keep tracking the still-open segment.
            if ring_was_empty {
                self.attach_pending_reopen();
            }
            self.evict_scrollback_to_fit();
        }
        self.retained_bytes -= released_bytes;
    }

    /// Moves a carried re-opener onto the ring head, if there is now a head to carry it. With an
    /// empty ring the opener stays pending — it attaches to the next bytes that enter.
    fn attach_pending_reopen(&mut self) {
        if self.scrollback_ring.is_empty() {
            return;
        }
        let Some(reopen) = self.pending_alt_reopen.take() else {
            return;
        };
        let added = reopen.len();
        if let Some(head) = self.scrollback_ring.first_mut() {
            let mut repaired = reopen;
            repaired.extend_from_slice(&head.bytes);
            head.bytes = repaired;
        }
        self.scrollback_bytes += added;
    }

    /// Evicts the OLDEST scrollback entries until the ring fits its cap.
    ///
    /// LINE-ALIGNED: after an eviction lands at/under the cap, the new oldest entry may start
    /// mid-line (the evicted chunk was the tail of a `\n`-terminated sequence). Its front is
    /// trimmed to the next `\n` + 1 so a cold replay starts on a clean line boundary, never
    /// mid-escape-sequence. If the new oldest has no `\n` it is left intact (the next cycle removes
    /// it if still over cap; a line longer than the cap cannot be split usefully, and the following
    /// entry already starts clean).
    ///
    /// Then the alt-screen cut is repaired: a cut inside an open alt segment beheads it, and a cold
    /// replay would pour the surviving interior onto the MAIN screen (the unpaired `?1049l` reads
    /// as a defensive reset downstream). Re-opening the segment at the surviving head lets
    /// replay-side segmentation pair it like any other, and keeps the ring a well-formed stream
    /// — so the NEXT eviction's scan needs no carried state, it reads the opener like any byte.
    fn evict_scrollback_to_fit(&mut self) {
        if self.scrollback_bytes <= self.scrollback_bytes_cap || self.scrollback_ring.is_empty() {
            return;
        }
        // Count the eviction prefix WITHOUT mutating, then remove it in ONE bulk drain.
        let mut drop_count = 0;
        let mut dropped_bytes = 0;
        while self.scrollback_bytes - dropped_bytes > self.scrollback_bytes_cap
            && drop_count < self.scrollback_ring.len()
        {
            dropped_bytes += self
                .scrollback_ring
                .get(drop_count)
                .map_or(0, |entry| entry.bytes.len());
            drop_count += 1;
        }
        // Collect the dropped prefix for the alt-screen cut scan (cost bounded by the bytes leaving
        // the ring, so amortised O(stream) across the session).
        let mut dropped = Vec::with_capacity(dropped_bytes);
        for entry in self.scrollback_ring.drain(..drop_count) {
            dropped.extend_from_slice(&entry.bytes);
        }
        self.scrollback_bytes -= dropped_bytes;
        // Landed at/under cap: line-align the new oldest so the ring never starts mid-escape-sequence.
        if self.scrollback_bytes <= self.scrollback_bytes_cap
            && let Some(head) = self.scrollback_ring.first_mut()
            && let Some(newline) = head.bytes.iter().position(|&byte| byte == b'\n')
        {
            let removed = newline + 1;
            // The trimmed bytes are dropped too, so the cut scan must see them.
            dropped.extend(head.bytes.iter().take(removed));
            head.bytes.drain(..removed);
            self.scrollback_bytes -= removed;
        }
        let kept_head: &[u8] = self.scrollback_ring.first().map_or(&[], |entry| &entry.bytes);
        let Some(reopen) = slopdesk_altscreen::reopen_sequence(&dropped, kept_head) else {
            return;
        };
        // An empty ring has no head to repair yet, so the opener stays pending and attaches to the
        // next bytes that enter.
        self.pending_alt_reopen = Some(reopen);
        self.attach_pending_reopen();
    }

    // MARK: Reading back

    /// Retained output payloads with `seq > last_received_seq`, ascending, for replay after
    /// reconnect.
    ///
    /// **Cold reattach** (`0`, or below the oldest scrollback entry): all ring entries above the
    /// cursor, then the whole un-acked tail. The fresh client re-renders the full scrollback, like
    /// `tmux attach-session`.
    ///
    /// **Warm reconnect** (at/near the live frontier): ring entries all sit at or below the acked
    /// seq, so the filter drops them all; only the un-acked tail returns.
    ///
    /// **Ring-wrapped edge** (ring wrapped past the reconnect point): whatever ring entries survive
    /// are selected; the client's own dedup drops anything it already holds, so no duplicate is
    /// possible.
    ///
    /// Un-acked entries are never absent (the never-drop invariant).
    #[must_use]
    pub fn messages(&self, last_received_seq: i64) -> Vec<(i64, &[u8])> {
        self.scrollback_ring
            .iter()
            .filter(|entry| entry.seq > last_received_seq)
            .map(|entry| (entry.seq, entry.bytes.as_slice()))
            .chain(
                self.entries
                    .iter()
                    .filter(|entry| entry.seq > last_received_seq)
                    .map(|entry| (entry.seq, entry.bytes.as_slice())),
            )
            .collect()
    }

    /// The raw material for a RENDERED-snapshot replay: the COMPLETE retained history plus the seq
    /// budget the rendered stream may ride.
    #[must_use]
    pub fn snapshot_source(&self, last_received_seq: i64) -> SnapshotSource {
        let mut source = SnapshotSource::default();
        let ring = self.scrollback_ring.iter().map(|entry| (entry.seq, &entry.bytes));
        let tail = self.entries.iter().map(|entry| (entry.seq, &entry.bytes));
        for (seq, bytes) in ring.chain(tail) {
            source.history.extend_from_slice(bytes);
            if seq > last_received_seq {
                source.replay_seqs.push(seq);
                source.replay_bytes += bytes.len();
            }
        }
        source
    }

    /// Returns retained `output` messages with `seq > last_received_seq`, in order, wrapped as
    /// [`WireMessage::Output`] ready to re-send — the reconnect/reattach replay.
    ///
    /// When a distiller is attached AND the replay reaches the scrollback ring (a COLD reattach —
    /// the cursor is below the acked frontier), the scrollback portion is DISTILLED and RE-CHUNKED
    /// across the same seq range (distilled bytes ≤ raw, so the chunk count never exceeds the entry
    /// count → seqs stay ascending and strictly below the un-acked tail).
    ///
    /// **FRESH client (`0`)**: the un-acked live tail is history to a client that has rendered
    /// nothing — there is no byte-exact continuity to protect, and a session that ran detached for
    /// hours retains up to the offline gate of raw live-TUI churn that would replay for seconds and
    /// then render wrong at the new geometry. Ring + tail are therefore transformed as ONE
    /// chronological stream and re-chunked across the combined seq range; the LAST emitted chunk
    /// always carries the highest tail seq, so the client's ack releases every retained entry (the
    /// transform can shrink the byte count below the seq count — an unsent top seq would otherwise
    /// strand un-acked bytes against the pause gate forever).
    ///
    /// **Warm reconnect**: the un-acked tail is ALWAYS re-sent RAW — the client's grid is live
    /// mid-stream and transformed bytes would corrupt it. Without a distiller this is
    /// byte-identical to [`messages`](Self::messages) mapped to `Output`.
    #[must_use]
    pub fn replay(&self, last_received_seq: i64) -> Vec<WireMessage> {
        let scrollback: Vec<&RingEntry> = self
            .scrollback_ring
            .iter()
            .filter(|entry| entry.seq > last_received_seq)
            .collect();

        if let Some(distiller) = self.scrollback_distiller.as_ref()
            && last_received_seq == 0
            && !self.entries.is_empty()
        {
            // COLD replay to a fresh client — transform ring + tail as one stream.
            let mut raw = Vec::new();
            for entry in &scrollback {
                raw.extend_from_slice(&entry.bytes);
            }
            for entry in &self.entries {
                raw.extend_from_slice(&entry.bytes);
            }
            let seqs: Vec<i64> = scrollback
                .iter()
                .map(|entry| entry.seq)
                .chain(self.entries.iter().map(|entry| entry.seq))
                .collect();
            return Self::rechunk(&distiller(&raw), &seqs, true);
        }

        let mut result = Vec::new();
        match self
            .scrollback_distiller
            .as_ref()
            .filter(|_| !scrollback.is_empty())
        {
            Some(distiller) => {
                let mut raw = Vec::new();
                for entry in &scrollback {
                    raw.extend_from_slice(&entry.bytes);
                }
                let seqs: Vec<i64> = scrollback.iter().map(|entry| entry.seq).collect();
                result.extend(Self::rechunk(&distiller(&raw), &seqs, false));
            },
            None => {
                for entry in &scrollback {
                    result.push(WireMessage::Output {
                        seq: entry.seq,
                        bytes: entry.bytes.clone(),
                    });
                }
            },
        }
        // Un-acked live tail — raw (byte-exact resume of in-flight output on a warm grid).
        for entry in self.entries.iter().filter(|entry| entry.seq > last_received_seq) {
            result.push(WireMessage::Output {
                seq: entry.seq,
                bytes: entry.bytes.clone(),
            });
        }
        result
    }

    // MARK: History canonicalisation (docs/DECISIONS.md 2026-07-25 state-transfer, follow-up)

    /// Re-chunks a RENDERED snapshot stream across `seqs` (ascending, from
    /// [`snapshot_source`](Self::snapshot_source)) — always covering the last seq so the ack it
    /// provokes releases every retained entry, exactly like the cold distilled replay.
    #[must_use]
    pub fn rechunk_snapshot(data: &[u8], seqs: &[i64]) -> Vec<WireMessage> {
        Self::rechunk(data, seqs, true)
    }

    /// Captures the ring for a detach-time fold, or `None` when the ring is empty.
    #[must_use]
    pub fn ring_fold_source(&self) -> Option<RingFoldSource> {
        if self.scrollback_ring.is_empty() {
            return None;
        }
        let mut bytes = Vec::with_capacity(self.scrollback_bytes);
        for entry in &self.scrollback_ring {
            bytes.extend_from_slice(&entry.bytes);
        }
        Some(RingFoldSource {
            bytes,
            seqs: self.scrollback_ring.iter().map(|entry| entry.seq).collect(),
            generation: self.ring_generation,
        })
    }

    /// Replaces the acked ring with `rendered` (the canonical state-transfer render of the ring
    /// bytes) re-chunked across the original ring seqs — the detach-time fold that turns the NEXT
    /// cold compose from O(raw history) into O(rendered + delta), and collapses the ring's memory
    /// to the rendered size. Round-trip feed-equivalence (the renderer's pinned differential)
    /// is what makes the un-acked tail parse identically on top of the fold.
    ///
    /// Returns `false` without touching anything when the buffer has mutated since `source` was
    /// captured (a reattach adopted a snapshot, new acks moved entries in, eviction ran).
    pub fn adopt_folded_ring(&mut self, rendered: &[u8], source: &RingFoldSource) -> bool {
        if source.generation != self.ring_generation {
            return false;
        }
        self.ring_generation += 1;
        self.scrollback_ring = Self::rechunk(rendered, &source.seqs, true)
            .into_iter()
            .filter_map(|message| {
                match message {
                    WireMessage::Output { seq, bytes } => Some(RingEntry { seq, bytes }),
                    _ => None,
                }
            })
            .collect();
        self.scrollback_bytes = rendered.len();
        // The canonical stream is self-contained (it opens with the full preamble wipe) — any carried
        // alt-segment repair belongs to the raw bytes it just replaced.
        self.pending_alt_reopen = None;
        true
    }

    /// Replaces the ENTIRE retained history (ring + un-acked tail) with the rendered snapshot
    /// stream EXACTLY as it was sent — "as if the host had emitted the rendered bytes all
    /// along". Chunks at/below the acked seq become the ring; the rest become the un-acked
    /// tail, released by the client's acks exactly like the raw entries they replaced (a warm
    /// re-reconnect mid-delivery resumes the rendered stream byte-exact).
    ///
    /// Called right after a successful snapshot compose. Two loads it carries:
    /// - the consumed detached-window backlog got NO seqs of its own, so without this it would
    ///   exist only in the delivered bytes and VANISH from every later cold replay;
    /// - the next compose parses the (small) rendered history instead of re-walking the full raw
    ///   ring.
    pub fn adopt_snapshot_replay(&mut self, messages: &[WireMessage]) {
        self.ring_generation += 1;
        let mut ring = Vec::new();
        let mut tail = Vec::new();
        let mut ring_bytes = 0;
        let mut tail_bytes = 0;
        for message in messages {
            let WireMessage::Output { seq, bytes } = message else {
                continue;
            };
            if *seq <= self.acked_seq {
                // With the ring disabled the acked prefix is discarded, exactly as `ack` would.
                if self.scrollback_bytes_cap > 0 {
                    ring_bytes += bytes.len();
                    ring.push(RingEntry {
                        seq: *seq,
                        bytes: bytes.clone(),
                    });
                }
            } else {
                // The adopted stream REPLACES the tail, so its cumulative labels are re-derived from
                // the running total's current value — the invariant `retained_bytes_above` reads is
                // "labels ascend to `tail_cumulative_bytes`", and rebasing here keeps that true
                // across a wholesale replacement.
                tail.push(TailEntry {
                    seq: *seq,
                    bytes: bytes.clone(),
                    cumulative_before: self.tail_cumulative_bytes + tail_bytes,
                });
                tail_bytes += bytes.len();
            }
        }
        self.scrollback_ring = ring;
        self.scrollback_bytes = ring_bytes;
        self.entries = tail;
        self.tail_cumulative_bytes += tail_bytes;
        self.retained_bytes = tail_bytes;
        self.pending_alt_reopen = None;
        self.evict_scrollback_to_fit();
    }

    /// Splits `data` (distilled scrollback) into at most `seqs.len()` `Output` messages, assigning
    /// the scrollback seqs ascending.
    ///
    /// `data.len() <= sum(original entry sizes)`, so at chunk size `ceil(len / max_chunks)` the
    /// chunk count is `<= max_chunks`; the LAST allowed chunk absorbs the remainder so every
    /// byte is emitted and no seq is reused. Empty `data` ⇒ no messages (the client's
    /// forward-jump tolerance handles the seq gap).
    ///
    /// `must_cover_last_seq` (the cold fresh-client replay, where `seqs` includes UN-ACKED tail
    /// seqs): the final emitted message is relabelled to the last seq — ascending order holds
    /// (every earlier chunk uses a strictly lower seq from the same list) and the client
    /// accepts the forward jump — so the ack that follows releases the entire retained tail.
    /// With empty `data` an empty `Output` still carries the last seq for the same reason.
    ///
    /// The chunk size is CLAMPED to [`MuxFlowControl::max_output_frame_payload_bytes`]: every
    /// emitted frame must satisfy the credit progress invariant (wire bytes ≤ window/2),
    /// exactly like the live drain's merged-frame cap. Without the clamp, the 32 KiB floor
    /// alone can emit 32768-byte payloads — 32781 wire bytes, 13 over window/2: the "dead zone"
    /// that can park the sender against a receiver whose pending credit never crosses the grant
    /// threshold (a silent pane right after cold reattach). The clamp is safe on the seq
    /// budget: every ring entry was appended at ≤ the same cap, so `ceil(len / max_chunks)` ≤
    /// cap and the chunk count stays ≤ `max_chunks` even at the clamped size; the last-chunk
    /// absorb then never exceeds the cap either.
    fn rechunk(data: &[u8], seqs: &[i64], must_cover_last_seq: bool) -> Vec<WireMessage> {
        let Some(&last_seq) = seqs.last() else {
            return Vec::new();
        };
        if data.is_empty() {
            // No bytes, but a cold-tail replay must still deliver the top seq — un-acked entries
            // release only on the ack this message provokes.
            return if must_cover_last_seq {
                vec![WireMessage::Output {
                    seq: last_seq,
                    bytes: Vec::new(),
                }]
            } else {
                Vec::new()
            };
        }
        let max_chunks = seqs.len();
        let payload_cap =
            usize::try_from(MuxFlowControl::max_output_frame_payload_bytes()).unwrap_or(usize::MAX);
        let chunk_size = payload_cap
            .min(Self::RECHUNK_FLOOR_BYTES.max(data.len().div_ceil(max_chunks)))
            .max(1);
        let mut result = Vec::new();
        let mut start = 0;
        let mut index = 0;
        while start < data.len() && index < max_chunks {
            let end = if index + 1 == max_chunks {
                data.len()
            } else {
                start.saturating_add(chunk_size).min(data.len())
            };
            let Some(&seq) = seqs.get(index) else { break };
            result.push(WireMessage::Output {
                seq,
                bytes: data.get(start..end).unwrap_or_default().to_vec(),
            });
            start = end;
            index += 1;
        }
        if must_cover_last_seq && let Some(WireMessage::Output { seq, .. }) = result.last_mut() {
            *seq = last_seq;
        }
        result
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::expect_used,
        reason = "a panic in a test is the failure report, not a runtime fault"
    )]

    use std::sync::Arc;

    use super::{DrainState, ReplayBuffer, ScrollbackDistiller};
    use crate::message::WireMessage;
    use crate::mux::MuxFlowControl;

    fn bytes(text: &str) -> Vec<u8> {
        text.as_bytes().to_vec()
    }

    fn chunk(size: usize, byte: u8) -> Vec<u8> {
        vec![byte; size]
    }

    fn seqs(messages: &[WireMessage]) -> Vec<i64> {
        messages
            .iter()
            .filter_map(|message| {
                match message {
                    WireMessage::Output { seq, .. } => Some(*seq),
                    _ => None,
                }
            })
            .collect()
    }

    fn joined(messages: &[WireMessage]) -> Vec<u8> {
        let mut out = Vec::new();
        for message in messages {
            if let WireMessage::Output { bytes, .. } = message {
                out.extend_from_slice(bytes);
            }
        }
        out
    }

    fn output(seq: i64, text: &str) -> WireMessage {
        WireMessage::Output {
            seq,
            bytes: bytes(text),
        }
    }

    /// A synthetic distiller that drops every `-` byte — stands in for the OSC-133 churn collapse
    /// so the buffer's wiring is tested independently of the host distiller's algorithm.
    fn drop_dashes() -> ScrollbackDistiller {
        Arc::new(|raw: &[u8]| raw.iter().copied().filter(|byte| *byte != b'-').collect())
    }

    fn identity() -> ScrollbackDistiller {
        Arc::new(|raw: &[u8]| raw.to_vec())
    }

    // MARK: Constants / contract

    #[test]
    fn the_caps_are_the_contract_values() {
        assert_eq!(ReplayBuffer::MAX_BACKUP_BYTES, 256 * 1024 * 1024);
        assert_eq!(ReplayBuffer::OFFLINE_GATE_BYTES, 64 * 1024 * 1024);
        assert_eq!(ReplayBuffer::DEFAULT_SCROLLBACK_BYTES, 64 * 1024 * 1024);
    }

    // MARK: Monotonic seq

    #[test]
    fn the_seq_starts_at_one_and_is_monotonic() {
        let mut buffer = ReplayBuffer::new();
        assert_eq!(buffer.highest_seq(), 0);
        assert_eq!(buffer.append(bytes("a")), 1);
        assert_eq!(buffer.append(bytes("b")), 2);
        assert_eq!(buffer.append(bytes("c")), 3);
        assert_eq!(buffer.highest_seq(), 3);
    }

    #[test]
    fn enqueue_output_agrees_with_append() {
        let mut buffer = ReplayBuffer::new();
        assert_eq!(buffer.enqueue_output(bytes("x")), (1, DrainState::BufferedOnly));
        assert_eq!(buffer.highest_seq(), 1);
    }

    // MARK: retained-byte accounting

    #[test]
    fn retained_bytes_is_the_sum_of_the_un_acked_payloads() {
        let mut buffer = ReplayBuffer::new();
        assert_eq!(buffer.retained_bytes(), 0);
        buffer.append(chunk(10, 0));
        buffer.append(chunk(25, 0));
        buffer.append(chunk(5, 0));
        assert_eq!(buffer.retained_bytes(), 40);
        buffer.ack(2);
        assert_eq!(buffer.retained_bytes(), 5);
        buffer.ack(3);
        assert_eq!(buffer.retained_bytes(), 0);
    }

    // MARK: ack semantics — partial, idempotent, monotonic

    #[test]
    fn an_ack_drops_the_released_prefix_only() {
        let mut buffer = ReplayBuffer::new();
        for index in 1..=5 {
            buffer.append(vec![index]);
        }
        buffer.ack(3);
        assert_eq!(buffer.acked_seq(), 3);
        // `messages(acked_seq)` isolates the un-acked tail; `messages(0)` would also include the ring.
        let tail: Vec<i64> = buffer
            .messages(buffer.acked_seq())
            .into_iter()
            .map(|(seq, _)| seq)
            .collect();
        assert_eq!(tail, [4, 5]);
    }

    #[test]
    fn an_ack_is_idempotent() {
        let mut buffer = ReplayBuffer::new();
        for _ in 1..=5 {
            buffer.append(chunk(1, 0));
        }
        buffer.ack(3);
        let after_first = buffer.retained_bytes();
        buffer.ack(3);
        assert_eq!(buffer.retained_bytes(), after_first);
        assert_eq!(buffer.acked_seq(), 3);
    }

    #[test]
    fn a_stale_ack_is_a_no_op() {
        let mut buffer = ReplayBuffer::new();
        for _ in 1..=5 {
            buffer.append(chunk(1, 0));
        }
        buffer.ack(4);
        buffer.ack(2);
        assert_eq!(buffer.acked_seq(), 4, "the acked seq must only advance");
        let tail: Vec<i64> = buffer
            .messages(buffer.acked_seq())
            .into_iter()
            .map(|(seq, _)| seq)
            .collect();
        assert_eq!(tail, [5]);
    }

    #[test]
    fn an_ack_past_the_head_clears_everything_and_clamps() {
        let mut buffer = ReplayBuffer::new();
        for _ in 1..=3 {
            buffer.append(chunk(7, 0));
        }
        buffer.ack(100);
        assert_eq!(buffer.retained_bytes(), 0);
        assert_eq!(buffer.acked_seq(), 3, "an ack past the head clamps to the head");
        assert!(buffer.messages(buffer.acked_seq()).is_empty());

        let mut no_ring = ReplayBuffer::with_scrollback(0);
        for _ in 1..=3 {
            no_ring.append(chunk(7, 0));
        }
        no_ring.ack(100);
        assert!(
            no_ring.messages(0).is_empty(),
            "no ring ⇒ the acked prefix is gone"
        );
        assert_eq!(
            buffer.append(chunk(1, 0)),
            4,
            "the seq still continues from the head"
        );
    }

    /// A bogus far-future ack (a buggy or corrupt peer sending `i64::MAX`) must not wedge the
    /// buffer forever. Unclamped, the acked seq jumps past any seq a legitimate client can ever
    /// send, so every later ack hits the no-op branch and is silently dropped; appends then
    /// accumulate to the cap and the drain pauses PERMANENTLY.
    #[test]
    fn a_bogus_far_future_ack_does_not_wedge_later_acks() {
        let mut buffer = ReplayBuffer::with_caps(100, 40, 0);
        for _ in 1..=3 {
            buffer.append(chunk(10, 0));
        }
        buffer.ack(i64::MAX);
        assert_eq!(buffer.retained_bytes(), 0);
        buffer.append(chunk(60, 0));
        let top = buffer.append(chunk(60, 0));
        assert_eq!(buffer.retained_bytes(), 120);
        assert!(
            buffer.should_pause_drain(),
            "over the max-backup cap → the drain pauses"
        );
        buffer.ack(top);
        assert_eq!(buffer.acked_seq(), top);
        assert_eq!(buffer.retained_bytes(), 0);
        assert!(!buffer.should_pause_drain(), "the drain must resume, not wedge");
    }

    // MARK: messages() tail boundaries

    #[test]
    fn messages_after_zero_returns_everything() {
        let mut buffer = ReplayBuffer::new();
        for index in 1..=4_u8 {
            buffer.append(vec![index]);
        }
        assert_eq!(seq_list(&buffer.messages(0)), [1, 2, 3, 4]);
    }

    fn seq_list(pairs: &[(i64, &[u8])]) -> Vec<i64> {
        pairs.iter().map(|(seq, _)| *seq).collect()
    }

    #[test]
    fn messages_after_the_head_returns_nothing() {
        let mut buffer = ReplayBuffer::new();
        for _ in 1..=4 {
            buffer.append(chunk(1, 0));
        }
        assert!(buffer.messages(4).is_empty());
    }

    #[test]
    fn messages_after_the_middle_returns_the_exact_tail_with_bytes() {
        let mut buffer = ReplayBuffer::new();
        buffer.append(bytes("one"));
        buffer.append(bytes("two"));
        buffer.append(bytes("three"));
        let tail = buffer.messages(1);
        assert_eq!(seq_list(&tail), [2, 3]);
        assert_eq!(tail.iter().map(|(_, payload)| *payload).collect::<Vec<_>>(), [
            b"two".as_slice(),
            b"three".as_slice()
        ]);
    }

    #[test]
    fn replay_wraps_the_tail_as_output_messages_in_order() {
        let mut buffer = ReplayBuffer::new();
        buffer.append(bytes("a"));
        buffer.append(bytes("b"));
        buffer.append(bytes("c"));
        assert_eq!(buffer.replay(1), [output(2, "b"), output(3, "c")]);
    }

    // MARK: Offline gate transitions

    #[test]
    fn online_below_the_gate_does_not_pause() {
        let mut buffer = ReplayBuffer::with_caps(1000, 400, 0);
        buffer.append(chunk(399, 0));
        assert!(!buffer.should_pause_drain());
        assert_eq!(buffer.drain_state(), DrainState::BufferedOnly);
    }

    #[test]
    fn online_above_the_offline_gate_does_not_pause() {
        // The offline gate applies only while OFFLINE; online, only the max-backup cap pauses.
        let mut buffer = ReplayBuffer::with_caps(1000, 400, 0);
        buffer.append(chunk(401, 0));
        assert!(!buffer.should_pause_drain());
    }

    #[test]
    fn offline_crossing_the_gate_pauses() {
        let mut buffer = ReplayBuffer::with_caps(1000, 400, 0);
        buffer.set_client_online(false);
        buffer.append(chunk(399, 0));
        assert!(
            !buffer.should_pause_drain(),
            "just below the gate: keep buffering"
        );
        buffer.append(chunk(2, 0));
        assert!(buffer.should_pause_drain(), "offline at/over the gate: SKIPPED");
        assert_eq!(buffer.drain_state(), DrainState::Skipped);
    }

    #[test]
    fn going_offline_with_a_large_backlog_pauses() {
        let mut buffer = ReplayBuffer::with_caps(1000, 400, 0);
        buffer.append(chunk(500, 0));
        assert!(!buffer.should_pause_drain());
        buffer.set_client_online(false);
        assert!(buffer.should_pause_drain());
    }

    #[test]
    fn an_ack_below_the_gate_resumes_after_an_offline_pause() {
        let mut buffer = ReplayBuffer::with_caps(1000, 400, 0);
        buffer.set_client_online(false);
        let first = buffer.append(chunk(250, 0));
        buffer.append(chunk(250, 0));
        assert!(buffer.should_pause_drain());
        buffer.ack(first);
        assert!(
            !buffer.should_pause_drain(),
            "an ack dropping below the gate resumes"
        );
    }

    #[test]
    fn coming_back_online_resumes_even_with_a_backlog() {
        let mut buffer = ReplayBuffer::with_caps(1000, 400, 0);
        buffer.set_client_online(false);
        buffer.append(chunk(401, 0));
        assert!(buffer.should_pause_drain());
        buffer.set_client_online(true);
        assert!(!buffer.should_pause_drain());
    }

    // MARK: Never-drop invariant

    #[test]
    fn un_acked_data_is_never_dropped_to_satisfy_the_gate() {
        let mut buffer = ReplayBuffer::with_caps(1000, 400, 0);
        buffer.set_client_online(false);
        for _ in 0..6 {
            buffer.append(chunk(100, 0));
        }
        assert!(buffer.should_pause_drain());
        assert_eq!(seq_list(&buffer.messages(0)), [1, 2, 3, 4, 5, 6]);
        assert_eq!(buffer.retained_bytes(), 600);
    }

    #[test]
    fn the_pause_signal_honours_the_instance_caps() {
        let mut buffer = ReplayBuffer::with_caps(100, 40, 0);
        assert!(!buffer.should_pause_drain());
        buffer.append(chunk(50, 0));
        assert!(!buffer.should_pause_drain());
        buffer.set_client_online(false);
        assert!(buffer.should_pause_drain(), "offline + retained(50) ≥ gate(40)");
        buffer.set_client_online(true);
        assert!(!buffer.should_pause_drain(), "online + retained(50) < cap(100)");
        buffer.append(chunk(60, 0));
        assert!(buffer.should_pause_drain(), "online + retained(110) ≥ cap(100)");
        buffer.ack(buffer.highest_seq());
        assert!(!buffer.should_pause_drain());
    }

    // MARK: Scrollback ring

    #[test]
    fn acked_entries_move_into_the_scrollback_ring() {
        let mut buffer = ReplayBuffer::with_scrollback(1024);
        let first = buffer.append(bytes("hello"));
        let second = buffer.append(bytes("world"));
        buffer.append(bytes("tail"));
        buffer.ack(second);
        assert_eq!(buffer.retained_bytes(), 4, "only the un-acked entry is retained");
        assert_eq!(buffer.scrollback_ring_seqs(), [first, second]);
        let messages = buffer.messages(0);
        assert_eq!(seq_list(&messages), [1, 2, 3]);
        assert_eq!(
            messages.iter().map(|(_, payload)| *payload).collect::<Vec<_>>(),
            [b"hello".as_slice(), b"world".as_slice(), b"tail".as_slice()]
        );
    }

    #[test]
    fn a_cold_replay_after_a_full_ack_returns_the_ring_only() {
        let mut buffer = ReplayBuffer::with_scrollback(512);
        buffer.append(bytes("a"));
        buffer.append(bytes("b"));
        buffer.ack(buffer.highest_seq());
        assert_eq!(buffer.retained_bytes(), 0);
        assert_eq!(seq_list(&buffer.messages(0)), [1, 2]);
    }

    #[test]
    fn the_ring_evicts_the_oldest_to_stay_within_its_cap() {
        let mut buffer = ReplayBuffer::with_scrollback(10);
        let first = buffer.append(bytes("abcd"));
        let second = buffer.append(bytes("efgh"));
        let third = buffer.append(bytes("ijkl"));
        buffer.ack(first);
        assert!(buffer.scrollback_ring_bytes() <= 10);
        buffer.ack(second);
        assert!(buffer.scrollback_ring_bytes() <= 10);
        buffer.ack(third);
        assert!(buffer.scrollback_ring_bytes() <= 10);
        let ring = buffer.scrollback_ring_seqs();
        assert!(!ring.contains(&first), "the oldest entry must be evicted");
        assert!(ring.contains(&third), "the newest acked entry must survive");
    }

    /// Pins the EXACT ring contents after a multi-entry eviction — seqs, byte totals, and the
    /// line-aligned head trim — so the bulk drain stays byte-identical to a per-entry loop.
    #[test]
    fn bulk_eviction_leaves_byte_pinned_ring_contents() {
        // 6 entries × 5 B, cap 12 → one ack moves 30 B into the ring, eviction drops seqs 1..4
        // (30→25→20→15→10 ≤ 12), then the line-align trim fires on the new head ("q4\nr4" → "r4").
        let mut buffer = ReplayBuffer::with_scrollback(12);
        for index in 0..6 {
            buffer.append(bytes(&format!("q{index}\nr{index}")));
        }
        buffer.ack(6);
        assert_eq!(buffer.retained_bytes(), 0);
        assert_eq!(buffer.scrollback_ring_seqs(), [5, 6]);
        assert_eq!(buffer.scrollback_ring_len(), 2);
        assert_eq!(buffer.scrollback_ring_oldest(), Some(b"r4".as_slice()));
        assert_eq!(buffer.scrollback_ring_bytes(), 7, "5 + 5 - 3 trimmed head bytes");
        assert_eq!(
            buffer
                .messages(0)
                .iter()
                .map(|(_, payload)| *payload)
                .collect::<Vec<_>>(),
            [b"r4".as_slice(), b"q5\nr5".as_slice()]
        );

        // Many small entries, no `\n` in the surviving head → bulk drop, head intact.
        let mut big = ReplayBuffer::with_scrollback(64);
        let mut last = 0;
        for _ in 0..200 {
            last = big.append(bytes("abcdefgh"));
        }
        big.ack(last);
        assert_eq!(big.scrollback_ring_seqs(), (193..=200).collect::<Vec<i64>>());
        assert_eq!(big.scrollback_ring_bytes(), 64);
        assert_eq!(big.scrollback_ring_oldest(), Some(b"abcdefgh".as_slice()));
    }

    #[test]
    fn ring_eviction_is_line_aligned() {
        // cap 8. s1 = "AAAA" (4 B), s2 = "BB\nCC" (5 B). Ack s1 → 4 B, under cap. Ack s2 → 9 B > 8 →
        // evict s1 → 5 B ≤ 8 → trim s2 past its `\n` → "CC".
        let mut buffer = ReplayBuffer::with_scrollback(8);
        let first = buffer.append(bytes("AAAA"));
        let second = buffer.append(bytes("BB\nCC"));
        buffer.append(bytes("live"));
        buffer.ack(first);
        assert_eq!(buffer.scrollback_ring_seqs(), [first]);
        buffer.ack(second);
        assert_eq!(buffer.scrollback_ring_seqs(), [second]);
        assert_eq!(buffer.scrollback_ring_oldest(), Some(b"CC".as_slice()));
        assert_eq!(buffer.scrollback_ring_bytes(), 2);
    }

    #[test]
    fn the_ring_does_not_affect_the_offline_gate() {
        let mut buffer = ReplayBuffer::with_caps(64 * 1024, 32 * 1024, 8);
        buffer.set_client_online(false);
        buffer.append(bytes("abc"));
        buffer.append(bytes("def"));
        buffer.ack(buffer.highest_seq());
        assert_eq!(buffer.retained_bytes(), 0);
        assert!(
            !buffer.should_pause_drain(),
            "ring bytes must not contribute to the pause signal"
        );
    }

    #[test]
    fn a_warm_reconnect_sees_only_the_un_acked_tail() {
        let mut buffer = ReplayBuffer::with_scrollback(512);
        buffer.append(bytes("A"));
        buffer.append(bytes("B"));
        buffer.append(bytes("C"));
        buffer.ack(2);
        assert_eq!(seq_list(&buffer.messages(2)), [3]);
    }

    #[test]
    fn a_zero_cap_disables_the_ring() {
        let mut buffer = ReplayBuffer::with_scrollback(0);
        buffer.append(bytes("hello"));
        buffer.ack(buffer.highest_seq());
        assert_eq!(buffer.scrollback_ring_len(), 0);
        assert_eq!(buffer.scrollback_ring_bytes(), 0);
        assert!(buffer.messages(0).is_empty());
    }

    #[test]
    fn the_ring_never_swallows_un_acked_entries() {
        let mut buffer = ReplayBuffer::with_scrollback(4);
        for _ in 0..5 {
            buffer.append(bytes("XX"));
        }
        assert_eq!(buffer.scrollback_ring_len(), 0);
        assert_eq!(buffer.retained_bytes(), 10);
        assert_eq!(seq_list(&buffer.messages(0)), [1, 2, 3, 4, 5]);
    }

    #[test]
    fn a_cold_replay_includes_the_ring() {
        let mut buffer = ReplayBuffer::with_scrollback(256);
        buffer.append(bytes("x"));
        buffer.append(bytes("y"));
        buffer.ack(1);
        assert_eq!(buffer.replay(0), [output(1, "x"), output(2, "y")]);
    }

    // MARK: Distiller injection

    #[test]
    fn a_cold_replay_transforms_ring_and_tail_for_a_fresh_client() {
        let mut buffer = ReplayBuffer::with_scrollback(256).distilling(drop_dashes());
        buffer.append(bytes("a-b"));
        buffer.append(bytes("c-d"));
        buffer.append(bytes("tail-raw"));
        buffer.ack(2);
        let replayed = buffer.replay(0);
        assert_eq!(joined(&replayed), b"abcdtailraw");
        let emitted = seqs(&replayed);
        let mut sorted = emitted.clone();
        sorted.sort_unstable();
        assert_eq!(emitted, sorted, "seqs ascend");
        assert_eq!(
            emitted.last(),
            Some(&3),
            "the last chunk carries the top tail seq"
        );
        buffer.ack(3);
        assert_eq!(
            buffer.retained_bytes(),
            0,
            "the post-replay ack releases the tail"
        );
    }

    #[test]
    fn a_cold_tail_only_replay_still_anchors_the_ack() {
        let mut buffer = ReplayBuffer::with_scrollback(256).distilling(drop_dashes());
        buffer.append(bytes("x-y"));
        buffer.append(bytes("z-"));
        let replayed = buffer.replay(0);
        assert_eq!(joined(&replayed), b"xyz");
        assert_eq!(seqs(&replayed).last(), Some(&2));

        let mut churn = ReplayBuffer::with_scrollback(256).distilling(drop_dashes());
        churn.append(bytes("---"));
        churn.append(bytes("--"));
        assert_eq!(
            churn.replay(0),
            [WireMessage::Output {
                seq: 2,
                bytes: Vec::new()
            }],
            "an empty clean still anchors the ack"
        );
    }

    #[test]
    fn a_warm_reconnect_never_distills() {
        let mut buffer = ReplayBuffer::with_scrollback(256).distilling(drop_dashes());
        buffer.append(bytes("a-b"));
        buffer.ack(1);
        buffer.append(bytes("live-tail"));
        assert_eq!(buffer.replay(1), [output(2, "live-tail")]);
    }

    #[test]
    fn distilled_ring_chunk_seqs_stay_below_the_tail() {
        // The RING-ONLY distill path: a returning client whose cursor sits inside the ring. The
        // re-chunker must assign only scrollback seqs, ascending, each strictly below the tail seq.
        let mut buffer = ReplayBuffer::with_scrollback(4096).distilling(drop_dashes());
        let mut expected = String::new();
        for index in 0..50 {
            let line = format!("L{index}\n"); // no dashes → the distiller is an identity here
            if index >= 1 {
                expected.push_str(&line);
            }
            buffer.append(bytes(&line));
        }
        buffer.ack(50);
        buffer.append(bytes("TAIL"));
        let replayed = buffer.replay(1);
        let ring_seqs: Vec<i64> = seqs(&replayed).into_iter().filter(|seq| *seq <= 50).collect();
        let mut sorted = ring_seqs.clone();
        sorted.sort_unstable();
        assert_eq!(ring_seqs, sorted, "ring chunk seqs ascend");
        assert!(ring_seqs.iter().all(|seq| (2..=50).contains(seq)));
        sorted.dedup();
        assert_eq!(sorted.len(), ring_seqs.len(), "no seq is reused across chunks");
        let ring_bytes: Vec<u8> = replayed
            .iter()
            .filter(|message| matches!(message, WireMessage::Output { seq, .. } if *seq <= 50))
            .flat_map(|message| {
                match message {
                    WireMessage::Output { bytes, .. } => bytes.clone(),
                    _ => Vec::new(),
                }
            })
            .collect();
        assert_eq!(ring_bytes, expected.as_bytes());
        assert_eq!(replayed.last(), Some(&output(51, "TAIL")));
    }

    /// Every re-chunked replay frame must respect the credit progress invariant — payload ≤
    /// [`MuxFlowControl::max_output_frame_payload_bytes`] (wire size ≤ window/2). A hardcoded 32
    /// KiB floor emits 32768-byte payloads → 32781 wire bytes > 32768: the literal "13-byte
    /// dead zone" that parks the sender against a receiver whose pending credit can never cross
    /// the grant threshold (a permanently silent pane right after reattach).
    #[test]
    fn a_combined_rechunk_respects_the_payload_cap_and_the_top_seq() {
        let mut buffer = ReplayBuffer::with_scrollback(8 * 1024 * 1024).distilling(identity());
        let cap = usize::try_from(MuxFlowControl::max_output_frame_payload_bytes()).unwrap_or(usize::MAX);
        let mut fed = Vec::new();
        for index in 0..8_u8 {
            let payload = chunk(cap, 0x30 + index);
            fed.extend_from_slice(&payload);
            buffer.append(payload);
        }
        buffer.ack(4);
        let replayed = buffer.replay(0);
        for message in &replayed {
            if let WireMessage::Output { bytes, .. } = message {
                assert!(bytes.len() <= cap, "window/2 progress invariant");
            }
        }
        assert_eq!(joined(&replayed), fed, "the combined re-chunk is byte-preserving");
        assert_eq!(seqs(&replayed).last(), Some(&8), "the top tail seq is covered");
    }

    #[test]
    fn a_ring_only_rechunk_never_exceeds_the_payload_cap() {
        let mut buffer = ReplayBuffer::with_scrollback(8 * 1024 * 1024).distilling(identity());
        let cap = usize::try_from(MuxFlowControl::max_output_frame_payload_bytes()).unwrap_or(usize::MAX);
        let mut fed = Vec::new();
        let mut last = 0;
        for index in 0..8_u8 {
            let payload = chunk(cap, 0x30 + index);
            fed.extend_from_slice(&payload);
            last = buffer.append(payload);
        }
        buffer.ack(last);
        let replayed = buffer.replay(0);
        for message in &replayed {
            if let WireMessage::Output { bytes, .. } = message {
                assert!(bytes.len() <= cap);
            }
        }
        assert_eq!(joined(&replayed), fed, "the re-chunk is byte-preserving");
    }

    #[test]
    fn no_distiller_is_raw_byte_identical() {
        let mut buffer = ReplayBuffer::with_scrollback(256);
        buffer.append(bytes("a-b"));
        buffer.append(bytes("c-d"));
        buffer.ack(1);
        assert_eq!(buffer.replay(0), [output(1, "a-b"), output(2, "c-d")]);
    }

    // MARK: Alt-screen cut repair

    #[test]
    fn eviction_mid_alt_segment_prepends_the_reopen_to_the_ring_head() {
        // cap 30. s1 = "before\n" (7 B), s2 = opener + "alt\n" (12 B) — both evicted; the cut lands
        // INSIDE the still-open segment. s3 has no `\n` so the line trim stays out of the way.
        let mut buffer = ReplayBuffer::with_scrollback(30);
        let first = buffer.append(bytes("before\n"));
        let second = buffer.append(bytes("\u{1B}[?1049halt\n"));
        let third = buffer.append(bytes("frame-two-no-newline"));
        buffer.append(bytes("live"));
        buffer.ack(second);
        assert_eq!(buffer.scrollback_ring_seqs(), [first, second]);
        buffer.ack(third);
        assert_eq!(buffer.scrollback_ring_seqs(), [third]);
        assert_eq!(
            buffer.scrollback_ring_oldest(),
            Some(b"\x1B[?1049hframe-two-no-newline".as_slice())
        );
        assert_eq!(
            buffer.scrollback_ring_bytes(),
            28,
            "20 B entry + 8 B synthetic opener"
        );
    }

    #[test]
    fn eviction_on_the_main_screen_does_not_repair() {
        let mut buffer = ReplayBuffer::with_scrollback(30);
        buffer.append(bytes("plain-history-1\n"));
        let second = buffer.append(bytes("\u{1B}[?1049halt-opens-in-kept"));
        buffer.ack(second);
        assert_eq!(
            buffer.scrollback_ring_oldest(),
            Some(b"\x1B[?1049halt-opens-in-kept".as_slice()),
            "a cut before the opener needs no repair"
        );
    }

    #[test]
    fn eviction_after_a_closed_segment_does_not_repair() {
        let mut buffer = ReplayBuffer::with_scrollback(20);
        let first = buffer.append(bytes("\u{1B}[?1049hchurn\u{1B}[?1049l\n"));
        let second = buffer.append(bytes("after-close"));
        buffer.ack(first);
        buffer.ack(second);
        assert_eq!(
            buffer.scrollback_ring_oldest(),
            Some(b"after-close".as_slice()),
            "a closed segment before the cut must not synthesise an opener"
        );
    }

    #[test]
    fn the_line_trim_and_the_repair_compose() {
        // cap 12. s1 = opener + "x\n" (10 B) evicts whole; s2 = "in-alt\nrest" (11 B) survives and is
        // line-trimmed to "rest" — still inside the segment → opener + "rest".
        let mut buffer = ReplayBuffer::with_scrollback(12);
        let first = buffer.append(bytes("\u{1B}[?1049hx\n"));
        let second = buffer.append(bytes("in-alt\nrest"));
        buffer.ack(first);
        buffer.ack(second);
        assert_eq!(
            buffer.scrollback_ring_oldest(),
            Some(b"\x1B[?1049hrest".as_slice()),
            "the repair applies after the line trim, covering the trimmed bytes in the scan"
        );
        assert_eq!(buffer.scrollback_ring_bytes(), 12, "4 B survivor + 8 B opener");
    }

    #[test]
    fn a_repaired_head_survives_the_next_eviction_scan() {
        let mut buffer = ReplayBuffer::with_scrollback(30);
        buffer.append(bytes("before\n"));
        buffer.append(bytes("\u{1B}[?1049halt\n"));
        let third = buffer.append(bytes("frame-two-no-newline"));
        buffer.ack(third);
        let fourth = buffer.append(bytes("frame-three-no-newlin"));
        buffer.ack(fourth);
        assert_eq!(
            buffer.scrollback_ring_oldest(),
            Some(b"\x1B[?1049hframe-three-no-newlin".as_slice()),
            "the synthetic opener round-trips through the next eviction's scan"
        );
    }

    #[test]
    fn a_ring_emptying_eviction_carries_the_reopen_forward() {
        let mut buffer = ReplayBuffer::with_scrollback(12);
        let first = buffer.append(bytes("\u{1B}[?1049hlong-alt-frame"));
        buffer.ack(first);
        assert_eq!(buffer.scrollback_ring_len(), 0);
        let second = buffer.append(bytes("next"));
        buffer.ack(second);
        assert_eq!(
            buffer.scrollback_ring_oldest(),
            Some(b"\x1B[?1049hnext".as_slice()),
            "the pending reopen attaches to the first bytes that survive the emptied ring"
        );
        assert_eq!(buffer.scrollback_ring_bytes(), 12);
    }

    // MARK: History canonicalisation

    #[test]
    fn a_stale_ring_fold_is_dropped_whole() {
        let mut buffer = ReplayBuffer::new();
        buffer.append(bytes("one\n"));
        buffer.append(bytes("two\n"));
        buffer.ack(2);
        let stale = buffer.ring_fold_source().expect("the ring is non-empty");
        buffer.append(bytes("three\n"));
        buffer.ack(3);
        assert!(!buffer.adopt_folded_ring(b"folded", &stale));
        assert_eq!(buffer.snapshot_source(0).history, b"one\ntwo\nthree\n");

        let fresh = buffer.ring_fold_source().expect("the ring is non-empty");
        assert!(buffer.adopt_folded_ring(b"folded", &fresh));
        assert_eq!(buffer.snapshot_source(0).history, b"folded");
        assert_eq!(buffer.scrollback_ring_bytes(), 6);
    }

    #[test]
    fn snapshot_adoption_splits_at_the_acked_seq() {
        let mut buffer = ReplayBuffer::new();
        buffer.append(bytes("raw-a"));
        buffer.append(bytes("raw-b"));
        buffer.ack(1);
        buffer.adopt_snapshot_replay(&[output(1, "R"), output(2, "T")]);
        assert_eq!(
            buffer.retained_bytes(),
            1,
            "the tail is the adopted un-acked chunk"
        );
        assert_eq!(buffer.snapshot_source(0).history, b"RT");
        assert_eq!(buffer.replay(1), [output(2, "T")]);
    }

    #[test]
    fn snapshot_adoption_respects_a_disabled_ring() {
        let mut buffer = ReplayBuffer::with_scrollback(0);
        buffer.append(bytes("raw-a"));
        buffer.append(bytes("raw-b"));
        buffer.ack(1);
        buffer.adopt_snapshot_replay(&[output(1, "R"), output(2, "T")]);
        assert_eq!(buffer.scrollback_ring_len(), 0);
        assert_eq!(buffer.snapshot_source(0).history, b"T");
    }

    #[test]
    fn rechunk_snapshot_always_covers_the_last_seq() {
        let messages = ReplayBuffer::rechunk_snapshot(b"", &[7, 9]);
        assert_eq!(messages, [WireMessage::Output {
            seq: 9,
            bytes: Vec::new()
        }]);
        assert!(ReplayBuffer::rechunk_snapshot(b"abc", &[]).is_empty());
    }

    // MARK: The lag metric

    #[test]
    fn the_lag_metric_counts_exactly_the_entries_above_the_cursor() {
        let mut buffer = ReplayBuffer::with_scrollback(0);
        let first = buffer.append(chunk(10, 0x41));
        let second = buffer.append(chunk(20, 0x41));
        let third = buffer.append(chunk(30, 0x41));
        assert_eq!(
            buffer.retained_bytes_above(0),
            60,
            "a cursor at 0 is behind everything"
        );
        assert_eq!(buffer.retained_bytes_above(first), 50);
        assert_eq!(buffer.retained_bytes_above(second), 30);
        assert_eq!(
            buffer.retained_bytes_above(third),
            0,
            "a cursor at the head is not behind"
        );
        assert_eq!(
            buffer.retained_bytes_above(third + 1000),
            0,
            "a cursor past the head — an over-eager or corrupt ack — is still not behind"
        );
    }

    /// The load-bearing case: `ack` drops the released prefix, and the cumulative labels the metric
    /// subtracts must stay meaningful across that drop. A metric that reset its base on every ack
    /// would over-report the tail and evict a healthy subscriber.
    #[test]
    fn the_lag_metric_is_exact_after_an_ack_drops_the_prefix() {
        let mut buffer = ReplayBuffer::with_scrollback(0);
        for _ in 0..10 {
            buffer.append(chunk(100, 0x41));
        }
        assert_eq!(buffer.retained_bytes(), 1000);
        buffer.ack(4);
        assert_eq!(buffer.retained_bytes(), 600);
        assert_eq!(buffer.retained_bytes_above(4), 600);
        assert_eq!(buffer.retained_bytes_above(7), 300);
        assert_eq!(buffer.retained_bytes_above(10), 0);
        assert_eq!(
            buffer.retained_bytes_above(1),
            600,
            "a cursor below the retained window answers the whole tail — released bytes are not lag"
        );
    }

    #[test]
    fn the_lag_metric_stays_exact_across_interleaved_appends_and_acks() {
        let mut buffer = ReplayBuffer::with_scrollback(0);
        let mut expected_above_zero = 0;
        for round in 1..=20_usize {
            buffer.append(chunk(round, 0x41));
            expected_above_zero += round;
            if round % 3 == 0 {
                let released = buffer.retained_bytes_above(i64::try_from(round).unwrap_or(i64::MAX));
                buffer.ack(i64::try_from(round).unwrap_or(i64::MAX));
                expected_above_zero = released;
                assert_eq!(
                    buffer.retained_bytes(),
                    released,
                    "round {round}: the metric predicted exactly what survived the ack"
                );
            }
            assert_eq!(
                buffer.retained_bytes_above(0),
                expected_above_zero,
                "round {round}"
            );
            assert_eq!(
                buffer.retained_bytes_above(buffer.highest_seq()),
                0,
                "round {round}: a current member is never behind"
            );
        }
    }

    /// `adopt_snapshot_replay` REPLACES the tail wholesale. The metric has to be re-derived there
    /// or it reads a stale base — which, being an under-count, would silently stop evicting.
    #[test]
    fn the_lag_metric_is_rederived_after_a_snapshot_adoption() {
        let mut buffer = ReplayBuffer::with_scrollback(0);
        for _ in 0..5 {
            buffer.append(chunk(100, 0x41));
        }
        buffer.ack(2);
        buffer.adopt_snapshot_replay(&[
            WireMessage::Output {
                seq: 3,
                bytes: chunk(10, 0x42),
            },
            WireMessage::Output {
                seq: 4,
                bytes: chunk(10, 0x42),
            },
            WireMessage::Output {
                seq: 5,
                bytes: chunk(10, 0x42),
            },
        ]);
        assert_eq!(buffer.retained_bytes(), 30);
        assert_eq!(buffer.retained_bytes_above(2), 30);
        assert_eq!(buffer.retained_bytes_above(4), 10);
        assert_eq!(buffer.retained_bytes_above(5), 0);
        buffer.append(chunk(7, 0x43));
        assert_eq!(buffer.retained_bytes_above(5), 7);
        assert_eq!(buffer.retained_bytes_above(2), 37);
    }

    /// The metric reads the LIVE tail only. Acked history lives in the ring, which is not something
    /// anybody is waiting for — counting it would evict every member of a pane with a large
    /// scrollback.
    #[test]
    fn the_lag_metric_ignores_the_acked_ring() {
        let mut buffer = ReplayBuffer::with_scrollback(1024 * 1024);
        for _ in 0..5 {
            buffer.append(chunk(100, 0x41));
        }
        buffer.ack(5);
        assert!(
            buffer.scrollback_ring_bytes() > 0,
            "precondition: the ring holds history"
        );
        assert_eq!(
            buffer.retained_bytes_above(0),
            0,
            "everything is acked — nobody is behind, however much history the ring keeps"
        );
    }

    #[test]
    fn the_lag_metric_on_an_empty_buffer_is_zero() {
        let buffer = ReplayBuffer::with_scrollback(0);
        assert_eq!(buffer.retained_bytes_above(0), 0);
        assert_eq!(buffer.retained_bytes_above(i64::MAX), 0);
        assert_eq!(buffer.retained_bytes_above(-1), 0);
    }
}
