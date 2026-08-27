import CSlopDeskFFI
import Foundation
import SlopDeskArena

// SupervisorDoors — the crossing into `slopdesk_superwire::protocol`, and the only place in Swift
// that knows this protocol exists.
//
// Encoding is `docs/55` §4's pure convention: arguments in, bytes out, nothing retained. Decoding is
// not, and cannot be — a `blockOutput` reply carries up to a frame's worth of output and a caller
// reads a dozen fields off one reply, so re-parsing per field would be the cost. The reply takes the
// HANDLE convention instead: parse once, read the scalars in one crossing, project the
// variable-length parts into buffers, free. ``SupervisorReplyReader`` owns that lifetime, so no
// caller can forget the `free`.

// MARK: - Lending

/// Lends `text`'s UTF-8 for the duration of the call — the `(ptr, len)` half of §4's convention.
///
/// A `nil` text crosses as a NULL pointer, which the doors read as ABSENT. A present-but-empty one
/// must not: `""` for a spawn's auto-progress list is an instruction — the operator cleared the list
/// and the feature is off — where absent means superd's built-in list applies. An empty Swift
/// array's `baseAddress` is `nil`, which would collapse the two, so the buffer always carries one
/// byte more than it lends and the LENGTH is what says how much of it counts.
private func lend<T>(_ text: String?, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    guard let text else { return body(nil, 0) }
    var bytes = Array(text.utf8)
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { body($0.baseAddress, $0.count - 1) }
}

/// The same for a blob Swift already holds, with the same empty-is-not-absent rule.
private func lend<T>(_ blob: [UInt8], _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    var bytes = blob
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { body($0.baseAddress, $0.count - 1) }
}

/// Lends every text in `texts` at once, in order, and hands the pairs to `body`.
///
/// The spawn door takes SIX optional strings and two blobs, and the alternative here is an
/// eight-deep closure nest whose only content is indentation. Recursive rather than a loop because
/// each pointer is only valid inside its own `withUnsafeBufferPointer`, so the frames have to still
/// be on the stack when `body` runs — which is exactly what the recursion buys.
private func lendAll<T>(
    _ texts: [String?],
    _ body: ([(pointer: UnsafePointer<UInt8>?, count: Int)]) -> T,
) -> T {
    var lent: [(pointer: UnsafePointer<UInt8>?, count: Int)] = []
    lent.reserveCapacity(texts.count)
    func step(_ index: Int) -> T {
        guard index < texts.count else { return body(lent) }
        return lend(texts[index]) { pointer, count in
            lent.append((pointer, count))
            defer { lent.removeLast() }
            return step(index + 1)
        }
    }
    return step(0)
}

// MARK: - Encoding

/// One request as the bytes that go on the wire.
///
/// Every method answers `[UInt8]`, and an EMPTY answer is the door's refusal: a selector outside a
/// grouped door's shape, or a request that will not serialise. The caller reports it rather than
/// sending a frame whose meaning it cannot state — a `pause` encoded without its `paused` field
/// would be read by superd as a bool it never got, and would resume a pane the caller meant to stop.
enum SupervisorEncoder {
    /// Bumped only for a breaking change. superd refuses a hostd whose major differs.
    static let versionMajor = Int(slopdesk_supervisor_version_major())
    /// Bumped when a verb or field is added. Both sides interoperate freely across minors.
    static let versionMinor = Int(slopdesk_supervisor_version_minor())
    /// The `id` an unsolicited push carries.
    static let notificationID = slopdesk_supervisor_notification_id()

    /// The version pair is NOT a parameter: it is the protocol's, it lives beside the message set,
    /// and a caller that could pass its own would be a second place the handshake is decided.
    static func hello(id: UInt64, client: String) -> [UInt8] {
        lend(client) { pointer, count in
            ffiAnswerBytes(capacity: 256) { out, cap in
                slopdesk_supervisor_encode_hello(id, pointer, count, out, cap)
            }
        }
    }

    static func list(id: UInt64) -> [UInt8] {
        ffiAnswerBytes(capacity: 64) { out, cap in slopdesk_supervisor_encode_list(id, out, cap) }
    }

