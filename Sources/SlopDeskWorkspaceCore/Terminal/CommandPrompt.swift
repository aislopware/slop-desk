// The editor-like command prompt, as the Swift face of `rust/slopdesk-terminal`'s `prompt` module,
// reached through `rust/slopdesk-ffi`'s `prompt` door.
//
// ## What is not here
//
// Every rule. The text buffer and its grapheme/word/line motions, the undo stack and its coalescing,
// the shell lexer that decides both the colours and whether Enter runs, the history ring, the
// reverse search, and the fzf ranking behind completion — all Rust's, in a crate that forbids
// `unsafe`. What is here is a handle's lifetime and the vocabulary a view binds.
//
// ## Why the state is cached
//
// Every mutating call refreshes one `SlopDeskPromptState` record, so `cursor`, `selection`,
// `wouldRun` and the rest are plain field reads rather than a boundary crossing each. Reading them
// one at a time across the door would also let a keystroke interleave between two reads and pair a
// cursor from before it with a selection from after — the reason the door answers one record at all.
//
// ## What stays on this side
//
// Composition (`NSTextInputClient` / `UITextInput`), key mapping, and how the candidate list looks.
// `docs/68` §10 keeps those in the view: a motion crosses as a case, never as a key, so ⌥→ on macOS
// and ⌃→ elsewhere arrive as the same ``PromptMotion/word(_:)``.

import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// Which way a motion runs.
public enum PromptDirection: Sendable, Equatable {
    /// Toward the start of the document.
    case backward
    /// Toward the end.
    case forward
}

/// A caret movement, named by what it means rather than by the key that sends it.
///
/// Every case is also a DELETION granularity, which is why ``CommandPrompt/delete(_:)`` takes one.
public enum PromptMotion: Sendable, Equatable {
    /// One grapheme cluster.
    case grapheme(PromptDirection)
    /// To the far edge of the neighbouring UAX #29 word.
    case word(PromptDirection)
    /// To the start or end of the current logical line.
    case lineEdge(PromptDirection)
    /// One logical line up or down, keeping the goal column.
    case line(PromptDirection)
    /// To the start or end of the whole document.
    case documentEdge(PromptDirection)

    /// The `SLOPDESK_PROMPT_MOTION_*` index the door reads.
    var index: UInt8 {
        switch self {
        case .grapheme(.backward): UInt8(SLOPDESK_PROMPT_MOTION_GRAPHEME_BACKWARD)
        case .grapheme(.forward): UInt8(SLOPDESK_PROMPT_MOTION_GRAPHEME_FORWARD)
        case .word(.backward): UInt8(SLOPDESK_PROMPT_MOTION_WORD_BACKWARD)
        case .word(.forward): UInt8(SLOPDESK_PROMPT_MOTION_WORD_FORWARD)
        case .lineEdge(.backward): UInt8(SLOPDESK_PROMPT_MOTION_LINE_START)
        case .lineEdge(.forward): UInt8(SLOPDESK_PROMPT_MOTION_LINE_END)
        case .line(.backward): UInt8(SLOPDESK_PROMPT_MOTION_LINE_UP)
        case .line(.forward): UInt8(SLOPDESK_PROMPT_MOTION_LINE_DOWN)
        case .documentEdge(.backward): UInt8(SLOPDESK_PROMPT_MOTION_DOC_START)
        case .documentEdge(.forward): UInt8(SLOPDESK_PROMPT_MOTION_DOC_END)
        }
    }
}

/// What the renderer should colour a run of bytes as.
///
/// About ROLE rather than syntax class: `main.rs` and `--verbose` are both bare words to the shell,
/// and a terminal that paints them differently is the whole point of a rich prompt.
public enum PromptToken: Sendable, Equatable {
    /// The first word of a command.
    case commandName
    /// A bare word in argument position.
    case argument
    /// An argument beginning with `-`.
    case flag
    /// An argument that looks like a path, and every redirection target.
    case path
    /// A quoted run, its quotes included.
    case quoted
    /// `$NAME`, `${…}`, or a special parameter.
    case variable
    /// A control operator.
    case `operator`
    /// A redirection.
    case redirection
    /// `#` to end of line.
    case comment

