import SlopDeskWorkspaceModel

// MARK: - WorkspaceStore × close-confirmation resolution

/// The parked-close RESOLUTION cluster — confirm/cancel + the two mutually-exclusive park helpers + the
/// dialog's spec lookup — split into their own extension so the (already large) ``WorkspaceStore`` body stays
/// under the lint type-body ceiling (the same reason ``WorkspaceStore+PaneCycle`` / ``WorkspaceStore+Blocks``
/// exist). The parked STATE (``WorkspaceStore/pendingClose`` / ``WorkspaceStore/pendingTabCloseID``) stays a
/// stored property on the main type; everything that arms or resolves it lives here.
public extension WorkspaceStore {
    /// Confirms the parked close in whichever live model is current. A parked TAB close
    /// (``pendingTabCloseID``) drops the WHOLE tab via ``closeTab(_:)`` — NOT a single leaf — so a
    /// multi-pane tab does not keep its siblings; it is checked first since the two parks are mutually
    /// exclusive. Otherwise the parked pane id closes via ``closePaneTree(_:)`` under ``LiveModel/tree`` (the
    /// canvas ``closePane(_:)`` would early-return on a tree id, silently dropping the close) or
    /// ``closePane(_:)`` under ``LiveModel/canvas``. No-op when nothing is pending (the unit was already
    /// closed by another path — a close clears a matching park).
    func confirmPendingClose() {
        if let tabID = pendingTabCloseID {
            pendingTabCloseID = nil
            closeTab(tabID)
            return
        }
        guard let id = pendingClose else { return }
        pendingClose = nil
        switch liveModel {
        case .tree: closePaneTree(id)
        case .canvas: closePane(id)
        }
    }

    /// Dismisses the busy-shell / policy close confirmation (pane OR tab) without closing.
    func cancelPendingClose() {
        pendingClose = nil
        pendingTabCloseID = nil
    }

    /// The ``PaneSpec`` of the pane awaiting a busy-close confirmation, resolved from whichever live model
    /// is current — the tree's side table under ``LiveModel/tree``, else the canvas. Lets the
    /// confirmation dialog name the leaf it would close on EITHER shell (a canvas-only lookup would show a
    /// generic title under `.tree`). `nil` when nothing is pending or the pane vanished (a parked TAB close
    /// carries no pane spec — the dialog titles it generically off ``pendingTabCloseID``).
    var pendingCloseSpec: PaneSpec? {
        guard let id = pendingClose else { return nil }
        switch liveModel {
        case .tree: return tree.spec(for: id)
        case .canvas: return workspace.canvas.spec(for: id)
        }
    }

    /// The close-confirmation policy that GATED the currently-parked close — drives the in-app
    /// ``CloseConfirmationPanel`` subtitle so it reads accurately (a `.process` park says "a
    /// process is still running", an `.always` park does not). A parked PANE close reports
    /// ``CloseConfirmationPolicy/process`` — ⌘W's only policy gate is the busy-shell guard (see
    /// ``WorkspaceStore/closeConfirmationNeeded(scope:pane:)``), so the subtitle names the running command
    /// rather than a tab/window consequence the user did not ask about. A parked TAB close reports
    /// ``SettingsKey/closeConfirmTab``. `nil` when nothing is parked. A park raised ONLY for the
    /// project-loss warning still reports its scope's policy — the dialog consults
    /// ``pendingClosePolicyGated`` before printing the policy line at all.
    var pendingCloseReasonPolicy: CloseConfirmationPolicy? {
        if pendingTabCloseID != nil { return SettingsKey.closeConfirmTab }
        guard pendingClose != nil else { return nil }
        return .process
    }

    /// The By-Project section that DIES with the parked close — its display name
    /// (``TabOrderingEngine/projectSectionHeader(for:)``) when the parked pane / tab holds that project's
    /// last live pane(s), `nil` when every project touched keeps a pane elsewhere (or nothing is parked).
    /// Drives the dialog's "closing this closes the project" warning line. Computed LIVE off the tree (not
    /// captured at park time) so a pane opened or closed while the dialog is up keeps the answer honest.
    var pendingCloseProjectName: String? {
        if let tabID = pendingTabCloseID,
           let tab = tree.sessions.flatMap(\.tabs).first(where: { $0.id == tabID })
        {
            return projectClosed(byRemoving: tab.allPaneIDs())
        }
        guard let id = pendingClose else { return nil }
        return projectClosed(byRemoving: [id])
    }

    /// Whether the configured close policy (busy shell / `always` / `multiple_tabs`) gates the parked
    /// close — `false` when the park exists ONLY for the project-loss warning, so the dialog never claims
    /// "a process is still running" over an idle shell. Re-evaluated live, like the park conditions.
    var pendingClosePolicyGated: Bool {
        if pendingTabCloseID != nil { return closeConfirmationNeeded(scope: .tab) }
        guard let id = pendingClose else { return false }
        return closeConfirmationNeeded(scope: .pane, pane: id)
    }

    /// The project whose LAST live pane(s) sit entirely inside `ids` — the section header to warn with
    /// before the close makes the whole rail section disappear; `nil` when every project touched survives
    /// in some pane outside `ids`. Keys fold through ``TabOrderingEngine/normalizedProjectKey(_:)`` so the
    /// answer matches the rail's bucketing exactly (`/proj` vs `/proj/` is ONE section), survivors span
    /// EVERY session (a project still open in another window is not closed), and only terminal panes carry
    /// a project — the keyless "Other" bucket never warns, it is not a project.
    internal func projectClosed(byRemoving ids: [PaneID]) -> String? {
        let closing = Set(ids)
        let surviving = Set(tree.allPaneIDs().filter { !closing.contains($0) }.compactMap { sectionKey($0) })
        guard let dead = ids.compactMap({ sectionKey($0) }).first(where: { !surviving.contains($0) })
        else { return nil }
        return TabOrderingEngine.projectSectionHeader(for: dead)
    }

    /// Pane `id`'s normalized By-Project section key — `nil` for a non-terminal pane (GUI panes carry no
    /// project, mirroring the rail) and for the keyless "Other" bucket.
    private func sectionKey(_ id: PaneID) -> String? {
        guard tree.spec(for: id)?.kind == .terminal else { return nil }
        return TabOrderingEngine.normalizedProjectKey(paneProjectKey(id))
    }

    /// Arms a single-PANE close confirmation, clearing any parked tab close so exactly one confirmation
    /// dialog is ever up (the two parks are mutually exclusive — see ``pendingTabCloseID``).
    internal func parkPaneClose(_ id: PaneID) {
        pendingTabCloseID = nil
        pendingClose = id
    }

    /// Arms a whole-TAB close confirmation, clearing any parked pane close so exactly one confirmation
    /// dialog is ever up (the two parks are mutually exclusive — see ``pendingTabCloseID``).
    internal func parkTabClose(_ tabID: TabID) {
        pendingClose = nil
        pendingTabCloseID = tabID
    }

    /// Whether `id` is the SOLE pane on the canvas — so closing it empties the workspace (the "Add a
    /// pane" empty state). Lets the pane chrome label the close button honestly.
    func isOnlyLeaf(_ id: PaneID) -> Bool {
        workspace.canvas.contains(id) && workspace.canvas.itemCount == 1
    }
}
