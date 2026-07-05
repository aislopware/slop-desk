import Foundation

/// A frame that has been fully reassembled and is ready to feed the decoder.
public struct ReassembledFrame: Equatable, Sendable {
    public var frameID: UInt32
    public var keyframe: Bool
    public var crisp: Bool
    /// The AVCC byte buffer (length-prefixed NAL units) — exactly the bytes the
    /// host packetized, restored either directly or via FEC recovery.
    public var avcc: Data
    /// True when a data hole existed and FEC parity filled it to complete this frame (the
    /// `fecRecovered` telemetry numerator). False for a frame that arrived whole. Defaulted so
    /// existing constructors stay valid.
    public var recoveredViaFEC: Bool
    /// WF-8: this is a Long-Term-Reference frame (the fragments carried
    /// ``FrameFragmentHeader/Flags/isLTR``, bit 6). On a SUCCESSFUL decode the client replies
    /// `RecoveryMessage.ack(frameID)` so the host learns the client holds this LTR (the ACKED-ONLY
    /// recovery invariant). Defaulted false for source-compat; false on every pre-WF-8 / LTR-off frame.
    public var isLTR: Bool
    /// Bit 7 — this frame was encoded via `ForceLTRRefresh` (references ONLY client-acked LTRs),
    /// the decode gate's non-keyframe re-anchor admission (see FrameFragmentHeader.Flags.ackedAnchored).
    public var ackedAnchored: Bool

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
/// The whole reassembly ALGORITHM — fragment buffering, the data/parity boundary inversion (FIX #1),
/// the m-aware FEC recovery, the NACK / selective-ARQ hold, and the hopeless-frame loss sweep — is
/// NATIVE Swift (the SINGLE SOURCE OF TRUTH; the former Rust core + opaque-handle FFI is deleted). It
/// reuses the migrated native primitives: ``FECScheme`` (the production ``RustReedSolomonFEC`` over
/// GF(2^8)), ``AdaptiveFECPolicy`` (the per-frame group-size + parity-`m` tier tables), and the
/// ``FrameFragment`` codec. With `m == 1` (the production wire) the receive path is byte-identical to
/// the legacy single-parity reassembler the golden vectors anchored.
///
/// It is a `final class` (NOT a value struct) so callers hold it by reference inside the single client
/// receive loop (one reassembler per video stream). Not `Sendable` by design: it owns mutable
/// per-frame state.
public final class FrameReassembler {
    /// Per-frame reassembly buffer. Native heap state; `nil`-defaulted fields latch from the flags so
    /// a reordered/partial arrival still marks the frame keyframe/crisp/LTR/anchored.
    private struct Pending {
        var fragCount: UInt16
        var keyframe: Bool = false
        var crisp: Bool = false
        /// WF-8: set true once ANY fragment of this frame carries ``FrameFragmentHeader/Flags/isLTR``
        /// (bit 6). Threaded into the completed ``ReassembledFrame``.
        var isLTR: Bool = false
        var ackedAnchored: Bool = false
        /// WF-4: the FEC tier PINNED from the FIRST fragment seen for this frame. Every fragment of a
        /// frame carries the same tier; later disagreement (a corrupt fragment) is ignored so the
        /// data/parity split — and the per-frame parity multiplicity `m` — can't change mid-frame.
        var fecTier: UInt8 = AdaptiveFECPolicy.defaultTier
        /// Data-fragment payloads by `fragIndex` (the data range is `0 ..< dataCount`).
        var data: [UInt16: Data] = [:]
        /// Parity-fragment payloads keyed by their flat group-major/parity-rank layout index
        /// `group * m + rank` (= `fragIndex - dataBoundary`), NOT by raw `fragIndex`. So a LOST
        /// group-0 parity never shifts the boundary or mis-maps a surviving higher-group parity
        /// (FIX #1). For `m == 1` the slot collapses to the group order — byte-identical to the v1
        /// layout where parity is keyed by group order alone.
        var parity: [Int: Data] = [:]
        /// The observed parity boundary (lowest parity `fragIndex` seen). Authoritative ONLY in the
        /// no-FEC fallback; with FEC the boundary comes from the unambiguous fragCount inversion.
        var dataCount: Int?
    }

