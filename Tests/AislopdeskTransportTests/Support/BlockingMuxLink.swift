import Foundation
@testable import AislopdeskTransport

/// A pair of in-memory ``MuxByteLink``s whose `send` BLOCKS (suspends, TCP-style) when the link's
/// in-flight buffer is full and the peer is not draining — unlike ``InMemoryMuxLink`` whose `send`
/// is instantaneous (it `yield`s into an unbounded stream and returns immediately).
///
/// This is the link variant FIX #2 needs: the non-blocking ``InMemoryMuxLink`` can NEVER exhibit
/// the bidirectional-flood credit deadlock (a grant `send` there never blocks), so it cannot tell
/// apart "grant on the flooded DATA link" (deadlocks under back-to-back blocking) from "grant on
/// the fast CONTROL link" (always gets out). `BlockingMuxLink` models real backpressure: when the
/// DATA link is congested in both directions, a writer that tries to emit a frame on it suspends —
/// so if the receiver tried to write the windowAdjust grant INLINE on the flooded DATA receive loop
/// it would block the only task draining inbound DATA, while the peer is symmetrically stuck → the
/// classic credit deadlock. Routing the grant via the (fast-draining) CONTROL link breaks it.
///
/// Model: each direction has a bounded buffer of at most `capacity` un-consumed chunks. `send`
/// appends a chunk; if that pushes the buffer to/over `capacity` the caller SUSPENDS until the
/// consumer (`receiveChunks`) pulls enough to bring it back under `capacity`. The consumer is the
/// mux receive loop, which `await`s `ingest` per chunk — so a receive loop that blocks (e.g. trying
/// to write a grant on a full link) stops pulling, and the peer's `send` backs up. Exactly the
/// shape of a real flooded TCP pair.
///
/// Locking note: all critical sections are SYNCHRONOUS closures via ``locked(_:)`` so an `NSLock`
/// is never held across an `await` (Swift 6 makes `NSLock.unlock()` unavailable in async contexts).
/// A `send`/`receive` decides its next action under the lock, then suspends OUTSIDE it.
final class BlockingMuxLink: MuxByteLink, @unchecked Sendable {
    /// The shared, lock-guarded state for ONE direction (a→b). Both the writer (`send`) and the
    /// reader (the `receiveChunks` task) touch it.
    private final class Pipe: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [Data] = []
        private var readerWaiter: CheckedContinuation<Data?, Never>?
        /// Writers parked because the buffer was full, in FIFO order.
        private var writerWaiters: [CheckedContinuation<Void, Never>] = []
        private var finished = false
        /// When `true`, EVERY `send` parks regardless of buffer space — a test-held gate modelling a
        /// link whose writes cannot complete (a flooded/blocked direction). Closing it lets the test
        /// prove a writer that tries to emit on THIS link (e.g. a grant on a flooded DATA link) blocks.
        private var gateClosed = false
        let capacity: Int

        init(capacity: Int) { self.capacity = max(1, capacity) }

        /// Opens/closes the write gate. Opening wakes every parked writer so they retry.
        func setGateClosed(_ closed: Bool) {
            let waiters: [CheckedContinuation<Void, Never>] = locked {
                gateClosed = closed
                guard !closed else { return [] }
                let w = writerWaiters; writerWaiters.removeAll(); return w
            }
            for w in waiters { w.resume() }
        }

