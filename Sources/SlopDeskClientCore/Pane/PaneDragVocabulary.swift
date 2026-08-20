// PaneDragVocabulary — the values a pane move is spoken in, on every floor that speaks it.
//
// A pane move crosses three hosting views: the in-canvas grab handle, the navigator's rows, and a
// satellite window's grab strip. Nothing on that list is a drawing — a drop is an ORIGIN, a
// DESTINATION, and the screen rects the destination was resolved against — so the vocabulary lives
// below the view layer (docs/56 §3: a UI target holds views only) and each renderer is left with the
// ink.
//
// It lived in the old shared SwiftUI target's `Pane/PaneMoveAffordance.swift` and `.../PaneDragCoordinator.swift`
// until the drag block was evacuated, and the cost of leaving it there was specific rather than
// stylistic. ``PaneDropZone`` is the value the canvas overlay, the AppKit navigator rows and the
// cross-window chip all switch over; on the day the canvas is rewritten in AppKit it would either
// have been spelled a second time, or `SlopDeskMacUI` would have imported the phone's view target to
// reach it — the common view ancestor docs/56 §3 forbids. The same holds for ``PaneDragDestination``,
// which `SlopDeskMacUI` already compares against today.

import CoreGraphics
import SlopDeskWorkspaceModel

// MARK: - The grab strip: what reveals its pill, and what starts a drag from it

/// What is driving a grab strip right now.
///
/// Deliberately NOT "which platform". The distinction that matters is the INPUT's shape: a cursor
/// arrives over a control before it presses it, so it can be asked to reveal one; a finger arrives
/// already pressed and produces no hover at all, so anything gated on hover is not merely subtle there
/// but unreachable. An iPad canvas is `.touch` even with a trackpad attached, because the pane it is
/// drawn over is touch-first and a control a finger cannot find is not improved by a pointer that can.
package enum PaneGrabInput: Equatable {
    /// A cursor that can hover the strip before pressing it.
    case pointer
    /// A finger. No hover, and a press that wanders a little is still a press.
    case touch
}

/// The two facts a grab strip needs which are decisions rather than drawings — so neither of the three
/// renderers that draw one (the canvas handle on each half, the satellite window's strip) may keep its
/// own answer. ``Slate/GrabPill`` owns the strip's SHAPE for the same reason; this owns its BEHAVIOUR.
///
/// The phone's canvas handle used to spell `hovering || isDragging` inline, with `.onHover` the only
/// writer of `hovering` — so on a phone the pill the drag starts from was never drawn at all, and the
/// whole move gesture was unreachable. The drag machinery under it was fine; only its reveal condition
/// was.
package enum PaneGrabPill {
    /// Whether the pill is DRAWN right now.
    ///
    /// Touch reveals it unconditionally, rather than on a long-press, and the choice is not a shrug.
    /// A long-press over this strip would have to win against the recognisers the pane surface already
    /// spends that gesture on (the terminal's own selection and edit menu), and an affordance whose
    /// existence has to be guessed at by pressing is not an affordance. The platform agrees with
    /// itself here: iPadOS draws its own window grabber and Split View pill permanently rather than
    /// revealing them. The cost is one tertiary capsule, and it is bounded — the whole move layer is
    /// mounted only where a move is possible, so a single-pane phone never sees one.
    ///
    /// A pointer keeps the hover reveal it always had, and on a mixed-input iPad it also keeps the
    /// hover GROWTH, which is the renderer's own business: this answers whether the pill is there, not
    /// how big it is.
    package static func isRevealed(input: PaneGrabInput, hovering: Bool, isDragging: Bool) -> Bool {
        switch input {
        case .touch: true
        case .pointer: hovering || isDragging
        }
    }

    /// How far a press must travel before it is a MOVE rather than a tap on the strip (which focuses
    /// the pane).
    ///
    /// A pointer's 2pt is a mouse's slop and always was. A finger's is not: a touch that lands and
    /// lifts moves several points on the way, so 2pt there turns nearly every tap into a drag and the
    /// tap-to-focus underneath becomes unreachable in the other direction. 10pt is the platform's own
    /// panning slop, which is what a user's hand has already been calibrated against.
    package static func minimumDragDistance(_ input: PaneGrabInput) -> CGFloat {
        switch input {
        case .pointer: 2
        case .touch: 10
        }
    }
}

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
