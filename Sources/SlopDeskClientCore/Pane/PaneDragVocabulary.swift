// PaneDragVocabulary — the values a pane move is spoken in, on every floor that speaks it.
//
// A pane move crosses three hosting views: the in-canvas grab handle, the navigator's rows, and a
// satellite window's grab strip. Nothing on that list is a drawing — a drop is an ORIGIN, a
// DESTINATION, and the screen rects the destination was resolved against — so the vocabulary lives
// below the view layer (docs/56 §3: a UI target holds views only) and each renderer is left with the
// ink.
//
// It lived in `SlopDeskClientUI/Pane/PaneMoveAffordance.swift` and `.../PaneDragCoordinator.swift`
// until the drag block was evacuated, and the cost of leaving it there was specific rather than
// stylistic. ``PaneDropZone`` is the value the canvas overlay, the AppKit navigator rows and the
// cross-window chip all switch over; on the day the canvas is rewritten in AppKit it would either
// have been spelled a second time, or `SlopDeskMacUI` would have imported the phone's view target to
// reach it — the common view ancestor docs/56 §3 forbids. The same holds for ``PaneDragDestination``,
// which `SlopDeskMacUI` already compares against today.

import CoreGraphics
import SlopDeskWorkspaceModel

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

/// View-local move-drag state (held by the canvas compositor). `zone` is the resolved drop action
/// under the cursor; the overlay previews it and the release commits it.
package struct PaneMoveDrag: Equatable {
    package var source: PaneID
    package var location: CGPoint
    package var zone: PaneDropZone

    package init(source: PaneID, location: CGPoint, zone: PaneDropZone) {
        self.source = source
        self.location = location
        self.zone = zone
    }
}

// MARK: - The rects a cross-container resolution runs against

/// The keys drop-target frame providers register under. Sidebar rows key per-pane (a row is a pane,
/// not a tab — dropping on it lands BESIDE that pane).
package enum PaneDropTargetKey: Hashable {
    case canvas
    case sidebarList
    case sidebarRow(PaneID)
    case newTabZone
}

/// The screen-rect snapshot a resolution runs against — gathered by ``PaneDragCoordinator``, but kept
/// a plain value so ``PaneDragResolver`` is pure and unit-pinned without views or windows.
package struct PaneDragExternalTargets {
    /// The main workspace window's frame — the `.tearOff` boundary.
    package var mainWindow: CGRect?
    /// The sidebar row list's visible viewport — a row hit counts only inside it (a scrolling list
    /// keeps scrolled-away rows mounted, so a raw row rect can sit outside the clip).
    package var sidebarList: CGRect?
    /// Every registered sidebar row (screen rect), unordered.
    package var rows: [(pane: PaneID, rect: CGRect)]
    /// The sidebar's New-Tab drop slot (mounted only while a drag is live).
    package var newTabZone: CGRect?

    package init(
        mainWindow: CGRect? = nil,
        sidebarList: CGRect? = nil,
        rows: [(pane: PaneID, rect: CGRect)] = [],
        newTabZone: CGRect? = nil,
    ) {
        self.mainWindow = mainWindow
        self.sidebarList = sidebarList
        self.rows = rows
        self.newTabZone = newTabZone
    }
}
