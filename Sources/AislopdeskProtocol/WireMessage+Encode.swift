import Foundation

extension WireMessage {
    /// Number of bytes occupied by a UUID on the wire (its 16 raw bytes).
    static let sessionIDByteCount = 16

    /// All-zero UUID used in `hello` to request a brand-new session.
    public static let newSessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Encodes this message into a complete frame, ready to write to a socket:
    /// `[UInt32 BE payloadLength][UInt8 messageType][body...]`.
    ///
    /// `payloadLength` counts `messageType` + `body` and excludes the 4 prefix
    /// bytes — exactly what ``FrameDecoder`` expects.
    ///
    /// Encodes through the Rust `aislopdesk-core` codec via the FFI (``RustFFI/encodeFrame(_:)``) —
    /// the single source of truth shared with the Android client (the wire format is pinned by
    /// golden vectors). The bulk `.output`/`.input` variants take a zero-copy single-payload-copy
    /// path; control messages use the flat-struct codec.
    public func encode() -> Data {
        RustFFI.encodeFrame(self)
    }

    /// A notification title whose UTF-8 fits the wire's UInt16 length field (≤ 65535 bytes), clamped at a
    /// Character boundary so it stays valid UTF-8. Identity for any sane title (the only producer caps the
    /// OSC at 1KiB); only an absurd >64KiB title is shortened — preventing the length field from wrapping
    /// and corrupting the body. Shared by ``encode()`` and ``wireByteCount`` so the two stay consistent.
    static func clampedNotificationTitle(_ title: String) -> String {
        guard title.utf8.count > Int(UInt16.max) else { return title }
        // Clamp at a Unicode SCALAR boundary (not a grapheme cluster) so this matches the Rust
        // core's `clamped_notification_title` (which iterates `char_indices`) byte-for-byte —
        // keeping native `wireByteCount` consistent with the Rust `encode()` length even for a
        // >64KiB title whose cut would straddle a multi-scalar grapheme. (Unreachable in
        // production — the OSC producer caps titles at ~1KiB — but it keeps the encode()↔
        // wireByteCount flow-control parity contract honest; see RustWireParityTests.)
        var clamped = String.UnicodeScalarView()
        var count = 0
        for scalar in title.unicodeScalars {
            let n = String(scalar).utf8.count
            if count + n > Int(UInt16.max) { break }
            clamped.append(scalar)
            count += n
        }
        return String(clamped)
    }
}

public extension WireMessage {
    /// The exact number of bytes ``encode()`` produces for this message, computed WITHOUT
    /// building the frame (no payload copy). Used by the receive-side flow-control
    /// crediting: the consumer credits `wireByteCount` per consumed message, which matches
    /// the sender's per-frame debit exactly (`.channelData` chunking partitions inner
    /// frames, so the chunk payloads of one frame sum to this). Pinned to `encode().count`
    /// for every variant by `WireMessageWireByteCountTests`.
    var wireByteCount: Int {
        let body: Int =
            switch self {
            case let .output(_, bytes): 8 + bytes.count // seq Int64 + payload
            case .exit: 4 // code Int32
            case let .input(bytes): bytes.count
            case .hello: 2 + Self.sessionIDByteCount + 8 // UInt16 + UUID + Int64
            case .resize: 8 // 4 × UInt16
            case .ack: 8 // seq Int64
            case .bye: 0
            case .ping,
                 .pong: 8 // timestampMS UInt64
            case .helloAck: Self.sessionIDByteCount + 8 + 1 // UUID + Int64 + Bool
            case let .title(string): string.utf8.count
            case let .notification(title, bodyText): 2 + Self.clampedNotificationTitle(title).utf8.count + bodyText.utf8
                .count // UInt16 len + (clamped) title + body
            case .bell: 0
            case let .commandStatus(status):
                switch status {
                case .running: 1 // tag
                case .idle: 1 + 1 + 4 + 4 // tag + hasExit + Int32 + UInt32
                }
            }
        // 4-byte length prefix + 1 type byte + body (see encode()).
        return 4 + 1 + body
    }
}

extension UUID {
    /// The UUID's 16 raw bytes as `Data`, in canonical order.
    var dataBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    /// Builds a UUID from exactly 16 raw bytes. Returns `nil` otherwise.
    init?(dataBytes data: Data) {
        guard data.count == 16 else { return nil }
        var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { dest in
            _ = data.copyBytes(to: dest)
        }
        self.init(uuid: raw)
    }
}
