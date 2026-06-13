import Foundation
import CoreGraphics

// MARK: - Queries (drive reconcile + the coupling that replaces PaneNode reads)

public extension Canvas {
    /// All item ids in a **total, deterministic order**: z ascending, ties broken by the id's UUID
    /// string. This is the canonical ordering used everywhere downstream — it DRIVES the store's
    /// reconcile diff (replacing `PaneNode.allLeafIDs()`), the compact carousel page order, and the
    /// `.next`/`.previous` focus cycle — so all three agree. (reconcile only compares it as a `Set`, so
    /// order never affects the registry invariant; the determinism matters for the cycle + carousel.)
    func allIDs() -> [PaneID] {
        items
            .sorted { lhs, rhs in
                if lhs.z != rhs.z { return lhs.z < rhs.z }
                return lhs.id.raw.uuidString < rhs.id.raw.uuidString
            }
            .map(\.id)
    }

    /// The number of items (diagnostics / "is this the only pane" — replaces `PaneNode.leafCount`).
    var itemCount: Int { items.count }

    /// Whether `id` names an item in this canvas.
    func contains(_ id: PaneID) -> Bool { items.contains { $0.id == id } }

    /// The spec for `id`, or `nil` (replaces `PaneNode.spec(for:)`).
    func spec(for id: PaneID) -> PaneSpec? { items.first { $0.id == id }?.spec }

    /// The canvas-space frame for `id`, or `nil`.
    func frame(of id: PaneID) -> CGRect? { items.first { $0.id == id }?.frame }

    /// The whole item for `id`, or `nil`.
    func item(_ id: PaneID) -> CanvasItem? { items.first { $0.id == id } }

    /// The highest z currently in use, or `-1` when empty (so the first `raising` / `adding` lands at 0).
    var maxZ: Int { items.map(\.z).max() ?? -1 }

    /// The `[PaneID: CGRect]` of canvas-space frames — the input for ``solvedLayout()`` /
    /// ``FocusResolver``.
    func framesByID() -> [PaneID: CGRect] {
        var map: [PaneID: CGRect] = [:]
        for item in items { map[item.id] = item.frame }
        return map
    }

    /// The topmost item whose frame contains `point` (canvas space), or `nil`. Iterates **z-descending**
    /// so a click on overlapping panes hits the frontmost — the inverse of the z-ascending render order.
    func hitTest(_ point: CGPoint) -> PaneID? {
        items
            .sorted { lhs, rhs in
                if lhs.z != rhs.z { return lhs.z > rhs.z }
                return lhs.id.raw.uuidString > rhs.id.raw.uuidString
            }
            .first { $0.frame.contains(point) }?
            .id
    }

    /// Returns a copy with any item whose id was ALREADY seen re-minted to a FRESH ``PaneID`` (first
    /// occurrence in array order keeps its id; a later duplicate gets a new one), so the canvas ends with
    /// globally-unique ids. The load-time repair for a corrupt / copy-pasted file — lossless, since
    /// restored sessions always start idle (a port of the legacy `PaneNode.dedupingLeafIDs`; the registry
    /// is keyed 1:1 by PaneID so a duplicate would otherwise collapse two panes onto one session).
    func dedupingItemIDs(seen: inout Set<PaneID>) -> Canvas {
        var newItems: [CanvasItem] = []
        newItems.reserveCapacity(items.count)
        for item in items {
            if seen.contains(item.id) {
                let fresh = PaneID()
                seen.insert(fresh)
                newItems.append(CanvasItem(id: fresh, spec: item.spec, frame: item.frame, z: item.z, groupID: item.groupID))
            } else {
                seen.insert(item.id)
                newItems.append(item)
            }
        }
        return Canvas(items: newItems, camera: camera)
    }
}

// MARK: - Structural mutations (all pure — return a NEW canvas)

public extension Canvas {
    /// Appends a NEW item of `spec` at `z = maxZ + 1` (frontmost), placed near the `near` pane (or the
    /// viewport centre when `near` is nil) via ``CanvasGeometry/placement(near:existing:viewport:size:cascade:)``.
    /// Returns `(newCanvas, newID)`. Replaces `PaneNode.splitting`. (The store separately guarantees the
    /// new item is in view via ``centered(on:viewport:)``.)
    func adding(
        _ spec: PaneSpec,
        near: PaneID?,
        viewport: CGSize,
        size: CGSize = Canvas.defaultItemSize
    ) -> (Canvas, PaneID) {
        let id = PaneID()
        let nearFrame = near.flatMap { frame(of: $0) }
        let viewportRect = CGRect(origin: camera.origin, size: viewport)
        let placed = CanvasGeometry.placement(
            near: nearFrame,
            existing: items.map(\.frame),
            viewport: viewportRect,
            size: size
        )
        let item = CanvasItem(id: id, spec: spec, frame: Canvas.sanitize(placed), z: maxZ + 1)
        return (Canvas(items: items + [item], camera: camera), id)
    }

