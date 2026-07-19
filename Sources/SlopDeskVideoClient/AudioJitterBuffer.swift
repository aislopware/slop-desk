import Foundation
import SlopDeskVideoProtocol
import Synchronization

/// PURE jitter STAGE between the audio decode path (push — the session's serial audio queue) and
/// whatever drains a steady stream of samples. Decoded ~10 ms frames of interleaved Float32
/// enter keyed by their wire `seq`; consumption is either ``pull(into:)`` (the loopback harness /
/// test surface, which zero-fills a shortfall itself) or the producer-side
/// ``drainAvailable(into:)`` that ``AudioPlaybackPump`` uses to feed the lock-free
/// ``AudioSampleRing`` hand-off to the render callback.
///
/// Policy (doc 20, audio channel):
/// - PRIME: silence until ``targetDepthFrames`` frames are buffered, so playback starts with
///   enough slack to absorb ordinary arrival jitter (audio mirror of ``FramePacer``'s priming).
/// - UNDERRUN: the consumer ran dry mid-play → conceal with silence and DROP BACK to priming
///   (re-inflate before playing again). ``pull(into:)`` detects this itself; the pump path
///   signals it via ``noteConsumerStarved()``.
/// - REORDER: frames insert in wrap-aware `seq` order, so a swapped pair of datagrams still
///   plays in order. A `seq` at-or-behind the play frontier (already played, or the head frame
///   has begun playing past it) arrived too late to matter → drop.
/// - HIGH WATER: past ``highWaterFrames`` pending frames the OLDEST is dropped (skip forward —
///   stale audio is worse than a click; audio must never build latency to avoid loss).
///
/// The `seq` space is session-scoped and SHARED with config packets (one counter for all tag-6
/// datagrams), so gaps between pushed frames are normal — the ring plays across them seamlessly.
///
/// ⚠️ NOT thread-safe by itself — a plain value type confined to ONE thread (the session's
/// serial audio queue in the live engine; the loopback's single thread). It stays pure so the
/// policy is headlessly unit-testable (`AudioJitterBufferTests`). The render thread NEVER
/// touches this type — it consumes the ``AudioSampleRing`` the pump fills.
public struct AudioJitterBuffer: Sendable {
    /// Cumulative policy counters (monotonic; diagnostics + test pins).
    public struct Stats: Equatable, Sendable {
        /// Frames accepted into the ring.
        public var framesPushed = 0
        /// Frames dropped for arriving at-or-behind the play frontier.
        public var lateDropped = 0
        /// Frames dropped as duplicates of a pending frame.
        public var duplicateDropped = 0
        /// Oldest-pending frames dropped past the high-water mark.
        public var overflowDropped = 0
        /// Times the ring ran dry mid-play (primed → silence). Priming silence is not an underrun.
        public var underruns = 0
        /// Zero samples emitted (priming + underrun tails).
        public var silenceSamples = 0

        public init() {}
    }

    private struct Block {
        let seq: UInt32
        let samples: [Float]
    }

    /// Interleaved channel count — sizes ``pull(frameCount:)``'s sample count.
    public let channels: Int
    /// Pending frames required before playback starts (≈2 × 10 ms of slack).
    public let targetDepthFrames: Int
    /// Pending-frame cap; past it the oldest pending frame is dropped.
    public let highWaterFrames: Int

    /// Pending + not-yet-reclaimed frames, in wrap-aware `seq` order. The first
    /// ``consumedBlocks`` entries are fully played, awaiting reclaim on the push side.
    private var blocks: [Block] = []
    private var consumedBlocks = 0
    /// Read offset (samples) into the first UNconsumed block (partial-frame pulls).
    private var headSampleOffset = 0
    /// `seq` of the newest frame fully played or overflow-dropped (`nil` ⇒ none yet). A push
    /// at-or-behind it is late.
    private var playFrontier: UInt32?
    /// Whether the ring has filled to ``targetDepthFrames`` and is playing (vs. priming).
    public private(set) var primed = false
    public private(set) var stats = Stats()

    public init(channels: Int, targetDepthFrames: Int = 2, highWaterFrames: Int = 8) {
        self.channels = max(1, channels)
        self.targetDepthFrames = max(1, targetDepthFrames)
        self.highWaterFrames = max(self.targetDepthFrames, highWaterFrames)
    }

