import Foundation

/// A frame that has been fully reassembled and is ready to feed the decoder.
public struct ReassembledFrame: Equatable, Sendable {
    public var frameID: UInt32
    public var keyframe: Bool
    public var crisp: Bool
    /// The AVCC byte buffer (length-prefixed NAL units) — exactly the bytes the
    /// host packetized, restored either directly or via FEC recovery.
    public var avcc: Data
    /// True when a data hole existed and FEC parity filled it (the `fecRecovered` telemetry
    /// numerator); false for a whole-arrival frame.
    public var recoveredViaFEC: Bool
    /// A Long-Term-Reference frame (fragments carried ``FrameFragmentHeader/Flags/isLTR``,
    /// bit 6). On a SUCCESSFUL decode the client replies `RecoveryMessage.ack(frameID)` so the host
    /// learns the client holds this LTR (the ACKED-ONLY recovery invariant). False whenever LTR is off.
    public var isLTR: Bool
    /// Bit 7 — this frame was encoded via `ForceLTRRefresh` (references ONLY client-acked LTRs),
    /// the decode gate's non-keyframe re-anchor admission (see FrameFragmentHeader.Flags.ackedAnchored).
    public var ackedAnchored: Bool

    /// The three flag params default to `false` so a call site that only cares about the frame itself
    /// (tests, plain whole-arrival construction) need not spell them out.
    public init(
        frameID: UInt32,
        keyframe: Bool,
        crisp: Bool,
        avcc: Data,
        recoveredViaFEC: Bool = false,
        isLTR: Bool = false,
        ackedAnchored: Bool = false,
    ) {
        self.frameID = frameID
        self.keyframe = keyframe
        self.crisp = crisp
        self.avcc = avcc
        self.recoveredViaFEC = recoveredViaFEC
        self.isLTR = isLTR
        self.ackedAnchored = ackedAnchored
    }
}

/// The outcome of feeding one datagram to the reassembler.
public enum ReassemblyResult: Equatable, Sendable {
    /// More fragments are still needed for this frame; nothing to emit yet.
    case incomplete
    /// The frame is complete and reassembled (possibly via FEC recovery).
    case completed(ReassembledFrame)
    /// The frame was abandoned: a fragment is missing, FEC could not recover it, so the caller must
    /// drop it and signal recovery (LTR RFI, then IDR fallback). `frameID` is the lost frame.
    case dropped(frameID: UInt32)
    /// The datagram belonged to a frame already completed or dropped — ignored.
    case stale
}

/// Reassembles fragmented frames by `frameID`, detects loss, and applies FEC.
///
/// Loss model (doc 17 §3.6): plain UDP, so fragments may be lost or reordered. A frame is declared
/// lost (`.dropped`) only once we know we cannot complete it — a NEWER frame's fragments arrive while
/// this one still misses data FEC cannot fill. That edge triggers request-recovery.
///
/// The whole reassembly ALGORITHM — fragment buffering, the data/parity boundary inversion, the
/// m-aware FEC recovery, the NACK / selective-ARQ hold, and the hopeless-frame loss sweep — lives
/// here, on top of ``FECScheme`` (the production ``RustReedSolomonFEC`` over GF(2^8)),
/// ``AdaptiveFECPolicy`` (per-frame group-size + parity-`m` tier tables), and the ``FrameFragment``
/// codec. With `m == 1` (the production wire) the receive path is byte-identical to single-parity
/// XOR — the shape the golden vectors pin, so keep that identity when touching FEC.
///
/// A `final class` (NOT a value struct) so callers hold it by reference in the single client receive
/// loop (one per video stream). Not `Sendable` by design: it owns mutable per-frame state.
public final class FrameReassembler {
    /// Per-frame reassembly buffer. Fields latch from the flags so a reordered/partial arrival still
    /// marks the frame keyframe/crisp/LTR/anchored.
    private struct Pending {
        /// PINNED from the first fragment seen (see the FRAGCOUNT PIN comment in `ingest`): the
        /// data/parity boundary every completeness/assembly decision derives from. A later
        /// disagreeing fragCount is dropped in `ingest`, so it is immutable per frame.
        let fragCount: UInt16
        var keyframe: Bool = false
        var crisp: Bool = false
        /// True once ANY fragment carries ``FrameFragmentHeader/Flags/isLTR`` (bit 6). Threaded
        /// into the completed ``ReassembledFrame``.
        var isLTR: Bool = false
        var ackedAnchored: Bool = false
        /// The FEC tier PINNED from the FIRST fragment seen. Every fragment carries the same
        /// tier; later disagreement (a corrupt fragment) is ignored so the data/parity split — and the
        /// per-frame parity multiplicity `m` — can't change mid-frame.
        let fecTier: UInt8
        /// Data-fragment payloads by `fragIndex` (the data range is `0 ..< dataCount`).
        var data: [UInt16: Data] = [:]
        /// Parity payloads keyed by flat group-major/parity-rank layout index `group * m + rank`
        /// (= `fragIndex - dataBoundary`), NOT raw `fragIndex`, so a LOST group-0 parity never shifts
        /// the boundary or mis-maps a surviving higher-group parity. For `m == 1` the slot collapses
        /// to the group order — byte-identical to single-parity.
        var parity: [Int: Data] = [:]
        /// The observed parity boundary (lowest parity `fragIndex` seen). Authoritative ONLY in the
        /// no-FEC fallback; with FEC the boundary comes from the unambiguous fragCount inversion.
        var dataCount: Int?