    /// Re-adds a previously-closed pane at its EXACT former frame (the close-undo restore), frontmost.
    /// A FRESH id is minted deliberately: the closed pane's session teardown is async, so reusing the
    /// old ``PaneID`` could race the in-flight teardown's registry/cap bookkeeping — and a reopened
    /// pane's session is a NEW session anyway (scrollback does not survive; the menu says "Reopen",
    /// not "Undo"). `group` is the caller-validated group to rejoin (`nil` = ungrouped).
    func restoring(_ spec: PaneSpec, frame: CGRect, group: PaneGroupID?) -> (Canvas, PaneID) {
        let id = PaneID()
        let item = CanvasItem(id: id, spec: spec, frame: Canvas.sanitize(frame), z: maxZ + 1, groupID: group)
        return (Canvas(items: items + [item], camera: camera), id)
    }

    /// Removes `id`; returns `nil` iff it was the **last** item (the tab empties — the exact
    /// `PaneNode.closing → nil` contract the store relies on to close the tab). Surviving items keep
    /// their z verbatim (z is order-independent, so no renumber is needed).
    func removing(_ id: PaneID) -> Canvas? {
        let survivors = items.filter { $0.id != id }
        if survivors.count == items.count { return self } // id absent — unchanged
        if survivors.isEmpty { return nil }                // emptied the tab
        return Canvas(items: survivors, camera: camera)
    }

    /// Translates `id`'s frame by `delta` (the chrome drag-to-move commit), clamped finite. No raise
    /// (the store composes `raising` so the policy lives in one place).
    func moving(_ id: PaneID, by delta: CGSize) -> Canvas {
        mapItem(id) { item in
            item.frame = Canvas.sanitize(item.frame.offsetBy(dx: delta.width, dy: delta.height))
        }
    }

    /// Moves `id`'s frame origin to `origin` (clamped finite).
    func moving(_ id: PaneID, to origin: CGPoint) -> Canvas {
        mapItem(id) { item in
            item.frame = Canvas.sanitize(CGRect(origin: origin, size: item.frame.size))
        }
    }

    /// Sets `id`'s frame (the corner/edge resize commit), sanitized so size ≥ ``minItemSize`` and finite.
    func resizing(_ id: PaneID, to frame: CGRect) -> Canvas {
        mapItem(id) { item in item.frame = Canvas.sanitize(frame) }
    }

    /// Brings `id` to the front: `z = maxZ + 1`. A no-op (returns `self`) if `id` is already the top
    /// (or absent), so a redundant focus does not churn the value / persistence.
    func raising(_ id: PaneID) -> Canvas {
        guard let item = item(id) else { return self }
        let top = maxZ
        if item.z == top, items.filter({ $0.z == top }).count == 1 { return self } // already uniquely top
        return mapItem(id) { $0.z = top + 1 }
    }

    /// Transforms the spec of `id` in place (rename / fill endpoint). No-op if absent. Port of
    /// `PaneNode.updatingSpec`.
    func updatingSpec(_ id: PaneID, _ transform: (inout PaneSpec) -> Void) -> Canvas {
        mapItem(id) { transform(&$0.spec) }
    }

    /// Internal helper: returns a copy with the item matching `id` transformed in place (identity if
    /// absent). Keeps the mutation ops one-liners.
    private func mapItem(_ id: PaneID, _ transform: (inout CanvasItem) -> Void) -> Canvas {
        Canvas(
            items: items.map { item in
                guard item.id == id else { return item }
                var copy = item
                transform(&copy)
                return copy
            },
            camera: camera
        )
    }
}

// MARK: - Arrange: align + distribute (pure)

/// Which edge/centre the panes are aligned to.
public enum AlignEdge: Sendable, CaseIterable, Equatable { case left, right, top, bottom, centerHorizontal, centerVertical }

