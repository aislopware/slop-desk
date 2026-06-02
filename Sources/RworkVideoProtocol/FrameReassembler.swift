import Foundation

/// A frame that has been fully reassembled and is ready to feed the decoder.
public struct ReassembledFrame: Equatable, Sendable {
    public var frameID: UInt32
    public var keyframe: Bool
    public var crisp: Bool
    /// The AVCC byte buffer (length-prefixed NAL units) — exactly the bytes the
    /// host packetized, restored either directly or via FEC recovery.
    public var avcc: Data

    public init(frameID: UInt32, keyframe: Bool, crisp: Bool, avcc: Data) {
        self.frameID = frameID
        self.keyframe = keyframe
        self.crisp = crisp
        self.avcc = avcc
    }
}

/// The outcome of feeding one datagram to the reassembler.
public enum ReassemblyResult: Equatable, Sendable {
    /// More fragments are still needed for this frame; nothing to emit yet.
    case incomplete
    /// The frame is complete and reassembled (possibly via FEC recovery).
    case completed(ReassembledFrame)
    /// The frame was abandoned: a fragment is missing and FEC could not recover it,
    /// so the caller must drop the frame and signal recovery (LTR RFI, then IDR
    /// fallback). `frameID` is the lost frame.
    case dropped(frameID: UInt32)
    /// The datagram belonged to a frame already completed or dropped — ignored.
    case stale
}

/// Reassembles fragmented frames by `frameID`, detects loss, and applies FEC.
///
/// Loss model (doc 17 §3.6): the stream is plain UDP, so fragments may be lost or
/// reordered. A frame is only declared lost (`.dropped`) once we know we cannot
/// complete it — i.e. a NEWER frame's fragments arrive while this one is still
/// missing data that FEC cannot fill. That edge is what triggers request-recovery.
///
/// Not `Sendable` by design: it owns mutable per-frame buffers and lives inside the
/// single client receive loop (one reassembler per video stream).
public struct FrameReassembler {
    private struct Pending {
        var fragCount: UInt16
        var keyframe: Bool
        var crisp: Bool
        /// Data-fragment payloads by `fragIndex` (the data range is `0 ..< dataCount`).
        var data: [UInt16: Data] = [:]
        /// Parity-fragment payloads by their group order (0-based among parity frags).
        var parity: [Int: Data] = [:]
        /// First parity fragment index (== number of data fragments) once known.
        var dataCount: Int?
    }

    private let fec: FECScheme?
    /// Frames currently being assembled, keyed by frameID.
    private var pending: [UInt32: Pending] = [:]
    /// The highest frameID we have completed or dropped — anything <= this is stale.
    private var highestRetiredFrameID: UInt32?
    /// The highest frameID we have ever SEEN a fragment for (the loss frontier): once
    /// a newer frame appears, strictly-older incomplete frames that FEC cannot fill
    /// are hopeless (UDP send order only moves forward).
    private var highestSeenFrameID: UInt32?
    /// FrameIDs we have completed/dropped recently, to classify late stragglers.
    private var retired: Set<UInt32> = []
    /// Frames detected as unrecoverably lost, queued for the caller to drain via
    /// ``nextDroppedFrame()`` so a single `ingest` can both complete its own frame
    /// AND surface older drops. Each maps to one request-recovery signal.
    private var droppedQueue: [UInt32] = []

    public init(fec: FECScheme? = nil) {
        self.fec = fec
    }

    /// Pops the next unrecoverably-lost frameID detected during prior ``ingest(_:)``
    /// calls, or `nil`. The client drains this after each ingest and, for each
    /// frameID, issues a recovery signal (LTR RFI → IDR fallback, doc 17 §3.6).
    public mutating func nextDroppedFrame() -> UInt32? {
        droppedQueue.isEmpty ? nil : droppedQueue.removeFirst()
    }

