// The per-pane command blocks, as the Swift face of `rust/slopdesk-terminal`'s `blocks`, reached
// through `rust/slopdesk-ffi`'s `blocks` door.
//
// ## What is not here any more
//
// The ring and its bound, the ordered insert that tolerates a late lower index, the eviction that
// takes the oldest block and its first-seen stamp with it, the bookmark set with its FIFO cap and
// its restore-is-not-an-edit rule, the status a block derives from `complete` and `exitCode`, the
// duration label, the jump-to-failed walk, and the coalescing and generation rules that decide
// whether an output request goes on the wire at all. All Rust's, in a crate that forbids `unsafe`.
//
// ## What stays, and why it has to
//
// Two things cannot cross. The CALLBACKS a resolved request fans out to are Swift closures, so this
// file keeps a bag of them keyed by index — a bag, not a rule: the door decides send-versus-coalesce
// and owns the generation, and this side only remembers who to call. And the SF Symbol and label
// strings a row displays are the surface's vocabulary, derived here from the door's status.
//
// ## Why `blocks` is a mirror rather than a query
//
// `@Observable` tracks stored properties, so the array the navigator's tracked arm reads has to live here —
// a computed projection over the door would register no dependency at all and wake nobody. When the ring
// MOVES — a new command, an eviction, a reset — it is rebuilt by one `slopdesk_block_store_project`
// crossing that writes every row and the one arena their command texts share, rather than 64
// crossings for one answer. When a known block merely CHANGES, the door names the slot it landed in
// and this side writes that one element; rebuilding 64 rows to move one field measured at eight
// times the cost, and that is the update the host sends most.

import CSlopDeskFFI
import Foundation
import SlopDeskArena
import SlopDeskClient

// MARK: - CommandBlock (one Warp-style per-command block, client-side)

/// One Warp-style "Block" as the client knows it: a per-command record built from the host's
/// `commandBlock` metadata (wire type 28). Metadata ONLY — the captured OUTPUT bytes are fetched on
/// demand (``TerminalBlockModel/requestOutput(index:send:completion:)`` → wire type 15 → 29) so the
/// CONTROL channel never floods with command output.
///
/// A PURE value type (metadata only — no view framework, no client) so the block model is headlessly testable.
/// Every derived property — ``status``, ``isFailed``, ``durationLabel`` — asks the door, so the rule
/// behind it has one speller.
public struct CommandBlock: Equatable, Sendable, Identifiable {
    /// The 0-based block index in the channel's segmenter lifetime — the upsert key AND the
    /// ``TerminalBlockModel/requestOutput(index:send:completion:)`` request key. Stable for a
    /// block's lifetime.
    public let index: UInt32
    /// The typed command line (no prompt), as the host segmented it. Empty for a still-forming block.
    public var commandText: String
    /// The command's `$?` once it finished (nil while running, or if the shell did not report one).
    public var exitCode: Int32?
    /// The host-measured C→D wall-clock time in ms (nil while still running).
    public var durationMS: UInt32?
    /// True once the matching OSC 133 `D` arrived — the command finished.
    public var complete: Bool
    /// How many output bytes the host currently holds for this block (UI size hint / "has output" gate).
    public var outputLen: UInt32
    /// The block's 1-based PROMPT-CYCLE ordinal (the count of OSC-133 `A` marks at the block's start —
    /// including blockless empty-Enter / Ctrl-C cycles, matching the prompt rows libghostty-vt flags per
    /// OSC-133 `A` mark). The
    /// ``BlockJump`` anchor for the outline/navigator jump. `0` = unknown (mid-stream join) — the jump
    /// is skipped for such a block rather than mis-landing.
    public var promptOrdinal: UInt32

    /// `Identifiable` over the stable wire index: a block's identity is the index the host segmented it at,
    /// never its position in ``TerminalBlockModel/blocks`` — which shifts under every eviction.
    ///
    /// ⚠️ NOTHING READS THIS TODAY. It was the key a SwiftUI list diffed rows by, and the imperative
    /// navigators (`MacCommandNavigator` / the phone's) address rows by `index` directly. Kept because the
    /// conformance is the honest statement of what identifies a block, and a future diffing data source
    /// wants exactly this key — not because a caller needs it.
    public var id: UInt32 { index }