        // MARK: pinned per-frame FEC geometry

        // `fragCount`, `fecTier`, and the reassembler's scheme are all fixed for the life of a frame,
        // so the whole FEC geometry is resolved ONCE here rather than per received fragment.

        /// The per-frame FEC group size (tier → size), or `nil` for a no-FEC client OR an
        /// OFF-tier frame — treated as no-parity.
        let groupSize: Int?
        /// The per-frame parity-shards-per-group count `m` (>= 1).
        let m: Int
        /// The resolved data/parity boundary for the FEC case (`groupSize != nil`):
        /// `invertedDataCount(fragCount, g, m) ?? fragCount`. Unused when `groupSize == nil` (the
        /// no-FEC boundary is the mutable observed `dataCount` above).
        let pinnedDataCount: Int

        // MARK: incremental completeness counters

        // Deciding `canEventuallyComplete` by re-scanning every data group (grouped dictionary probes
        // over `0..<dataCount`) on EVERY fragment ingest is O(dataCount²) per frame — millions of
        // probes on a multi-thousand-fragment IDR, serialized on the client receive path exactly at
        // the keyframe latency spike. These counters hold the SAME decision in O(1): per-group
        // missing-data / surviving-parity counts, plus a three-way tally of not-yet-complete groups.
        // Updated only on a FIRST-arrival fragment (duplicates never re-count — dictionary presence
        // is checked before insert).

        /// Missing data fragments per group (`0..<ceil(pinnedDataCount / g)`), FEC case only.
        var missingPerGroup: [Int] = []
        /// Surviving parity shards per group (distinct parity SLOTS present among the group's `m`),
        /// FEC case only.
        var survivingPerGroup: [Int] = []
        /// Groups with `missing > m` — beyond the per-group erasure budget. Any such group makes the
        /// frame permanently unrecoverable by FEC.
        var hopelessGroups = 0
        /// Groups with `1 <= missing <= m` and `surviving >= missing` — repairable RIGHT NOW from
        /// parity already held.
        var recoverableNowGroups = 0
        /// Groups with `1 <= missing <= m` but `surviving < missing` — within budget, still waiting
        /// on not-yet-arrived parity (or data).
        var awaitingGroups = 0
        /// No-FEC case only: distinct data fragments present below the observed boundary
        /// (`dataCount ?? fragCount`). Adjusted when the boundary shrinks (rare: a parity-flagged
        /// fragment on a no-FEC/OFF frame), so the no-FEC completeness test is also O(1).
        var dataPresentBelowBoundary = 0

        /// Resolves the FEC geometry ONCE from the two pinned wire fields + the fixed scheme, and
        /// starts every group at its all-missing tally (size > m ⇒ hopeless, else awaiting).
        init(fragCount: UInt16, fecTier: UInt8, groupSize: Int?, parityShardsPerGroup: Int) {
            self.fragCount = fragCount
            self.fecTier = fecTier
            // Defensive floors mirror `invertedDataCount`'s `g >= 1, m >= 1` guards.
            let g: Int? = if let groupSize, groupSize >= 1 { groupSize } else { nil }
            self.groupSize = g
            m = max(1, parityShardsPerGroup)
            let total = Int(fragCount)
            if let g {
                let d = FrameReassembler.invertedDataCount(fragCount: total, groupSize: g, m: m) ?? total
                pinnedDataCount = d
                let groups = (d + g - 1) / g
                missingPerGroup = (0..<groups).map { min(g, d - $0 * g) }
                survivingPerGroup = Array(repeating: 0, count: groups)
                hopelessGroups = missingPerGroup.count(where: { $0 > m })
                awaitingGroups = groups - hopelessGroups
            } else {
                pinnedDataCount = total // unused: the no-FEC boundary is the observed `dataCount`
            }
        }

        /// How many of this frame's fragments are DATA (vs FEC parity). O(1) — it reads the geometry
        /// pinned at init. With FEC, always the unambiguous fragCount inversion (NEVER the observed
        /// parity boundary, which a lost group-0 parity would shift); the inversion is m-aware and
        /// falls back to `fragCount` on no solution (corrupt header, or a `fragCount` shaped for a
        /// different `m`). With no FEC, the observed parity boundary (or the whole `fragCount`).
        var resolvedDataCount: Int {
            groupSize != nil ? pinnedDataCount : (dataCount ?? Int(fragCount))
        }

        /// All data present, or FEC could fill the remaining holes from parity ALREADY HELD. m-aware
        /// — a group is hopeless when it lost more than its budget `m`; a group still missing data
        /// needs as many surviving parity shards as it has holes. For `m == 1` this is "no group with
        /// >= 2 holes, and any single-hole group has its (one) parity present". O(1) off the counters.
        var canEventuallyComplete: Bool {
            let dc = resolvedDataCount
            if dc == 0 { return data[0] != nil } // zero-data frame: single empty fragment at index 0
            guard groupSize != nil else {
                // No FEC (or OFF tier): ANY missing data fragment is terminal once "old".
                return dataPresentBelowBoundary == dc
            }
            return hopelessGroups == 0 && awaitingGroups == 0
        }

