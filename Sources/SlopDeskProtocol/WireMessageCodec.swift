import CSlopDeskFFI
import Foundation
import SlopDeskArena

// The PATH-1 terminal codec, through `rust/slopdesk-wire` — the crate that has carried this whole
// table since the port's stage 1. What used to be here was a second implementation of it: 680 lines
// of Swift laying out the same 30 message types, kept in step with the Rust by review and by a
// golden corpus both had to pass. `docs/DECISIONS.md` recorded that duplication as a debt whose
// "only honest retirement is finishing the port". This is that retirement.
//
// TWO ADDRESS SPACES, and it is worth knowing which is which:
//
//   - `text_*` spans are offsets into the ARENA — a flat buffer of short strings. Titles, cwds,
//     labels, a branch name. A message can carry two of them, and an encode has to write them down
//     somewhere, so they cannot be spans into anything that already exists.
//   - `blob_*` spans are offsets into the DATAGRAM. The opaque byte run six arms end in (an
//     `.output` payload under a flood, an `.input`, a block's captured output, a metadata or
//     workspace body) is the one field big enough for a copy to be felt, so decoding answers WHERE
//     it sits and encoding hands it over as its own argument. Exactly one copy either way — the
//     same number the hand-written Swift made.

public extension WireMessage {
    /// Bytes a UUID occupies on the wire (its 16 raw bytes).
    static let sessionIDByteCount = slopdesk_wire_constant(1)

    /// All-zero UUID used in `hello` to request a brand-new session.
    static let newSessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Encodes this message into a complete frame, ready to write to a socket:
    /// `[UInt32 BE payloadLength][UInt8 messageType][body...]`.
    ///
    /// `payloadLength` counts `messageType` + `body` and excludes the 4 prefix bytes — exactly what
    /// ``FrameDecoder`` expects.
    ///
    /// The frame is sized by ASKING (``wireByteCount``, which never builds one), so there is one
    /// allocation, one pass, and the opaque run copied exactly once. WHICH allocation is a measured
    /// choice, because the two `Data` shapes cross over:
    ///
    ///   - `Data(count:)` zeroes what it hands back, but a frame of 14 bytes or fewer — an `ack`,
    ///     the message this wire sends most — lives INSIDE the `Data` value and never reaches the
    ///     allocator at all (~5 ns against ~113 ns for a `malloc`).
    ///   - `Data(bytesNoCopy:deallocator:)` skips the zeroing but carries a heavier representation,
    ///     about 20 ns of it, which only pays for itself once the pass it skips is longer than that.
    ///
    /// Measured, the crossing is at ``zeroingCheaperThanTheAllocator``: below it the two are within
    /// noise and the small-frame win is large; at 32 KiB under an output flood the zeroing costs as
    /// much as the encode (1.18 µs against 632 ns) and skipping it is the difference between this
    /// and the hand-written Swift it replaced.
    func encode() -> Data {
        var flat = SlopDeskWireMessage()
        var arena = Data()
        var blob = Data()
        flatten(into: &flat, arena: &arena, blob: &blob)
        return withUnsafePointer(to: flat) { message in
            arena.spanning { pool, poolLength in
                blob.spanning { payload, payloadLength in
                    let bound = slopdesk_wire_message_byte_count(message, pool, poolLength, payloadLength)
                    precondition(bound > 0, "the wire codec refused a message this type can express")
                    return WireBuffer.filled(bound) { out in
                        let written = slopdesk_wire_message_encode(
                            message, pool, poolLength, payload, payloadLength, out, bound,
                        )
                        precondition(written == bound, "the wire codec sized a frame differently than it wrote it")
                    }
                }
            }
        }
    }

    /// The exact number of bytes ``encode()`` produces, computed WITHOUT building the frame.
    ///
    /// The receive-side flow control credits this per consumed message and it must match the
    /// sender's per-frame debit EXACTLY — a mismatch leaks or over-grants window forever, because
    /// the error accumulates rather than cancelling. Asking the codec is what keeps the two equal;
    /// the opaque run costs its own length and is never materialised to be counted.
    var wireByteCount: Int {
        var flat = SlopDeskWireMessage()
        var arena = Data()
        var blob = Data()
        flatten(into: &flat, arena: &arena, blob: &blob)
        return withUnsafePointer(to: flat) { message in
            arena.spanning { pool, poolLength in
                slopdesk_wire_message_byte_count(message, pool, poolLength, blob.count)
            }
        }
    }
}

