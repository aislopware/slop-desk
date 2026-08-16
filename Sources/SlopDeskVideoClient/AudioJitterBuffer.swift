import CSlopDeskFFI
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
/// The law is `rust/slopdesk-video`'s `audio_jitter`; this is its face, and it is a HANDLE rather
/// than a by-value fold because this stage's whole product IS the samples — it hands back a steady
/// stream of them, in an order it chose, split at offsets it chose — so they live where the
/// decisions are. (The decode sequencer next door is the opposite case and takes the opposite
/// convention: it never reads a compressed byte, so it moves ids. See `docs/55-ffi-boundary.md`.)
/// Samples cross once each way through `(ptr, len)`: one memcpy of ~10 ms of audio per push.
///
/// ⚠️ NOT thread-safe by itself — one owner, confined to ONE thread (the session's serial audio
/// queue in the live engine; the loopback's single thread), which is what `@unchecked Sendable`
/// stands on and what the door's "no two calls overlap" obligation needs. The policy is still
/// headlessly unit-testable (`AudioJitterBufferTests`). The render thread NEVER touches this type
/// — it consumes the ``AudioSampleRing`` the pump fills.
public final class AudioJitterBuffer: @unchecked Sendable {
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

        /// The door's odometers as this side reads them.
        init(_ counted: SlopDeskAudioStageStats) {
            framesPushed = Int(counted.frames_pushed)
            lateDropped = Int(counted.late_dropped)
            duplicateDropped = Int(counted.duplicate_dropped)
            overflowDropped = Int(counted.overflow_dropped)
            underruns = Int(counted.underruns)
            silenceSamples = Int(counted.silence_samples)
        }
    }

    private let handle: OpaquePointer?
    /// The depth policy, read once — no fold moves one.
    private let shape: SlopDeskAudioStageShape

    /// Interleaved channel count — sizes ``pull(frameCount:)``'s sample count.
    public var channels: Int { shape.channels }
    /// Pending frames required before playback starts (≈2 × 10 ms of slack).
    public var targetDepthFrames: Int { shape.target_depth_frames }
    /// Pending-frame cap; past it the oldest pending frame is dropped.
    public var highWaterFrames: Int { shape.high_water_frames }

    public init(channels: Int, targetDepthFrames: Int = 2, highWaterFrames: Int = 8) {
        handle = slopdesk_audio_stage_new(channels, targetDepthFrames, highWaterFrames)
        shape = slopdesk_audio_stage_shape(handle)
    }

    deinit { slopdesk_audio_stage_free(handle) }

    /// Whether the ring has filled to ``targetDepthFrames`` and is playing (vs. priming).
    public var primed: Bool { slopdesk_audio_stage_primed(handle) }
    public var stats: Stats { Stats(slopdesk_audio_stage_stats(handle)) }

    /// Pending (unplayed) frame count — the ring's live depth.
    public var pendingFrames: Int { slopdesk_audio_stage_pending_frames(handle) }

    /// Samples currently available to pull (partial head accounted).
    public var availableSamples: Int { slopdesk_audio_stage_available_samples(handle) }

    /// Offers one decoded frame. Empty sample sets are dropped (a decoder miss, not a frame).
    public func push(seq: UInt32, samples: [Float]) {
        samples.withUnsafeBufferPointer {
            slopdesk_audio_stage_push(handle, seq, $0.baseAddress, $0.count)
        }
    }

    /// Fills `out` with the next interleaved samples, zero-filling whatever the ring cannot
    /// supply (priming, or a mid-play underrun — which drops back to priming). The loopback/test
    /// consumption surface; the live engine drains via ``drainAvailable(into:)`` instead (its
    /// silence conceal happens in the render callback).
    public func pull(into out: UnsafeMutableBufferPointer<Float>) {
        slopdesk_audio_stage_pull(handle, out.baseAddress, out.count)
    }

    /// Producer-side drain for the lock-free hand-off ring: copies up to `out.count` of the
    /// samples currently available (primed only) and marks them consumed — no zero-fill and no
    /// underrun re-prime, because running short HERE only means nothing is staged to hand off
    /// (actual consumer starvation is signalled by ``noteConsumerStarved()``). Returns the
    /// samples written. Runs on the push thread, so block reclaim stays a single-thread affair.
    public func drainAvailable(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        slopdesk_audio_stage_drain_available(handle, out.baseAddress, out.count)
    }

    /// The hand-off consumer ran the ring dry mid-play (producer-side detection — the render
    /// callback itself only zero-fills): mirror ``pull(into:)``'s underrun policy by dropping
    /// back to priming, so playback resumes with full slack instead of one-frame-at-a-time
    /// crackle. Pending frames stay buffered (they re-count toward the re-prime).
    public func noteConsumerStarved() {
        slopdesk_audio_stage_note_consumer_starved(handle)
    }

    /// Skips the oldest PENDING frame forward — the depth-bound drop the pump applies when the
    /// combined stage + hand-off depth passes high-water (``push(seq:samples:)``'s own high-water
    /// check sees only staged frames). Same skip-forward semantics as the push-side drop: the
    /// frontier advances past the dropped seq (a straggling re-send becomes a late drop) and a
    /// partially handed-off head is abandoned mid-frame. Never re-primes — a latency shed is a
    /// skip, not an underrun.
    public func dropOldestPending() {
        slopdesk_audio_stage_drop_oldest_pending(handle)
    }

    /// Sheds the oldest STAGED frames until the combined stage + hand-off depth is back at target,
    /// returning how many went. The stage's own high-water check sees only staged frames, so this
    /// is the real client-side latency bound — and it is the door's decision, not this side's.
    func shedToDepthBound(ringFill: Int, samplesPerFrame: Int) -> Int {
        slopdesk_audio_stage_shed_to_depth_bound(handle, ringFill, samplesPerFrame)
    }

    /// Convenience pull of `frameCount` interleaved sample-frames (`frameCount × channels`
    /// Floats), silence-filled. Allocates — the test/diagnostic surface (the live engine drains
    /// via ``drainAvailable(into:)``).
    public func pull(frameCount: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, frameCount) * channels)
        out.withUnsafeMutableBufferPointer { pull(into: $0) }
        return out
    }

    /// Drops everything buffered (local disable) and drops back to priming. KEEPS the play
    /// frontier — the tag-6 `seq` is session-scoped monotonic (config packets consume ids too),
    /// so frames arriving after a re-enable are strictly newer and must not be mistaken for
    /// late; stats stay cumulative.
    public func clear() {
        slopdesk_audio_stage_clear(handle)
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
    let stage: AudioJitterBuffer
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
    /// ring are the consumer's and can never be taken back. The arithmetic is the door's, so this
    /// budget and the stage's own policy can never drift apart.
    private var ringTargetSamples: Int {
        slopdesk_audio_ring_target_samples(stage.targetDepthFrames, samplesPerFrame)
    }

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
        if slopdesk_audio_consumer_starved(
            stage.primed, emittedSincePrime, UInt64(shortfallNow), UInt64(lastShortfall),
        ) {
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
        _ = stage.shedToDepthBound(ringFill: ring.fillLevel, samplesPerFrame: samplesPerFrame)
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
