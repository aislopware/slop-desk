import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// The Swift face of `rust/slopdesk-video`'s `retransmit_ring`, reached through the door of the
/// same name.
///
/// Bounded send-history ring for NACK / selective-ARQ retransmit.
///
/// Maps a `frameID` to the exact wire datagrams that frame was sent as, so a client NACK
/// (``RecoveryDatagramRouter/Decision/retransmitFragments(frameID:fragIndices:)``) can be answered by
/// re-sending only the missing fragments — cheaper than a recovery-IDR, and with the client's playout
/// buffer ≫ RTT it lands before playout (no stutter). Evicts oldest-first past the frame-count OR
/// byte ceiling. The host populates it only when NACK is enabled (`SLOPDESK_NACK=1`).
///
/// A HANDLE, and therefore a CLASS, and it is the sharpest case of the rule in the repo: the ring
/// exists BECAUSE it is large. Folding it by value would copy the entire send history — up to the
/// byte ceiling — on every frame recorded. A repair instead crosses in two steps: the selection
/// reports its shape, one take copies out only the fragments the NACK named.
///
/// The selection reads each datagram's own wire header rather than trusting record order, so a
/// reordered or partially-parity send answers correctly, and a truncated datagram is skipped rather
/// than mis-selected. Every recorded outgoing is a `.video` datagram — the packetizer's own
/// `scheduleFrameRaw` puts them all on that channel — so the ring carries bytes and the channel is
/// restored here.
final class RetransmitRing: @unchecked Sendable {
    /// The recorded frames and their datagrams.
    private let handle: OpaquePointer?

    init(maxFrames: Int, maxBytes: Int) {
        handle = slopdesk_retransmit_ring_new(max(1, maxFrames), max(1, maxBytes))
    }

    deinit {
        slopdesk_retransmit_ring_free(handle)
    }

    /// Records a frame's datagrams. A repeat `frameID` (e.g. the kfDup re-enqueue) keeps the first
    /// copy — they are byte-identical, so a NACK answer is the same either way.
    func record(frameID: UInt32, outgoings: [VideoSendScheduler.Outgoing]) {
        var arena = Data()
        var spans: [SlopDeskByteSpan] = []
        spans.reserveCapacity(outgoings.count)
        for outgoing in outgoings {
            let span = ArenaText.intern(bytes: outgoing.bytes, into: &arena)
            spans.append(SlopDeskByteSpan(offset: span.offset, length: span.length))
        }
        spans.withUnsafeBufferPointer { source in
            arena.withUnsafeBytes { pool in
                slopdesk_retransmit_ring_record(
                    handle, frameID, source.baseAddress, source.count, pool.baseAddress, pool.count,
                )
            }
        }
    }

    /// The datagrams for the requested DATA fragment indices of `frameID`, or `[]` if the frame has
    /// aged out of the ring.
    func fragments(frameID: UInt32, fragIndices: [UInt16]) -> [VideoSendScheduler.Outgoing] {
        let shape = fragIndices.withUnsafeBufferPointer { wanted in
            slopdesk_retransmit_ring_select(handle, frameID, wanted.baseAddress, wanted.count)
        }
        guard shape.datagram_count > 0 else { return [] }
        var spans = [SlopDeskByteSpan](repeating: SlopDeskByteSpan(), count: shape.datagram_count)
        var arena = Data(count: shape.total_len)
        let taken = spans.withUnsafeMutableBufferPointer { out in
            arena.withUnsafeMutableBytes { pool in
                slopdesk_retransmit_ring_take(
                    handle, out.baseAddress, out.count, pool.baseAddress, pool.count,
                )
            }
        }
        guard taken else { return [] }
        return spans.map { span in
            VideoSendScheduler.Outgoing(
                channel: .video,
                bytes: ArenaText.data(arena, offset: Int(span.offset), length: Int(span.length)),
            )
        }
    }
}
