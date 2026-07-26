import Foundation
import SlopDeskWorkspaceModel

// MARK: - TabOrderingEngine (the pure By-Project key helpers)

/// The PURE helpers behind the sidebar's single layout: sections are ALWAYS bucketed by the By-Project key
/// and both sections and rows follow first-appearance in `session.tabs` (creation order) — there is no
/// grouping/sort hamburger, `.byDate` buckets, `.updated` recency sort, or manual drag-reorder; see
/// `docs/DECISIONS.md` for the rationale. The bucketing itself lives in
/// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` (per-PANE, so a split tab's panes land in
/// their respective projects), but the BUCKETING ITSELF is ``bucketedByProject(_:projectKey:)`` right
/// here — the rail and the close rule read the same sections from the same code, at their two different
/// granularities, rather than from two hand-written first-appearance loops free to drift apart.
/// No SwiftUI, no I/O — fully headless-testable.
public enum TabOrderingEngine {
    /// Normalize a raw project key for BUCKETING: trim whitespace, strip trailing slashes (but keep root
    /// `/`), and treat an empty result as absent (`nil` ⇒ the "Other" bucket). The trailing-slash strip is
    /// load-bearing — a pane's cwd (`/work/alpha`) and its git toplevel (`/work/alpha/`, or vice-versa) or a
    /// `cd foo/` differ only by a trailing `/` yet name the SAME project; without normalizing they would
    /// split one directory into two identically-titled sections.
    public static func normalizedProjectKey(_ key: String?) -> String? {
        guard let key else { return nil }
        var trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The section header for a project key — its last path component (`/Users/me/proj/foo` → `foo`),
    /// falling back to the whole (trimmed) key when there is no `/`-delimited component; a `nil`/blank key is
    /// the "Other" bucket. Mirrors the basename helper in ``TabBadgeResolver`` (split on `/`, last non-empty
    /// component).
    public static func projectSectionHeader(for key: String?) -> String {
        guard let key, case let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return "Other" }
        guard let last = trimmed.split(separator: "/", omittingEmptySubsequences: true).last else {
            return trimmed
        }
        return String(last)
    }

    // MARK: - By-Project bucketing (the ONE sectioning rule)

    /// Buckets `elements` into By-Project sections: keys ``normalizedProjectKey``-folded, SECTIONS in
    /// first-appearance order, elements WITHIN a section in their incoming order. The sidebar's single
    /// layout, expressed once and generically so its two granularities share it —
    /// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` passes pane ROWS (a split tab's panes
    /// land in their respective projects) and ``projectGroupedTabOrder(_:projectKey:)`` passes TABs (what
    /// "the adjacent tab" means for the close rule). Two hand-written first-appearance loops would be free
    /// to drift, and the drift would show up as focus landing somewhere the sidebar never drew.
    ///
    /// Sections are (key, elements) PAIRS keyed on `String?`, not a dictionary behind a stand-in string for
    /// the keyless case: a sentinel here would be a second literal that merely LOOKS coupled to the rail's
    /// "Other" collapse key, and the two answer different questions. `nil` is its own section, natively.
    /// Linear section lookup is right at these counts (sections in the tens) and keeps first-appearance
    /// order without a side table.
    public static func bucketedByProject<Element>(
        _ elements: [Element],
        projectKey: (Element) -> String?,
    ) -> [(key: String?, elements: [Element])] {
        var sections: [(key: String?, elements: [Element])] = []
        for element in elements {
            let bucket = normalizedProjectKey(projectKey(element))
            if let index = sections.firstIndex(where: { $0.key == bucket }) {
                sections[index].elements.append(element)
            } else {
                sections.append((bucket, [element]))
            }
        }
        return sections
    }

    // MARK: - Close → next selection

    /// The tab ids in the order the sidebar DRAWS them — ``bucketedByProject(_:projectKey:)`` flattened,
    /// the tab-level reading of the same sectioning the rail renders per PANE.
    ///
    /// This exists because `session.tabs` is CREATION order while the rail is PROJECT order, and the two
    /// disagree the moment a new tab for an already-open project appends past a different project's tab.
    /// Any rule phrased as "the adjacent tab" has to mean adjacent *on screen*, so it reads this — not the
    /// array. Pure; `projectKey` supplies each tab's raw (un-normalized) key.
    public static func projectGroupedTabOrder(
        _ tabs: [TabID],
        projectKey: (TabID) -> String?,
    ) -> [TabID] {
        bucketedByProject(tabs, projectKey: projectKey).flatMap(\.elements)
    }

    /// The tab to focus once `closing` is gone, in preference order:
    ///
    /// 1. **Most-recently-focused survivor** (`focusHistory`, most-recent FIRST) — closing a scratch tab
    ///    returns you to the tab you opened it from, which is where you were actually working.
    /// 2. **Its neighbour inside its own project section** — next, else previous. A fresh launch has no
    ///    history, and rule 1 must not be the only thing keeping focus in the project you are reading.
    /// 3. **Its neighbour in the full display order** — reached only when `closing` was its project's last
    ///    tab, so there is no section left to stay inside.
    ///
    /// "Next, else previous" throughout: the survivor that takes the closed tab's slot, matching the
    /// long-standing `min(removedIndex, count - 1)` feel — the change is WHICH order that index walks.
    ///
    /// `displayOrder` is ``projectGroupedTabOrder(_:projectKey:)`` and still CONTAINS `closing`. Returns
    /// `nil` when `closing` is absent from `displayOrder` or is the only tab.
    public static func successorAfterClose(
        closing: TabID,
        displayOrder: [TabID],
        projectKey: (TabID) -> String?,
        focusHistory: [TabID],
    ) -> TabID? {
        guard let closingIndex = displayOrder.firstIndex(of: closing) else { return nil }
        let survivors = displayOrder.filter { $0 != closing }
        guard !survivors.isEmpty else { return nil }

        // 1. Most-recently-focused survivor. The history's newest entry is usually `closing` itself (it was
        //    active when the user hit ⌘W), so identity + liveness are both filtered here.
        let live = Set(survivors)
        if let recent = focusHistory.first(where: { $0 != closing && live.contains($0) }) { return recent }

        // 2. Neighbour inside the closing tab's own project section.
        let section = normalizedProjectKey(projectKey(closing))
        let siblings = displayOrder.filter { normalizedProjectKey(projectKey($0)) == section }
        if let sibling = neighbour(of: closing, in: siblings) { return sibling }

        // 3. Neighbour in the full display order (the section died with its last tab).
        return neighbour(of: closing, in: displayOrder) ?? survivors[min(closingIndex, survivors.count - 1)]
    }

    /// The element after `target` in `list`, else the one before it — `nil` when `target` is absent or alone.
    private static func neighbour(of target: TabID, in list: [TabID]) -> TabID? {
        guard let index = list.firstIndex(of: target) else { return nil }
        if index + 1 < list.count { return list[index + 1] }
        if index > 0 { return list[index - 1] }
        return nil
    }
}
