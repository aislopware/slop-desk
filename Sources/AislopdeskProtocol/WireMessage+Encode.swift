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
    public func encode() -> Data {
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
