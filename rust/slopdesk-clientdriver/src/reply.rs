//! One value, handed from the supervisor thread back to the caller that asked for it.
//!
//! The near side calls `connect` and waits for its verdict, which means a command has to carry a
//! way back. `std::sync::mpsc` in the other direction would work and would allocate a channel per
//! call; a `Mutex<Option<T>>` behind a `Condvar` is the same rendezvous with one allocation and no
//! receiver to leak.
//!
//! A dropped supervisor is a real case — it happens when the driver is being freed while a call is
//! in flight — so [`Reply::wait`] answers `None` rather than parking when the sender goes away
//! without filling it. That is what makes a `Drop` on the near side safe at any moment.

use std::sync::{Condvar, Mutex};

/// A one-shot slot, filled once and read once.
#[derive(Debug)]
pub struct Reply<T> {
    slot: Mutex<Slot<T>>,
    filled: Condvar,
}

#[derive(Debug)]
struct Slot<T> {
    value: Option<T>,
    /// Set when the value arrives OR when the sender is dropped without one. A waiter must be able
    /// to tell "not yet" from "never", and a bare `Option` cannot.
    settled: bool,
}

impl<T> Default for Reply<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Reply<T> {
    /// An empty slot.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            slot: Mutex::new(Slot {
                value: None,
                settled: false,
            }),
            filled: Condvar::new(),
        }
    }

    /// Fills the slot and wakes the waiter. Later calls are ignored.
    pub fn fill(&self, value: T) {
        if let Ok(mut slot) = self.slot.lock()
            && !slot.settled
        {
            slot.value = Some(value);
            slot.settled = true;
        }
        self.filled.notify_all();
    }

    /// Settles the slot with nothing in it — the answer will never come.
    pub fn abandon(&self) {
        if let Ok(mut slot) = self.slot.lock() {
            slot.settled = true;
        }
        self.filled.notify_all();
    }

    /// Waits for the value, or `None` if the slot was abandoned or its lock was poisoned.
    pub fn wait(&self) -> Option<T> {
        let Ok(mut slot) = self.slot.lock() else {
            return None;
        };
        while !slot.settled {
            let Ok(next) = self.filled.wait(slot) else {
                return None;
            };
            slot = next;
        }
        slot.value.take()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;

    use super::Reply;

    /// The ordinary rendezvous: a value posted from another thread reaches the waiter.
    #[test]
    fn a_filled_slot_hands_its_value_over() {
        let reply: Arc<Reply<u32>> = Arc::new(Reply::new());
        let sender = Arc::clone(&reply);
        let filler = thread::spawn(move || sender.fill(7));
        assert_eq!(reply.wait(), Some(7));
        drop(filler.join());
    }

    /// A value already in the slot is taken without parking.
    #[test]
    fn a_value_posted_before_the_wait_is_not_missed() {
        let reply: Reply<u32> = Reply::new();
        reply.fill(3);
        assert_eq!(reply.wait(), Some(3));
    }

    /// The case that makes a `Drop` mid-call safe: an abandoned slot ends the wait rather than
    /// parking on an answer that is never coming.
    #[test]
    fn an_abandoned_slot_answers_nothing_rather_than_parking() {
        let reply: Arc<Reply<u32>> = Arc::new(Reply::new());
        let sender = Arc::clone(&reply);
        let dropper = thread::spawn(move || sender.abandon());
        assert_eq!(reply.wait(), None);
        drop(dropper.join());
    }

    /// A second fill does not overwrite the first: the caller reads the verdict that was decided,
    /// not whichever one raced in last.
    #[test]
    fn the_first_value_wins() {
        let reply: Reply<u32> = Reply::new();
        reply.fill(1);
        reply.fill(2);
        assert_eq!(reply.wait(), Some(1));
    }
}
