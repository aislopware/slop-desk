import CSlopDeskFFI
import SlopDeskVideoProtocol

/// IN-ORDER decode admission — closes the `frontier = N−2` failure class.
///
/// WHY: the reassembler completes frames in ARRIVAL/RECOVERY order, not frameID order — its own
/// `fecReorderGrace` doc describes the canonical case: frame N−1 waits for late parity while
/// frame N (small, one datagram) completes first. Submitting completion order straight into VT
/// lets the out-of-order frame N reference a not-yet-decoded N−1, which throws -12909 →
/// `invalidateSession` → forced IDR — a ~150 ms freeze for a frame that was about to complete
/// anyway. Every hard fail on a loss-free wire has `frontier = N−2` — N−1 still pending at N's
/// submit — which is exactly the case this sequencer closes.
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
/// The law is `rust/slopdesk-video`'s `decode_admission`; this is its face, and the split is the
/// point: the ordering law never reads a compressed byte, so what crosses is frameIDs — the two
/// outstanding SETS travel with the state, and each fold answers with the ids to RELEASE, in
/// order, and the ids a keyframe made obsolete. The AVCC payloads stay on this side, in a bag
/// keyed by id, so no compressed frame is ever copied through the door. Honour the answers in the
/// order the door gives them: release first, forget second (see `docs/55-ffi-boundary.md` §4b).
public struct DecodeSequencer: Sendable {
    /// The law's fixed numbers, resolved once. Nothing here is state — no fold moves one.
    private static let constants = slopdesk_decode_sequencer_constants()

    /// Stock valve values, exposed so wiring code (e.g. the NACK-grace floor in
    /// ``SlopDeskVideoClientSession``) can derive from them instead of duplicating magic numbers.
    /// `defaultMaxHeld` is a held-frame COUNT; `defaultMaxGap` is a frameID SPAN past the expectation.
    public static var defaultMaxHeld: Int { constants.default_max_held }
    public static var defaultMaxGap: Int { Int(constants.default_max_gap) }

    private var record: SlopDeskDecodeSequencer
    /// The payloads the law does not read, kept by the id it does. Held frames live here until the
    /// door releases or forgets them, so the bag is bounded by ``maxHeld`` exactly as the law is.
    private var frames: [UInt32: ReassembledFrame] = [:]

    public init(maxHeld: Int = Self.defaultMaxHeld, maxGap: Int = Self.defaultMaxGap) {
        record = slopdesk_decode_sequencer_new(maxHeld, Int32(clamping: maxGap))
    }

    /// The next frameID the decoder should see (nil until the first release).
    public var nextExpected: UInt32? { record.has_next_expected ? record.next_expected : nil }

    /// Overflow valves (see header). Held-count and id-span caps both trip the flush; each is
    /// floored so neither can be disabled, and capped at the band the crossing's capacity is proved
    /// against. (Internal read: lets wiring tests verify the configured patience without behaviour
    /// probes.)
    var maxHeld: Int { record.max_held }
    var maxGap: Int { Int(record.max_gap) }

    /// Folds one reassembler completion. Returns the frames now releasable to the decoder, in
    /// frameID order (possibly empty — the frame was held; possibly several — it closed a gap).
    public mutating func noteCompleted(_ frame: ReassembledFrame) -> [ReassembledFrame] {
        frames[frame.frameID] = frame
        let step = withUnsafePointer(to: record) {
            slopdesk_decode_sequencer_note_completed($0, frame.frameID, frame.keyframe)
        }
        return harvest(step)
    }

    /// Folds one reassembler loss declaration: the hole at `frameID` will never complete — skip
    /// it. Returns frames released by the gap closing (in order).
    public mutating func noteLost(frameID: UInt32) -> [ReassembledFrame] {
        let step = withUnsafePointer(to: record) {
            slopdesk_decode_sequencer_note_lost($0, frameID)
        }
        return harvest(step)
    }

    /// Takes one fold's answers: release first, then forget. An id can be in BOTH lists exactly
    /// once — a duplicate keyframe that was already held releases as the new arrival and drops as
    /// the held copy — and in that order the removal is the no-op it should be.
    private mutating func harvest(_ step: SlopDeskDecodeSequencerStep) -> [ReassembledFrame] {
        record = step.sequencer
        let released = Self.ids(step.released, step.released_len).compactMap {
            frames.removeValue(forKey: $0)
        }
        for obsolete in Self.ids(step.dropped, step.dropped_len) {
            frames.removeValue(forKey: obsolete)
        }
        return released
    }

    /// The live prefix of one of the door's id arrays. A C array is a TUPLE over here, so the only
    /// way to read one is through its own storage.
    private static func ids(_ carried: some Any, _ count: Int) -> [UInt32] {
        withUnsafeBytes(of: carried) { raw in
            Array(raw.bindMemory(to: UInt32.self).prefix(count))
        }
    }
}
