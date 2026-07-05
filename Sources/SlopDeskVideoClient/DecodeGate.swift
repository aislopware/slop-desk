import SlopDeskVideoProtocol

/// PRE-EMPTIVE drop-until-anchor decode admission (decode-fail cascade fix, 2026-06-12).
///
/// WHY: a delta that (transitively) references an unrecoverably-lost frame cannot decode — VT
/// throws -12909 (HW-measured, 9/9 in the self-heal probe). The client used to learn that the
/// hard way, PER FRAME: every post-loss delta was submitted, failed, tore down the
/// `VTDecompressionSession` (`invalidateSession`), and fired its own `requestIDR` — measured live
/// (139s parity session): 9 wire losses amplified into 23 decode-fails + 63 IDR re-requests. The
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
/// LTR is enabled (measured live 2026-06-12: 7865/7874 frames) — bit 6 means "ack me on decode",
/// not "decodable past a loss". The first gate deploy admitted bit 6 and ate exactly one VT
/// failure per loss episode through ordinary chain deltas.
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
/// Wrap-aware (`UInt32.distanceWrapped`, the reassembler's sequence-space discipline) — no clock,
/// no transport — headlessly unit-testable.
///
/// Native Swift is the single source of truth for the drop-until-anchor state machine. This is a
/// `final class` (not a value struct) so the single owner (`SlopDeskVideoClientSession`) holds it
/// by reference and mutates it in place across the decode loop. `@unchecked Sendable` is sound
/// because that owner only touches it on its actor (and the tests from one thread), so no two
/// threads race the mutable state.
public final class DecodeGate: @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        /// Chain intact — everything submits.
        case open
        /// ≥1 unrecoverable loss since the last anchor; the decoder session is still alive.
        case brokenChain
        /// The decoder session is invalid (hard failure / never configured) — keyframe only.
        case needKeyframe
    }

    public enum Verdict: Sendable, Equatable {
        case submit
        case drop
    }

    /// The current admission mode.
    public private(set) var mode: Mode = .open
    /// OLDEST lost frameID of the episode — the chain is intact strictly BEFORE this id, so an
    /// older in-flight delta may still submit (its references predate the break).
    public private(set) var minLostFrameID: UInt32?
    /// NEWEST lost frameID of the episode — an anchor must decode strictly PAST this id to prove
    /// the chain re-anchored (same keep-newest discipline as `LTREscalationTracker.maxLostFrameID`).
    public private(set) var maxLostFrameID: UInt32?

    public init() {}

    /// One unrecoverably-lost frame (the reassembler's `.dropped` / drain path). Opens the episode;
    /// `needKeyframe` is strictly stronger and is never downgraded by a mere loss.
    public func noteLoss(frameID: UInt32) {
        if mode == .open { mode = .brokenChain }
        if let mx = maxLostFrameID {
            if frameID.distanceWrapped(from: mx) > 0 { maxLostFrameID = frameID }
        } else {
            maxLostFrameID = frameID
        }
        if let mn = minLostFrameID {
            if frameID.distanceWrapped(from: mn) < 0 { minLostFrameID = frameID }
        } else {
            minLostFrameID = frameID
        }
    }

    /// A hard decode failure tore the session down (`invalidateSession`) — only an IDR helps now.
    public func noteHardDecodeFailure() {
        mode = .needKeyframe
    }

    /// The decoder reported `awaitingKeyframe` (no session/parameter sets yet) — same anchor set.
    public func noteAwaitingKeyframe() {
        mode = .needKeyframe
    }

    /// Admission decision for one reassembled frame. Pure — never mutates; the caller acts.
    public func verdict(frameID: UInt32, keyframe: Bool, ackedAnchored: Bool) -> Verdict {
        switch mode {
        case .open:
            return .submit
        case .needKeyframe:
            return keyframe ? .submit : .drop
        case .brokenChain:
            if keyframe || ackedAnchored { return .submit }
            // Pre-break delta still in flight: references predate the OLDEST loss.
            if let mn = minLostFrameID, frameID.distanceWrapped(from: mn) < 0 { return .submit }
            return .drop
        }
    }

    /// Folds one SUCCESSFUL decode. A keyframe re-opens the gate unless a loss NEWER than it is
    /// already on record (the chain past the keyframe is still broken — stay `brokenChain` so the
    /// next refresh/IDR can finish the job). A non-keyframe success newer than every loss is the
    /// healed LTR anchor (mirrors `LTREscalationTracker.frameDecoded`).
    public func noteDecodeSucceeded(frameID: UInt32, keyframe: Bool) {
        if keyframe {
            if let mx = maxLostFrameID, frameID.distanceWrapped(from: mx) <= 0 {
                // The keyframe predates the newest loss: it re-anchored the chain UP TO itself, but
                // losses past it remain. Downgrade to brokenChain (which then admits an acked-LTR
                // refresh) ONLY if the session was still ALIVE — i.e. we were in brokenChain, so the
                // pre-loss acked LTRs survive in the DPB and an LTR refresh can decode. If the session
                // had been TORN DOWN (needKeyframe: invalidateSession wiped the DPB), a stale keyframe
                // rebuilds it with an empty/keyframe-only DPB — NO pre-teardown acked LTR survives, so
                // admitting an ackedAnchored refresh would feed VT a reference it no longer holds
                // (-12909) → another decode-fail / teardown / IDR round, the exact churn this gate
                // prevents. Stay needKeyframe so only a keyframe NEWER than the loss can re-anchor.
                if mode != .needKeyframe { mode = .brokenChain }
            } else {
                reset()
            }
            return
        }
        guard mode == .brokenChain, let mx = maxLostFrameID,
              frameID.distanceWrapped(from: mx) > 0 else { return }
        reset()
    }

    private func reset() {
        mode = .open
        minLostFrameID = nil
        maxLostFrameID = nil
    }
}
