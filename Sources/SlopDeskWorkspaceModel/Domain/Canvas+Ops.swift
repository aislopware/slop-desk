import CoreGraphics
import CSlopDeskFFI
import Foundation

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
                newItems.append(CanvasItem(
                    id: fresh,
                    spec: item.spec,
                    frame: item.frame,
                    z: item.z,
                    groupID: item.groupID,
                ))
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
        size: CGSize = Canvas.defaultItemSize,
    ) -> (Canvas, PaneID) {
        let id = PaneID()
        let nearFrame = near.flatMap { frame(of: $0) }
        let viewportRect = CGRect(origin: camera.origin, size: viewport)
        let placed = CanvasGeometry.placement(
            near: nearFrame,
            existing: items.map(\.frame),
            viewport: viewportRect,
            size: size,
        )
        let item = CanvasItem(id: id, spec: spec, frame: Self.sanitize(placed), z: maxZ + 1)
        return (Canvas(items: items + [item], camera: camera), id)
    }

    /// Re-adds a previously-closed pane at its EXACT former frame (the close-undo restore), frontmost.
    /// A FRESH id is minted deliberately: the closed pane's session teardown is async, so reusing the
    /// old ``PaneID`` could race the in-flight teardown's registry/cap bookkeeping — and a reopened
    /// pane's session is a NEW session anyway (scrollback does not survive; the menu says "Reopen",
    /// not "Undo"). `group` is the caller-validated group to rejoin (`nil` = ungrouped).
    func restoring(_ spec: PaneSpec, frame: CGRect, group: PaneGroupID?) -> (Canvas, PaneID) {
        let id = PaneID()
        let item = CanvasItem(id: id, spec: spec, frame: Self.sanitize(frame), z: maxZ + 1, groupID: group)
        return (Canvas(items: items + [item], camera: camera), id)
    }

    /// Removes `id`; returns `nil` iff it was the **last** item (the tab empties — the exact
    /// `PaneNode.closing → nil` contract the store relies on to close the tab). Surviving items keep
    /// their z verbatim (z is order-independent, so no renumber is needed).
    func removing(_ id: PaneID) -> Canvas? {
        let survivors = items.filter { $0.id != id }
        if survivors.count == items.count { return self } // id absent — unchanged
        if survivors.isEmpty { return nil } // emptied the tab
        return Canvas(items: survivors, camera: camera)
    }

    /// Translates `id`'s frame by `delta` (the chrome drag-to-move commit), clamped finite. No raise
    /// (the store composes `raising` so the policy lives in one place).
    func moving(_ id: PaneID, by delta: CGSize) -> Canvas {
        mapItem(id) { item in
            item.frame = Self.sanitize(item.frame.offsetBy(dx: delta.width, dy: delta.height))
        }
    }

    /// Moves `id`'s frame origin to `origin` (clamped finite).
    func moving(_ id: PaneID, to origin: CGPoint) -> Canvas {
        mapItem(id) { item in
            item.frame = Self.sanitize(CGRect(origin: origin, size: item.frame.size))
        }
    }

    /// Sets `id`'s frame (the corner/edge resize commit), sanitized so size ≥ ``minItemSize`` and finite.
    func resizing(_ id: PaneID, to frame: CGRect) -> Canvas {
        mapItem(id) { item in item.frame = Self.sanitize(frame) }
    }

    /// Brings `id` to the front: `z = maxZ + 1`. A no-op (returns `self`) if `id` is already the top
    /// (or absent), so a redundant focus does not churn the value / persistence.
    func raising(_ id: PaneID) -> Canvas {
        guard let item = item(id) else { return self }
        let top = maxZ
        if item.z == top, items.count(where: { $0.z == top }) == 1 { return self } // already uniquely top
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
            camera: camera,
        )
    }
}

// MARK: - Arrange: align + distribute (pure)

/// Which edge/centre the panes are aligned to.
///
/// The case ORDER is a cross-language contract — it crosses to `rust/slopdesk-workspace` as a byte,
/// and `scripts/check-supervisor.sh` pins it so a reordering fails the build rather than aligning to
/// the wrong edge.
public enum AlignEdge: Sendable, CaseIterable,
    Equatable { case left, right, top, bottom, centerHorizontal, centerVertical }