// MARK: - The record itself, for the doors that speak it rather than bytes

// `encode()` and `decode(payload:)` above cross this boundary as BYTES because their door does:
// `slopdesk_wire_message_encode` writes a frame and `slopdesk_wire_message_decode` reads one. The
// PATH-1 client transport's door does not. `slopdesk_mux_transport_send` takes the flat record
// directly and its inbound callback lends one, because on both sides of that door the frame is
// Rust's — the socket moved there in `docs/63` G.3, so re-encoding a message to bytes just to have
// Rust decode them again would be a marshalling face built to be deleted.
//
// So the two halves of the flattening are exported. Nothing new is computed here; these are the
// same `flatten` and `build` the byte doors use, with the frame step left out.

public extension WireMessage {
    /// Rebuilds one message from a flat record and the two spans lent alongside it.
    ///
    /// `arena` holds the short text fields; `run` IS the opaque byte run, already its own `Data`.
    /// Answers `nil` for a `message_type` no arm claims, which is a frame from a newer peer and is
    /// dropped rather than guessed at — the same reading the byte decoder gives it.
    static func lent(_ flat: SlopDeskWireMessage, arena: UnsafeRawBufferPointer, run: Data) -> WireMessage? {
        build(flat, arena, run)
    }

    /// Hands this message to `body` as the flat record, its arena and its opaque run.
    ///
    /// Every pointer is valid for the duration of `body` and no longer, which is exactly the term
    /// every door in `slopdesk_ffi.h` asks for. The run is passed as its own span rather than
    /// interned: `Data` is copy-on-write, so handing over the caller's own bytes costs a retain,
    /// while interning them would memcpy the largest field on the wire.
    func withFlattened<T>(
        _ body: (UnsafePointer<SlopDeskWireMessage>, UnsafeRawPointer?, Int, UnsafeRawPointer?, Int) -> T,
    ) -> T {
        var flat = SlopDeskWireMessage()
        var arena = Data()
        var blob = Data()
        flatten(into: &flat, arena: &arena, blob: &blob)
        return withUnsafePointer(to: flat) { message in
            arena.spanning { pool, poolLength in
                blob.spanning { payload, payloadLength in
                    body(message, pool, poolLength, payload, payloadLength)
                }
            }
        }
    }
}

extension WireMessage {
    /// Decodes a message from a **complete payload** (`[UInt8 messageType][body...]`, without the
    /// length prefix — framing is ``FrameDecoder``'s job).
    ///
    /// - Throws: ``SlopDeskError/truncated`` if the body is shorter than the type requires,
    ///   ``SlopDeskError/unknownMessageType(_:)`` for an unrecognized type byte, or
    ///   ``SlopDeskError/malformedBody(_:)`` for a right-length-but-invalid body. String fields are
    ///   STRICT UTF-8 — an invalid sequence is malformed, never a replacement-character repair.
    static func decode(payload: Data) throws -> WireMessage {
        try payload.withUnsafeBytes { bytes -> WireMessage in
            if let message = try Self.attempt(bytes, room: Self.scratchArena) { return message }
            // Text on this wire is a SUBSTRING of the datagram, so the datagram's own length is a
            // bound no message can exceed — a proof, not a bigger guess.
            guard let message = try Self.attempt(bytes, room: bytes.count + 1) else {
                throw SlopDeskError.truncated
            }
            return message
        }
    }

    /// A title, a cwd or a label fits this, and nothing else reaches the arena at all — an
    /// `.output` payload under a flood never enters it, in either direction.
    private static let scratchArena = 512

    /// One decode into an arena of `room` bytes. `nil` means only that the arena was too small.
    private static func attempt(_ bytes: UnsafeRawBufferPointer, room: Int) throws -> WireMessage? {
        var flat = SlopDeskWireMessage()
        var verdict = UInt32(SLOPDESK_WIRE_DECODE_OK)
        var built: WireMessage?
        withUnsafeTemporaryAllocation(byteCount: room, alignment: 1) { arena in
            verdict = slopdesk_wire_message_decode(
                bytes.baseAddress, bytes.count, &flat, arena.baseAddress, arena.count,
            )
            if verdict == UInt32(SLOPDESK_WIRE_DECODE_OK) {
                built = build(flat, UnsafeRawBufferPointer(arena), run(bytes, flat))
            }
        }
        guard verdict != UInt32(SLOPDESK_WIRE_DECODE_AGAIN) else { return nil }
        let type = bytes.first ?? 0
        switch verdict {
        case UInt32(SLOPDESK_WIRE_DECODE_TRUNCATED):
            throw SlopDeskError.truncated
        case UInt32(SLOPDESK_WIRE_DECODE_UNKNOWN_TYPE):
            throw SlopDeskError.unknownMessageType(type)
        case UInt32(SLOPDESK_WIRE_DECODE_MALFORMED):
            throw SlopDeskError.malformedBody("type \(type): body is not what its type declares")
        default:
            break
        }
        guard let built else { throw SlopDeskError.unknownMessageType(type) }
        return built
    }
}

