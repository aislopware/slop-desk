//! Per-channel credit flow control: the sender's window, the receiver's replenish decision, the
//! host's bounded producer queue, and the constants all three are sized from.
//!
//! `rust/slopdesk-wire`'s `mux::flow` owns the arithmetic. This is the door.
//!
//! ## Why these cross by VALUE and not as handles
//! Each policy is two `i64`s and no allocation, so the state fits in the call: the caller holds the
//! struct, passes a pointer to it, and the entry point reads and writes it in place. A handle would
//! buy nothing here and cost a `new`/`free` pair per channel per direction — [`crate::replay`]'s
//! convention is for state that CANNOT cross, which this is not.

use slopdesk_wire::mux::{
    BoundedQueuePolicy, ConsumeResult, FlowCreditPolicy, MuxFlowControl, PausableQueueGate,
    ReceiveWindowAccountant,
};

/// One direction of one channel's send window.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskFlowCredit {
    /// The window the channel started with — the reference a caller measures consumption against,
    /// never a cap on `remaining`.
    pub initial_window: i64,
    /// Bytes of credit still available to send. Never negative.
    pub remaining: i64,
}

/// What one [`slopdesk_flow_credit_consume`] decided.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskFlowVerdict {
    /// The credit left after the debit when `allowed`, or what is sendable right now when not.
    pub value: i64,
    /// Whether the full request fit. A refusal consumed NOTHING.
    pub allowed: bool,
}

/// One direction of one channel's receive accounting.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskReceiveWindow {
    /// The receive window — the same value the sender was told to use as its initial send window.
    pub initial_window: i64,
    /// Bytes consumed but not yet granted back. Reset to 0 at each grant.
    pub pending_credit: i64,
}

/// A bounded per-channel producer queue's accounting.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskBoundedQueue {
    /// The high-water mark in bytes: at or past it the producer must pause.
    pub capacity: i64,
    /// Bytes enqueued and not yet sent. Never negative.
    pub outstanding: i64,
}

/// Builds a window with `initial_window` bytes of credit, clamped non-negative.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_flow_credit_new(initial_window: i64) -> SlopDeskFlowCredit {
    let policy = FlowCreditPolicy::new(initial_window);
    SlopDeskFlowCredit {
        initial_window: policy.initial_window(),
        remaining: policy.remaining(),
    }
}

/// Attempts to debit `bytes`, all-or-nothing, updating `policy` in place.
///
/// # Safety
/// `policy` must point at one live [`SlopDeskFlowCredit`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_flow_credit_consume(
    policy: *mut SlopDeskFlowCredit,
    bytes: i64,
) -> SlopDeskFlowVerdict {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe {
        let held = *policy;
        let mut inner = FlowCreditPolicy::restored(held.initial_window, held.remaining);
        let verdict = match inner.consume(bytes) {
            ConsumeResult::Allowed(remaining) => {
                SlopDeskFlowVerdict {
                    value: remaining,
                    allowed: true,
                }
            },
            ConsumeResult::Insufficient(available) => {
                SlopDeskFlowVerdict {
                    value: available,
                    allowed: false,
                }
            },
        };
        (*policy).remaining = inner.remaining();
        verdict
    }
}

/// Re-credits the window by `bytes_to_add`, saturating rather than trapping.
///
/// # Safety
/// `policy` must point at one live [`SlopDeskFlowCredit`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_flow_credit_adjust(policy: *mut SlopDeskFlowCredit, bytes_to_add: i64) {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe {
        let held = *policy;
        let mut inner = FlowCreditPolicy::restored(held.initial_window, held.remaining);
        inner.adjust(bytes_to_add);
        (*policy).remaining = inner.remaining();
    }
}

/// Whether the window is exhausted — no credit to send even a single byte.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_flow_credit_blocked(policy: SlopDeskFlowCredit) -> bool {
    FlowCreditPolicy::restored(policy.initial_window, policy.remaining).is_blocked()
}