    /// Pending (unplayed) frame count — the ring's live depth.
    public var pendingFrames: Int { blocks.count - consumedBlocks }

    /// Samples currently available to pull (partial head accounted).
    public var availableSamples: Int {
        var total = 0
        for i in consumedBlocks..<blocks.count { total += blocks[i].samples.count }
        return total - headSampleOffset
    }

    /// The frontier a push must be strictly ahead of: once the head frame has BEGUN playing,
    /// nothing at-or-behind its `seq` can be inserted (it would play out of order).
    private var effectiveFrontier: UInt32? {
        if headSampleOffset > 0, consumedBlocks < blocks.count { return blocks[consumedBlocks].seq }
        return playFrontier
    }

    /// Offers one decoded frame. Empty sample sets are dropped (a decoder miss, not a frame).
    public mutating func push(seq: UInt32, samples: [Float]) {
        guard !samples.isEmpty else { return }
        // Reclaim render-consumed frames HERE (the decode side) so the render callback never frees.
        if consumedBlocks > 0 {
            blocks.removeFirst(consumedBlocks)
            consumedBlocks = 0
        }
        // Duplicate of a pending frame (UDP re-delivery)?
        for i in consumedBlocks..<blocks.count where blocks[i].seq == seq {
            stats.duplicateDropped += 1
            return
        }
        // Behind (or at) what already played — too late to matter.
        if let frontier = effectiveFrontier, seq.distanceWrapped(from: frontier) <= 0 {
            stats.lateDropped += 1
            return
        }
        // Insert in wrap-aware seq order (walk from the end — in-order arrival appends).
        var idx = blocks.count
        while idx > consumedBlocks, seq.distanceWrapped(from: blocks[idx - 1].seq) < 0 { idx -= 1 }
        blocks.insert(Block(seq: seq, samples: samples), at: idx)
        stats.framesPushed += 1
        // High water: drop the OLDEST pending frames (skip forward). Advancing the frontier past
        // each dropped seq makes a straggling re-send of it a late drop, not a re-insert.
        while blocks.count - consumedBlocks > highWaterFrames {
            let dropped = blocks.removeFirst() // consumedBlocks == 0 (reclaimed above)
            headSampleOffset = 0
            playFrontier = dropped.seq
            stats.overflowDropped += 1
        }
        if !primed, blocks.count - consumedBlocks >= targetDepthFrames { primed = true }
    }

    /// Fills `out` with the next interleaved samples, zero-filling whatever the ring cannot
    /// supply (priming, or a mid-play underrun — which drops back to priming). Allocation- and
    /// free-free. The loopback/test consumption surface; the live engine drains via
    /// ``drainAvailable(into:)`` instead (its silence conceal happens in the render callback).
    public mutating func pull(into out: UnsafeMutableBufferPointer<Float>) {
        guard !out.isEmpty else { return }
        let wrote = primed ? copyAvailable(into: out) : 0
        guard wrote < out.count else { return }
        for i in wrote..<out.count { out[i] = 0 }
        stats.silenceSamples += out.count - wrote
        if primed {
            // Ran dry mid-play: back to priming so playback resumes with full slack, not
            // one-frame-at-a-time crackle.
            stats.underruns += 1
            primed = false
        }
    }

    /// Producer-side drain for the lock-free hand-off ring: copies up to `out.count` of the
    /// samples currently available (primed only) and marks them consumed — no zero-fill and no
    /// underrun re-prime, because running short HERE only means nothing is staged to hand off
    /// (actual consumer starvation is signalled by ``noteConsumerStarved()``). Returns the
    /// samples written. Runs on the push thread, so block reclaim stays a single-thread affair.
    public mutating func drainAvailable(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        guard primed, !out.isEmpty else { return 0 }
        return copyAvailable(into: out)
    }

    /// The hand-off consumer ran the ring dry mid-play (producer-side detection — the render
    /// callback itself only zero-fills): mirror ``pull(into:)``'s underrun policy by dropping
    /// back to priming, so playback resumes with full slack instead of one-frame-at-a-time
    /// crackle. Pending frames stay buffered (they re-count toward the re-prime).
    public mutating func noteConsumerStarved() {
        guard primed else { return }
        stats.underruns += 1
        primed = false
    }

