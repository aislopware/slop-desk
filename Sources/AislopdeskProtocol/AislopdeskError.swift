/// Errors thrown while decoding Aislopdesk wire frames.
///
/// These are decode-time faults: a frame that is too large to be legitimate, a
/// truncated body that can never complete, an unknown message type, or a body
/// whose contents do not match the type's declared layout. Partial frames that
/// might still complete are **not** errors — the decoder simply waits (see
/// ``FrameDecoder``).
public enum AislopdeskError: Error, Equatable, Sendable {
    /// A frame's length prefix exceeded ``Aislopdesk/maxFramePayloadLength``.
    /// Associated value is the offending claimed payload length.
    case frameTooLarge(Int)

    /// A complete frame's body was shorter than the message type requires
    /// (e.g. an `exit` frame whose payload is fewer than 4 bytes). Distinct from
    /// a partial TCP read, which is not an error.
    case truncated

    /// The frame's first byte was not a recognized ``WireMessage`` type.
    /// Associated value is the unknown type byte.
    case unknownMessageType(UInt8)

    /// A body had the right length but malformed contents (e.g. invalid UTF-8 in
    /// a `title`). Associated value is a short human-readable reason.
    case malformedBody(String)
}