    /// Feeds one parsed fragment. Returns the outcome FOR THE INGESTED FRAGMENT'S
    /// frame. Drops of OLDER, now-hopeless frames are surfaced separately via
    /// ``nextDroppedFrame()`` (so completing a newer frame never hides an older loss).
    /// As a convenience, when the ingested fragment is `.incomplete` but its own
    /// frame became hopeless, `.dropped` is returned directly.
    @discardableResult
    public mutating func ingest(_ fragment: FrameFragment) -> ReassemblyResult {
        let frameID = fragment.header.frameID

        if retired.contains(frameID) { return .stale }
        if let retiredHigh = highestRetiredFrameID, frameID.distanceWrapped(from: retiredHigh) <= 0, !pending.keys.contains(frameID) {
            // frameID is at or behind the retire frontier and not actively pending.
            return .stale
        }

        // Advance the loss frontier.
        if let seen = highestSeenFrameID {
            if frameID.distanceWrapped(from: seen) > 0 { highestSeenFrameID = frameID }
        } else {
            highestSeenFrameID = frameID
        }

        var entry = pending[frameID] ?? Pending(fragCount: fragment.header.fragCount, keyframe: false, crisp: false)
        entry.fragCount = fragment.header.fragCount
        if fragment.header.flags.contains(.keyframe) { entry.keyframe = true }
        if fragment.header.flags.contains(.crisp) { entry.crisp = true }

        if fragment.header.flags.contains(.parity) {
            // Parity index = its position past the data fragments.
            // We learn dataCount from the lowest parity fragIndex seen.
            let pIndex = Int(fragment.header.fragIndex)
            entry.dataCount = min(entry.dataCount ?? pIndex, pIndex)
            entry.parity[pIndex] = fragment.payload
        } else {
            entry.data[fragment.header.fragIndex] = fragment.payload
        }
        pending[frameID] = entry

        // Try to complete THIS frame.
        let result = tryComplete(frameID: frameID)

        // Sweep ALL pending frames strictly older than the loss frontier that can no
        // longer complete; queue them as drops (the caller drains them). This runs
        // regardless of whether `result` is completed/incomplete, so completing a
        // newer frame does not hide an older, hopeless one.
        sweepHopelessFrames()

        if case .completed = result { return result }

        // The ingested frame itself may have just been declared hopeless by the sweep
        // (e.g. a newer frame's fragment arrived and this one can't be filled).
        if pending[frameID] == nil, droppedQueue.contains(frameID) {
            droppedQueue.removeAll { $0 == frameID }
            return .dropped(frameID: frameID)
        }
        return .incomplete
    }

    /// Retires every pending frame strictly older than the loss frontier that can no
    /// longer complete, queueing each as a drop.
    private mutating func sweepHopelessFrames() {
        guard let frontier = highestSeenFrameID else { return }
        let hopeless = pending.keys.filter { fid in
            // fid is strictly OLDER than the frontier: frontier - fid > 0.
            frontier.distanceWrapped(from: fid) > 0 && !canEventuallyComplete(fid)
        }
        // Drop oldest-first for deterministic recovery-signal ordering.
        for fid in hopeless.sorted(by: { $0.distanceWrapped(from: $1) < 0 }) {
            retire(fid, completed: false)
            droppedQueue.append(fid)
        }
    }

    /// Attempts to finish a specific frame; emits `.completed` when whole.
    private mutating func tryComplete(frameID: UInt32) -> ReassemblyResult {
        guard let entry = pending[frameID] else { return .stale }
        guard let avcc = assemble(entry) else { return .incomplete }
        retire(frameID, completed: true)
        return .completed(ReassembledFrame(frameID: frameID, keyframe: entry.keyframe, crisp: entry.crisp, avcc: avcc))
    }

