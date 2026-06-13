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
    /// Delegates to the Rust `aislopdesk-core` codec via the FFI (``RustFFI/encodeFrame(_:)``),
    /// the single source of truth shared with the Android client — byte-identical to
    /// ``encodeNative()`` (proven by golden vectors and re-proven through the wrapper by
    /// `RustWireParityTests`). Large bulk `.output`/`.input` payloads stay on the native
    /// zero-copy encoder, where Rust's extra FFI copies would regress the flood path (see
    /// ``RustFFI/payloadThreshold``); the common case + all control traffic use the faster Rust path.
    public func encode() -> Data {
        if exceedsRustCodecThreshold { return encodeNative() }
        return RustFFI.encodeFrame(self)
    }

    /// True for the bulk DATA variants (`.output`/`.input`) whose payload is large enough that
    /// the Rust codec's extra FFI buffer copies would regress the native zero-copy path.
    private var exceedsRustCodecThreshold: Bool {
        switch self {
        case let .output(_, bytes): return bytes.count > RustFFI.payloadThreshold
        case let .input(bytes): return bytes.count > RustFFI.payloadThreshold
        default: return false
        }
    }

    /// The native Swift frame encoder. Retained as the differential/benchmark baseline and as
    /// the safety fallback inside ``RustFFI/encodeFrame(_:)``; ``encode()`` is the production
    /// entry point and routes through Rust.
    func encodeNative() -> Data {
        // Build the whole frame in ONE buffer: a 4-byte length placeholder, then [messageType][body…],
        // then BACK-PATCH the prefix with the payload length. This avoids an intermediate `body` Data
        // and the extra whole-payload copy it forced — notably the up-to-128 KiB `.output` payload under
        // a flood (the old code memcpy'd that payload twice: into `body`, then into `frame`).
        var frame = Data()
        frame.append(contentsOf: [0, 0, 0, 0]) // length prefix placeholder (back-patched below)
        frame.append(messageType)

        switch self {
        case let .output(seq, bytes):
            frame.appendBE(seq)
            frame.append(bytes)

        case let .exit(code):
            frame.appendBE(code)

        case let .input(bytes):
            frame.append(bytes)

        case let .hello(protocolVersion, sessionID, lastReceivedSeq):
            frame.appendBE(protocolVersion)
            frame.append(sessionID.dataBytes)
            frame.appendBE(lastReceivedSeq)

        case let .resize(cols, rows, pxWidth, pxHeight):
            frame.appendBE(cols)
            frame.appendBE(rows)
            frame.appendBE(pxWidth)
            frame.appendBE(pxHeight)

        case let .ack(seq):
            frame.appendBE(seq)

        case .bye:
            break // empty body

        case let .ping(timestampMS):
            frame.appendBE(timestampMS)

        case let .pong(timestampMS):
            frame.appendBE(timestampMS)

        case let .helloAck(sessionID, resumeFromSeq, returningClient):
            frame.append(sessionID.dataBytes)
            frame.appendBE(resumeFromSeq)
            frame.append(returningClient ? 1 : 0)

        case let .title(string):
            frame.append(Data(string.utf8))

        case let .notification(title, body):
            // [UInt16 BE titleLen][title UTF-8][body UTF-8] — the title is length-prefixed so the
            // body (which may contain anything, incl. no delimiter) is the unambiguous remainder.
            // Clamp the title to the UInt16 length the field can hold (see clampedNotificationTitle): a
            // raw `truncatingIfNeeded` would WRAP the length on a >64KiB title while still appending every
            // byte, so the decoder would mis-split title/body and CORRUPT the body.
            let titleBytes = Data(Self.clampedNotificationTitle(title).utf8)
            frame.appendBE(UInt16(titleBytes.count))
            frame.append(titleBytes)
            frame.append(Data(body.utf8))

        case .bell:
            break // empty body

        case let .commandStatus(status):
            // Tag byte discriminates the two cases; `.idle`'s body is FIXED-SIZE (no
            // length-prefix needed) — a presence flag + a manual BE Int32 exit + a BE
            // UInt32 duration, matching the manual-binary style (never JSON/Codable).
            switch status {
            case .running:
                frame.append(0)
            case let .idle(exitCode, durationMS):
                frame.append(1)
                frame.append(exitCode != nil ? 1 : 0)   // hasExit
                frame.appendBE(exitCode ?? 0)            // Int32 BE (0 when absent)
                frame.appendBE(durationMS)               // UInt32 BE
            }
        }

        // payloadLength counts [messageType][body] — everything after the 4-byte prefix — exactly the
        // value the old `UInt32(body.count)` carried.
        let payloadLength = UInt32(frame.count - 4)
        let s = frame.startIndex
        frame[s]     = UInt8(truncatingIfNeeded: payloadLength >> 24)
        frame[s + 1] = UInt8(truncatingIfNeeded: payloadLength >> 16)
        frame[s + 2] = UInt8(truncatingIfNeeded: payloadLength >> 8)
        frame[s + 3] = UInt8(truncatingIfNeeded: payloadLength)
        return frame
    }

    /// A notification title whose UTF-8 fits the wire's UInt16 length field (≤ 65535 bytes), clamped at a
    /// Character boundary so it stays valid UTF-8. Identity for any sane title (the only producer caps the
    /// OSC at 1KiB); only an absurd >64KiB title is shortened — preventing the length field from wrapping
    /// and corrupting the body. Shared by ``encode()`` and ``wireByteCount`` so the two stay consistent.
    static func clampedNotificationTitle(_ title: String) -> String {
        guard title.utf8.count > Int(UInt16.max) else { return title }
        var clamped = "", count = 0
        for ch in title {
            let n = String(ch).utf8.count
            if count + n > Int(UInt16.max) { break }
            clamped.append(ch); count += n
        }
        return clamped
    }
}

extension WireMessage {
    /// The exact number of bytes ``encode()`` produces for this message, computed WITHOUT
    /// building the frame (no payload copy). Used by the receive-side flow-control
    /// crediting: the consumer credits `wireByteCount` per consumed message, which matches
    /// the sender's per-frame debit exactly (`.channelData` chunking partitions inner
    /// frames, so the chunk payloads of one frame sum to this). Pinned to `encode().count`
    /// for every variant by `WireMessageWireByteCountTests`.
    public var wireByteCount: Int {
        let body: Int
        switch self {
        case let .output(_, bytes): body = 8 + bytes.count            // seq Int64 + payload
        case .exit: body = 4                                          // code Int32
        case let .input(bytes): body = bytes.count
        case .hello: body = 2 + Self.sessionIDByteCount + 8           // UInt16 + UUID + Int64
        case .resize: body = 8                                        // 4 × UInt16
        case .ack: body = 8                                           // seq Int64
        case .bye: body = 0
        case .ping, .pong: body = 8                                   // timestampMS UInt64
        case .helloAck: body = Self.sessionIDByteCount + 8 + 1        // UUID + Int64 + Bool
        case let .title(string): body = string.utf8.count
        case let .notification(title, bodyText): body = 2 + Self.clampedNotificationTitle(title).utf8.count + bodyText.utf8.count  // UInt16 len + (clamped) title + body
        case .bell: body = 0
        case let .commandStatus(status):
            switch status {
            case .running: body = 1                                   // tag
            case .idle: body = 1 + 1 + 4 + 4                          // tag + hasExit + Int32 + UInt32
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
