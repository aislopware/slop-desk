import Foundation
import CoreGraphics

// MARK: - Readable wire shape for CoreGraphics values

// `CGPoint`/`CGSize`/`CGRect` synthesize an OPAQUE array Codable (`[x, y]`, `[[x,y],[w,h]]`) — not the
// human-reviewable object shape the persistence format documents (docs/30 §4.1). These tiny mirrors
// give the canvas a self-describing `{ "x": …, "y": … }` / `{ "origin": …, "size": … }` wire shape.
private struct WirePoint: Codable {
    var x: CGFloat
    var y: CGFloat
    init(_ p: CGPoint) { x = p.x; y = p.y }
    var point: CGPoint { CGPoint(x: x, y: y) }
}
private struct WireSize: Codable {
    var width: CGFloat
    var height: CGFloat
    init(_ s: CGSize) { width = s.width; height = s.height }
    var size: CGSize { CGSize(width: width, height: height) }
}
private struct WireRect: Codable {
    var origin: WirePoint
    var size: WireSize
    init(_ r: CGRect) { origin = WirePoint(r.origin); size = WireSize(r.size) }
    var rect: CGRect { CGRect(origin: origin.point, size: size.size) }
}

// MARK: - CanvasCamera (origin as a readable {x,y})

public extension CanvasCamera {
    private enum CodingKeys: String, CodingKey { case origin }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(origin: try c.decode(WirePoint.self, forKey: .origin).point)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(WirePoint(origin), forKey: .origin)
    }
}

// MARK: - CanvasItem (frame as a readable {origin:{x,y}, size:{width,height}})

public extension CanvasItem {
    private enum CodingKeys: String, CodingKey { case id, spec, frame, z, groupID }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(PaneID.self, forKey: .id),
            spec: try c.decode(PaneSpec.self, forKey: .spec),
            frame: try c.decode(WireRect.self, forKey: .frame).rect,
            z: try c.decode(Int.self, forKey: .z),
            // Optional so an ungrouped pane (and any pre-group file) round-trips: absent ⇒ ungrouped.
            groupID: try c.decodeIfPresent(PaneGroupID.self, forKey: .groupID)
        )
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(spec, forKey: .spec)
        try c.encode(WireRect(frame), forKey: .frame)
        try c.encode(z, forKey: .z)
        // Omit the key entirely for an ungrouped pane (keeps the JSON minimal + the round-trip stable).
        try c.encodeIfPresent(groupID, forKey: .groupID)
    }
}

// MARK: - Defensive Codable for Canvas (invariant enforcement on decode)

/// ``Canvas`` is flat (no recursion), so a synthesized `Codable` would be perfectly correct — but the
/// canvas IS the persistence format (docs/30 §4), and a corrupt / hand-edited file must FAIL the
/// decode so ``WorkspacePersistence/load()`` falls back cleanly (and writes the `.corrupt` sidecar)
/// rather than letting a degenerate `Canvas` reach the renderer. So `Canvas` gets a thin hand-written
/// `init(from:)`/`encode(to:)` that mirrors the legacy `PaneNode+Codable` `children.count >= 2`
/// guard: it rejects a zero-item canvas and sanitizes every frame (finite origin, size clamped ≥
/// ``Canvas/minItemSize``) so a NaN / zero / infinite frame can never render.
///
/// `CanvasItem` / `CanvasCamera` keep their SYNTHESIZED `Codable` (flat structs over Codable
/// CoreGraphics types — safe to synthesize). The wire shape stays stable + reviewable under the
/// encoder's `.sortedKeys` / `.prettyPrinted` (docs/30 §4.1).
public extension Canvas {
    private enum CodingKeys: String, CodingKey {
        case items
        case camera
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawItems = try container.decode([CanvasItem].self, forKey: .items)
        // The camera is optional on the wire so a hand-authored / older-but-v2 file without it decodes
        // to the zero (un-panned) camera rather than failing. Sanitized so a corrupt non-finite/extreme
        // origin can never later overflow or make a save throw.
        let camera = (try container.decodeIfPresent(CanvasCamera.self, forKey: .camera) ?? .zero).sanitized()

        // An EMPTY canvas is now a valid state — it is the single workspace root (docs/31), not a tab's
        // canvas, so when the user closes the last pane the canvas legitimately has zero items and must
        // round-trip (→ the "Add a pane" empty state on reload). (Was a hard decode failure when a
        // canvas could only exist inside a non-empty tab.)

        // Sanitize each frame on the way in: a NaN / infinite / sub-minimum frame must never reach the
        // layout. (Duplicate ids are repaired separately — losslessly re-minted — at `load()` time via
        // `dedupingItemIDs`, since the registry is keyed 1:1 by PaneID.)
        let sanitized = rawItems.map { item -> CanvasItem in
            var copy = item
            copy.frame = Canvas.sanitize(item.frame)
            return copy
        }
        self.init(items: sanitized, camera: camera)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(camera, forKey: .camera)
    }
}

// MARK: - Frame sanitation

public extension Canvas {
    /// Returns `frame` with a finite origin and a size floored to ``minItemSize``; a non-finite
    /// (NaN / ±inf) origin coordinate collapses to 0 and a non-finite / sub-minimum extent collapses to
    /// the corresponding ``minItemSize`` component. Total + pure: every output rect is finite with
    /// `size ≥ minItemSize`, so it is always safe to render and to drive a terminal reflow.
    static func sanitize(_ frame: CGRect) -> CGRect {
        let b = coordinateBound
        // Origin: NaN/inf → 0, then clamp magnitude so a bounding-box union can never overflow to ±inf.
        let x = frame.origin.x.isFinite ? min(max(frame.origin.x, -b), b) : 0
        let y = frame.origin.y.isFinite ? min(max(frame.origin.y, -b), b) : 0
        // Size: floor to minItemSize, cap at the bound; NaN/inf → minItemSize.
        let w = frame.size.width.isFinite ? min(max(frame.size.width, minItemSize.width), b) : minItemSize.width
        let h = frame.size.height.isFinite ? min(max(frame.size.height, minItemSize.height), b) : minItemSize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