    private let fec: FECScheme?
    /// Frames currently being assembled, keyed by frameID.
    private var pending: [UInt32: Pending] = [:]
    /// The highest frameID we have completed or dropped — anything <= this is stale.
    private var highestRetiredFrameID: UInt32?
    /// The highest frameID we have ever SEEN a fragment for (the loss frontier): once a newer frame
    /// appears, strictly-older incomplete frames that FEC cannot fill are hopeless (UDP send order
    /// only moves forward).
    private var highestSeenFrameID: UInt32?
    /// FrameIDs completed/dropped recently, to classify late stragglers. Bounded (see ``retire``).
    private var retired: Set<UInt32> = []
    /// Frames detected as unrecoverably lost, queued for the caller to drain via
    /// ``nextDroppedFrame()`` so a single `ingest` can both complete its own frame AND surface older
    /// drops. Each maps to one request-recovery signal.
    private var droppedQueue: [UInt32] = []

    /// How many frameIDs past the loss frontier a frame stays eligible for FEC when the ONLY thing
    /// missing is parity that could still fill its data holes. The packetizer emits parity LAST, so
    /// on a reordering UDP network frame N's parity commonly arrives just after frame N+1's data
    /// (doc 17 §3.6). Floored at 0.
    private let fecReorderGrace: Int

    /// NACK / selective-ARQ: frame-ids past the frontier a FEC-unrecoverable frame is HELD pending
    /// (instead of dropped at `fecReorderGrace`) so a host retransmit can still fill it within the
    /// client's playout buffer. `0` = retransmit OFF (legacy drop behaviour). Set by
    /// ``enableRetransmit(grace:maxFrags:)``.
    private var retransmitGrace: Int = 0
    /// Frames already surfaced via ``nextNeedsRetransmit()`` (so each retransmit is requested once).
    /// Cleared on retire; bounded like `retired`.
    private var nacked: Set<UInt32> = []
    /// `(frameID, missing data-fragment indices)` the client should NACK, FIFO.
    private var needsRetransmitQueue: [(UInt32, [UInt16])] = []
    /// Only NACK a loss of at most this many DATA fragments — a SMALL loss (a keystroke / tiny frame)
    /// is cheap and stutter-free to retransmit, but a BIG loss (a scroll frame) is wasteful to
    /// re-send into a burst and is better served by an LTR-refresh skip-to-current. Clamped to the
    /// wire cap ``RecoveryMessage/maxNackFragments`` by ``enableRetransmit(grace:maxFrags:)``.
    private var nackMaxFrags: Int = 0

    /// Upper bound on a frame's declared fragment count (R7 #6 hostile-input). `fragCount` is a
    /// peer-controlled `UInt16` (≤ 65535); a real frame is at most a few thousand fragments (a ~2 MB
    /// keyframe at ~1.2 KB/fragment ≈ 1700 data + parity). 8192 covers a ~10 MB frame with generous
    /// headroom, so a crafted larger value can only be hostile — reject it BEFORE any per-frame buffer
    /// is allocated and surface it as `.stale` (ignored). Matches `FrameReassembler::MAX_FRAGMENTS_PER_FRAME`.
    static let maxFragmentsPerFrame = 8192

    /// Builds a reassembler matching the host's FEC. `fec` supplies the per-group data count (`k =
    /// fec.groupSize`) and configured parity multiplicity (`m = fec.parityCount`); a `nil` `fec` (or
    /// an `m == 0` scheme) builds a no-FEC reassembler.
    ///
    /// `fecReorderGrace` is how many frameIDs past the loss frontier a frame stays eligible for FEC
    /// when the ONLY thing missing is parity that could still fill its data holes. Floored at 0.
    public init(fec: FECScheme? = nil, fecReorderGrace: Int = 2) {
        // A scheme whose `m == 0` (degenerate, only constructible by a stub) is treated as no-FEC, so
        // the recover path never tries to read parity that can't exist — mirrors the core's `m == 0`
        // → no-FEC handle and keeps the unwrap-free contract.
        self.fec = (fec?.parityCount ?? 0) >= 1 ? fec : nil
        self.fecReorderGrace = max(0, fecReorderGrace)
    }