    /// The case one `SLOPDESK_PROMPT_TOKEN_*` value names. Unknown reads as ``argument``, which is
    /// the neutral colour — a header from a newer build paints plainly rather than crashing.
    static func of(_ raw: UInt32) -> Self {
        switch raw {
        case UInt32(SLOPDESK_PROMPT_TOKEN_COMMAND_NAME): .commandName
        case UInt32(SLOPDESK_PROMPT_TOKEN_FLAG): .flag
        case UInt32(SLOPDESK_PROMPT_TOKEN_PATH): .path
        case UInt32(SLOPDESK_PROMPT_TOKEN_QUOTED): .quoted
        case UInt32(SLOPDESK_PROMPT_TOKEN_VARIABLE): .variable
        case UInt32(SLOPDESK_PROMPT_TOKEN_OPERATOR): .operator
        case UInt32(SLOPDESK_PROMPT_TOKEN_REDIRECTION): .redirection
        case UInt32(SLOPDESK_PROMPT_TOKEN_COMMENT): .comment
        default: .argument
        }
    }
}

/// The one construct the document left open, innermost first.
///
/// Innermost because that is what the user is typing INTO: inside `$(echo '` the thing that needs
/// closing is the quote, and naming the `$(` would name the wrong key.
public enum PromptOpen: Sendable, Equatable {
    /// Everything is closed — Enter runs it.
    case nothing
    /// A `'` with no partner.
    case singleQuote
    /// A `"` with no partner.
    case doubleQuote
    /// The document ends with an unescaped `\`.
    case backslash
    /// A `$(` with no `)`.
    case substitution
    /// An odd number of `` ` ``.
    case backtick
    /// A `${` with no `}`.
    case variable
    /// A `(` with no `)`, outside a substitution.
    case group

    /// The case one `SLOPDESK_PROMPT_OPEN_*` value names.
    static func of(_ raw: UInt32) -> Self {
        switch raw {
        case UInt32(SLOPDESK_PROMPT_OPEN_SINGLE_QUOTE): .singleQuote
        case UInt32(SLOPDESK_PROMPT_OPEN_DOUBLE_QUOTE): .doubleQuote
        case UInt32(SLOPDESK_PROMPT_OPEN_BACKSLASH): .backslash
        case UInt32(SLOPDESK_PROMPT_OPEN_SUBSTITUTION): .substitution
        case UInt32(SLOPDESK_PROMPT_OPEN_BACKTICK): .backtick
        case UInt32(SLOPDESK_PROMPT_OPEN_VARIABLE): .variable
        case UInt32(SLOPDESK_PROMPT_OPEN_GROUP): .group
        default: .nothing
        }
    }
}

/// What a completion candidate is.
public enum PromptCandidateKind: Sendable, Equatable {
    /// A subcommand of the command already typed.
    case subcommand
    /// A flag of that command.
    case flag
    /// A directory.
    case directory
    /// A file.
    case path
    /// An environment variable name.
    case variable
    /// A whole command line from the history.
    case history

    /// The case one `SLOPDESK_PROMPT_CANDIDATE_*` value names.
    static func of(_ raw: UInt32) -> Self {
        switch raw {
        case UInt32(SLOPDESK_PROMPT_CANDIDATE_SUBCOMMAND): .subcommand
        case UInt32(SLOPDESK_PROMPT_CANDIDATE_FLAG): .flag
        case UInt32(SLOPDESK_PROMPT_CANDIDATE_DIRECTORY): .directory
        case UInt32(SLOPDESK_PROMPT_CANDIDATE_VARIABLE): .variable
        case UInt32(SLOPDESK_PROMPT_CANDIDATE_HISTORY): .history
        default: .path
        }
    }
}

/// One coloured run of the document, as a byte range into ``CommandPrompt/text``.
public struct PromptSpan: Sendable, Equatable {
    /// Byte offset of the first byte.
    public let start: Int
    /// Byte offset one past the last.
    public let end: Int
    /// What to paint it as.
    public let kind: PromptToken
}