        /// The ONLY obstacle is not-yet-arrived FEC parity — every group with a hole is within its
        /// `m`-erasure budget but none is repairable from parity already held, and at least one hole
        /// exists. Not permanently hopeless, so the sweep grants the reorder grace. O(1) off the
        /// counters.
        var isAwaitingRecoverableParity: Bool {
            groupSize != nil && hopelessGroups == 0 && recoverableNowGroups == 0 && awaitingGroups > 0
        }

        /// O(1) bookkeeping for a FIRST-arrival data fragment (the caller checks dictionary presence
        /// first; duplicates never re-count). A data-flagged index outside the pinned data range
        /// (corrupt) is outside every completeness/assembly scan, so it is not counted either.
        mutating func noteDataArrived(at index: Int) {
            if let g = groupSize {
                guard index < pinnedDataCount else { return }
                let group = index / g
                tally(group: group, delta: -1)
                missingPerGroup[group] -= 1
                tally(group: group, delta: +1)
            } else if index < (dataCount ?? Int(fragCount)) {
                dataPresentBelowBoundary += 1
            }
        }

        /// O(1) bookkeeping for a FIRST-arrival parity shard at flat layout slot `slot`
        /// (`group * m + rank`). No-op for a no-FEC/OFF frame (parity repairs nothing there).
        mutating func noteParityArrived(atSlot slot: Int) {
            guard groupSize != nil else { return }
            let group = slot / m
            // Slots are in-range by construction (`fragIndex < fragCount` + the boundary clamp);
            // defensive for a hostile shape the inversion fallback produces.
            guard group < survivingPerGroup.count else { return }
            tally(group: group, delta: -1)
            survivingPerGroup[group] += 1
            tally(group: group, delta: +1)
        }

        /// Records the observed parity boundary (lowest parity `fragIndex` seen). On the no-FEC/OFF
        /// path this IS the authoritative data boundary, so a shrink evicts previously-counted data
        /// fragments at or past the new boundary from the completeness counter — O(shrink), and only
        /// on a no-FEC parity arrival, never on the hot data path.
        mutating func noteObservedParityBoundary(_ pIndex: Int) {
            if groupSize == nil {
                let oldBoundary = dataCount ?? Int(fragCount)
                let newBoundary = min(oldBoundary, pIndex)
                if newBoundary < oldBoundary {
                    for i in newBoundary..<oldBoundary where data[UInt16(i)] != nil {
                        dataPresentBelowBoundary -= 1
                    }
                }
            }
            dataCount = min(dataCount ?? pIndex, pIndex)
        }

        /// Moves `group`'s contribution in/out of the three-way tally (`delta` −1 before a counter
        /// change, +1 after). The buckets partition the NOT-yet-complete groups; a hole-free group is
        /// counted nowhere. `surviving <= m` always (a group has `m` parity slots), so `missing > m`
        /// (hopeless) and `surviving >= missing` (recoverable now) are mutually exclusive.
        private mutating func tally(group: Int, delta: Int) {
            let missing = missingPerGroup[group]
            guard missing >= 1 else { return }
            if missing > m {
                hopelessGroups += delta
            } else if survivingPerGroup[group] >= missing {
                recoverableNowGroups += delta
            } else {
                awaitingGroups += delta
            }
        }
    }

    private let fec: FECScheme?
    /// Frames currently being assembled, keyed by frameID.
    private var pending: [UInt32: Pending] = [:]
    /// The highest frameID we have completed or dropped — anything <= this is stale.
    private var highestRetiredFrameID: UInt32?
    /// The highest frameID ever SEEN a fragment for (the loss frontier): once a newer frame appears,
    /// strictly-older incomplete frames FEC cannot fill are hopeless (UDP send order only moves
    /// forward).
    private var highestSeenFrameID: UInt32?
    /// FrameIDs completed/dropped recently, to classify late stragglers. Bounded (see ``retire``).
    private var retired: Set<UInt32> = []
    /// Unrecoverably-lost frames, queued for the caller to drain via ``nextDroppedFrame()`` so a
    /// single `ingest` can both complete its own frame AND surface older drops. Each maps to one
    /// request-recovery signal.
    private var droppedQueue: [UInt32] = []

    /// How many frameIDs past the loss frontier a frame stays FEC-eligible when the ONLY thing missing
    /// is parity that could still fill its data holes. The packetizer emits parity LAST, so on a
    /// reordering UDP network frame N's parity commonly arrives just after frame N+1's data
    /// (doc 17 §3.6). Floored at 0.
    private let fecReorderGrace: Int

    /// NACK / selective-ARQ: frame-ids past the frontier a FEC-unrecoverable frame is HELD pending
    /// (instead of dropped at `fecReorderGrace`) so a host retransmit can still fill it within the
    /// client's playout buffer. `0` = retransmit OFF (drop straight at the FEC grace). Set by
    /// ``enableRetransmit(grace:maxFrags:)``.
    private var retransmitGrace: Int = 0
    /// Frames already surfaced via ``nextNeedsRetransmit()`` (so each retransmit is requested once).
    /// Cleared on retire; bounded like `retired`.
    private var nacked: Set<UInt32> = []
    /// `(frameID, missing data-fragment indices)` the client should NACK, FIFO.
    private var needsRetransmitQueue: [(UInt32, [UInt16])] = []
    /// Only NACK a loss of at most this many DATA fragments — a SMALL loss (keystroke / tiny frame) is
    /// cheap to retransmit, but a BIG loss (scroll frame) is wasteful to re-send into a burst and is
    /// better served by an LTR-refresh skip-to-current. Clamped to the wire cap
    /// ``RecoveryMessage/maxNackFragments`` by ``enableRetransmit(grace:maxFrags:)``.
    private var nackMaxFrags: Int = 0

