//! Per-channel credit flow control: the sender's window, the receiver's replenish decision, the
//! host's bounded producer queue, and the constants all three are sized from.
//!
//! SSH / HTTP-2 / yamux windowing, split into three pure state machines so each is testable without
//! a socket. The only impurity in the file is [`MuxFlowControl`] reading its env overrides once.
//!
//! ## Why `i64` and not `usize`
//! These are ports of Swift `Int` arithmetic that deliberately accepts and clamps NEGATIVE inputs
//! (a defensive guard on `consume(-1)`), and that saturates a peer-chosen credit grant at `Int.max`
//! rather than trapping. `usize` would make the negative cases unrepresentable and move the guard
//! to the caller — where it would be written once per call site instead of once here.

use std::sync::OnceLock;

/// Halves a non-negative byte count.
///
/// Written out rather than inline because `clippy::integer_division` is denied crate-wide: the lint
/// is right that a bare `/ 2` hides a rounding decision, and every window here rounds DOWN on
/// purpose — a threshold that rounded up could sit above what the sender is able to put in flight.
const fn half(value: i64) -> i64 {
    value.div_euclid(2)
}

/// Shared constants for TCP-mux per-channel credit flow control, which is always on.
///
/// The numbers are in ONE place so both ends agree without negotiation: a sender's initial
/// [`FlowCreditPolicy`] window, a receiver's [`ReceiveWindowAccountant`] window and the host's
/// [`BoundedQueuePolicy`] capacity are all sized from here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MuxFlowControl;

impl MuxFlowControl {
    /// Max LIVE logical channels (panes) one physical connection may hold open at once.
    ///
    /// A hostile or buggy peer can otherwise spam distinct open ids and make the host `openpty()` +
    /// `fork()` a shell per id without bound — a fork-bomb that exhausts fds, processes and RAM.
    /// The host refuses a NEW channel past this. 256 is far above any real multi-pane session.
    pub const MAX_CHANNELS_PER_CONNECTION: usize = 256;

    /// Initial per-channel send/receive window, in bytes (64 KiB).
    ///
    /// Sized for LATENCY: credit is granted at CONSUMPTION (the client's render drain), not at
    /// demux, so every in-flight byte is committed ahead of fresh output, and the window bounds
    /// both client RAM per flooding pane AND the echo head-of-line delay (~44 ms at the
    /// measured ~12 Mbps inter-ISP path; a 256 KiB window would cost ~175 ms). Still far above
    /// what an interactive pane ever has outstanding, so flow control stays invisible on the
    /// common path.
    ///
    /// PROGRESS INVARIANT (credit-at-consumption): every DATA inner frame must satisfy
    /// `frame wire bytes <= window/2`. The receiver can only consume — and so re-grant — COMPLETE
    /// decoded frames, so a frame near the whole window could park its sender against a receiver
    /// whose pending credit never crosses the grant threshold. Enforced by construction at
    /// [`max_output_frame_payload_bytes`](Self::max_output_frame_payload_bytes) and
    /// [`max_data_message_payload_bytes`](Self::max_data_message_payload_bytes).
    ///
    /// `SLOPDESK_MUX_WINDOW` tunes it — and MUST be set identically in BOTH processes. The sender's
    /// window and the receiver's grant threshold derive from this constant in their own process, so
    /// a host-only decrease below the client's half-window threshold permanently stalls the channel
    /// on the first flood.
    #[must_use]
    pub fn initial_window_bytes() -> i64 {
        static VALUE: OnceLock<i64> = OnceLock::new();
        *VALUE.get_or_init(|| env_int("SLOPDESK_MUX_WINDOW", 64 * 1024, 16 * 1024, 16 * 1024 * 1024))
    }

