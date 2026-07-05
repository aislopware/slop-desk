import Foundation

// MARK: - WorkspaceStore × close-confirmation resolution (E3 WI-4)

/// The parked-close RESOLUTION cluster — confirm/cancel + the two mutually-exclusive park helpers + the
/// dialog's spec lookup — split into their own extension so the (already large) ``WorkspaceStore`` body stays
/// under the lint type-body ceiling (the same reason ``WorkspaceStore+PaneCycle`` / ``WorkspaceStore+Blocks``
/// exist). The parked STATE (``WorkspaceStore/pendingClose`` / ``WorkspaceStore/pendingTabCloseID``) stays a
/// stored property on the main type; everything that arms or resolves it lives here.
public extension WorkspaceStore {
    /// Confirms the parked close in whichever live model is current (W5, ITEM A1 / E3 WI-4). A parked TAB
    /// close (``pendingTabCloseID``) drops the WHOLE tab via ``closeTab(_:)`` — NOT a single leaf — so a
    /// multi-pane tab no longer keeps its siblings; it is checked first since the two parks are mutually
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
    /// is current (W5, ITEM A1) — the tree's side table under ``LiveModel/tree``, else the canvas. Lets the
    /// confirmation dialog name the leaf it would close on EITHER shell (the old canvas-only lookup showed a
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
    /// ``CloseConfirmationPanel`` subtitle (E7 carry-over #4) so it reads accurately (a `.process` park says "a
    /// process is still running", an `.always`/`.multiple_tabs` park does not). A parked PANE close reports its
    /// EFFECTIVE gating policy (``WorkspaceStore/effectivePanePolicy(for:)`` — `.process` for a non-cascading
    /// mid-tab close, else the Tab/Window policy, exactly the #8 guard); a parked TAB close reports
    /// ``SettingsKey/closeConfirmTab``. `nil` when nothing is parked.
    var pendingCloseReasonPolicy: CloseConfirmationPolicy? {
        if pendingTabCloseID != nil { return SettingsKey.closeConfirmTab }
        guard let pane = pendingClose else { return nil }
        return effectivePanePolicy(for: pane)
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
