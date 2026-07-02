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
    /// Native Swift — the single source of truth for the terminal (path-1) wire codec,
    /// pinned by the `terminalWireMessages` golden vectors. The hot path uses manual
    /// big-endian binary decoding (never JSON/`Codable`); all string fields are STRICT
    /// UTF-8 (an invalid sequence throws ``AislopdeskError/malformedBody(_:)``, never a
    /// lossy/replacement decode — only the video path is lossy).
    static func decode(payload: Data) throws -> WireMessage {
        var reader = BigEndianReader(payload)
        let type = try reader.readUInt8()

        switch type {
        case 1: // output
            let seq = try reader.readInt64()
            return .output(seq: seq, bytes: reader.remaining())

        case 2: // exit
            let code = try reader.readInt32()
            return .exit(code: code)

        case 3: // input
            return .input(reader.remaining())

        case 10: // hello
            let version = try reader.readUInt16()
            let idBytes = try reader.readBytes(sessionIDByteCount)
            let lastReceivedSeq = try reader.readInt64()
            guard let sessionID = UUID(dataBytes: idBytes) else {
                throw AislopdeskError.malformedBody("hello: invalid sessionID bytes")
            }
            return .hello(protocolVersion: version, sessionID: sessionID, lastReceivedSeq: lastReceivedSeq)

        case 11: // resize
            let cols = try reader.readUInt16()
            let rows = try reader.readUInt16()
            let pxWidth = try reader.readUInt16()
            let pxHeight = try reader.readUInt16()
            return .resize(cols: cols, rows: rows, pxWidth: pxWidth, pxHeight: pxHeight)

        case 12: // ack
            return try .ack(seq: reader.readInt64())

        case 13: // bye
            return .bye

        case 14: // ping
            return try .ping(timestampMS: reader.readUInt64())

        case 15: // requestBlockOutput
            return try .requestBlockOutput(index: reader.readUInt32())

        case 16: // metadataRequest
            let requestID = try reader.readUInt32()
            let verb = try reader.readUInt8()
            // Validate the declared payload length BEFORE allocating/reading: readBytes throws
            // `truncated` if the body is shorter than the declared count — never over-reading a
            // hostile body. The payload is opaque here (the per-verb MetadataCodec validates it).
            let payloadLen = try Int(reader.readUInt32())
            let payload = try reader.readBytes(payloadLen)
            return .metadataRequest(requestID: requestID, verb: verb, payload: payload)

        case 20: // helloAck
            let idBytes = try reader.readBytes(sessionIDByteCount)
            let resumeFromSeq = try reader.readInt64()
            let returningByte = try reader.readUInt8()
            guard let sessionID = UUID(dataBytes: idBytes) else {
                throw AislopdeskError.malformedBody("helloAck: invalid sessionID bytes")
            }
            return .helloAck(
                sessionID: sessionID,
                resumeFromSeq: resumeFromSeq,
                returningClient: returningByte != 0,
            )

        case 21: // title
            let bytes = reader.remaining()
            guard let string = String(data: bytes, encoding: .utf8) else {
                throw AislopdeskError.malformedBody("title: invalid UTF-8")
            }
            return .title(string)

        case 22: // bell
            return .bell

        case 23: // commandStatus
            let tag = try reader.readUInt8()
            switch tag {
            case 0:
                return .commandStatus(.running)
            case 1:
                let hasExit = try reader.readUInt8()
                let exitRaw = try reader.readInt32()
                let durationMS = try reader.readUInt32()
                return .commandStatus(.idle(exitCode: hasExit != 0 ? exitRaw : nil, durationMS: durationMS))
            default:
                throw AislopdeskError.malformedBody("commandStatus: invalid tag \(tag)")
            }

        case 24: // pong
            return try .pong(timestampMS: reader.readUInt64())

        case 25: // notification
            let titleLen = try Int(reader.readUInt16())
            let titleBytes = try reader.readBytes(titleLen)
            let bodyBytes = reader.remaining()
            guard let title = String(data: titleBytes, encoding: .utf8) else {
                throw AislopdeskError.malformedBody("notification: invalid title UTF-8")
            }
            guard let body = String(data: bodyBytes, encoding: .utf8) else {
                throw AislopdeskError.malformedBody("notification: invalid body UTF-8")
            }
            return .notification(title: title, body: body)

        case 26: // foregroundProcess
            let bytes = reader.remaining()
            guard let name = String(data: bytes, encoding: .utf8) else {
                throw AislopdeskError.malformedBody("foregroundProcess: invalid UTF-8")
            }
            return .foregroundProcess(name: name)

        case 27: // claudeStatus
            let state = try reader.readUInt8()
            let kind = try reader.readUInt8()
            // Validate the declared label length BEFORE reading: readBytes throws `truncated`
            // if the body is shorter than the declared count — never over-reading a hostile body.
            let labelLen = try Int(reader.readUInt16())
            let labelBytes = try reader.readBytes(labelLen)
            guard let label = String(data: labelBytes, encoding: .utf8) else {
                throw AislopdeskError.malformedBody("claudeStatus: invalid label UTF-8")
            }
            return .claudeStatus(state: state, kind: kind, label: label)

        case 28: // commandBlock
            let index = try reader.readUInt32()
            let hasExit = try reader.readUInt8()
            let exitRaw = try reader.readInt32()
            let hasDuration = try reader.readUInt8()
            let durationRaw = try reader.readUInt32()
            let complete = try reader.readUInt8()
            let outputLen = try reader.readUInt32()
            let promptOrdinal = try reader.readUInt32()
            // Validate the declared command-text length BEFORE reading: readBytes throws
            // `truncated` if the body is shorter than the declared count — never over-reading.
            let cmdLen = try Int(reader.readUInt16())
            let cmdBytes = try reader.readBytes(cmdLen)
            guard let commandText = String(data: cmdBytes, encoding: .utf8) else {
                throw AislopdeskError.malformedBody("commandBlock: invalid commandText UTF-8")
            }
            return .commandBlock(
                index: index,
                exitCode: hasExit != 0 ? exitRaw : nil,
                durationMS: hasDuration != 0 ? durationRaw : nil,
                complete: complete != 0,
                outputLen: outputLen,
                commandText: commandText,
                promptOrdinal: promptOrdinal,
            )

        case 29: // blockOutput
            let index = try reader.readUInt32()
            // Validate the declared output length BEFORE allocating/reading: readBytes throws
            // `truncated` if the body is shorter than the declared count — never over-reading a
            // hostile body. The output is raw bytes (control sequences preserved), not UTF-8.
            let outputLen = try Int(reader.readUInt32())
            let output = try reader.readBytes(outputLen)
            return .blockOutput(index: index, output: output)

        case 30: // metadataResponse
            let requestID = try reader.readUInt32()
            let status = try reader.readUInt8()
            // Validate the declared payload length BEFORE allocating/reading: readBytes throws
            // `truncated` if the body is shorter than the declared count — never over-reading a
            // hostile body. The payload is opaque here (the typed MetadataCodec/client validates it).
            let payloadLen = try Int(reader.readUInt32())
            let payload = try reader.readBytes(payloadLen)
            return .metadataResponse(requestID: requestID, status: status, payload: payload)

        case 31: // inputEcho
            // 1-byte body: the canonical-echo flag. Validate-then-drop on a short body (`readUInt8`
            // throws `truncated` if the body is missing — never an over-read of a hostile datagram).
            // Read as `byte != 0` (untrusted-bool rule — never assume {0,1}); any trailing bytes are
            // ignored, matching the file's forward-tolerant fixed-field decoders (bell/ack/etc.).
            let echoByte = try reader.readUInt8()
            return .inputEcho(enabled: echoByte != 0)

        case 32: // progress
            // Exactly 2 bytes: [UInt8 state][UInt8 percent]. `readUInt8` throws `truncated` on a short
            // body (validate-then-drop — never over-reads a hostile datagram). The state is carried
            // VERBATIM here (an unknown discriminant is not rejected by the codec) so the byte
            // round-trip stays faithful and the golden vector is stable; the CLIENT handler validates
            // it via `ProgressState(wire:)` and drops an unknown state. Trailing bytes are ignored,
            // matching the file's other fixed-field decoders (inputEcho/bell/ack).
            let state = try reader.readUInt8()
            let percent = try reader.readUInt8()
            return .progress(state: state, percent: percent)

        case 33: // cwd
            let bytes = reader.remaining()
            guard let path = String(data: bytes, encoding: .utf8) else {
                throw AislopdeskError.malformedBody("cwd: invalid UTF-8")
            }
            return .cwd(path)

        default:
            throw AislopdeskError.unknownMessageType(type)
        }
    }
}