    /// Split cap for client→host input frames (paste), in bytes.
    ///
    /// Sending a whole paste as ONE inner frame is avoided because the host writes nothing to the
    /// PTY until the WHOLE frame reassembles, and under credit-at-consumption a frame at or above
    /// the window would deadlock. 16 KiB is far below window/2, streams a paste progressively and
    /// keeps interleave granularity fine. Splitting a byte stream is transparent to the PTY: frames
    /// carry no semantics, and order is preserved by the per-channel send gate.
    ///
    /// Cross-clamped against the tunable window so `SLOPDESK_MUX_WINDOW` at its low bound can never
    /// reintroduce the `frame >= window/2` dead zone on the input direction.
    #[must_use]
    pub fn max_data_message_payload_bytes() -> i64 {
        (16 * 1024).min(half(Self::initial_window_bytes()) - 16)
    }

    /// Bound on the host's per-channel PTY-read queue, in bytes (64 KiB).
    ///
    /// Sized for LATENCY, not throughput: every byte enqueued-not-yet-sent is committed AHEAD of
    /// fresh output (a keystroke echo, the post-flood prompt), so on a slow link this bound IS the
    /// in-host head-of-line delay. ~44 ms at the measured ~12 Mbps inter-ISP path, versus ~175 ms
    /// at a 256 KiB bound, while still amortising the pause/resume gate to one signal per ~64
    /// KiB drained. The PTY-pause → kernel-buffer → shell backpressure chain is unchanged; only
    /// the trigger point moves.
    ///
    /// Host-local, with no protocol interaction, so `SLOPDESK_MUX_HOST_QUEUE` is unilaterally safe.
    #[must_use]
    pub fn host_queue_capacity_bytes() -> i64 {
        static VALUE: OnceLock<i64> = OnceLock::new();
        *VALUE.get_or_init(|| env_int("SLOPDESK_MUX_HOST_QUEUE", 64 * 1024, 8 * 1024, 8 * 1024 * 1024))
    }

    /// The DETACHED-mode replacement for
    /// [`host_queue_capacity_bytes`](Self::host_queue_capacity_bytes) (64 MiB).
    ///
    /// With no client consuming, the queue bound is not a latency knob but the "output while away"
    /// budget — past it the PTY pause chain stalls the pane's still-running process, so an agent
    /// left working would freeze mid-task at 64 KiB plus a kernel buffer. 64 MiB is roughly an
    /// aggressive overnight agent's output, bounded per detached session; rebinding the relay
    /// restores the attached bound once the backlog has shipped.
    ///
    /// Host-local, so `SLOPDESK_MUX_DETACHED_QUEUE` is unilaterally safe.
    #[must_use]
    pub fn detached_host_queue_capacity_bytes() -> i64 {
        static VALUE: OnceLock<i64> = OnceLock::new();
        *VALUE.get_or_init(|| {
            env_int(
                "SLOPDESK_MUX_DETACHED_QUEUE",
                64 * 1024 * 1024,
                64 * 1024,
                1024 * 1024 * 1024,
            )
        })
    }

    /// Cap on a MERGED host output frame (drain-side coalescing), in bytes (32 KiB).
    ///
    /// The host drain concatenates immediately-available FIFO chunks into one output frame up to
    /// this cap, amortising per-frame costs across a flood's small kernel-sized chunks.
    ///
    /// `SLOPDESK_MUX_MERGE_CAP` tunes it, but the EFFECTIVE bound is
    /// [`max_output_frame_payload_bytes`](Self::max_output_frame_payload_bytes): this raw value
    /// alone is NOT a safe frame bound.
    #[must_use]
    pub fn host_merge_cap_bytes() -> i64 {
        static VALUE: OnceLock<i64> = OnceLock::new();
        *VALUE.get_or_init(|| env_int("SLOPDESK_MUX_MERGE_CAP", 32 * 1024, 4 * 1024, 128 * 1024))
    }