    /// Enables NACK / selective ARQ: a FEC-unrecoverable frame is HELD pending for `grace` frame-ids
    /// past the loss frontier (instead of dropped at the reorder grace), so a host retransmit
    /// requested via ``nextNeedsRetransmit()`` can still fill it within the client's playout buffer.
    /// Only losses of at most `maxFrags` fragments are NACKed (a SMALL loss; a bigger one skips to
    /// the Drop → LTR-refresh fallback). `maxFrags` is clamped to the wire cap
    /// ``RecoveryMessage/maxNackFragments``. `grace == 0` (the default) disables it — byte-identical
    /// legacy drop behaviour.
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
    /// newer frame never hides an older loss). As a convenience, when the ingested fragment is
    /// `.incomplete` but its own frame became hopeless, `.dropped` is returned directly.
    @discardableResult
    public func ingest(_ fragment: FrameFragment) -> ReassemblyResult {
        let header = fragment.header
        let frameID = header.frameID

        // R7 #6 (hostile input — UDP video has no auth beyond the mesh): reject an implausible header
        // BEFORE allocating any per-frame buffer. A crafted huge `fragCount` would make assembly
        // build/iterate a `dataCount`-sized array per frame (alloc+CPU DoS), and `fragIndex >=
        // fragCount` can never complete the frame. Every legitimate fragment satisfies
        // `0 < fragCount <= maxFragmentsPerFrame` and `fragIndex < fragCount`. Drop the bad fragment
        // as `.stale` (ignored).
        guard header.fragCount > 0,
              Int(header.fragCount) <= Self.maxFragmentsPerFrame,
              header.fragIndex < header.fragCount
        else {
            return .stale
        }

        if retired.contains(frameID) { return .stale }
        if let retiredHigh = highestRetiredFrameID, frameID.distanceWrapped(from: retiredHigh) <= 0,
           pending[frameID] == nil
        {
            // frameID is at or behind the retire frontier and not actively pending.
            return .stale
        }

        // Advance the loss frontier.
        if let seen = highestSeenFrameID {
            if frameID.distanceWrapped(from: seen) > 0 { highestSeenFrameID = frameID }
        } else {
            highestSeenFrameID = frameID
        }

        var entry = pending[frameID] ?? Pending(fragCount: header.fragCount, fecTier: header.flags.fecTier)
        entry.fragCount = header.fragCount
        if header.flags.contains(.keyframe) { entry.keyframe = true }
        if header.flags.contains(.crisp) { entry.crisp = true }
        if header.flags.contains(.isLTR) { entry.isLTR = true } // WF-8 bit 6
        if header.flags.contains(.ackedAnchored) { entry.ackedAnchored = true } // bit 7

        if header.flags.contains(.parity) {
            let pIndex = Int(header.fragIndex)
            // Group size + m both need `fec` (the disjoint field) + this entry's pinned tier.
            let gOpt = parityGroupSize(entry)
            let m = parityCount(entry)
            let total = Int(entry.fragCount)
            // m-aware boundary; on no solution fall back to the TOTAL frag_count — identical to
            // `resolvedDataCount`'s `.unwrap_or(total)`, so the boundary the parity is keyed against
            // and the boundary `assemble`/`canEventuallyComplete` use never disagree. The OFF/no-FEC
            // case (`gOpt == nil`) keeps the observed parity index `pIndex`.
            let dataBoundary: Int =
                if let g = gOpt {
                    invertedDataCount(fragCount: total, groupSize: g, m: m) ?? total
                } else {
                    pIndex
                }
            entry.dataCount = min(entry.dataCount ?? pIndex, pIndex)
            // Parity is laid out group-major then parity-rank AFTER the data fragments, so
            // `fragIndex - dataBoundary` IS the flat layout index `group * m + rank`. For m == 1 this
            // collapses to the group order — byte-identical.
            let paritySlot = max(0, pIndex - dataBoundary)
            entry.parity[paritySlot] = fragment.payload
        } else {
            entry.data[header.fragIndex] = fragment.payload
        }
        pending[frameID] = entry

        // Try to complete THIS frame.
        let result = tryComplete(frameID: frameID)

        // Sweep ALL pending frames strictly older than the frontier that can no longer complete; queue
        // them as drops (runs regardless of `result`, so completing a newer frame never hides an
        // older, hopeless one).
        sweepHopelessFrames()

        if case .completed = result { return result }

        // The ingested frame itself may have just been declared hopeless by the sweep.
        if pending[frameID] == nil, droppedQueue.contains(frameID) {
            droppedQueue.removeAll { $0 == frameID }
            return .dropped(frameID: frameID)
        }
        return .incomplete
    }