    /// `adopt` / `unsubscribe` / `forgetTitle` / `blockSnapshot` — a pane id and nothing else.
    static func pane(_ which: UInt32, id: UInt64, paneID: String) -> [UInt8] {
        lend(paneID) { pointer, count in
            ffiAnswerBytes(capacity: 128) { out, cap in
                slopdesk_supervisor_encode_pane(which, id, pointer, count, out, cap)
            }
        }
    }

    /// `signal` / `subscribe` / `blockOutput` / `blockControl` — a pane id and one number, narrowed
    /// per verb inside the door. A value too wide SATURATES rather than wrapping, because a wrapped
    /// block index would fetch the WRONG block.
    static func paneNumber(_ which: UInt32, id: UInt64, paneID: String, value: UInt64) -> [UInt8] {
        lend(paneID) { pointer, count in
            ffiAnswerBytes(capacity: 128) { out, cap in
                slopdesk_supervisor_encode_pane_number(which, id, pointer, count, value, out, cap)
            }
        }
    }

    /// `release` (the flag is `kill`) / `pause` (the flag is `paused`).
    static func paneFlag(_ which: UInt32, id: UInt64, paneID: String, flag: Bool) -> [UInt8] {
        lend(paneID) { pointer, count in
            ffiAnswerBytes(capacity: 128) { out, cap in
                slopdesk_supervisor_encode_pane_flag(which, id, pointer, count, flag, out, cap)
            }
        }
    }

    static func resize(id: UInt64, paneID: String, rows: UInt16, cols: UInt16) -> [UInt8] {
        lend(paneID) { pointer, count in
            ffiAnswerBytes(capacity: 128) { out, cap in
                slopdesk_supervisor_encode_resize(id, pointer, count, rows, cols, out, cap)
            }
        }
    }

    static func journal(
        _ which: UInt32,
        id: UInt64,
        directory: String,
        sessionID: String = "",
        maxAgeSeconds: UInt64 = 0,
        keepNewest: Int = 0,
    ) -> [UInt8] {
        lend(directory) { directoryPointer, directoryCount in
            lend(sessionID) { sessionPointer, sessionCount in
                ffiAnswerBytes(capacity: 512) { out, cap in
                    slopdesk_supervisor_encode_journal(
                        which, id, directoryPointer, directoryCount, sessionPointer, sessionCount,
                        maxAgeSeconds, keepNewest, out, cap,
                    )
                }
            }
        }
    }