/// Builds an accountant for a window of `initial_window` bytes, clamped non-negative.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_receive_window_new(initial_window: i64) -> SlopDeskReceiveWindow {
    let inner = ReceiveWindowAccountant::new(initial_window);
    SlopDeskReceiveWindow {
        initial_window: inner.initial_window(),
        pending_credit: inner.pending_credit(),
    }
}

/// The half-window replenish threshold for a window of `initial_window` bytes.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_receive_window_threshold(initial_window: i64) -> i64 {
    ReceiveWindowAccountant::new(initial_window).threshold()
}

/// Records `bytes` consumed and answers the credit to grant back RIGHT NOW, or a negative number
/// when the threshold has not been crossed and the caller should accumulate and wait.
///
/// # Safety
/// `window` must point at one live [`SlopDeskReceiveWindow`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_receive_window_consume(
    window: *mut SlopDeskReceiveWindow,
    bytes: i64,
) -> i64 {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe {
        let held = *window;
        let mut inner = ReceiveWindowAccountant::restored(held.initial_window, held.pending_credit);
        let grant = inner.consume(bytes);
        (*window).pending_credit = inner.pending_credit();
        // A grant is a non-negative byte count, so -1 is unambiguous where an `Option` cannot cross.
        grant.unwrap_or(-1)
    }
}

/// Builds a queue policy with `capacity` bytes of buffering, clamped non-negative.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_bounded_queue_new(capacity: i64) -> SlopDeskBoundedQueue {
    let inner = BoundedQueuePolicy::new(capacity);
    SlopDeskBoundedQueue {
        capacity: inner.capacity(),
        outstanding: inner.outstanding(),
    }
}

/// Re-sizes the high-water mark IN PLACE, preserving `outstanding`.
///
/// # Safety
/// `queue` must point at one live [`SlopDeskBoundedQueue`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_bounded_queue_set_capacity(
    queue: *mut SlopDeskBoundedQueue,
    new_capacity: i64,
) {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe {
        let held = *queue;
        let mut inner = BoundedQueuePolicy::restored(held.capacity, held.outstanding);
        inner.set_capacity(new_capacity);
        (*queue).capacity = inner.capacity();
    }
}

/// Whether the producer should be PAUSED right now — the queue is at or over capacity.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_bounded_queue_full(queue: SlopDeskBoundedQueue) -> bool {
    BoundedQueuePolicy::restored(queue.capacity, queue.outstanding).is_full()
}

/// Records `bytes` enqueued and answers whether the producer should PAUSE afterwards.
///
/// # Safety
/// `queue` must point at one live [`SlopDeskBoundedQueue`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_bounded_queue_enqueue(
    queue: *mut SlopDeskBoundedQueue,
    bytes: i64,
) -> bool {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe {
        let held = *queue;
        let mut inner = BoundedQueuePolicy::restored(held.capacity, held.outstanding);
        let full = inner.enqueue(bytes);
        (*queue).outstanding = inner.outstanding();
        full
    }
}

/// Records `bytes` dequeued and answers whether a PAUSED producer should now RESUME.
///
/// # Safety
/// `queue` must point at one live [`SlopDeskBoundedQueue`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_bounded_queue_dequeue(
    queue: *mut SlopDeskBoundedQueue,
    bytes: i64,
) -> bool {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe {
        let held = *queue;
        let mut inner = BoundedQueuePolicy::restored(held.capacity, held.outstanding);
        let resume = inner.dequeue(bytes);
        (*queue).outstanding = inner.outstanding();
        resume
    }
}

/// The flow-control constants, which are read from the environment ONCE and then fixed.
///
/// `index` selects: 0 the initial window, 1 the input split cap, 2 the host queue bound, 3 the
/// detached host queue bound, 4 the merge cap, 5 the provably-safe output payload cap, 6 the live
/// channel cap. An index with no constant behind it answers 0.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub extern "C" fn slopdesk_mux_flow_constant(index: u32) -> i64 {
    match index {
        0 => MuxFlowControl::initial_window_bytes(),
        1 => MuxFlowControl::max_data_message_payload_bytes(),
        2 => MuxFlowControl::host_queue_capacity_bytes(),
        3 => MuxFlowControl::detached_host_queue_capacity_bytes(),
        4 => MuxFlowControl::host_merge_cap_bytes(),
        5 => MuxFlowControl::max_output_frame_payload_bytes(),
        6 => i64::try_from(MuxFlowControl::MAX_CHANNELS_PER_CONNECTION).unwrap_or(i64::MAX),
        _ => 0,
    }
}

