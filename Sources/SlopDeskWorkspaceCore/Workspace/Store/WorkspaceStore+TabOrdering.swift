import Foundation
import SlopDeskWorkspaceModel

// MARK: - Sidebar ordering (ALWAYS grouped By-Project, in creation order) + tab selection helpers

/// The sidebar-ordering surface factored out of ``WorkspaceStore`` so the class body stays under the
/// `type_body_length` ceiling (like `WorkspaceStore+Attention.swift` / `WorkspaceStore+Completion.swift`).
///
/// The sidebar has exactly ONE layout (see `docs/DECISIONS.md`): panes bucket by their By-Project key
/// and both sections and rows follow first-appearance in `session.tabs` (creation order). There is no
/// client-side grouping/sorting, recency stamps, manual drag-reorder, or git-toplevel sweep — the key is
/// HOST-pushed (wire type 34 → ``WorkspaceStore/setProjectKey(_:for:)``) so every reconnect converges on
/// the same sections regardless of client-side state.
public extension WorkspaceStore {
    /// The active session's tab ids in ARRAY (== creation) order — the within-section row-order basis for
    /// the per-pane By-Project sectioning (``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)``).
    /// Empty when there is no active session.
    func flatOrderedTabIDs() -> [TabID] {
        tree.activeSession?.tabs.map(\.id) ?? []
    }

    /// The By-Project key for pane `id`: its HOST-pushed `pane/projectKey` (wire type 34 — the git
    /// worktree toplevel containing the pane's cwd, else the cwd), else its `pane/cwd` until the first
    /// push lands. `nil` ⇒ the pane lands in the "Other" bucket.
    ///
    /// A transient plugin-cache dir (``PaneSpec/looksLikeTransientPluginCwd(_:)`` — `…/owner---repo`) is
    /// NEVER a project key: the host's resolver can race a zinit turbo `builtin cd`, which would file a
    /// real project's pane under a phantom `zsh-users---zsh-autosuggestions` section. The write sinks
    /// (``WorkspaceStore/setProjectKey(_:for:)``, ``WorkspaceStore/setLastKnownCwd(_:for:)``) already drop
    /// such readings; this is the read-side backstop so grouping stays clean even if one slips through. A
    /// guarded-out source falls through to the next (host key → cwd → `nil`/"Other") — self-healing once
    /// the shell settles.
    func paneProjectKey(_ id: PaneID) -> String? {
        Self.paneProjectKey(
            id, projectKey: { projectKey(for: $0) }, cwd: { paneCwd(for: $0) },
        )
    }