    /// Skips the oldest PENDING frame forward — the depth-bound drop the pump applies when the
    /// combined stage + hand-off depth passes high-water (``push(seq:samples:)``'s own high-water
    /// check sees only staged frames). Same skip-forward semantics as the push-side drop: the
    /// frontier advances past the dropped seq (a straggling re-send becomes a late drop) and a
    /// partially handed-off head is abandoned mid-frame. Never touches consumed-awaiting-reclaim
    /// blocks, and never re-primes — a latency shed is a skip, not an underrun.
    public mutating func dropOldestPending() {
        guard consumedBlocks < blocks.count else { return }
        let dropped = blocks.remove(at: consumedBlocks)
        headSampleOffset = 0
        playFrontier = dropped.seq
        stats.overflowDropped += 1
    }

    /// Copies as many buffered samples as `out` can hold, advancing the consumed marker and the
    /// play frontier as blocks complete. Allocation- and free-free: consumed frames are only
    /// FLAGGED consumed (index advance) and reclaimed by the next ``push(seq:samples:)``.
    private mutating func copyAvailable(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = out.baseAddress else { return 0 }
        var wrote = 0
        while wrote < out.count, consumedBlocks < blocks.count {
            let samples = blocks[consumedBlocks].samples
            let n = min(samples.count - headSampleOffset, out.count - wrote)
            samples.withUnsafeBufferPointer { src in
                // Blocks are never empty (push drops empty sample sets), so a nil base
                // address is unreachable; the guard just keeps the copy total.
                guard let srcBase = src.baseAddress else { return }
                (base + wrote).update(from: srcBase + headSampleOffset, count: n)
            }
            wrote += n
            headSampleOffset += n
            if headSampleOffset == samples.count {
                playFrontier = blocks[consumedBlocks].seq
                consumedBlocks += 1
                headSampleOffset = 0
            }
        }
        return wrote
    }

    /// Convenience pull of `frameCount` interleaved sample-frames (`frameCount × channels`
    /// Floats), silence-filled. Allocates — the test/diagnostic surface (the live engine drains
    /// via ``drainAvailable(into:)``).
    public mutating func pull(frameCount: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, frameCount) * channels)
        out.withUnsafeMutableBufferPointer { pull(into: $0) }
        return out
    }

    /// Drops everything buffered (local disable) and drops back to priming. KEEPS the play
    /// frontier — the tag-6 `seq` is session-scoped monotonic (config packets consume ids too),
    /// so frames arriving after a re-enable are strictly newer and must not be mistaken for
    /// late; stats stay cumulative.
    public mutating func clear() {
        blocks.removeAll()
        consumedBlocks = 0
        headSampleOffset = 0
        primed = false
    }
}

/// Lock-free SPSC hand-off ring between the audio decode side (single producer — the session's
/// serial `audioQueue`) and the output AU's render callback (single consumer — the HAL/RemoteIO
/// real-time thread). Fixed preallocated interleaved-Float32 storage; the indices are MONOTONIC
/// total-sample counters published with acquire/release atomics, so neither side ever takes a
/// lock, allocates, or makes a syscall — a render callback blocking on a mutex held by a
/// preempted pusher is a priority-inversion dropout, the exact failure this type exists to
/// prevent.
///
/// `@unchecked Sendable`: the raw storage is race-free because the counters partition it — the
/// producer writes only `[write, read + capacity)`, the consumer reads only `[read, write)`, and
/// each index is advanced ONLY by its owner AFTER its memcpy completes (release), then observed
/// by the other side (acquire). ⚠️ Lifetime: the owner (``AudioPlaybackEngine``) must stop the
/// AU — `AudioOutputUnitStop` waits out an in-flight render — before releasing this ring, so the
/// callback never touches freed storage.
final class AudioSampleRing: @unchecked Sendable {
    /// Ring capacity in samples (fixed at init — the producer's jitter stage absorbs overflow).
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total samples ever committed (producer-owned; release-published after the copy).
    private let writeIndex = Atomic<Int>(0)
    /// Total samples ever consumed or flush-skipped (consumer-owned; release-published).
    private let readIndex = Atomic<Int>(0)
    /// Flush frontier: the consumer discards (skips — an index advance, no copy) every sample
    /// below it. Producer-set, consumer-honoured: the producer must never move `readIndex`
    /// itself (single-consumer law), so a flush is a request the next render pass executes.
    private let flushUpTo = Atomic<Int>(0)
    /// Total samples ``consume(into:)`` came up short — the ask minus what was buffered (the
    /// caller zero-fills exactly that many). Monotonic, relaxed: this counter advancing between
    /// two producer observations means the listener actually heard conceal silence, which is the
    /// producer's starvation signal — `fillLevel == 0` alone cannot distinguish an exact dry
    /// drain (no silence played) from a real zero-fill.
    private let shortfall = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Samples currently buffered, as the PRODUCER sees it. Flush-requested-but-not-yet-skipped
    /// samples still count — acceptable slack for the producer's starvation check (a flush also
    /// re-primes the stage, so no underrun is inferred across one).
    var fillLevel: Int {
        writeIndex.load(ordering: .relaxed) - readIndex.load(ordering: .acquiring)
    }

