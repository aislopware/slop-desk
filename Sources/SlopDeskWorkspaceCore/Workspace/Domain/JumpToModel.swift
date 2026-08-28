import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

// MARK: - The Jump-To panel's rows (⌘J)

/// The classification of one ``JumpToItem`` — drives the row's type badge + icon (`jump-to.png`:
/// File / Folder / URL / Cmd / Prompt).
///
/// The five cases are a SUBSET of the picker's own kinds, and the badge and the glyph each one wears
/// are `slopdesk_workspace::open_quickly::Kind`'s and pinned there: a Jump-To row and the
/// Open-Quickly row it becomes under Current are the same row, so a second table here would be the
/// one place they could badge differently.
///
/// The pure detector cannot `stat` a path to know file-vs-folder (no host round-trip), so every
/// path-like ``DetectedLinkKind`` collapses to ``path``; the `file://` URL form keeps its own
/// ``fileURL`` badge and a plain URL keeps ``url``. That collapse is
/// `slopdesk_workspace::jump_to::kind_of`'s, reached through ``JumpToModel/items(links:blocks:)``.
public enum JumpToItemKind: Equatable, Hashable, Sendable, CaseIterable {
    /// A filesystem path detected in the scrollback (abs / `~` / relative / `path:line:col`).
    case path
    /// A `scheme://…` URL or a `mailto:` address.
    case url
    /// A `file://…` URL (its filesystem path lives in the underlying ``DetectedLink/resolvedAbsolute``).
    case fileURL
    /// A user-run shell command (an OSC-133 block).
    case command
    /// An agent history prompt (an OSC-133 block flagged as a prompt). See ``BlockSummary/isPrompt``.
    case prompt

    /// The short type badge string the row renders flush-right (`jump-to.png`).
    public var badge: String { OpenQuicklyKind(jumpTo: self).badge }

    /// The SF Symbol name for the row's leading icon. Passed to `Image(systemName:)` (the string API — no
    /// deprecation), so a plain name is fine.
    public var symbol: String { OpenQuicklyKind(jumpTo: self).symbol }
}

/// A pure, headless summary of one OSC-133 block the Jump-To panel consumes — the view builds these from
/// the per-pane ``TerminalBlockModel`` (`navigatorBlocks` + `firstSeen(index:)`). A SEPARATE value type
/// (not ``CommandBlock`` directly) so the pure model + its tests stay free of the block-store's
/// `@Observable` / client coupling, and so a future agent-prompt source can feed ``isPrompt`` rows the
/// command-mark stream does not carry today (see ``isPrompt``).
public struct BlockSummary: Equatable, Hashable, Sendable {
    /// The block's stable 0-based index — the scrollback-jump target (`jumpToNavigatorBlockInActivePane`).
    public var index: UInt32
    /// The typed command line (or agent prompt text). An empty string is skipped by ``JumpToModel/items``.
    public var commandText: String
    /// Whether this is an agent HISTORY PROMPT rather than a shell command (`outline.md`: a supported code
    /// agent session also lists prompts). SlopDesk carries no prompt-mark on the wire today (see
    /// DECISIONS.md — `no prompt row is invented`), so production feeds only `false` rows; the model supports
    /// both kinds for when an agent-prompt source lands.
    public var isPrompt: Bool
    /// The CLIENT-RECEIVE first-seen time (the relative-timestamp source, per the outline mapping — the
    /// host clock is not on the wire), or `nil` if unknown / evicted.
    public var firstSeen: Date?

    public init(index: UInt32, commandText: String, isPrompt: Bool = false, firstSeen: Date? = nil) {
        self.index = index
        self.commandText = commandText
        self.isPrompt = isPrompt
        self.firstSeen = firstSeen
    }
}

/// One row in the Jump-To panel: a detected link (path / URL) or an indexed command / prompt, with the
/// display text, type badge + icon, an optional relative-timestamp source, and the ACTION that firing the
/// row performs. A pure value (no view framework, no store) so assembly + filtering are headlessly
/// unit-tested.
public struct JumpToItem: Identifiable, Equatable, Hashable, Sendable {
    /// What firing the row does — resolved by the view against the pure ``LinkActionPolicy`` (a link) or the
    /// store's scrollback jump (a block). Carrying the source value keeps the view's actuator a thin switch.
    public enum Act: Equatable, Hashable, Sendable {
        /// Act on a detected link (⌘click-equivalent open by default; ⌘K offers the full link item set).
        case link(DetectedLink)
        /// Jump the active pane's scrollback to this block index.
        case block(index: UInt32)
    }

    /// A stable, unique id — the row-identity key the panel addresses a row by, and the fuzzy-dedup key.
    /// `link:<kind>:<raw>` / `block:<index>`.
    public let id: String
    public let kind: JumpToItemKind
    /// The primary display text — the path / URL `raw`, or the command / prompt text.
    public let title: String
    /// The CLIENT-RECEIVE time the relative stamp renders from (commands/prompts), or `nil` (links).
    public let timestamp: Date?
    public let act: Act

    /// The fuzzy-match haystack the view ranks against (the visible ``title``).
    public var searchText: String { title }
    /// The type badge label (delegates to ``kind``).
    public var badge: String { kind.badge }
    /// The leading icon symbol (delegates to ``kind``).
    public var symbol: String { kind.symbol }

    public init(id: String, kind: JumpToItemKind, title: String, timestamp: Date?, act: Act) {
        self.id = id
        self.kind = kind
        self.title = title
        self.timestamp = timestamp
        self.act = act
    }
}

