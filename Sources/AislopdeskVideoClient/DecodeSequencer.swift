import AislopdeskVideoProtocol

/// IN-ORDER decode admission (2026-06-12) — the fix for the `frontier = N−2` failure class.
///
/// WHY: the reassembler completes frames in ARRIVAL/RECOVERY order, not frameID order — its own
/// `fecReorderGrace` doc describes the canonical case: frame N−1 waits for late parity while
/// frame N (small, one datagram) completes first. The decode path used to submit completion-order
/// straight into VT, so the out-of-order frame N referenced a not-yet-decoded N−1 and threw
/// -12909 → `invalidateSession` → forced IDR — a ~150 ms freeze for a frame that was about to
/// complete anyway. Measured live (loss-free wire!): every remaining hard fail had
/// `frontier = N−2` — N−1 still pending at N's submit.
///
/// THE SEQUENCER: frames are released to the decoder strictly in frameID order. A frame ahead of
/// the expectation is HELD (bounded); the gap closes when the missing frame completes (released
/// in order) or is declared LOST by the reassembler (the hole is skipped — the decode gate then
/// drops non-anchors downstream, exactly its job). KEYFRAMES bypass ordering entirely: they
/// reference nothing, and waiting on a pre-IDR gap would delay the very frame that heals it —
/// held frames OLDER than the keyframe are obsolete and dropped.
///
/// BOUNDED: a gap that neither completes nor gets declared (pathological) trips the overflow
/// valve — `maxHeld` frames or a `maxGap` id-span — and the sequencer flushes everything held in
/// ascending order (= today's behaviour, the gate/VT sort it out) rather than stalling the pane.
/// Worst-case added hold on the unhappy path ≈ `maxGap` frame intervals (~100 ms @60fps); the
/// happy path (in-order completions, the overwhelming norm) releases immediately, zero latency.
///
/// Pure value type — wrap-aware (`UInt32.distanceWrapped`), no clock, no transport; headlessly
/// unit-testable.
public struct DecodeSequencer: Sendable {
    /// The next frameID the decoder should see (nil until the first release).
    public private(set) var nextExpected: UInt32?
    /// Completed frames waiting for an older gap to resolve, keyed by frameID.
    private var held: [UInt32: ReassembledFrame] = [:]
    /// FrameIDs declared lost while NEWER than the expectation (out-of-order loss declarations).
    private var lostAhead: Set<UInt32> = []

    /// Overflow valves (see header). Held-count and id-span caps both trip the flush.
    private let maxHeld: Int
    private let maxGap: Int

    public init(maxHeld: Int = 4, maxGap: Int = 6) {
        self.maxHeld = max(1, maxHeld)
        self.maxGap = max(1, maxGap)
    }

    /// Folds one reassembler completion. Returns the frames now releasable to the decoder, in
    /// frameID order (possibly empty — the frame was held; possibly several — it closed a gap).
    public mutating func noteCompleted(_ frame: ReassembledFrame) -> [ReassembledFrame] {
        // First frame of the session anchors the expectation.
        guard let expected = nextExpected else {
            nextExpected = frame.frameID &+ 1
            return [frame]
        }
        if frame.keyframe {
            // Keyframes reference nothing — release NOW. Held frames older than it are pre-IDR
            // content behind a known gap: obsolete (the keyframe repaints everything) and very
            // likely undecodable — drop them. The expectation jumps past the keyframe unless it
            // was itself a stale straggler (kfDup duplicates are `.stale` upstream, but be safe).
            if frame.frameID.distanceWrapped(from: expected) >= 0 {
                held = held.filter { $0.key.distanceWrapped(from: frame.frameID) > 0 }
                lostAhead = lostAhead.filter { $0.distanceWrapped(from: frame.frameID) > 0 }
                nextExpected = frame.frameID &+ 1
                return [frame] + drainContiguous()
            }
            return [frame]
        }
        let dist = frame.frameID.distanceWrapped(from: expected)
        if dist < 0 {
            // Older than the expectation (late straggler the reassembler somehow completed):
            // release immediately — the gate/decoder decide; the expectation never regresses.
            return [frame]
        }
        if dist == 0 {
            nextExpected = expected &+ 1
            return [frame] + drainContiguous()
        }
        // Ahead of a gap: hold, then check the overflow valves.
        held[frame.frameID] = frame
        if held.count > maxHeld || dist > Int64(maxGap) {
            return flushAll()
        }
        return []
    }

    /// Folds one reassembler loss declaration: the hole at `frameID` will never complete — skip
    /// it. Returns frames released by the gap closing (in order).
    public mutating func noteLost(frameID: UInt32) -> [ReassembledFrame] {
        guard let expected = nextExpected else { return [] }
        let dist = frameID.distanceWrapped(from: expected)
        if dist < 0 { return [] } // already behind the expectation
        if dist == 0 {
            nextExpected = expected &+ 1
            return drainContiguous()
        }
        lostAhead.insert(frameID)
        // A loss can also trip the span valve (the gap is now known-unfillable up to it).
        if lostAhead.count + held.count > maxHeld + maxGap { return flushAll() }
        return []
    }

    /// Releases the contiguous run now available at the expectation: held frames release,
    /// declared-lost ids are skipped, the first true hole stops the run.
    private mutating func drainContiguous() -> [ReassembledFrame] {
        var out: [ReassembledFrame] = []
        while let expected = nextExpected {
            if let f = held.removeValue(forKey: expected) {
                out.append(f)
                nextExpected = expected &+ 1
            } else if lostAhead.remove(expected) != nil {
                nextExpected = expected &+ 1
            } else {
                break
            }
        }
        return out
    }

    /// Overflow valve: give up on the gap — release EVERYTHING held in ascending frameID order
    /// (downstream gate/VT handle the consequences, exactly the pre-sequencer behaviour) and jump
    /// the expectation past it all.
    private mutating func flushAll() -> [ReassembledFrame] {
        let out = held.values.sorted { $0.frameID.distanceWrapped(from: $1.frameID) < 0 }
        if let last = out.last {
            let pastHeld = last.frameID &+ 1
            let pastLost = lostAhead.max(by: { $0.distanceWrapped(from: $1) < 0 }).map { $0 &+ 1 }
            if let pastLost, pastLost.distanceWrapped(from: pastHeld) > 0 {
                nextExpected = pastLost
            } else {
                nextExpected = pastHeld
            }
        } else if let maxLost = lostAhead.max(by: { $0.distanceWrapped(from: $1) < 0 }) {
            nextExpected = maxLost &+ 1
        }
        held.removeAll(keepingCapacity: true)
        lostAhead.removeAll(keepingCapacity: true)
        return out
    }
}