    /// The PROVABLY-SAFE payload cap for host output frames — the single place the credit progress
    /// invariant is enforced.
    ///
    /// Every windowed inner frame's WIRE size must stay at or below window/2, or a sender can park
    /// permanently: at a credit park the receiver can only re-grant bytes of COMPLETE decoded
    /// frames, and the partial frame buried in its decoder is uncreditable — if that partial prefix
    /// alone exceeds the grant threshold, pending credit never crosses it and no window-adjust is
    /// ever emitted.
    ///
    /// This is a real trap, not a theoretical one: a 32 KiB PAYLOAD cap puts the max output frame
    /// at 32 KiB + 13 header bytes = 32781 > 32768 — a 13-byte dead zone that permanently
    /// wedges the pane. So the cap is in PAYLOAD bytes but accounts the frame overhead:
    /// window/2 minus a 16-byte margin (at least the 13-byte output header — 4 length, 1 type,
    /// 8 seq — with headroom for future header growth), cross-clamped against the merge cap at
    /// [`host_merge_cap_bytes`](Self::host_merge_cap_bytes) so env-tuning either knob can never
    /// produce a deadlocking combination.
    #[must_use]
    pub fn max_output_frame_payload_bytes() -> i64 {
        Self::host_merge_cap_bytes().min(half(Self::initial_window_bytes()) - 16)
    }
}

/// Env-seamed integer with bounds: out-of-range or unparseable values fall back to the shipped
/// default, so a typo can never produce a degenerate window or queue.
fn env_int(key: &str, fallback: i64, lo: i64, hi: i64) -> i64 {
    std::env::var(key)
        .ok()
        .and_then(|raw| raw.parse::<i64>().ok())
        .filter(|value| *value >= lo && *value <= hi)
        .unwrap_or(fallback)
}

/// The outcome of attempting to send some bytes against a [`FlowCreditPolicy`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConsumeResult {
    /// The full request fit; the payload is the credit left afterwards.
    Allowed(i64),
    /// The window had less than the requested credit, and NOTHING was consumed. The payload is how
    /// much could be sent right now (0 when blocked).
    Insufficient(i64),
}

/// SSH-window-style flow-control credit math for one direction of one channel — the SENDER's half.
///
/// The sender may transmit at most [`remaining`](FlowCreditPolicy::remaining) bytes before it must
/// wait for the peer to grant more via a window-adjust.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlowCreditPolicy {
    initial_window: i64,
    remaining: i64,
}

impl FlowCreditPolicy {
    /// A window starting with `initial_window` bytes of credit, clamped non-negative.
    #[must_use]
    pub const fn new(initial_window: i64) -> Self {
        let start = if initial_window > 0 { initial_window } else { 0 };
        Self {
            initial_window: start,
            remaining: start,
        }
    }

    /// Rebuilds a window whose two numbers a caller held across a boundary.
    ///
    /// The state of every policy in this file is small enough to cross by value, so the FFI door
    /// hands the numbers back rather than keeping a handle per channel per direction. Both are
    /// clamped exactly as [`new`](Self::new) clamps, so a caller cannot restore a window this type
    /// could not have produced.
    #[must_use]
    pub const fn restored(initial_window: i64, remaining: i64) -> Self {
        Self {
            initial_window: if initial_window > 0 { initial_window } else { 0 },
            remaining: if remaining > 0 { remaining } else { 0 },
        }
    }

    /// The window size the channel started with — a reference for callers that want to know how
    /// much has been consumed, NOT a cap on [`remaining`](Self::remaining).
    #[must_use]
    pub const fn initial_window(&self) -> i64 {
        self.initial_window
    }

    /// Bytes of credit still available to send. Never negative.
    #[must_use]
    pub const fn remaining(&self) -> i64 {
        self.remaining
    }

    /// Attempts to debit `bytes` from the window.
    ///
    /// All-or-nothing: if less than `bytes` of credit remains the window is left untouched and
    /// [`ConsumeResult::Insufficient`] reports how much is currently sendable. A zero or negative
    /// request is always allowed and consumes nothing — callers never send negative bytes, and the
    /// guard is here rather than at every call site.
    pub const fn consume(&mut self, bytes: i64) -> ConsumeResult {
        let want = if bytes > 0 { bytes } else { 0 };
        if want > self.remaining {
            return ConsumeResult::Insufficient(self.remaining);
        }
        self.remaining -= want;
        ConsumeResult::Allowed(self.remaining)
    }