    /// ``paneProjectKey(_:)`` over EXPLICIT lookups — the close path resolves keys for whichever
    /// session owns the closing tab, which is not necessarily the active one, and the rail resolves them
    /// for every pane it draws. Static + lookup-parameterized so every caller shares ONE copy of the
    /// host-key → cwd → `nil` precedence and its plugin-cwd guards; a second transcription of those
    /// rules would be free to drift out of agreement with the sidebar.
    static func paneProjectKey(
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

    // MARK: Close → next selection

    /// Records the active tab at the head of ``WorkspaceStore/tabFocusHistory`` (most-recent first), pruned
    /// to the live tab set and capped. Called from every ``reconcileTree()``, which is the one funnel every
    /// tab switch passes through — recording at the individual gestures instead would miss whichever one
    /// gets added next.
    ///
    /// A repeat of the current head is dropped, so a burst of reconciles for the SAME tab (a spec update, a
    /// badge clear) cannot flood the ring and evict the genuinely-previous tab this exists to remember.
    func recordTabFocus() {
        let liveTabs = Set(tree.sessions.flatMap { session in session.tabs.map(\.id) })
        guard let active = tree.activeSession?.activeTab?.id else {
            tabFocusHistory = tabFocusHistory.filter { liveTabs.contains($0) }
            return
        }
        guard tabFocusHistory.first != active else {
            // Still prune: a tab closed elsewhere must not linger as a successor candidate.
            tabFocusHistory = tabFocusHistory.filter { liveTabs.contains($0) }
            return
        }
        var updated = tabFocusHistory.filter { $0 != active && liveTabs.contains($0) }
        updated.insert(active, at: 0)
        tabFocusHistory = Array(updated.prefix(Self.tabFocusHistoryCap))
    }

    /// The tab to focus after `closing` is dropped — MRU survivor, else its neighbour inside its own project
    /// section, else its neighbour in the display order
    /// (``TabOrderingEngine/successorAfterClose(closing:displayOrder:projectKey:focusHistory:)``).
    ///
    /// Closing a BACKGROUND tab returns the ACTIVE tab: the user dismissed something they were not looking
    /// at, and focus has no business moving. (The old index clamp moved it anyway — closing tab 0 while on
    /// tab 2 re-pointed the selection at index 0.)
    ///
    /// Resolved against whichever session OWNS `closing`, not the active one: a tab can be closed in a
    /// background session (another window), and reading the active session's tabs there would compare the
    /// closing tab against a list it is not in and give up.
    ///
    /// `nil` when no session owns `closing`; the caller then leaves the tree ops on their index-clamp
    /// fallback.
    func plannedTabSuccessor(closing: TabID) -> TabID? {
        guard let session = tree.sessions.first(where: { $0.tabs.contains { $0.id == closing } }) else {
            return nil
        }
        if let active = session.activeTab?.id, active != closing { return active }
        // The lookups read THIS store's mirror while the ordering rules stay pure and session-scoped.
        let key: (TabID) -> String? = { [self] in
            Self.tabProjectKey(
                $0, in: session, projectKey: { projectKey(for: $0) }, cwd: { paneCwd(for: $0) },
            )
        }
        return TabOrderingEngine.successorAfterClose(
            closing: closing,
            displayOrder: TabOrderingEngine.projectGroupedTabOrder(
                session.tabs.map(\.id), projectKey: key,
            ),
            projectKey: key,
            focusHistory: tabFocusHistory,
        )
    }

    /// A TAB's By-Project key for close-selection purposes: its ACTIVE pane's key, else its first pane's.
    ///
    /// A tab is one row per PANE in the sidebar, so a split tab straddling two projects genuinely has no
    /// single section — it draws in both. The pane the user is focused on is the honest answer to "which
    /// section did this tab live in", and it is the one the close gesture was aimed at.
    static func tabProjectKey(
        _ id: TabID,
        in session: Session,
        projectKey: (PaneID) -> String?,
        cwd: (PaneID) -> String?,
    ) -> String? {
        guard let tab = session.tabs.first(where: { $0.id == id }) else { return nil }
        if let active = tab.activePane,
           let key = paneProjectKey(active, projectKey: projectKey, cwd: cwd) { return key }
        // A plain loop, not `lazy.compactMap`: the two lookups are non-escaping.
        for pane in tab.allPaneIDs() {
            if let key = paneProjectKey(pane, projectKey: projectKey, cwd: cwd) { return key }
        }
        return nil
    }

    /// Prunes the TREE-keyed sidebar mirror to the live tree on every ``reconcileTree()``: the E20 manual
    /// tab-badge override (keyed by ``TabID``). A closed tab must not keep a stale manual badge (and the
    /// dict must not grow unbounded across a long session of open/close). Empty in the common case ⇒ cheap.
    func pruneTreeSidebarMirrors() {
        guard !tabBadgeOverrides.isEmpty else { return }
        let liveTabs = Set(tree.sessions.flatMap { session in session.tabs.map(\.id) })
        tabBadgeOverrides = tabBadgeOverrides.filter { liveTabs.contains($0.key) }
    }

    /// Selects the tab `delta` away from the active tab in the active session, clamped to the tab range
    /// (no wrap — a list stops at its ends, like the palette). The "next/prev tab" command entry. No-op
    /// without an active session.
    func cycleTab(by delta: Int) {
        guard let session = tree.activeSession else { return }
        let count = session.tabs.count
        guard count > 1 else { return }
        let next = min(max(session.activeTabIndex + delta, 0), count - 1)
        guard next != session.activeTabIndex else { return }
        selectTab(next)
    }

    /// Selects the `number`-th tab (1-based) of the active session, if it exists. The ⌘1…⌘9 command entry;
    /// a number past the tab count is a no-op (clamps to nothing rather than the last tab — a missing tab
    /// number simply does nothing, the native ⌘N tab idiom).
    func selectTabNumber(_ number: Int) {
        guard let session = tree.activeSession else { return }
        let index = number - 1
        guard session.tabs.indices.contains(index) else { return }
        selectTab(index)
    }
}
