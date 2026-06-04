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
        /// Parity-fragment payloads keyed by their GROUP ORDER (0-based among parity
        /// frags), NOT by raw `fragIndex`. The packetizer assigns parity
        /// `fragIndex = trueDataCount + groupOrder`, so keying by group order means a
        /// LOST group-0 parity never shifts the boundary or mis-maps a surviving
        /// higher-group parity (FIX #1). The group order is recovered at ingest from the
        /// fragCount-inverted dataCount: `groupOrder = fragIndex - invertedDataCount`.
        var parity: [Int: Data] = [:]
        /// The observed parity boundary (lowest parity `fragIndex` seen). With an FEC
        /// scheme this is recorded ONLY as a no-FEC fallback / cross-check; the
        /// authoritative dataCount comes from the unambiguous fragCount inversion (FIX
        /// #1) because a lost group-0 parity makes the lowest observed parity fragIndex
        /// EXCEED the true dataCount. With no FEC there is no parity, so this stays `nil`.
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

    /// How many frameIDs past the loss frontier a frame stays eligible for FEC when
    /// the ONLY thing missing is parity that could still fill its (single-per-group)
    /// data holes. The packetizer emits parity LAST within a frame, so on a
    /// reordering UDP network frame N's parity commonly arrives just AFTER frame
    /// N+1's data begins (doc 17 §3.6). Without this grace, frame N would be swept
    /// the instant N+1's first data fragment advanced the frontier — turning a
    /// fully-recoverable single loss into a drop — and the late parity would then be
    /// `.stale` and useless. The window is small (bounded buffering) but covers the
    /// realistic "parity reordered past the next frame" case. A frame that is hopeless
    /// for a reason FEC parity CANNOT fix (>=2 data losses in a group, or any missing
    /// data with no FEC) is still swept immediately, regardless of the grace.
    private let fecReorderGrace: Int

    public init(fec: FECScheme? = nil, fecReorderGrace: Int = 2) {
        self.fec = fec
        self.fecReorderGrace = max(0, fecReorderGrace)
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
            let pIndex = Int(fragment.header.fragIndex)
            // Track the lowest observed parity fragIndex. With NO FEC scheme this is the
            // only data-boundary signal we have. With an FEC scheme it is NOT trusted as
            // the boundary (a lost group-0 parity makes the lowest survivor's fragIndex
            // exceed the true dataCount); `resolvedDataCount` derives the boundary from
            // the fragCount inversion instead and uses this only as a cross-check (FIX #1).
            entry.dataCount = min(entry.dataCount ?? pIndex, pIndex)
            // Key parity by GROUP ORDER (= fragIndex - dataCount), so a lost group-0
            // parity does not shift the boundary or mis-map a surviving higher-group
            // parity. Without FEC, fall back to the raw fragIndex (no inversion possible).
            let dataBoundary = fec != nil ? invertedDataCount(fragCount: Int(entry.fragCount)) : pIndex
            let groupOrder = max(0, pIndex - dataBoundary)
            entry.parity[groupOrder] = fragment.payload
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
    ///
    /// A frame whose ONLY obstacle is FEC parity that has not yet arrived (every
    /// missing-data group has exactly one hole, repairable once its parity lands) is
    /// granted a bounded ``fecReorderGrace`` window past the frontier before being
    /// swept — because the packetizer emits parity LAST, so on a reordering network it
    /// commonly arrives just after the next frame's data (doc 17 §3.6). A frame that is
    /// hopeless for a reason parity cannot fix is swept immediately.
    private mutating func sweepHopelessFrames() {
        guard let frontier = highestSeenFrameID else { return }
        let hopeless = pending.keys.filter { fid in
            // fid is strictly OLDER than the frontier: frontier - fid > 0.
            let age = frontier.distanceWrapped(from: fid)
            guard age > 0, !canEventuallyComplete(fid) else { return false }
            // Hole(s) only fillable by not-yet-arrived parity → keep within the grace
            // window so reordered parity (emitted last) still has a chance to land.
            if awaitingRecoverableParity(fid), age <= fecReorderGrace { return false }
            return true
        }
        // Drop oldest-first for deterministic recovery-signal ordering.
        for fid in hopeless.sorted(by: { $0.distanceWrapped(from: $1) < 0 }) {
            retire(fid, completed: false)
            droppedQueue.append(fid)
        }
    }

    /// True when `frameID`'s only obstacle to completion is FEC parity that has not
    /// yet arrived: it has an FEC scheme, every group with a missing data fragment is
    /// missing exactly ONE (XOR-recoverable) and that group's parity has not been
    /// ingested yet. Such a frame is NOT permanently hopeless — its late, reordered
    /// parity could still complete it — so the sweep grants it the reorder grace.
    private func awaitingRecoverableParity(_ frameID: UInt32) -> Bool {
        guard let entry = pending[frameID], let fec else { return false }
        let dataCount = resolvedDataCount(entry)
        guard dataCount > 0 else { return false }
        var index = 0
        var groupIndex = 0
        var sawRepairableHole = false
        while index < dataCount {
            let upper = min(index + fec.groupSize, dataCount)
            let missing = (index ..< upper).filter { entry.data[UInt16($0)] == nil }.count
            if missing >= 2 { return false } // not parity-repairable: permanently hopeless
            if missing == 1 {
                // A single hole repairable IFF its parity is still outstanding. Parity is
                // keyed by GROUP ORDER (FIX #1), so this group's parity is `parity[groupIndex]`.
                if entry.parity[groupIndex] != nil { return false }
                sawRepairableHole = true
            }
            index += fec.groupSize
            groupIndex += 1
        }
        return sawRepairableHole
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
    /// With an FEC scheme present, ALWAYS derive `dataCount` from the unambiguous
    /// fragCount inversion (`fragCount = dataCount + ceil(dataCount / groupSize)`), NOT
    /// from the observed parity boundary (FIX #1): the packetizer assigns parity
    /// `fragIndex = trueDataCount + groupOrder`, so if group-0 parity is LOST the lowest
    /// surviving parity fragIndex EXCEEDS the true dataCount and would shift the boundary
    /// — wedging an otherwise-recoverable frame (all data arrives, but the boundary is
    /// off so a real data fragment is treated as parity). The inversion depends only on
    /// the total `fragCount` (which every fragment carries), so it is correct regardless
    /// of WHICH parity fragments survived. With no FEC, `dataCount == fragCount`.
    private func resolvedDataCount(_ entry: Pending) -> Int {
        let total = Int(entry.fragCount)
        if fec != nil { return invertedDataCount(fragCount: total) }
        // No FEC: every fragment is data (the observed boundary, if any, equals total).
        return entry.dataCount ?? total
    }

    /// Inverts `fragCount = dataCount + ceil(dataCount / groupSize)` to recover the data
    /// fragment count from the total, assuming the configured FEC group size. Monotonic
    /// in `dataCount`, so a simple descending scan finds the unique solution. Returns
    /// `fragCount` unchanged if there is no FEC scheme (no parity to subtract).
    private func invertedDataCount(fragCount total: Int) -> Int {
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
            // Parity is keyed by GROUP ORDER (FIX #1): group `g`'s parity is `parity[g]`,
            // so a lost group-0 parity leaves slot 0 `nil` (the recover() contract) while
            // a surviving group-1 parity is correctly at slot 1 — never shifted.
            let parityFragments: [Data?] = (0 ..< max(0, parityCount)).map { entry.parity[$0] }
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
        while index < dataCount {
            let upper = min(index + fec.groupSize, dataCount)
            let missing = (index ..< upper).filter { entry.data[UInt16($0)] == nil }.count
            if missing >= 2 { return false }
            // Parity keyed by GROUP ORDER (FIX #1): this group's parity is `parity[groupIndex]`.
            if missing == 1, entry.parity[groupIndex] == nil { return false }
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
    /// "ahead of" `other`. Public so the host's ``VideoMuxRouter`` can bound its retired
    /// channelID set with the SAME wrap-aware high-water-mark prune (FIX #4).
    public func distanceWrapped(from other: UInt32) -> Int {
        Int(Int32(bitPattern: self &- other))
    }
}