        /// Runs `body` under the lock and returns its result (a SYNCHRONOUS critical section — the
        /// lock is never held across a suspension).
        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body()
        }

        /// The decision a `send` reaches under the lock.
        private enum SendStep {
            case done                                                  // accepted (and possibly handed off)
            case handoff(CheckedContinuation<Data?, Never>, Data)      // accepted + a parked reader to wake
            case park                                                  // buffer full → suspend then retry
        }

        /// Appends `data`; suspends the caller while the buffer is at/over capacity (backpressure).
        func send(_ data: Data) async {
            while true {
                let step: SendStep = locked {
                    if finished { return .done }
                    if gateClosed { return .park }                     // gate forces every send to park
                    guard buffer.count < capacity else { return .park }
                    if let waiter = readerWaiter {
                        // Hand off directly to a parked reader (buffer was empty ⇒ this is the item).
                        readerWaiter = nil
                        return .handoff(waiter, data)
                    }
                    buffer.append(data)
                    return .done
                }
                switch step {
                case .done:
                    return
                case let .handoff(waiter, item):
                    waiter.resume(returning: item)
                    return
                case .park:
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        // Re-check under the lock to avoid a lost wakeup between the decision above and
                        // parking: if a slot freed (or we finished) meanwhile, resume immediately. The
                        // gate keeps us parked even when there is buffer space.
                        let resumeNow: Bool = locked {
                            if finished || (!gateClosed && buffer.count < capacity) { return true }
                            writerWaiters.append(c)
                            return false
                        }
                        if resumeNow { c.resume() }
                    }
                    // loop and retry
                }
            }
        }

        /// Pulls the next chunk, suspending if the buffer is empty. Returns `nil` when finished.
        func receive() async -> Data? {
            // Fast path / park decision under the lock.
            enum RecvStep { case value(Data, CheckedContinuation<Void, Never>?), end, park }
            while true {
                let step: RecvStep = locked {
                    if !buffer.isEmpty {
                        let next = buffer.removeFirst()
                        let writer = writerWaiters.isEmpty ? nil : writerWaiters.removeFirst()
                        return .value(next, writer)
                    }
                    if finished { return .end }
                    return .park
                }
                switch step {
                case let .value(next, writer):
                    writer?.resume()
                    return next
                case .end:
                    return nil
                case .park:
                    // Re-check under the lock to avoid a lost wakeup; if a value is already buffered
                    // take it (and wake a parked writer for the freed slot), else park as the reader.
                    var wakeWriter: CheckedContinuation<Void, Never>?
                    let result: Data? = await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
                        let immediate: Data?? = locked {
                            if !buffer.isEmpty {
                                let next = buffer.removeFirst()
                                wakeWriter = writerWaiters.isEmpty ? nil : writerWaiters.removeFirst()
                                return .some(.some(next))
                            }
                            if finished { return .some(.none) }
                            readerWaiter = c
                            return .none
                        }
                        if let immediate { c.resume(returning: immediate) }
                    }
                    wakeWriter?.resume()
                    // A direct value was handed off (or finished → nil): return it. A `nil` from a
                    // handoff means finished; a `nil` we synthesised on park-with-value can't happen.
                    return result
                }
            }
        }

        func finish() {
            let (reader, writers): (CheckedContinuation<Data?, Never>?, [CheckedContinuation<Void, Never>]) = locked {
                finished = true
                let r = readerWaiter; readerWaiter = nil
                let w = writerWaiters; writerWaiters.removeAll()
                return (r, w)
            }
            reader?.resume(returning: nil)
            for w in writers { w.resume() }
        }
    }

    private let outPipe: Pipe   // this end's send → peer's receive
    private let inPipe: Pipe    // peer's send → this end's receive
    private let chunkStream: AsyncThrowingStream<Data, Error>

    private init(outPipe: Pipe, inPipe: Pipe) {
        self.outPipe = outPipe
        self.inPipe = inPipe
        self.chunkStream = AsyncThrowingStream { continuation in
            let pipe = inPipe
            let task = Task {
                while let chunk = await pipe.receive() {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Builds a connected pair with the given per-direction buffer `capacity` (chunks). A small
    /// capacity makes the blocking/backpressure path easy to hit.
    static func pair(capacity: Int) -> (BlockingMuxLink, BlockingMuxLink) {
        let aToB = Pipe(capacity: capacity)
        let bToA = Pipe(capacity: capacity)
        let a = BlockingMuxLink(outPipe: aToB, inPipe: bToA)
        let b = BlockingMuxLink(outPipe: bToA, inPipe: aToB)
        return (a, b)
    }

    var receiveChunks: AsyncThrowingStream<Data, Error> { chunkStream }

    /// Closes/opens this end's OUTBOUND write gate: while closed, every `send` on this link parks
    /// (modelling a flooded/blocked direction). The test uses it to prove that a writer forced onto
    /// THIS link — e.g. a windowAdjust grant emitted on a flooded DATA link — blocks, whereas the
    /// same grant on the (ungated) CONTROL link gets through.
    func setOutboundGateClosed(_ closed: Bool) {
        outPipe.setGateClosed(closed)
    }

    func send(_ data: Data) async throws {
        await outPipe.send(data)
    }

    func close() async {
        outPipe.finish()
        inPipe.finish()
    }
}
