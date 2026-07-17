import Foundation
import SlopDeskVideoProtocol

/// PURE jitter ring between the audio decode path (push — the session's serial audio queue) and
/// the output AudioUnit's render callback (pull). Decoded ~10 ms frames of interleaved Float32
/// enter keyed by their wire `seq`; the render callback drains a steady stream of samples.
///
/// Policy (doc 20, audio channel):
/// - PRIME: silence until ``targetDepthFrames`` frames are buffered, so playback starts with
///   enough slack to absorb ordinary arrival jitter (audio mirror of ``FramePacer``'s priming).
/// - UNDERRUN: the ring ran dry mid-play → silence-fill the remainder and DROP BACK to priming
///   (re-inflate before playing again), never block the render thread.
/// - REORDER: frames insert in wrap-aware `seq` order, so a swapped pair of datagrams still
///   plays in order. A `seq` at-or-behind the play frontier (already played, or the head frame
///   has begun playing past it) arrived too late to matter → drop.
/// - HIGH WATER: past ``highWaterFrames`` pending frames the OLDEST is dropped (skip forward —
///   stale audio is worse than a click; audio must never build latency to avoid loss).
///
/// The `seq` space is session-scoped and SHARED with config packets (one counter for all tag-6
/// datagrams), so gaps between pushed frames are normal — the ring plays across them seamlessly.
///
/// ⚠️ NOT thread-safe by itself — a plain value type. ``AudioPlaybackEngine`` owns the live
/// instance behind its lock (push and pull race there); this type stays pure so the policy is
/// headlessly unit-testable (`AudioJitterBufferTests`).
///
/// RENDER-THREAD DISCIPLINE: ``pull(into:)`` neither allocates nor frees — consumed frames are
/// only MARKED consumed (index advance) and reclaimed by the next ``push(seq:samples:)`` on the
/// decode side, so the malloc lock is never touched from the render callback.
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
    /// free-free: safe from the render callback (under the engine's lock).
    public mutating func pull(into out: UnsafeMutableBufferPointer<Float>) {
        guard let base = out.baseAddress, !out.isEmpty else { return }
        var wrote = 0
        if primed {
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
        }
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

    /// Convenience pull of `frameCount` interleaved sample-frames (`frameCount × channels`
    /// Floats), silence-filled. Allocates — the test/diagnostic surface; the render callback
    /// uses ``pull(into:)``.
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