// MARK: - Flattening, one arm per message type

private extension WireMessage {
    /// Spreads this message onto the flat struct, a text arena and the opaque run.
    ///
    /// The run is returned as its own `Data` rather than appended to the arena: `Data` is
    /// copy-on-write, so handing back the caller's own bytes costs a retain, and interning them
    /// would cost a memcpy of the largest field on the wire.
    func flatten(into flat: inout SlopDeskWireMessage, arena: inout Data, blob: inout Data) {
        flat.message_type = messageType

        switch self {
        case let .output(seq, bytes):
            flat.seq = seq
            blob = bytes

        case let .exit(code):
            flat.exit_code = code
            flat.has_exit_code = true

        case let .input(bytes):
            blob = bytes

        case let .hello(protocolVersion, sessionID, lastReceivedSeq):
            flat.protocol_version = protocolVersion
            flat.session_id = sessionID.uuid
            flat.last_received_seq = lastReceivedSeq

        case let .resize(cols, rows, pxWidth, pxHeight):
            flat.cols = cols
            flat.rows = rows
            flat.px_width = pxWidth
            flat.px_height = pxHeight

        case let .ack(seq):
            flat.seq = seq

        case .bye,
             .bell:
            break

        case let .ping(timestampMS),
             let .pong(timestampMS):
            flat.timestamp_ms = timestampMS

        case let .requestBlockOutput(index):
            flat.index = index

        case let .helloAck(sessionID, resumeFromSeq, returningClient):
            flat.session_id = sessionID.uuid
            flat.resume_from_seq = resumeFromSeq
            flat.returning_client = returningClient

        case let .title(text),
             let .cwd(text),
             let .projectKey(text),
             let .agentSessionIntent(text),
             let .foregroundProcess(text):
            Self.intern(text, into: &arena, first: &flat)

        case let .commandStatus(status):
            switch status {
            case .running:
                flat.command_status = 0
            case let .idle(exitCode, durationMS):
                flat.command_status = 1
                flat.has_exit_code = exitCode != nil
                flat.exit_code = exitCode ?? 0
                flat.duration_ms = durationMS
                flat.has_duration_ms = true
            }

        case let .notification(title, body):
            Self.intern(title, into: &arena, first: &flat)
            Self.intern(body, into: &arena, second: &flat)

        case let .claudeStatus(state, kind, label):
            flat.state = state
            flat.kind = kind
            Self.intern(label, into: &arena, first: &flat)

        case let .commandBlock(index, exitCode, durationMS, complete, outputLen, commandText, promptOrdinal):
            flat.index = index
            flat.has_exit_code = exitCode != nil
            flat.exit_code = exitCode ?? 0
            flat.has_duration_ms = durationMS != nil
            flat.duration_ms = durationMS ?? 0
            flat.complete = complete
            flat.output_len = outputLen
            flat.prompt_ordinal = promptOrdinal
            Self.intern(commandText, into: &arena, first: &flat)

        case let .blockOutput(index, output):
            flat.index = index
            blob = output

        case let .metadataRequest(requestID, verb, payload):
            flat.request_id = requestID
            flat.verb = verb
            blob = payload

        case let .metadataResponse(requestID, status, payload):
            flat.request_id = requestID
            flat.status = status
            blob = payload

        case let .workspaceRequest(requestSeq, verb, payload):
            flat.request_seq = requestSeq
            flat.verb = verb
            blob = payload

        case let .workspaceEvent(kind, epoch, baseStateNum, newStateNum, payload):
            flat.kind = kind
            flat.epoch = epoch.uuid
            flat.base_state_num = baseStateNum
            flat.new_state_num = newStateNum
            blob = payload

        case let .inputEcho(enabled):
            flat.enabled = enabled

        case let .progress(state, percent):
            flat.state = state
            flat.percent = percent

        case let .projectGitStatus(status):
            Self.intern(status.repoRoot, into: &arena, first: &flat)
            Self.intern(status.branch, into: &arena, second: &flat)
            flat.ahead = status.ahead
            flat.behind = status.behind
            flat.stash_count = status.stashCount
            flat.staged = status.staged
            flat.modified = status.modified
            flat.untracked = status.untracked
            flat.conflicted = status.conflicted
            flat.changed_count = status.changedCount
        }
    }

