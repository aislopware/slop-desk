//! Waiting on a framework completion handler, from the thread that asked for it.
//!
//! Every `ScreenCaptureKit` lifecycle call answers through a block on one of the framework's own
//! queues. This is the one place that turns that back into a return value, so no other module in
//! the crate has to know it was ever asynchronous.
//!
//! ## Two things make the wait safe, and neither is Rust's to check
//! The handler never runs on the caller's thread — `ScreenCaptureKit` dispatches it to a queue of
//! its own — so a caller blocking here cannot be the thread the answer is waiting for. And the
//! value crossing between them is an `objc2` `Retained`, whose reference count is maintained
//! atomically by the Objective-C runtime; the lock and its condition variable supply the
//! happens-before that makes the object's own fields safe to read afterwards.
//!
//! ## The wait is bounded on purpose
//! A daemon that blocks forever on a framework that never answers is a hang with no operator-
//! visible cause. Every wait here gives up after [`WAIT_LIMIT`] and reports nothing, which the
//! callers turn into a status their own caller can log and recover from. The limit is far past any
//! real answer — a shareable-content query is milliseconds and a capture start about a tenth of a
//! second — so reaching it means the framework is wedged, not slow.

use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

/// How long a caller waits for a framework handler before giving up. Two orders of magnitude past
/// the slowest of these calls; see the module note.
pub(crate) const WAIT_LIMIT: Duration = Duration::from_secs(10);

/// A slot the framework's thread fills and the asking thread takes.
pub(crate) struct Handoff<T> {
    slot: Mutex<Option<T>>,
    ready: Condvar,
}

impl<T> Handoff<T> {
    /// A fresh empty slot, shared so a completion block can hold one end of it.
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            slot: Mutex::new(None),
            ready: Condvar::new(),
        })
    }

    /// Fills the slot and wakes the waiter. A second delivery overwrites the first, which cannot
    /// happen with the handlers here — each is documented to fire once — and would be the framework
    /// misbehaving rather than something to encode a policy about.
    pub(crate) fn deliver(&self, value: T) {
        if let Ok(mut slot) = self.slot.lock() {
            *slot = Some(value);
        }
        self.ready.notify_all();
    }

    /// Waits for the slot to be filled and takes what is in it, or answers `None` when the wait ran
    /// out or the lock was poisoned by a panicking handler.
    pub(crate) fn take(&self) -> Option<T> {
        let Ok(mut slot) = self.slot.lock() else {
            return None;
        };
        while slot.is_none() {
            let Ok((next, timing)) = self.ready.wait_timeout(slot, WAIT_LIMIT) else {
                return None;
            };
            slot = next;
            if timing.timed_out() {
                return slot.take();
            }
        }
        slot.take()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::Handoff;

    /// The ordinary shape: one thread waits, another delivers, and the waiter gets the value.
    #[test]
    fn a_value_delivered_from_another_thread_is_what_the_waiter_takes() {
        let handoff = Handoff::<u32>::new();
        let filler = Arc::clone(&handoff);
        let worker = thread::spawn(move || {
            thread::sleep(Duration::from_millis(10));
            filler.deliver(7);
        });
        assert_eq!(handoff.take(), Some(7));
        assert!(worker.join().is_ok());
    }

    /// A delivery that has ALREADY happened is taken without waiting at all — the handler racing
    /// ahead of the waiter is the common case for a fast query, not an error.
    #[test]
    fn a_delivery_that_arrived_first_is_taken_without_waiting() {
        let handoff = Handoff::<&str>::new();
        handoff.deliver("early");
        let started = Instant::now();
        assert_eq!(handoff.take(), Some("early"));
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "no wait for a filled slot"
        );
    }

    /// The slot empties on take, so a second take on a one-shot handler answers nothing rather
    /// than the same value twice.
    #[test]
    fn taking_empties_the_slot() {
        let handoff = Handoff::<u8>::new();
        handoff.deliver(1);
        assert_eq!(handoff.take(), Some(1));
        // A second take would block for the full limit, so ask the slot directly instead.
        assert!(handoff.slot.lock().is_ok_and(|slot| slot.is_none()));
    }
}