/// One thing that could go at the caret.
public struct PromptCandidate: Sendable, Equatable {
    /// What the candidate IS — shown in the list, and what ``matched`` indexes into.
    public let text: String
    /// What actually replaces ``replaceStart``..<``replaceEnd``, quoted so a shell reads it back.
    public let insert: String
    /// An optional right-hand column — a flag's summary, a file's size, an exit code.
    public let detail: String?
    /// What it is.
    public let kind: PromptCandidateKind
    /// Byte offset in the document where the replacement starts.
    public let replaceStart: Int
    /// Byte offset in the document one past where it ends.
    public let replaceEnd: Int
    /// Which scalars of ``text`` the query matched, for the underline.
    public let matched: [Int]
}

/// One filesystem name the caller read for the caret's directory.
public struct PromptPathEntry: Sendable, Equatable {
    /// The name, without any directory part.
    public let name: String
    /// Whether it is a directory — which decides both the kind and the trailing slash.
    public let directory: Bool

    public init(name: String, directory: Bool) {
        self.name = name
        self.directory = directory
    }
}

/// What the submit key did.
public enum PromptSubmission: Sendable, Equatable {
    /// The document was closed: it was recorded in the history, the prompt is empty, and this is
    /// what to run.
    case run(String)
    /// Something was still open, so a newline went in instead. The case names what needs closing.
    case continued(PromptOpen)
}

/// One pane's command prompt: the text, its history, its undo stack and everything derived.
///
/// A reference type because it IS a handle — two values holding one Rust editor would be two views
/// of one caret, and the second to write would win silently.
public final class CommandPrompt {
    /// The Rust-owned editor. Non-optional: `new` only fails by allocation failure, which is not a
    /// condition this process survives anyway.
    private let handle: OpaquePointer

    /// The last state read out of the door, refreshed by every call that can change it.
    private var state: SlopDeskPromptState

    public init() {
        guard let created = slopdesk_prompt_new() else {
            preconditionFailure("slopdesk_prompt_new returned null — allocation failed")
        }
        handle = created
        state = slopdesk_prompt_state(created)
    }

    deinit { slopdesk_prompt_free(handle) }

    // MARK: Reading

    /// The document.
    public var text: String {
        ffiAnswerText { slopdesk_prompt_text(handle, $0, $1) }
    }

    /// The caret's byte offset.
    public var cursor: Int { Int(state.cursor) }

    /// The selection as a byte range, or `nil` — an empty selection is not a selection.
    public var selection: Range<Int>? {
        guard state.has_selection else { return nil }
        let anchor = Int(state.selection_anchor)
        let head = Int(state.selection_head)
        return min(anchor, head)..<max(anchor, head)
    }

    /// What the document left open.
    public var unterminated: PromptOpen { PromptOpen.of(state.unterminated) }

    /// Whether the submit key would run the document rather than extend it.
    public var wouldRun: Bool { state.would_run }

    /// Whether ↑/↓ are walking the history rather than moving the caret.
    public var isWalkingHistory: Bool { state.walking_history }

    /// Whether a reverse search is open.
    public var isSearching: Bool { state.searching }

    /// Whether the reverse search has a hit. Always `false` with no search open.
    public var searchHasHit: Bool { state.search_has_hit }

    /// Whether there is an undo step to take.
    public var canUndo: Bool { state.can_undo }

    /// Whether there is a redo step to take.
    public var canRedo: Bool { state.can_redo }

    /// How many entries the history holds.
    public var historyCount: Int { Int(state.history_count) }

    /// Which candidate is highlighted. Meaningless with no candidates.
    public var selectedCandidate: Int { Int(state.selected_candidate) }

    /// The coloured runs: ascending, non-overlapping, adjacent runs of one kind already merged, so
    /// the view draws one attribute run per element.
    public var spans: [PromptSpan] {
        let records = ffiAnswerRecords(SlopDeskPromptSpan.self) { slopdesk_prompt_spans(handle, $0, $1) }
        return records.map { PromptSpan(start: Int($0.start), end: Int($0.end), kind: PromptToken.of($0.kind)) }
    }

    /// The reverse-search query. Empty when no search is open.
    public var searchQuery: String {
        ffiAnswerText { slopdesk_prompt_search_query(handle, $0, $1) }
    }