    /// The one door with a record of its own, because a spawn decides twenty-three things.
    ///
    /// The strings stay separate `(ptr, len)` parameters — §4's convention, and the reason the
    /// record is scalars only: a pointer inside an input record would be a second kind of borrow
    /// obligation, and there is one on purpose.
    static func spawn(id: UInt64, _ request: SpawnRequest) -> [UInt8] {
        var arguments: [UInt8] = []
        for argument in request.arguments { ffiPushRun(&arguments, argument) }
        var environment: [UInt8] = []
        for (key, value) in request.environment {
            ffiPushRun(&environment, key)
            ffiPushRun(&environment, value)
        }
        var fields = SlopDeskSupervisorSpawnFields()
        fields.rows = request.rows
        fields.cols = request.cols
        fields.shell_integration = request.shellIntegration
        fields.journal = request.journal != nil
        fields.journal_cap_bytes = request.journal?.capBytes ?? 0
        fields.blocks = request.blocks != nil
        fields.blocks_output_cap = request.blocks?.outputCap ?? 0
        fields.blocks_max_blocks = request.blocks?.maxBlocks ?? 0
        fields.blocks_max_total_output_bytes = request.blocks?.maxTotalOutputBytes ?? 0

        // The order here is the door's parameter order, and it is the only thing tying the two
        // together — so it is written once, as a list, rather than as an eight-deep nest whose
        // arguments could be transposed without the compiler noticing.
        let texts: [String?] = [
            request.paneID,
            request.sessionID,
            request.executable,
            request.argv0,
            request.cwd,
            request.owner,
            request.journal?.directory,
            request.blocks?.autoProgressCommands,
        ]
        let sized = max(4096, arguments.count + environment.count + 2048)
        return lendAll(texts) { lent in
            lend(arguments) { argumentPointer, argumentCount in
                lend(environment) { environmentPointer, environmentCount in
                    ffiAnswerBytes(capacity: sized) { out, cap in
                        slopdesk_supervisor_encode_spawn(
                            id,
                            lent[0].pointer, lent[0].count,
                            lent[1].pointer, lent[1].count,
                            lent[2].pointer, lent[2].count,
                            lent[3].pointer, lent[3].count,
                            lent[4].pointer, lent[4].count,
                            lent[5].pointer, lent[5].count,
                            argumentPointer, argumentCount,
                            environmentPointer, environmentCount,
                            lent[6].pointer, lent[6].count,
                            lent[7].pointer, lent[7].count,
                            fields, out, cap,
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Reading a reply

/// One parsed reply, alive for as long as this object is.
///
/// Every read below is a crossing into the SAME parse. The alternative under the pure convention
/// would be re-parsing the body per field, which for a `blockControl` answer carrying a megabyte of
/// retained output is the cost the handle exists to avoid.
final class SupervisorReplyReader {
    /// `nil` from ``init(_:)`` means the bytes are not this protocol's JSON at all — a corrupt or
    /// truncated frame. It deliberately does NOT mean "vocabulary this build does not know": an
    /// unrecognised status arrives as ``SupervisorStatus/unrecognised`` and an unrecognised push as
    /// ``Event/unknown``, because a caller that drops a frame here never wakes the waiter registered
    /// under its id, and a pane that hangs is worse than one that fails.
    private let handle: OpaquePointer

    /// Every scalar, read once. The read loop needs the id, the status and whether this is a push
    /// before it can route the frame at all.
    let head: SlopDeskSupervisorReplyHead

    init?(_ body: [UInt8]) {
        guard let handle = body.withUnsafeBufferPointer({ bytes in
            slopdesk_supervisor_reply_open(bytes.baseAddress, bytes.count)
        }) else { return nil }
        self.handle = handle
        head = slopdesk_supervisor_reply_head(handle)
    }

    deinit { slopdesk_supervisor_reply_free(handle) }

    /// Which unsolicited push this is, if it is one.
    enum Event {
        case none
        case exited
        case connection
        /// A push this build has no name for. Named rather than folded into ``none``, which would
        /// make a newer superd's notification read as an ANSWER to whatever request holds id 0.
        case unknown
    }

    var id: UInt64 { head.id }

    var status: SupervisorStatus {
        switch head.status {
        case UInt32(SLOPDESK_SUPERVISOR_STATUS_OK): .ok
        case UInt32(SLOPDESK_SUPERVISOR_STATUS_ERROR): .error
        case UInt32(SLOPDESK_SUPERVISOR_STATUS_UNSUPPORTED): .unsupported
        default: .unrecognised
        }
    }

    var event: Event {
        switch head.event {
        case UInt32(SLOPDESK_SUPERVISOR_EVENT_EXITED): .exited
        case UInt32(SLOPDESK_SUPERVISOR_EVENT_CONNECTION): .connection
        case UInt32(SLOPDESK_SUPERVISOR_EVENT_UNKNOWN): .unknown
        default: .none
        }
    }

    /// A projected text. A length of zero is `""`; the head's `has_*` flag is what tells an ABSENT
    /// text from an empty one, because both deliver no bytes.
    private func text(_ which: Int32) -> String {
        ffiAnswerText(capacity: 512) { out, cap in
            slopdesk_supervisor_reply_text(handle, UInt32(which), out, cap)
        }
    }

    /// The diagnostic superd sent, always populated for `.error` and `.unsupported`.
    var message: String? {
        head.has_message ? text(SLOPDESK_SUPERVISOR_TEXT_MESSAGE) : nil
    }

    var hello: HelloReply? {
        guard head.has_hello else { return nil }
        return HelloReply(
            versionMajor: Int(head.hello_version_major),
            versionMinor: Int(head.hello_version_minor),
            superdPID: head.hello_superd_pid,
            hookSocketPath: head.has_hook_socket ? text(SLOPDESK_SUPERVISOR_TEXT_HOOK_SOCKET) : nil,
            controlSocketPath: head.has_control_socket
                ? text(SLOPDESK_SUPERVISOR_TEXT_CONTROL_SOCKET) : nil,
            buildVersion: head.has_build_version ? text(SLOPDESK_SUPERVISOR_TEXT_BUILD_VERSION) : nil,
        )
    }

    var exited: ExitedNotice? {
        guard head.has_exited else { return nil }
        return ExitedNotice(
            paneID: text(SLOPDESK_SUPERVISOR_TEXT_EXITED_PANE),
            pid: head.exited_pid,
            code: head.exited_code,
        )
    }

    var stream: StreamPosition? {
        guard head.has_stream else { return nil }
        return StreamPosition(
            start: head.stream_start,
            head: head.stream_head,
            lossy: head.stream_lossy,
            ended: head.stream_ended,
        )
    }

    var journal: JournalReply? {
        guard head.has_journal else { return nil }
        return JournalReply(
            path: text(SLOPDESK_SUPERVISOR_TEXT_JOURNAL_PATH),
            bytes: head.journal_bytes,
            rows: head.journal_rows,
            cols: head.journal_cols,
            head: head.journal_has_head ? head.journal_head : nil,
        )
    }

    /// The single pane a `spawn` or `adopt` answers with.
    var pane: PaneRecord? {
        guard head.has_pane else { return nil }
        return panes(UInt32(SLOPDESK_SUPERVISOR_PANES_SINGLE)).first
    }

    /// The `panes` array a `list` answers with — distinct from a count of zero, which is a `list`
    /// with nothing supervised.
    var paneList: [PaneRecord]? {
        guard head.has_panes else { return nil }
        return panes(UInt32(SLOPDESK_SUPERVISOR_PANES_LIST))
    }

    private func panes(_ which: UInt32) -> [PaneRecord] {
        let (rows, arena) = project(SlopDeskSupervisorPaneRow()) { rows, rowCap, bytes, byteCap in
            slopdesk_supervisor_reply_panes(handle, which, rows, rowCap, bytes, byteCap)
        }
        return arena.withUnsafeBytes { text in
            rows.map { row in
                PaneRecord(
                    paneID: ArenaText.text(text, row.pane_id_offset, row.pane_id_length),
                    sessionID: ArenaText.text(text, row.session_id_offset, row.session_id_length),
                    pid: row.pid,
                    executable: ArenaText.text(text, row.executable_offset, row.executable_length),
                    cwd: row.has_cwd ? ArenaText.text(text, row.cwd_offset, row.cwd_length) : nil,
                    rows: row.rows,
                    cols: row.cols,
                    spawnedAt: row.spawned_at,
                    attached: row.attached,
                    owner: row.has_owner ? ArenaText.text(text, row.owner_offset, row.owner_length) : nil,
                )
            }
        }
    }

    /// What the three block-reading verbs answer with, or `nil` when the pane has no tap at all —
    /// which a caller reports differently from "this pane has run nothing yet".
    var blocks: BlocksReply? {
        guard head.has_blocks else { return nil }
        return BlocksReply(
            output: head.has_block_output ? blockOutput() : nil,
            snapshot: head.has_block_snapshot ? blockSnapshot() : nil,
            recent: head.has_block_recent ? blockRecords() : nil,
            open: head.has_open_block
                ? OpenBlock(
                    commandText: text(SLOPDESK_SUPERVISOR_TEXT_OPEN_COMMAND),
                    outputLen: head.open_block_output_len,
                )
                : nil,
            nextIndex: head.has_next_index ? head.next_index : nil,
        )
    }

    /// Base64 decoded on the crate side: the caller wants BYTES, and a second decoder here would be
    /// a second place a transcript could silently lie.
    private func blockOutput() -> [UInt8] {
        ffiAnswerBytes(capacity: max(1, head.block_output_len)) { out, cap in
            slopdesk_supervisor_reply_block_output(handle, out, cap)
        }
    }

    private func blockSnapshot() -> [BlockMetadata] {
        let (rows, arena) = project(SlopDeskSupervisorBlockRow()) { rows, rowCap, bytes, byteCap in
            slopdesk_supervisor_reply_block_metas(handle, rows, rowCap, bytes, byteCap)
        }
        return arena.withUnsafeBytes { text in rows.map { metadata($0, text) } }
    }

    private func blockRecords() -> [BlockRecord] {
        var counts = slopdesk_supervisor_reply_block_records(handle, nil, 0, nil, 0, nil, 0)
        var rows = [SlopDeskSupervisorRecordRow](
            repeating: SlopDeskSupervisorRecordRow(), count: counts.row_count,
        )
        var texts = [UInt8](repeating: 0, count: counts.text_length)
        var bytes = [UInt8](repeating: 0, count: counts.byte_length)
        // Three buffers, one all-or-nothing fill: nothing is written unless EVERY one fits, so a
        // half-filled array can never read as a whole answer.
        counts = rows.withUnsafeMutableBufferPointer { rowBuffer in
            texts.withUnsafeMutableBufferPointer { textBuffer in
                bytes.withUnsafeMutableBufferPointer { byteBuffer in
                    slopdesk_supervisor_reply_block_records(
                        handle,
                        rowBuffer.baseAddress, rowBuffer.count,
                        textBuffer.baseAddress, textBuffer.count,
                        byteBuffer.baseAddress, byteBuffer.count,
                    )
                }
            }
        }
        guard counts.row_count == rows.count else { return [] }
        return texts.withUnsafeBytes { text in
            rows.map { row in
                BlockRecord(
                    index: row.index,
                    commandText: ArenaText.text(text, row.command_offset, row.command_length),
                    exitCode: row.has_exit_code ? row.exit_code : nil,
                    durationMS: row.has_duration ? row.duration_ms : nil,
                    complete: row.complete,
                    output: ArenaText.bytes(bytes, offset: row.output_offset, length: row.output_length),
                )
            }
        }
    }

    /// The ask-size-then-fill dance every rows-plus-arena projection answers to.
    ///
    /// The first call lends nothing and learns both sizes, so a caller can never read a half-filled
    /// array as a complete one and never needs a retry per arena.
    private func project<Row>(
        _ zero: Row,
        _ door: (UnsafeMutablePointer<Row>?, Int, UnsafeMutablePointer<UInt8>?, Int)
            -> SlopDeskSupervisorCounts,
    ) -> ([Row], [UInt8]) {
        var counts = door(nil, 0, nil, 0)
        var rows = [Row](repeating: zero, count: counts.row_count)
        var arena = [UInt8](repeating: 0, count: counts.text_length)
        counts = rows.withUnsafeMutableBufferPointer { rowBuffer in
            arena.withUnsafeMutableBufferPointer { arenaBuffer in
                door(rowBuffer.baseAddress, rowBuffer.count, arenaBuffer.baseAddress, arenaBuffer.count)
            }
        }
        guard counts.row_count == rows.count else { return ([], []) }
        return (rows, arena)
    }
}

/// One block row as its value, shared by the snapshot projection and the live batch below because
/// they receive the same record — `docs/51` says one decoder reads a block wherever it turns up.
func metadata(_ row: SlopDeskSupervisorBlockRow, _ arena: UnsafeRawBufferPointer) -> BlockMetadata {
    BlockMetadata(
        index: row.index,
        exitCode: row.has_exit_code ? row.exit_code : nil,
        durationMS: row.has_duration ? row.duration_ms : nil,
        complete: row.complete,
        outputLen: row.output_len,
        commandText: ArenaText.text(arena, row.command_offset, row.command_length),
        promptOrdinal: row.prompt_ordinal,
    )
}

// MARK: - Reading a push batch

/// The `0x04` and `0x05` bodies, decoded.
///
/// Handles rather than the pure convention for the same reason the reply takes one: a batch arrives
/// once per output chunk on a pane that is printing, and asking the size then filling would decode
/// the JSON twice per chunk on the hottest path this socket has.
enum SupervisorBatch {
    /// One `{"events": [...]}` body. `nil` only when the body is not a batch at all — a member this
    /// build cannot name becomes ``SniffedEvent/unknown(kind:)``, never a thrown batch.
    static func sniffed(_ json: Data) -> [SniffedEvent]? {
        guard let handle = json.withUnsafeBytes({ bytes in
            slopdesk_sniff_batch_open(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }) else { return nil }
        defer { slopdesk_sniff_batch_free(handle) }
        let (rows, arena) = project(SlopDeskSniffRow()) { rows, rowCap, bytes, byteCap in
            slopdesk_sniff_batch_rows(handle, rows, rowCap, bytes, byteCap)
        }
        return arena.withUnsafeBytes { text in
            rows.map { row in
                let primary = ArenaText.text(text, row.primary_offset, row.primary_length)
                switch row.kind {
                case SLOPDESK_SNIFF_KIND_TITLE: return .title(primary)
                case SLOPDESK_SNIFF_KIND_BELL: return .bell
                case SLOPDESK_SNIFF_KIND_CWD: return .cwd(primary)
                case SLOPDESK_SNIFF_KIND_PROGRESS: return .progress(primary)
                case SLOPDESK_SNIFF_KIND_NOTIFICATION:
                    return .notification(
                        title: primary,
                        body: ArenaText.text(text, row.secondary_offset, row.secondary_length),
                    )
                case SLOPDESK_SNIFF_KIND_STATUS:
                    guard row.status == SLOPDESK_SNIFF_STATUS_IDLE else { return .commandRunning }
                    return .commandIdle(
                        exitCode: row.has_exit_code ? row.exit_code : nil,
                        durationMS: row.duration_ms,
                    )
                default: return .unknown(kind: primary)
                }
            }
        }
    }

    /// One `{"blocks": [...]}` body, with the same contract.
    static func blocks(_ json: Data) -> [BlockEvent]? {
        guard let handle = json.withUnsafeBytes({ bytes in
            slopdesk_block_batch_open(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }) else { return nil }
        defer { slopdesk_block_batch_free(handle) }
        let (rows, arena) = project(SlopDeskBlockEventRow()) { rows, rowCap, bytes, byteCap in
            slopdesk_block_batch_rows(handle, rows, rowCap, bytes, byteCap)
        }
        return arena.withUnsafeBytes { text in
            rows.map { row in
                switch row.kind {
                case SLOPDESK_BLOCK_EVENT_META: .block(metadata(row.meta, text))
                case SLOPDESK_BLOCK_EVENT_PROGRESS:
                    .progress(
                        row.progress == SLOPDESK_BLOCK_PROGRESS_INDETERMINATE ? .indeterminate : .clear,
                    )
                default:
                    .unknown(
                        kind: ArenaText.text(text, row.meta.command_offset, row.meta.command_length),
                    )
                }
            }
        }
    }

    /// ``SupervisorReplyReader``'s projection, for a batch handle rather than a reply handle.
    private static func project<Row>(
        _ zero: Row,
        _ door: (UnsafeMutablePointer<Row>?, Int, UnsafeMutablePointer<UInt8>?, Int)
            -> SlopDeskSupervisorCounts,
    ) -> ([Row], [UInt8]) {
        var counts = door(nil, 0, nil, 0)
        var rows = [Row](repeating: zero, count: counts.row_count)
        var arena = [UInt8](repeating: 0, count: counts.text_length)
        counts = rows.withUnsafeMutableBufferPointer { rowBuffer in
            arena.withUnsafeMutableBufferPointer { arenaBuffer in
                door(rowBuffer.baseAddress, rowBuffer.count, arenaBuffer.baseAddress, arenaBuffer.count)
            }
        }
        guard counts.row_count == rows.count else { return ([], []) }
        return (rows, arena)
    }
}
