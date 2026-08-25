import CSlopDeskFFI
import Foundation
import SlopDeskAgentDetect
import SlopDeskProtocol
import SlopDeskSupervisor

/// The Swift face of `rust/slopdesk-muxsession`'s `truths`, reached through the `pane_truths` door.
///
/// One pane's LATCHED truths — what somebody who was not listening still has to be told. The window
/// title and when it was said, the OSC 9;4 badge, whether a command is running and how the last one
/// ended, the block the shell is in, the echo anchor behind the Secure-Input pill, and how many
/// turns have finished. Every one of them is the freshest answer to a question a reattaching
/// client, the `list-panes` verb or the workspace document asks.
///
/// **Seven locks became one.** These were seven stored properties behind seven `NSLock`s, all seven
/// written on the read-loop thread and read from a control socket's. They were separate because the
/// FIELDS were separate, never because the truths are: one sniffed batch folds most of them in one
/// pass, so seven acquisitions bought no concurrency against a serial writer and cost every reader
/// the chance of a torn view.
///
/// Not `Sendable` and deliberately unlocked: ``MuxChannelSession`` holds every call under its
/// `truthsLock`, which is also the lock its agent detector now sits behind.
final class PaneTruths {
    /// Where one folded message goes.
    enum Route: UInt8 {
        /// Rides the pane's output FIFO, interleaved byte-faithfully with its chunk.
        case fifo = 0
        /// Goes to every subscriber's CONTROL sender, off the data drain.
        case broadcast = 1
        /// The pane keeps it; the client must not see it (the raw OSC-7 cwd).
        case withheld = 2
    }

    /// One message the fold produced, and where it goes.
    struct Routed {
        var message: WireMessage
        var route: Route
    }

    /// The far side, which owns every latch and both folds.
    private let handle: OpaquePointer?

    /// A pane that has said nothing yet.
    init() { handle = slopdesk_pane_truths_new() }

    deinit { slopdesk_pane_truths_free(handle) }

    // MARK: - The fold

    /// Folds one SNIFFED batch and answers its messages in order.
    ///
    /// `suppressChildNotifications` is the agent detector's verdict, read by the caller under the
    /// SAME lock and handed over as a value rather than reached for: while a pane's agent announces
    /// its own edges through the hook feed, its OSC notification duplicates the type-27 the client
    /// already banners, so one blocked prompt raises one notification.
    ///
    /// - Parameters:
    ///   - reference: `timeIntervalSinceReferenceDate` — the title stamp's scale, deliberately the
    ///     one superd's command-running stamp uses, because the two are COMPARED.
    ///   - uptime: monotonic `systemUptime` — the command-running stamp's scale.
    func ingest(
        sniffed: [SniffedEvent],
        reference: TimeInterval,
        uptime: TimeInterval,
        suppressChildNotifications: Bool,
    ) -> [Routed] {
        var table = FactTable()
        for event in sniffed { table.append(event) }
        return fold(table) { facts, count, arena, arenaLen, out, cap in
            slopdesk_pane_truths_ingest_sniffed(
                handle, facts, count, arena, arenaLen,
                reference, uptime, suppressChildNotifications, out, cap,
            )
        }
    }

    /// Folds one BLOCK batch. Every member broadcasts — block metadata rides the control sender so
    /// it never waits behind the output it describes.
    func ingest(blocks: [BlockEvent]) -> [Routed] {
        var table = FactTable()
        for event in blocks { table.append(event) }
        return fold(table) { facts, count, arena, arenaLen, out, cap in
            slopdesk_pane_truths_ingest_blocks(handle, facts, count, arena, arenaLen, out, cap)
        }
    }

