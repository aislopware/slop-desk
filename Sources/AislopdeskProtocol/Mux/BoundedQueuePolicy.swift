import Foundation

/// Pure admit / backpressure decision for a BOUNDED per-channel producer queue.
///
/// This is the decider behind the host PTY-read backpressure (TCP-mux S2 scope #4): the
/// per-channel relay reads the PTY into a queue and drains it onto the channel's send
/// window. Without a bound, the per-channel credit window just moves the unboundedness
/// one hop upstream — a `yes | head -c 50M` flood is buffered whole in the host's memory
/// instead of on the socket. The fix is to BOUND the queue and pause the PTY read when it
/// is full, so the flood backpressures all the way to the producer (the kernel's PTY
/// buffer), exactly as a bounded channel would.
///
/// `BoundedQueuePolicy` owns only the byte-accounting + the admit/pause/resume DECISION
/// (yamux / HTTP-2 windows backpressure the same way: stop reading the source when the
/// downstream window + buffer are full). No IO, no clock, no actual queue storage — so it
/// is trivially unit-testable in isolation (same discipline as ``FlowCreditPolicy``).
public struct BoundedQueuePolicy: Sendable, Equatable {
    /// The high-water mark in bytes: once outstanding (enqueued-not-yet-sent) bytes reach
    /// this, the producer (PTY read) must PAUSE.
    public let capacity: Int
    /// Bytes currently enqueued and not yet sent. Never negative.
    public private(set) var outstanding: Int

    /// Creates a queue policy with `capacity` bytes of buffering (clamped non-negative).
    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        outstanding = 0
    }

    /// Whether the producer should be PAUSED right now (queue at/over capacity).
    public var isFull: Bool {
        outstanding >= capacity
    }

    /// Records that `bytes` were enqueued. Returns `true` if the queue is now full and the
    /// producer should pause AFTER this enqueue. A zero/negative enqueue admits nothing.
    @discardableResult
    public mutating func enqueue(_ bytes: Int) -> Bool {
        outstanding += max(0, bytes)
        return isFull
    }

    /// Records that `bytes` were dequeued (sent). Returns `true` if the queue has now drained
    /// below capacity and a PAUSED producer should RESUME. Clamps outstanding at 0 so a
    /// double-dequeue can never drive accounting negative.
    @discardableResult
    public mutating func dequeue(_ bytes: Int) -> Bool {
        let wasFull = isFull
        outstanding = max(0, outstanding - max(0, bytes))
        return wasFull && !isFull
    }
}
