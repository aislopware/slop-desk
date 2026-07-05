import SlopDeskVideoProtocol

/// The client's decode frontier: the wrap-aware highest frameID that SUCCESSFULLY decoded
/// (component 2, 2026-06-11). Every recovery request (`requestIDR` / `requestLTRRefresh`) now
/// carries ``wireValue`` so the host's delivery-keyed `RecoveryIDRPolicy` can tell whether a
/// recently-sent keyframe reached this client (request newer ⇒ delivered) or is a presumed
/// casualty (request older + past the in-flight grace ⇒ bypass the cooldown).
///
/// Pure value type — no transport, no clock — headlessly unit-testable. Monotonic by
/// `UInt32.distanceWrapped` (same sequence-space discipline as the reassembler), so a late
/// out-of-order decode can never move the frontier backwards.
public struct DecodeFrontier: Sendable, Equatable {
    public private(set) var lastDecodedFrameID: UInt32?

    public init() {}

    /// Folds one successfully-decoded frame. Keep-newest, wrap-aware; older/equal ids are no-ops.
    /// Native Swift twin of `slopdesk_core::decode_frontier::DecodeFrontier::note_decoded`: a
    /// late out-of-order decode (`frameID.distanceWrapped(from: current) <= 0`) is a no-op, so the
    /// frontier only ever advances in `UInt32`-wrap sequence space.
    public mutating func noteDecoded(frameID: UInt32) {
        if let current = lastDecodedFrameID, frameID.distanceWrapped(from: current) <= 0 {
            return
        }
        lastDecodedFrameID = frameID
    }

    /// The on-wire field value: the frontier id, or ``RecoveryMessage/noFrameDecodedSentinel``
    /// when nothing has decoded yet (frameIDs start at 0, so 0 cannot be the sentinel).
    public var wireValue: UInt32 { lastDecodedFrameID ?? RecoveryMessage.noFrameDecodedSentinel }
}
