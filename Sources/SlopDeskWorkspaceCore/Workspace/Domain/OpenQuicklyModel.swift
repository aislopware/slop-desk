import Foundation
import SlopDeskProtocol

// MARK: - E11 WI-3 (ES-E11-1..4): the pure Open-Quickly (`⌘⇧O`) switcher model

/// The Open-Quickly filter pills — the `⌘⇧O` taxonomy (distinct from the `⌘⇧P` command-palette
/// `QueryFilter`). One floating picker fuzzy-searches these sources; `.all` merges the rest into a single
/// ranked list with ALL-CAPS section headers.
///
/// ### Pill set
/// The ring is **All / Opened / Recent / Folders / Agents / Current**. Two pills were dropped by product
/// decision — the cuts are structural (no `ssh` / `recipes` case exists on this enum, so nothing can route
/// to a missing source):
/// - **SSH** cut: no `~/.ssh/config` parse, no `⌘S` chord, no SSH Actions row.
/// - **Recipes** removed with the recipe feature (2026-07-03).
public enum OpenQuicklyFilter: String, CaseIterable, Equatable, Hashable, Sendable {
    /// The merged, section-headered list of every source — the `⌘⇧O` default.
    case all
    /// Every currently-open pane (the vertical-rail "Opened" — `⌘W`).
    case opened
    /// Recently-closed tabs from this/the previous session (`⌘R`).
    case recent
    /// Frequently-visited folders, frecency-ranked (`⌘Z`).
    case folders
    /// Claude Code agent sessions for the current project (`⌘G`). Claude-only (carry-over).
    case agents
    /// The HOST machine's windows from the live feed (docs/45) — streamed ones focus their pane,
    /// the rest open a new `.remoteGUI` pane (`⌘H`).
    case hostWindows
    /// The focused pane's detected links + command/prompt index (`⌘J` / Jump-To).
    case current

    // SSH pill: dropped by product decision (no ~/.ssh/config parse).
    /// The pill order rendered in the filter bar (Tab/⇧Tab cycle this ring). `⌘⇧O` opens to ``defaultFilter``.
    public static let pickerPills: [Self] = [.all, .opened, .recent, .folders, .agents, .hostWindows, .current]

    /// The section order the `.all` list merges in (every pill EXCEPT `.all`, in pill order). `.all` itself is
    /// never a section — it is the merged view of these.
    public static let sectionOrder: [Self] = [.opened, .recent, .folders, .agents, .hostWindows, .current]

    /// The pill `⌘⇧O` opens to (the merged All list).
    public static let defaultFilter: OpenQuicklyFilter = .all

    /// The pill's display label (also the source of ``sectionHeader``).
    public var label: String {
        switch self {
        case .all: "All"
        case .opened: "Opened"
        case .recent: "Recent"
        case .folders: "Folders"
        case .agents: "Agents"
        case .hostWindows: "Host"
        case .current: "Current"
        }
    }

    /// The ALL-CAPS group header this source renders under in the merged `.all` list (the uppercased pill name).
    public var sectionHeader: String { label.uppercased() }

    /// The pill's leading SF Symbol name (`Image(systemName:)`).
    public var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .opened: "rectangle.stack"
        case .recent: "clock.arrow.circlepath"
        case .folders: "folder"
        case .agents: "sparkles"
        case .hostWindows: "macwindow"
        case .current: "scope"
        }
    }

    /// The bare character of the picker-LOCAL `⌘`-chord that jumps straight to this pill (`⌘0`/`⌘W`/`⌘R`/
    /// `⌘Z`/`⌘G`/`⌘J`). Handled by the panel's own `onKeyPress`, NEVER registered globally.
    public var pickerChordKey: String {
        switch self {
        case .all: "0"
        case .opened: "w"
        case .recent: "r"
        case .folders: "z"
        case .agents: "g"
        case .hostWindows: "h"
        case .current: "j"
        }
    }

    /// The honest empty-state line the picker shows when this source has no rows.
    public var emptyMessage: String {
        switch self {
        case .all: "No results"
        case .opened: "No open panes"
        case .recent: "No recently closed tabs"
        case .folders: "No folders yet"
        case .agents: "No agent sessions"
        case .hostWindows: "No windows on the host"
        case .current: "Nothing detected in this pane"
        }
    }
}