    /// Cumulative consumer shortfall in samples (see `shortfall`). Producer-side read; compare
    /// two observations with `!=` — the value is a monotonic odometer, not a level.
    var shortfallSamples: Int {
        shortfall.load(ordering: .relaxed)
    }

    /// PRODUCER: hands `fill` the free contiguous region(s) in write order; `fill` returns how
    /// many samples it wrote into the region it was given (writing a region short ends the
    /// pass). The new write index publishes with release only AFTER the copies, so the consumer
    /// can never observe unwritten samples. Returns the samples committed.
    func produce(_ fill: (UnsafeMutableBufferPointer<Float>) -> Int) -> Int {
        let r = readIndex.load(ordering: .acquiring)
        let w = writeIndex.load(ordering: .relaxed)
        let free = capacity - (w - r)
        guard free > 0 else { return 0 }
        var written = 0
        let start = w % capacity
        let firstLen = min(free, capacity - start)
        written += fill(UnsafeMutableBufferPointer(start: storage + start, count: firstLen))
        if written == firstLen, free > firstLen {
            written += fill(UnsafeMutableBufferPointer(start: storage, count: free - firstLen))
        }
        guard written > 0 else { return 0 }
        writeIndex.store(w + written, ordering: .releasing)
        return written
    }

    /// CONSUMER (render callback): copies up to `out.count` buffered samples into `out` and
    /// returns the count — zero-filling the remainder (silence conceal) is the caller's job; the
    /// shortfall odometer records how much that was. Honours a pending flush by skipping the
    /// flushed span first. Wait-free: atomic loads, at most two memcpys, one relaxed add, one
    /// release store — nothing here can block on the producer.
    func consume(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        let w = writeIndex.load(ordering: .acquiring)
        let seen = readIndex.load(ordering: .relaxed)
        let flushed = flushUpTo.load(ordering: .acquiring)
        // A flush frontier ahead of the read index discards that span un-copied. ⚠️ The `min`
        // clamp against `w` is LOAD-BEARING, not defensive: `flushed` was the producer's write
        // index at flush time, but `w` here is an EARLIER acquire snapshot — two separate loads,
        // not one atomic picture — so `flushed` CAN legally be ahead of the `w` this pass sees.
        // Unclamped, `r` would pass `w` and the next pass would "consume" unpublished samples.
        let r = flushed > seen ? min(flushed, w) : seen
        var copied = 0
        if let outBase = out.baseAddress {
            copied = min(w - r, out.count)
            let start = r % capacity
            let firstLen = min(copied, capacity - start)
            outBase.update(from: storage + start, count: firstLen)
            if copied > firstLen { (outBase + firstLen).update(from: storage, count: copied - firstLen) }
        }
        if copied < out.count { shortfall.wrappingAdd(out.count - copied, ordering: .relaxed) }
        if r + copied != seen { readIndex.store(r + copied, ordering: .releasing) }
        return copied
    }

    /// PRODUCER: asks the consumer to discard everything committed so far (the next render pass
    /// skips it) — a local disable must fall silent NOW, not one ring-drain later. Samples
    /// produced AFTER this call play normally.
    func requestFlush() {
        flushUpTo.store(writeIndex.load(ordering: .relaxed), ordering: .releasing)
    }
}