    /// Lends the fact table and its arena for one call, then reads the verdicts back as messages.
    ///
    /// A mutating call cannot be retried, and does not need to be: the fold answers at most one
    /// verdict per fact, so lending `rows.count` slots always has room.
    private func fold(
        _ table: FactTable,
        _ call: (
            UnsafePointer<SlopDeskTruthFact>?, Int, UnsafePointer<UInt8>?, Int,
            UnsafeMutablePointer<SlopDeskTruthVerdict>?, Int,
        ) -> Int,
    ) -> [Routed] {
        guard !table.rows.isEmpty else { return [] }
        var verdicts = [SlopDeskTruthVerdict](
            repeating: SlopDeskTruthVerdict(), count: table.rows.count,
        )
        let written = table.rows.withUnsafeBufferPointer { rows in
            table.arena.withUnsafeBufferPointer { arena in
                verdicts.withUnsafeMutableBufferPointer { out in
                    call(
                        rows.baseAddress, rows.count, arena.baseAddress, arena.count,
                        out.baseAddress, out.count,
                    )
                }
            }
        }
        guard written > 0, written <= verdicts.count else { return [] }
        return verdicts.prefix(written).compactMap { table.routed($0) }
    }

    // MARK: - The title

    /// The pane's current window title. Empty means either "never said one" or "the agent that owned
    /// it handed it back" — an empty type-21 on the wire is unambiguously that retirement.
    var title: String { text { slopdesk_pane_truths_title($0, $1, $2) } }

    /// When the title was sniffed, on the `reference` scale. `nil` once retired.
    var titleAt: TimeInterval? {
        var at: Double = 0
        guard slopdesk_pane_truths_title_at(handle, &at) else { return nil }
        return at
    }

    /// Records that the agent that owned the title has gone: the title is dropped, its freshness
    /// verdict with it, and the sniffer's coalescing anchor is asked to retire.
    func retireTitle() { slopdesk_pane_truths_retire_title(handle) }

    /// TAKES the pending coalescing-reset request, counting it when there was one.
    ///
    /// Without the retirement the next agent's opening title — very often byte-identical to the one
    /// just handed back — would be deduped away and the pane would stay untitled.
    func takeTitleCoalescingReset() -> Bool {
        slopdesk_pane_truths_take_title_coalescing_reset(handle)
    }

    /// How many times the read loop has been asked to retire the title anchor.
    var titleAnchorRetirements: UInt64 { slopdesk_pane_truths_title_anchor_retirements(handle) }

    // MARK: - The command

    /// The freshest OSC 9;4 pair, `nil` when the badge is down.
    var progress: (state: UInt8, percent: UInt8)? {
        var state: UInt8 = 0
        var percent: UInt8 = 0
        guard slopdesk_pane_truths_progress(handle, &state, &percent) else { return nil }
        return (state, percent)
    }

    /// The badge as the type-32 that re-asserts it, `nil` when down.
    var progressMessage: WireMessage? {
        progress.map { .progress(state: $0.state, percent: $0.percent) }
    }

    /// The freshest code-carrying `D` exit status, `nil` until the first one.
    var lastExit: Int32? {
        var code: Int32 = 0
        guard slopdesk_pane_truths_last_exit(handle, &code) else { return nil }
        return code
    }

    /// The host-measured C→D duration of the last completed command.
    var lastDuration: UInt32? {
        var duration: UInt32 = 0
        guard slopdesk_pane_truths_last_duration(handle, &duration) else { return nil }
        return duration
    }

    /// When the command now running started, on the `uptime` scale. `nil` at a prompt.
    var commandRunningSince: TimeInterval? {
        var since: Double = 0
        guard slopdesk_pane_truths_command_running_since(handle, &since) else { return nil }
        return since
    }

    /// The command line the pane is running, `nil` at a prompt or with block tracking off.
    var runningCommand: String? {
        let running = text { slopdesk_pane_truths_running_command($0, $1, $2) }
        return running.isEmpty ? nil : running
    }

    // MARK: - The turn counter

    /// Folds one detected status TRANSITION and answers the completion epoch it leaves standing.
    ///
    /// Whether the shape is a finished turn is `slopdesk-agent`'s answer, asked against the status
    /// the handle already stands at; the `quiet` VETO is the fold's. A bookkeeping correction — a
    /// `/compact` boundary, an Esc-cancelled dialog, a watchdog undoing a hook block it outlasted —
    /// still moves the status everywhere it shows and must not mint an unread badge over nothing.
    @discardableResult
    func foldCompletion(_ status: ClaudeStatus, quiet: Bool) -> UInt32 {
        slopdesk_pane_truths_fold_completion(handle, status.ffiByte, quiet)
    }

    /// How many turns have finished on this pane. The host holds ZERO per-client acknowledgement
    /// state: it publishes the count, and each viewer compares it against its own device-local one.
    var completionEpoch: UInt32 { slopdesk_pane_truths_completion_epoch(handle) }