    /// Appends a string's UTF-8 to the arena and points the FIRST text span at it.
    static func intern(_ text: String, into arena: inout Data, first flat: inout SlopDeskWireMessage) {
        let (offset, length) = append(text, to: &arena)
        flat.text_a_offset = offset
        flat.text_a_length = length
    }

    /// The same, for the second text span — a notification body, a branch name.
    static func intern(_ text: String, into arena: inout Data, second flat: inout SlopDeskWireMessage) {
        let (offset, length) = append(text, to: &arena)
        flat.text_b_offset = offset
        flat.text_b_length = length
    }

    static func append(_ text: String, to arena: inout Data) -> (UInt32, UInt32) {
        let span = ArenaText.intern(text, into: &arena)
        return (span.offset, span.length)
    }
}

// MARK: - Rebuilding, one arm per message type

extension WireMessage {
    /// Puts a decoded flat message back together. `arena` holds the text; `blob` IS the opaque byte
    /// run, already its own buffer, so the arms that carry one hand it straight on — `Data` is
    /// copy-on-write, and re-slicing it here would copy the largest field on the wire a second time.
    static func build(
        _ flat: SlopDeskWireMessage, _ arena: UnsafeRawBufferPointer, _ blob: Data,
    ) -> WireMessage? {
        let first = text(arena, flat.text_a_offset, flat.text_a_length)
        switch flat.message_type {
        case 1: return .output(seq: flat.seq, bytes: blob)
        case 2: return .exit(code: flat.exit_code)
        case 3: return .input(blob)
        case 10:
            return .hello(
                protocolVersion: flat.protocol_version,
                sessionID: UUID(uuid: flat.session_id),
                lastReceivedSeq: flat.last_received_seq,
            )
        case 11:
            return .resize(cols: flat.cols, rows: flat.rows, pxWidth: flat.px_width, pxHeight: flat.px_height)
        case 12: return .ack(seq: flat.seq)
        case 13: return .bye
        case 14: return .ping(timestampMS: flat.timestamp_ms)
        case 15: return .requestBlockOutput(index: flat.index)
        case 16:
            return .metadataRequest(requestID: flat.request_id, verb: flat.verb, payload: blob)
        case 17:
            return .workspaceRequest(requestSeq: flat.request_seq, verb: flat.verb, payload: blob)
        case 20:
            return .helloAck(
                sessionID: UUID(uuid: flat.session_id),
                resumeFromSeq: flat.resume_from_seq,
                returningClient: flat.returning_client,
            )
        case 21: return .title(first)
        case 22: return .bell
        case 23:
            guard flat.command_status != 0 else { return .commandStatus(.running) }
            return .commandStatus(.idle(
                exitCode: flat.has_exit_code ? flat.exit_code : nil, durationMS: flat.duration_ms,
            ))
        case 24: return .pong(timestampMS: flat.timestamp_ms)
        case 25:
            return .notification(title: first, body: text(arena, flat.text_b_offset, flat.text_b_length))
        case 26: return .foregroundProcess(name: first)
        case 27: return .claudeStatus(state: flat.state, kind: flat.kind, label: first)
        case 28:
            return .commandBlock(
                index: flat.index,
                exitCode: flat.has_exit_code ? flat.exit_code : nil,
                durationMS: flat.has_duration_ms ? flat.duration_ms : nil,
                complete: flat.complete,
                outputLen: flat.output_len,
                commandText: first,
                promptOrdinal: flat.prompt_ordinal,
            )
        case 29: return .blockOutput(index: flat.index, output: blob)
        case 30:
            return .metadataResponse(requestID: flat.request_id, status: flat.status, payload: blob)
        case 31: return .inputEcho(enabled: flat.enabled)
        case 32: return .progress(state: flat.state, percent: flat.percent)
        case 33: return .cwd(first)
        case 34: return .projectKey(first)
        case 35:
            return .projectGitStatus(ProjectGitStatus(
                repoRoot: first,
                branch: text(arena, flat.text_b_offset, flat.text_b_length),
                ahead: flat.ahead,
                behind: flat.behind,
                stashCount: flat.stash_count,
                staged: flat.staged,
                modified: flat.modified,
                untracked: flat.untracked,
                conflicted: flat.conflicted,
                changedCount: flat.changed_count,
            ))
        case 36: return .agentSessionIntent(first)
        case 37:
            return .workspaceEvent(
                kind: flat.kind,
                epoch: UUID(uuid: flat.epoch),
                baseStateNum: flat.base_state_num,
                newStateNum: flat.new_state_num,
                payload: blob,
            )
        default: return nil
        }
    }

