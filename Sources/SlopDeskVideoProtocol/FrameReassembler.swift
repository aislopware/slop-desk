import CSlopDeskFFI
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
/// The whole reassembly ALGORITHM — fragment buffering, the data/parity boundary inversion, the
/// m-aware FEC recovery, the NACK / selective-ARQ hold, the hopeless-frame loss sweep and every
/// hostile-input guard on the way in — lives in `rust/slopdesk-video`'s `reassembler`. This type is
/// the boundary to it. With `m == 1` (the production wire) the receive path is byte-identical to
/// single-parity XOR — the shape the golden vectors pin.
///
/// ## Why a handle
/// The state outlives every call by design: a frame is declared lost only once a NEWER frame's
/// fragments arrive while it still has a hole the code cannot fill, so the reassembler has to
/// remember what it has been shown. Passing that across per datagram would copy the frame under
/// construction — up to a whole IDR — once per fragment. `docs/55` §4b is the convention; its
/// obligation comes with it: exactly one free per new (``deinit``), and no two calls may overlap.
///
/// A `final class` (NOT a value struct) so callers hold it by reference in the single client receive
/// loop (one per video stream). Not `Sendable` by design: it owns the handle, and the receive loop
/// is what serialises it.
public final class FrameReassembler {
    /// The Rust reassembler: the buffers, the frontier, the queues and the FEC.
    private let handle: OpaquePointer

    /// Builds a reassembler matching the host's FEC. `fec` supplies the per-group data count (`k =
    /// fec.groupSize`) and configured parity multiplicity (`m = fec.parityCount`); a `nil` `fec` (or
    /// an `m == 0` scheme) builds a no-FEC reassembler.
    ///
    /// `fecReorderGrace` is how many frameIDs past the loss frontier a frame stays eligible for FEC
    /// when the ONLY thing missing is parity that could still fill its data holes. Floored at 0.
    public init(fec: FECScheme? = nil, fecReorderGrace: Int = 2) {
        // An `m == 0` scheme (degenerate, only a stub builds it) is treated as no-FEC, so the
        // recover path never reads parity that cannot exist.
        let coded = (fec?.parityCount ?? 0) >= 1 ? fec : nil
        guard let handle = slopdesk_video_reassembler_new(
            coded?.groupSize ?? 1,
            coded?.parityCount ?? 0,
            Int32(Swift.max(0, fecReorderGrace)),
        ) else { preconditionFailure("the FEC shape is one the erasure code cannot exist in") }
        self.handle = handle
    }

    deinit { slopdesk_video_reassembler_free(handle) }

    /// Enables NACK / selective ARQ: a FEC-unrecoverable frame is HELD pending for `grace` frame-ids
    /// past the loss frontier (instead of dropped at the reorder grace), so a host retransmit
    /// requested via ``nextNeedsRetransmit()`` can still fill it within the client's playout buffer.
    /// Only losses of at most `maxFrags` fragments are NACKed (SMALL loss; bigger skips to the
    /// Drop → LTR-refresh fallback). `maxFrags` is clamped to the wire cap
    /// ``RecoveryMessage/maxNackFragments``. `grace == 0` (default) disables it.
    public func enableRetransmit(grace: Int32, maxFrags: Int) {
        slopdesk_video_reassembler_enable_retransmit(
            handle, Swift.max(0, grace), Swift.min(maxFrags, RecoveryMessage.maxNackFragments),
        )
    }

    /// Pops the next NACK request a prior ``ingest(_:)`` queued — `(frameID, the missing DATA
    /// fragment indices)` — or `nil`. The client drains this after each ingest (alongside
    /// ``nextDroppedFrame()``) and sends a ``RecoveryMessage/requestFragments(frameID:fragIndices:)``.
    /// Inert unless ``enableRetransmit(grace:maxFrags:)`` was called.
    public func nextNeedsRetransmit() -> (frameID: UInt32, frags: [UInt16])? {
        // A request naming no fragments is not a request, so a count of zero IS the absence — there
        // is no separate "did it answer" call to get out of step with this one.
        let count = slopdesk_video_reassembler_next_needs_retransmit(handle)
        guard count > 0 else { return nil }
        var written = 0
        let frags = [UInt16](unsafeUninitializedCapacity: count) { buffer, filled in
            written = slopdesk_video_reassembler_retransmit_frags(handle, buffer.baseAddress, buffer.count)
            filled = Swift.min(written, buffer.count)
        }
        guard written == count else { return nil }
        return (slopdesk_video_reassembler_retransmit_frame_id(handle), frags)
    }

