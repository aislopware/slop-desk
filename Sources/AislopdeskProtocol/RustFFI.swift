import CAislopdeskFFI
import Foundation

/// Swift-side bridge that routes the terminal wire codec to the Rust core over the C ABI.
///
/// All `import CAislopdeskFFI` (and the unsafe pointer marshaling it requires) is
/// contained in this file; the rest of `AislopdeskProtocol` calls these typed, safe
/// wrappers, which forward `WireMessage` encode/decode to the codec in the Rust core
/// (`aislopdesk-core`) — the single source of truth (there is no native Swift codec).
/// Cross-language golden parity (the `golden_parity` test against the `aislopdesk-corevectors`
/// corpus) pins the codec's byte/bit output, and the Swift marshaling here is pinned to the wire
/// format by `RustWireCodecTests`, so the macOS/iOS app and a future Android client run *the
/// identical algorithm bytes* from the one shared core.
///
/// Memory contract (mirrors `aislopdesk_ffi.h`): buffers passed *in* are borrowed for the
/// call only (`cap == 0`, Rust copies and never frees them); any `AisdBytes` the library
/// returns owns a Rust allocation and is released with `aisd_bytes_free` /
/// `aisd_wire_message_free` before the wrapper returns.
enum RustFFI {
    /// Wrap-aware signed 32-bit sequence distance `a - b` (positive ⇒ `a` is ahead).
    static func seqDistance(_ a: UInt32, _ b: UInt32) -> Int32 {
        aisd_seq_distance(a, b)
    }

    // MARK: - WireMessage encode / decode

    /// Encodes a ``WireMessage`` into a complete length-prefixed wire frame — the Rust core is the
    /// single source of truth. The bulk DATA variants (`.output`/`.input`) take the zero-copy
    /// single-payload-copy path; every control message goes through the flat-struct encoder (its
    /// payloads are tiny, so the marshaling copies are negligible).
    static func encodeFrame(_ message: WireMessage) -> Data {
        switch message {
        case let .output(seq, bytes):
            encodeDataFrame(tag: 1, seq: seq, payload: bytes, frameSize: message.wireByteCount)
        case let .input(bytes):
            encodeDataFrame(tag: 3, seq: 0, payload: bytes, frameSize: message.wireByteCount)
        default:
            encodeControlFrame(message)
        }
    }

