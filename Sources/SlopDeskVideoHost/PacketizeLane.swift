import Foundation
import SlopDeskVideoProtocol

/// Dedicated serial executor for the CPU-heavy encoded-frame → wire-datagram step (the
/// keystroke-latency fix, 2026-07-11).
///
/// Measured defect this fixes: `onEncodedFrame` ran `packetizeRaw` (hundreds of MTU-split `Data`
/// slice copies + RS-FEC parity) + the wire-encode map SYNCHRONOUSLY on the session actor — the
/// SAME actor that runs the inbound input consumer — so a keystroke arriving mid-packetize of a
/// large IDR waited several ms for `CGEventPost`, directly on the keystroke-to-echo path.
///
/// This actor owns the ``VideoPacketizer`` (its monotonic `frameID`/`streamSeq` counters) plus a
/// stateless ``VideoSendScheduler`` end-to-end, and the session actor `await`s ``packetize`` — the
/// hop is a SUSPENSION point, so pending input hops interleave onto the session actor while the
/// heavy work runs here. Correctness contract:
/// - **Order**: the session's single encoded-frame consumer awaits `onEncodedFrame` (and so this
///   call) one frame at a time, so frames enter serially and `frameID`/`streamSeq` stay assigned
///   in encode order — exactly the pre-fix discipline. The lane itself is additionally an actor,
///   so even a hypothetical second caller could never interleave the counters mid-frame.
/// - **No drops**: every submitted frame returns its datagrams; nothing is queued or shed here.
/// - **Byte-identical wire**: the lane moves WHERE the work runs, never WHAT it computes — the
///   same `VideoPacketizer` call with the same arguments (FEC `m == 1` ≡ XOR stays pinned by the
///   golden vectors and `PacketizeLaneTests`' byte-identity pin).
/// - **Race-free bookkeeping**: the assigned `frameID` is returned WITH the datagrams (assigned
///   and consumed atomically inside one actor hop), so the session actor's LTR / recovery-IDR /
///   retransmit-ring records no longer depend on a peek-before-increment discipline.
public actor PacketizeLane {
    private let packetizer: VideoPacketizer
    private let scheduler = VideoSendScheduler()

    /// One packetized frame: the `frameID` the packetizer assigned it plus its finished, ordered
    /// wire datagrams (`.video` channel). The session actor records LTR/recovery/NACK bookkeeping
    /// against `frameID` and hands `outgoings` to the paced-send lane.
    public struct PacketizedFrame: Sendable {
        public let frameID: UInt32
        public let outgoings: [VideoSendScheduler.Outgoing]
        public init(frameID: UInt32, outgoings: [VideoSendScheduler.Outgoing]) {
            self.frameID = frameID
            self.outgoings = outgoings
        }
    }

    /// - Parameter fec: the packetizer's FEC scheme (same semantics as `VideoPacketizer(fec:)`;
    ///   `nil` = no parity). The lane builds the packetizer itself so its counters can never be
    ///   touched from outside this actor.
    public init(fec: FECScheme?) {
        packetizer = VideoPacketizer(fec: fec)
    }

    /// MTU-split + FEC-parity + wire-encode one encoded frame — the exact
    /// ``VideoPacketizer/packetizeRaw(frame:keyframe:crisp:hostSendTsMillis:fecTier:isLTR:ackedAnchored:interleave:)``
    /// + ``VideoSendScheduler/scheduleFrameRaw(_:)`` composition `onEncodedFrame` used to run
    /// inline, now isolated here so the session actor is free (suspended) while it runs.
    public func packetize(
        frame: Data,
        keyframe: Bool,
        crisp: Bool,
        hostSendTsMillis: UInt32,
        fecTier: UInt8,
        isLTR: Bool,
        ackedAnchored: Bool,
        interleave: Bool,
    ) -> PacketizedFrame {
        // The frameID this packetize call assigns (peek + increment happen inside this single
        // actor-isolated call, so the pair is atomic — no cross-suspension peek race).
        let frameID = packetizer.peekNextFrameID
        let orderedRaw = packetizer.packetizeRaw(
            frame: frame,
            keyframe: keyframe,
            crisp: crisp,
            hostSendTsMillis: hostSendTsMillis,
            fecTier: fecTier,
            isLTR: isLTR,
            ackedAnchored: ackedAnchored,
            interleave: interleave,
        )
        return PacketizedFrame(frameID: frameID, outgoings: scheduler.scheduleFrameRaw(orderedRaw))
    }
}