    /// Re-credits the window by `bytes_to_add`. Negative grants are ignored; replenishing a blocked
    /// window unblocks it.
    ///
    /// OVERFLOW-SAFE: a huge peer-chosen `u32` grant, or a long run of grants, must not overflow.
    /// It saturates instead. Note that SSH-style windows may legitimately grow PAST
    /// [`initial_window`](Self::initial_window) — that is the starting reference, not a hard cap —
    /// so this deliberately does NOT clamp to the window; it only defuses the overflow. For this
    /// remote terminal the SENDER is the host PTY, whose output is bounded by what the shell
    /// produces, so an inflated window is not itself a socket-monopolisation lever, and the bounded
    /// queue bounds host memory regardless.
    pub const fn adjust(&mut self, bytes_to_add: i64) {
        if bytes_to_add <= 0 {
            return;
        }
        self.remaining = self.remaining.saturating_add(bytes_to_add);
    }

    /// Whether the window is exhausted — no credit to send even a single byte.
    #[must_use]
    pub const fn is_blocked(&self) -> bool {
        self.remaining <= 0
    }
}

/// Receiver-side accounting for one direction of one channel: how many bytes the receiver has
/// delivered upward since it last granted credit, and WHEN to emit a window-adjust.
///
/// The symmetric peer of [`FlowCreditPolicy`]. Emitting on a HALF-WINDOW threshold rather than per
/// byte keeps a window-adjust frame off the wire for every chunk while still keeping the sender's
/// window from draining to zero under a steady stream — the standard amortised-credit trade-off
/// (yamux replenishes past half; RFC 9113 §5.2 and RFC 4254 are equivalent).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReceiveWindowAccountant {
    initial_window: i64,
    pending_credit: i64,
}

impl ReceiveWindowAccountant {
    /// An accountant for a window of `initial_window` bytes, clamped non-negative.
    #[must_use]
    pub const fn new(initial_window: i64) -> Self {
        Self {
            initial_window: if initial_window > 0 { initial_window } else { 0 },
            pending_credit: 0,
        }
    }

    /// Rebuilds an accountant whose two numbers a caller held across a boundary. See
    /// [`FlowCreditPolicy::restored`] for why the state crosses by value.
    #[must_use]
    pub const fn restored(initial_window: i64, pending_credit: i64) -> Self {
        Self {
            initial_window: if initial_window > 0 { initial_window } else { 0 },
            pending_credit: if pending_credit > 0 { pending_credit } else { 0 },
        }
    }

    /// The receive window size — the same value the sender was told to use as its initial send
    /// window.
    #[must_use]
    pub const fn initial_window(&self) -> i64 {
        self.initial_window
    }

    /// Bytes delivered upward but NOT yet granted back to the sender. Reset to 0 on each grant.
    #[must_use]
    pub const fn pending_credit(&self) -> i64 {
        self.pending_credit
    }

    /// The half-window replenish threshold. At least 1 for any positive window, so a tiny window
    /// still makes progress; [`i64::MAX`] for a non-positive one, which never grants.
    #[must_use]
    pub const fn threshold(&self) -> i64 {
        if self.initial_window <= 0 {
            return i64::MAX;
        }
        let half = half(self.initial_window);
        if half > 1 { half } else { 1 }
    }

    /// Records that `bytes` were consumed and returns the credit to GRANT back right now, or `None`
    /// when the half-window threshold has not been crossed (accumulate and wait).
    ///
    /// All-or-nothing per crossing: the WHOLE accumulated credit is granted and reset, so the
    /// sender's window is topped back up to its full size. A zero or negative consume grants
    /// nothing, and so does a non-positive window.
    pub const fn consume(&mut self, bytes: i64) -> Option<i64> {
        if self.initial_window <= 0 {
            return None;
        }
        let took = if bytes > 0 { bytes } else { 0 };
        self.pending_credit = self.pending_credit.saturating_add(took);
        if self.pending_credit < self.threshold() {
            return None;
        }
        let grant = self.pending_credit;
        self.pending_credit = 0;
        Some(grant)
    }
}