    /// Upper bound on a frame's declared fragment count (hostile-input guard). `fragCount` is a
    /// peer-controlled `UInt16` (≤ 65535); a real frame is at most a few thousand fragments (a ~2 MB
    /// keyframe at ~1.2 KB/fragment ≈ 1700 data + parity). 8192 covers a ~10 MB frame with headroom,
    /// so a larger value can only be hostile — reject it BEFORE allocating any per-frame buffer and
    /// surface it as `.stale`.
    static let maxFragmentsPerFrame = 8192

    /// Upper bound on how far a SINGLE fragment may advance the loss frontier (hostile-input guard,
    /// the `frameID` companion to `maxFragmentsPerFrame`). The legitimate encoder's `frameID` counter
    /// (`VideoPacketizer.nextFrameID`) advances by 1 per frame, so a real in-flight window is at most a
    /// few thousand frames; a jump larger than this can only be a corrupt/off-path/stray datagram.
    /// Reject it BEFORE creating any per-frame buffer and WITHOUT moving the frontier — see
    /// `resyncStreak` for how a genuine resync still gets through.
    static let maxFrontierJump = 4096

    /// How many CONSECUTIVE fragments rejected for jumping the frontier too far, all clustered within
    /// `resyncClusterWindow` of each other, it takes to accept a resync (latch the frontier at the new
    /// region instead of dropping forever). A real stream that genuinely moved keeps proposing frameIDs
    /// near each other; a lone corrupt/hostile datagram does not repeat.
    static let resyncStreak = 8
    /// How close consecutive jump candidates must be to each other to count as the SAME resync attempt
    /// (not two unrelated bad jumps).
    static let resyncClusterWindow = 256

    /// Consecutive fragments rejected for jumping the frontier, oldest first — reset whenever a
    /// candidate falls outside `resyncClusterWindow` of the previous one, or a normal (non-jumping)
    /// fragment arrives. Bounded by `resyncStreak`.
    private var frontierJumpCandidates: [UInt32] = []
    /// Telemetry: total fragments dropped for jumping the frontier too far (including ones later
    /// absorbed into an accepted resync run).
    public private(set) var frontierJumpRejectedCount = 0

    /// Builds a reassembler matching the host's FEC. `fec` supplies the per-group data count (`k =
    /// fec.groupSize`) and configured parity multiplicity (`m = fec.parityCount`); a `nil` `fec` (or
    /// an `m == 0` scheme) builds a no-FEC reassembler.
    ///
    /// `fecReorderGrace` is how many frameIDs past the loss frontier a frame stays eligible for FEC
    /// when the ONLY thing missing is parity that could still fill its data holes. Floored at 0.
    public init(fec: FECScheme? = nil, fecReorderGrace: Int = 2) {
        // An `m == 0` scheme (degenerate, only a stub builds it) is treated as no-FEC, so the recover
        // path never reads parity that can't exist — keeps the unwrap-free contract.
        self.fec = (fec?.parityCount ?? 0) >= 1 ? fec : nil
        self.fecReorderGrace = max(0, fecReorderGrace)
    }

    /// Enables NACK / selective ARQ: a FEC-unrecoverable frame is HELD pending for `grace` frame-ids
    /// past the loss frontier (instead of dropped at the reorder grace), so a host retransmit
    /// requested via ``nextNeedsRetransmit()`` can still fill it within the client's playout buffer.
    /// Only losses of at most `maxFrags` fragments are NACKed (SMALL loss; bigger skips to the
    /// Drop → LTR-refresh fallback). `maxFrags` is clamped to the wire cap
    /// ``RecoveryMessage/maxNackFragments``. `grace == 0` (default) disables it: a FEC-unrecoverable
    /// frame drops straight at the reorder grace.
    public func enableRetransmit(grace: Int32, maxFrags: Int) {
        retransmitGrace = max(0, Int(grace))
        nackMaxFrags = min(maxFrags, RecoveryMessage.maxNackFragments)
    }

    /// Pops the next NACK request a prior ``ingest(_:)`` queued — `(frameID, the missing DATA
    /// fragment indices)` — or `nil`. The client drains this after each ingest (alongside
    /// ``nextDroppedFrame()``) and sends a ``RecoveryMessage/requestFragments(frameID:fragIndices:)``.
    /// Inert unless ``enableRetransmit(grace:maxFrags:)`` was called.
    public func nextNeedsRetransmit() -> (frameID: UInt32, frags: [UInt16])? {
        needsRetransmitQueue.isEmpty ? nil : needsRetransmitQueue.removeFirst()
    }

    /// Pops the next unrecoverably-lost frameID detected during prior ``ingest(_:)`` calls, or `nil`.
    /// The client drains this after each ingest and, for each frameID, issues a recovery signal (LTR
    /// RFI → IDR fallback, doc 17 §3.6).
    public func nextDroppedFrame() -> UInt32? {
        droppedQueue.isEmpty ? nil : droppedQueue.removeFirst()
    }