    /// Frames a DATA-channel message (`.output`/`.input`) directly into a pre-sized buffer with a
    /// SINGLE payload copy, matching the native encoder's cost. `frameSize` is the message's
    /// `wireByteCount` (the exact frame length). Wraps `aisd_wire_data_frame_encode_into`.
    private static func encodeDataFrame(tag: UInt8, seq: Int64, payload: Data, frameSize: Int) -> Data {
        var frame = Data(count: frameSize)
        let written: Int = frame.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            guard let outBase = out.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                preconditionFailure("RustFFI: \(frameSize)-byte frame buffer has a nil baseAddress")
            }
            var n = 0
            let status: AisdStatus = payload.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> AisdStatus in
                aisd_wire_data_frame_encode_into(
                    tag, seq, p.baseAddress?.assumingMemoryBound(to: UInt8.self), p.count,
                    outBase, out.count, &n,
                )
            }
            guard status == AISD_OK else {
                preconditionFailure("aisd_wire_data_frame_encode_into failed (status \(status))")
            }
            return n
        }
        precondition(written == frameSize, "RustFFI: data frame wrote \(written), expected \(frameSize)")
        return frame
    }

    /// Encodes a control ``WireMessage`` through the Rust core's flat-struct codec. Encoding a valid
    /// message cannot fail (tags are valid; Swift `String`s are valid UTF-8), so the guard traps
    /// rather than masking corruption with a second codec.
    private static func encodeControlFrame(_ message: WireMessage) -> Data {
        var m = AisdWireMessage()
        m.tag = message.messageType
        var buf0: Data?
        var buf1: Data?

        switch message {
        case let .output(seq, bytes):
            m.seq = seq
            buf0 = bytes
        case let .exit(code):
            m.code = code
        case let .input(bytes):
            buf0 = bytes
        case let .hello(protocolVersion, sessionID, lastReceivedSeq):
            m.protocol_version = protocolVersion
            setSessionID(&m, sessionID)
            m.last_received_seq = lastReceivedSeq
        case let .resize(cols, rows, pxWidth, pxHeight):
            m.cols = cols
            m.rows = rows
            m.px_width = pxWidth
            m.px_height = pxHeight
        case let .ack(seq):
            m.seq = seq
        case .bye:
            break
        case let .ping(timestampMS):
            m.timestamp_ms = timestampMS
        case let .pong(timestampMS):
            m.timestamp_ms = timestampMS
        case let .helloAck(sessionID, resumeFromSeq, returningClient):
            setSessionID(&m, sessionID)
            m.resume_from_seq = resumeFromSeq
            m.returning_client = returningClient ? 1 : 0
        case let .title(string):
            // Pass the RAW UTF-8; the Rust encoder applies the UInt16 title clamp.
            buf0 = Data(string.utf8)
        case let .notification(title, body):
            buf0 = Data(title.utf8)
            buf1 = Data(body.utf8)
        case .bell:
            break
        case let .commandStatus(status):
            switch status {
            case .running:
                m.cmd_running = 1
            case let .idle(exitCode, durationMS):
                m.cmd_running = 0
                m.cmd_has_exit_code = exitCode != nil ? 1 : 0
                m.code = exitCode ?? 0
                m.duration_ms = durationMS
            }
        }

        return withBorrowedBytes(buf0) { d0 in
            withBorrowedBytes(buf1) { d1 in
                m.data = d0
                m.data2 = d1
                var out = AisdBytes()
                let status = aisd_wire_message_encode(&m, &out)
                guard status == AISD_OK else {
                    preconditionFailure("aisd_wire_message_encode failed for a valid message (status \(status))")
                }
                defer { aisd_bytes_free(out) }
                return dataFrom(out)
            }
        }
    }

    /// Decodes a complete payload (`[type byte][body…]`, no length prefix) into a ``WireMessage``
    /// — the Rust core is the single source of truth. The bulk DATA variants (`.output`/`.input`)
    /// take the zero-copy borrowed-view path (one payload copy into the message's `Data`); control
    /// messages decode through the flat-struct codec. Throws ``AislopdeskError`` (`.truncated`,
    /// `.unknownMessageType`, `.malformedBody`) exactly as the wire format requires.
    static func decodePayload(_ payload: Data) throws -> WireMessage {
        var view = AisdDataFrameView(tag: 0, seq: 0, bytes: nil, bytes_len: 0)
        var bulk: Data?
        let status: AisdStatus = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> AisdStatus in
            let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let st = aisd_wire_data_frame_view(base, raw.count, &view)
            // Copy the borrowed bulk bytes ONCE, while `payload` is alive (the view points into it).
            if st == AISD_OK, view.tag == 1 || view.tag == 3 {
                if let p = view.bytes, view.bytes_len > 0 {
                    bulk = Data(bytes: p, count: view.bytes_len)
                } else {
                    bulk = Data()
                }
            }
            return st
        }
        switch status {
        case AISD_OK:
            switch view.tag {
            case 1: return .output(seq: view.seq, bytes: bulk ?? Data())
            case 3: return .input(bulk ?? Data())
            default: return try decodeControlPayload(payload) // tag 0 — a control message
            }
        case AISD_ERR_TRUNCATED:
            throw AislopdeskError.truncated
        default:
            // AISD_ERR_NULL is unreachable: payload.withUnsafeBytes always yields a valid base/len.
            throw AislopdeskError.truncated
        }
    }

    /// Decodes a control payload (any non-DATA type) through the Rust core's flat-struct codec.
    private static func decodeControlPayload(_ payload: Data) throws -> WireMessage {
        var out = AisdWireMessage()
        let status: AisdStatus = payload.withUnsafeBytes { raw in
            let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return aisd_wire_message_decode(base, raw.count, &out)
        }
        switch status {
        case AISD_OK:
            defer { aisd_wire_message_free(&out) }
            return message(from: out)
        case AISD_ERR_UNKNOWN_TYPE:
            // Reconstruct the offending byte (the payload's first byte) to match native.
            throw AislopdeskError.unknownMessageType(payload.first ?? 0)
        case AISD_ERR_MALFORMED:
            throw AislopdeskError.malformedBody("rust: malformed body")
        default:
            // AISD_ERR_TRUNCATED (incl. an empty payload) and any unexpected status map to
            // .truncated, exactly as the decoder rejects a short/empty body.
            throw AislopdeskError.truncated
        }
    }

    // MARK: - C-struct ↔ WireMessage mapping

    /// Rebuilds a ``WireMessage`` from a successfully decoded flat C struct (its buffers are
    /// copied out into Swift `Data`/`String`; the caller frees the C buffers afterwards).
    private static func message(from m: AisdWireMessage) -> WireMessage {
        switch m.tag {
        case 1:
            return .output(seq: m.seq, bytes: dataFrom(m.data))
        case 2:
            return .exit(code: m.code)
        case 3:
            return .input(dataFrom(m.data))
        case 10:
            return .hello(
                protocolVersion: m.protocol_version,
                sessionID: sessionID(from: m),
                lastReceivedSeq: m.last_received_seq,
            )
        case 11:
            return .resize(cols: m.cols, rows: m.rows, pxWidth: m.px_width, pxHeight: m.px_height)
        case 12:
            return .ack(seq: m.seq)
        case 13:
            return .bye
        case 14:
            return .ping(timestampMS: m.timestamp_ms)
        case 20:
            return .helloAck(
                sessionID: sessionID(from: m),
                resumeFromSeq: m.resume_from_seq,
                returningClient: m.returning_client != 0,
            )
        case 21:
            return .title(stringFrom(m.data))
        case 22:
            return .bell
        case 23:
            if m.cmd_running != 0 {
                return .commandStatus(.running)
            }
            let exitCode: Int32? = m.cmd_has_exit_code != 0 ? m.code : nil
            return .commandStatus(.idle(exitCode: exitCode, durationMS: m.duration_ms))
        case 24:
            return .pong(timestampMS: m.timestamp_ms)
        case 25:
            return .notification(title: stringFrom(m.data), body: stringFrom(m.data2))
        default:
            // Unreachable: the Rust decoder only writes a known tag on AISD_OK.
            preconditionFailure("RustFFI: decoder returned unknown tag \(m.tag)")
        }
    }

    // MARK: - Pointer / buffer marshaling helpers

    /// Borrows a `Data`'s bytes as a read-only input `AisdBytes` for the duration of `body`
    /// (`cap == 0`; Rust copies and never frees borrowed input). Nil/empty → the empty buffer.
    private static func withBorrowedBytes<R>(_ data: Data?, _ body: (AisdBytes) -> R) -> R {
        guard let data, !data.isEmpty else { return body(AisdBytes()) }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> R in
            guard let baseAddress = raw.baseAddress else {
                // Unreachable: `data` is guarded non-empty above, so its buffer has a base address.
                preconditionFailure("RustFFI: non-empty Data has a nil baseAddress")
            }
            let base = baseAddress.assumingMemoryBound(to: UInt8.self)
            return body(AisdBytes(ptr: UnsafeMutablePointer(mutating: base), len: raw.count, cap: 0))
        }
    }

    /// Copies an owned/returned `AisdBytes` into a Swift `Data` (empty for the null buffer).
    private static func dataFrom(_ b: AisdBytes) -> Data {
        guard let p = b.ptr, b.len > 0 else { return Data() }
        return Data(bytes: p, count: b.len)
    }

    /// Copies a returned UTF-8 buffer into a `String`. The Rust decoder already validated the
    /// UTF-8 (else it returns `AISD_ERR_MALFORMED`), so the decode never fails here.
    private static func stringFrom(_ b: AisdBytes) -> String {
        String(data: dataFrom(b), encoding: .utf8) ?? ""
    }

    /// Writes a `UUID`'s 16 raw bytes into the C struct's `session_id` array.
    private static func setSessionID(_ m: inout AisdWireMessage, _ uuid: UUID) {
        var raw = uuid.uuid
        withUnsafeMutableBytes(of: &m.session_id) { dest in
            withUnsafeBytes(of: &raw) { src in dest.copyMemory(from: src) }
        }
    }

    /// Reads the C struct's 16-byte `session_id` array back into a `UUID`.
    private static func sessionID(from m: AisdWireMessage) -> UUID {
        var sid = m.session_id
        return withUnsafeBytes(of: &sid) { raw in
            UUID(uuid: raw.load(as: uuid_t.self))
        }
    }
}
