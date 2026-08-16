import CSlopDeskFFI

/// Pure admit / backpressure decision for a BOUNDED per-channel producer queue.
///
/// This is the decider behind the host PTY-read backpressure: the per-channel relay reads the PTY
/// into a queue and drains it onto the channel's send window. Without a bound, the per-channel
/// credit window just moves the unboundedness one hop upstream — a `yes | head -c 50M` flood is
/// buffered whole in the host's memory instead of on the socket. The fix is to BOUND the queue and
/// pause the PTY read when it is full, so the flood backpressures all the way to the producer (the
/// kernel's PTY buffer), exactly as a bounded channel would.
///
/// The byte accounting and the pause/resume decision live in `rust/slopdesk-wire`'s `mux::flow`;
/// this crosses by value for the reason ``FlowCreditPolicy`` does. No IO, no clock, no actual queue
/// storage.
public struct BoundedQueuePolicy: Sendable, Equatable {
    /// The two numbers, in the layout the codec reads them in.
    private var state: SlopDeskBoundedQueue

    /// The high-water mark in bytes: once outstanding (enqueued-not-yet-sent) bytes reach
    /// this, the producer (PTY read) must PAUSE.
    public var capacity: Int { Int(state.capacity) }

    /// Bytes currently enqueued and not yet sent. Never negative.
    public var outstanding: Int { Int(state.outstanding) }

    /// Creates a queue policy with `capacity` bytes of buffering (clamped non-negative).
    public init(capacity: Int) {
        state = slopdesk_bounded_queue_new(Int64(capacity))
    }

    /// Re-sizes the high-water mark IN PLACE, preserving `outstanding` (the attached ↔ detached
    /// gate re-sizing: 64 KiB is a LATENCY bound while a client is consuming; with no client the
    /// bound is capacity for "output while away", so a pane's agent keeps running instead of
    /// stalling on a full PTY). The caller re-derives `isFull` after this.
    public mutating func setCapacity(_ newCapacity: Int) {
        slopdesk_bounded_queue_set_capacity(&state, Int64(newCapacity))
    }

    /// Whether the producer should be PAUSED right now (queue at/over capacity).
    public var isFull: Bool {
        slopdesk_bounded_queue_full(state)
    }

    /// Records that `bytes` were enqueued. Returns `true` if the queue is now full and the
    /// producer should pause AFTER this enqueue. A zero/negative enqueue admits nothing.
    @discardableResult
    public mutating func enqueue(_ bytes: Int) -> Bool {
        slopdesk_bounded_queue_enqueue(&state, Int64(bytes))
    }

    /// Records that `bytes` were dequeued (sent). Returns `true` if the queue has now drained
    /// below capacity and a PAUSED producer should RESUME. Clamps outstanding at 0 so a
    /// double-dequeue can never drive accounting negative.
    @discardableResult
    public mutating func dequeue(_ bytes: Int) -> Bool {
        slopdesk_bounded_queue_dequeue(&state, Int64(bytes))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state.capacity == rhs.state.capacity && lhs.state.outstanding == rhs.state.outstanding
    }
}