    /// Feeds one parsed fragment. Returns the outcome FOR THE INGESTED FRAGMENT'S frame. Drops of
    /// OLDER, now-hopeless frames are surfaced separately via ``nextDroppedFrame()`` (so completing a
    /// newer frame never hides an older loss). If the ingested fragment is `.incomplete` but its own
    /// frame became hopeless, `.dropped` is returned directly.
    @discardableResult
    public func ingest(_ fragment: FrameFragment) -> ReassemblyResult {
        let header = fragment.header
        let frameID = header.frameID

        // Hostile input — UDP video has no auth beyond the mesh: reject an implausible header BEFORE
        // allocating any per-frame buffer. A crafted huge `fragCount` makes assembly build/iterate a
        // `dataCount`-sized array per frame (alloc+CPU DoS), and `fragIndex >= fragCount` can never
        // complete the frame. Every legitimate fragment satisfies `0 < fragCount <=
        // maxFragmentsPerFrame` and `fragIndex < fragCount`. Drop the bad one as `.stale`.
        guard header.fragCount > 0,
              Int(header.fragCount) <= Self.maxFragmentsPerFrame,
              header.fragIndex < header.fragCount
        else {
            return .stale
        }

        if retired.contains(frameID) { return .stale }
        // At or behind the retire frontier and not actively pending → a late straggler the bounded
        // `retired` set may already have forgotten.
        if let retiredHigh = highestRetiredFrameID, frameID.distanceWrapped(from: retiredHigh) <= 0,
           pending[frameID] == nil
        {
            return .stale
        }

        // Advance the loss frontier — bounded to at most `maxFrontierJump` per fragment (hostile-input
        // guard, mirrors the fragCount guard above). A farther-forward frameID is dropped outright: no
        // entry started, frontier untouched. `resyncOnConsistentJump` still lets a GENUINE resync
        // (several consecutive jump candidates clustered near each other) through.
        if let seen = highestSeenFrameID {
            let jump = frameID.distanceWrapped(from: seen)
            if jump > Self.maxFrontierJump {
                frontierJumpRejectedCount += 1
                guard resyncOnConsistentJump(frameID) else { return .stale }
            } else {
                frontierJumpCandidates.removeAll()
            }
            if jump > 0 { highestSeenFrameID = frameID }
        } else {
            highestSeenFrameID = frameID
        }

        // FRAGCOUNT PIN (the `fecTier` pin's companion): `fragCount` is pinned from the FIRST
        // fragment seen for a frame. Every boundary decision — `resolvedDataCount`, the
        // parity-slot mapping, `canEventuallyComplete`, `assemble`, the hopeless sweep — derives the
        // data/parity split from it, so a later fragment carrying a DIFFERENT fragCount (corrupt or
        // hostile; it passes the per-fragment `fragIndex < fragCount` guard against its OWN header)
        // must be validate-then-DROPPED, never believed: a shrunk count would move the boundary below
        // already-buffered data (frame declared "complete" while real data is missing — corrupted
        // decoder input AND a suppressed loss-recovery signal); a grown count would wedge the frame.
        // Equality also re-establishes `fragIndex < pinned fragCount` for the accepted fragment.
        // Removed (not read) so `entry` holds the ONLY live reference to its `data`/`parity`
        // dictionaries while we mutate it below — a plain `pending[frameID]` read would leave a second
        // reference sitting in `pending`, forcing copy-on-write to duplicate the WHOLE fragment buffer
        // on every mutation (O(fragmentCount) per fragment, O(fragmentCount²) per frame).
        var entry: Pending
        if let existing = pending.removeValue(forKey: frameID) {
            guard header.fragCount == existing.fragCount else {
                pending[frameID] = existing // put back — reject only THIS fragment, not the frame.
                return .stale
            }
            entry = existing
        } else {
            entry = makePending(fragCount: header.fragCount, fecTier: header.flags.fecTier)
        }
        if header.flags.contains(.keyframe) { entry.keyframe = true }
        if header.flags.contains(.crisp) { entry.crisp = true }
        if header.flags.contains(.isLTR) { entry.isLTR = true } // bit 6
        if header.flags.contains(.ackedAnchored) { entry.ackedAnchored = true } // bit 7

        if header.flags.contains(.parity) {
            let pIndex = Int(header.fragIndex)
            // m-aware boundary, PINNED at first fragment (`Pending.init` — inversion with
            // total-fragCount fallback), so the boundary the parity is keyed against and the boundary
            // `assemble`/`canEventuallyComplete` use never disagree. The OFF/no-FEC case
            // (`groupSize == nil`) keeps the observed parity index `pIndex`.
            let dataBoundary: Int = entry.groupSize != nil ? entry.pinnedDataCount : pIndex
            entry.noteObservedParityBoundary(pIndex)
            // Parity is laid out group-major then parity-rank AFTER the data fragments, so
            // `fragIndex - dataBoundary` IS the flat layout index `group * m + rank`. For m == 1 it
            // collapses to the group order — byte-identical.
            let paritySlot = max(0, pIndex - dataBoundary)
            let firstArrival = entry.parity[paritySlot] == nil
            entry.parity[paritySlot] = fragment.payload // duplicates overwrite (last-write-wins)
            if firstArrival { entry.noteParityArrived(atSlot: paritySlot) }
        } else {
            let firstArrival = entry.data[header.fragIndex] == nil
            entry.data[header.fragIndex] = fragment.payload // duplicates overwrite (last-write-wins)
            if firstArrival { entry.noteDataArrived(at: Int(header.fragIndex)) }
        }
        pending[frameID] = entry

        let result = tryComplete(frameID: frameID)

        // Sweep ALL pending frames strictly older than the frontier that can no longer complete; queue
        // them as drops (runs regardless of `result`, so completing a newer frame never hides an older
        // hopeless one).
        sweepHopelessFrames()

        if case .completed = result { return result }

        // The ingested frame itself may have just been declared hopeless by the sweep.
        if pending[frameID] == nil, droppedQueue.contains(frameID) {
            droppedQueue.removeAll { $0 == frameID }
            return .dropped(frameID: frameID)
        }
        return .incomplete
    }

