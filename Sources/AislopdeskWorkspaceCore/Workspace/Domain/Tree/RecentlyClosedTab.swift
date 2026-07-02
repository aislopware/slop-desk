import Foundation

// MARK: - RecentlyClosedTab (the tree-path reopen-last-closed LIFO record)

/// One entry of the tree shell's "Reopen Closed Tab" LIFO (E3 WI-3, the ⇧⌘T chord) — everything needed to
/// bring a just-closed ``Tab`` back exactly as it was: its full split ``tab`` tree, the ``PaneSpec`` of
/// every leaf in it (``specs``), and the ``SessionID`` that owned it so a reopen lands the tab back in its
/// original session when that session still exists.
///
/// Captured *before* a close op mutates the tree — the close cascade can drop the whole session, so the
/// pre-mutation snapshot is the only source. The reopen re-inserts the tab via
/// ``WorkspaceTreeOps/insertTab(_:specs:at:in:)`` at the configured ``NewTabPosition``, reusing the
/// original ``PaneID``s (the close already removed them from the registry synchronously, so a reopen
/// materializes fresh idle sessions for them — scrollback does not survive, by design, mirroring the
/// canvas single-slot ``WorkspaceStore/RecentlyClosedPane``).
///
/// **In-memory only** (deliberately not persisted, like the canvas reopen slot): across a relaunch the
/// layout file already restores every tab that mattered, so there is no untrusted-decode surface here.
public struct RecentlyClosedTab: Sendable {
    /// The closed tab's split tree (its ``Tab/root``, ``Tab/activePane``, title, zoom) —
    /// captured verbatim so the reopen restores the exact layout, keeping every original ``PaneID``.
    public let tab: Tab
    /// The ``PaneSpec`` for every leaf the closed tab held — merged back into the owning session's side
    /// table on reopen so the **specs == leafIDs invariant** holds for the restored leaves.
    public let specs: [PaneID: PaneSpec]
    /// The session that owned the closed tab. The reopen lands the tab back here when this session is still
    /// alive; otherwise (the owning session was closed while the record sat on the LIFO) it falls back to
    /// the active session. `nil` only when the workspace had no resolvable active session at capture time.
    public let sessionID: SessionID?

    public init(tab: Tab, specs: [PaneID: PaneSpec], sessionID: SessionID?) {
        self.tab = tab
        self.specs = specs
        self.sessionID = sessionID
    }
}
