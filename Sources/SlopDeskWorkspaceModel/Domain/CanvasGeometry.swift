import CoreGraphics
import CSlopDeskFFI

// MARK: - Resize anchors

/// Which corner / edge of an item is being dragged during a resize (docs/30 §3). The opposite
/// edge(s) stay pinned; the anchored edge(s) follow the drag.
///
/// The case ORDER is a cross-language contract — it crosses to `rust/slopdesk-workspace` as a byte,
/// and `scripts/check-supervisor.sh` pins it so a reordering fails the build rather than resizing
/// from the wrong corner.
public enum ResizeAnchor: Sendable, CaseIterable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight
}

// MARK: - Canvas geometry

/// The infinite canvas's geometry: the camera transform (a rigid translate), the 8-anchor resize
/// math, new-pane placement, the kind-aware culling decision, the fit-everything overview and the
/// off-screen beacons.
///
/// Every rule here is `rust/slopdesk-workspace`'s `geometry` and `canvas_geometry` (docs/55). What
/// stays in Swift is the shape of the ANSWER — an ``OverviewLayout`` is what a view iterates, and a
/// `CanvasItem` is the document — so the marshalling below projects each item down to the three
/// facts these rules actually read: its id, its frame, and whether it costs a decode slot.
public enum CanvasGeometry {
    // MARK: Camera transform

    /// The on-screen rect for a canvas-space frame under `camera` — a **pure translate**: the extents
    /// are copied verbatim (1:1, no scale) and the origin is shifted. This is the single canvas↔screen
    /// mapping, and keeping it one function is what pins the pan-only invariant.
    public static func screenRect(_ f: CGRect, camera: CanvasCamera) -> CGRect {
        slopdesk_ws_screen_rect(SlopDeskWsRect(f), SlopDeskWsPoint(camera.origin)).rect
    }

    /// The inverse: the canvas-space point for an on-screen point under `camera`.
    public static func canvasPoint(_ p: CGPoint, camera: CanvasCamera) -> CGPoint {
        slopdesk_ws_canvas_point(SlopDeskWsPoint(p), SlopDeskWsPoint(camera.origin)).point
    }

    // MARK: Resize

    /// The new frame while dragging `anchor` by `delta`: the anchored edge(s) move, the opposite
    /// edge(s) stay pinned, and width/height are floored to `minSize` — clamping pushes the *moved*
    /// edge back, so the pinned edge never shifts.
    public static func resizing(
        _ frame: CGRect,
        anchor: ResizeAnchor,
        by delta: CGSize,
        minSize: CGSize,
    ) -> CGRect {
        slopdesk_ws_resizing(
            SlopDeskWsRect(frame),
            anchor.ffiByte,
            delta.width,
            delta.height,
            minSize.width,
            minSize.height,
        ).rect
    }

    // MARK: New-pane placement

    /// The fraction of overlap (relative to the candidate's own area) at or above which a placement
    /// counts as colliding and must be nudged.
    public static let overlapThreshold: CGFloat = 0.25

    /// A clean canvas-space frame for a NEW pane of `size`:
    /// - seeded at `near.origin + (cascade, cascade)` (the `NSWindow.cascadeTopLeft` convention) when
    ///   splitting off a focused pane, else at the centre of `viewport` (in canvas space);
    /// - then cascade-stepped while it overlaps ANY `existing` frame by more than
    ///   ``overlapThreshold`` of its own area;
    /// - and behind the step cap, a bounded grid scan that guarantees a non-overlapping slot, so this
    ///   terminates rather than merely usually terminating.
    ///
    /// The store separately composes ``Canvas/centered(on:viewport:)`` for the in-view guarantee, so
    /// this only needs to avoid stacking exactly on top of another pane.
    public static func placement(
        near: CGRect?,
        existing: [CGRect],
        viewport: CGRect,
        size: CGSize,
        cascade: CGFloat = Canvas.cascadeStep,
    ) -> CGRect {
        var rects = existing.map(SlopDeskWsRect.init)
        return rects.withUnsafeMutableBufferPointer { buffer in
            slopdesk_ws_placement(
                SlopDeskWsRect(near ?? .zero),
                near != nil,
                buffer.baseAddress,
                buffer.count,
                SlopDeskWsRect(viewport),
                size.width,
                size.height,
                cascade,
            ).rect
        }
    }

    // MARK: Culling

    /// The items to keep mounted. A terminal always stays — the compositor occludes an off-viewport
    /// view cheaply anyway, so it simply repaints — and a video pane only while it is near the
    /// viewport, because culling one frees a real decode slot. The focused pane is never culled
    /// whatever its kind.
    public static func visibleItems(
        _ items: [CanvasItem],
        camera: CanvasCamera,
        viewport: CGSize,
        focused: PaneID?,
        margin: CGFloat = Canvas.cullMargin,
    ) -> [CanvasItem] {
        items.filter { item in
            slopdesk_ws_pane_visible(
                item.placed,
                SlopDeskWsPoint(camera.origin),
                viewport.width,
                viewport.height,
                focused?.ffi ?? SlopDeskWsUuid(),
                focused != nil,
                margin,
            )
        }
    }