    /// True once `frameID` extends a run of `resyncStreak` consecutive rejected-for-jump candidates all
    /// clustered within `resyncClusterWindow` of each other — a stream that genuinely moved, not a lone
    /// corrupt/hostile datagram. Clears the run (starting a fresh one at `frameID`) when the candidate
    /// falls outside the window, so an unrelated second bad jump can't compound into a false resync.
    private func resyncOnConsistentJump(_ frameID: UInt32) -> Bool {
        if let last = frontierJumpCandidates.last,
           abs(frameID.distanceWrapped(from: last)) > Self.resyncClusterWindow
        {
            frontierJumpCandidates.removeAll()
        }
        frontierJumpCandidates.append(frameID)
        if frontierJumpCandidates.count >= Self.resyncStreak {
            frontierJumpCandidates.removeAll()
            return true
        }
        return false
    }

    private func tryComplete(frameID: UInt32) -> ReassemblyResult {
        guard let entry = pending[frameID] else { return .stale }
        // CHEAP completeness precheck before the expensive `assemble` (which copies every present
        // payload and runs FEC recovery). `canEventuallyComplete` is OUTCOME-EQUIVALENT to "assemble
        // would succeed now" — true iff every group is hole-free or has enough ALREADY-PRESENT parity
        // to cover its erasures. It reads the incremental per-group counters `ingest` maintains, so
        // the precheck stays O(1) per fragment instead of an O(N²) per-ingest group re-scan on a
        // multi-thousand-fragment IDR.
        guard entry.canEventuallyComplete else { return .incomplete }
        guard let assembled = assemble(entry) else { return .incomplete }
        retire(frameID)
        return .completed(ReassembledFrame(
            frameID: frameID,
            keyframe: entry.keyframe,
            crisp: entry.crisp,
            avcc: assembled.avcc,
            recoveredViaFEC: assembled.recoveredViaFEC,
            isLTR: entry.isLTR,
            ackedAnchored: entry.ackedAnchored,
        ))
    }

    /// Retires every pending frame strictly older than the loss frontier that can no longer complete.
    ///
    /// A frame whose ONLY obstacle is not-yet-arrived FEC parity gets a bounded ``fecReorderGrace``
    /// window past the frontier (the packetizer emits parity LAST). With NACK enabled and the loss
    /// small enough, a FEC-unrecoverable frame is instead HELD for the retransmit grace (missing data
    /// indices surfaced once). A frame hopeless for a reason neither parity nor a NACK can fix is swept
    /// immediately.
    private func sweepHopelessFrames() {
        guard let frontier = highestSeenFrameID else { return }
        let grace = fecReorderGrace
        let rgrace = retransmitGrace
        var hopeless: [UInt32] = []
        // NACK candidates found this sweep (FEC-unrecoverable, not yet nacked, still inside the
        // retransmit window). Collected under the read-only `pending` scan, applied after.
        var nack: [(UInt32, [UInt16])] = []
        for (fid, entry) in pending {
            // fid strictly OLDER than the frontier: frontier - fid > 0.
            let age = frontier.distanceWrapped(from: fid)
            if age <= 0 || entry.canEventuallyComplete {
                continue // newer than the frontier, or completable now — not hopeless.
            }
            // Hole(s) only fillable by not-yet-arrived parity → keep within the grace window so
            // reordered parity (emitted last) still has a chance to land.
            if entry.isAwaitingRecoverableParity, age <= grace { continue }
            // FEC cannot recover this frame from what is here. With NACK enabled (`rgrace > 0`) and the
            // loss SMALL enough, HOLD it for the retransmit-grace window so a host re-send can fill it
            // inside the client's playout buffer, and surface the request once. A loss too BIG to NACK
            // is NOT held uselessly: it falls through to the prompt Drop → LTR-refresh
            // skip-to-current, because holding it would stall the in-order client for the whole grace
            // with no retransmit ever coming.
            if rgrace > 0, age <= rgrace {
                if nacked.contains(fid) {
                    continue // already requested → hold for its retransmit.
                }
                if let missing = missingDataFrags(entry, maxFrags: nackMaxFrags) {
                    nack.append((fid, missing))
                    continue // small loss → request + hold for the retransmit.
                }
                // else: too big to NACK → fall through to the prompt drop below (no useless hold).
            }
            // Past every grace window → genuinely hopeless (the LTR-refresh fallback then fires).
            hopeless.append(fid)
        }
        for (fid, missing) in nack {
            nacked.insert(fid)
            needsRetransmitQueue.append((fid, missing))
        }
        // Drop oldest-first for deterministic recovery-signal ordering.
        for fid in hopeless.sorted(by: { $0.distanceWrapped(from: $1) < 0 }) {
            retire(fid)
            droppedQueue.append(fid)
        }
    }