public extension Canvas {
    /// Aligns the panes named by `ids` to the shared edge/centre of THEIR bounding box (Figma's
    /// align-left / align-centre / …). Only the moved axis changes; the perpendicular axis and every
    /// size stay put. Panes not in `ids` are untouched. No-op for fewer than 2 targets.
    func aligning(_ ids: [PaneID], to edge: AlignEdge) -> Canvas {
        let targets = items.filter { ids.contains($0.id) }
        guard targets.count >= 2 else { return self }
        let box = targets.dropFirst().reduce(targets[0].frame) { $0.union($1.frame) }
        let idSet = Set(ids)
        return Canvas(items: items.map { item in
            guard idSet.contains(item.id) else { return item }
            var copy = item
            var f = item.frame
            switch edge {
            case .left:             f.origin.x = box.minX
            case .right:            f.origin.x = box.maxX - f.width
            case .top:              f.origin.y = box.minY
            case .bottom:           f.origin.y = box.maxY - f.height
            case .centerHorizontal: f.origin.x = box.midX - f.width / 2
            case .centerVertical:   f.origin.y = box.midY - f.height / 2
            }
            copy.frame = Canvas.sanitize(f)
            return copy
        }, camera: camera)
    }

    /// Distributes the panes named by `ids` so the GAPS between adjacent panes along `horizontal`/
    /// vertical are equal (Figma's distribute-spacing). The two extreme panes stay put; the interior
    /// ones move. No-op for fewer than 3 targets (nothing interior to redistribute).
    func distributing(_ ids: [PaneID], horizontal: Bool) -> Canvas {
        let targets = items.filter { ids.contains($0.id) }
        guard targets.count >= 3 else { return self }
        // Sort by the leading edge along the axis.
        let sorted = targets.sorted { a, b in
            horizontal ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
        }
        let span = horizontal
            ? (sorted.last!.frame.maxX - sorted.first!.frame.minX)
            : (sorted.last!.frame.maxY - sorted.first!.frame.minY)
        let sumSizes = sorted.reduce(CGFloat(0)) { $0 + (horizontal ? $1.frame.width : $1.frame.height) }
        let gap = (span - sumSizes) / CGFloat(sorted.count - 1)
        // Place each from the first's leading edge, cursor advancing by size + gap.
        var cursor = horizontal ? sorted.first!.frame.minX : sorted.first!.frame.minY
        var newOrigin: [PaneID: CGFloat] = [:]
        for item in sorted {
            newOrigin[item.id] = cursor
            cursor += (horizontal ? item.frame.width : item.frame.height) + gap
        }
        let idSet = Set(ids)
        return Canvas(items: items.map { item in
            guard idSet.contains(item.id), let lead = newOrigin[item.id] else { return item }
            var copy = item
            var f = item.frame
            if horizontal { f.origin.x = lead } else { f.origin.y = lead }
            copy.frame = Canvas.sanitize(f)
            return copy
        }, camera: camera)
    }
}

// MARK: - Camera / arrange (pure)

public extension Canvas {
    /// A new canvas whose camera is panned by `delta` (origin += delta). NO `/scale` term — the camera
    /// is a pure translate, so a screen-space delta IS the canvas-space delta. Sanitized so an extreme
    /// pan can never push the origin non-finite.
    func panned(by delta: CGSize) -> Canvas {
        Canvas(items: items, camera: camera.translated(by: delta).sanitized())
    }

    /// A new canvas with `camera` replaced (commit a live pan). Sanitized — the only camera-set funnel
    /// (centre/tidy/commit all route here), so a non-finite/extreme origin can never be stored.
    func camera(_ camera: CanvasCamera) -> Canvas {
        Canvas(items: items, camera: camera.sanitized())
    }

    /// Centres the camera on `id` (item centre → viewport centre). Always works (no zoom needed); a
    /// no-op if `id` is absent.
    func centered(on id: PaneID, viewport: CGSize) -> Canvas {
        guard let f = frame(of: id) else { return self }
        return camera(Self.camera(centeredOn: CGPoint(x: f.midX, y: f.midY), viewport: viewport))
    }

    /// Centres the camera on the bounding box of ALL items. Because there is no scale, this CANNOT
    /// shrink to fit — it only centres (a bbox larger than the viewport stays centred, partly
    /// off-screen). Identity when there are no items.
    func centeredOnAll(viewport: CGSize) -> Canvas {
        guard let bounds = itemsBoundingBox() else { return self }
        return camera(Self.camera(centeredOn: CGPoint(x: bounds.midX, y: bounds.midY), viewport: viewport))
    }

    /// Whether NO item currently intersects the viewport — i.e. the user has panned into empty space
    /// and the "Recenter" affordance should appear. False when at least one item is (partly) visible.
    func needsRecenter(viewport: CGSize) -> Bool {
        let viewportRect = CGRect(origin: camera.origin, size: viewport)
        return !items.contains { $0.frame.intersects(viewportRect) }
    }

