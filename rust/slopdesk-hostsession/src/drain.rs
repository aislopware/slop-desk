//! The pane's ONE outbound drain: the only thread that sequences a frame or ships an exit.
//!
//! Serial by construction, and that is the ordering guarantee the whole output path rests on. The
//! FIFO decides what a frame IS (merged, split, or the exit barrier that never coalesces) and this
//! thread decides nothing except who receives it — so per-channel wire order is this thread's
//! order, and nothing downstream needs a sequence number to restore it.
//!
//! ## Drain until empty before re-parking
//!
//! One wake can cover many appends: the flag lives inside the queue's lock and a producer that
//! finds it already set adds an item without adding a wake. A one-frame-per-wake drain would
//! therefore strand backlog. The loop empties the queue, then parks.
//!
//! ## Where the copies are, honestly
//!
//! One copy per chunk reaches the ring, because the ring must own what it retains — that is the
//! floor, and it is the same copy the FFI door made. The message the single member receives MOVES
//! the caller's buffer, so the interactive steady state adds nothing on top.
//!
//! A FANNED-OUT frame is different and the difference is worth stating rather than discovering: a
//! [`WireMessage`] owns its `Vec`, so N members mean N copies where the Swift's copy-on-write
//! `Data` meant one. `docs/59` §7's budget is *zero allocations added per chunk* on the path that
//! runs once per 32 KiB forever — the single-member drain — and this satisfies it there. The
//! multi-member path pays a copy per member per frame, which is the price of the message owning its
//! bytes and is bounded by the same eviction rule that bounds everything else about a laggard.
//!
//! ## `dequeue` stays post-send
//!
//! The gate bounds enqueued-not-yet-SENT bytes. Accounting a frame at take-time would let the read
//! loop refill while it is still unsent, which is the backpressure chain silently going slack.

use std::sync::Arc;
use std::time::Duration;

use slopdesk_wire::message::WireMessage;

use crate::shared::{Ready, Shared};

/// How long the exit ladder waits for every member to be handed the exit before giving up.
///
/// Bounded because a dead client must not hold a pane's teardown open. The wait is a condvar, not a
/// poll: the latch that satisfies it is set by the sender threads, so they can wake it directly.
const EXIT_DELIVERY_TIMEOUT: Duration = Duration::from_secs(2);

/// The drain thread's whole life.
pub(crate) fn run(shared: &Arc<Shared>) {
    while shared.await_drainable() {
        while let Some(ready) = shared.take_frame() {
            match ready {
                Ready::Output {
                    bytes,
                    byte_count,
                    control,
                } => ship(shared, bytes, byte_count, &control),
                Ready::Exit { code } => {
                    deliver_exit(shared, code);
                    // Release the exit thread's wait: the code is on the wire (or its window
                    // closed), so `onExit` may now run the teardown that cancels this drain.
                    shared.signal_exit_sent();
                },
            }
        }
    }
}

/// Sequences one frame and hands it to whoever must receive it.
fn ship(shared: &Arc<Shared>, bytes: Vec<u8>, byte_count: usize, control: &[WireMessage]) {
    let sequenced = shared.sequence(&bytes);
    if sequenced.fanned_out {
        let message = WireMessage::Output {
            seq: sequenced.seq,
            bytes,
        };
        for target in &sequenced.targets {
            target.enqueue_data(vec![message.clone()]);
        }
    } else if let Some(target) = sequenced.targets.first() {
        // ONE member: send inline, exactly as a single-subscriber pane always has. The send PARKS
        // on the per-channel credit window, so a flooding channel naturally slows here.
        let message = WireMessage::Output {
            seq: sequenced.seq,
            bytes,
        };
        if target.data.send(&message).is_ok() {
            shared.note_sent(target.id, sequenced.seq);
        }
    }
    // An EMPTY set drops the frame — exactly as a send on the finished pair a departed client left
    // behind did — INCLUDING the dequeue, without which the gate would strand bytes and wedge the
    // read loop for a pane nobody is watching.
    shared.dequeue_accounted(byte_count);
    // Sniffed control goes to the control senders: the data drain never waits on a control socket,
    // so a stalled control link cannot freeze data.
    if !control.is_empty() {
        for target in &sequenced.targets {
            target.enqueue_control(control.to_vec());
        }
    }
}

/// Ships the pane's exit code, then waits — bounded — for it to have been handed over.
fn deliver_exit(shared: &Arc<Shared>, code: i32) {
    let (fanned_out, targets) = shared.hand_off_exit();
    if !fanned_out {
        if let Some(target) = targets.first() {
            drop(target.data.send(&WireMessage::Exit { code }));
            shared.mark_exit_delivered(target.id);
        }
        return;
    }
    for target in &targets {
        target.enqueue_data(vec![WireMessage::Exit { code }]);
    }
    shared.await_exit_delivery(&targets, EXIT_DELIVERY_TIMEOUT);
}