/// The host PTY-read backpressure gate: the bounded queue OR-ed with the replay-buffer and fan-out
/// sources, plus a memory of what the caller last applied.
///
/// Crosses BY VALUE for the reason the three policies above do — five scalars, no allocation — and
/// for one more: hostd applies the pause WHILE HOLDING the lock that guards this struct, so the
/// state has to be somewhere that lock already covers. A handle would put it behind a pointer the
/// lock says nothing about.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskPausableGate {
    /// The high-water mark, in bytes. BOTH the queue and the fan-out backlog are measured against
    /// it, so one re-size moves both sources.
    pub capacity: i64,
    /// Bytes enqueued and not yet sent. Never negative.
    pub outstanding: i64,
    /// Bytes sequenced that not even the FASTEST subscriber has put on the wire.
    pub fanout_backlog: i64,
    /// The replay buffer's own verdict: retained-but-unacked bytes are at the cap, or the channel
    /// is offline.
    pub replay_pause: bool,
    /// What the caller last applied. Written by every mutator below; never set by hand.
    pub applied: bool,
}

/// What one gate mutation decided.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct SlopDeskPauseVerdict {
    /// True when the caller must act. False means the fold decided nothing new — the commonest
    /// case by far, since most enqueues and dequeues cross no threshold.
    pub changed: bool,
    /// The state to apply when `changed`: pause the read loop (`true`) or resume it (`false`).
    /// Meaningless otherwise.
    pub paused: bool,
}

/// Builds an UNPAUSED gate over a queue of `capacity` bytes, both other sources inert.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub const extern "C" fn slopdesk_pausable_gate_new(capacity: i64) -> SlopDeskPausableGate {
    let gate = PausableQueueGate::new(capacity);
    SlopDeskPausableGate {
        capacity: gate.capacity(),
        outstanding: gate.outstanding(),
        fanout_backlog: gate.fanout_backlog(),
        replay_pause: gate.replay_pause(),
        applied: gate.applied(),
    }
}

/// Rebuilds the crate's gate from the caller's struct, applies `mutate`, and writes the new state
/// back in place. The ONE marshalling path all five mutators below share.
fn settle(
    gate: &mut SlopDeskPausableGate,
    mutate: impl FnOnce(&mut PausableQueueGate) -> Option<bool>,
) -> SlopDeskPauseVerdict {
    let mut inner = PausableQueueGate::restored(
        gate.capacity,
        gate.outstanding,
        gate.replay_pause,
        gate.fanout_backlog,
        gate.applied,
    );
    let decided = mutate(&mut inner);
    gate.capacity = inner.capacity();
    gate.outstanding = inner.outstanding();
    gate.fanout_backlog = inner.fanout_backlog();
    gate.replay_pause = inner.replay_pause();
    gate.applied = inner.applied();
    SlopDeskPauseVerdict {
        changed: decided.is_some(),
        paused: decided.unwrap_or(false),
    }
}

/// Accounts `bytes` enqueued and re-folds every source.
///
/// # Safety
/// `gate` must point at one live [`SlopDeskPausableGate`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pausable_gate_enqueue(
    gate: *mut SlopDeskPausableGate,
    bytes: i64,
) -> SlopDeskPauseVerdict {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe { settle(&mut *gate, |inner| inner.enqueue(bytes)) }
}

/// Accounts `bytes` dequeued (sent) and re-folds every source.
///
/// # Safety
/// `gate` must point at one live [`SlopDeskPausableGate`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pausable_gate_dequeue(
    gate: *mut SlopDeskPausableGate,
    bytes: i64,
) -> SlopDeskPauseVerdict {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe { settle(&mut *gate, |inner| inner.dequeue(bytes)) }
}