/// The classification of one ``OpenQuicklyItem`` — drives the row's leading icon + trailing type badge. A
/// superset of the sources: panes (Opened), folders (Folders), agents (Agents), recently-closed tabs (Recent),
/// and the Jump-To-derived command/prompt/path/url/file rows (Current).
public enum OpenQuicklyKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case pane
    case folder
    case agent
    case recentTab
    case command
    case prompt
    case path
    case url
    case fileURL
    /// A HOST machine window from the live feed (docs/45) — not yet necessarily streamed.
    case hostWindow

    /// The trailing type-badge label the row renders flush-right.
    public var badge: String {
        switch self {
        case .pane: "Pane"
        case .folder: "Folder"
        case .agent: "Agent"
        case .recentTab: "Tab"
        case .command: "Cmd"
        case .prompt: "Prompt"
        case .path: "Path"
        case .url: "URL"
        case .fileURL: "File"
        case .hostWindow: "Host"
        }
    }

    /// The leading icon SF Symbol name (`Image(systemName:)`).
    public var symbol: String {
        switch self {
        case .pane: "rectangle.split.2x1"
        case .folder: "folder"
        case .agent: "sparkles"
        case .recentTab: "clock.arrow.circlepath"
        case .command: "terminal"
        case .prompt: "text.bubble"
        case .path: "doc.text"
        case .url: "link"
        case .fileURL: "doc"
        case .hostWindow: "macwindow"
        }
    }

    /// Map a ``JumpToItemKind`` (the Current source) onto its Open-Quickly kind 1:1.
    public init(jumpTo kind: JumpToItemKind) {
        switch kind {
        case .path: self = .path
        case .url: self = .url
        case .fileURL: self = .fileURL
        case .command: self = .command
        case .prompt: self = .prompt
        }
    }
}

/// One row in the Open-Quickly picker: a typed display value (title / subtitle / badge / icon / optional
/// relative-timestamp) plus the ACTION that firing it (`↩` or `⌘1–9`) performs. A pure value (no SwiftUI /
/// store) so the merge/rank/section/select logic is headlessly unit-tested; the view turns ``act`` into a
/// store op / `LinkActionActuator` call via a thin switch.
public struct OpenQuicklyItem: Identifiable, Equatable, Hashable, Sendable {
    /// What firing the row does. Carrying the typed source keeps routing decisions in the model (a thin view
    /// actuator), not scattered across the view.
    public enum Act: Equatable, Hashable, Sendable {
        /// Focus a currently-open pane (Opened `↩`).
        case focusPane(PaneID)
        /// Open / change-directory to a frecent folder (Folders `↩`); the view picks the verbatim-`cd` vs
        /// open routing.
        case openFolder(path: String)
        /// Resume a Claude agent session (Agents `↩`).
        case resumeAgent(sessionID: String, cwd: String)
        /// Reopen a recently-closed tab by its LIFO index (Recent `↩`).
        case reopenRecentTab(index: Int)
        /// Act on a focused-pane detection (Current `↩`) — wraps the underlying ``JumpToItem/Act`` (a link
        /// open or a scrollback jump) so the Current rows actuate through the SAME path as the Jump-To panel.
        case jumpTo(JumpToItem.Act)
        /// Open a NOT-yet-streamed host window into a new `.remoteGUI` pane (Host `↩`, docs/45). A
        /// window already streaming surfaces as `.focusPane` instead — the rail's exact click grammar.
        case openHostWindow(windowID: UInt32, title: String, appName: String)
    }

