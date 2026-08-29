import CSlopDeskFFI
import Foundation
import SlopDeskArena

// The PATH-1 terminal codec's MARSHALLING, and by G.4 that is all it is. `rust/slopdesk-wire` has
// carried the table itself since the port's stage 1; what used to be here was a second
// implementation of it — 680 lines of Swift laying out the same 30 message types, kept in step by
// review and by a golden corpus both had to pass. `docs/DECISIONS.md` recorded that duplication as
// a debt whose "only honest retirement is finishing the port", and the bytes half of the retirement
// landed then. This file is the residue that retirement could not remove: a Swift `enum` the UI
// switches on has to be spread onto the flat record every door speaks, and put back together from
// one, and neither direction is something Rust can do for it. `flatten` and `build` below are those
// two directions and nothing more — no length is computed here, no field is validated here, no byte
// order is decided here.
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
    /// All-zero UUID used in `hello` to request a brand-new session.
    static let newSessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// The exact number of bytes this message occupies as a complete frame
    /// (`[UInt32 BE payloadLength][UInt8 messageType][body...]`), computed WITHOUT building one.
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

// MARK: - The record itself, which is the only thing that crosses

// There used to be a second pair here — an `encode()` that asked `slopdesk_wire_message_encode`
// for a whole frame and a `decode(payload:)` that handed a whole frame to
// `slopdesk_wire_message_decode`. Both are gone, and `docs/63` G.4 is why: once the socket moved
// to Rust in G.3, `slopdesk_mux_transport_send` took the FLAT RECORD directly and its inbound
// callback lent one back, so nothing on the client's live path ever wanted bytes. What kept the
// byte pair alive was its own test suite and the golden generator — a codec whose only callers
// were the things checking it still worked. Their pin did not go with them: the four wire-message
// corpus keys are replayed end to end by `rust/slopdesk-wire/tests/golden_vectors.rs`, which
// decodes each pinned frame, checks its fields, re-encodes and asserts byte-identical output.
//
// So what is exported is the two halves of the flattening and nothing else. Nothing is computed
// here that Rust does not also compute; this is the marshalling between a Swift enum the UI
// switches on and the flat record every door speaks.

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
}