/// Admit / backpressure decision for a BOUNDED per-channel producer queue.
///
/// The decider behind the host's PTY-read backpressure: the per-channel relay reads the PTY into a
/// queue and drains it onto the channel's send window. Without a bound the per-channel credit
/// window just moves the unboundedness one hop upstream — a `yes | head -c 50M` flood would be
/// buffered whole in the host's memory instead of on the socket. Bounding the queue and pausing the
/// PTY read when it is full backpressures the flood all the way to the producer (the kernel's PTY
/// buffer), exactly as a bounded channel would.
///
/// Owns only the byte accounting and the pause/resume DECISION — no IO, no clock, no queue storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoundedQueuePolicy {
    capacity: i64,
    outstanding: i64,
}

impl BoundedQueuePolicy {
    /// A queue policy with `capacity` bytes of buffering, clamped non-negative.
    #[must_use]
    pub const fn new(capacity: i64) -> Self {
        Self {
            capacity: if capacity > 0 { capacity } else { 0 },
            outstanding: 0,
        }
    }

    /// Rebuilds a queue policy whose two numbers a caller held across a boundary. See
    /// [`FlowCreditPolicy::restored`] for why the state crosses by value.
    #[must_use]
    pub const fn restored(capacity: i64, outstanding: i64) -> Self {
        Self {
            capacity: if capacity > 0 { capacity } else { 0 },
            outstanding: if outstanding > 0 { outstanding } else { 0 },
        }
    }

    /// The high-water mark: once outstanding bytes reach this, the producer must PAUSE.
    #[must_use]
    pub const fn capacity(&self) -> i64 {
        self.capacity
    }

    /// Bytes currently enqueued and not yet sent. Never negative.
    #[must_use]
    pub const fn outstanding(&self) -> i64 {
        self.outstanding
    }

    /// Re-sizes the high-water mark IN PLACE, preserving `outstanding`.
    ///
    /// This is the attached ↔ detached gate: 64 KiB is a LATENCY bound while a client is consuming;
    /// with no client the bound is capacity for "output while away", so a pane's agent keeps
    /// running instead of stalling on a full PTY. The caller re-derives
    /// [`is_full`](Self::is_full) after this.
    pub const fn set_capacity(&mut self, new_capacity: i64) {
        self.capacity = if new_capacity > 0 { new_capacity } else { 0 };
    }

    /// Whether the producer should be PAUSED right now.
    #[must_use]
    pub const fn is_full(&self) -> bool {
        self.outstanding >= self.capacity
    }

    /// Records that `bytes` were enqueued. Returns `true` if the producer should pause AFTER this
    /// enqueue. A zero or negative enqueue admits nothing.
    pub const fn enqueue(&mut self, bytes: i64) -> bool {
        let took = if bytes > 0 { bytes } else { 0 };
        self.outstanding = self.outstanding.saturating_add(took);
        self.is_full()
    }

    /// Records that `bytes` were dequeued (sent). Returns `true` if the queue has now drained below
    /// capacity and a PAUSED producer should RESUME.
    ///
    /// Clamps outstanding at 0, so a double-dequeue can never drive the accounting negative.
    pub const fn dequeue(&mut self, bytes: i64) -> bool {
        let was_full = self.is_full();
        let gave = if bytes > 0 { bytes } else { 0 };
        let left = self.outstanding - gave;
        self.outstanding = if left > 0 { left } else { 0 };
        was_full && !self.is_full()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BoundedQueuePolicy, ConsumeResult, FlowCreditPolicy, MuxFlowControl, ReceiveWindowAccountant,
    };

    // --- FlowCreditPolicy ------------------------------------------------------------------- //