    /// A stable, unique id (the `ForEach` key). Prefixed by source: `pane:` / `folder:` / `agent:` /
    /// `recent:` / `current:`.
    public let id: String
    public let kind: OpenQuicklyKind
    /// The primary display label (pane title / folder name / agent / command / link).
    public let title: String
    /// The trailing metadata line (cwd / project path), or `nil`.
    public let subtitle: String?
    /// The CLIENT-RECEIVE time the relative stamp renders from, or `nil` (links / panes carry none).
    public let timestamp: Date?
    /// The fuzzy-match haystack the model ranks against — usually ``title``, but a folder row matches on its
    /// full path (held here) while its ``title`` stays the short display name.
    public let searchText: String
    public let act: Act

    /// E21 WI-2: the WORKSPACE pane kind a `.pane` row is backed by. For a `.remoteGUI`/`.systemDialog` VIDEO
    /// pane it differentiates ``symbol``/``badge`` so the row reads as a *window* (window glyph +
    /// "Window"/"Dialog" badge) instead of a generic split "Pane", while ``act`` stays kind-generic
    /// (`.focusPane` — `↩` focuses the pane exactly as a terminal row does). Defaults to `.terminal` (the
    /// non-differentiating value) for every NON-pane source (folders / agents / recent / current), where it is
    /// inert (those rows keep their ``OpenQuicklyKind`` chrome).
    public let paneKind: PaneKind

    /// The trailing type badge. A `.pane` row backed by a VIDEO pane reads as a *window* — "Window" for
    /// `.remoteGUI`, "Dialog" for the auto `.systemDialog` — differentiating it from a generic terminal
    /// "Pane"; every other row delegates to its ``OpenQuicklyKind``. (E21 WI-2.)
    public var badge: String {
        switch paneKind {
        case .remoteGUI: "Window"
        case .systemDialog: "Dialog"
        default: kind.badge
        }
    }

    /// The leading icon symbol. A video pane (`.remoteGUI`/`.systemDialog`) uses the window glyph (`display`);
    /// every other row delegates to its ``OpenQuicklyKind``. (E21 WI-2.)
    public var symbol: String {
        paneKind.isVideo ? "display" : kind.symbol
    }

    public init(
        id: String,
        kind: OpenQuicklyKind,
        title: String,
        subtitle: String?,
        timestamp: Date?,
        searchText: String,
        act: Act,
        paneKind: PaneKind = .terminal,
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
        self.searchText = searchText
        self.act = act
        self.paneKind = paneKind
    }
}

/// One labelled group in the picker: the source ``filter`` it came from and the (already-ranked) ``items``.
/// In `.all` the picker shows one section per non-empty source under its ``header``; in a specific pill it is
/// a single section (possibly empty, so the view can render the empty-state).
public struct OpenQuicklySection: Identifiable, Equatable, Sendable {
    /// Which source this section is.
    public let filter: OpenQuicklyFilter
    /// The ranked rows of this source.
    public let items: [OpenQuicklyItem]

    /// `Identifiable` by the source filter (one section per source).
    public var id: OpenQuicklyFilter { filter }
    /// The ALL-CAPS group header (delegates to the source ``filter``).
    public var header: String { filter.sectionHeader }

    public init(filter: OpenQuicklyFilter, items: [OpenQuicklyItem]) {
        self.filter = filter
        self.items = items
    }
}

/// The PURE merge / rank / section / cycle / quick-pick logic + the source builders for the Open-Quickly
/// picker. No SwiftUI, no store — every source is handed in pre-built (the view assembles them from
/// `WorkspaceStore` / `MetadataClient` / `JumpToModel`), so the ordering + selection contract is headlessly
/// testable.
///
/// ### Reuse
/// - Ranking takes an INJECTED `score` closure (the view passes `FuzzyMatcher.score(_:_:)?.score`; the tests
///   pass a deterministic subsequence scorer) — the same contract as ``JumpToModel/filtered(_:query:score:)``.
///   Scores are `Int` (no float / FMA / NaN hazard — CLAUDE.md §2).
/// - The **Current** source is the existing ``JumpToModel`` output, wrapped 1:1 via ``currentItems(from:)``.
public enum OpenQuicklyModel {
    // MARK: - Sectioning + ranking

