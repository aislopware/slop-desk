import Foundation
import SlopDeskVideoProtocol

/// LOSS-TOLERANCE #1 (2026-06-10): a dedicated PACED-SEND lane that decouples wire pacing from the
/// encoder-output pump.
///
/// Measured defect this fixes: `onEncodedFrame` used to `await sendPaced(...)` — the inter-chunk
/// pacing sleeps ran INSIDE the ordered encoder-output pump, so pacing frame N delayed the SEND of
/// frames N+1..N+k. A large recovery IDR paced at a post-backoff ABR rate (gap ceiling 40ms/chunk)
/// serialized over 100s of ms, and the measured result on the real inter-ISP path was send gaps of
/// 28–179ms (179ms ≈ 11 dropped frame slots = the visible khựng). The loss itself is path weather
/// (rate-independent ~1% + multi-second 3–9% bursts); what the host CAN control is not amplifying
/// one lost packet into an 11-frame send hole.
///
/// Design (mirrors the proven `EncodedFrameQueue` + single-consumer pump discipline):
/// - `enqueue` is O(1), lock-guarded, NEVER blocks and never sleeps — the encoder pump stays at
///   encode cadence no matter how slow the wire drain is.
/// - ONE consumer task drains jobs IN ORDER (wire order = encode order, unchanged), applying the
///   same chunked pacing (`gapNanos` per `chunkFragments` chunk) the inline path used.
/// - `flush()` (bye/teardown) bumps a generation: queued jobs are dropped and a mid-pace job aborts
///   at its next chunk boundary — the lane equivalent of sendPaced's `mediaFlowing` re-check.
/// - `close()` ends the consumer for good (session stop).
///
/// Thread-safety: `@unchecked Sendable` + NSLock over the FIFO/generation, the same discipline as
/// `EncodedFrameQueue`/`InboundQueue`. The send closure is the fire-and-forget
/// `VideoDatagramTransport.send` (UDP enqueue, never blocks).
public final class VideoSendLane: @unchecked Sendable {
    /// One frame's worth of wire datagrams plus its pacing parameters, computed by the session
    /// actor at enqueue time (it owns `lastActuatedBitrate`/flags; the lane stays policy-free).
    public struct Job: Sendable {
        public let outgoings: [VideoSendScheduler.Outgoing]
        /// Inter-chunk pacing gap. 0 ⇒ single-shot regardless of size.
        public let gapNanos: UInt64
        /// Chunk size in datagrams; jobs with `outgoings.count <= chunkFragments` send in one shot.
        public let chunkFragments: Int
        /// Sleep BEFORE sending (kfDup second copy time-separation). 0 for normal frames.
        public let leadingDelayNanos: UInt64

        public init(
            outgoings: [VideoSendScheduler.Outgoing],
            gapNanos: UInt64,
            chunkFragments: Int,
            leadingDelayNanos: UInt64 = 0,
        ) {
            self.outgoings = outgoings
            self.gapNanos = gapNanos
            self.chunkFragments = max(1, chunkFragments)
            self.leadingDelayNanos = leadingDelayNanos
        }
    }

    private let lock = NSLock()
    private var fifo: [Job] = []
    private var generation: UInt64 = 0
    private var closed = false
    private var consumer: Task<Void, Never>?
    private var wakeup: AsyncStream<Void>.Continuation?
    private let send: @Sendable (Data, VideoChannel) -> Void

    @preconcurrency
    public init(send: @escaping @Sendable (Data, VideoChannel) -> Void) {
        self.send = send
        let (wakeups, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakeup = continuation
        // .high: every encoded frame crosses this lane on its way to the wire (same rationale as
        // the encoder-output pump's priority).
        consumer = Task(priority: .high) { [weak self] in
            for await _ in wakeups {
                while let (job, gen) = self?.popNext() {
                    await self?.transmit(job, generation: gen)
                }
                if self == nil || self?.isClosed == true { return }
            }
        }
    }

    /// Queued jobs not yet fully sent (the backpressure signal; ≥1 while a job is mid-pace).
    public var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return fifo.count + (transmitting ? 1 : 0)
    }

    private var transmitting = false

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// O(1) append + coalesced wakeup. Never blocks, never sleeps.
    public func enqueue(_ job: Job) {
        lock.lock()
        guard !closed else { lock.unlock()
            return
        }
        fifo.append(job)
        lock.unlock()
        wakeup?.yield()
    }

