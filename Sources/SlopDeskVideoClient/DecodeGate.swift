import CSlopDeskFFI

/// PRE-EMPTIVE drop-until-anchor decode admission.
///
/// WHY: a delta that (transitively) references an unrecoverably-lost frame cannot decode — VT
/// throws -12909 (HW-measured, 9/9 in the self-heal probe). Without this gate the client learns
/// that the hard way, PER FRAME: every post-loss delta gets submitted, fails, tears down the
/// `VTDecompressionSession` (`invalidateSession`), and fires its own `requestIDR` — measured
/// (139s parity session): 9 wire losses amplify into 23 decode-fails + 63 IDR re-requests. The
/// session teardown is the expensive part: it wipes the decoder's reference state (killing the
/// LTR recovery path's anchor) and forces a full reconfigure on the next keyframe.
///
/// THE GATE: once the reference chain is known-broken (`noteLoss`), deltas stop reaching VT at
/// all. Only ANCHOR CANDIDATES are submitted:
///  - a KEYFRAME (references nothing), or
///  - an ACKED-ANCHORED frame (wire bit 7 — a `ForceLTRRefresh` product: the host's recovery /
///    self-heal cadence refresh, forced against an LTR this client ACKED, i.e. one it provably
///    decoded BEFORE the loss; still held in the un-torn-down session's DPB precisely because
///    the gate kept garbage out of VT), or
///  - a delta OLDER than the oldest loss of the episode (its references predate the break).
/// NOTE bit 6 (`isLTR`) is NOT an anchor: VT surfaces an ack token on virtually EVERY frame once
/// LTR is enabled (measured live: 7865/7874 frames) — bit 6 means "ack me on decode", not
/// "decodable past a loss". Treating bit 6 as an anchor would admit ordinary chain deltas past
/// a break and eat exactly one VT failure per loss episode.
///
/// TWO BROKEN MODES — the anchor set differs:
///  - ``Mode/brokenChain``: the decoder session is alive (references survive) → keyframe OR LTR.
///  - ``Mode/needKeyframe``: the session itself is gone (`invalidateSession` after a hard failure,
///    or no IDR has ever configured it) → ONLY a keyframe can re-anchor.
///
/// LIVENESS stays with the caller: the escalation episode is armed by the loss-detection path
/// before the first drop, and the session re-runs its `shouldEscalateToIDR` check on every gated
/// drop — so a lost recovery frame still escalates to a forced IDR at the 2·RTT / escalation-floor
/// cadence, now WITHOUT a per-frame request storm.
///
/// The law is `rust/slopdesk-video`'s `decode_admission`; this is its face. The gate is five
/// scalars that cross BY VALUE, but the single owner (`SlopDeskVideoClientSession`) holds it by
/// REFERENCE and mutates it in place across the decode loop, so the type stays a `final class`
/// wrapping the record it folds. `@unchecked Sendable` is sound because that owner only touches it
/// on its actor (and the tests from one thread), so no two threads race the mutable state.
public final class DecodeGate: @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        /// Chain intact — everything submits.
        case open
        /// ≥1 unrecoverable loss since the last anchor; the decoder session is still alive.
        case brokenChain
        /// The decoder session is invalid (hard failure / never configured) — keyframe only.
        case needKeyframe

        /// The door's code as a mode. An unknown code cannot arise — the door emits exactly these
        /// three — and reads as the one a fresh gate holds.
        static func of(_ code: UInt32) -> Self {
            switch code {
            case UInt32(SLOPDESK_GATE_MODE_BROKEN_CHAIN): .brokenChain
            case UInt32(SLOPDESK_GATE_MODE_NEED_KEYFRAME): .needKeyframe
            default: .open
            }
        }
    }

    public enum Verdict: Sendable, Equatable {
        case submit
        case drop
    }

    private var record = slopdesk_decode_gate_new()

    public init() {}

    /// The current admission mode.
    public var mode: Mode { Mode.of(record.mode) }
    /// OLDEST lost frameID of the episode — the chain is intact strictly BEFORE this id, so an
    /// older in-flight delta may still submit (its references predate the break).
    public var minLostFrameID: UInt32? { record.has_min_lost ? record.min_lost_frame_id : nil }
    /// NEWEST lost frameID of the episode — an anchor must decode strictly PAST this id to prove
    /// the chain re-anchored (same keep-newest discipline as `LTREscalationTracker.maxLostFrameID`).
    public var maxLostFrameID: UInt32? { record.has_max_lost ? record.max_lost_frame_id : nil }

    /// One unrecoverably-lost frame (the reassembler's `.dropped` / drain path). Opens the episode;
    /// `needKeyframe` is strictly stronger and is never downgraded by a mere loss.
    public func noteLoss(frameID: UInt32) {
        record = slopdesk_decode_gate_note_loss(record, frameID)
    }

    /// A hard decode failure tore the session down (`invalidateSession`) — only an IDR helps now.
    public func noteHardDecodeFailure() {
        record = slopdesk_decode_gate_note_hard_decode_failure(record)
    }

    /// The decoder reported `awaitingKeyframe` (no session/parameter sets yet) — same anchor set.
    public func noteAwaitingKeyframe() {
        record = slopdesk_decode_gate_note_awaiting_keyframe(record)
    }

    /// Admission decision for one reassembled frame. Pure — never mutates; the caller acts.
    public func verdict(frameID: UInt32, keyframe: Bool, ackedAnchored: Bool) -> Verdict {
        slopdesk_decode_gate_submits(record, frameID, keyframe, ackedAnchored) ? .submit : .drop
    }

    /// Folds one SUCCESSFUL decode. A keyframe re-opens the gate unless a loss NEWER than it is
    /// already on record (the chain past the keyframe is still broken — stay `brokenChain` so the
    /// next refresh/IDR can finish the job). A non-keyframe success newer than every loss is the
    /// healed LTR anchor (mirrors `LTREscalationTracker.frameDecoded`).
    public func noteDecodeSucceeded(frameID: UInt32, keyframe: Bool) {
        record = slopdesk_decode_gate_note_decode_succeeded(record, frameID, keyframe)
    }
}