    #[test]
    fn consuming_is_all_or_nothing() {
        let mut window = FlowCreditPolicy::new(100);
        assert_eq!(window.consume(60), ConsumeResult::Allowed(40));
        assert_eq!(window.consume(41), ConsumeResult::Insufficient(40));
        assert_eq!(window.remaining(), 40, "a refused send consumes nothing");
        assert_eq!(window.consume(40), ConsumeResult::Allowed(0));
        assert!(window.is_blocked());
    }

    #[test]
    fn a_non_positive_request_is_allowed_and_consumes_nothing() {
        let mut window = FlowCreditPolicy::new(10);
        assert_eq!(window.consume(0), ConsumeResult::Allowed(10));
        assert_eq!(window.consume(-5), ConsumeResult::Allowed(10));
    }

    #[test]
    fn an_adjust_can_grow_the_window_past_its_initial_size() {
        // SSH windows may legitimately exceed the starting reference. Clamping here would throttle
        // a peer that is entitled to more credit than it started with.
        let mut window = FlowCreditPolicy::new(100);
        window.adjust(500);
        assert_eq!(window.remaining(), 600);
        assert_eq!(window.initial_window(), 100);
    }

    #[test]
    fn a_hostile_run_of_grants_saturates_rather_than_overflowing() {
        let mut window = FlowCreditPolicy::new(1);
        for _ in 0..8 {
            window.adjust(i64::MAX);
        }
        assert_eq!(window.remaining(), i64::MAX);
        window.adjust(-1);
        assert_eq!(window.remaining(), i64::MAX, "a negative grant is ignored");
    }

    #[test]
    fn a_blocked_window_unblocks_on_replenish() {
        let mut window = FlowCreditPolicy::new(8);
        assert_eq!(window.consume(8), ConsumeResult::Allowed(0));
        assert!(window.is_blocked());
        window.adjust(4);
        assert!(!window.is_blocked());
        assert_eq!(window.consume(4), ConsumeResult::Allowed(0));
    }

    #[test]
    fn a_negative_initial_window_is_an_empty_one_not_a_negative_one() {
        let window = FlowCreditPolicy::new(-1);
        assert_eq!(window.remaining(), 0);
        assert!(window.is_blocked());
    }

    // --- ReceiveWindowAccountant ------------------------------------------------------------ //

    #[test]
    fn credit_is_granted_whole_once_the_half_window_is_crossed() {
        let mut rx = ReceiveWindowAccountant::new(1000);
        assert_eq!(rx.threshold(), 500);
        assert_eq!(rx.consume(499), None, "below the threshold, accumulate");
        assert_eq!(rx.consume(1), Some(500), "the WHOLE accumulation is granted");
        assert_eq!(rx.pending_credit(), 0);
    }

    #[test]
    fn one_big_consume_grants_all_of_it_not_just_the_threshold() {
        let mut rx = ReceiveWindowAccountant::new(1000);
        assert_eq!(rx.consume(900), Some(900));
    }

    #[test]
    fn a_tiny_window_still_makes_progress() {
        // A threshold that rounded to 0 would grant on every byte; one that never fired would stall.
        let mut rx = ReceiveWindowAccountant::new(1);
        assert_eq!(rx.threshold(), 1);
        assert_eq!(rx.consume(1), Some(1));
    }

    #[test]
    fn a_zero_window_never_grants() {
        let mut rx = ReceiveWindowAccountant::new(0);
        assert_eq!(rx.threshold(), i64::MAX);
        assert_eq!(rx.consume(1_000_000), None);
        assert_eq!(rx.pending_credit(), 0, "and accumulates nothing either");
    }

    #[test]
    fn a_non_positive_consume_grants_nothing() {
        let mut rx = ReceiveWindowAccountant::new(10);
        assert_eq!(rx.consume(0), None);
        assert_eq!(rx.consume(-9), None);
        assert_eq!(rx.pending_credit(), 0);
    }

    // --- BoundedQueuePolicy ----------------------------------------------------------------- //