    private func tryComplete(frameID: UInt32) -> ReassemblyResult {
        guard let entry = pending[frameID] else { return .stale }
        // CHEAP completeness precheck before the expensive `assemble` (which copies every present
        // fragment payload and runs the FEC recovery pass). `canEventuallyComplete` is
        // OUTCOME-EQUIVALENT to "assemble would succeed now" — true iff every group is either
        // hole-free or has enough ALREADY-PRESENT parity to cover its erasures — but it uses only
        // dictionary presence lookups, no per-fragment payload copy and no GF recovery work. Without
        // it, `tryComplete` ran the full copy + FEC-recover on EVERY fragment ingest of an in-flight
        // frame (O(N²) churn for an N-fragment frame arriving one at a time). The
        // Completed/Incomplete decision is unchanged; only the wasted work is removed.
        guard canEventuallyComplete(frameID) else { return .incomplete }
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
    /// A frame whose ONLY obstacle is FEC parity that has not yet arrived is granted a bounded
    /// ``fecReorderGrace`` window past the frontier (the packetizer emits parity LAST). With NACK
    /// enabled and the loss small enough, a FEC-unrecoverable frame is instead HELD for the
    /// retransmit grace (and its missing data indices surfaced once). A frame hopeless for a reason
    /// neither parity nor a NACK can fix is swept immediately.
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
            if age <= 0 || canEventuallyComplete(fid) {
                continue // newer than the frontier, or completable now — not hopeless.
            }
            // Hole(s) only fillable by not-yet-arrived parity → keep within the grace window so
            // reordered parity (emitted last) still has a chance to land.
            if awaitingRecoverableParity(entry), age <= grace { continue }
            // FEC cannot recover this frame from what is here. With NACK enabled (`rgrace > 0`) and the
            // loss SMALL enough to retransmit, HOLD it for the retransmit-grace window so a host
            // re-send can fill it inside the client's playout buffer, and surface the request once. A
            // loss too BIG to NACK (or an already-requested one short of its window) is NOT held
            // uselessly: it falls straight through to the prompt Drop → LTR-refresh skip-to-current
            // (holding it would stall the in-order client for the whole grace with no retransmit
            // coming — the late-frame regression this guard fixes).
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

    /// The PER-FRAME FEC group size for `entry` (WF-4): `nil` for a no-FEC client OR an OFF-tier frame
    /// (``AdaptiveFECPolicy/groupSize(forTier:default:)`` returns `nil`), in which case the frame is
    /// treated as no-parity. Tier 0 routes to the configured `fec.groupSize`, matching the host.
    private func parityGroupSize(_ entry: Pending) -> Int? {
        guard let fec else { return nil }
        return AdaptiveFECPolicy.groupSize(forTier: entry.fecTier, default: fec.groupSize)
    }

    /// The PER-FRAME parity-shards-per-group count (`m`) for `entry`, derived from the frame's pinned
    /// FEC tier, floored to at least 1.
    ///
    /// Mirrors `adaptive_fec::parity_count(tier, default_m)` exactly: the `default_m` is the configured
    /// scheme's own `parityCount` (`1` for the production XOR / `m == 1` codec, so EVERY tier resolves
    /// to `m == 1` and the receive path is byte-identical to the single-parity world). A no-FEC client
    /// has no parity, so `m` is `1` (immaterial — no recovery is attempted).
    ///
    /// CRITICAL byte-identity invariant: the adaptive-`m` tier slots (5/6/7) only resolve to `m > 1`
    /// when `default_m >= 2`, i.e. a matched multi-loss codec (`FEC_M >= 2`, deploy-together). A
    /// production XOR host never emits tiers 5/6/7 (its ladder produces only the group-size tiers
    /// 0–4), so those slots are reached only by an adaptive-`m` host paired with an adaptive-`m`
    /// client. The OFF tier (1) sends no parity, so its `m` is pinned to the byte-identical 1.
    private func parityCount(_ entry: Pending) -> Int {
        let defaultM = max(1, fec?.parityCount ?? 1)
        let m: Int =
            switch entry.fecTier {
            case 1: 1 // OFF: no parity sent → m moot, pinned to the byte-identical 1.
            case AdaptiveFECPolicy.parityTierClean where defaultM >= 2: Self.parityMClean // 5 → 2
            case AdaptiveFECPolicy.parityTierNormal where defaultM >= 2: Self.parityMNormal // 6 → 3
            case AdaptiveFECPolicy.parityTierBurst where defaultM >= 2: Self.parityMBurst // 7 → 5
            default: defaultM // every other tier (+ 5/6/7 when default_m == 1) → default_m
            }
        return max(1, m)
    }

    /// Parity shards per group at the adaptive ladder's CLEAN / NORMAL / BURST levels (tiers 5/6/7),
    /// mirroring `adaptive_fec::PARITY_M_CLEAN` / `_NORMAL` / `_BURST`. NORMAL matches the legacy fixed
    /// `FEC_M=3`. Only consulted when the configured `default_m >= 2` (a matched multi-loss codec).
    private static let parityMClean = 2
    private static let parityMNormal = 3
    private static let parityMBurst = 5

    /// Resolves how many of a frame's fragments are DATA (vs FEC parity). With FEC, always derive
    /// `dataCount` from the unambiguous fragCount inversion (NEVER the observed parity boundary, which
    /// a lost group-0 parity would shift — FIX #1). With no FEC, `dataCount == fragCount`.
    ///
    /// The inversion is m-aware: it solves `fragCount = data + m * ceil(data / g)` for the per-frame
    /// `m`. When no data count solves it (a corrupt header, or a `fragCount` shaped for a different
    /// `m`) it falls back to `fragCount` — byte-identical to the original `m == 1` total-on-no-solution
    /// fallback.
    private func resolvedDataCount(_ entry: Pending) -> Int {
        let total = Int(entry.fragCount)
        guard let g = parityGroupSize(entry) else { return entry.dataCount ?? total }
        return invertedDataCount(fragCount: total, groupSize: g, m: parityCount(entry)) ?? total
    }

    /// Inverts `fragCount = dataCount + m * ceil(dataCount / groupSize)` for `dataCount`.
    ///
    /// `m` is the parity-shards-per-group multiplicity (`m == 1` is the single-parity case). The
    /// right-hand side is monotonic non-decreasing in `dataCount`, so a descending scan finds the
    /// (unique, when it exists) solution. Returns `nil` when no `dataCount` solves the equation (a
    /// corrupt header, or a `fragCount` shaped for a different `m`); the call sites apply
    /// `?? fragCount` to recover the pre-existing total-on-no-solution fallback. A non-positive
    /// `groupSize` or `m` (defensive, off hostile input) yields `nil`. Mirrors
    /// `reassembler::invert_data_count`.
    private func invertedDataCount(fragCount total: Int, groupSize: Int, m: Int) -> Int? {
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
    /// NACK / selective-ARQ request — or `nil` when there are none to request, the count exceeds
    /// `maxFrags` (a BIG loss: re-sending a stale frame into a burst is wasteful, so the client lets it
    /// Drop → LTR-refresh skip-to-current instead), or the data count is unknown. Parity fragments are
    /// NOT requested — the host's retransmit ring holds the original data datagrams, and once enough
    /// DATA arrives the frame completes (with FEC for any residual hole). Mirrors
    /// `reassembler::missing_data_frags`.
    private func missingDataFrags(_ entry: Pending, maxFrags: Int) -> [UInt16]? {
        let dataCount = resolvedDataCount(entry)
        if dataCount == 0 { return nil }
        var missing: [UInt16] = []
        // At most `dataCount` indices can be missing; reserve the worst case so the append loop never
        // grows. Same indices, same order as the `compactMap` it replaces (ascending 0..<dataCount).
        missing.reserveCapacity(dataCount)
        for i in 0..<dataCount where entry.data[UInt16(i)] == nil { missing.append(UInt16(i)) }
        if missing.isEmpty || missing.count > maxFrags { return nil }
        return missing
    }

    /// Whether a group is unrecoverable: it lost more data fragments than its budget `m` repairs. With
    /// `m == 1` this is the original `missing >= 2` test; an `[k + m, k]` code recovers up to `m`
    /// erasures per group, so `missing > m` is terminal.
    private func groupIsHopeless(missingInGroup: Int, m: Int) -> Bool {
        missingInGroup > m
    }

    /// The flat index, within a frame's group-major/parity-rank parity array, of the parity shard at
    /// `rank` (`0..<m`) of group `groupIndex`: `groupIndex * m + rank`. For `m == 1` this collapses to
    /// `groupIndex` — byte-identical to the v1 layout. Mirrors `reassembler::parity_index`.
    private func parityIndex(groupIndex: Int, rank: Int, m: Int) -> Int {
        groupIndex * m + rank
    }

    /// Whether a group with `missingInGroup` lost data fragments can be repaired GIVEN how many of
    /// that group's `m` parity shards have actually survived. Repairable iff it lost at least one
    /// fragment, the loss is within the per-group budget `m`, AND enough of its `m` parity shards
    /// survived (`survivingParity >= missingInGroup`). For `m == 1` this is "one hole AND that group's
    /// single parity is present". Mirrors `reassembler::group_is_recoverable`.
    private func groupIsRecoverable(missingInGroup: Int, survivingParity: Int, m: Int) -> Bool {
        missingInGroup >= 1
            && !groupIsHopeless(missingInGroup: missingInGroup, m: m)
            && survivingParity >= missingInGroup
    }

    /// Returns the reassembled AVCC bytes if all data fragments are present (after FEC recovery), else
    /// `nil`. `recoveredViaFEC` is true when a data hole existed and the FEC `recover` filled it.
    private func assemble(_ entry: Pending) -> (avcc: Data, recoveredViaFEC: Bool)? {
        let dataCount = resolvedDataCount(entry)
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
        // attempt recovery with a real PER-FRAME group size (nil = no-FEC OR OFF tier → no parity
        // exists, so a hole stays a hole and the frame is left incomplete/dropped).
        let hadHole = dataFragments.contains { $0 == nil }
        if hadHole, let fec, let g = parityGroupSize(entry) {
            // The full flat parity array in group-major then parity-rank order (`parity[group * m +
            // rank]`) — exactly the layout the recover path indexes. A lost parity shard leaves its
            // slot `nil`; the codec recovers up to `m` data losses per group from the survivors.
            let paritySlots = max(0, Int(entry.fragCount) - dataCount)
            var parityFragments: [Data?] = []
            parityFragments.reserveCapacity(paritySlots)
            for i in 0..<paritySlots { parityFragments.append(entry.parity[i]) }
            // ADAPTIVE-m: recover at the SAME per-frame m the host encoded with (from this frame's
            // pinned FEC tier), which sets both the parity-array stride (`group * m + rank`) and the
            // per-group recovery budget. For every legacy / production tier this equals the codec's
            // configured m, so it is byte-identical to the pre-port `fec.recover`.
            dataFragments = recover(
                with: fec, dataFragments: dataFragments, parityFragments: parityFragments, groupSize: g,
                m: parityCount(entry),
            )
        }

        guard !dataFragments.contains(where: { $0 == nil }) else { return nil }
        // Pre-size to the exact assembled length so the concat never reallocates mid-loop.
        let total = dataFragments.reduce(0) { $0 + ($1?.count ?? 0) }
        var avcc = Data(capacity: total)
        for case let fragment? in dataFragments { avcc.append(fragment) }
        return (avcc, hadHole)
    }

    /// Recovers holes at the PER-FRAME parity multiplicity `m`, the counterpart of the core's
    /// `FecScheme::recover_with_m`.
    ///
    /// When the per-frame `m` equals the codec's configured `parityCount` (the production case —
    /// always for the `m == 1` wire, and for the FIXED multi-loss codec) this delegates straight to
    /// the scheme's public `recover(dataFragments:parityFragments:groupSize:)` — byte-identical to the
    /// pre-port path. When the adaptive-`m` ladder signals a per-frame `m` that DIFFERS from the
    /// codec's `m` (deploy-together, `FEC_M >= 2` + `ADAPTIVE_FEC_M`), it recovers through a codec
    /// built at that per-frame `m`: the Cauchy parity rows are index-deterministic (row `i` depends
    /// only on `k = g` and `i`, never on the total `m` — `x_i = k + i`), so this reproduces EXACTLY
    /// the host's per-frame-`m` encode and equals `recover_with_m(g, m)`.
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

    /// Whether a frame still has a chance to complete (all data present, or FEC could fill the
    /// remaining holes from the parity it already holds). m-aware: a group hopeless when it lost more
    /// than its budget `m`; a group still missing data needs as many SURVIVING parity shards as it has
    /// holes. For `m == 1` this is the original "no group with >=2 holes, and any single-hole group
    /// has its (one) parity present". Mirrors `reassembler::can_eventually_complete`.
    private func canEventuallyComplete(_ frameID: UInt32) -> Bool {
        guard let entry = pending[frameID] else { return false }
        let dataCount = resolvedDataCount(entry)
        if dataCount == 0 { return entry.data[0] != nil }
        guard let g = parityGroupSize(entry) else {
            // No FEC (or OFF tier): ANY missing data fragment is terminal once "old".
            return !(0..<dataCount).contains { entry.data[UInt16($0)] == nil }
        }
        let m = parityCount(entry)
        var index = 0
        var groupIndex = 0
        while index < dataCount {
            let upper = min(index + g, dataCount)
            let missing = (index..<upper).count(where: { entry.data[UInt16($0)] == nil })
            if groupIsHopeless(missingInGroup: missing, m: m) { return false }
            if missing >= 1 {
                // The group's parity shards already held (its `m` slots at groupIndex*m + rank).
                let surviving = (0..<m).count(where: { rank in
                    entry.parity[parityIndex(groupIndex: groupIndex, rank: rank, m: m)] != nil
                })
                if !groupIsRecoverable(missingInGroup: missing, survivingParity: surviving, m: m) { return false }
            }
            index += g
            groupIndex += 1
        }
        return true
    }

    /// True when the only obstacle is FEC parity that has not yet arrived: every group with a missing
    /// data fragment is still within its `m`-erasure budget but does not YET hold enough surviving
    /// parity to repair it. Such a frame is not permanently hopeless — its late, reordered parity
    /// could still complete it — so the sweep grants it the reorder grace. m-aware: a group with
    /// `missing > m` is permanently hopeless → not "awaiting"; a group already holding
    /// `surviving >= missing` is repairable NOW, not "awaiting". For `m == 1` this is the original
    /// "exactly one hole and its single parity not yet ingested". Mirrors
    /// `reassembler::awaiting_recoverable_parity`.
    private func awaitingRecoverableParity(_ entry: Pending) -> Bool {
        guard let g = parityGroupSize(entry) else { return false }
        let dataCount = resolvedDataCount(entry)
        guard dataCount > 0 else { return false }
        let m = parityCount(entry)
        var index = 0
        var groupIndex = 0
        var sawRepairableHole = false
        while index < dataCount {
            let upper = min(index + g, dataCount)
            let missing = (index..<upper).count(where: { entry.data[UInt16($0)] == nil })
            if groupIsHopeless(missingInGroup: missing, m: m) { return false } // beyond budget: hopeless
            if missing >= 1 {
                let surviving = (0..<m).count(where: { rank in
                    entry.parity[parityIndex(groupIndex: groupIndex, rank: rank, m: m)] != nil
                })
                if groupIsRecoverable(missingInGroup: missing, survivingParity: surviving, m: m) {
                    return false // enough parity already here → repairable now, not "awaiting"
                }
                sawRepairableHole = true // within budget but short of parity → awaiting more
            }
            index += g
            groupIndex += 1
        }
        return sawRepairableHole
    }

    private func retire(_ frameID: UInt32) {
        pending[frameID] = nil
        // Drop any NACK bookkeeping: a retired frame (completed OR genuinely dropped) is no longer a
        // retransmit candidate, so the once-per-frame guard can forget it.
        nacked.remove(frameID)
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

public extension UInt32 {
    /// Signed wrap-aware distance `self - other` interpreted in a 32-bit sequence space (handles the
    /// `frameID`/`streamSeq` wrap at 2^32). Positive ⇒ `self` is "ahead of" `other`. Public so the
    /// host's ``VideoMuxRouter`` can bound its retired channelID set with the SAME wrap-aware
    /// high-water-mark prune (FIX #4).
    ///
    /// A one-instruction two's-complement wrap-subtract (`Int(Int32(bitPattern: self &- other))` ≡
    /// the core's `a.wrapping_sub(b) as i32`); the canonical wrap-distance law shared by the
    /// reassembler, decode frontier, and the network/trendline estimators. Wrap behaviour is pinned
    /// by `DecodeSequencerTests` / `DecodeFrontierTests`.
    func distanceWrapped(from other: UInt32) -> Int {
        Int(Int32(bitPattern: self &- other))
    }
}
