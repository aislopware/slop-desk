import Foundation

/// Bounded, ordered hand-off between a dedicated blocking reader thread (stdin) and a single
/// async consumer (the input-sender task). Replaces an unbounded `AsyncStream` on the CLI
/// stdin→`sendInput` relay: when the consumer parks in the mux credit window (half-open link,
/// wifi flap), the producer must stop draining the upstream pipe instead of buffering it —
/// stdin is user input and may never be silently dropped, so the bound is *blocking*
/// backpressure, not a lossy cap.
///
/// Contract:
/// - `enqueue` BLOCKS the calling thread while `queuedByteCount >= capacityBytes` (the caller
///   is a dedicated `Thread`, not a cooperative-pool thread, so blocking it is the correct
///   POSIX backpressure: the upstream pipe writer stalls in `write(2)`).
/// - Bytes are delivered to `next()` in exact enqueue order, never dropped while live.
/// - `finish()` unblocks a parked producer (its `enqueue` returns `false`) and, once the queue
///   drains, ends the consumer (`next()` returns `nil`). Chunks queued before `finish()` are
///   still delivered — the disconnect-key path yields a final partial chunk then finishes.
/// - Single consumer. `next()` is cancellation-aware (a cancelled sender task resumes `nil`).
public final class BoundedInputPipe: @unchecked Sendable {
    private let cond = NSCondition()
    // FIFO with a head index so drain is O(1) amortized (removeFirst-per-chunk is the known
    // O(n²) trap; the queue stays small — cap/chunk — but keep the pattern anyway).
    private var queue: [Data] = []
    private var head = 0
    private var queuedBytes = 0
    private var finished = false
    private var consumerWaiter: CheckedContinuation<Data?, Never>?

    public let capacityBytes: Int

    public init(capacityBytes: Int) {
        precondition(capacityBytes > 0, "capacityBytes must be positive")
        self.capacityBytes = capacityBytes
    }

    /// Bytes currently buffered (test / diagnostics seam).
    public var queuedByteCount: Int {
        cond.lock()
        defer { cond.unlock() }
        return queuedBytes
    }

    /// Producer side (dedicated blocking thread). Blocks while the pipe is at capacity.
    /// Returns `false` if the pipe finished (shutdown) — the chunk was not accepted.
    @discardableResult
    public func enqueue(_ data: Data) -> Bool {
        cond.lock()
        // Park while at capacity: this is the whole point — the reader thread stops draining
        // the upstream pipe, so the pipe writer stalls in write(2). Admit an oversized single
        // chunk into an EMPTY pipe (queuedBytes == 0) so a chunk larger than the cap can never
        // deadlock (the CLI reads ≤ 4 KiB, far below any sane cap).
        while !finished, queuedBytes > 0, queuedBytes + data.count > capacityBytes {
            cond.wait()
        }
        if finished {
            cond.unlock()
            return false
        }
        // Hand a chunk straight to a parked consumer — it is consumed immediately, so it
        // never counts against the buffer.
        if let waiter = consumerWaiter, head >= queue.count {
            consumerWaiter = nil
            cond.unlock()
            waiter.resume(returning: data)
            return true
        }
        queue.append(data)
        queuedBytes += data.count
        cond.unlock()
        return true
    }

    /// Consumer side (single async task). Returns the next chunk in enqueue order, or `nil`
    /// once the pipe finished and drained (or the consuming task was cancelled).
    public func next() async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                cond.lock()
                if head < queue.count {
                    let chunk = queue[head]
                    head += 1
                    queuedBytes -= chunk.count
                    if head >= 64 || head >= queue.count {
                        queue.removeFirst(head)
                        head = 0
                    }
                    cond.broadcast() // wake a producer parked on the capacity bound
                    cond.unlock()
                    cont.resume(returning: chunk)
                } else if finished {
                    cond.unlock()
                    cont.resume(returning: nil)
                } else {
                    consumerWaiter = cont
                    cond.unlock()
                }
            }
        } onCancel: {
            cond.lock()
            let waiter = consumerWaiter
            consumerWaiter = nil
            cond.unlock()
            waiter?.resume(returning: nil)
        }
    }

    /// End of input (stdin EOF / disconnect key / shutdown). Unblocks a parked producer and
    /// a parked consumer; already-queued chunks still drain before `next()` returns `nil`.
    public func finish() {
        cond.lock()
        finished = true
        let waiter = consumerWaiter
        consumerWaiter = nil
        cond.broadcast()
        cond.unlock()
        waiter?.resume(returning: nil)
    }
}