    /// Packs every item into a uniform grid (≈`ceil(sqrt(n))` columns), preserving each item's own
    /// size + z, then recentres the camera on the packed bbox. Deterministic: cells are filled in
    /// ``allIDs()`` order (z-asc, ties by id). The "Tidy" command.
    func tidied(gutter: CGFloat = 16, viewport: CGSize) -> Canvas {
        let count = items.count
        guard count > 1 else { return centeredOnAll(viewport: viewport) }
        let cols = Int(ceil(Double(count).squareRoot()))
        let cellW = (items.map(\.frame.width).max() ?? Canvas.defaultItemSize.width) + gutter
        let cellH = (items.map(\.frame.height).max() ?? Canvas.defaultItemSize.height) + gutter

        let order = allIDs()
        let positionByID: [PaneID: CGPoint] = Dictionary(uniqueKeysWithValues: order.enumerated().map { index, id in
            let row = index / cols
            let col = index % cols
            return (id, CGPoint(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH))
        })

        let packed = items.map { item -> CanvasItem in
            guard let origin = positionByID[item.id] else { return item }
            var copy = item
            copy.frame = Canvas.sanitize(CGRect(origin: origin, size: item.frame.size))
            return copy
        }
        return Canvas(items: packed, camera: camera).centeredOnAll(viewport: viewport)
    }

    /// The bounding box that contains every item's frame, or `nil` when empty.
    private func itemsBoundingBox() -> CGRect? {
        guard var box = items.first?.frame else { return nil }
        for item in items.dropFirst() { box = box.union(item.frame) }
        return box
    }

    /// The camera whose viewport is centred on the canvas-space `point`.
    private static func camera(centeredOn point: CGPoint, viewport: CGSize) -> CanvasCamera {
        CanvasCamera(origin: CGPoint(
            x: point.x - viewport.width / 2,
            y: point.y - viewport.height / 2
        ))
    }
}

// MARK: - Groups (membership lives on the item; pure queries + mutations)

public extension Canvas {
    /// The ids of every pane belonging to `groupID` (or, when `groupID` is `nil`, every UNGROUPED
    /// pane), in the canonical ``allIDs()`` order so the sidebar section + canvas box are deterministic.
    func ids(inGroup groupID: PaneGroupID?) -> [PaneID] {
        allIDs().filter { id in item(id)?.groupID == groupID }
    }

    /// The set of group ids actually referenced by at least one item — used to prune dangling group
    /// metadata (a `PaneGroup` whose every member was closed) on load / save.
    func groupIDsInUse() -> Set<PaneGroupID> {
        Set(items.compactMap(\.groupID))
    }

    /// The tight canvas-space bounding box around every pane in `groupID`, or `nil` when the group has
    /// no members. The view insets/labels it for the Figma-style group frame.
    func groupBoundingBox(_ groupID: PaneGroupID) -> CGRect? {
        let frames = items.filter { $0.groupID == groupID }.map(\.frame)
        guard var box = frames.first else { return nil }
        for f in frames.dropFirst() { box = box.union(f) }
        return box
    }

    /// Assigns pane `id` to `groupID` (or ungroups it when `groupID` is `nil`). Disjoint by
    /// construction — a pane carries exactly one optional `groupID`, so re-assigning moves it. No-op if
    /// absent or already in that group.
    func assigning(_ id: PaneID, toGroup groupID: PaneGroupID?) -> Canvas {
        guard let existing = item(id), existing.groupID != groupID else { return self }
        return mapItem(id) { $0.groupID = groupID }
    }

    /// Clears membership for every pane in `groupID` (the model side of deleting a group — the members
    /// survive as ungrouped panes). Identity if no pane is in the group.
    func clearingGroup(_ groupID: PaneGroupID) -> Canvas {
        guard items.contains(where: { $0.groupID == groupID }) else { return self }
        return Canvas(
            items: items.map { item in
                guard item.groupID == groupID else { return item }
                var copy = item
                copy.groupID = nil
                return copy
            },
            camera: camera
        )
    }
}

// MARK: - Non-overlap collision bodies + commit application (pure)

