import Foundation

// MARK: - TabOrderingEngine (the pure By-Project key helpers)

/// The PURE helpers behind the sidebar's single layout: sections are ALWAYS bucketed by the By-Project key,
/// SECTIONS sort A→Z on their displayed header and ROWS inside one follow first-appearance in
/// `session.tabs` (creation order) — there is no grouping/sort hamburger, `.byDate` buckets, `.updated`
/// recency sort, or manual drag-reorder; see `docs/DECISIONS.md` for the rationale. The bucketing itself lives in
/// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` (per-PANE, so a split tab's panes land in
/// their respective projects), but the BUCKETING ITSELF is ``bucketedByProject(_:projectKey:)`` right
/// here — the rail and the close rule read the same sections from the same code, at their two different
/// granularities, rather than from two hand-written first-appearance loops free to drift apart.
/// No SwiftUI, no I/O — fully headless-testable.
///
/// It lives in the leaf VALUE model, below both ends, because the close rule has two runners:
/// `WorkspaceStore` draws the rail with it, and `WorkspaceIntentApplier` — which is the HOST deciding
/// where focus lands after a close — reaches it from `SlopDeskHost`, a target that does not (and must
/// not) depend on `SlopDeskWorkspaceCore`. A second transcription host-side is exactly how the
/// close-jumps-to-another-project bug comes back.
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

    // MARK: - The pane → project-key precedence (the ONE resolution rule)

    /// The By-Project key for pane `id`: its HOST-pushed `pane/projectKey` (the git worktree toplevel
    /// containing the pane's cwd, else the cwd), else its `pane/cwd` until the first push lands. `nil` ⇒
    /// the pane lands in the "Other" bucket.
    ///
    /// A transient plugin-cache dir (``PaneSpec/looksLikeTransientPluginCwd(_:)`` — `…/owner---repo`) is
    /// NEVER a project key: the host's resolver can race a zinit turbo `builtin cd`, which would file a
    /// real project's pane under a phantom `zsh-users---zsh-autosuggestions` section. A guarded-out
    /// source falls through to the next (host key → cwd → `nil`/"Other") — self-healing once the shell
    /// settles.
    ///
    /// Lookup-parameterized so every caller shares ONE copy of the precedence and its guards: the rail
    /// reads a store, the close rule reads whichever session owns the closing tab, and the host reads
    /// its own document's cells.
    public static func paneProjectKey(
        _ id: PaneID,
        projectKey: (PaneID) -> String?,
        cwd: (PaneID) -> String?,
    ) -> String? {
        if let key = projectKey(id), !key.isEmpty, !PaneSpec.looksLikeTransientPluginCwd(key) {
            return key
        }
        guard let cwd = cwd(id), !PaneSpec.looksLikeTransientPluginCwd(cwd) else { return nil }
        return cwd
    }

    /// A TAB's By-Project key for close-selection purposes: its ACTIVE pane's key, else its first pane's.
    ///
    /// A tab is one row per PANE in the sidebar, so a split tab straddling two projects genuinely has no
    /// single section — it draws in both. The pane the user is focused on is the honest answer to "which
    /// section did this tab live in", and it is the one the close gesture was aimed at.
    ///
    /// `paneKey` is a pane's ALREADY-RESOLVED key (``paneProjectKey(_:projectKey:cwd:)``), so a caller
    /// whose sources are not a `projectKey`/`cwd` pair — the host, reading two document cells — still
    /// gets the active-pane-else-first-pane rule from here rather than writing its own.
    public static func tabProjectKey(
        _ id: TabID,
        in session: Session,
        paneKey: (PaneID) -> String?,
    ) -> String? {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return nil }
        if let active = tab.activePane, let key = paneKey(active) { return key }
        // A plain loop, not `lazy.compactMap`: the lookup is non-escaping.
        for pane in tab.allPaneIDs() {
            if let key = paneKey(pane) { return key }
        }
        return nil
    }

    /// ``tabProjectKey(_:in:paneKey:)`` over the two RAW sources the client holds.
    public static func tabProjectKey(
        _ id: TabID,
        in session: Session,
        projectKey: (PaneID) -> String?,
        cwd: (PaneID) -> String?,
    ) -> String? {
        tabProjectKey(id, in: session, paneKey: {
            paneProjectKey($0, projectKey: projectKey, cwd: cwd)
        })
    }

    // MARK: - By-Project bucketing (the ONE sectioning rule)

    /// Buckets `elements` into By-Project sections: keys ``normalizedProjectKey``-folded, SECTIONS
    /// ALPHABETICAL by their displayed header (``sectionPrecedes(_:_:)``), elements WITHIN a section in
    /// their incoming order. The sidebar's single
    /// layout, expressed once and generically so its two granularities share it —
    /// ``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)`` passes pane ROWS (a split tab's panes
    /// land in their respective projects) and ``projectGroupedTabOrder(_:projectKey:)`` passes TABs (what
    /// "the adjacent tab" means for the close rule). Two hand-written first-appearance loops would be free
    /// to drift, and the drift would show up as focus landing somewhere the sidebar never drew.
    ///
    /// Sections are (key, elements) PAIRS keyed on `String?`, not a dictionary behind a stand-in string for
    /// the keyless case: a sentinel here would be a second literal that merely LOOKS coupled to the rail's
    /// "Other" collapse key, and the two answer different questions. `nil` is its own section, natively.
    /// Linear section lookup is right at these counts (sections in the tens).
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
        return sections.sorted { sectionPrecedes($0.key, $1.key) }
    }

    /// The SECTION order: named projects A→Z by the header the sidebar actually shows, the keyless
    /// "Other" bucket last (user-directed 2026-08-10 — the list used to follow first appearance in
    /// `session.tabs`, so where a project sat was a fact about when you happened to open it).
    ///
    /// Ordering on the HEADER (the key's basename), not the key, because the header is what the eye
    /// scans: `/w/zeta/alpha` reads "alpha" and belongs under A. `localizedStandardCompare` is the
    /// Finder's comparison — case- and diacritic-insensitive, with digit runs read as numbers, so
    /// `app2` precedes `app10`.
    ///
    /// The key breaks a header tie, which makes this a TOTAL order (keys are unique per section, so
    /// two sections can never compare equal) — `sorted(by:)` is not documented stable, and two
    /// same-basename worktrees are exactly the case that would otherwise shuffle between renders. It
    /// is also the order their parent-qualified headers will read in
    /// (``RailRowsBuilder/headerDisambiguated(_:)`` turns `/w/feature-a/myapp` into `feature-a/myapp`).
    public static func sectionPrecedes(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs else { return false } // the keyless bucket never precedes a named project
        guard let rhs else { return true }
        let byHeader = projectSectionHeader(for: lhs)
            .localizedStandardCompare(projectSectionHeader(for: rhs))
        if byHeader != .orderedSame { return byHeader == .orderedAscending }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
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
