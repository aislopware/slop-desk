//! The flow-control CONSTANTS, in C — the one half of this module that still has a foreign caller.
//!
//! `rust/slopdesk-wire`'s `mux::flow` owns the arithmetic. This is the door.
//!
//! ## What stood here, and why it went
//! Three by-value policies and twelve entry points over them: the sender's window
//! (`SlopDeskFlowCredit`), the receiver's replenish decision (`SlopDeskReceiveWindow`) and the
//! host's bounded producer queue (`SlopDeskBoundedQueue`). Every one of them crossed for the same
//! reason and no other — the `SubChannel` running the policy was Swift while the policy itself was
//! Rust's, so the two `i64`s had to make a round trip per frame per direction. `docs/63` G.3 put
//! the connection in Rust: `slopdesk_clientnet`'s `SubChannel` owns all three in-process now, and
//! state that never leaves the crate has nothing to marshal. `docs/55` §4b calls that the
//! retirement criterion — a door whose far side went away.
//!
//! ## Why the constant is a different question
//! [`slopdesk_mux_flow_constant`] is not a state machine; it is the seven numbers the whole mux is
//! sized from, read from the environment once and then fixed. Its callers sit OUTSIDE the mux and
//! outlive it — `ConnectGate.swift:51` bounds an input batch by index 1, and
//! `ReplayBufferTests.swift:611,641` asserts the window/2 progress invariant with index 5 — both
//! through `MuxFlowControl`, which `docs/63` G.3 re-homes onto the surviving face rather than
//! re-typing. A constant transcribed where a door already exists is `docs/55` §8's own shape, so
//! this half stays even though every policy around it left.

use slopdesk_wire::mux::MuxFlowControl;

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

// The host PTY-read backpressure GATE has no door here, and `docs/60` F.9 is why.
//
// It crossed by value — five scalars naming the bounded queue's high-water mark, its outstanding
// bytes, the fan-out backlog, the replay buffer's own verdict and what the caller last applied —
// with five mutators over it and one shared `settle` that rebuilt `PausableQueueGate` from the
// struct, folded, and wrote the fields back. All of that existed for ONE property: hostd applied
// the pause while holding the lock that guarded the struct, so the state had to live somewhere that
// lock already covered, and a handle would have put it behind a pointer the lock said nothing
// about. A Swift host with a Rust rule has no other shape available.
//
// `rust/slopdesk-hostsession` holds `PausableQueueGate` itself now, under its own lock, so the
// rebuild-fold-writeback round trip is a plain method call and there is nothing to marshal.

#[cfg(test)]
mod tests {
    use super::slopdesk_mux_flow_constant;

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
}
