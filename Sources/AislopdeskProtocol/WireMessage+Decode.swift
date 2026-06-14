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
    /// Delegates to the Rust `aislopdesk-core` codec via the FFI (``RustFFI/decodePayload(_:)``),
    /// the single source of truth shared with the Android client — behaviour-identical to
    /// ``decodeNative(payload:)`` (re-proven through the wrapper by `RustWireParityTests`). A
    /// large bulk payload stays on the native decoder, where Rust's extra FFI copies would
    /// regress the flood path (see ``RustFFI/payloadThreshold``).
    static func decode(payload: Data) throws -> WireMessage {
        if payload.count > RustFFI.payloadThreshold { return try decodeNative(payload: payload) }
        return try RustFFI.decodePayload(payload)
    }

    /// The native Swift payload decoder. Retained as the differential/benchmark baseline;
    /// ``decode(payload:)`` is the production entry point and routes through Rust.
    static func decodeNative(payload: Data) throws -> WireMessage {
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

        default:
            throw AislopdeskError.unknownMessageType(type)
        }
    }
}