    /// Builds a frame's buffer with the whole per-frame FEC geometry resolved ONCE from the two
    /// pinned wire fields (never re-derived per received fragment):
    ///
    ///  * group size: `nil` for a no-FEC client OR an OFF-tier frame
    ///    (``AdaptiveFECPolicy/groupSize(forTier:default:)`` returns `nil`) → treated as no-parity.
    ///    Tier 0 routes to the configured `fec.groupSize`, matching the host;
    ///  * parity multiplicity `m` (see ``parityCount(forTier:)``);
    ///  * the data/parity boundary inversion + the per-group completeness counters.
    private func makePending(fragCount: UInt16, fecTier: UInt8) -> Pending {
        let groupSize = fec.flatMap { AdaptiveFECPolicy.groupSize(forTier: fecTier, default: $0.groupSize) }
        return Pending(
            fragCount: fragCount,
            fecTier: fecTier,
            groupSize: groupSize,
            parityShardsPerGroup: parityCount(forTier: fecTier),
        )
    }

    /// The PER-FRAME parity-shards-per-group count (`m`) for a frame's pinned FEC tier, floored to
    /// at least 1.
    ///
    /// `default_m` is the configured scheme's own `parityCount` (`1` for the production XOR / `m == 1`
    /// codec, so EVERY tier resolves to `m == 1` and the receive path is byte-identical to the
    /// single-parity world). A no-FEC client has no parity, so `m` is `1` (immaterial — no recovery
    /// attempted).
    ///
    /// CRITICAL byte-identity invariant: the adaptive-`m` tier slots (5/6/7) resolve to `m > 1` only
    /// when `default_m >= 2`, i.e. a matched multi-loss codec (`FEC_M >= 2`, deploy-together). A
    /// production XOR host never emits tiers 5/6/7 (its ladder produces only the group-size tiers
    /// 0–4), so those slots are reached only by an adaptive-`m` host paired with an adaptive-`m`
    /// client. The OFF tier (1) sends no parity, so its `m` is pinned to the byte-identical 1.
    private func parityCount(forTier tier: UInt8) -> Int {
        let defaultM = max(1, fec?.parityCount ?? 1)
        let m: Int =
            switch tier {
            case 1: 1 // OFF: no parity sent → m moot, pinned to the byte-identical 1.
            case AdaptiveFECPolicy.parityTierClean where defaultM >= 2: Self.parityMClean // 5 → 2
            case AdaptiveFECPolicy.parityTierNormal where defaultM >= 2: Self.parityMNormal // 6 → 3
            case AdaptiveFECPolicy.parityTierBurst where defaultM >= 2: Self.parityMBurst // 7 → 5
            default: defaultM // every other tier (+ 5/6/7 when default_m == 1) → default_m
            }
        return max(1, m)
    }

    /// Parity shards per group at the adaptive ladder's CLEAN / NORMAL / BURST levels (tiers 5/6/7).
    /// NORMAL matches a fixed `FEC_M=3`. Only consulted when the configured `default_m >= 2` (a
    /// matched multi-loss codec).
    private static let parityMClean = 2
    private static let parityMNormal = 3
    private static let parityMBurst = 5

    /// Inverts `fragCount = dataCount + m * ceil(dataCount / groupSize)` for `dataCount`.
    ///
    /// `m` is the parity-shards-per-group multiplicity (`m == 1` is single-parity). The right-hand side
    /// is monotonic non-decreasing in `dataCount`, so a descending scan finds the (unique, when it
    /// exists) solution. Returns `nil` when no `dataCount` solves the equation (corrupt header, or a
    /// `fragCount` shaped for a different `m`); call sites apply `?? fragCount` for the
    /// total-on-no-solution fallback. A non-positive `groupSize` or `m` (defensive, off hostile input)
    /// yields `nil`. Static (pure) and called exactly once per frame from `Pending.init` — keep it off
    /// the per-fragment path.
    private static func invertedDataCount(fragCount total: Int, groupSize: Int, m: Int) -> Int? {
        guard groupSize >= 1, m >= 1 else { return nil }
        var d = total
        while d > 0 {
            let parity = m * ((d + groupSize - 1) / groupSize) // m * ceil(d / groupSize)
            if d + parity == total { return d }
            if d + parity < total {
                // monotonic: every smaller `d` undershoots even more — no solution exists.
                return nil
            }
            d -= 1
        }
        // d == 0: a frame with zero data fragments has zero parity, so fragCount must be 0.
        return total == 0 ? 0 : nil
    }

    /// The missing DATA fragment indices for `entry` (those in `0..<dataCount` not yet received), for a
    /// NACK / selective-ARQ request — or `nil` when there are none, the count exceeds `maxFrags` (a BIG
    /// loss: re-sending a stale frame into a burst is wasteful, so the client lets it Drop → LTR-refresh
    /// skip-to-current), or the data count is unknown. Parity is NOT requested — the host's retransmit
    /// ring holds the original data datagrams, and once enough DATA arrives the frame completes (with
    /// FEC for any residual hole).
    private func missingDataFrags(_ entry: Pending, maxFrags: Int) -> [UInt16]? {
        let dataCount = entry.resolvedDataCount
        if dataCount == 0 { return nil }
        var missing: [UInt16] = []
        // At most `dataCount` indices can be missing; reserve the worst case so the append loop never
        // grows. Ascending 0..<dataCount order.
        missing.reserveCapacity(dataCount)
        for i in 0..<dataCount where entry.data[UInt16(i)] == nil { missing.append(UInt16(i)) }
        if missing.isEmpty || missing.count > maxFrags { return nil }
        return missing
    }

