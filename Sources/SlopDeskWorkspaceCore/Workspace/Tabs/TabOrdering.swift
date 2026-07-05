import Foundation

// MARK: - Tab grouping / sort preference (sidebar hamburger menu)

/// How the vertical sidebar BUCKETS tabs into sections (see `docs/ui-shell/spec/user-interface__window-tab-split.md` →
/// the sort hamburger's "Group By" rows). The selection lives on ``WorkspaceStore/tabGrouping`` (the
/// single source of truth for row order) and is persisted via ``SettingsKey/tabGroupingKey``; the
/// rendered sections are a pure derivation of it (``TabOrderingEngine/groups(tabs:grouping:sort:projectKey:lastActiveAt:now:)``).
///
/// Pure value type — `Codable`/`CaseIterable` so the picker enumerates it and it round-trips as its
/// bare rawValue through `Defaults`. **No SwiftUI import** (so the engine unit-tests headless).
public enum TabGrouping: String, Codable, Sendable, CaseIterable {
    /// One flat list, no section chrome (the default — byte-identical to the pre-E6 single-list rail).
    case none
    /// Bucket by the pane's project key (a cached git toplevel, else its `lastKnownCwd`). Headers are the
    /// project's last path component; a keyless pane lands in an "Other" bucket.
    case byProject
    /// Bucket by recency into `Today` / `Yesterday` / `Earlier` (computed from ``WorkspaceStore/tabLastActiveAt``).
    case byDate
}

/// How tabs are ORDERED **within** a group (the sidebar hamburger's "Sort By" rows).
///
/// `created` and `manual` both preserve the `session.tabs` array order — `created` because a tab is
/// appended on creation (so array order == creation order, Design #2 in the E6 plan — no timestamp), and
/// `manual` because a drag permutes that very array (``WorkspaceTreeOps/moveTab(from:to:in:)``). `updated`
/// re-orders by live recency. Persisted via ``SettingsKey/tabSortKey``.
public enum TabSort: String, Codable, Sendable, CaseIterable {
    /// Oldest-opened first — the `session.tabs` insertion order (Design #2: array order == created order).
    case created
    /// Most-recently-active first — stable-sorted by ``WorkspaceStore/tabLastActiveAt`` descending (a tab
    /// with no recency stamp sorts last, ties preserve array order).
    case updated
    /// User-arranged — the `session.tabs` array order, which a manual drag permutes.
    case manual
}

// MARK: - OrderedTabGroup (one rendered section)

/// One rendered sidebar section: an optional `header` (the section title) and the `tabIDs` in render
/// order. `header == nil` ⇒ an UNGROUPED flat list (no section chrome) — the `.none` grouping always
/// emits exactly one such group. A pure `Equatable`/`Sendable` value so the engine output is testable.
public struct OrderedTabGroup: Equatable, Sendable {
    /// The section title, or `nil` for the ungrouped flat list (no header chrome).
    public let header: String?
    /// The tab ids in this section, in final render order (grouping bucket × within-group sort applied).
    public let tabIDs: [TabID]

    public init(header: String?, tabIDs: [TabID]) {
        self.header = header
        self.tabIDs = tabIDs
    }
}

// MARK: - TabOrderingEngine (the pure ordering derivation)

/// The PURE engine that derives the rendered sidebar sections from the tab list + the grouping/sort
/// preference. One static; no SwiftUI, no I/O, **no clock read** (the caller passes `now`) — so it is
/// fully headless-testable and deterministic.
///
/// Order of operations (E6 plan WI-3): the **grouping** buckets tabs (using their FIRST-APPEARANCE in the
/// incoming `tabs` array for the group order), then the **sort** orders the tabs *within* each bucket.
/// Both `created`/`manual` preserve array order; `updated` is a STABLE sort by recency descending with a
/// nil-last tiebreak (ties fall back to array order) — never a bare `<` that would reorder equal keys.
public enum TabOrderingEngine {
    /// Derive the rendered sections.
    ///
    /// - Parameters:
    ///   - tabs: the active session's tabs, in array (== creation) order.
    ///   - grouping: how to bucket into sections.
    ///   - sort: how to order tabs within a section.
    ///   - projectKey: a pane → project-key lookup (cached git toplevel, else cwd). An empty/whitespace
    ///     key is treated as absent (⇒ the "Other" bucket). Called only for `.byProject`.
    ///   - lastActiveAt: a tab → last-active timestamp lookup (`nil` = no recency stamp). Drives `.updated`
    ///     and `.byDate`.
    ///   - now: the reference "now" the `.byDate` Today/Yesterday/Earlier boundaries are computed against
    ///     (injected so the engine never reads the wall clock — pure + testable).
    /// - Returns: the sections in render order. `.none` ⇒ exactly one header-less group.
    public static func groups(
        tabs: [Tab],
        grouping: TabGrouping,
        sort: TabSort,
        projectKey: (PaneID) -> String?,
        lastActiveAt: (TabID) -> Date?,
        now: Date,
    ) -> [OrderedTabGroup] {
        switch grouping {
        case .none:
            let ordered = sortWithinGroup(tabs, sort: sort, lastActiveAt: lastActiveAt)
            return [OrderedTabGroup(header: nil, tabIDs: ordered.map(\.id))]
        case .byProject:
            return projectGroups(tabs: tabs, sort: sort, projectKey: projectKey, lastActiveAt: lastActiveAt)
        case .byDate:
            return dateGroups(tabs: tabs, sort: sort, lastActiveAt: lastActiveAt, now: now)
        }
    }