    // MARK: - The echo edge

    /// Folds one termios `ECHO` sample, answering the type-31 to enqueue — `nil` on no edge.
    ///
    /// A no-echo reading is suppressed entirely until a confirmed echo-ON sample has warmed this
    /// connection up: a freshly connected master reads `ECHO`-cleared for a sample or two before the
    /// line discipline settles, and folding that transient would latch the client's Secure-Input
    /// pill on an ordinary prompt.
    func foldEcho(echoOn: Bool) -> WireMessage? {
        message(from: slopdesk_pane_truths_fold_echo(handle, echoOn))
    }

    /// RE-ANCHORS the detector to the canonical baseline and folds `echoOn` against it — the
    /// reattach re-assert, which is NOT gated by the warm-up.
    ///
    /// The re-anchor is the load-bearing step. Echo state is by design not in the replayed output
    /// bytes, and a client resets its mirror on reconnect, so re-folding an unchanged state would
    /// emit nothing and leave a returning client's keyboard unprotected mid-password.
    func reanchorEcho(echoOn: Bool) -> WireMessage? {
        message(from: slopdesk_pane_truths_reanchor_echo(handle, echoOn))
    }

    /// An echo door's tri-state as the message it means.
    private func message(from edge: Int32) -> WireMessage? {
        edge < 0 ? nil : .inputEcho(enabled: edge != 0)
    }

    /// One block's metadata as its type-28.
    ///
    /// Shared by the live fold and the reattach backfill, which receive the same object from superd
    /// precisely so this can be one function: a re-sent block and a live one cannot disagree about a
    /// field.
    static func blockMessage(_ meta: BlockMetadata) -> WireMessage {
        .commandBlock(
            index: meta.index,
            exitCode: meta.exitCode,
            durationMS: meta.durationMS,
            complete: meta.complete,
            outputLen: meta.outputLen,
            commandText: meta.commandText,
            promptOrdinal: meta.promptOrdinal,
        )
    }