    /// Reads a text span out of the arena. The codec already refused anything that is not valid
    /// UTF-8, so this cannot be a lossy repair of wire bytes — it is a read of bytes Rust just wrote.
    private static func text(_ arena: UnsafeRawBufferPointer, _ offset: UInt32, _ length: UInt32) -> String {
        ArenaText.text(arena, offset, length)
    }

    /// Lifts the opaque run out of the caller's own datagram — the ONE copy this direction makes.
    ///
    /// Rebased inside the borrow that already holds the pointer: `dropFirst().prefix()` would build
    /// two intermediate `Data` values, each retaining the whole parent buffer.
    static func run(_ payload: UnsafeRawBufferPointer, _ flat: SlopDeskWireMessage) -> Data {
        let start = Int(flat.blob_offset)
        let end = start + Int(flat.blob_length)
        guard flat.blob_length > 0, end <= payload.count else { return Data() }
        return Data(UnsafeRawBufferPointer(rebasing: payload[start..<end]))
    }
}

extension UUID {
    /// The UUID's 16 raw bytes as `Data`, in canonical order.
    var dataBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    /// Builds a UUID from a session id's worth of raw bytes. Returns `nil` for any other length.
    init?(dataBytes data: Data) {
        guard data.count == WireMessage.sessionIDByteCount else { return nil }
        var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { dest in
            _ = data.copyBytes(to: dest)
        }
        self.init(uuid: raw)
    }
}

extension Data {
    /// Hands this buffer to `body` as the `(pointer, length)` pair the codec's C entries take.
    ///
    /// An EMPTY buffer short-circuits to `(nil, 0)` rather than borrowing: the messages this wire
    /// sends most — an `ack`, an `.output`, an `.input` — carry no text at all, so their arena is
    /// empty every time, and `withUnsafeBytes` on it is a borrow bought for nothing.
    @inline(__always)
    func spanning<R>(_ body: (UnsafeRawPointer?, Int) throws -> R) rethrows -> R {
        try isEmpty ? body(nil, 0) : withUnsafeBytes { try body($0.baseAddress, $0.count) }
    }
}

/// Where this module's byte buffers come from.
enum WireBuffer {
    /// A buffer of exactly `count` bytes, written by `fill` and handed back as `Data`.
    ///
    /// WHICH allocation is a measured choice, because the two `Data` shapes cross over:
    ///
    ///   - `Data(count:)` zeroes what it hands back, but a buffer of 14 bytes or fewer — an `ack`,
    ///     the message this wire sends most — lives INSIDE the `Data` value and never reaches the
    ///     allocator at all (~5 ns against ~113 ns for a `malloc`).
    ///   - `Data(bytesNoCopy:deallocator:)` skips the zeroing but carries a heavier representation,
    ///     about 20 ns of it, which only pays for itself once the pass it skips is longer than that.
    ///
    /// Measured, the crossing is at ``zeroingCheaperThanTheAllocator``: below it the two are within
    /// noise and the small-buffer win is large; at 32 KiB the zeroing costs as much as the encode
    /// that follows it (1.18 µs against 632 ns).
    @inline(__always)
    static func filled(_ count: Int, _ fill: (UnsafeMutableRawPointer?) -> Void) -> Data {
        guard count > 0 else { return Data() }
        guard count >= zeroingCheaperThanTheAllocator else {
            var buffer = Data(count: count)
            buffer.withUnsafeMutableBytes { fill($0.baseAddress) }
            return buffer
        }
        guard let out = malloc(count) else { preconditionFailure("out of memory for a wire buffer") }
        fill(out)
        return Data(bytesNoCopy: out, count: count, deallocator: .free)
    }

    /// The size at and above which writing into UNINITIALISED memory beats letting `Data` zero the
    /// buffer first — see ``filled(_:_:)`` for the two costs that cross here.
    private static let zeroingCheaperThanTheAllocator = 4096
}