    /// Sends `outgoings` INLINE on the caller's thread — skipping the consumer Task-wakeup hop — but
    /// ONLY when the lane is fully drained; returns `true` if it sent, `false` if the caller must
    /// ``enqueue(_:)`` instead.
    ///
    /// RANK-2 INPUT LATENCY (2026-06-18): the lane exists to keep PACING sleeps off the encoder pump
    /// (see the type doc). A tiny single-shot delta — the typing-idle keystroke frame — has no sleeps:
    /// the consumer would just `send()` it in a loop. Yet it still pays a Task hop (~0.1–1 ms) to
    /// reach that consumer. When the wire is idle we run that same loop right here and save the hop.
    ///
    /// The idleness test reads `fifo.isEmpty && !transmitting` UNDER THE LOCK. `transmitting` is true
    /// for the WHOLE span a consumer drains a job (set in ``popNext`` before its lock-free send loop,
    /// cleared only once the FIFO empties), so a `false` reading means no consumer send is in flight
    /// AND nothing is queued — the wire is drained, and sending now preserves strict wire order. If
    /// anything is queued or mid-pace we bail to `false`, so a keystroke can never overtake an
    /// earlier, still-draining frame.
    ///
    /// INVARIANT (relied on, mirrors the rest of the lane): producers — this and ``enqueue(_:)`` —
    /// are serialized by the owning session actor, so the FIFO cannot grow between the check and the
    /// send; the consumer never sends with an empty FIFO, so the lock-free send below is exclusive of
    /// the consumer's sends. Multi-chunk/paced jobs and the time-separated dup copies must still take
    /// ``enqueue(_:)`` — they NEED the async sleeps.
    public func trySendInline(_ outgoings: [VideoSendScheduler.Outgoing]) -> Bool {
        lock.lock()
        guard !closed, fifo.isEmpty, !transmitting else {
            lock.unlock()
            return false
        }
        lock.unlock()
        for outgoing in outgoings { send(outgoing.bytes, outgoing.channel) }
        return true
    }

    /// Drops every queued job and aborts a mid-pace job at its next chunk boundary. Call on
    /// bye/media-stop so a dead client's frames are never paced onto the wire.
    public func flush() {
        lock.lock()
        fifo.removeAll(keepingCapacity: true)
        generation &+= 1
        lock.unlock()
    }

    /// Permanently ends the lane (session stop). Idempotent.
    public func close() {
        lock.lock()
        closed = true
        fifo.removeAll(keepingCapacity: false)
        generation &+= 1
        lock.unlock()
        wakeup?.finish()
        wakeup = nil
        consumer?.cancel()
        consumer = nil
    }

    private func popNext() -> (Job, UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !fifo.isEmpty else { transmitting = false
            return nil
        }
        transmitting = true
        return (fifo.removeFirst(), generation)
    }

    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Sends one job with the inline path's chunked pacing on an ABSOLUTE-DEADLINE schedule,
    /// aborting if the lane is flushed/closed at a chunk boundary (the `mediaFlowing` re-check
    /// equivalent).
    ///
    /// DEADLINE PACING (latency audit, 2026-06-11): the original per-gap
    /// `Task.sleep(nanoseconds: gapNanos)` was RELATIVE — Darwin's ~1ms timer quantum turns a
    /// 0.7ms gap request into a 1–2ms actual sleep, and with 6+ gaps per 50KB frame the overshoot
    /// ACCUMULATED to +3–4ms of serialization per frame (and, worse, per-frame VARIANCE that
    /// surfaced as present-cadence jitter at the depth-1 present-on-arrival client). Chunk k's
    /// deadline is now `start + k × gap` on the continuous clock: an oversleep eats into the NEXT
    /// gap instead of pushing the whole schedule right, and a behind-schedule chunk sends
    /// immediately with no sleep (catch-up). Total serialization ≈ theoretical + ONE quantum,
    /// regardless of fragment count; the average wire rate is unchanged.
    private func transmit(_ job: Job, generation gen: UInt64) async {
        if job.leadingDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: job.leadingDelayNanos)
            guard currentGeneration() == gen else { return }
        }
        let outgoings = job.outgoings
        if job.gapNanos == 0 || outgoings.count <= job.chunkFragments {
            for outgoing in outgoings { send(outgoing.bytes, outgoing.channel) }
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        var chunk = 0
        var i = 0
        while i < outgoings.count {
            let end = min(i + job.chunkFragments, outgoings.count)
            var j = i
            while j < end { send(outgoings[j].bytes, outgoings[j].channel)
                j += 1
            }
            i = end
            chunk += 1
            if i < outgoings.count {
                let deadline = start + .nanoseconds(Int64(job.gapNanos) * Int64(chunk))
                if deadline > clock.now {
                    try? await clock.sleep(until: deadline)
                }
                guard currentGeneration() == gen else { return } // flushed/closed mid-pace
            }
        }
    }
}