/// Sets the replay-buffer source and re-folds.
///
/// # Safety
/// `gate` must point at one live [`SlopDeskPausableGate`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pausable_gate_set_replay_pause(
    gate: *mut SlopDeskPausableGate,
    pause: bool,
) -> SlopDeskPauseVerdict {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe { settle(&mut *gate, |inner| inner.set_replay_pause(pause)) }
}

/// Sets the fan-out source — bytes nobody has shipped — and re-folds. `0` makes it inert.
///
/// # Safety
/// `gate` must point at one live [`SlopDeskPausableGate`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pausable_gate_set_fanout_backlog(
    gate: *mut SlopDeskPausableGate,
    bytes: i64,
) -> SlopDeskPauseVerdict {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe { settle(&mut *gate, |inner| inner.set_fanout_backlog(bytes)) }
}

/// Re-sizes the bound — the attached ↔ detached gate — and re-folds.
///
/// # Safety
/// `gate` must point at one live [`SlopDeskPausableGate`] for the call.
#[unsafe(no_mangle)]
#[expect(
    unsafe_code,
    reason = "an exported C entry point is unsafe by definition in edition 2024"
)]
pub unsafe extern "C" fn slopdesk_pausable_gate_set_capacity(
    gate: *mut SlopDeskPausableGate,
    new_capacity: i64,
) -> SlopDeskPauseVerdict {
    // SAFETY: one struct read and one write, neither outliving the call.
    unsafe { settle(&mut *gate, |inner| inner.set_capacity(new_capacity)) }
}