public extension Canvas {
    /// The collision bodies for a non-overlap drag (``CanvasNonOverlap``): every UNGROUPED pane as a
    /// `.pane` body plus one `.group` body per group's derived bounding box — the "{ungrouped panes} ∪
    /// {group boxes}" set, so group-vs-group / pane-vs-group non-overlap falls out of feeding the group
    /// boxes into the SAME solver. `excludingPane` (the dragged pane) and `excludingGroup` (its own group,
    /// so a member never collides with its own group box) are filtered out. Bounded to `region` (the
    /// caller passes the viewport expanded by a small margin) so the body count stays ~O(visible).
    func collisionBodies(
        excludingPane: PaneID?,
        excludingGroup: PaneGroupID?,
        region: CGRect,
        groups: [PaneGroup]
    ) -> [CanvasNonOverlap.Body] {
        var bodies: [CanvasNonOverlap.Body] = []
        for item in items where item.groupID == nil && item.id != excludingPane && item.frame.intersects(region) {
            bodies.append(CanvasNonOverlap.Body(id: .pane(item.id), rect: item.frame))
        }
        for group in groups where group.id != excludingGroup {
            if let box = groupBoundingBox(group.id), box.intersects(region) {
                bodies.append(CanvasNonOverlap.Body(id: .group(group.id), rect: box))
            }
        }
        return bodies
    }

    /// Applies a ``CanvasNonOverlap/CommitResult`` to the canvas in ONE pure mutation: a `.pane` body sets
    /// that pane's frame (move only — its size is preserved); a `.group` body distributes its box's shift
    /// RIGIDLY to every member (so the derived box follows for free and the group's internal layout is
    /// untouched). Every output frame is sanitized.
    func applying(_ result: CanvasNonOverlap.CommitResult, groups: [PaneGroup]) -> Canvas {
        var paneOrigin: [PaneID: CGPoint] = [:]
        var groupDelta: [PaneGroupID: CGSize] = [:]
        for (bodyID, newRect) in result.frames {
            switch bodyID {
            case .pane(let id):
                paneOrigin[id] = newRect.origin
            case .group(let gid):
                if let box = groupBoundingBox(gid) {
                    groupDelta[gid] = CGSize(width: newRect.minX - box.minX, height: newRect.minY - box.minY)
                }
            }
        }
        guard !paneOrigin.isEmpty || !groupDelta.isEmpty else { return self }
        let newItems = items.map { item -> CanvasItem in
            var copy = item
            if let origin = paneOrigin[item.id] {
                copy.frame = Canvas.sanitize(CGRect(origin: origin, size: item.frame.size))
            } else if let gid = item.groupID, let d = groupDelta[gid] {
                copy.frame = Canvas.sanitize(item.frame.offsetBy(dx: d.width, dy: d.height))
            }
            return copy
        }
        return Canvas(items: newItems, camera: camera)
    }

    /// Translates every member of `groupID` by `delta` (the group-handle drag-to-move). The derived
    /// ``groupBoundingBox(_:)`` follows for free; the group's internal layout is untouched (a rigid move).
    func movingGroup(_ groupID: PaneGroupID, by delta: CGSize) -> Canvas {
        guard delta != .zero else { return self }
        return Canvas(items: items.map { item in
            guard item.groupID == groupID else { return item }
            var copy = item
            copy.frame = Canvas.sanitize(item.frame.offsetBy(dx: delta.width, dy: delta.height))
            return copy
        }, camera: camera)
    }

    /// Affinely remaps every member of `groupID` from its CURRENT bounding box into `newBox` (the
    /// group-handle resize): each member's origin offset within the box and its size scale by the per-axis
    /// ratio, so the group's footprint becomes `newBox` while its relative layout is preserved (the
    /// "resize a grouped selection" semantics). Member sizes floor at ``minItemSize`` via `sanitize`.
    /// Identity when the group is empty or degenerate.
    func resizingGroup(_ groupID: PaneGroupID, toBox newBox: CGRect) -> Canvas {
        guard let oldBox = groupBoundingBox(groupID), oldBox.width > 0, oldBox.height > 0 else { return self }
        let sx = newBox.width / oldBox.width
        let sy = newBox.height / oldBox.height
        return Canvas(items: items.map { item in
            guard item.groupID == groupID else { return item }
            var copy = item
            copy.frame = Canvas.sanitize(CGRect(
                x: newBox.minX + (item.frame.minX - oldBox.minX) * sx,
                y: newBox.minY + (item.frame.minY - oldBox.minY) * sy,
                width: item.frame.width * sx,
                height: item.frame.height * sy
            ))
            return copy
        }, camera: camera)
    }
}

// MARK: - SolvedLayout (FocusResolver reuse — the resolver is UNCHANGED)

public extension Canvas {
    /// A ``SolvedLayout`` for ``FocusResolver``: the items' **canvas-space** frames (camera-independent,
    /// so directional focus is stable across pans and an off-viewport pane stays keyboard-navigable).
    /// `FocusResolver.neighbor`/`cycle` consume `frames`, so they work verbatim.
    func solvedLayout() -> SolvedLayout {
        SolvedLayout(frames: framesByID())
    }
}