    /// Build the picker sections for `filter`, ranking each source against `query` with the injected `score`.
    ///
    /// - `.all`: one section per source in ``OpenQuicklyFilter/sectionOrder``, EMPTY sources omitted (no
    ///   stray header) — the merged-with-headers list.
    /// - a specific pill: exactly ONE section for that source (kept even when empty, so the view renders the
    ///   honest empty-state rather than a blank panel).
    public static func sectioned(
        sources: [OpenQuicklyFilter: [OpenQuicklyItem]],
        filter: OpenQuicklyFilter,
        query: String,
        score: (_ query: String, _ haystack: String) -> Int?,
    ) -> [OpenQuicklySection] {
        if filter == .all {
            return OpenQuicklyFilter.sectionOrder.compactMap { source in
                let ranked = rank(sources[source] ?? [], query: query, score: score)
                guard !ranked.isEmpty else { return nil }
                return OpenQuicklySection(filter: source, items: ranked)
            }
        }
        let ranked = rank(sources[filter] ?? [], query: query, score: score)
        return [OpenQuicklySection(filter: filter, items: ranked)]
    }

    /// Fuzzy-filter + rank `items` by `query`. An EMPTY query returns `items` unchanged (the zero-state). A
    /// non-empty query drops every item the scorer rejects (`nil`) and orders survivors by score DESCENDING,
    /// breaking ties by original order (a STABLE sort). Integer scores only — the `>`/`<` are ordered + total.
    static func rank(
        _ items: [OpenQuicklyItem],
        query: String,
        score: (_ query: String, _ haystack: String) -> Int?,
    ) -> [OpenQuicklyItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let scored: [(score: Int, order: Int, item: OpenQuicklyItem)] = items.enumerated().compactMap { offset, item in
            guard let s = score(trimmed, item.searchText) else { return nil }
            return (s, offset, item)
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }.map(\.item)
    }

    /// The flattened, navigable row list (sections concatenated; headers are NOT rows). The basis for
    /// arrow-key selection + ``quickPickIndex(_:in:)``.
    public static func selectable(_ sections: [OpenQuicklySection]) -> [OpenQuicklyItem] {
        sections.flatMap(\.items)
    }

    /// Map a 1-based `⌘1–9` quick-pick chord onto a 0-based index into the visible `rows`. Returns `nil` for
    /// `⌘0` (the All-pill chord, not a pick), a chord above 9, or an index past the visible rows.
    public static func quickPickIndex(_ oneBased: Int, in rows: [OpenQuicklyItem]) -> Int? {
        guard (1...9).contains(oneBased) else { return nil }
        let index = oneBased - 1
        guard rows.indices.contains(index) else { return nil }
        return index
    }