    /// The ids whose frame intersects the viewport (NO margin, NO kind filter) — the video-cap "on
    /// screen" signal the store consumes. Kept a separate question from ``visibleItems(_:camera:viewport:focused:margin:)``
    /// so terminals being held mounted does not pollute the membership set.
    public static func viewportMembers(
        _ items: [CanvasItem],
        camera: CanvasCamera,
        viewport: CGSize,
    ) -> Set<PaneID> {
        var members: Set<PaneID> = []
        for item in items where slopdesk_ws_pane_in_viewport(
            SlopDeskWsRect(item.frame),
            SlopDeskWsPoint(camera.origin),
            viewport.width,
            viewport.height,
        ) {
            members.insert(item.id)
        }
        return members
    }

    // MARK: Overview (fit-all "Mission Control")

    /// The uniform scale that fits every pane into the viewport, and each pane's screen-space card
    /// under it. The view renders STATIC cards at these rects — no live-surface `scaleEffect`, so no
    /// Metal/libghostty transform hazard.
    public struct OverviewLayout: Equatable, Sendable {
        public let scale: CGFloat
        public let cards: [PaneID: CGRect]
    }

    /// The overview layout: the bounding box of ALL panes fitted into the viewport (with `padding`
    /// inset, never magnified past 1×), the scaled box centred.
    public static func overviewLayout(
        _ items: [CanvasItem],
        viewport: CGSize,
        padding: CGFloat = 48,
    ) -> OverviewLayout {
        var scale = 1.0
        let cards: [(PaneID, CGRect)] = withPlaced(items) { panes in
            answers(SlopDeskWsCard()) { out, cap in
                slopdesk_ws_overview_layout(
                    panes.baseAddress,
                    panes.count,
                    viewport.width,
                    viewport.height,
                    padding,
                    &scale,
                    out,
                    cap,
                )
            }
            .map { (PaneID(ffi: $0.id), $0.rect.rect) }
        }
        return OverviewLayout(scale: scale, cards: Dictionary(uniqueKeysWithValues: cards))
    }

    // MARK: Off-screen beacons

    /// A glass pill on the viewport border saying "a pane is over there", which pans to it on click.
    public struct OffscreenBeacon: Equatable, Sendable {
        public let id: PaneID
        /// On-screen point (viewport coordinates) at which to centre the pill — already clamped
        /// inside the `inset` margin on all sides, so it never clips.
        public let screenPoint: CGPoint
        /// The viewport edge the off-screen pane lies past (drives the little direction arrow).
        public let edge: Edge
        public enum Edge: Sendable { case top, bottom, left, right }
    }

    /// Every pane whose frame does NOT intersect the viewport, projected onto the viewport border.
    /// The DOMINANT overflow picks the edge, so a pane far up and slightly right reads as "above"
    /// rather than flickering between the two. Panes that intersect get no beacon — they are visible.
    public static func offscreenBeacons(
        _ items: [CanvasItem],
        camera: CanvasCamera,
        viewport: CGSize,
        inset: CGFloat = 18,
    ) -> [OffscreenBeacon] {
        withPlaced(items) { panes in
            answers(SlopDeskWsBeacon()) { out, cap in
                slopdesk_ws_offscreen_beacons(
                    panes.baseAddress,
                    panes.count,
                    SlopDeskWsPoint(camera.origin),
                    viewport.width,
                    viewport.height,
                    inset,
                    out,
                    cap,
                )
            }
            .map { beacon in
                let edge: OffscreenBeacon.Edge =
                    switch beacon.edge {
                    case 0: .top
                    case 1: .bottom
                    case 2: .left
                    default: .right
                    }
                return OffscreenBeacon(
                    id: PaneID(ffi: beacon.id),
                    screenPoint: beacon.screen_point.point,
                    edge: edge,
                )
            }
        }
    }

    // MARK: - Marshalling

    /// Lends the items as the three facts these rules read, for exactly one call.
    private static func withPlaced<T>(
        _ items: [CanvasItem],
        _ body: (UnsafeMutableBufferPointer<SlopDeskWsPlaced>) -> T,
    ) -> T {
        var panes = items.map(\.placed)
        return panes.withUnsafeMutableBufferPointer { buffer in body(buffer) }
    }

    /// Reads a variable-length answer with the retry docs/55 §4 describes.
    private static func answers<Element>(
        _ empty: Element,
        _ call: (UnsafeMutablePointer<Element>?, Int) -> Int,
    ) -> [Element] {
        var out = [Element](repeating: empty, count: 16)
        var needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        if needed > out.count {
            out = [Element](repeating: empty, count: needed)
            needed = out.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count) }
        }
        guard needed > 0, needed <= out.count else { return [] }
        return Array(out[0..<needed])
    }
}

private extension CanvasItem {
    /// The pane as the geometry rules see it. A `CanvasItem` carries its spec, its group and its z,
    /// none of which any of them consults — so what crosses is this projection, not the document.
    var placed: SlopDeskWsPlaced {
        SlopDeskWsPlaced(id: id.ffi, rect: SlopDeskWsRect(frame), is_video: spec.kind.isVideo)
    }
}
