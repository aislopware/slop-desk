//! Pure admit / backpressure decision for a BOUNDED per-channel producer queue — a port
//! of Swift `AislopdeskProtocol.BoundedQueuePolicy`.
//!
//! The decider behind the host PTY-read backpressure: the per-channel relay reads the PTY
//! into a queue and drains it onto the channel's send window. Without a bound, the
//! per-channel credit window just moves the unboundedness one hop upstream. The fix is to
//! BOUND the queue and pause the PTY read when full, so a flood backpressures all the way
//! to the producer (the kernel's PTY buffer). This owns only the byte-accounting +
//! admit/pause/resume DECISION — no IO, no clock, no actual queue storage.

/// Byte-accounting + pause/resume decision for a bounded producer queue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoundedQueuePolicy {
    /// The high-water mark in bytes: once outstanding bytes reach this, the producer pauses.
    capacity: i64,
    /// Bytes currently enqueued and not yet sent. Never negative.
    outstanding: i64,
}

impl BoundedQueuePolicy {
    /// Creates a queue policy with `capacity` bytes of buffering (clamped non-negative).
    #[must_use]
    pub fn new(capacity: i64) -> Self {
        Self {
            capacity: capacity.max(0),
            outstanding: 0,
        }
    }

    /// The high-water mark in bytes.
    #[must_use]
    pub const fn capacity(&self) -> i64 {
        self.capacity
    }

    /// Bytes currently enqueued and not yet sent.
    #[must_use]
    pub const fn outstanding(&self) -> i64 {
        self.outstanding
    }

    /// Whether the producer should be PAUSED right now (queue at/over capacity).
    #[must_use]
    pub const fn is_full(&self) -> bool {
        self.outstanding >= self.capacity
    }

    /// Records that `bytes` were enqueued. Returns `true` if the queue is now full and the
    /// producer should pause AFTER this enqueue. A zero/negative enqueue admits nothing.
    pub fn enqueue(&mut self, bytes: i64) -> bool {
        self.outstanding += bytes.max(0);
        self.is_full()
    }

    /// Records that `bytes` were dequeued (sent). Returns `true` if the queue has now
    /// drained below capacity and a PAUSED producer should RESUME. Clamps outstanding at 0
    /// so a double-dequeue can never drive accounting negative.
    pub fn dequeue(&mut self, bytes: i64) -> bool {
        let was_full = self.is_full();
        self.outstanding = (self.outstanding - bytes.max(0)).max(0);
        was_full && !self.is_full()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enqueue_below_capacity_does_not_pause() {
        let mut q = BoundedQueuePolicy::new(1000);
        assert!(!q.enqueue(300));
        assert!(!q.enqueue(699), "999 < 1000 → still not full");
        assert_eq!(q.outstanding(), 999);
        assert!(!q.is_full());
    }

    #[test]
    fn enqueue_at_or_over_capacity_pauses() {
        let mut q = BoundedQueuePolicy::new(1000);
        assert!(!q.enqueue(900));
        assert!(q.enqueue(100), "reaching capacity exactly → pause");
        assert!(q.is_full());
        assert!(q.enqueue(500));
        assert_eq!(q.outstanding(), 1500);
    }

    #[test]
    fn dequeue_resumes_only_when_crossing_back_under_capacity() {
        let mut q = BoundedQueuePolicy::new(1000);
        assert!(q.enqueue(1200), "over capacity → full");
        assert!(!q.dequeue(100), "1100 still ≥ 1000 → stay paused");
        assert!(q.is_full());
        assert!(q.dequeue(200), "900 < 1000 → resume on the crossing");
        assert!(!q.is_full());
        assert!(!q.dequeue(100), "already below capacity → no re-trigger");
    }

    #[test]
    fn dequeue_while_not_full_never_resumes() {
        let mut q = BoundedQueuePolicy::new(1000);
        q.enqueue(500);
        assert!(!q.dequeue(200), "was never full → no resume edge");
        assert_eq!(q.outstanding(), 300);
    }

    #[test]
    fn dequeue_clamps_at_zero() {
        let mut q = BoundedQueuePolicy::new(1000);
        q.enqueue(100);
        q.dequeue(500); // over-dequeue
        assert_eq!(q.outstanding(), 0, "outstanding never goes negative");
        assert!(!q.is_full());
    }

    #[test]
    fn zero_and_negative_amounts_admit_nothing() {
        let mut q = BoundedQueuePolicy::new(1000);
        assert!(!q.enqueue(0));
        assert!(!q.enqueue(-50));
        assert_eq!(q.outstanding(), 0);
    }

    #[test]
    fn negative_capacity_clamps_to_zero_and_is_always_full() {
        let q = BoundedQueuePolicy::new(-100);
        assert_eq!(q.capacity(), 0);
        assert!(q.is_full(), "a zero-capacity queue is full from the start");
    }
}