    /// Move a selection index by `delta`, clamped to `[0, count-1]` — the SHARED contract for the picker's
    /// arrow (`±1`), page (`±pageStep`) and Home/End (`±count`) navigation. An empty list (`count <= 0`)
    /// clamps to `0`. Pure so PageUp/PageDown/Home/End paging is headlessly testable (the view passes
    /// `selectableRows.count` and the page step). The `max`/`min` are ordered integer comparisons (no float).
    public static func clampedSelection(current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(count - 1, current + delta))
    }

    /// Fuzzy-filter + rank a list of titled actions by `query` — the `⌘K` Actions popover search. Generic
    /// over the action type via a `title` projection so the view can reuse the SAME injected `score` contract
    /// (and ordering) the row ranker uses. An EMPTY query returns `actions` unchanged; a non-empty query drops
    /// every action the scorer rejects (`nil`), orders survivors by score DESCENDING, breaking ties by original
    /// order (a STABLE sort). Integer scores only — the `>`/`<` are ordered + total (CLAUDE.md §2).
    public static func rankActions<Action>(
        _ actions: [Action],
        query: String,
        title: (Action) -> String,
        score: (_ query: String, _ haystack: String) -> Int?,
    ) -> [Action] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return actions }
        let scored: [(score: Int, order: Int, action: Action)] = actions.enumerated().compactMap { offset, action in
            guard let s = score(trimmed, title(action)) else { return nil }
            return (s, offset, action)
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }.map(\.action)
    }

    // MARK: - Filter cycling (Tab / ⇧Tab)

    /// The next pill in the ring (Tab), WRAPPING from the last pill back to the first.
    public static func nextFilter(_ current: OpenQuicklyFilter) -> OpenQuicklyFilter {
        cycle(from: current, by: 1)
    }

    /// The previous pill in the ring (⇧Tab), WRAPPING from the first pill back to the last.
    public static func prevFilter(_ current: OpenQuicklyFilter) -> OpenQuicklyFilter {
        cycle(from: current, by: -1)
    }

    private static func cycle(from current: OpenQuicklyFilter, by delta: Int) -> OpenQuicklyFilter {
        let pills = OpenQuicklyFilter.pickerPills
        guard !pills.isEmpty, let index = pills.firstIndex(of: current) else { return current }
        let count = pills.count
        // `((i + delta) % n + n) % n` keeps the index in range for a negative delta (no underflow / trap).
        let wrapped = ((index + delta) % count + count) % count
        return pills[wrapped]
    }

    // MARK: - Source builders (pure)

    /// Build the **Agents** rows from the host's agent-session list, filtered to **Claude only** (carry-over:
    /// Agents = Claude Code). A non-positive `mtimeMS` carries no timestamp; an empty title falls back to the
    /// session id; an empty cwd is no subtitle.
    public static func agentItems(from sessions: [MetadataCodec.AgentSessionInfo]) -> [OpenQuicklyItem] {
        sessions.compactMap { session in
            guard session.agentKind == .claude else { return nil }
            let title = session.title.isEmpty ? session.id : session.title
            // Whole-millisecond epoch → seconds; a non-positive sentinel (e.g. -1) means "unknown".
            let timestamp: Date? = session.mtimeMS > 0
                ? Date(timeIntervalSince1970: Double(session.mtimeMS) / 1000)
                : nil
            let haystack = [title, session.cwd].filter { !$0.isEmpty }.joined(separator: " ")
            return OpenQuicklyItem(
                id: "agent:\(session.id)",
                kind: .agent,
                title: title,
                subtitle: session.cwd.isEmpty ? nil : session.cwd,
                timestamp: timestamp,
                searchText: haystack,
                act: .resumeAgent(sessionID: session.id, cwd: session.cwd),
            )
        }
    }

    /// Build the **Folders** rows from the frecency store's ranked entries. The display ``title`` is the last
    /// path component; the full path is both the subtitle AND the fuzzy haystack (so typing part of the path
    /// matches).
    public static func folderItems(from entries: [FolderEntry]) -> [OpenQuicklyItem] {
        entries.map { entry in
            OpenQuicklyItem(
                id: "folder:\(entry.path)",
                kind: .folder,
                title: folderDisplayName(entry.path),
                subtitle: entry.path,
                timestamp: entry.lastAccess,
                searchText: entry.path,
                act: .openFolder(path: entry.path),
            )
        }
    }

    /// Build the **Current** rows by wrapping the focused pane's ``JumpToModel`` output 1:1 — the link/block
    /// ``JumpToItem/Act`` is carried verbatim so Current actuates through the same `LinkActionActuator` path.
    public static func currentItems(from items: [JumpToItem]) -> [OpenQuicklyItem] {
        items.map { item in
            OpenQuicklyItem(
                id: "current:\(item.id)",
                kind: OpenQuicklyKind(jumpTo: item.kind),
                title: item.title,
                subtitle: nil,
                timestamp: item.timestamp,
                searchText: item.title,
                act: .jumpTo(item.act),
            )
        }
    }

    /// Build one **Opened** row for a live pane (the view enumerates `tree.sessions[].tabs[].root` panes).
    /// `↩` focuses the pane; title + cwd are both matchable.
    ///
    /// `paneKind` (E21 WI-2) differentiates a VIDEO pane (`.remoteGUI`/`.systemDialog`) so the row reads as a
    /// *window* (glyph + "Window"/"Dialog" badge + host/window subtitle) while ``Act`` stays the kind-generic
    /// `.focusPane`. Defaults to `.terminal`, so every existing caller and non-video pane keeps "Pane" chrome.
    public static func paneItem(
        paneID: PaneID,
        title: String,
        cwd: String?,
        paneKind: PaneKind = .terminal,
        appName: String? = nil,
    ) -> OpenQuicklyItem {
        let haystack = [title, cwd ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return OpenQuicklyItem(
            id: "pane:\(paneID.raw.uuidString)",
            kind: .pane,
            title: title,
            subtitle: paneRowSubtitle(cwd: cwd, title: title, paneKind: paneKind, appName: appName),
            timestamp: nil,
            searchText: haystack,
            act: .focusPane(paneID),
            paneKind: paneKind,
        )
    }

    /// The subtitle for an Opened pane row (E21 WI-2). A terminal pane shows its cwd (or nothing when unknown —
    /// never a blank line). A VIDEO pane (`.remoteGUI`/`.systemDialog`) has no shell cwd, so the host window's
    /// owning APP name (`appName`) stands in — mirroring the sidebar's ``PaneSpec/railSubtitle`` discipline
    /// (window title on line 1, host app on line 2) so the row never echoes its title on both lines. It falls
    /// back to the window ``title`` only when `appName` is empty (a manual-id binding), keeping the row a
    /// labelled window (glyph + badge + subtitle) not a bare line. A real cwd always wins (never silently
    /// dropped).
    private static func paneRowSubtitle(cwd: String?, title: String, paneKind: PaneKind, appName: String?) -> String? {
        if let cwd = nonEmpty(cwd) { return cwd }
        guard paneKind.isVideo else { return nil }
        // EMPTY HOST-TITLE PARITY: surface the host app on line 2 only when it is NOT already line 1. An empty
        // streamed-window title makes line 1 fall back to the app name, so an app-name subtitle would echo it
        // on both lines — drop to a single line (the window-title fallback is likewise an echo of line 1).
        if let app = nonEmpty(appName), app != title { return app }
        return nil
    }

    /// Build one **Recent** row for a recently-closed tab at LIFO `index` (0 = most-recently closed). `↩`
    /// reopens it.
    public static func recentTabItem(index: Int, title: String, cwd: String?) -> OpenQuicklyItem {
        let haystack = [title, cwd ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return OpenQuicklyItem(
            id: "recent:\(index)",
            kind: .recentTab,
            title: title,
            subtitle: cwd,
            timestamp: nil,
            searchText: haystack,
            act: .reopenRecentTab(index: index),
        )
    }

    // MARK: - Composite source builders (whole-tree / whole-LIFO — E11 WI-6)

    /// Build the **Opened** rows: one ``OpenQuicklyItem(.pane)`` per LIVE pane across every session → tab,
    /// in `tree` order (the vertical-rail "Opened" — no horizontal tab-bar concept). The display title is the
    /// pane's `lastKnownTitle` (falling back to its spec `title`, then a generic "Pane"); the subtitle + extra
    /// haystack is its `lastKnownCwd`. `↩` focuses the pane. Pure so the view stays a thin renderer and the
    /// enumeration is headlessly testable.
    public static func openedItems(from tree: TreeWorkspace) -> [OpenQuicklyItem] {
        var out: [OpenQuicklyItem] = []
        for session in tree.sessions {
            for tab in session.tabs {
                for paneID in tab.allPaneIDs() {
                    let spec = session.specs[paneID]
                    out.append(paneItem(
                        paneID: paneID,
                        title: paneDisplayTitle(spec),
                        cwd: nonEmpty(spec?.lastKnownCwd),
                        // E21 WI-2: thread the workspace pane kind so a `.remoteGUI`/`.systemDialog` row reads
                        // as a window (glyph + "Window"/"Dialog" badge + host/window subtitle). Defaults to
                        // `.terminal` when the spec side-table is momentarily missing (the gap
                        // ``paneDisplayTitle`` also tolerates) — a spec-less pane stays a generic "Pane".
                        paneKind: spec?.kind ?? .terminal,
                        // E21 F2: thread the host-side app name (same `VideoEndpoint.appName` the rail's
                        // `railSubtitle` reads) so a remote-window row's subtitle is the host app, not an echo
                        // of the line-1 window title. Falls back to the title when absent.
                        appName: spec?.video?.appName,
                    ))
                }
            }
        }
        return out
    }

    /// Build the **Recent** rows from the store's recently-closed-tab LIFO. `records` is the raw
    /// `recentlyClosedTabs` array (appended OLDEST→newest); the rows are emitted NEWEST-first with `index` =
    /// the LIFO distance from the top (`0` = most-recently closed — the one `reopenLastClosedPane()` pops).
    /// The title is the closed tab's title (falling back to its active pane's last-known title); the subtitle
    /// is that pane's last-known cwd.
    public static func recentItems(from records: [RecentlyClosedTab]) -> [OpenQuicklyItem] {
        records.reversed().enumerated().map { index, record in
            let activeSpec = record.tab.activePane.flatMap { record.specs[$0] }
            return recentTabItem(
                index: index,
                title: recentDisplayTitle(tabTitle: record.tab.title, activeSpec: activeSpec),
                cwd: nonEmpty(activeSpec?.lastKnownCwd),
            )
        }
    }

    /// Build the **Host** rows from the live host-window feed (docs/45): one row per host window,
    /// the rail's exact click grammar — a window already streaming acts `.focusPane` (its badge stays
    /// "Host"; the pane row in Opened is the pane-side view of the same thing), the rest act
    /// `.openHostWindow`. `streamedPaneFor` is injected (the view derives it from the live tree) so
    /// the builder stays pure. Row order = feed structure order (position-stable, like the rail).
    public static func hostWindowItems(
        structure: [HostWindowIdentity],
        titles: [UInt32: String],
        streamedPaneFor: (UInt32) -> PaneID?,
    ) -> [OpenQuicklyItem] {
        structure.map { identity in
            let title = titles[identity.windowID] ?? ""
            let display = title.isEmpty ? identity.appName : title
            let act: OpenQuicklyItem.Act =
                if let paneID = streamedPaneFor(identity.windowID) {
                    .focusPane(paneID)
                } else {
                    .openHostWindow(windowID: identity.windowID, title: title, appName: identity.appName)
                }
            return OpenQuicklyItem(
                id: "hostwindow:\(identity.leafIdentity)",
                kind: .hostWindow,
                title: display,
                subtitle: identity.appName,
                timestamp: nil,
                searchText: "\(display) \(identity.appName)",
                act: act,
            )
        }
    }

    /// The display title for an **Opened** pane row: `lastKnownTitle` → spec `title` → the generic "Pane".
    static func paneDisplayTitle(_ spec: PaneSpec?) -> String {
        if let last = spec?.lastKnownTitle, !last.isEmpty { return last }
        if let spec, !spec.title.isEmpty { return spec.title }
        return "Pane"
    }

    /// The display title for a **Recent** tab row: the closed tab's title → its active pane's last-known
    /// title → the generic "Tab".
    static func recentDisplayTitle(tabTitle: String, activeSpec: PaneSpec?) -> String {
        if !tabTitle.isEmpty { return tabTitle }
        if let last = activeSpec?.lastKnownTitle, !last.isEmpty { return last }
        if let activeSpec, !activeSpec.title.isEmpty { return activeSpec.title }
        return "Tab"
    }

    /// A non-empty trimmed-presence helper: `nil` for `nil`/empty, the string otherwise (so an empty cwd is no
    /// subtitle, never a blank one — mirroring the ``agentItems``/``folderItems`` subtitle discipline).
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// The last path component for a folder's display title. Tolerates a trailing slash (`/var/log/` → `log`)
    /// and the root (`/` → `/`); never blanks. No force-unwrap (CLAUDE.md §3).
    static func folderDisplayName(_ path: String) -> String {
        let trimmed = (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
        if let last = trimmed.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return trimmed
    }
}