    public init(
        index: UInt32,
        commandText: String,
        exitCode: Int32? = nil,
        durationMS: UInt32? = nil,
        complete: Bool = false,
        outputLen: UInt32 = 0,
        promptOrdinal: UInt32 = 0,
    ) {
        self.index = index
        self.commandText = commandText
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.complete = complete
        self.outputLen = outputLen
        self.promptOrdinal = promptOrdinal
    }

    /// The wire fields as the door's record — everything but the command text, which no derived
    /// property reads.
    var fields: SlopDeskBlockFields {
        SlopDeskBlockFields(
            index: index,
            has_exit_code: exitCode != nil,
            exit_code: exitCode ?? 0,
            has_duration_ms: durationMS != nil,
            duration_ms: durationMS ?? 0,
            complete: complete,
            output_len: outputLen,
            prompt_ordinal: promptOrdinal,
        )
    }

    /// Builds a block from a projected row and the arena its command text sits in.
    init(row: SlopDeskBlockRow, arena: UnsafeRawBufferPointer) {
        // Bounds-checked by ``ArenaText`` — this reader had none at all, and a projected row whose
        // pair ran past the arena would have read whatever followed it.
        self.init(row: row, commandText: ArenaText.text(arena, row.command_offset, row.command_length))
    }

    /// Builds a block from a projected row and a command text already in hand — the carry-over path,
    /// where the previous mirror's string is byte-identical and is passed on rather than rebuilt.
    init(row: SlopDeskBlockRow, commandText: String) {
        self.init(
            index: row.fields.index,
            commandText: commandText,
            exitCode: row.fields.has_exit_code ? row.fields.exit_code : nil,
            durationMS: row.fields.has_duration_ms ? row.fields.duration_ms : nil,
            complete: row.fields.complete,
            outputLen: row.fields.output_len,
            promptOrdinal: row.fields.prompt_ordinal,
        )
    }

    // MARK: Status → presentation (the testable icon/label mapping)

    /// The block's high-level status, derived purely from `complete` + `exitCode`.
    public enum Status: Equatable, Sendable {
        /// Still executing (no OSC 133 `D` yet) — the spinner state.
        case running
        /// Finished successfully (exit 0, or the shell reported no code — treated as success).
        case succeeded
        /// Finished with a non-zero exit `code`.
        case failed(code: Int32)
    }

    /// The derived status: running until complete, then succeeded (exit 0 / unknown) or failed (≠0).
    ///
    /// A block INTERRUPTED by a new prompt (a nested shell / ssh emits its own OSC-133 A/B without a
    /// `D`) is closed on the host as `complete == false` but with non-nil `durationMS` (the host stamps
    /// the C→interrupt time). "Has a duration" therefore counts as FINISHED so the row doesn't spin
    /// `running…` forever — and that rule lives in the door, not here.
    public var status: Status {
        Self.status(from: slopdesk_block_status(fields))
    }

    /// Every block's ``Status`` in ONE crossing, in the order given — the form a caller holding the
    /// whole ring asks for.
    ///
    /// The rule is the same door's; what changes is how often the boundary is crossed to run it. The
    /// peek transcript derives a status per block inside a `map`, on every render pass of the
    /// overlay, and then hands the strings it built back across this boundary in the very next call,
    /// so `n` crossings became one. ``status`` stays for the row that is asking about itself.
    public static func statuses(of blocks: [Self]) -> [Status] {
        guard !blocks.isEmpty else { return [] }
        let held = blocks.map(\.fields)
        var answers = [SlopDeskBlockStatus](repeating: SlopDeskBlockStatus(), count: held.count)
        let written = held.withUnsafeBufferPointer { input in
            answers.withUnsafeMutableBufferPointer { room in
                slopdesk_block_statuses(input.baseAddress, input.count, room.baseAddress, room.count)
            }
        }
        // The buffer is sized at the list just handed over and the door writes all or nothing, so a
        // short write is unreachable — which is what makes this a precondition rather than a second
        // path that would quietly answer a transcript one status short.
        precondition(written == held.count, "the status door answered a count it would not fill")
        return answers.map(Self.status(from:))
    }

