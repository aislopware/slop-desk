// PaneDropVocabulary — where a pane drag came from, and what releasing it would do.
//
// These three values used to sit one target up, in `SlopDeskClientCore/Pane/PaneDragVocabulary.swift`,
// beside the grab-strip vocabulary they were written with. They came down when ``PaneDropRegister`` —
// the one place a drop's WORDING and MARK are decided — was written, because the register switches
// over all three and `SlopDeskSlate` draws its `Mark`. Slate is the design floor: it may not name the
// presentation layer, so a register living in `SlopDeskClientCore` would have forced either a Slate →
// ClientCore edge (the floor importing the ceiling) or a second `Mark` enum spelled in Slate's own
// terms. Moving the three cases the register asks about is the smaller move, and it makes the
// register's own "it sits BESIDE the zone vocabulary it reads" true rather than aspirational.
//
// What did NOT come down: ``PaneGrabInput``, the grab-strip reveal rule and `PaneMoveDrag`. Those are
// about the STRIP and about view-local drag state, not about what a release means, and nothing below
// the view layer asks them anything. The split is by question asked, not by file of origin.

// MARK: - Where a drag came from, and what releasing it would do

/// Where a live pane drag STARTED: a tiled tree leaf (the in-canvas grab handle) or a detached
/// satellite window's grab strip. Decides the commit family (move vs reattach) and whether `.tearOff`
/// resolves (a satellite already is its own window).
package enum PaneDragOrigin: Equatable {
    case tree
    case detached
}

/// The action releasing the drag at the current cursor would commit — the cross-container superset of
/// the in-canvas ``PaneDropZone``.
package enum PaneDragDestination: Equatable {
    case canvas(PaneDropZone)
    case sidebarRow(PaneID)
    case newTab
    case tearOff
    case none
}

/// The action a release at the current cursor location would commit inside ONE tab's canvas (resolved
/// every drag frame, committed once on release). `.none` is a cancel (release commits nothing).
package enum PaneDropZone: Equatable {
    case none
    /// Drop in the centre of `target` → exchange the two panes' positions.
    case swap(target: PaneID)
    /// Drop on an `edge` band of `target` → the dragged pane becomes a new column/row beside it.
    case resplit(target: PaneID, edge: PaneDropEdge)
    /// Drop in the container's outer gutter → dock the dragged pane to that whole `edge`.
    case dock(edge: PaneDropEdge)
}