/// The three arrange commands are `rust/slopdesk-workspace`'s `canvas_arrange` (docs/55). They read a
/// pane's id and its frame and write a frame — never a spec, a group, a z or the camera — so what
/// crosses is that projection and the plane itself stays here, where SwiftUI diffs it.
public extension Canvas {
    /// Aligns the panes named by `ids` to the shared edge/centre of THEIR bounding box (Figma's
    /// align-left / align-centre / …). Only the moved axis changes; the perpendicular axis and every
    /// size stay put. Panes not in `ids` are untouched. No-op for fewer than 2 targets.
    func aligning(_ ids: [PaneID], to edge: AlignEdge) -> Canvas {
        applying(arranged(ids) { targets, out, cap in
            slopdesk_ws_align(targets.baseAddress, targets.count, edge.ffiByte, out, cap)
        })
    }

    /// Distributes the panes named by `ids` so the GAPS between adjacent panes along `horizontal`/
    /// vertical are equal (Figma's distribute-spacing). The two extreme panes stay put; the interior
    /// ones move. No-op for fewer than 3 targets (nothing interior to redistribute).
    ///
    /// When the panes are collectively WIDER than their spread the ideal even gap is NEGATIVE, which
    /// would silently OVERLAP them. It is clamped to ≥ 0 instead, so they pack flush and the trailing
    /// extreme shifts rather than the panes overlapping.
    ///
    /// One behaviour was narrowed on the way across, deliberately: panes sharing a leading edge
    /// exactly used to keep whatever order `items` happened to be in, and now break the tie by id. The
    /// spread is a function of the SET either way, which it was not before.
    func distributing(_ ids: [PaneID], horizontal: Bool) -> Canvas {
        applying(arranged(ids) { targets, out, cap in
            slopdesk_ws_distribute(targets.baseAddress, targets.count, horizontal, out, cap)
        })
    }

    // MARK: Marshalling

    /// Runs an arrange command over the panes named by `ids`, in this plane's own item order.
    private func arranged(
        _ ids: [PaneID],
        _ call: (UnsafeMutableBufferPointer<SlopDeskWsFrame>, UnsafeMutablePointer<SlopDeskWsFrame>?, Int) -> Int,
    ) -> [PaneID: CGRect] {
        let idSet = Set(ids)
        var targets = items.filter { idSet.contains($0.id) }
            .map { SlopDeskWsFrame(id: $0.id.ffi, rect: SlopDeskWsRect($0.frame)) }
        return targets.withUnsafeMutableBufferPointer { buffer in
            moved { out, cap in call(buffer, out, cap) }
        }
    }

    /// Reads the frames a command moved, with the retry docs/55 §4 describes.
    private func moved(_ call: (UnsafeMutablePointer<SlopDeskWsFrame>?, Int) -> Int) -> [PaneID: CGRect] {
        var out = [SlopDeskWsFrame](repeating: SlopDeskWsFrame(), count: max(16, items.count))
        var needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        if needed > out.count {
            out = [SlopDeskWsFrame](repeating: SlopDeskWsFrame(), count: needed)
            needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        }
        guard needed > 0, needed <= out.count else { return [:] }
        var frames: [PaneID: CGRect] = [:]
        for frame in out[0..<needed] {
            frames[PaneID(ffi: frame.id)] = frame.rect.rect
        }
        return frames
    }

    /// This plane with each named pane at its new frame. A pane nobody named is untouched, and an
    /// empty answer is the plane itself rather than a copy that happened to reproduce it.
    private func applying(_ frames: [PaneID: CGRect]) -> Canvas {
        guard !frames.isEmpty else { return self }
        return Canvas(items: items.map { item in
            guard let frame = frames[item.id] else { return item }
            var copy = item
            copy.frame = frame
            return copy
        }, camera: camera)
    }
}