    /// The tagged answer as this side's case. One speller, so the single door and the list door
    /// cannot decode the same byte differently.
    private static func status(from answer: SlopDeskBlockStatus) -> Status {
        switch answer.kind {
        case UInt32(SLOPDESK_BLOCK_STATUS_RUNNING): .running
        case UInt32(SLOPDESK_BLOCK_STATUS_FAILED): .failed(code: answer.code)
        default: .succeeded
        }
    }

    /// The SF Symbol name for the status icon (chrome chip / navigator row).
    public var statusSymbol: String {
        switch status {
        case .running: "circle.dotted" // a spinner is overlaid in the view; this is the static fallback
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    /// A short, human status label ("running…", "exit 0", "exit 137").
    public var statusLabel: String {
        Self.label(for: status, exitCode: exitCode)
    }

    /// Every block's ``statusLabel``, over ONE ``statuses(of:)`` crossing — the whole-list form the
    /// peek transcript reads, satisfying `PeekBlockLine`'s requirement of the same name.
    public static func statusLabels(of lines: [Self]) -> [String] {
        zip(lines, statuses(of: lines)).map { block, status in
            label(for: status, exitCode: block.exitCode)
        }
    }

    /// The words a status reads as. The surface's vocabulary, deliberately on this side (the door's
    /// module says so), and spelled ONCE so a row and a transcript cannot print different words for
    /// the same block.
    private static func label(for status: Status, exitCode: Int32?) -> String {
        switch status {
        case .running: "running…"
        case .succeeded: "exit \(exitCode ?? 0)"
        case let .failed(code): "exit \(code)"
        }
    }

    /// Whether this block FAILED: completed with a reported non-zero exit code. A running block is NEVER
    /// failed; a completed exit-0 / no-code block is a success. The single predicate the "Failed"
    /// navigator filter + jump-to-failed both read.
    public var isFailed: Bool {
        slopdesk_block_status(fields).kind == UInt32(SLOPDESK_BLOCK_STATUS_FAILED)
    }

    /// The longest label the door can produce: `u32::MAX` milliseconds is `"4294967.3s"`, ten bytes.
    /// A stack buffer this size turns the usual size-then-fill pair into ONE crossing and no heap
    /// allocation — worth naming because this is read once per row per render, and the pair cost
    /// twice what the whole label is worth.
    private static let durationLabelCapacity = 16

    /// The duration formatted compactly ("1.3s", "340ms"), or `nil` while running / unknown.
    public var durationLabel: String? {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Self.durationLabelCapacity) { buffer in
            let written = slopdesk_block_duration_label(fields, buffer.baseAddress, buffer.count)
            guard written > 0, written <= buffer.count else { return nil }
            return String(decoding: buffer[..<written], as: UTF8.self)
        }
    }
}

// MARK: - TerminalBlockModel (the per-pane ordered, bounded block store)

/// The per-pane block store: an ORDERED, BOUNDED `[CommandBlock]` keyed by `index`, upserted from
/// the host's `commandBlock` metadata (wire type 28), plus a pending-output-request registry resolved by
/// `blockOutput` (type 29) — empty-eviction handled so it never hangs.
///
/// PURE + headlessly testable: no view framework, no surface, no actor state. The owning ``TerminalViewModel``
/// folds the two block events in; the surfaces that show them (navigator / chrome chip) track
/// its observable projections from their own arms. `@MainActor @Observable` (fold + reads are both on the main actor), yet
/// every method is a synchronous mutation a unit test drives directly.
@preconcurrency
@MainActor
@Observable
public final class TerminalBlockModel {
    /// The block ring cap — mirrors superd's 64-block ring (`rust/slopdesk-superd/src/blocks.rs`,
    /// `DEFAULT_MAX_BLOCKS`) so the client can never hold a block the daemon already evicted (an
    /// over-old index just yields an empty type-29). Eviction drops the OLDEST (lowest-index) blocks.
    ///
    /// Agreement with `blocks::MAX_BLOCKS` is a `slopdesk-invariants` gate, not a comment.
    public static let maxBlocks = 64