    #[test]
    fn the_producer_pauses_at_capacity_and_resumes_on_the_first_drain() {
        let mut queue = BoundedQueuePolicy::new(100);
        assert!(!queue.enqueue(60));
        assert!(queue.enqueue(40), "reaching capacity pauses the producer");
        assert!(queue.is_full());
        assert!(queue.dequeue(1), "the first byte out resumes it");
        assert!(!queue.dequeue(1), "and a later drain does not re-signal");
    }

    #[test]
    fn a_double_dequeue_cannot_drive_the_accounting_negative() {
        let mut queue = BoundedQueuePolicy::new(100);
        queue.enqueue(10);
        queue.dequeue(10);
        queue.dequeue(10);
        assert_eq!(queue.outstanding(), 0);
    }

    #[test]
    fn resizing_preserves_outstanding_bytes() {
        // The attached → detached gate: the bytes already queued do not move, only the bound.
        let mut queue = BoundedQueuePolicy::new(100);
        queue.enqueue(100);
        assert!(queue.is_full());
        queue.set_capacity(1_000);
        assert_eq!(queue.outstanding(), 100);
        assert!(!queue.is_full(), "the same bytes are no longer over the bound");
        queue.set_capacity(-1);
        assert_eq!(queue.capacity(), 0);
        assert!(queue.is_full());
    }

    #[test]
    fn a_zero_capacity_queue_is_always_full() {
        let mut queue = BoundedQueuePolicy::new(0);
        assert!(queue.is_full());
        assert!(queue.enqueue(0));
    }

    // --- MuxFlowControl --------------------------------------------------------------------- //

    #[test]
    fn every_frame_cap_stays_inside_the_credit_progress_invariant() {
        // The invariant the whole file exists for: a windowed inner frame's WIRE size must stay at
        // or below window/2, or a sender parks against a receiver that can never re-grant. The
        // 16-byte margin covers the 13-byte output header, so the check is on payload + margin.
        let half_window = super::half(MuxFlowControl::initial_window_bytes());
        assert!(MuxFlowControl::max_output_frame_payload_bytes() + 16 <= half_window);
        assert!(MuxFlowControl::max_data_message_payload_bytes() + 16 <= half_window);
    }

    #[test]
    fn the_defaults_are_the_shipped_numbers() {
        // These are read by BOTH ends without negotiation, so a silent drift is a stalled channel
        // rather than a failed test somewhere visible.
        assert_eq!(MuxFlowControl::initial_window_bytes(), 64 * 1024);
        assert_eq!(MuxFlowControl::host_queue_capacity_bytes(), 64 * 1024);
        assert_eq!(
            MuxFlowControl::detached_host_queue_capacity_bytes(),
            64 * 1024 * 1024
        );
        assert_eq!(MuxFlowControl::host_merge_cap_bytes(), 32 * 1024);
        assert_eq!(MuxFlowControl::max_data_message_payload_bytes(), 16 * 1024);
        assert_eq!(MuxFlowControl::max_output_frame_payload_bytes(), 32 * 1024 - 16);
        assert_eq!(MuxFlowControl::MAX_CHANNELS_PER_CONNECTION, 256);
    }

    #[test]
    fn an_out_of_range_or_unparseable_override_falls_back_to_the_default() {
        // The env seam is tested through the function rather than by setting a variable: these
        // constants are read once per process, and `set_var` is unsound beside other threads.
        assert_eq!(super::env_int("SLOPDESK_MUX_WINDOW_ABSENT", 7, 1, 10), 7);
    }

    #[test]
    fn the_merge_cap_and_the_window_can_never_be_tuned_into_a_deadlock() {
        // Both knobs are independently tunable, so the effective cap has to be the cross-clamp
        // rather than either raw value. A 16 KiB window with a 128 KiB merge cap is the worst pair
        // the bounds allow.
        let window: i64 = 16 * 1024;
        let merge: i64 = 128 * 1024;
        let effective = merge.min(super::half(window) - 16);
        assert!(effective + 16 <= super::half(window));
    }
}
