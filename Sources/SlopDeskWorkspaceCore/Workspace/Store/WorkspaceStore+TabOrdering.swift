import Foundation

// MARK: - Sidebar ordering (ALWAYS grouped By-Project, in creation order) + tab selection helpers

/// The sidebar-ordering surface factored out of ``WorkspaceStore`` so the class body stays under the
/// `type_body_length` ceiling (like `WorkspaceStore+Attention.swift` / `WorkspaceStore+Completion.swift`).
///
/// The sidebar has exactly ONE layout (2026-07-10 re-scope, `docs/DECISIONS.md`): panes bucket by their
/// By-Project key and both sections and rows follow first-appearance in `session.tabs` (creation order).
/// The old hamburger machinery — `TabGrouping`/`TabSort`, recency stamps, manual drag-reorder, and the
/// client-side git-toplevel sweep — is deleted; the key is HOST-pushed (wire type 34 →
/// ``WorkspaceStore/setProjectKey(_:for:)``) so every reconnect converges on the same sections.
public extension WorkspaceStore {
    /// The active session's tab ids in ARRAY (== creation) order — the within-section row-order basis for
    /// the per-pane By-Project sectioning (``RailRowsBuilder/sectionedByProject(_:tabOrder:query:)``).
    /// Empty when there is no active session.
    func flatOrderedTabIDs() -> [TabID] {
        tree.activeSession?.tabs.map(\.id) ?? []
    }

    /// The By-Project key for pane `id`: the HOST-pushed ``PaneSpec/projectKey`` (wire type 34 — the git
    /// worktree toplevel containing the pane's cwd, else the cwd; persisted so a cold relaunch renders the
    /// final sections from disk), else the pane's `lastKnownCwd` until the first push lands. `nil` ⇒ the
    /// pane lands in the "Other" bucket.
    ///
    /// A transient plugin-cache dir (``PaneSpec/looksLikeTransientPluginCwd(_:)`` — `…/owner---repo`) is
    /// NEVER a project key: the host's resolver (or a persisted-poison `lastKnownCwd` from before the write
    /// guards) can race a zinit turbo `builtin cd` — either would file a real project's pane under a phantom
    /// `zsh-users---zsh-autosuggestions` section. The write sinks (``WorkspaceStore/setProjectKey(_:for:)``,
    /// ``WorkspaceStore/setLastKnownCwd(_:for:)``) already drop such readings; this is the read-side
    /// backstop so grouping stays clean even if one slips through. A guarded-out source falls through to
    /// the next (host key → cwd → `nil`/"Other") — self-healing once the shell settles.
    func paneProjectKey(_ id: PaneID) -> String? {
        if let key = tree.activeSession?.specs[id]?.projectKey,
           !key.isEmpty, !PaneSpec.looksLikeTransientPluginCwd(key)
        {
            return key
        }
        guard let cwd = tree.activeSession?.specs[id]?.lastKnownCwd,
              !PaneSpec.looksLikeTransientPluginCwd(cwd)
        else { return nil }
        return cwd
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