    /// Resolves how many of a frame's fragments are DATA (vs FEC parity).
    ///
    /// Prefer the observed parity boundary (lowest parity `fragIndex` seen). If no
    /// parity fragment has arrived yet but this reassembler has an FEC scheme, invert
    /// `fragCount = dataCount + ceil(dataCount / groupSize)` to recover `dataCount`
    /// from the total — so a frame whose only loss is its single parity fragment, or
    /// whose data all arrived before any parity, still completes. With no FEC,
    /// `dataCount == fragCount`.
    private func resolvedDataCount(_ entry: Pending) -> Int {
        if let observed = entry.dataCount { return observed }
        let total = Int(entry.fragCount)
        guard let fec else { return total }
        // Find d such that d + ceil(d / groupSize) == total. Monotonic in d.
        var d = total
        while d > 0 {
            let parity = (d + fec.groupSize - 1) / fec.groupSize
            if d + parity == total { return d }
            if d + parity < total { break }
            d -= 1
        }
        return total
    }

    /// Returns the reassembled AVCC bytes if all data fragments are present (after
    /// FEC recovery), else `nil`.
    private func assemble(_ entry: Pending) -> Data? {
        // dataCount is the parity boundary; if no parity seen, infer it (see helper).
        let dataCount = resolvedDataCount(entry)
        guard dataCount > 0 else {
            // A zero-data frame: only valid if fragCount accounts purely for an empty
            // single fragment.
            if entry.data[0] != nil { return entry.data[0] }
            return nil
        }

        var dataFragments: [Data?] = (0 ..< dataCount).map { entry.data[UInt16($0)] }

        if dataFragments.contains(where: { $0 == nil }), let fec {
            let parityCount = Int(entry.fragCount) - dataCount
            let parityFragments: [Data?] = (0 ..< max(0, parityCount)).map { entry.parity[dataCount + $0] }
            dataFragments = fec.recover(dataFragments: dataFragments, parityFragments: parityFragments)
        }

        guard !dataFragments.contains(where: { $0 == nil }) else { return nil }
        var avcc = Data()
        for fragment in dataFragments { avcc.append(fragment!) }
        return avcc
    }

    /// Whether a frame still has a chance to complete (all data present or FEC could
    /// fill remaining holes). Used to decide if an older frame is hopelessly lost.
    private func canEventuallyComplete(_ frameID: UInt32) -> Bool {
        guard let entry = pending[frameID] else { return false }
        let dataCount = resolvedDataCount(entry)
        if dataCount <= 0 { return entry.data[0] != nil }
        // Group losses by FEC group; a group with >1 missing data fragment and no
        // way to fill it cannot complete. Without FEC, ANY missing data fragment is
        // terminal once the frame is "old".
        guard let fec else {
            return !(0 ..< dataCount).contains { entry.data[UInt16($0)] == nil }
        }
        var index = 0
        var groupIndex = 0
        let parityBase = dataCount
        while index < dataCount {
            let upper = min(index + fec.groupSize, dataCount)
            let missing = (index ..< upper).filter { entry.data[UInt16($0)] == nil }.count
            if missing >= 2 { return false }
            if missing == 1, entry.parity[parityBase + groupIndex] == nil { return false }
            index += fec.groupSize
            groupIndex += 1
        }
        return true
    }

    private mutating func retire(_ frameID: UInt32, completed: Bool) {
        pending[frameID] = nil
        retired.insert(frameID)
        if let high = highestRetiredFrameID {
            if frameID.distanceWrapped(from: high) > 0 { highestRetiredFrameID = frameID }
        } else {
            highestRetiredFrameID = frameID
        }
        // Bound the retired set so a long session doesn't grow it unboundedly.
        if retired.count > 512, let high = highestRetiredFrameID {
            retired = retired.filter { high.distanceWrapped(from: $0) <= 256 }
        }
    }
}

extension UInt32 {
    /// Signed wrap-aware distance `self - other` interpreted in a 32-bit sequence
    /// space (handles the `frameID`/`streamSeq` wrap at 2^32). Positive ⇒ `self` is
    /// "ahead of" `other`.
    func distanceWrapped(from other: UInt32) -> Int {
        Int(Int32(bitPattern: self &- other))
    }
}