    // MARK: Grouping — By Project

    private static func projectGroups(
        tabs: [Tab],
        sort: TabSort,
        projectKey: (PaneID) -> String?,
        lastActiveAt: (TabID) -> Date?,
    ) -> [OrderedTabGroup] {
        // Bucket by the (normalized) project key; group order = first appearance of the key in `tabs`.
        // The keyless ("Other") bucket is ordered by its first appearance too — fully deterministic.
        var order: [String?] = []
        var buckets: [String?: [Tab]] = [:]
        for tab in tabs {
            let key = normalizedKey(tab.activePane.flatMap { projectKey($0) })
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(tab)
        }
        return order.map { key in
            let ordered = sortWithinGroup(buckets[key] ?? [], sort: sort, lastActiveAt: lastActiveAt)
            let header = key.map { projectHeader(for: $0) } ?? "Other"
            return OrderedTabGroup(header: header, tabIDs: ordered.map(\.id))
        }
    }

    // MARK: Grouping — By Date

    /// The recency buckets, in fixed render order.
    private enum DateBucket: CaseIterable {
        case today
        case yesterday
        case earlier
        var header: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .earlier: "Earlier"
            }
        }
    }

    private static func dateGroups(
        tabs: [Tab],
        sort: TabSort,
        lastActiveAt: (TabID) -> Date?,
        now: Date,
    ) -> [OrderedTabGroup] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
        func bucket(for date: Date?) -> DateBucket {
            // A tab with no recency stamp can't be Today/Yesterday — it falls into Earlier.
            guard let date else { return .earlier }
            if date >= startOfToday { return .today }
            if let startOfYesterday, date >= startOfYesterday { return .yesterday }
            return .earlier
        }
        var buckets: [DateBucket: [Tab]] = [:]
        for tab in tabs {
            buckets[bucket(for: lastActiveAt(tab.id)), default: []].append(tab)
        }
        // Emit only the non-empty buckets, in the fixed Today → Yesterday → Earlier order.
        return DateBucket.allCases.compactMap { dateBucket in
            guard let group = buckets[dateBucket], !group.isEmpty else { return nil }
            let ordered = sortWithinGroup(group, sort: sort, lastActiveAt: lastActiveAt)
            return OrderedTabGroup(header: dateBucket.header, tabIDs: ordered.map(\.id))
        }
    }

    // MARK: Within-group sort

    /// Order `group` by `sort`. `created`/`manual` preserve the incoming array order; `updated` is a
    /// STABLE sort by recency descending with a nil-last tiebreak (equal-recency / both-nil pairs keep
    /// their original relative order, so the result never churns on a tie).
    private static func sortWithinGroup(
        _ group: [Tab],
        sort: TabSort,
        lastActiveAt: (TabID) -> Date?,
    ) -> [Tab] {
        switch sort {
        case .created,
             .manual:
            group
        case .updated:
            // Stable: carry the original index so ties (equal Date, or both nil) preserve array order.
            group.enumerated()
                .sorted { lhs, rhs in
                    let lDate = lastActiveAt(lhs.element.id)
                    let rDate = lastActiveAt(rhs.element.id)
                    switch (lDate, rDate) {
                    case let (l?, r?):
                        // More recent first; equal timestamps fall back to the stable index tiebreak.
                        if l != r { return l > r }
                        return lhs.offset < rhs.offset
                    case (.some, .none):
                        return true // a stamped tab sorts before an unstamped one (nil last)
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        return lhs.offset < rhs.offset
                    }
                }
                .map(\.element)
        }
    }

    // MARK: Key helpers

    /// Normalize a raw project key: trim, and treat an empty result as absent (`nil` ⇒ the "Other" bucket).
    private static func normalizedKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The section header for a project key — its last path component (`/Users/me/proj/foo` → `foo`),
    /// falling back to the whole (trimmed) key when there is no `/`-delimited component. Mirrors the
    /// basename helper in ``TabBadgeResolver`` (split on `/`, last non-empty component).
    private static func projectHeader(for key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(separator: "/", omittingEmptySubsequences: true).last else {
            return trimmed.isEmpty ? "Other" : trimmed
        }
        return String(last)
    }
}