/// Producer-side pump between the jitter STAGE (every buffering DECISION — ``AudioJitterBuffer``)
/// and the SPSC ``AudioSampleRing`` the render callback drains. Confined to the session's serial
/// audio queue; only the ring crosses to the render thread. Pure and headless so the
/// emission/starvation glue is unit-testable without an AudioUnit (repo hang-safety).
struct AudioPlaybackPump {
    /// Jitter/reorder/conceal policy — reorder happens HERE, before samples commit to the ring.
    private(set) var stage: AudioJitterBuffer
    /// The lock-free hand-off the render callback consumes.
    let ring: AudioSampleRing
    /// Nominal interleaved samples per ~10 ms frame — converts the stage's frame-count policy
    /// (target depth / high water) into ring sample budgets.
    private let samplesPerFrame: Int
    /// Whether any samples were handed off since the stage last (re)primed — gates the
    /// starvation check so priming silence is never miscounted as an underrun.
    private var emittedSincePrime = false
    /// `ring.shortfallSamples` at the last starvation check — an advance since then means the
    /// render callback actually zero-filled in between.
    private var lastShortfall = 0

    /// Ring top-up bound: the render side only needs target-depth's worth of headroom. Everything
    /// beyond it stays STAGED, where the depth bound can still shed it — samples committed to the
    /// ring are the consumer's and can never be taken back.
    private var ringTargetSamples: Int { stage.targetDepthFrames * samplesPerFrame }
    /// Combined (stage + ring) depth cap — the jitter policy's total client-side latency bound.
    private var highWaterSamples: Int { stage.highWaterFrames * samplesPerFrame }

    init(stage: AudioJitterBuffer, ring: AudioSampleRing, samplesPerFrame: Int) {
        self.stage = stage
        self.ring = ring
        self.samplesPerFrame = max(1, samplesPerFrame)
    }

    /// One decoded frame from the audio decode queue: starvation check → stage policy → combined
    /// depth bound → hand-off.
    mutating func enqueue(seq: UInt32, samples: [Float]) {
        // The render callback zero-filled since the last push while the stage was mid-play ⇒ the
        // listener actually heard conceal silence (underrun). The ring's shortfall odometer — not
        // `fillLevel == 0` — is the signal: a consumer that drains the ring EXACTLY dry zero-fills
        // nothing, and at the ~10 ms push cadence vs ~10.7 ms render quanta that phase alignment
        // is routine, not starvation. Detected HERE (the producer side) because the render thread
        // must not touch stage state; the detection lag stays one push cycle.
        let shortfallNow = ring.shortfallSamples
        if stage.primed, emittedSincePrime, shortfallNow != lastShortfall {
            stage.noteConsumerStarved()
            emittedSincePrime = false
        }
        lastShortfall = shortfallNow
        stage.push(seq: seq, samples: samples)
        // Total-depth bound: the stage's own high-water check sees only STAGED frames, so the
        // combined stage + ring fill is the real client-side latency figure. Past high-water,
        // shed oldest STAGED frames down to target — in-flow matches out-flow, so a backlog
        // never drains on its own; one clean skip forward beats permanently added latency
        // (stale audio is worse than a click).
        if stage.availableSamples + ring.fillLevel > highWaterSamples {
            while stage.pendingFrames > 0, stage.availableSamples + ring.fillLevel > ringTargetSamples {
                stage.dropOldestPending()
            }
        }
        emit()
    }

    /// Local disable: drop the stage AND ask the consumer to skip everything handed off, so the
    /// pane falls silent NOW. The stage keeps its frontier (session-scoped monotonic `seq`).
    mutating func flush() {
        stage.clear()
        emittedSincePrime = false
        ring.requestFlush()
    }

    /// Tops the ring up to the TARGET-depth budget from the stage — never further, whatever the
    /// ring's raw capacity: the render side only needs target-depth of headroom between pushes,
    /// and committed samples can never be dropped, so keeping the excess staged is what lets the
    /// combined depth bound shed it. Anything left stays staged.
    private mutating func emit() {
        while stage.primed, stage.availableSamples > 0 {
            var headroom = ringTargetSamples - ring.fillLevel
            guard headroom > 0 else { return }
            let committed = ring.produce { region in
                let want = min(headroom, region.count)
                guard want > 0 else { return 0 }
                let wrote = stage.drainAvailable(into: UnsafeMutableBufferPointer(rebasing: region[0..<want]))
                headroom -= wrote
                return wrote
            }
            guard committed > 0 else { return }
            emittedSincePrime = true
        }
    }
}
