import Foundation

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
/// Pure value type — no clock, no queue — so the admit/drop decision is unit-testable without
/// a `VTDecompressionSession` (hang-safety rule 6).
public struct DecodeAdmissionBudget: Sendable {
    /// Frames currently in flight on the decode queue (admitted, not yet completed).
    public private(set) var pendingCount = 0
    /// Compressed AVCC bytes currently in flight on the decode queue.
    public private(set) var pendingBytes = 0

    /// Frame cap: a healthy decode (~1–8 ms) against the ~33 ms arrival cadence keeps the
    /// stage near depth 0–2; a post-stall burst (sequencer release + retransmits) can spike
    /// it briefly, so the cap is generous — past it, decode is genuinely not keeping up.
    public let maxPendingCount: Int
    /// Byte cap: bounds the worst case of a few large IDRs (~2 MB each) queued behind a wedge.
    public let maxPendingBytes: Int

    public init(maxPendingCount: Int = 32, maxPendingBytes: Int = 16 << 20) {
        self.maxPendingCount = maxPendingCount
        self.maxPendingBytes = maxPendingBytes
    }

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
        if pendingCount > 0 {
            guard pendingCount < maxPendingCount, pendingBytes + bytes <= maxPendingBytes else { return false }
        }
        pendingCount += 1
        pendingBytes += bytes
        return true
    }

    /// One admitted frame finished decoding (success or failure — the block left the queue
    /// either way). Clamped at zero so an unpaired call can never wedge the budget negative.
    public mutating func complete(bytes: Int) {
        pendingCount = max(0, pendingCount - 1)
        pendingBytes = max(0, pendingBytes - bytes)
    }
}
