import Foundation

// MARK: - Identity for the Session → Tab → Pane hierarchy (docs/42 Phase C1)

/// Stable identity for a ``Session`` — the top of the new tiled hierarchy (a named, host-scoped group
/// of tabs that replaces the retired infinite canvas, docs/42 §Decisions.1).
///
/// Mirrors ``PaneID`` exactly: a UUID-backed value minted once and stable for the session's lifetime,
/// surviving the persistence round-trip so `activeSessionID` and the sidebar grouping stay valid after
/// restore.
public struct SessionID: Hashable, Codable, Sendable {
    public let raw: UUID
    /// Mints a fresh identity. The default is the common path (a brand-new session); pass an explicit
    /// `UUID` only when reconstructing a known identity (decode, or a test pinning a value).
    public init(raw: UUID = UUID()) { self.raw = raw }
}

/// Stable identity for a ``Tab`` — one tiled split tree within a session.
///
/// Mirrors ``PaneID``: minted once, stable across the tab's lifetime, survives persistence so a tab's
/// selection (`activeTabIndex`) and per-tab focus/zoom state round-trip after restore.
public struct TabID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

/// Stable identity for an interior `.split` node of the ``SplitNode`` tree.
///
/// Unlike ``PaneID`` (which joins to the live-session registry), a `SplitNodeID` names a *divider
/// group* so the store can target a specific split for `resizeDivider(splitID:…)` without an ambiguous
/// path. Minted once per split, stable across re-renders; survives persistence so a saved divider
/// position keeps referring to the same split after restore.
public struct SplitNodeID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}