#[cfg(test)]
mod tests {
    #![expect(
        unsafe_code,
        reason = "the tests drive the same C entry points every caller does"
    )]

    use super::{
        slopdesk_bounded_queue_dequeue, slopdesk_bounded_queue_enqueue, slopdesk_bounded_queue_new,
        slopdesk_flow_credit_adjust, slopdesk_flow_credit_consume, slopdesk_flow_credit_new,
        slopdesk_mux_flow_constant, slopdesk_pausable_gate_dequeue, slopdesk_pausable_gate_enqueue,
        slopdesk_pausable_gate_new, slopdesk_pausable_gate_set_capacity,
        slopdesk_pausable_gate_set_fanout_backlog, slopdesk_pausable_gate_set_replay_pause,
        slopdesk_receive_window_consume, slopdesk_receive_window_new, slopdesk_receive_window_threshold,
    };

    /// The window is all-or-nothing and a refusal must leave it untouched — the property every
    /// caller's "wait for credit" branch is built on.
    #[test]
    fn a_refused_debit_consumes_nothing() {
        let mut policy = slopdesk_flow_credit_new(100);
        let verdict = unsafe { slopdesk_flow_credit_consume(&raw mut policy, 60) };
        assert!(verdict.allowed);
        assert_eq!(policy.remaining, 40);

        let verdict = unsafe { slopdesk_flow_credit_consume(&raw mut policy, 60) };
        assert!(!verdict.allowed);
        assert_eq!(verdict.value, 40, "a refusal says what IS sendable");
        assert_eq!(policy.remaining, 40, "a refusal must not debit");

        unsafe { slopdesk_flow_credit_adjust(&raw mut policy, i64::MAX) };
        assert_eq!(
            policy.remaining,
            i64::MAX,
            "a hostile grant saturates, never traps"
        );
    }

    /// The receiver grants the WHOLE accumulation at the crossing, and says so only then.
    #[test]
    fn credit_is_granted_whole_at_the_half_window() {
        let mut window = slopdesk_receive_window_new(100);
        assert_eq!(slopdesk_receive_window_threshold(100), 50);
        assert_eq!(
            unsafe { slopdesk_receive_window_consume(&raw mut window, 49) },
            -1
        );
        assert_eq!(unsafe { slopdesk_receive_window_consume(&raw mut window, 1) }, 50);
        assert_eq!(window.pending_credit, 0);
    }

    /// Pause at the high-water mark, resume on the crossing back — and only on the crossing.
    #[test]
    fn the_queue_pauses_at_the_mark_and_resumes_on_the_way_back() {
        let mut queue = slopdesk_bounded_queue_new(64);
        assert!(!unsafe { slopdesk_bounded_queue_enqueue(&raw mut queue, 32) });
        assert!(unsafe { slopdesk_bounded_queue_enqueue(&raw mut queue, 32) });
        assert!(unsafe { slopdesk_bounded_queue_dequeue(&raw mut queue, 1) });
        assert!(
            !unsafe { slopdesk_bounded_queue_dequeue(&raw mut queue, 1) },
            "resume fires on the crossing, not on every drain",
        );
    }

    /// The progress invariant every windowed frame is sized by, asserted at the door rather than
    /// only inside the crate: an output frame at or above half the window can wedge a pane.
    #[test]
    fn the_output_cap_stays_under_half_the_window() {
        let half = slopdesk_mux_flow_constant(0).div_euclid(2);
        assert!(slopdesk_mux_flow_constant(5) <= half - 16);
        assert!(slopdesk_mux_flow_constant(1) <= half - 16);
        assert_eq!(slopdesk_mux_flow_constant(6), 256);
        assert_eq!(slopdesk_mux_flow_constant(99), 0);
    }

    /// The three sources OR together, and only a CHANGE is reported — the property that makes the
    /// caller's `if verdict.changed { setPaused(verdict.paused) }` idempotent.
    #[test]
    fn the_gate_reports_only_the_crossings() {
        let mut gate = slopdesk_pausable_gate_new(100);
        assert!(!unsafe { slopdesk_pausable_gate_enqueue(&raw mut gate, 50) }.changed);
        let paused = unsafe { slopdesk_pausable_gate_enqueue(&raw mut gate, 50) };
        assert!(paused.changed && paused.paused);
        assert!(!unsafe { slopdesk_pausable_gate_enqueue(&raw mut gate, 50) }.changed);
        assert_eq!(gate.outstanding, 150);

        let resumed = unsafe { slopdesk_pausable_gate_dequeue(&raw mut gate, 51) };
        assert!(resumed.changed && !resumed.paused);
        assert!(!gate.applied, "the struct carries what was applied");
    }

    /// A clear on one source must never resume a loop another source still holds — the lost-wakeup
    /// that froze a pane forever, now unreachable because the fold is one value.
    #[test]
    fn one_source_clearing_cannot_resume_what_another_holds() {
        let mut gate = slopdesk_pausable_gate_new(100);
        assert!(unsafe { slopdesk_pausable_gate_set_replay_pause(&raw mut gate, true) }.paused);
        assert!(!unsafe { slopdesk_pausable_gate_enqueue(&raw mut gate, 200) }.changed);
        assert!(
            !unsafe { slopdesk_pausable_gate_set_replay_pause(&raw mut gate, false) }.changed,
            "the queue is still over bound"
        );
        let resumed = unsafe { slopdesk_pausable_gate_dequeue(&raw mut gate, 200) };
        assert!(resumed.changed && !resumed.paused);
    }

    /// The fan-out source is measured against the SAME capacity, so the detached re-size moves it.
    #[test]
    fn re_sizing_the_bound_moves_the_fanout_source_too() {
        let mut gate = slopdesk_pausable_gate_new(1000);
        assert!(!unsafe { slopdesk_pausable_gate_set_fanout_backlog(&raw mut gate, 999) }.changed);
        assert!(unsafe { slopdesk_pausable_gate_set_fanout_backlog(&raw mut gate, 1000) }.paused);
        let raised = unsafe { slopdesk_pausable_gate_set_capacity(&raw mut gate, 4000) };
        assert!(raised.changed && !raised.paused);
        assert!(unsafe { slopdesk_pausable_gate_set_capacity(&raw mut gate, 500) }.paused);
        assert_eq!(gate.capacity, 500);
    }
}