    /// Pops the next unrecoverably-lost frameID detected during prior ``ingest(_:)`` calls, or `nil`.
    /// The client drains this after each ingest and, for each frameID, issues a recovery signal (LTR
    /// RFI → IDR fallback, doc 17 §3.6).
    public func nextDroppedFrame() -> UInt32? {
        // Through an out param rather than a sentinel return: every `UInt32` is a legal frameID, so
        // no value could have meant "none".
        var frameID: UInt32 = 0
        return slopdesk_video_reassembler_next_dropped_frame(handle, &frameID) ? frameID : nil
    }

    /// Feeds one parsed fragment. Returns the outcome FOR THE INGESTED FRAGMENT'S frame. Drops of
    /// OLDER, now-hopeless frames are surfaced separately via ``nextDroppedFrame()`` (so completing a
    /// newer frame never hides an older loss). If the ingested fragment is `.incomplete` but its own
    /// frame became hopeless, `.dropped` is returned directly.
    ///
    /// The header crosses as its seven fields rather than as the 19 bytes it was parsed from: the
    /// client's router already read `frameID` and `hostSendTsMillis` off this datagram for the
    /// one-way-delay telemetry, so handing the bytes over would mean decoding them twice.
    @discardableResult
    public func ingest(_ fragment: FrameFragment) -> ReassemblyResult {
        let header = fragment.header
        let verdict = fragment.payload.withUnsafeBytes { payload in
            slopdesk_video_reassembler_ingest(
                handle,
                header.streamSeq, header.frameID, header.fragIndex, header.fragCount,
                header.flags.rawValue, header.hostSendTsMillis,
                payload.bindMemory(to: UInt8.self).baseAddress, payload.count,
            )
        }
        switch verdict {
        case Self.verdictCompleted:
            return .completed(parkedFrame())
        case Self.verdictDropped:
            return .dropped(frameID: slopdesk_video_reassembler_frame_id(handle))
        case Self.verdictStale:
            return .stale
        default:
            return .incomplete
        }
    }

    /// Reads the frame the last completing ingest parked. The AVCC is asked for by length and then
    /// copied once, into storage sized for it — the shape §4 asks for, and the only copy the frame
    /// makes on this side.
    private func parkedFrame() -> ReassembledFrame {
        let needed = slopdesk_video_reassembler_frame_avcc(handle, nil, 0)
        var written = 0
        let avcc = [UInt8](unsafeUninitializedCapacity: needed) { buffer, count in
            written = slopdesk_video_reassembler_frame_avcc(handle, buffer.baseAddress, buffer.count)
            count = Swift.min(written, buffer.count)
        }
        let flags = slopdesk_video_reassembler_frame_flags(handle)
        return ReassembledFrame(
            frameID: slopdesk_video_reassembler_frame_id(handle),
            keyframe: flags & Self.frameKeyframe != 0,
            crisp: flags & Self.frameCrisp != 0,
            avcc: written == needed ? Data(avcc) : Data(),
            recoveredViaFEC: flags & Self.frameRecoveredViaFEC != 0,
            isLTR: flags & Self.frameIsLTR != 0,
            ackedAnchored: flags & Self.frameAckedAnchored != 0,
        )
    }

    /// The verdict tags ``slopdesk_video_reassembler_ingest`` answers with, taken from the header
    /// rather than restated: a switch that transcribed them would keep compiling if the crate
    /// renumbered, and read a dropped frame as a completed one.
    private static let verdictCompleted = SLOPDESK_REASSEMBLE_COMPLETED
    private static let verdictDropped = SLOPDESK_REASSEMBLE_DROPPED
    private static let verdictStale = SLOPDESK_REASSEMBLE_STALE

    /// The latched wire bits ``slopdesk_video_reassembler_frame_flags`` packs, asked for the way the
    /// verdicts above are: a position restated here would keep compiling if the crate renumbered,
    /// and describe a decoded frame wrongly rather than fail.
    private static let frameKeyframe = slopdesk_video_reassembler_frame_flag(0)
    private static let frameCrisp = slopdesk_video_reassembler_frame_flag(1)
    private static let frameRecoveredViaFEC = slopdesk_video_reassembler_frame_flag(2)
    private static let frameIsLTR = slopdesk_video_reassembler_frame_flag(3)
    private static let frameAckedAnchored = slopdesk_video_reassembler_frame_flag(4)
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
