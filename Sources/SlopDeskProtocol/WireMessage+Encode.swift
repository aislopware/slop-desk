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
    /// Native Swift — the single source of truth for the terminal (path-1) wire codec,
    /// pinned by the `terminalWireMessages` golden vectors. Manual big-endian binary
    /// encoding (never JSON/`Codable`); all multi-byte ints big-endian, UUIDs are 16 raw
    /// bytes, strings are UTF-8.
    public func encode() -> Data {
        // Build the whole frame in ONE buffer: a 4-byte length placeholder, then [messageType][body…],
        // then BACK-PATCH the prefix with the payload length. This avoids an intermediate `body` Data
        // and the extra whole-payload copy it forced — notably the up-to-128 KiB `.output` payload under
        // a flood (a naive approach would memcpy that payload twice: into `body`, then into `frame`).
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

        case let .requestBlockOutput(index):
            frame.appendBE(index)

        case let .pong(timestampMS):
            frame.appendBE(timestampMS)

        case let .helloAck(sessionID, resumeFromSeq, returningClient):
            frame.append(sessionID.dataBytes)
            frame.appendBE(resumeFromSeq)
            frame.append(returningClient ? 1 : 0)

        case let .title(string):
            frame.append(Data(string.utf8))

        case let .cwd(path):
            frame.append(Data(path.utf8))

        case let .projectKey(path):
            frame.append(Data(path.utf8))

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

        case let .foregroundProcess(name):
            // [remaining bytes = UTF-8 process basename] — like `title`, the name is the
            // unambiguous remainder (no length prefix needed for a single trailing string).
            frame.append(Data(name.utf8))

        case let .claudeStatus(state, kind, label):
            // [UInt8 state][UInt8 kind][UInt16 BE labelLen][label UTF-8] — fixed state+kind
            // bytes then a length-prefixed UTF-8 label (so an empty label is unambiguous).
            // Clamp the label to the UInt16 length the field can hold (see clampedClaudeLabel):
            // a raw `truncatingIfNeeded` would WRAP the length on a >64KiB label while still
            // appending every byte, so the decoder would over-read and corrupt the trailer.
            frame.append(state)
            frame.append(kind)
            let labelBytes = Data(Self.clampedClaudeLabel(label).utf8)
            frame.appendBE(UInt16(labelBytes.count))
            frame.append(labelBytes)

        case let .commandBlock(index, exitCode, durationMS, complete, outputLen, commandText, promptOrdinal):
            // [UInt32 index][UInt8 hasExit][Int32 BE exit (0 absent)][UInt8 hasDuration]
            // [UInt32 BE duration (0 absent)][UInt8 complete][UInt32 BE outputLen]
            // [UInt32 BE promptOrdinal (0 unknown)]
            // [UInt16 BE cmdLen][commandText UTF-8]. Fixed fields then a length-prefixed,
            // capped command line (so the decoder can validate its declared length before reading).
            // Clamp the command text to the UInt16 length field (see clampedCommandText): a raw
            // truncatingIfNeeded would WRAP the length on a >64KiB text while still appending every
            // byte → the decoder would over-read and corrupt nothing trailing (cmd is the last field)
            // but mis-report the length, so clamp the BYTES too to stay self-consistent.
            frame.appendBE(index)
            frame.append(exitCode != nil ? 1 : 0) // hasExit
            frame.appendBE(exitCode ?? 0) // Int32 BE (0 when absent)
            frame.append(durationMS != nil ? 1 : 0) // hasDuration
            frame.appendBE(durationMS ?? 0) // UInt32 BE (0 when absent)
            frame.append(complete ? 1 : 0)
            frame.appendBE(outputLen)
            frame.appendBE(promptOrdinal)
            let cmdBytes = Data(Self.clampedCommandText(commandText).utf8)
            frame.appendBE(UInt16(cmdBytes.count))
            frame.append(cmdBytes)

        case let .blockOutput(index, output):
            // [UInt32 index][UInt32 BE outputLen][output bytes]. The output is length-prefixed so the
            // decoder validates the declared length before reading (never over-reads a hostile body).
            frame.appendBE(index)
            frame.appendBE(UInt32(truncatingIfNeeded: output.count))
            frame.append(output)

        case let .metadataRequest(requestID, verb, payload):
            // [UInt32 BE requestID][UInt8 verb][UInt32 BE payloadLen][payload bytes]. The payload is
            // length-prefixed so the decoder validates the declared length before reading (never
            // over-reads a hostile body); the inner per-verb MetadataCodec validates the bytes.
            frame.appendBE(requestID)
            frame.append(verb)
            frame.appendBE(UInt32(truncatingIfNeeded: payload.count))
            frame.append(payload)

        case let .metadataResponse(requestID, status, payload):
            // [UInt32 BE requestID][UInt8 status][UInt32 BE payloadLen][payload bytes]. Same shape as
            // metadataRequest with a status byte in place of the verb; the payload is length-prefixed
            // and opaque (a MetadataCodec list encoding or raw cwd/diff/session bytes).
            frame.appendBE(requestID)
            frame.append(status)
            frame.appendBE(UInt32(truncatingIfNeeded: payload.count))
            frame.append(payload)

        case let .inputEcho(enabled):
            // [UInt8 enabled] — a single canonical-echo flag (1 = echo on, 0 = no-echo prompt).
            frame.append(enabled ? 1 : 0)

        case let .progress(state, percent):
            // [UInt8 state][UInt8 percent] — two raw bytes (no BE needed for single bytes). The state
            // is carried verbatim so the codec is a faithful round-trip; the client re-validates via
            // ProgressState(wire:) and drops an unknown discriminant.
            frame.append(state)
            frame.append(percent)

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
                frame.append(exitCode != nil ? 1 : 0) // hasExit
                frame.appendBE(exitCode ?? 0) // Int32 BE (0 when absent)
                frame.appendBE(durationMS) // UInt32 BE
            }
        }

        // payloadLength counts [messageType][body] — everything after the 4-byte prefix.
        let payloadLength = UInt32(frame.count - 4)
        let s = frame.startIndex
        frame[s] = UInt8(truncatingIfNeeded: payloadLength >> 24)
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

    /// A Claude-status label whose UTF-8 fits the wire's UInt16 length field (≤ 65535 bytes),
    /// clamped at a Unicode SCALAR boundary so it stays valid UTF-8. Identity for any sane
    /// label (the host caps Stop/Notification text well under 1KiB); only an absurd >64KiB
    /// label is shortened — preventing the length field from wrapping and corrupting the body.
    /// Shared by ``encode()`` and ``wireByteCount`` so the two stay consistent.
    static func clampedClaudeLabel(_ label: String) -> String {
        guard label.utf8.count > Int(UInt16.max) else { return label }
        var clamped = String.UnicodeScalarView()
        var count = 0
        for scalar in label.unicodeScalars {
            let n = String(scalar).utf8.count
            if count + n > Int(UInt16.max) { break }
            clamped.append(scalar)
            count += n
        }
        return String(clamped)
    }

    /// A Block command line whose UTF-8 fits the wire's UInt16 length field (≤ 65535 bytes),
    /// clamped at a Unicode SCALAR boundary so it stays valid UTF-8. Identity for any sane command
    /// (the segmenter caps captured command text at 256 bytes); only an absurd >64KiB text is
    /// shortened — preventing the length field from wrapping and the decoder mis-reading the count.
    /// Shared by ``encode()`` and ``wireByteCount`` so the two stay consistent.
    static func clampedCommandText(_ text: String) -> String {
        guard text.utf8.count > Int(UInt16.max) else { return text }
        var clamped = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
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
            case .requestBlockOutput: 4 // index UInt32
            case let .commandBlock(_, _, _, _, _, commandText, _):
                // index + hasExit + Int32 + hasDuration + UInt32 + complete + outputLen + promptOrdinal
                // + UInt16 len + cmd
                4 + 1 + 4 + 1 + 4 + 1 + 4 + 4 + 2 + Self.clampedCommandText(commandText).utf8.count
            case let .blockOutput(_, output): 4 + 4 + output.count // index + UInt32 len + output bytes
            case let .metadataRequest(_, _, payload): 4 + 1 + 4 + payload
                .count // requestID + verb + UInt32 len + payload
            case let .metadataResponse(_, _, payload): 4 + 1 + 4 + payload
                .count // requestID + status + UInt32 len + payload
            case .inputEcho: 1 // enabled UInt8
            case .progress: 2 // state UInt8 + percent UInt8
            case .helloAck: Self.sessionIDByteCount + 8 + 1 // UUID + Int64 + Bool
            case let .title(string): string.utf8.count
            case let .cwd(path): path.utf8.count
            case let .projectKey(path): path.utf8.count
            case let .notification(title, bodyText): 2 + Self.clampedNotificationTitle(title).utf8.count + bodyText.utf8
                .count // UInt16 len + (clamped) title + body
            case let .foregroundProcess(name): name.utf8.count
            case let .claudeStatus(_, _, label): 1 + 1 + 2 + Self.clampedClaudeLabel(label).utf8
                .count // state + kind + UInt16 len + (clamped) label
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
