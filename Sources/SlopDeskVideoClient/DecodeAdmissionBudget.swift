import CSlopDeskFFI

/// Pending-decode admission budget for the off-queue VT decode stage (wifi-flap hardening).
///
/// Every sequencer-released frame is `decodeQueue.async`'d with the block retaining the full
/// AVCC `Data`; the decode itself is a synchronous `VTDecompressionSessionDecodeFrame`, so one
/// wedged decode (the documented iOS background-suspend hang class) lets every later block pile
/// up in GCD at wire rate with no bound. This budget counts the blocks in flight (dispatched,
/// not yet completed) so the actor can drop a frame BEFORE dispatch once the stage saturates —
/// routed through the existing drop-until-anchor gate + IDR request, exactly as if the frame
/// had been lost on the wire.
///
/// The law is `rust/slopdesk-video`'s `decode_admission`; this is its face. Four counters cross by
/// value, so the admit/drop decision is testable without a `VTDecompressionSession` (hang-safety
/// rule 6).
public struct DecodeAdmissionBudget: Sendable {
    private var record: SlopDeskDecodeBudget

    /// The stock caps. The frame cap is generous: a healthy decode (~1–8 ms) against the ~33 ms
    /// arrival cadence keeps the stage near depth 0–2, and a post-stall burst (sequencer release +
    /// retransmits) can spike it briefly — past it, decode is genuinely not keeping up. The byte cap
    /// bounds the worst case of a few large IDRs queued behind a wedge. Both live behind the door.
    public init() { record = slopdesk_decode_budget_default() }

    public init(maxPendingCount: Int, maxPendingBytes: Int) {
        record = slopdesk_decode_budget_new(maxPendingCount, maxPendingBytes)
    }

    /// Frames currently in flight on the decode queue (admitted, not yet completed).
    public var pendingCount: Int { record.pending_count }
    /// Compressed AVCC bytes currently in flight on the decode queue.
    public var pendingBytes: Int { record.pending_bytes }
    /// Frame cap.
    public var maxPendingCount: Int { record.max_pending_count }
    /// Byte cap.
    public var maxPendingBytes: Int { record.max_pending_bytes }

    /// Admits one compressed frame of `bytes` AVCC bytes onto the decode queue. `false` means
    /// the stage is saturated — the caller must drop the frame before dispatch and arm the
    /// loss-recovery path (the stream re-syncs on the next admitted anchor).
    ///
    /// An IDLE stage (`pendingCount == 0`) ALWAYS admits, whatever the byte size: the budget
    /// bounds QUEUED work, and a frame whose size alone exceeds the byte cap (an extreme
    /// recovery keyframe, or an inflated mis-recovered reassembly) would otherwise be refused
    /// forever — every replacement IDR is the same size class, so the pane livelocks while the
    /// decode stage sits empty.
    public mutating func admit(bytes: Int) -> Bool {
        let step = slopdesk_decode_budget_admit(record, bytes)
        record = step.budget
        return step.admitted
    }

    /// One admitted frame finished decoding (success or failure — the block left the queue
    /// either way). Saturating, so an unpaired call can never wedge the budget negative.
    public mutating func complete(bytes: Int) {
        record = slopdesk_decode_budget_complete(record, bytes)
    }
}
