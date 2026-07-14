// WorkspaceStore+Stage — the STAGE ops (the Stage re-scope, docs/DECISIONS.md 2026-07-14): the
// dedicated tabbed zone for non-terminal content, docked beside the terminal canvas. Streamed remote
// windows open HERE (never in the split tree — the tree is terminal-only); one stage tab decodes at a
// time (single-active-decode), the background tabs cost zero decode.

import Foundation

public extension WorkspaceStore {
    // MARK: - Reads (the Stage zone's render inputs)

    /// The ACTIVE session's stage panes, in tab-strip order. Empty ⇒ the Stage zone collapses.
    var stagePaneIDs: [PaneID] {
        tree.activeSession?.stagePanes ?? []
    }

    /// The ACTIVE session's selected stage tab — the only one whose video stream decodes.
    var activeStagePaneID: PaneID? {
        tree.activeSession?.activeStagePane
    }

    // MARK: - Open (the single remote-window ingress)

    /// Opens host window `windowID` in the ACTIVE session's Stage — the ONE remote-window ingress
    /// (rail click/drag, palette, control backend). A window already staged is ACTIVATED, not
    /// duplicated (same one-home rule the rail rows key on). A fresh window lands as a new stage tab,
    /// selected; reconcile materializes its `RemoteWindowModel` session (admission still flows through
    /// ``liveVideoCap`` at activation). Returns the stage pane id, or `nil` with no active session.
    @discardableResult
    func openWindowInStage(windowID: UInt32, title: String, appName: String) -> PaneID? {
        guard let sIdx = tree.activeSessionIndex else { return nil }
        if let existing = tree.sessions[sIdx].stagePanes.first(where: {
            tree.sessions[sIdx].specs[$0]?.video?.windowID == windowID
        }) {
            activateStagePane(existing)
            return existing
        }
        return mintStagePane(spec: Self.remoteWindowSpec(windowID: windowID, title: title, appName: appName))
    }

    /// Mints a NEW stage tab carrying `spec` in the ACTIVE session, SELECTED — the shared shape behind
    /// ``openWindowInStage(windowID:title:appName:)`` and the system-dialog monitor's auto tab. Frees
    /// the outgoing tab's decode slot in the same op (single-active-decode) so admission never waits
    /// for the background view's disappear tick. Internal: callers own dedupe (a window already staged
    /// must ACTIVATE, not re-mint).
    @discardableResult
    internal func mintStagePane(spec: PaneSpec) -> PaneID {
        let id = PaneID()
        guard let sIdx = tree.activeSessionIndex else { return id }
        var session = tree.sessions[sIdx]
        if let previous = session.activeStagePane { deactivateVideo(previous) }
        session.stagePanes.append(id)
        session.specs[id] = spec
        session.activeStagePane = id
        tree.sessions[sIdx] = session
        reconcileTree()
        return id
    }

    // MARK: - Activate (stage tab selection = which stream decodes)

    /// Selects stage tab `id` in its owning session. Single-active-decode: the previously selected
    /// tab's video slot is freed IMMEDIATELY (not on the view's disappear tick) so the incoming stream
    /// admits against ``liveVideoCap`` without a transient double-decode. No-op when `id` is not staged
    /// or already selected.
    func activateStagePane(_ id: PaneID) {
        guard let sIdx = tree.sessions.firstIndex(where: { $0.stageContains(id) }),
              tree.sessions[sIdx].activeStagePane != id else { return }
        if let previous = tree.sessions[sIdx].activeStagePane { deactivateVideo(previous) }
        tree.sessions[sIdx].activeStagePane = id
        reconcileTree()
    }

    // MARK: - Close

    /// Closes stage tab `id`: removes it from its session's stage + specs (reconcile tears the video
    /// session down through the shared diff) and advances the selection to the tab that slid into its
    /// slot (else the new last tab; an emptied stage clears the selection and the zone collapses).
    func closeStagePane(_ id: PaneID) {
        guard let sIdx = tree.sessions.firstIndex(where: { $0.stageContains(id) }),
              let index = tree.sessions[sIdx].stagePanes.firstIndex(of: id) else { return }
        var session = tree.sessions[sIdx]
        session.stagePanes.remove(at: index)
        session.specs.removeValue(forKey: id)
        if session.activeStagePane == id {
            session.activeStagePane = session.stagePanes.indices.contains(index)
                ? session.stagePanes[index]
                : session.stagePanes.last
        }
        tree.sessions[sIdx] = session
        // An emptied stage collapses — input ownership falls back to the canvas (nothing left to hold it).
        if session.stagePanes.isEmpty { stageFocused = false }
        reconcileTree()
    }

    /// Where host window `windowID` is already STAGED in the active session: the stage pane + its
    /// 1-based tab-strip ordinal (the right rail's accent marker). The stage sibling of the tree-era
    /// ``streamedWindowPane(for:)``; the earliest tab wins for a window staged twice.
    func stagedWindowPane(for windowID: UInt32) -> StreamedWindowRef? {
        guard let session = tree.activeSession else { return nil }
        for (index, paneID) in session.stagePanes.enumerated()
            where session.specs[paneID]?.video?.windowID == windowID
        {
            return StreamedWindowRef(paneID: paneID, tabOrdinal: index + 1)
        }
        return nil
    }
}
