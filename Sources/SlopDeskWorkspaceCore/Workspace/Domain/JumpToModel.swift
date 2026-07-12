import Foundation

// MARK: - The pure Jump-To panel model (⌘J)

/// The classification of one ``JumpToItem`` — drives the row's type badge + icon (`jump-to.png`:
/// File / Folder / URL / Cmd / Prompt). The pure detector cannot `stat` a path to know file-vs-folder
/// (no host round-trip), so every path-like ``DetectedLinkKind`` collapses to ``path`` here; the
/// `file://` URL form keeps its own ``fileURL`` badge and a plain URL keeps ``url``.
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
    public var badge: String {
        switch self {
        case .path: "Path"
        case .url: "URL"
        case .fileURL: "File"
        case .command: "Cmd"
        case .prompt: "Prompt"
        }
    }

    /// The SF Symbol name for the row's leading icon. Passed to `Image(systemName:)` (the string API — no
    /// deprecation), so a plain name is fine. `terminal` is the prompt-box `>_` glyph for a command row.
    public var symbol: String {
        switch self {
        case .path: "doc.text"
        case .url: "link"
        case .fileURL: "doc"
        case .command: "terminal"
        case .prompt: "text.bubble"
        }
    }
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
/// row performs. A pure value (no SwiftUI / store) so assembly + filtering are headlessly unit-tested.
public struct JumpToItem: Identifiable, Equatable, Hashable, Sendable {
    /// What firing the row does — resolved by the view against the pure ``LinkActionPolicy`` (a link) or the
    /// store's scrollback jump (a block). Carrying the source value keeps the view's actuator a thin switch.
    public enum Act: Equatable, Hashable, Sendable {
        /// Act on a detected link (⌘click-equivalent open by default; ⌘K offers the full link item set).
        case link(DetectedLink)
        /// Jump the active pane's scrollback to this block index.
        case block(index: UInt32)
    }

    /// A stable, unique id (the `ForEach` key + the fuzzy-dedup key). `link:<kind>:<raw>` / `block:<index>`.
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

/// The PURE builder + filter for the Jump-To panel: assemble the focused pane's detected links
/// (paths/URLs) + its OSC-133 command/prompt index into ``JumpToItem`` rows, then fuzzy-filter them.
///
/// ## Why a pure enum
/// Assembly is a deterministic map over the already-pure ``DetectedLink`` (from ``TerminalLinkDetector``)
/// and the per-pane block index — no host round-trip, no SwiftUI. The view feeds it `viewportTextRows()` /
/// scrollback + `navigatorBlocks`, ranks via the vendored ``FuzzyMatcher`` (which lives in the view module,
/// so it is INJECTED into ``filtered(_:query:score:)`` rather than imported here), and renders the rows.
public enum JumpToModel {
    /// The cap on how many distinct LINK rows are assembled — a long scrollback can detect thousands of
    /// repeated paths, so the deduped link set is bounded (validate-then-bound, the CLAUDE.md §3 habit
    /// applied to attacker-influenced terminal output). Commands are already bounded by `maxBlocks`.
    public static let maxLinkItems = 200

    /// Assemble the panel rows: deduped detected LINKS first (in detection order), then the BLOCKS in the
    /// order given (the caller passes `navigatorBlocks`, newest-first). A block with empty `commandText` is
    /// skipped (a still-forming block). Links carry no timestamp (no jump target / receive-time); blocks
    /// carry their `firstSeen` for the relative stamp.
    ///
    /// - Parameters:
    ///   - links: the detected path/URL spans over the pane's scrollback (``TerminalLinkDetector/detect``).
    ///   - blocks: the pane's OSC-133 command/prompt summaries (caller-ordered; `navigatorBlocks` = newest-first).
    public static func items(links: [DetectedLink], blocks: [BlockSummary]) -> [JumpToItem] {
        var out: [JumpToItem] = []
        var seenLinkIDs = Set<String>()

        for link in links {
            let kind = itemKind(for: link.kind)
            let id = "link:\(kind):\(link.raw)"
            // Dedup: the same path/URL printed many times in the scrollback is ONE row.
            guard seenLinkIDs.insert(id).inserted else { continue }
            out.append(JumpToItem(id: id, kind: kind, title: link.raw, timestamp: nil, act: .link(link)))
            if out.count >= maxLinkItems { break }
        }

        for block in blocks where !block.commandText.isEmpty {
            let kind: JumpToItemKind = block.isPrompt ? .prompt : .command
            out.append(JumpToItem(
                id: "block:\(block.index)",
                kind: kind,
                title: block.commandText,
                timestamp: block.firstSeen,
                act: .block(index: block.index),
            ))
        }
        return out
    }

    /// Map a detected-span kind onto a Jump-To badge kind. Every path-like form collapses to ``path`` —
    /// the pure detector cannot `stat` to tell file-from-folder (no host round-trip), so a single honest
    /// "Path" badge is used rather than a guessed File/Folder split.
    static func itemKind(for kind: DetectedLinkKind) -> JumpToItemKind {
        switch kind {
        case .absolutePath,
             .tildePath,
             .relativePath,
             .pathLineCol: .path
        case .url: .url
        case .fileURL: .fileURL
        }
    }

    /// Fuzzy-filter + rank `items` by `query` using the INJECTED `score` closure (the view passes
    /// `FuzzyMatcher.score(_:_:)?.score`; the headless tests pass a deterministic scorer). An EMPTY query
    /// returns `items` unchanged (the zero-state list). A non-empty query drops every item the scorer
    /// rejects (`nil`) and orders the survivors by score DESCENDING, breaking ties by original order
    /// (a STABLE sort, so equal-score rows keep the assembly order — links before commands).
    ///
    /// Integer scores only (no float), so the `>` / `<` comparisons are ordered + total — no NaN hazard.
    public static func filtered(
        _ items: [JumpToItem],
        query: String,
        score: (_ query: String, _ haystack: String) -> Int?,
    ) -> [JumpToItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let scored: [(score: Int, order: Int, item: JumpToItem)] = items.enumerated().compactMap { offset, item in
            guard let s = score(trimmed, item.searchText) else { return nil }
            return (s, offset, item)
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }.map(\.item)
    }
}
