import Foundation
import CoreGraphics

// MARK: - The pan-only camera

/// The viewport's pan offset over one tab's infinite plane: the **canvas-space point shown at the
/// viewport's top-left** (screen = canvas − origin, a rigid translate). Pan-only by construction —
/// there is NO scale field, so a whole-board zoom is structurally unrepresentable (docs/30 §1).
///
/// Why no scale: a libghostty terminal surface sizes itself from its hosting view's
/// `bounds × contentsScale` in POINTS and pins `layer.bounds == view.bounds`
/// (`GhosttyTerminalView.layout()`); applying a `scaleEffect` / `CGAffineTransform` to any ancestor
/// of a surface would desync that and break the points-with-y-flip 1:1 mouse mapping. Omitting the
/// field is the strongest possible enforcement of the pan-only invariant.
public struct CanvasCamera: Codable, Sendable, Equatable {
    /// Canvas-space point shown at the viewport's top-left.
    public var origin: CGPoint
    public init(origin: CGPoint = .zero) { self.origin = origin }

    /// The zero camera (viewport top-left at the canvas origin).
    public static let zero = CanvasCamera(origin: .zero)

    /// A new camera translated by `delta` (origin += delta). Pure — no scale term, so a screen-space
    /// translation IS the canvas-space delta.
    public func translated(by delta: CGSize) -> CanvasCamera {
        CanvasCamera(origin: CGPoint(x: origin.x + delta.width, y: origin.y + delta.height))
    }
}

// MARK: - One item on the plane

/// One pane placed on a tab's infinite plane (replaces a `PaneNode` leaf). Pure value type holding
/// no live object (docs/30 §2).
///
/// The `id` is the SAME ``PaneID`` join key the registry / `reconcile()` / `.id(PaneID)` view
/// identity all reuse verbatim — only the *source* of "all pane ids" moved from `PaneNode.allLeafIDs`
/// to ``Canvas/allIDs()``. The `frame`'s width/height ARE the pane's 1:1 on-screen size, which drives
/// the terminal host's `.frame` → `layout()` → `setPixelSize` → cols×rows reflow (the existing resize
/// path; there is no new resize API). Stacking is the explicit `z` (NOT array order — see ``Canvas``).
public struct CanvasItem: Identifiable, Codable, Sendable, Equatable {
    /// Stable pane identity (the registry / `reconcile` / `.id(PaneID)` join key).
    public let id: PaneID
    /// Pure intent (kind / title / endpoint / video). Unchanged value type.
    public var spec: PaneSpec
    /// Canvas-space rect; `origin` may be negative (the plane is unbounded). `size` is the pane's 1:1
    /// on-screen size. Always finite, with `size ≥ Canvas.minItemSize` (enforced on decode + by every
    /// mutation op).
    public var frame: CGRect
    /// Explicit z-order; **higher == frontmost** (the focused / last-dragged pane floats to top).
    public var z: Int
    /// The ``PaneGroup`` this pane belongs to, or `nil` for an ungrouped pane. Disjoint membership: a
    /// pane is in at most one group. `nil` by default (a brand-new pane is ungrouped). Closing the pane
    /// drops the membership for free; deleting the group clears this back to `nil`.
    public var groupID: PaneGroupID?

    public init(id: PaneID, spec: PaneSpec, frame: CGRect, z: Int, groupID: PaneGroupID? = nil) {
        self.id = id
        self.spec = spec
        self.frame = frame
        self.z = z
        self.groupID = groupID
    }
}

// MARK: - The free 2D plane (replaces PaneNode as a Tab's layout model)

/// One ``Tab``'s infinite plane: a flat set of free-floating ``CanvasItem``s plus the pan
/// ``CanvasCamera`` (docs/30 §2). Pure value type, `Codable`, the persistence format, holding no live
/// object — every mutation is a pure function returning a NEW `Canvas` (so ~85% of the canvas logic is
/// deterministically unit-testable with no client, exactly as the old `PaneNode` tree was).
///
/// Flat-not-recursive is the whole point: it removes the only reason `PaneNode`'s `Codable` had to be
/// hand-written (a recursive `indirect enum`), so the synthesized `Codable` is safe here (a thin
/// defensive `init(from:)` in `Canvas+Codable.swift` only enforces the invariants on decode).
///
/// ### Invariants (held by every op; enforced on decode, `Canvas+Codable.swift`)
/// - **Unique ids**: `items.map(\.id)` has no duplicates (decode keeps raw; `load()` re-mints any
///   duplicate via ``dedupingItemIDs(seen:)``, since the registry is keyed 1:1 by ``PaneID``).
/// - **Finite, on-floor frames**: every `frame` is finite and has `size ≥ minItemSize`.
/// - **Non-empty (for a live tab)**: ``removing(_:)`` of the last item returns `nil`, which the store
///   treats as "this tab emptied" — the exact `PaneNode.closing → nil` contract.
/// - **Pan-only camera**: `camera` is a translation; there is no scale field.
public struct Canvas: Codable, Sendable, Equatable {
    /// All items on the plane. Array order is **NOT** z-order — ``CanvasItem/z`` is the render order,
    /// so a re-mint / dedup / future reorder of this array can never silently restack the panes.
    public var items: [CanvasItem]
    /// The pan offset (view-state that also persists, debounced — exactly as split `fractions` did).
    public var camera: CanvasCamera

    public init(items: [CanvasItem], camera: CanvasCamera = .zero) {
        self.items = items
        self.camera = camera
    }
}

// MARK: - Metrics

public extension Canvas {
    /// Minimum item size in canvas points — equals the legacy `PaneTreeView.minLeaf` (160×120) so a
    /// pane's cols/rows never collapse below a usable grid.
    static let minItemSize = CGSize(width: 160, height: 120)
    /// Default size for a brand-new pane (a comfortable shell).
    static let defaultItemSize = CGSize(width: 640, height: 420)
    /// Cascade step for new-pane placement (one title-bar + margin; the `NSWindow.cascadeTopLeft`
    /// convention).
    static let cascadeStep: CGFloat = 28
    /// Off-viewport overscan kept mounted so a video pane about to pan in is already warm before it
    /// crosses the viewport edge (culling margin, docs/30 §1).
    static let cullMargin: CGFloat = 600
    /// The maximum finite magnitude any canvas coordinate (item origin / size, camera origin) is clamped
    /// to. Far beyond any real layout (~13k screens), but bounding it keeps a corrupt/hand-edited file
    /// with extreme-but-finite coords from overflowing to ±inf in a bounding-box union (which would make
    /// `JSONEncoder` throw and silently stop ALL persistence). Pairs with the NaN/inf collapse in
    /// ``sanitize(_:)``.
    static let coordinateBound: CGFloat = 1_000_000
}

// MARK: - Coordinate sanitation

public extension CanvasCamera {
    /// A camera whose origin is finite and within ``Canvas/coordinateBound`` — collapses NaN/±inf to 0
    /// and clamps extreme magnitudes, so a corrupt camera can never make a save throw.
    func sanitized() -> CanvasCamera {
        let b = Canvas.coordinateBound
        let x = origin.x.isFinite ? min(max(origin.x, -b), b) : 0
        let y = origin.y.isFinite ? min(max(origin.y, -b), b) : 0
        return CanvasCamera(origin: CGPoint(x: x, y: y))
    }
}