    /// One `(handle, out, cap) -> size_t` door, read through the two-call convention.
    private func text(
        _ call: (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int,
    ) -> String {
        let needed = call(handle, nil, 0)
        guard needed > 0 else { return "" }
        var out = [UInt8](repeating: 0, count: needed)
        let written = out.withUnsafeMutableBufferPointer { call(handle, $0.baseAddress, $0.count) }
        guard written == needed else { return "" }
        // The bytes came back from a Rust `String`, so the repairing initialiser has no reachable
        // failure arm; the failable one would buy an optional that can never be `nil`.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - The batch, as rows and an arena

/// One batch on its way across: `#[repr(C)]` rows, one byte arena, and the text kept beside them so
/// a verdict can be read back into a wire message without a second crossing.
///
/// The arena is what makes the fold allocation-free on the Rust side: a fact BORROWS its text out of
/// these bytes for exactly the duration of the call, and a verdict names its fact by INDEX rather
/// than repeating it.
private struct FactTable {
    /// The kinds, matching `slopdesk_muxsession::truths::Kind`.
    enum Kind: UInt8 {
        case title = 1
        case bell = 2
        case commandRunning = 3
        case commandIdle = 4
        case cwd = 5
        case notification = 6
        case progress = 7
        case block = 8
    }

    var rows: [SlopDeskTruthFact] = []
    var arena: [UInt8] = []
    private var texts: [(primary: String, secondary: String)] = []
    /// The block metadata behind each `.block` row, so its type-28 goes through the ONE constructor
    /// rather than being rebuilt out of scalars that would then have to agree with it.
    private var blocks: [Int: BlockMetadata] = [:]

    /// Interns one string and answers its `(offset, length)` pair.
    private mutating func intern(_ text: String) -> (UInt32, UInt32) {
        let bytes = Array(text.utf8)
        let offset = UInt32(truncatingIfNeeded: arena.count)
        arena.append(contentsOf: bytes)
        return (offset, UInt32(truncatingIfNeeded: bytes.count))
    }

    /// Appends one row of `kind`, carrying `primary`/`secondary` and its scalars.
    ///
    /// NOT called `append`: `Kind` and `SniffedEvent` share four case names, so `append(.bell)` bound
    /// to the event overload and recursed until the stack ran out. A distinct verb is what makes the
    /// two unmistakable at every call site.
    private mutating func push(
        _ kind: Kind,
        primary: String = "",
        secondary: String = "",
        _ fill: (inout SlopDeskTruthFact) -> Void = { _ in },
    ) {
        var row = SlopDeskTruthFact()
        row.kind = kind.rawValue
        (row.primary_offset, row.primary_length) = intern(primary)
        (row.secondary_offset, row.secondary_length) = intern(secondary)
        fill(&row)
        rows.append(row)
        texts.append((primary, secondary))
    }

    /// Appends one sniffed event. A kind this build has no name for, and a progress body the ONE
    /// grammar will not parse, are dropped here — the batch that crosses carries only facts.
    mutating func append(_ event: SniffedEvent) {
        switch event {
        case let .title(title): push(.title, primary: title)
        case .bell: push(.bell)
        case .commandRunning: push(.commandRunning)
        case let .commandIdle(exitCode, durationMS):
            push(.commandIdle) { row in
                row.has_exit_code = exitCode != nil
                row.exit_code = exitCode ?? 0
                row.has_duration = true
                row.duration_ms = durationMS
            }
        case let .cwd(path): push(.cwd, primary: path)
        case let .notification(title, body):
            push(.notification, primary: title, secondary: body)
        // OSC 9;4 crosses the superd socket unparsed, because the progress vocabulary belongs to
        // `ProgressOSCParser` and a second copy of that grammar inside the byte reader is the drift
        // that port exists to remove. A body that will not parse is dropped — it was progress
        // either way, never a notification.
        case let .progress(body):
            guard let parsed = ProgressOSCParser.parse(body) else { return }
            push(.progress) { row in
                row.progress_state = parsed.state.rawValue
                row.progress_percent = parsed.percent
            }
        case .unknown: return
        }
    }

    /// Appends one block event.
    mutating func append(_ event: BlockEvent) {
        switch event {
        case let .block(meta):
            blocks[rows.count] = meta
            push(.block, primary: meta.commandText) { row in
                row.index = meta.index
                row.has_exit_code = meta.exitCode != nil
                row.exit_code = meta.exitCode ?? 0
                row.has_duration = meta.durationMS != nil
                row.duration_ms = meta.durationMS ?? 0
                row.complete = meta.complete
                row.output_len = meta.outputLen
                row.prompt_ordinal = meta.promptOrdinal
            }
        case .progress(.indeterminate):
            push(.progress) { row in row.progress_state = ProgressState.indeterminate.rawValue }
        case .progress(.clear):
            push(.progress) { row in row.progress_state = ProgressState.clear.rawValue }
        case .unknown: return
        }
    }

    /// One verdict as the message it names, built out of the row it points back at.
    func routed(_ verdict: SlopDeskTruthVerdict) -> PaneTruths.Routed? {
        let index = Int(verdict.fact)
        guard rows.indices.contains(index),
              let kind = Kind(rawValue: verdict.kind),
              let route = PaneTruths.Route(rawValue: verdict.route),
              let message = message(kind: kind, at: index)
        else { return nil }
        return PaneTruths.Routed(message: message, route: route)
    }

    /// One row as the wire message its kind spells — the marshalling half, and only that: every
    /// DECISION about the batch (what to latch, what to withhold, what never to make at all) was
    /// taken by the fold before this runs.
    private func message(kind: Kind, at index: Int) -> WireMessage? {
        let row = rows[index]
        let text = texts[index]
        switch kind {
        case .title: return .title(text.primary)
        case .bell: return .bell
        case .commandRunning: return .commandStatus(.running)
        case .commandIdle:
            return .commandStatus(.idle(
                exitCode: row.has_exit_code ? row.exit_code : nil,
                durationMS: row.duration_ms,
            ))
        case .cwd: return .cwd(text.primary)
        case .notification: return .notification(title: text.primary, body: text.secondary)
        case .progress:
            return .progress(state: row.progress_state, percent: row.progress_percent)
        // Through the ONE constructor rather than rebuilt out of the scalars, which would then have
        // to agree with it forever.
        case .block: return blocks[index].map(PaneTruths.blockMessage)
        }
    }
}
