import CoreGraphics
import Foundation

// MARK: - Drop zones

/// The five labelled drop targets the external-drop overlay shows over a pane (see
/// `docs/ui-shell/spec/user-interface__drag-and-drop.md`, `screenshots/drop-overlay-frame-action.png`): a central
/// vertical column of three circles (New Tab → Insert Path → Open In-Place, top-to-bottom) plus a
/// large ellipse hugging each side edge (Split Left / Split Right, extending off-screen).
public enum DropZone: String, CaseIterable, Sendable, Equatable {
    /// Top-center small circle — open a new terminal tab rooted at the dropped folder.
    case newTab
    /// Center medium circle — paste the dropped path/text into the focused terminal.
    case insertPath
    /// Lower-center medium circle — open the dropped path in place (host-open).
    case openInPlace
    /// Left-edge ellipse — split a new pane to the left.
    case splitLeft
    /// Right-edge ellipse — split a new pane to the right.
    case splitRight
}

// MARK: - One zone's drawn shape

/// A single zone's geometry as an axis-aligned ellipse (a circle is `radiusX == radiusY`) in pane-local
/// coordinates (origin top-left, y down — SwiftUI/CG convention). The overlay DRAWS this shape and the
/// drop receiver HIT-TESTS against it, so draw == hit by construction (the `.contentShape`-before-
/// `.position` trap is mooted by sharing one source of truth).
public struct DropZoneShape: Equatable, Sendable {
    public var center: CGPoint
    public var radiusX: CGFloat
    public var radiusY: CGFloat

    public init(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat) {
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
    }

    /// The normalized elliptical distance of `point` from the center: `1.0` exactly on the boundary,
    /// `< 1` inside, `> 1` outside, `0` at the center. Unifies circle + ellipse hit-testing and gives a
    /// containment DEPTH for deterministic overlap resolution. Separate `*`/`+` only — never fuse
    /// (CLAUDE.md float rule); inputs are finite local geometry, so the ordered `<=` compare is safe.
    /// A degenerate (zero) radius makes this non-finite, which fails every `<= 1` test → no false hit.
    public func normalizedDistance(to point: CGPoint) -> CGFloat {
        let dx = (point.x - center.x) / radiusX
        let dy = (point.y - center.y) / radiusY
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Whether `point` lies within (or on) this zone's ellipse.
    public func contains(_ point: CGPoint) -> Bool {
        normalizedDistance(to: point) <= 1
    }
}

// MARK: - Pane drop-zone layout

/// The PURE geometry of the external-drop overlay for a pane of a given `size`. It is the single source
/// of truth the overlay draws from and the drop receiver hit-tests against (E18 WI-1). Headless: no
/// AppKit, no view code — proportions only, so the layout is unit-testable and identical on macOS/iOS.
///
/// Layout (fractions of the pane box, matching `drop-overlay-frame-action.png`):
/// - the three central circles share the pane's horizontal center (`x = w/2`), stacked top→bottom at
///   `y = 0.18h / 0.46h / 0.72h`, with radii scaled to the pane's smaller dimension so they stay round;
/// - the two split ellipses are centered ON each side edge (`x = 0` / `x = w`) at mid-height, large
///   enough to spill off-screen (the visible half is what the user sees).
public struct PaneDropZoneLayout: Equatable, Sendable {
    public let size: CGSize

    public init(size: CGSize) {
        self.size = size
    }

    /// Draw / hit order — also the `CaseIterable` order. Central column first, edges last.
    public var zones: [DropZone] { DropZone.allCases }

    /// The drawn shape for one zone in pane-local coordinates.
    public func shape(for zone: DropZone) -> DropZoneShape {
        let w = size.width
        let h = size.height
        let s = min(w, h) // round-circle scale base
        let cx = w / 2

        switch zone {
        case .newTab:
            return DropZoneShape(center: CGPoint(x: cx, y: h * 0.18), radiusX: s * 0.15, radiusY: s * 0.15)
        case .insertPath:
            return DropZoneShape(center: CGPoint(x: cx, y: h * 0.46), radiusX: s * 0.16, radiusY: s * 0.16)
        case .openInPlace:
            return DropZoneShape(center: CGPoint(x: cx, y: h * 0.72), radiusX: s * 0.16, radiusY: s * 0.16)
        case .splitLeft:
            return DropZoneShape(center: CGPoint(x: 0, y: h / 2), radiusX: w * 0.26, radiusY: h * 0.30)
        case .splitRight:
            return DropZoneShape(center: CGPoint(x: w, y: h / 2), radiusX: w * 0.26, radiusY: h * 0.30)
        }
    }

    /// The zone under `point`, or `nil` if it lands in a gap. When zones overlap, the one the point is
    /// MOST deeply inside (smallest normalized distance) wins — deterministic, and a zone's own center
    /// (normalized distance `0`) always resolves to that zone, so draw-center == hit-center.
    public func zone(at point: CGPoint) -> DropZone? {
        var best: (zone: DropZone, depth: CGFloat)?
        for zone in DropZone.allCases {
            let depth = shape(for: zone).normalizedDistance(to: point)
            guard depth <= 1 else { continue }
            if let current = best {
                if depth < current.depth { best = (zone, depth) }
            } else {
                best = (zone, depth)
            }
        }
        return best?.zone
    }
}
