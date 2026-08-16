import CSlopDeskFFI

/// Top-level namespace for SlopDesk wire-protocol constants.
///
/// Every number here is ASKED for rather than spelled: `rust/slopdesk-wire` owns the wire, and a
/// constant typed on both sides of a boundary is the cheapest possible way for the two to disagree
/// — a version bump that lands in one language reads as a handshake failure, not as a mistake.
public enum SlopDesk {
    /// Current wire-protocol version, sent in the `hello` handshake.
    ///
    /// Bumped whenever the framing, message-type table, or any body layout changes
    /// in a non-backward-compatible way.
    public static let protocolVersion = UInt16(slopdesk_wire_constant(0))

    /// Maximum accepted frame payload size.
    ///
    /// A length prefix larger than this is rejected with ``SlopDeskError/frameTooLarge(_:)``
    /// rather than buffered — it almost certainly means a corrupt or hostile stream,
    /// and we will not allocate unbounded memory for it. The PTY hot path produces
    /// small frames; legitimate output is chunked far below this ceiling.
    public static let maxFramePayloadLength = slopdesk_wire_constant(2)
}
