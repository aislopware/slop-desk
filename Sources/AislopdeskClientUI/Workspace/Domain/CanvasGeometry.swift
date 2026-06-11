import Foundation
import CoreGraphics

// MARK: - Resize anchors

/// Which corner / edge of an item is being dragged during a resize (docs/30 §3). The opposite
/// edge(s) stay pinned; the anchored edge(s) follow the drag. This is the canvas analogue of the
/// legacy `SplitContainer`'s divider gap — a pure value so the resize math is unit-tested with no view.
public enum ResizeAnchor: Sendable, CaseIterable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight
}

// MARK: - Pure canvas geometry (the SplitContainer.applyingDelta analogue)

/// Pure static geometry for the infinite canvas: the camera transform (a rigid translate), the
/// 8-anchor resize math, new-pane placement, and the kind-aware culling decision. Free of SwiftUI;
/// `CGRect` math is the geometry source of truth, fully unit-testable on macOS with no view
/// (docs/30 §3).
public enum CanvasGeometry {
    // MARK: Camera transform

    /// The on-screen rect for a canvas-space frame `f` under `camera` — a **pure translate**: the
    /// width/height are copied verbatim (1:1, no scale) and the origin is shifted by the camera. This
    /// is the single canvas↔screen mapping; keeping it pure pins the pan-only invariant.
    public static func screenRect(_ f: CGRect, camera: CanvasCamera) -> CGRect {
        CGRect(
            x: f.origin.x - camera.origin.x,
            y: f.origin.y - camera.origin.y,
            width: f.size.width,
            height: f.size.height
        )
    }

    /// The inverse: the canvas-space point for an on-screen point under `camera`.
    public static func canvasPoint(_ p: CGPoint, camera: CanvasCamera) -> CGPoint {
        CGPoint(x: p.x + camera.origin.x, y: p.y + camera.origin.y)
    }

    // MARK: Resize

    /// The new frame while dragging `anchor` by `delta`: the anchored edge(s) move, the opposite
    /// edge(s) stay pinned, and width/height are floored to `minSize` (clamping pushes the *moved*
    /// edge back so the pinned edge never shifts). Pure; unit-tested edge-by-edge over all 8 anchors.
    public static func resizing(
        _ frame: CGRect,
        anchor: ResizeAnchor,
        by delta: CGSize,
        minSize: CGSize
    ) -> CGRect {
        var left = frame.minX
        var right = frame.maxX
        var top = frame.minY
        var bottom = frame.maxY

        let movesLeft: Bool
        let movesRight: Bool
        let movesTop: Bool
        let movesBottom: Bool
        switch anchor {
        case .topLeft:     movesLeft = true;  movesRight = false; movesTop = true;  movesBottom = false
        case .top:         movesLeft = false; movesRight = false; movesTop = true;  movesBottom = false
        case .topRight:    movesLeft = false; movesRight = true;  movesTop = true;  movesBottom = false
        case .left:        movesLeft = true;  movesRight = false; movesTop = false; movesBottom = false
        case .right:       movesLeft = false; movesRight = true;  movesTop = false; movesBottom = false
        case .bottomLeft:  movesLeft = true;  movesRight = false; movesTop = false; movesBottom = true
        case .bottom:      movesLeft = false; movesRight = false; movesTop = false; movesBottom = true
        case .bottomRight: movesLeft = false; movesRight = true;  movesTop = false; movesBottom = true
        }

        if movesLeft { left += delta.width }
        if movesRight { right += delta.width }
        if movesTop { top += delta.height }
        if movesBottom { bottom += delta.height }

        // Floor width by pushing whichever edge moved (the pinned edge never shifts).
        if right - left < minSize.width {
            if movesLeft { left = right - minSize.width }
            else { right = left + minSize.width } // movesRight (or neither: pin left, grow right harmlessly)
        }
        if bottom - top < minSize.height {
            if movesTop { top = bottom - minSize.height }
            else { bottom = top + minSize.height }
        }

        return Canvas.sanitize(CGRect(x: left, y: top, width: right - left, height: bottom - top))
    }

    // MARK: New-pane placement

    /// The fraction of overlap (relative to `a`'s own area) at or above which a candidate is considered
    /// to collide with an existing item and must be nudged.
    public static let overlapThreshold: CGFloat = 0.25

