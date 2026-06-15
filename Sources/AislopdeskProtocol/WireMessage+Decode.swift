import Foundation

extension WireMessage {
    /// Decodes a message from a **complete payload** (`[UInt8 messageType][body...]`,
    /// without the length prefix — framing is handled by ``FrameDecoder``).
    ///
    /// - Throws: ``AislopdeskError/truncated`` if the body is shorter than the type
    ///   requires, ``AislopdeskError/unknownMessageType(_:)`` for an unrecognized type
    ///   byte, or ``AislopdeskError/malformedBody(_:)`` for a right-length-but-invalid
    ///   body (e.g. bad UTF-8).
    ///
    /// Decodes through the Rust `aislopdesk-core` codec via the FFI (``RustFFI/decodePayload(_:)``)
    /// — the single source of truth shared with the Android client (the wire format is pinned by
    /// golden vectors). The bulk `.output`/`.input` variants take a zero-copy borrowed-view path;
    /// control messages use the flat-struct codec.
    static func decode(payload: Data) throws -> WireMessage {
        try RustFFI.decodePayload(payload)
    }
}
