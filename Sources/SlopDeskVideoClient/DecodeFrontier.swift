import CSlopDeskFFI

/// The client's decode frontier: the wrap-aware highest frameID that SUCCESSFULLY decoded.
/// Every recovery request (`requestIDR` / `requestLTRRefresh`) carries ``wireValue`` so the
/// host's delivery-keyed `RecoveryIDRPolicy` can tell whether a
/// recently-sent keyframe reached this client (request newer ⇒ delivered) or is a presumed
/// casualty (request older + past the in-flight grace ⇒ bypass the cooldown).
///
/// The law is `rust/slopdesk-video`'s `decode_admission`; this is its face. Two fields cross by
/// value — the frontier and whether there is one — so a late out-of-order decode can never move it
/// backwards and the sentinel is never a frame id.
public struct DecodeFrontier: Sendable, Equatable {
    private var record: SlopDeskDecodeFrontier

    public init() { record = slopdesk_decode_frontier_new() }

    /// The frontier itself, or `nil` when nothing has decoded.
    public var lastDecodedFrameID: UInt32? {
        record.has_last_decoded ? record.last_decoded_frame_id : nil
    }

    /// Folds one successfully-decoded frame. Keep-newest, wrap-aware; older/equal ids are no-ops.
    public mutating func noteDecoded(frameID: UInt32) {
        record = slopdesk_decode_frontier_note_decoded(record, frameID)
    }

    /// The on-wire field value: the frontier id, or `RecoveryMessage.noFrameDecodedSentinel`
    /// when nothing has decoded yet (frameIDs start at 0, so 0 cannot be the sentinel).
    public var wireValue: UInt32 { slopdesk_decode_frontier_wire_value(record) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.record.has_last_decoded == rhs.record.has_last_decoded
            && lhs.record.last_decoded_frame_id == rhs.record.last_decoded_frame_id
    }
}