    /// The history, oldest first — what a session save writes out.
    public var history: [String] {
        (0..<historyCount).map { index in
            ffiAnswerText { slopdesk_prompt_history_entry(handle, index, $0, $1) }
        }
    }

    /// The ranked candidates the last ``complete(limit:)`` produced.
    ///
    /// Three deliveries — the records, the text arena their spans index, and the concatenated match
    /// positions — rather than a call per candidate, so a full list crosses in constant call count.
    public var candidates: [PromptCandidate] {
        let records = ffiAnswerRecords(SlopDeskPromptCandidate.self) { slopdesk_prompt_candidates(handle, $0, $1) }
        guard !records.isEmpty else { return [] }
        let arena = Data(ffiAnswerBytes { slopdesk_prompt_candidate_arena(handle, $0, $1) })
        let positions = ffiAnswerRecords(UInt32.self) { slopdesk_prompt_candidate_positions(handle, $0, $1) }
        return records.map { record in
            PromptCandidate(
                text: Self.slice(arena, record.text),
                insert: Self.slice(arena, record.insert),
                detail: record.has_detail ? Self.slice(arena, record.detail) : nil,
                kind: PromptCandidateKind.of(record.kind),
                replaceStart: Int(record.replace_start),
                replaceEnd: Int(record.replace_end),
                matched: Self.window(positions, record.positions).map(Int.init),
            )
        }
    }

    // MARK: Editing

    /// Inserts text at the caret, replacing any selection.
    public func insert(_ text: String) {
        lend(text) { slopdesk_prompt_insert(handle, $0, $1) }
        refresh()
    }

    /// Inserts a newline — the continuation key, distinct from ``submit()``.
    public func insertNewline() {
        slopdesk_prompt_insert_newline(handle)
        refresh()
    }

    /// Pastes text, which coalesces into the undo stack as ONE step however long it is.
    ///
    /// Distinct from ``insert(_:)`` because that is the difference the undo stack keys on: a view
    /// that used insert for both would make ⌘Z walk a pasted paragraph one character at a time.
    public func paste(_ text: String) {
        lend(text) { slopdesk_prompt_paste(handle, $0, $1) }
        refresh()
    }

    /// Deletes the selection, or one granularity when there is none.
    public func delete(_ motion: PromptMotion) {
        slopdesk_prompt_delete(handle, motion.index)
        refresh()
    }

    /// Replaces a byte range with text.
    public func replace(_ range: Range<Int>, with text: String) {
        lend(text) { slopdesk_prompt_replace_range(handle, range.lowerBound, range.upperBound, $0, $1) }
        refresh()
    }

    /// Empties the document, keeping the history.
    public func clear() {
        slopdesk_prompt_clear(handle)
        refresh()
    }

    // MARK: Moving

    /// Moves the caret, collapsing any selection.
    public func move(_ motion: PromptMotion) {
        slopdesk_prompt_move(handle, motion.index)
        refresh()
    }

    /// Moves the selection's head, leaving the anchor — the shift-arrow half.
    public func extend(_ motion: PromptMotion) {
        slopdesk_prompt_extend(handle, motion.index)
        refresh()
    }

    /// Puts the caret at a byte offset, collapsing any selection — the click.
    public func setCursor(_ offset: Int) {
        slopdesk_prompt_set_cursor(handle, offset)
        refresh()
    }

    /// Sets both selection ends at once — the drag, and the only way to say which end is the head.
    public func setSelection(anchor: Int, head: Int) {
        slopdesk_prompt_set_selection(handle, anchor, head)
        refresh()
    }

    /// Selects the whole document.
    public func selectAll() {
        slopdesk_prompt_select_all(handle)
        refresh()
    }

    // MARK: Clipboard

    /// The selected text, or `nil` with no selection.
    public func copy() -> String? {
        let length = slopdesk_prompt_copy(handle)
        guard length > 0 else { return nil }
        return ffiAnswerText { slopdesk_prompt_take_clipboard(handle, $0, $1) }
    }

