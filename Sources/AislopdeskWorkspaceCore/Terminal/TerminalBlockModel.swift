import AislopdeskClient
import Foundation

// MARK: - CommandBlock (one Warp-style per-command block, client-side)

/// One Warp-style "Block" as the client knows it (WB2): a per-command record built from the host's
/// `commandBlock` metadata (wire type 28). It carries ONLY the metadata — the captured OUTPUT bytes are
/// fetched on demand (``TerminalBlockModel/requestOutput(index:send:)`` → wire type 15 → 29) so the
/// CONTROL channel never floods with command output.
///
/// A PURE value type (no SwiftUI / client import beyond the metadata) so the whole block model is
/// headlessly unit-testable.
public struct CommandBlock: Equatable, Sendable, Identifiable {
    /// The 0-based block index in the channel's segmenter lifetime — the upsert key AND the
    /// ``TerminalBlockModel/requestOutput(index:send:)`` request key. Stable for a block's lifetime.
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
    /// including blockless empty-Enter / Ctrl-C cycles, matching libghostty's `.prompt` rows). The
    /// ``BlockJump`` anchor for the outline/navigator jump. `0` = unknown (mid-stream join) — the jump
    /// is skipped for such a block rather than mis-landing.
    public var promptOrdinal: UInt32

    /// `Identifiable` over the stable wire index — so SwiftUI lists key rows by the block identity.
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
    /// A block INTERRUPTED by a new prompt (a nested shell / ssh whose inner shell emits its own
    /// OSC-133 A/B without a `D`) is closed on the host as `complete == false` but carries a
    /// non-nil `durationMS` (the host stamps the C→interrupt time). Treat "has a duration" as
    /// FINISHED so such a row does not spin `running…` forever — a genuinely-running block always
    /// arrives with `durationMS == nil` (the host never stamps a duration on the running peek).
    public var status: Status {
        guard complete || durationMS != nil else { return .running }
        switch exitCode {
        case nil,
             0:
            return .succeeded
        case let code?:
            return .failed(code: code)
        }
    }