    /// A clean canvas-space frame for a NEW pane of `size`:
    /// - seeded at `near.origin + (cascade, cascade)` (the `NSWindow.cascadeTopLeft` convention) when
    ///   splitting off a focused pane, else at the centre of `viewport` (in canvas space);
    /// - then cascade-stepped by `(cascade, cascade)` while it overlaps ANY `existing` frame by more
    ///   than ``overlapThreshold`` of its own area (capped at ~12 steps);
    /// - if still colliding after the cap, a bounded grid scan over the viewport guarantees a
    ///   non-overlapping slot (and termination).
    ///
    /// The store separately composes ``Canvas/centered(on:viewport:)`` for the in-view guarantee, so
    /// this only needs to avoid stacking exactly on top of another pane.
    public static func placement(
        near: CGRect?,
        existing: [CGRect],
        viewport: CGRect,
        size: CGSize,
        cascade: CGFloat = Canvas.cascadeStep
    ) -> CGRect {
        let seedOrigin: CGPoint
        if let near {
            seedOrigin = CGPoint(x: near.origin.x + cascade, y: near.origin.y + cascade)
        } else {
            seedOrigin = CGPoint(x: viewport.midX - size.width / 2, y: viewport.midY - size.height / 2)
        }

        var candidate = CGRect(origin: seedOrigin, size: size)
        var steps = 0
        while collides(candidate, with: existing), steps < 12 {
            candidate = candidate.offsetBy(dx: cascade, dy: cascade)
            steps += 1
        }
        guard collides(candidate, with: existing) else { return candidate }

        // Bounded grid scan (guarantees a slot + termination). Walk a grid anchored at the viewport's
        // top-left, stepping by the item size + cascade gutter; the first non-colliding cell wins.
        let stepX = size.width + cascade
        let stepY = size.height + cascade
        for row in 0..<8 {
            for col in 0..<8 {
                let cell = CGRect(
                    x: viewport.minX + CGFloat(col) * stepX,
                    y: viewport.minY + CGFloat(row) * stepY,
                    width: size.width,
                    height: size.height
                )
                if !collides(cell, with: existing) { return cell }
            }
        }
        // Pathological density: fall back to the cascaded candidate (still a valid, finite frame).
        return candidate
    }

    /// Whether `candidate` overlaps any `frame` in `existing` by more than ``overlapThreshold`` of
    /// `candidate`'s own area.
    private static func collides(_ candidate: CGRect, with existing: [CGRect]) -> Bool {
        let area = candidate.width * candidate.height
        guard area > 0 else { return false }
        for f in existing {
            let inter = candidate.intersection(f)
            guard !inter.isNull else { continue }
            if (inter.width * inter.height) / area > overlapThreshold { return true }
        }
        return false
    }

    // MARK: Culling (kind-aware)

    /// The items to MOUNT (pure culling, kind-aware, docs/30 §1):
    /// - every NON-`remoteGUI` item (terminals / claudeCode are **never culled** — removing a live
    ///   terminal host closes its surface and a revisit can show a stale alt-screen frame; the OS
    ///   occludes off-viewport views cheaply, so they stay mounted and repaint on pan-back);
    /// - the `focused` item, regardless of kind (never culled);
    /// - any `.remoteGUI` item whose frame intersects the viewport expanded by `margin` (video panes
    ///   ARE culled off-viewport, which beneficially frees a `liveVideoCap` slot via the existing
    ///   `.onDisappear` gate).
    ///
    /// Pure → unit-tested with no view.
    public static func visibleItems(
        _ items: [CanvasItem],
        camera: CanvasCamera,
        viewport: CGSize,
        focused: PaneID?,
        margin: CGFloat = Canvas.cullMargin
    ) -> [CanvasItem] {
        let viewportRect = CGRect(origin: camera.origin, size: viewport)
        let expanded = viewportRect.insetBy(dx: -margin, dy: -margin)
        return items.filter { item in
            if item.id == focused { return true }
            if item.spec.kind != .remoteGUI { return true }
            return item.frame.intersects(expanded)
        }
    }

    /// The ids whose frame intersects the viewport (NO margin, NO kind filter) — the video-cap "on
    /// screen" signal the store consumes (kept independent of ``visibleItems`` so terminals being held
    /// mounted does not pollute the membership set). Pure.
    public static func viewportMembers(
        _ items: [CanvasItem],
        camera: CanvasCamera,
        viewport: CGSize
    ) -> Set<PaneID> {
        let viewportRect = CGRect(origin: camera.origin, size: viewport)
        var members: Set<PaneID> = []
        for item in items where item.frame.intersects(viewportRect) {
            members.insert(item.id)
        }
        return members
    }
}