/// The builder + filter for the Jump-To panel: assemble the focused pane's detected links
/// (paths/URLs) + its OSC-133 command/prompt index into ``JumpToItem`` rows, then fuzzy-filter them.
///
/// ## Where the decisions live
/// WHICH detections and WHICH blocks earn a row is `slopdesk_workspace::jump_to` — the collapse of
/// four path forms into one badge, the dedup of a path a build log printed forty times, the ceiling
/// on a pathological scrollback, the skip of a block still being captured. The ranking is
/// `slopdesk_workspace::search_rank`, the one every search field in the app asks for. What is left
/// here is the row VALUES themselves, which never cross: the door answers indices into the arrays
/// this side already holds, so no scrollback string makes a second trip through the boundary to be
/// handed back unchanged.
public enum JumpToModel {
    /// The cap on how many distinct LINK rows are assembled — a long scrollback can detect thousands of
    /// repeated paths, so the deduped link set is bounded (validate-then-bound, the CLAUDE.md §3 habit
    /// applied to attacker-influenced terminal output). Commands are already bounded by `maxBlocks`.
    public static let maxLinkItems = Int(SLOPDESK_WS_JUMP_TO_MAX_LINK_ITEMS)

    /// Assemble the panel rows: the detected LINKS that earned one first, in detection order, then the
    /// BLOCKS in the order given (the caller passes `navigatorBlocks`, newest-first). Links carry no
    /// timestamp (no jump target / receive-time); blocks carry their `firstSeen` for the relative stamp.
    ///
    /// - Parameters:
    ///   - links: the detected path/URL spans over the pane's scrollback (``TerminalLinkDetector/detect``).
    ///   - blocks: the pane's OSC-133 command/prompt summaries (caller-ordered; `navigatorBlocks` = newest-first).
    public static func items(links: [DetectedLink], blocks: [BlockSummary]) -> [JumpToItem] {
        let (kept, captured) = rows(links: links, blocks: blocks)
        var out: [JumpToItem] = []
        out.reserveCapacity(kept.count + captured.count)

        for (index, kind) in kept where index < links.count {
            let link = links[index]
            out.append(JumpToItem(
                id: "link:\(kind):\(link.raw)",
                kind: kind,
                title: link.raw,
                timestamp: nil,
                act: .link(link),
            ))
        }

        for index in captured where index < blocks.count {
            let block = blocks[index]
            out.append(JumpToItem(
                id: "block:\(block.index)",
                kind: block.isPrompt ? .prompt : .command,
                title: block.commandText,
                timestamp: block.firstSeen,
                act: .block(index: block.index),
            ))
        }
        return out
    }

    /// Fuzzy-filter + rank `items` by `query`. An EMPTY query returns `items` unchanged (the
    /// zero-state list). A non-empty query drops every item the matcher rejects and orders the
    /// survivors best-first, with the assembly order — links before commands — breaking ties.
    public static func filtered(_ items: [JumpToItem], query: String) -> [JumpToItem] {
        wsSearchRanked(items, query: query) { $0.searchText }
    }

    // MARK: - The crossing

    /// Which detections earned a row and what each is called, then which blocks did — both as indices
    /// into the caller's own arrays. One crossing, whatever the scrollback held.
    private static func rows(
        links: [DetectedLink],
        blocks: [BlockSummary],
    ) -> (links: [(index: Int, kind: JumpToItemKind)], blocks: [Int]) {
        var arena = WsStrings()
        let linkSpans = links.map { arena.span($0.raw) }
        let blockSpans = blocks.map { arena.span($0.commandText) }
        let kinds = links.map { TerminalLinkDetector.code(of: $0.kind) }
        var bytes = arena.bytes

        let answer = bytes.withUnsafeMutableBufferPointer { lent in
            kinds.withUnsafeBufferPointer { codes in
                linkSpans.withUnsafeBufferPointer { detected in
                    blockSpans.withUnsafeBufferPointer { captured in
                        wsAnswerBytes { out, cap in
                            Int(slopdesk_ws_jump_to_rows(
                                codes.baseAddress, codes.count,
                                lent.baseAddress, lent.count,
                                detected.baseAddress, detected.count,
                                captured.baseAddress, captured.count,
                                out, cap,
                            ))
                        }
                    }
                }
            }
        }

        // Every field is one big-endian word, so the answer reads as a flat word array: the count,
        // then that many index/kind PAIRS, then the block indices.
        var words: [Int] = []
        words.reserveCapacity(answer.count / 4)
        var cursor = 0
        while cursor + 4 <= answer.count {
            words.append((0..<4).reduce(0) { $0 << 8 | Int(answer[cursor + $1]) })
            cursor += 4
        }
        guard let count = words.first, count * 2 <= words.count - 1 else { return ([], []) }

        let kept = stride(from: 1, to: 1 + count * 2, by: 2).map { slot in
            (index: words[slot], kind: kindOf(code: words[slot + 1]))
        }
        return (kept, Array(words.dropFirst(1 + count * 2)))
    }

    /// The Jump-To kind an Open-Quickly kind code names. A code no kind answers to reads as ``path``,
    /// which is the same floor `OpenQuicklyKind.jumpToKind` already lands on.
    private static func kindOf(code: Int) -> JumpToItemKind {
        kindByCode[code] ?? .path
    }

    /// Every picker kind's Jump-To reading, resolved once per process rather than once per row.
    private static let kindByCode: [Int: JumpToItemKind] = Dictionary(
        uniqueKeysWithValues: OpenQuicklyKind.allCases.map { ($0.code, $0.jumpToKind) },
    )
}