    /// The SF Symbol name for the status icon (chrome chip / navigator row / sticky header).
    public var statusSymbol: String {
        switch status {
        case .running: "circle.dotted" // a spinner is overlaid in the view; this is the static fallback
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    /// A short, human status label ("running…", "exit 0", "exit 137").
    public var statusLabel: String {
        switch status {
        case .running: "running…"
        case .succeeded: "exit \(exitCode ?? 0)"
        case let .failed(code): "exit \(code)"
        }
    }

    /// Whether this block FAILED: completed with a reported non-zero exit code. A still-running block is
    /// NEVER failed (no code yet), and a completed block with exit 0 / no reported code is a success. The
    /// single predicate the "Failed" navigator filter + jump-to-failed both read.
    public var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// The duration formatted compactly ("1.25s", "340ms"), or `nil` while running / unknown.
    public var durationLabel: String? {
        guard let ms = durationMS else { return nil }
        if ms >= 1000 {
            // One decimal of seconds (1250ms → "1.3s"); integer-rounded so the chip never jitters width.
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        return "\(ms)ms"
    }
}

// MARK: - TerminalBlockModel (the per-pane ordered, bounded block store)

/// The per-pane block store (WB2): an ORDERED, BOUNDED `[CommandBlock]` keyed by `index`, upserted from
/// the host's `commandBlock` metadata (wire type 28), plus a pending-output-request registry resolved by
/// `blockOutput` (type 29) with strict empty-eviction handling (never hangs).
///
/// PURE + headlessly testable: it holds no SwiftUI / surface / actor state. The owning
/// ``TerminalViewModel`` folds the two block events into it and the SwiftUI surfaces (navigator / sticky
/// header / chrome chip) read its observable projections. `@MainActor @Observable` like the rest of the
/// view-model layer (the events fold + the SwiftUI reads are both on the main actor), but every method is
/// a synchronous pure mutation a unit test drives directly.
@preconcurrency
@MainActor
@Observable
public final class TerminalBlockModel {
    /// The block ring cap — mirrors the host `CommandBlockTracker`'s 64-block ring so the client can never
    /// hold a block the host already evicted (a request for an over-old index just yields an empty type-29,
    /// handled gracefully). Eviction drops the OLDEST (lowest-index) blocks.
    public static let maxBlocks = 64

    /// The blocks in INDEX order (oldest first). Newest is `last`. Bounded to ``maxBlocks``.
    public private(set) var blocks: [CommandBlock] = []

    /// The newest block (the CURRENT / last command), or `nil` if none yet. Drives the sticky header +
    /// the chrome status chip.
    public var latest: CommandBlock? { blocks.last }

    /// The blocks newest-first — the Command Navigator's display order (most recent at the top).
    public var navigatorBlocks: [CommandBlock] { blocks.reversed() }

    public init() {}

    // MARK: First-seen timestamps (E9 Outline — per-index client-receive time)

    /// The CLIENT-RECEIVE time of the FIRST `commandBlock` update for each block index — the Outline tab's
    /// per-row relative-timestamp source. A SIDE-MAP (NOT a field on the ``CommandBlock`` value type) so its
    /// many call sites + its `Equatable` stay untouched. Captured ONCE on the new-index upsert (a later
    /// in-place running→complete update does NOT move it), dropped on eviction + on ``reset()``.
    /// Client-receive rather than the host clock because the host time would differ by the link RTT and
    /// there is no timestamp on the wire (E9 makes no wire change).
    @ObservationIgnored private var firstSeenByIndex: [UInt32: Date] = [:]

    /// The clock the first-seen capture reads — injectable so a unit test pins a fixed time (the production
    /// default is the real wall clock). `@ObservationIgnored`: a wiring seam, not observed state.
    @ObservationIgnored var now: () -> Date = { Date() }

    /// The client-receive time of `index`'s first `commandBlock` update, or `nil` if unknown / evicted —
    /// the Outline row's relative-timestamp source (rendered via ``OutlinePresentation/relativeTime(from:now:)``).
    public func firstSeen(index: UInt32) -> Date? { firstSeenByIndex[index] }

    // MARK: Bookmarks (WB3 — star a block)

    /// The cap on how many bookmarks one pane retains, so a long-lived session can't grow the set
    /// unbounded. When a toggle would exceed it, the OLDEST-inserted bookmark is evicted (FIFO). Generous
    /// enough that no real session hits it.
    public static let maxBookmarks = 256

    /// The bookmarked block indices, in INSERTION order (so the cap evicts the oldest). Stored as an
    /// ordered array but exposed as a `Set` for membership; persistence rides ``onBookmarksChanged``.
    @ObservationIgnored private var bookmarkOrder: [UInt32] = []

    /// The bookmarked block indices for this pane. `private(set)` — mutated only through
    /// ``toggleBookmark(index:)`` / ``setBookmarks(_:)`` so the cap + the change notification always run.
    /// Observed so the navigator star + "Bookmarked" filter re-render on a toggle.
    public private(set) var bookmarkedIndices: Set<UInt32> = []

    /// Fired on EVERY bookmark mutation with the current set, so the wiring layer can persist it (the model
    /// stays `UserDefaults`-free / pure / testable). `nil` (the default) = no persistence (a unit test or a
    /// preview). `@ObservationIgnored`: a wiring sink, not view state.
    @ObservationIgnored public var onBookmarksChanged: ((Set<UInt32>) -> Void)?

    /// Whether `index` is bookmarked.
    public func isBookmarked(_ index: UInt32) -> Bool { bookmarkedIndices.contains(index) }

    /// Toggles `index`'s bookmark: removes it if set, else adds it (evicting the oldest if over the cap).
    /// Fires ``onBookmarksChanged`` with the resulting set. Idempotent in the sense that two toggles return
    /// to the original set.
    public func toggleBookmark(index: UInt32) {
        if bookmarkedIndices.contains(index) {
            bookmarkedIndices.remove(index)
            bookmarkOrder.removeAll { $0 == index }
        } else {
            bookmarkedIndices.insert(index)
            bookmarkOrder.append(index)
            // Cap by count — evict the oldest-inserted bookmarks (FIFO) until under the bound.
            while bookmarkOrder.count > Self.maxBookmarks {
                let evicted = bookmarkOrder.removeFirst()
                bookmarkedIndices.remove(evicted)
            }
        }
        onBookmarksChanged?(bookmarkedIndices)
    }

    /// SEEDS the bookmark set from persistence on attach (does NOT fire ``onBookmarksChanged`` — this is
    /// the restore direction, not a user edit). Applies the same cap (a corrupt over-long persisted set is
    /// trimmed, keeping the FIRST ``maxBookmarks`` in the provided order). The order is the caller's
    /// (persistence stores it as an array); insertion order is preserved for future FIFO eviction.
    public func setBookmarks(_ indices: [UInt32]) {
        bookmarkOrder = []
        bookmarkedIndices = []
        for index in indices where !bookmarkedIndices.contains(index) {
            guard bookmarkOrder.count < Self.maxBookmarks else { break }
            bookmarkOrder.append(index)
            bookmarkedIndices.insert(index)
        }
    }

    // MARK: Filtered views (WB3 — status / bookmark navigator filter)

    /// The blocks NEWEST-FIRST matching `filter` — the navigator's filtered list (intersected with its text
    /// query in the view). `.all` is every block; `.failed` is completed non-zero exits (a RUNNING block is
    /// never failed); `.bookmarked` is the starred set.
    public func blocks(filter: BlockNavigatorFilter) -> [CommandBlock] {
        switch filter {
        case .all:
            navigatorBlocks
        case .failed:
            navigatorBlocks.filter(\.isFailed)
        case .bookmarked:
            navigatorBlocks.filter { bookmarkedIndices.contains($0.index) }
        }
    }

    /// The block for `index`, or `nil` if unknown / evicted.
    public func block(at index: UInt32) -> CommandBlock? {
        blocks.first { $0.index == index }
    }

    // MARK: Upsert (wire type 28 fold)

    /// Upserts a block from a `commandBlock` metadata update: a NEW index appends (kept index-ordered,
    /// evicting the oldest past ``maxBlocks``); a KNOWN index updates the existing record in place
    /// (running → completed transition, growing `outputLen`, a late command-text fill). The host emits
    /// monotonically increasing indices, but we tolerate any order: a binary-free linear scan finds the
    /// slot, and a brand-new lower index (shouldn't happen) still inserts in order.
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
        if let existing = blocks.firstIndex(where: { $0.index == index }) {
            blocks[existing] = block
            return
        }
        // New index — capture its client-receive time (Outline timestamp), insert at the index-ordered
        // position (almost always the end, since the host emits ascending indices), then evict the oldest
        // to stay bounded.
        firstSeenByIndex[index] = now()
        let insertAt = blocks.firstIndex(where: { $0.index > index }) ?? blocks.endIndex
        blocks.insert(block, at: insertAt)
        evictIfNeeded()
    }

    /// Folds one `AislopdeskClient.Event`. Only `.commandBlock` mutates the ring; `.blockOutput` resolves
    /// a pending output request (see ``resolveOutput(index:output:)``). All other events are ignored — the
    /// caller hands the whole event stream here for symmetry with the other folds.
    public func handle(_ event: AislopdeskClient.Event) {
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

    private func evictIfNeeded() {
        while blocks.count > Self.maxBlocks {
            let evicted = blocks.removeFirst()
            firstSeenByIndex.removeValue(forKey: evicted.index)
        }
    }

    /// Clears all blocks + cancels every pending output request with an empty result (so a caller awaiting
    /// one never hangs). Called on a session reset / reconnect — the dead session's blocks are stale.
    public func reset() {
        blocks.removeAll()
        // The dead session's first-seen timestamps die with its blocks (a fresh session re-captures them).
        firstSeenByIndex.removeAll()
        // Bookmarks are per-SESSION display state — a fresh session starts with none. The wiring layer
        // re-seeds them from persistence on the next attach (a new materialization mints a NEW
        // per-session scope key, so a relaunch starts empty rather than re-applying stale indices).
        // Cleared WITHOUT firing onBookmarksChanged so a reset doesn't overwrite the persisted set with
        // empty (persistence keys by the session scope key — `LivePaneSession.bookmarkScopeKey` — not the
        // stable pane id, so a within-launch reconnect's reset leaves the prior set untouched on disk).
        bookmarkOrder.removeAll()
        bookmarkedIndices.removeAll()
        // Resolve every in-flight request as "unavailable" so its continuation never strands.
        let stranded = pending
        pending.removeAll()
        for (_, callbacks) in stranded {
            for callback in callbacks { callback(nil) }
        }
    }

    // MARK: Output request → resolve flow (wire type 15 → 29)

    /// The result of an output request: the RAW VT bytes the host captured, or `nil` when the block was
    /// EVICTED / never existed (the host replied with an empty type-29) — so a consumer can distinguish
    /// "no output available" from "empty output" without hanging.
    public typealias OutputResult = Data?

    /// In-flight output requests keyed by block index. A list of callbacks per index COALESCES concurrent
    /// requests for the same block onto ONE wire request: the first request sends, later ones for the same
    /// index just append a callback; the single type-29 reply fans out to all of them.
    @ObservationIgnored private var pending: [UInt32: [(OutputResult) -> Void]] = [:]

    /// Monotonic per-index REQUEST GENERATION, bumped each time a brand-new pending slot opens for an
    /// index (NOT on a coalesced piggy-back). A timeout `Task` captures the generation it armed for and
    /// passes it to ``timeoutPending(index:generation:)``; the timeout only fires if THAT generation is
    /// still the live one — so a stale timer from request #1 can never resolve a fresh request #2 for the
    /// same index (the #5 race). Resolving / timing out a slot leaves the counter alone (it only ever
    /// advances), so the next request gets a strictly newer token.
    @ObservationIgnored private var requestGeneration: [UInt32: UInt64] = [:]

    /// The generation currently armed for an in-flight request at `index`, or `nil` if none is pending —
    /// the token a caller's timeout must match to fire. Bumped by ``requestOutput`` on a fresh send.
    public func currentRequestGeneration(index: UInt32) -> UInt64? {
        pending[index] != nil ? requestGeneration[index] : nil
    }

    /// Requests block `index`'s output, invoking `completion` with the RAW VT bytes when the host replies
    /// (or `nil` on an EMPTY reply = evicted/unknown). `send` actually fires the wire request (it is the
    /// `AislopdeskClient.requestBlockOutput` call, injected so the model stays pure / testable); a request
    /// for an already-pending index does NOT re-send (it coalesces). Returns the request GENERATION the
    /// caller should pass to ``timeoutPending(index:generation:)`` so a stale timer can't kill a later
    /// request (#5). The flow NEVER hangs: a `blockOutput` always resolves it (empty → `nil`), and the
    /// generation-gated timeout is the belt-and-braces guard for a dropped reply.
    @discardableResult
    public func requestOutput(
        index: UInt32,
        send: (UInt32) -> Void,
        completion: @escaping (OutputResult) -> Void,
    ) -> UInt64 {
        if pending[index] != nil {
            // Already in flight — coalesce: just register this callback, do NOT re-send. The live
            // generation is the one armed when this slot opened; a coalesced caller shares it.
            pending[index]?.append(completion)
            return requestGeneration[index] ?? 0
        }
        let generation = (requestGeneration[index] ?? 0) &+ 1
        requestGeneration[index] = generation
        pending[index] = [completion]
        send(index)
        return generation
    }

    /// Resolves a pending request for `index` from a `blockOutput` reply: an EMPTY `output` is treated as
    /// "unavailable" (`nil`) — the host evicted the block or never had it. A reply for an index with no
    /// pending request is dropped (a stray / late type-29 must not crash). Fans out to every coalesced
    /// callback, then clears the slot.
    public func resolveOutput(index: UInt32, output: Data) {
        guard let callbacks = pending.removeValue(forKey: index) else { return }
        let result: OutputResult = output.isEmpty ? nil : output
        for callback in callbacks { callback(result) }
    }

    /// Whether a request for `index` is still in flight (the view shows a copy spinner while true).
    public func isOutputPending(index: UInt32) -> Bool {
        pending[index] != nil
    }

    /// Times out a still-pending request for `index`, resolving it as "unavailable" (`nil`) — the
    /// belt-and-braces guard for a host that drops the reply (so the UI's copy spinner never spins
    /// forever). A no-op if the request already resolved.
    ///
    /// GENERATION-GATED (#5): fires ONLY if `generation` is still the live token for this index. A copy
    /// request resolves its slot and a SECOND copy of the same block opens a NEW slot with a NEWER
    /// generation; the first copy's parked timeout then carries a STALE generation and is correctly
    /// ignored, so it can't resolve the fresh request as "unavailable". Passing `nil` keeps the old
    /// unconditional behavior (any pending request for the index is timed out).
    public func timeoutPending(index: UInt32, generation: UInt64? = nil) {
        if let generation, requestGeneration[index] != generation { return } // stale timer — ignore.
        guard let callbacks = pending.removeValue(forKey: index) else { return }
        for callback in callbacks { callback(nil) }
    }
}

// MARK: - BlockNavigatorFilter (WB3 — the navigator's status / bookmark segment)

/// The Command Navigator's filter segment (WB3): all recent blocks, only FAILED ones (jump-to-error), or
/// only BOOKMARKED ones. A pure value enum so the model query (``TerminalBlockModel/blocks(filter:)``) and
/// the segmented control read one vocabulary. `CaseIterable` so the segmented control enumerates it.
public enum BlockNavigatorFilter: String, CaseIterable, Sendable, Hashable {
    case all
    case failed
    case bookmarked

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

// MARK: - BlockNavigation (WB3 — jump-to-failed cursor stepping)

/// PURE jump-to-failed navigation over a newest-first block list (WB3). Given the navigator's newest-first
/// `blocks`, a cursor (a block INDEX, or `nil` = start from the newest end), and a direction, it finds the
/// next/prev FAILED block — STOPPING at the ends (never wraps). Used by the active-pane "Jump to
/// Previous/Next Failed" store ops; kept pure + `nonisolated` so it unit-tests with no view / actor.
enum BlockNavigation {
    /// The next (`forward == true`) / previous (`forward == false`) FAILED block from the cursor in the
    /// NEWEST-FIRST `blocks` list, or `nil` if there is none in that direction (no wrap).
    ///
    /// Direction is expressed over the newest-first list ORDER: "forward" steps toward later positions
    /// (older blocks), "backward" toward earlier positions (newer blocks). `fromIndex == nil` starts from
    /// the newest end so a first "forward" jump lands on the newest failed block.
    ///
    /// If the cursor sits ON a failed block, the search ADVANCES PAST it (so repeated jumps walk through
    /// every failure rather than sticking). A cursor index not present in `blocks` (evicted) starts from the
    /// matching end.
    nonisolated static func adjacentFailed(
        in blocks: [CommandBlock],
        fromIndex: UInt32?,
        forward: Bool,
    ) -> CommandBlock? {
        guard !blocks.isEmpty else { return nil }
        // The cursor's position in the newest-first list, or a virtual position just OFF the matching end
        // when there is no cursor / it was evicted: forward starts before position 0 (so it can land on 0),
        // backward starts after the last position (so it can land on the last).
        let cursorPos: Int = fromIndex
            .flatMap { idx in blocks.firstIndex { $0.index == idx } } ?? (forward ? -1 : blocks.count)
        if forward {
            var pos = cursorPos + 1
            while pos < blocks.count {
                if blocks[pos].isFailed { return blocks[pos] }
                pos += 1
            }
        } else {
            var pos = cursorPos - 1
            while pos >= 0 {
                if blocks[pos].isFailed { return blocks[pos] }
                pos -= 1
            }
        }
        return nil
    }
}
