// PaneDragResolver — where a cross-container drag would land, decided from rectangles alone.
//
// The sidebar, the canvas and every satellite window live in SEPARATE hosting views, so no view
// framework's coordinate space spans them and the only space that does is the SCREEN's. That is the
// whole reason this is pure: every input is a `CGRect` or a `CGPoint` gathered by
// ``PaneDragCoordinator``, and nothing here reaches a view, a window or a store. It was already
// headlessly pinned while it sat in the view target (`PaneDragResolverTests`, 198 lines); moving it
// down cost the tests one import line.

import CoreGraphics
import SlopDeskWorkspaceModel

/// Pure destination resolution — all inputs are screen-space rects, no view/window reach.
package enum PaneDragResolver {
    /// Resolves a cursor OUTSIDE the main canvas. Precedence: sidebar row (clipped to the list
    /// viewport) → the New-Tab slot → dead main-window chrome (`.none`) → outside every window
    /// (`.tearOff`, tree drags only — a satellite already is a window, so its outside drop cancels).
    /// The source's own row resolves `.none` (dropping a pane on itself is a no-op — the preview must
    /// say so honestly). `sourceIsSoleLeafOfItsTab` gates `.newTab` for a tree drag: breaking a
    /// sole-leaf tab into "its own tab" is the identity op, so the slot reads as a cancel for it.
    package static func externalDestination(
        at point: CGPoint,
        targets: PaneDragExternalTargets,
        origin: PaneDragOrigin,
        source: PaneID,
        sourceIsSoleLeafOfItsTab: Bool,
    ) -> PaneDragDestination {
        if let list = targets.sidebarList, list.contains(point) {
            for row in targets.rows where row.rect.intersection(list).contains(point) {
                return row.pane == source ? .none : .sidebarRow(row.pane)
            }
            // Inside the list but over a header / empty space — fall through to the slot / chrome checks.
        }
        if let zone = targets.newTabZone, zone.contains(point) {
            if origin == .tree, sourceIsSoleLeafOfItsTab { return .none }
            return .newTab
        }
        if let window = targets.mainWindow, window.contains(point) { return .none }
        // Outside the main window entirely. Without a known window frame the geometry is unreliable —
        // never tear off on a guess.
        guard targets.mainWindow != nil, origin == .tree else { return .none }
        return .tearOff
    }

    /// The INSERT-drag zone for a detached pane over the main canvas (canvas-local, top-left
    /// coordinates): the pane is not in the tab, so there is no swap and no source to exclude — the
    /// container gutter docks full-span, and anywhere over a leaf re-splits toward the NEAREST edge
    /// (band 0.5 ⇒ every interior point maps to its dominant edge; no dead centre). Deterministic
    /// under (impossible-in-practice) overlapping rects via a positional sort.
    package static func insertZone(
        at point: CGPoint,
        frames: [PaneID: CGRect],
        container: CGRect,
    ) -> PaneDropZone {
        guard container.width > 0, container.height > 0, container.contains(point) else { return .none }
        if let edge = PaneDropGeometry.containerEdge(at: point, container: container, sourceRect: nil) {
            return .dock(edge: edge)
        }
        let ordered = frames.sorted {
            ($0.value.minY, $0.value.minX, $0.key.raw.uuidString)
                < ($1.value.minY, $1.value.minX, $1.key.raw.uuidString)
        }
        for (pane, rect) in ordered where rect.contains(point) && rect.width > 0 && rect.height > 0 {
            let u = (point.x - rect.minX) / rect.width
            let v = (point.y - rect.minY) / rect.height
            return .resplit(target: pane, edge: PaneDropGeometry.dominantEdge(u: u, v: v, band: 0.5))
        }
        return .none
    }

    /// The signed sidebar auto-scroll step for a drag cursor at `point` (screen coords, bottom-left
    /// origin) over the list viewport `list`: inside the TOP band the list should scroll UP (negative —
    /// the flipped document's origin.y shrinks), inside the BOTTOM band DOWN (positive), anywhere else
    /// `nil` (no scroll). The step ramps linearly with depth into the band, so grazing the edge creeps
    /// and burying the cursor in it moves fast. Pure — pinned headlessly.
    package static func autoScrollStep(
        at point: CGPoint,
        list: CGRect,
        band: CGFloat = 44,
        maxStep: CGFloat = 12,
    ) -> CGFloat? {
        guard list.contains(point), list.height > 0, band > 0, maxStep > 0 else { return nil }
        // A short list would let the bands overlap and jitter between directions — shrink them.
        let band = Double.minimum(band, list.height / 3)
        let intoTop = point.y - (list.maxY - band)
        if intoTop > 0 { return -maxStep * (intoTop / band) }
        let intoBottom = (list.minY + band) - point.y
        if intoBottom > 0 { return maxStep * (intoBottom / band) }
        return nil
    }

    /// Canvas-local (top-left origin) → screen (AppKit bottom-left) given the canvas's screen rect.
    package static func screenPoint(fromCanvasLocal p: CGPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: canvas.minX + p.x, y: canvas.maxY - p.y)
    }

    /// Screen (AppKit bottom-left) → canvas-local (top-left origin).
    package static func canvasLocal(fromScreen p: CGPoint, canvas: CGRect) -> CGPoint {
        CGPoint(x: p.x - canvas.minX, y: canvas.maxY - p.y)
    }
}
