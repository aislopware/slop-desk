import Foundation

// MARK: - PaneGroup (a named collection of panes — replaces the tab concept)

/// A named collection of panes on the single infinite ``Canvas`` — the replacement for the retired
/// tab concept (docs/31). A group is **pure metadata**: membership lives on each ``CanvasItem`` via
/// its optional `groupID`, so a `PaneGroup` holds only its identity + display name. There is no pane
/// list to keep in sync and no dangling-id repair — closing a pane drops its membership for free, and
/// deleting a group just clears the `groupID` of its members.
///
/// Groups are **disjoint**: a pane belongs to at most one group (its `groupID`), or to none (the
/// "Ungrouped" bucket). The sidebar lists panes under their group's section; the canvas draws a
/// labeled bounding box around each group's panes (the Figma-style group frame).
///
/// `Identifiable` by ``PaneGroupID`` so SwiftUI lists / `ForEach` bind to a stable key across reorder.
public struct PaneGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: PaneGroupID
    public var name: String

    public init(id: PaneGroupID = PaneGroupID(), name: String) {
        self.id = id
        self.name = name
    }
}