    /// Cap on bookmarks per pane so a long-lived session can't grow the set unbounded. Over the cap, the
    /// OLDEST-inserted bookmark is evicted (FIFO). Pinned against `blocks::MAX_BOOKMARKS` by the same gate.
    public static let maxBookmarks = 256

    /// The blocks in INDEX order (oldest first). Newest is `last`. Bounded to ``maxBlocks``.
    ///
    /// A MIRROR of the door's ring, rebuilt after every mutation: `@Observable` tracks stored
    /// properties, so the array the views read has to live on this side of the boundary.
    public private(set) var blocks: [CommandBlock] = []

    /// The bookmarked block indices for this pane. Mirrored from the door alongside ``blocks`` so the
    /// navigator star + "Bookmarked" filter re-render on a toggle.
    public private(set) var bookmarkedIndices: Set<UInt32> = []

    /// The door's store: the ring, the bookmark set and the request registry that resets with it.
    ///
    /// `nonisolated(unsafe)` for `deinit` alone: every OTHER touch is on the main actor with the
    /// class, and by the time `deinit` runs the last reference is already gone, so the free races
    /// with nothing.
    @ObservationIgnored private nonisolated(unsafe) let store: OpaquePointer

    public init() {
        guard let handle = slopdesk_block_store_new() else {
            preconditionFailure("the block store door would not open")
        }
        store = handle
    }

    deinit { slopdesk_block_store_free(store) }

    /// The newest block (the CURRENT / last command), or `nil` if none yet. Drives the chrome status chip.
    ///
    /// NOT the pinned command head: that is `slopdesk_termrender::pin`, and it reads the row the shell
    /// drew from the block LAYOUT rather than this ring — the head has to render for a block the host
    /// has told us nothing about yet, which is every block while its command is still running.
    public var latest: CommandBlock? { blocks.last }

    /// The blocks newest-first — the Command Navigator's display order (most recent at the top).
    public var navigatorBlocks: [CommandBlock] { blocks.reversed() }

    // MARK: First-seen timestamps (per-index client-receive time, for the Outline tab)

    /// The clock first-seen capture reads — injectable so a unit test pins a fixed time (production default
    /// is the real wall clock). `@ObservationIgnored`: a wiring seam, not observed state.
    @ObservationIgnored var now: () -> Date = { Date() }

    /// The client-receive time of `index`'s first `commandBlock` update, or `nil` if unknown / evicted —
    /// the Outline row's relative-timestamp source (rendered via ``OutlinePresentation/relativeTime(from:now:)``).
    ///
    /// Captured ONCE on the new-index upsert (a later in-place running→complete update does NOT move it),
    /// dropped on eviction + ``reset()`` — all of that inside the door. Client-receive rather than the host
    /// clock because host time would differ by the link RTT and there is no wire timestamp to use instead.
    public func firstSeen(index: UInt32) -> Date? {
        let stamp = slopdesk_block_store_first_seen(store, index)
        guard stamp.has_value else { return nil }
        return Date(timeIntervalSince1970: Double(stamp.value) / 1000.0)
    }

    // MARK: Bookmarks (star a block)

    /// Fired on EVERY bookmark mutation with the current set so the wiring layer can persist it (the model
    /// stays `UserDefaults`-free / pure). `nil` (default) = no persistence (unit test or preview).
    /// `@ObservationIgnored`: a wiring sink, not view state.
    @ObservationIgnored public var onBookmarksChanged: ((Set<UInt32>) -> Void)?

    /// Whether `index` is bookmarked.
    public func isBookmarked(_ index: UInt32) -> Bool {
        slopdesk_block_store_is_bookmarked(store, index)
    }

    /// Toggles `index`'s bookmark: removes it if set, else adds it (evicting the oldest if over the cap).
    /// Fires ``onBookmarksChanged`` with the resulting set. Idempotent in the sense that two toggles return
    /// to the original set.
    public func toggleBookmark(index: UInt32) {
        slopdesk_block_store_toggle_bookmark(store, index)
        refreshBookmarks()
        onBookmarksChanged?(bookmarkedIndices)
    }

