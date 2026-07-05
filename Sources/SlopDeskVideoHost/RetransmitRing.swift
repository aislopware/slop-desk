import Foundation

/// Bounded send-history ring for NACK / selective-ARQ retransmit.
///
/// Maps a `frameID` to the exact wire datagrams that frame was sent as, so a client NACK
/// (``RecoveryDatagramRouter/Decision/retransmitFragments(frameID:fragIndices:)``) can be answered by
/// re-sending only the missing fragments — cheaper than a recovery-IDR, and with the client's playout
/// buffer ≫ RTT it lands before playout (no stutter). Evicts oldest-first past the frame-count OR
/// byte ceiling. The host populates it only when NACK is enabled (`SLOPDESK_NACK=1`); a value type
/// owned by the session actor (no shared mutable state).
struct RetransmitRing {
    private var order: [UInt32] = []
    private var byFrame: [UInt32: [VideoSendScheduler.Outgoing]] = [:]
    private var totalBytes = 0
    private let maxFrames: Int
    private let maxBytes: Int

    init(maxFrames: Int, maxBytes: Int) {
        self.maxFrames = max(1, maxFrames)
        self.maxBytes = max(1, maxBytes)
    }

    /// Records a frame's datagrams. A repeat `frameID` (e.g. the kfDup re-enqueue) keeps the first
    /// copy — they are byte-identical, so a NACK answer is the same either way.
    mutating func record(frameID: UInt32, outgoings: [VideoSendScheduler.Outgoing]) {
        guard byFrame[frameID] == nil else { return }
        order.append(frameID)
        byFrame[frameID] = outgoings
        totalBytes += outgoings.reduce(0) { $0 + $1.bytes.count }
        while order.count > maxFrames || (totalBytes > maxBytes && order.count > 1) {
            let evicted = order.removeFirst()
            if let gone = byFrame.removeValue(forKey: evicted) {
                totalBytes -= gone.reduce(0) { $0 + $1.bytes.count }
            }
        }
    }

    /// The datagrams for the requested DATA fragment indices of `frameID`, or `[]` if the frame has
    /// aged out of the ring. Filters by the `frag_index` parsed from each datagram's wire header
    /// (big-endian `UInt16` at offset 8 of the raw fragment datagram — no mux prefix is present here;
    /// the transport prepends it at send time).
    func fragments(frameID: UInt32, fragIndices: [UInt16]) -> [VideoSendScheduler.Outgoing] {
        guard let outgoings = byFrame[frameID] else { return [] }
        let want = Set(fragIndices)
        return outgoings.filter { og in
            let b = og.bytes
            guard b.count >= 19 else { return false }
            let idx = (UInt16(b[b.startIndex + 8]) << 8) | UInt16(b[b.startIndex + 9])
            return want.contains(idx)
        }
    }
}