    /// Deletes the selection and answers it, or `nil` with no selection.
    public func cut() -> String? {
        let length = slopdesk_prompt_cut(handle)
        refresh()
        guard length > 0 else { return nil }
        return ffiAnswerText { slopdesk_prompt_take_clipboard(handle, $0, $1) }
    }

    // MARK: Undo

    /// Takes one undo step. `false` when there was none.
    @discardableResult
    public func undo() -> Bool {
        let moved = slopdesk_prompt_undo(handle)
        refresh()
        return moved
    }

    /// Takes one redo step. `false` when there was none.
    @discardableResult
    public func redo() -> Bool {
        let moved = slopdesk_prompt_redo(handle)
        refresh()
        return moved
    }

    // MARK: History

    /// Walks one entry back, keeping what was typed as the prefix. `false` at the end.
    @discardableResult
    public func historyPrevious() -> Bool {
        let moved = slopdesk_prompt_history_previous(handle)
        refresh()
        return moved
    }

    /// Walks one entry forward, back toward the draft. `false` when not walking.
    @discardableResult
    public func historyNext() -> Bool {
        let moved = slopdesk_prompt_history_next(handle)
        refresh()
        return moved
    }

    /// Appends one command to the history — how a restore from disk replays what was saved.
    public func recordHistory(_ command: String) {
        lend(command) { slopdesk_prompt_history_record(handle, $0, $1) }
        refresh()
    }

    // MARK: Reverse search

    /// Opens a reverse search over the history.
    public func beginSearch() {
        slopdesk_prompt_search_begin(handle)
        refresh()
    }

    /// Appends to the query and re-runs it.
    public func searchType(_ text: String) {
        lend(text) { slopdesk_prompt_search_type(handle, $0, $1) }
        refresh()
    }

    /// Drops the query's last grapheme and re-runs it.
    public func searchBackspace() {
        slopdesk_prompt_search_backspace(handle)
        refresh()
    }

    /// Steps to the next older hit. `false` when there is none.
    @discardableResult
    public func searchAgain() -> Bool {
        let moved = slopdesk_prompt_search_again(handle)
        refresh()
        return moved
    }

    /// Takes the hit into the document and closes the search. `false` with no hit.
    @discardableResult
    public func acceptSearch() -> Bool {
        let taken = slopdesk_prompt_search_accept(handle)
        refresh()
        return taken
    }

    /// Closes the search, leaving the document as it was.
    public func cancelSearch() {
        slopdesk_prompt_search_cancel(handle)
        refresh()
    }

    // MARK: Completion

    /// Replaces the filesystem source: the directory prefix, and the names read from it.
    ///
    /// The two go together because a base without its entries would rank the previous directory's
    /// names under the new prefix — a list naming files that are not there.
    public func setPaths(base: String, entries: [PromptPathEntry]) {
        var arena = Data()
        var spans = [SlopDeskByteSpan]()
        var directories = [Bool]()
        spans.reserveCapacity(entries.count)
        directories.reserveCapacity(entries.count)
        for entry in entries {
            spans.append(Self.intern(entry.name, into: &arena))
            directories.append(entry.directory)
        }
        let baseBytes = Array(base.utf8)
        baseBytes.withUnsafeBufferPointer { basePointer in
            spans.withUnsafeBufferPointer { spanPointer in
                directories.withUnsafeBufferPointer { flagPointer in
                    arena.withUnsafeBytes { (arenaPointer: UnsafeRawBufferPointer) in
                        slopdesk_prompt_set_paths(
                            handle,
                            basePointer.baseAddress,
                            basePointer.count,
                            spanPointer.baseAddress,
                            flagPointer.baseAddress,
                            spanPointer.count,
                            arenaPointer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            arenaPointer.count,
                        )
                    }
                }
            }
        }
    }

    /// Replaces the environment-variable source.
    public func setVariables(_ names: [String]) {
        var arena = Data()
        let spans = names.map { Self.intern($0, into: &arena) }
        spans.withUnsafeBufferPointer { spanPointer in
            arena.withUnsafeBytes { (arenaPointer: UnsafeRawBufferPointer) in
                slopdesk_prompt_set_variables(
                    handle,
                    spanPointer.baseAddress,
                    spanPointer.count,
                    arenaPointer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    arenaPointer.count,
                )
            }
        }
    }