    /// SEEDS the bookmark set from persistence on attach (does NOT fire ``onBookmarksChanged`` — restore,
    /// not a user edit). Applies the same cap (a corrupt over-long set is trimmed to the FIRST
    /// ``maxBookmarks`` in the caller's order); insertion order is preserved for future FIFO eviction.
    public func setBookmarks(_ indices: [UInt32]) {
        slopdesk_block_store_set_bookmarks(store, indices, indices.count)
        refreshBookmarks()
    }

    // MARK: Filtered views (status / bookmark navigator filter)

    /// The blocks NEWEST-FIRST matching `filter` — the navigator's filtered list (intersected with its text
    /// query in the view). `.all` is every block; `.failed` is completed non-zero exits (a RUNNING block is
    /// never failed); `.bookmarked` is the starred set. The rule is the door's; this maps the indices it
    /// answers back onto the mirrored rows.
    public func blocks(filter: BlockNavigatorFilter) -> [CommandBlock] {
        let count = slopdesk_block_store_filtered(store, filter.code, nil, 0)
        guard count > 0 else { return [] }
        var matched = [UInt32](repeating: 0, count: count)
        let written = matched.withUnsafeMutableBufferPointer {
            slopdesk_block_store_filtered(store, filter.code, $0.baseAddress, $0.count)
        }
        guard written == count else { return [] }
        let byIndex = Dictionary(blocks.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        return matched.compactMap { byIndex[$0] }
    }

    /// The block for `index`, or `nil` if unknown / evicted.
    public func block(at index: UInt32) -> CommandBlock? {
        blocks.first { $0.index == index }
    }

    /// The block whose 1-based PROMPT-CYCLE ordinal is `ordinal`, or `nil` when none has it.
    ///
    /// The one hop between the two keys a block wears. A right-click over the grid resolves to an
    /// ORDINAL — the join key, which survives the output that re-flows the layout while the menu is
    /// open — and everything that then ACTS on the block (the output request, the star) is keyed by the
    /// ring ``CommandBlock/index``. The door owns the rule, not this side: `0` is "the host attached
    /// mid-stream and could not count prompts", which several blocks can wear, so it resolves to
    /// nothing rather than to whichever one is first; and a reattach that replayed a record over a ring
    /// already holding that ordinal resolves to the NEWEST index, which is the block still on screen.
    public func block(promptOrdinal ordinal: UInt32) -> CommandBlock? {
        let index = slopdesk_block_store_index_of_prompt_ordinal(store, ordinal)
        guard index >= 0, let index = UInt32(exactly: index) else { return nil }
        return block(at: index)
    }

    // MARK: Upsert (wire type 28 fold)

    /// Upserts a block from a `commandBlock` metadata update: a NEW index appends (kept index-ordered,
    /// evicting the oldest past ``maxBlocks``); a KNOWN index updates in place (running → completed,
    /// growing `outputLen`, a late command-text fill). The host emits ascending indices, but the door
    /// tolerates any order: a brand-new lower index still inserts in order.
    public func upsert(
        index: UInt32,
        commandText: String,
        exitCode: Int32?,
        durationMS: UInt32?,
        complete: Bool,
        outputLen: UInt32,
        promptOrdinal: UInt32 = 0,
    ) {
        let block = CommandBlock(
            index: index,
            commandText: commandText,
            exitCode: exitCode,
            durationMS: durationMS,
            complete: complete,
            outputLen: outputLen,
            promptOrdinal: promptOrdinal,
        )
        var text = commandText
        let stamp = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let landed = text.withUTF8 {
            slopdesk_block_store_upsert(store, block.fields, $0.baseAddress, $0.count, stamp)
        }
        // A known index REPLACES its slot with exactly the block just built, so the mirror is one
        // element behind and nothing else moved. Reading the whole ring back for that costs the same
        // as reading it back for a command that did not exist a moment ago, and this is the update
        // that arrives on every output-length growth of whatever is running.
        if landed.replaced, landed.position < blocks.count, blocks[landed.position].index == index {
            blocks[landed.position] = block
        } else {
            refreshBlocks()
        }
    }

    /// Folds one `SlopDeskClient.Event`. Only `.commandBlock` mutates the ring; `.blockOutput` resolves
    /// a pending output request (see ``resolveOutput(index:output:)``). All other events are ignored — the
    /// caller hands the whole event stream here for symmetry with the other folds.
    public func handle(_ event: SlopDeskClient.Event) {
        switch event {
        case let .commandBlock(index, exitCode, durationMS, complete, outputLen, commandText, promptOrdinal):
            upsert(
                index: index, commandText: commandText, exitCode: exitCode,
                durationMS: durationMS, complete: complete, outputLen: outputLen,
                promptOrdinal: promptOrdinal,
            )
        case let .blockOutput(index, output):
            resolveOutput(index: index, output: output)
        default:
            break
        }
    }

    /// Clears all blocks + cancels every pending output request with an empty result (so a caller awaiting
    /// one never hangs). Called on a session reset / reconnect — the dead session's blocks are stale.
    ///
    /// Bookmarks go WITHOUT firing ``onBookmarksChanged``: a reset must not overwrite the persisted set
    /// with empty. Persistence keys by the session scope key — `LivePaneSession.bookmarkScopeKey` — not
    /// the stable pane id, so a within-launch reconnect's reset leaves the prior set untouched on disk.
    public func reset() {
        // The door drops the blocks, the stamps and the bookmarks and hands back every request it
        // stranded, in one call — a reset that dropped the blocks without naming them would leave a
        // continuation parked forever.
        let count = slopdesk_block_store_reset(store)
        var stranded = [UInt32](repeating: 0, count: count)
        let written = stranded.withUnsafeMutableBufferPointer {
            slopdesk_block_store_take_stranded(store, $0.baseAddress, $0.count)
        }
        precondition(written == count, "the stranded slot answered a size it would not fill")
        refreshBlocks()
        refreshBookmarks()
        for index in stranded {
            guard let callbacks = pending.removeValue(forKey: index) else { continue }
            for callback in callbacks { callback(nil) }
        }
        // Anything the door did not name has no live slot, so nothing is waiting on the wire for it.
        let orphaned = pending
        pending.removeAll()
        for (_, callbacks) in orphaned {
            for callback in callbacks { callback(nil) }
        }
    }

    // MARK: Output request → resolve flow (wire type 15 → 29)

    /// The result of an output request: the RAW VT bytes the host captured, or `nil` when the block was
    /// EVICTED / never existed (the host replied with an empty type-29) — so a consumer can distinguish
    /// "no output available" from "empty output" without hanging.
    public typealias OutputResult = Data?

    /// The callbacks waiting on each in-flight index. A BAG, not a rule: whether a request coalesces or
    /// goes on the wire, and which generation it is under, are the door's answers. This only remembers who
    /// to call when one resolves — a list per index so concurrent requests for the same block all get the
    /// single reply.
    @ObservationIgnored private var pending: [UInt32: [(OutputResult) -> Void]] = [:]

    /// The generation currently armed for an in-flight request at `index`, or `nil` if none is pending —
    /// the token a caller's timeout must match to fire.
    public func currentRequestGeneration(index: UInt32) -> UInt64? {
        let armed = slopdesk_block_store_current_generation(store, index)
        return armed.has_value ? armed.value : nil
    }

    /// Requests block `index`'s output, invoking `completion` with the RAW VT bytes when the host replies
    /// (or `nil` on an EMPTY reply = evicted/unknown). `send` fires the wire request (the injected
    /// `SlopDeskClient.requestBlockOutput`, so the model stays pure / testable); an already-pending index
    /// does NOT re-send (it coalesces). Returns the request GENERATION to pass to
    /// ``timeoutPending(index:generation:)`` so a stale timer can't kill a later request. NEVER hangs:
    /// a `blockOutput` always resolves it (empty → `nil`), and the generation-gated timeout guards a
    /// dropped reply.
    @discardableResult
    public func requestOutput(
        index: UInt32,
        send: (UInt32) -> Void,
        completion: @escaping (OutputResult) -> Void,
    ) -> UInt64 {
        let decision = slopdesk_block_store_request(store, index)
        pending[index, default: []].append(completion)
        if decision.send { send(index) }
        return decision.generation
    }

    /// Resolves a pending request for `index` from a `blockOutput` reply: an EMPTY `output` is treated as
    /// "unavailable" (`nil`) — the host evicted the block or never had it. A reply for an index with no
    /// pending request is dropped (a stray / late type-29 must not crash). Fans out to every coalesced
    /// callback, then clears the slot.
    public func resolveOutput(index: UInt32, output: Data) {
        guard slopdesk_block_store_resolve(store, index) else { return }
        let callbacks = pending.removeValue(forKey: index) ?? []
        let result: OutputResult = output.isEmpty ? nil : output
        for callback in callbacks { callback(result) }
    }

    /// Whether a request for `index` is still in flight (the view shows a copy spinner while true).
    public func isOutputPending(index: UInt32) -> Bool {
        slopdesk_block_store_is_pending(store, index)
    }

    /// Times out a still-pending request for `index`, resolving it as "unavailable" (`nil`) — the
    /// belt-and-braces guard for a host that drops the reply (so the UI's copy spinner never spins
    /// forever). A no-op if the request already resolved.
    ///
    /// GENERATION-GATED by the door: it fires ONLY if `generation` is still the live token for this index.
    /// A copy request resolves its slot and a SECOND copy of the same block opens a NEW slot with a NEWER
    /// generation; the first copy's parked timeout then carries a STALE generation and is correctly
    /// ignored. Passing `nil` times out whatever is pending.
    public func timeoutPending(index: UInt32, generation: UInt64? = nil) {
        guard slopdesk_block_store_time_out(store, index, generation != nil, generation ?? 0) else { return }
        let callbacks = pending.removeValue(forKey: index) ?? []
        for callback in callbacks { callback(nil) }
    }

    // MARK: Mirroring the door

    /// The projection's landing ground, kept between calls and grown but never shrunk. An upsert is
    /// not rare — it arrives on every output-length growth of a RUNNING command — and a fresh pair of
    /// buffers per call was two allocations for an answer that is the same size as the last one.
    @ObservationIgnored private var rowScratch: [SlopDeskBlockRow] = []
    @ObservationIgnored private var arenaScratch: [UInt8] = []

    /// Rebuilds ``blocks`` from the door — one crossing that writes every row and the one arena their
    /// command texts share.
    ///
    /// Only a projection that does not fit the scratch costs a second crossing: §4 says nothing is
    /// written unless BOTH buffers fit, and the sizes needed come back either way, so the sizing call
    /// is the failure path rather than the usual one.
    ///
    /// This runs when the ring MOVED — a new command, an eviction, a reset. The far commoner update,
    /// a running command's output length growing, replaces one slot and is written straight into
    /// ``blocks`` by ``upsert(index:commandText:exitCode:durationMS:complete:outputLen:promptOrdinal:)``
    /// without coming here at all; rebuilding 64 rows to change one field measured at eight times
    /// what writing the one costs, and no arrangement of the rebuild closed that gap.
    private func refreshBlocks() {
        var written = project()
        if written.row_count > rowScratch.count || written.arena_length > arenaScratch.count {
            rowScratch = [SlopDeskBlockRow](
                repeating: SlopDeskBlockRow(), count: Swift.max(written.row_count, Self.maxBlocks),
            )
            arenaScratch = [UInt8](repeating: 0, count: Swift.max(written.arena_length, 4096))
            written = project()
            precondition(
                written.row_count <= rowScratch.count && written.arena_length <= arenaScratch.count,
                "the projection outgrew a scratch sized to its own answer",
            )
        }
        let count = written.row_count
        blocks = count == 0 ? [] : arenaScratch.withUnsafeBytes { arena in
            (0..<count).map { CommandBlock(row: rowScratch[$0], arena: arena) }
        }
    }

    /// Asks the door to write the projection into the scratch, and returns the sizes it NEEDED —
    /// which is what it wrote when the scratch was big enough, and what to grow to when it was not.
    private func project() -> SlopDeskBlockCounts {
        rowScratch.withUnsafeMutableBufferPointer { rows in
            arenaScratch.withUnsafeMutableBufferPointer { arena in
                slopdesk_block_store_project(
                    store,
                    rows.baseAddress, rows.count,
                    arena.baseAddress, arena.count,
                )
            }
        }
    }

    /// Rebuilds ``bookmarkedIndices`` from the door.
    private func refreshBookmarks() {
        let count = slopdesk_block_store_bookmarks(store, nil, 0)
        guard count > 0 else {
            bookmarkedIndices = []
            return
        }
        var marked = [UInt32](repeating: 0, count: count)
        let written = marked.withUnsafeMutableBufferPointer {
            slopdesk_block_store_bookmarks(store, $0.baseAddress, $0.count)
        }
        bookmarkedIndices = written == count ? Set(marked) : []
    }
}

// MARK: - BlockNavigatorFilter (the navigator's status / bookmark segment)

/// The Command Navigator's filter segment: all recent blocks, only FAILED ones (jump-to-error), or
/// only BOOKMARKED ones. A pure value enum so the model query (``TerminalBlockModel/blocks(filter:)``) and
/// the segmented control read one vocabulary. `CaseIterable` so the segmented control enumerates it.
public enum BlockNavigatorFilter: String, CaseIterable, Sendable, Hashable {
    case all
    case failed
    case bookmarked

