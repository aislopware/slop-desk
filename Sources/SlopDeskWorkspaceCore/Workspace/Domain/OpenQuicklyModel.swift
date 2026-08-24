import CSlopDeskFFI
import Foundation
import SlopDeskProtocol
import SlopDeskWorkspaceModel

// MARK: - The pure Open-Quickly (`⌘⇧O`) switcher model

/// The Open-Quickly filter pills — the `⌘⇧O` taxonomy (distinct from the `⌘⇧P` command-palette
/// `QueryFilter`). One floating picker fuzzy-searches these sources; `.all` merges the rest into a single
/// ranked list with ALL-CAPS section headers.
///
/// The pill's four readings — its label, its ALL-CAPS header, its silhouette and its honest empty line —
/// are `slopdesk_workspace::open_quickly`'s, and they cross in ONE delivery per pill: a pill labelled
/// one thing whose header said another would be two of the four disagreeing, which is only reachable if
/// they are asked separately.
///
/// ### Pill set
/// The ring is **All / Opened / Recent / Folders / Agents / Current**. SSH and Recipes are NOT pills — the
/// cut is structural (no `ssh` / `recipes` case exists on this enum, so nothing can route to either):
/// - **SSH**: no `~/.ssh/config` parse, no `⌘S` chord, no SSH Actions row.
/// - **Recipes**: no recipe feature backs this picker.
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
    /// The focused pane's detected links + command/prompt index (`⌘J` / Jump-To).
    case current

    /// The pill order rendered in the filter bar (Tab/⇧Tab cycle this ring). `⌘⇧O` opens to ``defaultFilter``.
    ///
    /// Both memberships come from ONE bitmask over the shared code space: the low 16 bits are the pill
    /// ring, the high 16 the section headers. They differ by exactly one member — All is a pill and
    /// heads nothing — and asking for that difference twice is how the two lists come apart.
    public static let pickerPills: [Self] = offered { $0 & 0xFFFF }

    /// The section order the `.all` list merges in (every pill EXCEPT `.all`, in pill order). `.all` itself is
    /// never a section — it is the merged view of these.
    public static let sectionOrder: [Self] = offered { $0 >> 16 }

    /// The pill `⌘⇧O` opens to (the merged All list).
    public static let defaultFilter: OpenQuicklyFilter = .all

    /// The pill's display label (also the source of ``sectionHeader``).
    public var label: String { readings[0] }

    /// The ALL-CAPS group header this source renders under in the merged `.all` list (the uppercased pill name).
    public var sectionHeader: String { readings[1] }

    /// The pill's leading SF Symbol name (`Image(systemName:)`).
    public var icon: String { readings[2] }

    /// The honest empty-state line the picker shows when this source has no rows.
    public var emptyMessage: String { readings[3] }

    /// The bare character of the picker-LOCAL `⌘`-chord that jumps straight to this pill (`⌘0`/`⌘W`/`⌘R`/
    /// `⌘Z`/`⌘G`/`⌘J`). Handled by the panel's own `onKeyPress`, NEVER registered globally.
    public var pickerChordKey: String { String(UnicodeScalar(Self.pills[code].chord)) }

    /// This pill's own code, which is also its place in the ring.
    public var code: Int {
        switch self {
        case .all: 0
        case .opened: 1
        case .recent: 2
        case .folders: 3
        case .agents: 4
        case .current: 5
        }
    }

    public init?(code: Int) {
        guard Self.allCases.indices.contains(code) else { return nil }
        self = Self.allCases[code]
    }

    private var readings: [String] { Self.pills[code].runs }

    /// Every pill's chord key and four readings, in six crossings, once per process.
    private static let pills: [(chord: UInt8, runs: [String])] = allCases.map { pill in
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_ws_open_quickly_pill(UInt8(pill.code), out, cap))
        }
        guard let chord = blob.first else { return (0, ["", "", "", ""]) }
        return (chord, wsRuns(Array(blob.dropFirst()), count: 4))
    }

    /// The members of one half of the shared bitmask, in code order.
    private static func offered(_ half: (UInt32) -> UInt32) -> [Self] {
        let mask = half(slopdesk_ws_open_quickly_pill_sets())
        return allCases.filter { mask & (1 << UInt32($0.code)) != 0 }
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

    /// The trailing type-badge label the row renders flush-right.
    public var badge: String { Self.kinds[code].runs[0] }

    /// The leading icon SF Symbol name (`Image(systemName:)`).
    public var symbol: String { Self.kinds[code].runs[1] }

    /// The `↩` verb a row of this kind earns, for the footer hint — the ROW's, not the picker's.
    ///
    /// It rides with the badge and the symbol because all three are readings of one kind and a row is
    /// built with all three at once.
    public var defaultActionLabel: String { Self.kinds[code].runs[2] }

    /// The ``JumpToItemKind`` a reconstructed item takes. Cosmetic — the shared jump table keys only on
    /// the act and the title — so a kind that never reaches here reads as `.path`.
    public var jumpToKind: JumpToItemKind {
        switch Self.kinds[code].jumpTo {
        case 1: .url
        case 2: .fileURL
        case 3: .command
        case 4: .prompt
        default: .path
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

    public var code: Int {
        switch self {
        case .pane: 0
        case .folder: 1
        case .agent: 2
        case .recentTab: 3
        case .command: 4
        case .prompt: 5
        case .path: 6
        case .url: 7
        case .fileURL: 8
        }
    }

    /// Every kind's jump-to code and three readings, in nine crossings, once per process.
    private static let kinds: [(jumpTo: UInt8, runs: [String])] = allCases.map { kind in
        let blob = wsAnswerBytes { out, cap in
            Int(slopdesk_ws_open_quickly_kind(UInt8(kind.code), out, cap))
        }
        guard let jumpTo = blob.first else { return (0, ["", "", ""]) }
        return (jumpTo, wsRuns(Array(blob.dropFirst()), count: 3))
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

    /// The WORKSPACE pane kind a `.pane` row is backed by. For a `.desktop` VIDEO
    /// pane it differentiates ``symbol``/``badge`` so the row reads as its stream target (display glyph +
    /// "Desktop" badge) instead of a generic split "Pane", while ``act`` stays kind-generic
    /// (`.focusPane` — `↩` focuses the pane exactly as a terminal row does). Defaults to `.terminal` (the
    /// non-differentiating value) for every NON-pane source (folders / agents / recent / current), where it is
    /// inert (those rows keep their ``OpenQuicklyKind`` chrome).
    public let paneKind: PaneKind

    /// The trailing type badge. A `.pane` row backed by a VIDEO pane reads as its stream target —
    /// "Desktop" — differentiating it from a generic terminal "Pane"; every other row delegates to
    /// its ``OpenQuicklyKind``.
    public var badge: String {
        switch paneKind {
        case .desktop: "Desktop"
        default: kind.badge
        }
    }

    /// The leading icon symbol. A video pane (`.desktop`) uses the display glyph;
    /// every other row delegates to its ``OpenQuicklyKind``.
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
/// - Ranking is `slopdesk_workspace::search_rank`, the one every search field in the app asks for —
///   the same call as ``JumpToModel/filtered(_:query:)``.
/// - The **Current** source is the existing ``JumpToModel`` output, wrapped 1:1 via ``currentItems(from:)``.
/// - What a row is CALLED comes from the rules the rail reads — ``PaneLabel/rowTitle(kind:specTitle:userRenamed:cwd:liveTitle:processLabel:projectKey:)``
///   for line one, ``PaneSpec/cwdDisplayName(_:)`` for a folder's name and
///   ``PaneLabel/railSubtitle(kind:title:video:cwd:liveTitle:projectKey:)`` for a pane's second line.
///   A switcher and a sidebar naming the same pane two different things reads as two panes, so the
///   picker asks rather than re-deriving.
public enum OpenQuicklyModel {
    // MARK: - Sectioning + ranking

    /// Build the picker sections for `filter`, ranking each source against `query`.
    ///
    /// - `.all`: one section per source in ``OpenQuicklyFilter/sectionOrder``, EMPTY sources omitted (no
    ///   stray header) — the merged-with-headers list.
    /// - a specific pill: exactly ONE section for that source (kept even when empty, so the view renders the
    ///   honest empty-state rather than a blank panel).
    public static func sectioned(
        sources: [OpenQuicklyFilter: [OpenQuicklyItem]],
        filter: OpenQuicklyFilter,
        query: String,
    ) -> [OpenQuicklySection] {
        if filter == .all {
            return OpenQuicklyFilter.sectionOrder.compactMap { source in
                let ranked = rank(sources[source] ?? [], query: query)
                guard !ranked.isEmpty else { return nil }
                return OpenQuicklySection(filter: source, items: ranked)
            }
        }
        return [OpenQuicklySection(filter: filter, items: rank(sources[filter] ?? [], query: query))]
    }

    /// Fuzzy-filter + rank `items` by `query`. An EMPTY query returns `items` unchanged (the
    /// zero-state); a non-empty one drops the misses and orders the survivors best-first, with the
    /// source's own order breaking ties.
    static func rank(_ items: [OpenQuicklyItem], query: String) -> [OpenQuicklyItem] {
        wsSearchRanked(items, query: query) { $0.searchText }
    }

    /// The flattened, navigable row list (sections concatenated; headers are NOT rows). The basis for
    /// arrow-key selection + ``quickPickIndex(_:in:)``.
    public static func selectable(_ sections: [OpenQuicklySection]) -> [OpenQuicklyItem] {
        sections.flatMap(\.items)
    }

    /// Map a 1-based `⌘1–9` quick-pick chord onto a 0-based index into the visible `rows` —
    /// ``ListNavigation/quickPickIndex(_:rowCount:)``, over the rows this picker happens to be
    /// showing. `nil` for `⌘0` (the All-pill chord, not a pick), a chord above 9, or an index past
    /// the visible rows.
    public static func quickPickIndex(_ oneBased: Int, in rows: [OpenQuicklyItem]) -> Int? {
        ListNavigation.quickPickIndex(oneBased, rowCount: rows.count)
    }

    /// Fuzzy-filter + rank a list of titled actions by `query` — the `⌘K` Actions popover search.
    /// Generic over the action type via a `title` projection, so the popover and the row ranker
    /// differ in what they are found BY and in nothing else.
    public static func rankActions<Action>(
        _ actions: [Action],
        query: String,
        title: (Action) -> String,
    ) -> [Action] {
        wsSearchRanked(actions, query: query, searchText: title)
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

    /// The pills are a RING rather than a list, so the step wraps —
    /// ``ListNavigation/wrappedIndex(_:delta:count:)``. A pill that is not in the ring has nothing
    /// to step from and stays where it is.
    private static func cycle(from current: OpenQuicklyFilter, by delta: Int) -> OpenQuicklyFilter {
        let pills = OpenQuicklyFilter.pickerPills
        guard let index = pills.firstIndex(of: current),
              let wrapped = ListNavigation.wrappedIndex(index, delta: delta, count: pills.count),
              pills.indices.contains(wrapped)
        else { return current }
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
    /// `paneKind` differentiates a VIDEO pane (`.desktop`) so the row reads as its
    /// stream target (glyph + badge + host subtitle) while ``Act`` stays the kind-generic
    /// `.focusPane`. Defaults to `.terminal`, so every existing caller and non-video pane keeps "Pane" chrome.
    ///
    /// LINE TWO is ``PaneLabel/railSubtitle(kind:title:video:cwd:liveTitle:projectKey:)`` — the rail's
    /// own rule, not a second one: a terminal says where it is, a video pane says which host APP it
    /// streams unless line one already said it. The picker draws no section headers, so it passes no
    /// project key and gets the whole path.
    public static func paneItem(
        paneID: PaneID,
        title: String,
        cwd: String?,
        paneKind: PaneKind = .terminal,
        video: VideoEndpoint? = nil,
    ) -> OpenQuicklyItem {
        let haystack = [title, cwd ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return OpenQuicklyItem(
            id: "pane:\(paneID.raw.uuidString)",
            kind: .pane,
            title: title,
            subtitle: PaneLabel.railSubtitle(
                kind: paneKind, title: title, video: video, cwd: cwd, liveTitle: title, projectKey: nil,
            ),
            timestamp: nil,
            searchText: haystack,
            act: .focusPane(paneID),
            paneKind: paneKind,
        )
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

    // MARK: - Composite source builders (whole-tree / whole-LIFO)

    /// Build the **Opened** rows: one ``OpenQuicklyItem(.pane)`` per LIVE pane across every session → tab,
    /// in `tree` order (the vertical-rail "Opened" — no horizontal tab-bar concept). The display title is the
    /// rail's own structural title for that pane (``paneDisplayTitle(_:liveTitle:cwd:)``); the subtitle + extra
    /// haystack is its cwd. `↩` focuses the pane. Pure so the view stays a thin renderer and the
    /// enumeration is headlessly testable.
    ///
    /// - Parameter facts: the three per-pane facts the tree does not carry — the pane's live shell title,
    ///   its working directory, and the foreground process the title's lowest rung reads. The caller reads them from the workspace mirror; a pane the mirror knows
    ///   nothing about answers `(nil, nil)` and falls through to the spec title with no subtitle.
    public static func openedItems(
        from tree: TreeWorkspace,
        facts: (PaneID) -> (title: String?, cwd: String?, process: String?) = { _ in (nil, nil, nil) },
    ) -> [OpenQuicklyItem] {
        var out: [OpenQuicklyItem] = []
        for session in tree.sessions {
            for tab in session.tabs {
                for paneID in tab.allPaneIDs() {
                    let spec = session.specs[paneID]
                    let fact = facts(paneID)
                    out.append(paneItem(
                        paneID: paneID,
                        title: paneDisplayTitle(
                            spec, liveTitle: fact.title, cwd: fact.cwd, process: fact.process,
                        ),
                        cwd: nonEmpty(fact.cwd),
                        // Thread the workspace pane kind so a `.desktop` row reads as its
                        // stream target (glyph + badge + host subtitle). Defaults to
                        // `.terminal` when the spec side-table is momentarily missing (the gap
                        // ``paneDisplayTitle`` also tolerates) — a spec-less pane stays a generic "Pane".
                        paneKind: spec?.kind ?? .terminal,
                        // Thread the streamed window so the row's line two is the rail's own subtitle
                        // rule: the host app, never an echo of the line-1 target title.
                        video: spec?.video,
                    ))
                }
            }
        }
        return out
    }

    /// Build the **Recent** rows from the DOCUMENT's reopen ring. `records` arrives NEWEST-first
    /// (``WorkspaceStore/closedTabRecords``) and `index` is the LIFO distance from the top (`0` = the
    /// most-recently closed tab, the one `reopenLastClosedPane()` restores). The title is the closed
    /// tab's title (falling back to its active pane's live shell title); the subtitle is that pane's cwd.
    ///
    /// - Parameter facts: as ``openedItems(from:facts:)``. A closed pane's facts may already have been
    ///   reaped, which is honest: the row then reads by the tab's own title.
    public static func recentItems(
        from records: [WorkspaceTopology.ClosedTab],
        facts: (PaneID) -> (title: String?, cwd: String?, process: String?) = { _ in (nil, nil, nil) },
    ) -> [OpenQuicklyItem] {
        records.enumerated().map { index, record in
            let activePane = record.tab.activePane
            let activeSpec = activePane.flatMap { record.specs[$0] }
            let fact: (title: String?, cwd: String?, process: String?) =
                activePane.map(facts) ?? (nil, nil, nil)
            return recentTabItem(
                index: index,
                title: recentDisplayTitle(
                    tabTitle: record.tab.title, activeSpec: activeSpec, liveTitle: fact.title,
                    cwd: fact.cwd, process: fact.process,
                ),
                cwd: nonEmpty(fact.cwd),
            )
        }
    }

    /// The display title for an **Opened** pane row — ``PaneLabel/rowTitle(kind:specTitle:userRenamed:cwd:liveTitle:processLabel:projectKey:)``,
    /// the rail's own LINE ONE, with the picker's kind-generic name for the empty answer.
    ///
    /// ASKED rather than re-derived. The three rungs this used to spell — the rename, the live shell
    /// title, the spec title — are `slopdesk_workspace::rail_title::row_title`'s, and it had lost a
    /// rung the rail has: a pane in `/work/a` reads `a` in the sidebar and read its shell's `vim`
    /// here, which is one pane wearing two names in two lists of the same panes. The picker draws no
    /// section headers, so it passes no project key and the folder name stays the title.
    ///
    /// The empty answer is real (the crate's at-root idle shell), and this surface has no live chain
    /// to hand it to — so "Pane" is what a row with nothing to say is called, never a blank.
    ///
    /// `process` is threaded for the reason the doc above gives and the code did not do: the rung
    /// exists in the crate, the rail passes it, and this surface passing `nil` was the SAME
    /// two-names-for-one-pane bug one rung lower — a cwd-less pane running `vim` read `vim` in the
    /// sidebar and `Pane` here. The caller applies `RailStructureKey.titledByProcess` before it
    /// reads, exactly as the titlebar does, so the rung stays off for a pane the other rungs answer.
    static func paneDisplayTitle(
        _ spec: PaneSpec?, liveTitle: String?, cwd: String? = nil, process: String? = nil,
    ) -> String {
        let title = PaneLabel.rowTitle(
            kind: spec?.kind ?? .terminal, specTitle: spec.map(\.title),
            userRenamed: spec?.userRenamed == true, cwd: cwd, liveTitle: liveTitle,
            processLabel: process,
        )
        return title.isEmpty ? "Pane" : title
    }

    /// The display title for a **Recent** tab row: the closed TAB's own title, else its active pane's
    /// row title, else the generic "Tab".
    ///
    /// The tab title leads because a closed tab is what was closed — the crate's rail rule names a
    /// PANE and has no notion of the tab above it. Everything below that rung is the pane's, and is
    /// asked for rather than re-spelled.
    static func recentDisplayTitle(
        tabTitle: String, activeSpec: PaneSpec?, liveTitle: String?, cwd: String? = nil,
        process: String? = nil,
    ) -> String {
        if !tabTitle.isEmpty { return tabTitle }
        let title = PaneLabel.rowTitle(
            kind: activeSpec?.kind ?? .terminal, specTitle: activeSpec.map(\.title),
            userRenamed: activeSpec?.userRenamed == true, cwd: cwd, liveTitle: liveTitle,
            processLabel: process,
        )
        return title.isEmpty ? "Tab" : title
    }

    /// A non-empty trimmed-presence helper: `nil` for `nil`/empty, the string otherwise (so an empty cwd is no
    /// subtitle, never a blank one — mirroring the ``agentItems``/``folderItems`` subtitle discipline).
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// The last path component for a folder's display title — ``PaneSpec/cwdDisplayName(_:)``, the
    /// same folder name the sidebar row, the tab strip and the project sections derive, so one
    /// directory is never called two things. A path with no name to show (blank) reads as itself
    /// rather than blanking the row.
    static func folderDisplayName(_ path: String) -> String {
        PaneSpec.cwdDisplayName(path) ?? path
    }
}