extension AlignEdge {
    /// The CASE index — the crate's enum order, pinned by `scripts/check-supervisor.sh`.
    var ffiByte: UInt8 {
        switch self {
        case .left: 0
        case .right: 1
        case .top: 2
        case .bottom: 3
        case .centerHorizontal: 4
        case .centerVertical: 5
        }
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
    func tidied(gutter: CGFloat = Canvas.tidyGutter, viewport: CGSize) -> Canvas {
        guard items.count > 1 else { return centeredOnAll(viewport: viewport) }
        let order = allIDs()
        let framed = order.compactMap { id in frame(of: id).map { (id, $0) } }
        var packed = framed.map { SlopDeskWsFrame(id: $0.0.ffi, rect: SlopDeskWsRect($0.1)) }
        let grid = packed.withUnsafeMutableBufferPointer { buffer in
            moved { out, cap in
                slopdesk_ws_tidy(buffer.baseAddress, buffer.count, gutter, out, cap)
            }
        }
        return applying(grid).centeredOnAll(viewport: viewport)
    }

    /// The gap a tidy leaves between packed panes, exported by the crate rather than transcribed.
    static var tidyGutter: CGFloat { slopdesk_ws_tidy_gutter() }

    /// The bounding box that contains every item's frame, or `nil` when empty.
    private func itemsBoundingBox() -> CGRect? {
        var frames = items.map { SlopDeskWsRect($0.frame) }
        var answer = SlopDeskWsRect()
        let found = frames.withUnsafeMutableBufferPointer { buffer in
            slopdesk_ws_bounding_box(buffer.baseAddress, buffer.count, &answer)
        }
        return found ? answer.rect : nil
    }

    /// The camera whose viewport is centred on the canvas-space `point`.
    private static func camera(centeredOn point: CGPoint, viewport: CGSize) -> CanvasCamera {
        CanvasCamera(origin: CGPoint(
            x: point.x - viewport.width / 2,
            y: point.y - viewport.height / 2,
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

    /// The set of group ids actually referenced by at least one item.
    ///
    /// No caller, and it should not get one for the reason it used to give. This said it existed to
    /// "prune dangling group metadata (a `PaneGroup` whose every member was closed) on load / save",
    /// which reads as an unfinished feature and was reported as one. It is not: `Workspace`'s own
    /// `normalizingGroups()` decides the opposite in as many words — *"Empty groups are KEPT (a user
    /// may create a group before assigning panes)"* — and repairs only the other direction, an item
    /// pointing at a group that is gone. Wiring this in would delete a group the user made on purpose
    /// and had not filled yet.
    ///
    /// What is left is a membership query with no asker. It stays because the repair rule above is
    /// the kind that grows a second, contradictory implementation the moment someone needs the set
    /// and does not find one — and now the contradiction is written down where they would look.
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
            camera: camera,
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
        groups: [PaneGroup],
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
    func applying(_ result: CanvasNonOverlap.CommitResult, groups _: [PaneGroup]) -> Canvas {
        var paneOrigin: [PaneID: CGPoint] = [:]
        var groupDelta: [PaneGroupID: CGSize] = [:]
        for (bodyID, newRect) in result.frames {
            switch bodyID {
            case let .pane(id):
                paneOrigin[id] = newRect.origin
            case let .group(gid):
                if let box = groupBoundingBox(gid) {
                    groupDelta[gid] = CGSize(width: newRect.minX - box.minX, height: newRect.minY - box.minY)
                }
            }
        }
        guard !paneOrigin.isEmpty || !groupDelta.isEmpty else { return self }
        let newItems = items.map { item -> CanvasItem in
            var copy = item
            if let origin = paneOrigin[item.id] {
                copy.frame = Self.sanitize(CGRect(origin: origin, size: item.frame.size))
            } else if let gid = item.groupID, let d = groupDelta[gid] {
                copy.frame = Self.sanitize(item.frame.offsetBy(dx: d.width, dy: d.height))
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
            copy.frame = Self.sanitize(item.frame.offsetBy(dx: delta.width, dy: delta.height))
            return copy
        }, camera: camera)
    }

    /// Affinely remaps every member of `groupID` from its CURRENT bounding box into `proposedBox` (the
    /// group-handle resize): each member's origin offset within the box and its size scale by the per-axis
    /// ratio, so the group's footprint becomes the new box while its relative layout is preserved.
    ///
    /// The rule itself — floor the box at the minimum pane size, clamp every member back inside it, so a
    /// sub-floor box cannot spill members outside the body the non-overlap solver drags — lives in
    /// `canvas_arrange::resized_group` and is stated once, there. It used to be stated twice, and the two
    /// copies did not even agree on `min`: this side's `Swift.min` is `<`-ordered where the crate's is
    /// IEEE `minNum`, so they parted on ±0 and NaN.
    ///
    /// The old box is NOT passed across — the crate derives it from the members it was handed, so there is
    /// no second box to compute here and get wrong. A group with no members or no extent answers nothing
    /// moved, which ``applying(_:)`` turns back into this plane unchanged.
    func resizingGroup(_ groupID: PaneGroupID, toBox proposedBox: CGRect) -> Canvas {
        applying(arranged(ids(inGroup: groupID)) { targets, out, cap in
            slopdesk_ws_resize_group(targets.baseAddress, targets.count, SlopDeskWsRect(proposedBox), out, cap)
        })
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