    /// The `SLOPDESK_BLOCK_FILTER_*` code the door reads.
    var code: UInt32 {
        switch self {
        case .all: UInt32(SLOPDESK_BLOCK_FILTER_ALL)
        case .failed: UInt32(SLOPDESK_BLOCK_FILTER_FAILED)
        case .bookmarked: UInt32(SLOPDESK_BLOCK_FILTER_BOOKMARKED)
        }
    }

    /// The segment label.
    public var title: String {
        switch self {
        case .all: "All"
        case .failed: "Failed"
        case .bookmarked: "Bookmarked"
        }
    }

    /// The SF Symbol for the segment.
    public var symbol: String {
        switch self {
        case .all: "list.bullet"
        case .failed: "xmark.octagon"
        case .bookmarked: "star"
        }
    }
}

// MARK: - BlockNavigation (jump-to-failed cursor stepping)

/// PURE jump-to-failed navigation over a newest-first block list — the Swift face of
/// `blocks::adjacent_failed`.
///
/// It takes a LIST rather than the model because the walk runs over whatever the caller projected:
/// the navigator's newest-first rows in production, a hand-built list in a test. Kept `nonisolated`
/// so it unit-tests with no view / actor.
enum BlockNavigation {
    /// The next (`forward == true`) / previous (`forward == false`) FAILED block from the cursor in the
    /// NEWEST-FIRST `blocks` list, or `nil` if there is none in that direction (no wrap).
    ///
    /// Direction is expressed over the newest-first list ORDER: "forward" steps toward later positions
    /// (older blocks), "backward" toward earlier positions (newer blocks). `fromIndex == nil` starts from
    /// the newest end so a first "forward" jump lands on the newest failed block. A cursor sitting ON a
    /// failed block ADVANCES PAST it (so repeated jumps walk through every failure rather than sticking);
    /// a cursor index not present in `blocks` (evicted) starts from the matching end.
    nonisolated static func adjacentFailed(
        in blocks: [CommandBlock],
        fromIndex: UInt32?,
        forward: Bool,
    ) -> CommandBlock? {
        let fields = blocks.map(\.fields)
        var found: UInt32 = 0
        let hit = fields.withUnsafeBufferPointer { buffer in
            slopdesk_block_adjacent_failed(
                buffer.baseAddress, buffer.count,
                fromIndex != nil, fromIndex ?? 0, forward,
                &found,
            )
        }
        guard hit else { return nil }
        return blocks.first { $0.index == found }
    }
}