    /// Returns the reassembled AVCC bytes if all data fragments are present (after FEC recovery), else
    /// `nil`. `recoveredViaFEC` is true when a data hole existed and the FEC `recover` filled it.
    private func assemble(_ entry: Pending) -> (avcc: Data, recoveredViaFEC: Bool)? {
        let dataCount = entry.resolvedDataCount
        guard dataCount > 0 else {
            // A zero-data frame: only valid if it is a single empty fragment at index 0.
            if let only = entry.data[0] { return (only, false) }
            return nil
        }

        var dataFragments: [Data?] = []
        // Exactly `dataCount` slots, one per data index in order; pre-size so the gather never grows.
        dataFragments.reserveCapacity(dataCount)
        for i in 0..<dataCount { dataFragments.append(entry.data[UInt16(i)]) }

        // A hole existed before FEC: if recovery then completes the frame, it was FEC-recovered. Only
        // attempt recovery with a real PER-FRAME group size (nil = no-FEC OR OFF tier → no parity, so a
        // hole stays a hole and the frame is left incomplete/dropped).
        let hadHole = dataFragments.contains { $0 == nil }
        if hadHole, let fec, let g = entry.groupSize {
            // The full flat parity array in group-major then parity-rank order (`parity[group * m +
            // rank]`) — the layout the recover path indexes. A lost parity shard leaves its slot `nil`;
            // the codec recovers up to `m` data losses per group from the survivors.
            let paritySlots = max(0, Int(entry.fragCount) - dataCount)
            var parityFragments: [Data?] = []
            parityFragments.reserveCapacity(paritySlots)
            for i in 0..<paritySlots { parityFragments.append(entry.parity[i]) }
            // ADAPTIVE-m: recover at the SAME per-frame m the host encoded with (from this frame's
            // pinned FEC tier), setting both the parity-array stride (`group * m + rank`) and the
            // per-group recovery budget. For every production tier this equals the codec's configured
            // m, so it collapses to a plain `fec.recover`.
            dataFragments = recover(
                with: fec, dataFragments: dataFragments, parityFragments: parityFragments, groupSize: g,
                m: entry.m,
            )
        }

        guard !dataFragments.contains(where: { $0 == nil }) else { return nil }
        // Pre-size to the exact assembled length so the concat never reallocates mid-loop.
        let total = dataFragments.reduce(0) { $0 + ($1?.count ?? 0) }
        var avcc = Data(capacity: total)
        for case let fragment? in dataFragments { avcc.append(fragment) }
        return (avcc, hadHole)
    }

    /// Recovers holes at the PER-FRAME parity multiplicity `m`.
    ///
    /// When the per-frame `m` equals the codec's configured `parityCount` (the production case —
    /// always for the `m == 1` wire, and for the FIXED multi-loss codec) this delegates straight to the
    /// scheme's public `recover(dataFragments:parityFragments:groupSize:)`. When the adaptive-`m`
    /// ladder signals a per-frame `m` DIFFERING from the codec's `m` (deploy-together, `FEC_M >= 2` +
    /// `ADAPTIVE_FEC_M`), it recovers through a codec built at that per-frame `m`: the Cauchy parity
    /// rows are index-deterministic (row `i` depends only on `k = g` and `i`, never on the total `m` —
    /// `x_i = k + i`), so this reproduces EXACTLY the host's per-frame-`m` encode.
    private func recover(
        with fec: FECScheme,
        dataFragments: [Data?],
        parityFragments: [Data?],
        groupSize g: Int,
        m: Int,
    ) -> [Data?] {
        if m == fec.parityCount {
            return fec.recover(dataFragments: dataFragments, parityFragments: parityFragments, groupSize: g)
        }
        let perFrameCodec = RustReedSolomonFEC(groupSize: g, parityCount: m)
        return perFrameCodec.recover(dataFragments: dataFragments, parityFragments: parityFragments, groupSize: g)
    }

    private func retire(_ frameID: UInt32) {
        pending[frameID] = nil
        // A retired frame (completed OR dropped) is no longer a retransmit candidate, so the
        // once-per-frame guard can forget it.
        nacked.remove(frameID)
        retired.insert(frameID)
        if let high = highestRetiredFrameID {
            if frameID.distanceWrapped(from: high) > 0 { highestRetiredFrameID = frameID }
        } else {
            highestRetiredFrameID = frameID
        }
        // Bound the retired set so a long session doesn't grow it without limit.
        if retired.count > 512, let high = highestRetiredFrameID {
            retired = retired.filter { high.distanceWrapped(from: $0) <= 256 }
        }
    }
}

public extension UInt32 {
    /// Signed wrap-aware distance `self - other` interpreted in a 32-bit sequence space (handles the
    /// `frameID`/`streamSeq` wrap at 2^32). Positive ⇒ `self` is "ahead of" `other`. Public so the
    /// host's ``VideoMuxRouter`` can bound its retired channelID set with the SAME wrap-aware
    /// high-water-mark prune.
    ///
    /// A two's-complement wrap-subtract (`Int(Int32(bitPattern: self &- other))`); the canonical
    /// wrap-distance law shared by the reassembler, decode frontier, and the network/trendline
    /// estimators. Wrap behaviour is pinned by `DecodeSequencerTests` / `DecodeFrontierTests`.
    func distanceWrapped(from other: UInt32) -> Int {
        Int(Int32(bitPattern: self &- other))
    }
}