    /// Empties the command/subcommand/flag table.
    public func clearCommands() { addCommand(name: "", subcommands: [], flags: []) }

    /// Appends one command to that table. Built once at launch, not per keystroke.
    public func addCommand(name: String, subcommands: [String], flags: [String]) {
        var arena = Data()
        let subSpans = subcommands.map { Self.intern($0, into: &arena) }
        let flagSpans = flags.map { Self.intern($0, into: &arena) }
        let nameBytes = Array(name.utf8)
        nameBytes.withUnsafeBufferPointer { namePointer in
            subSpans.withUnsafeBufferPointer { subPointer in
                flagSpans.withUnsafeBufferPointer { flagPointer in
                    arena.withUnsafeBytes { (arenaPointer: UnsafeRawBufferPointer) in
                        slopdesk_prompt_add_command(
                            handle,
                            namePointer.baseAddress,
                            namePointer.count,
                            subPointer.baseAddress,
                            subPointer.count,
                            flagPointer.baseAddress,
                            flagPointer.count,
                            arenaPointer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            arenaPointer.count,
                        )
                    }
                }
            }
        }
    }

    /// Ranks every seeded source plus the history at the caret. Answers how many survived.
    @discardableResult
    public func complete(limit: Int = 32) -> Int {
        let count = slopdesk_prompt_complete(handle, limit)
        refresh()
        return count
    }

    /// Highlights the next candidate, wrapping.
    public func selectNextCandidate() {
        slopdesk_prompt_select_next_candidate(handle)
        refresh()
    }

    /// Highlights the previous candidate, wrapping.
    public func selectPreviousCandidate() {
        slopdesk_prompt_select_previous_candidate(handle)
        refresh()
    }

    /// Applies the highlighted candidate. `false` with no candidates.
    @discardableResult
    public func acceptCompletion() -> Bool {
        let applied = slopdesk_prompt_accept_completion(handle)
        refresh()
        return applied
    }

    /// Drops the candidate list.
    public func dismissCompletion() {
        slopdesk_prompt_dismiss_completion(handle)
        refresh()
    }

    // MARK: Submit

    /// The submit key.
    public func submit() -> PromptSubmission {
        let verdict = slopdesk_prompt_submit(handle)
        refresh()
        guard verdict == UInt8(SLOPDESK_PROMPT_SUBMISSION_RUN) else {
            return .continued(unterminated)
        }
        return .run(ffiAnswerText { slopdesk_prompt_take_submitted(handle, $0, $1) })
    }

    // MARK: Boundary plumbing

    /// Re-reads the one state record every property above is a field of.
    private func refresh() { state = slopdesk_prompt_state(handle) }

    /// Lends a string to a door as `(bytes, len)` for exactly the call.
    private func lend(_ text: String, _ body: (UnsafePointer<UInt8>?, Int) -> Void) {
        ffiLend(text) { body($0.baseAddress, $0.count) }
    }

    /// Appends one string to an arena being built for a door, answering the span that names it.
    ///
    /// `SlopDeskArena` owns both halves of `docs/55` §4c; this only reshapes the pair into the
    /// record the prompt's doors take.
    private static func intern(_ text: String, into arena: inout Data) -> SlopDeskByteSpan {
        let span = ArenaText.intern(bytes: Array(text.utf8), into: &arena)
        return SlopDeskByteSpan(offset: span.offset, length: span.length)
    }

    /// The string one arena span names — `ArenaText`'s read, which repairs rather than drops and
    /// answers `""` for a pair naming bytes that are not there.
    private static func slice(_ arena: Data, _ span: SlopDeskByteSpan) -> String {
        ArenaText.text(arena, offset: Int(span.offset), length: Int(span.length))
    }

    /// The run of a flat array one span names, empty when the span does not fit.
    private static func window<Element>(_ all: [Element], _ span: SlopDeskByteSpan) -> ArraySlice<Element> {
        let start = Int(span.offset)
        let end = start + Int(span.length)
        guard start <= end, end <= all.count else { return [] }
        return all[start..<end]
    }
}
