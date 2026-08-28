// MARK: - Drop zones

// The five labelled drop targets the external-drop overlay shows over a pane (see
// `docs/ui-shell/spec/user-interface__drag-and-drop.md`, `screenshots/drop-overlay-frame-action.png`): a
// central vertical column of three circles (New Tab → Insert Path → Open In-Place, top-to-bottom) plus a
// large ellipse hugging each side edge (Split Left / Split Right, extending off-screen).
//
// The LAWS live in `slopdesk_workspace::drop_zone` — every fraction of the pane box, the elliptical
// distance, and the overlap rule. What is left here is the enum the surfaces switch over and `CGPoint`/
// `CGSize` becoming the door's doubles, which is a struct copy either way.
//
// Why they moved: the overlay DRAWS these shapes and the drop receiver HIT-TESTS against them. When the
// two are one function a `.contentShape`-before-`.position` mistake cannot move the hit region off the
// blob, and a drop cannot land in a zone the user was not pointing at. Rust holds that function once, for
// both platforms' surfaces.
import CoreGraphics
import CSlopDeskFFI
import Foundation

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
/// coordinates (origin top-left, y DOWN — the UIKit / CoreGraphics-image convention, NOT AppKit's
/// bottom-left y-up: `MacPaneDropOverlay` overrides `isFlipped` to `true` for exactly this reason, and
/// says so in its own header).
public struct DropZoneShape: Equatable, Sendable {
    public var center: CGPoint
    public var radiusX: CGFloat
    public var radiusY: CGFloat

    public init(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat) {
        self.center = center
        self.radiusX = radiusX
        self.radiusY = radiusY
    }
}

// MARK: - Pane drop-zone layout

/// The overlay's geometry for a pane of a given `size`: the one thing the overlay draws from and the drop
/// receiver hit-tests against.
///
/// Proportions only — no AppKit, no view code — so the layout is identical on macOS and iOS, and the same
/// on a sidebar-sized pane and a full-screen one.
public struct PaneDropZoneLayout: Equatable, Sendable {
    public let size: CGSize

    public init(size: CGSize) {
        self.size = size
    }

    /// Draw / hit order — also the `CaseIterable` order. Central column first, edges last.
    public var zones: [DropZone] { DropZone.allCases }

    /// The drawn shape for one zone in pane-local coordinates.
    public func shape(for zone: DropZone) -> DropZoneShape {
        let drawn = slopdesk_drop_zone_shape(zone.ffiCode, Double(size.width), Double(size.height))
        return DropZoneShape(
            center: CGPoint(x: drawn.center.x, y: drawn.center.y),
            radiusX: drawn.radius_x,
            radiusY: drawn.radius_y,
        )
    }

    /// The zone under `point`, or `nil` if it lands in a gap — including every point over a pane that has
    /// not been laid out yet, whose zones are all degenerate.
    ///
    /// Where zones overlap the one the point is MOST deeply inside wins, so a zone's own drawn centre
    /// always resolves to that zone: draw-centre == hit-centre.
    public func zone(at point: CGPoint) -> DropZone? {
        var code: UInt8 = 0
        let point = SlopDeskWsPoint(x: Double(point.x), y: Double(point.y))
        guard slopdesk_drop_zone_at(point, Double(size.width), Double(size.height), &code) else {
            return nil
        }
        return DropZone(ffiCode: code)
    }
}

// MARK: - The codes the doors read

// Named rather than numbered, so no code is spelled twice and the two languages cannot drift over one.

extension DropZone {
    var ffiCode: UInt8 {
        switch self {
        case .newTab: UInt8(SLOPDESK_DROP_ZONE_NEW_TAB)
        case .insertPath: UInt8(SLOPDESK_DROP_ZONE_INSERT_PATH)
        case .openInPlace: UInt8(SLOPDESK_DROP_ZONE_OPEN_IN_PLACE)
        case .splitLeft: UInt8(SLOPDESK_DROP_ZONE_SPLIT_LEFT)
        case .splitRight: UInt8(SLOPDESK_DROP_ZONE_SPLIT_RIGHT)
        }
    }

    /// The inverse, for the hit test. An unrecognised code reads as the centre — the one zone that only
    /// ever pastes, which is the least destructive thing a drop can do.
    init(ffiCode: UInt8) {
        switch ffiCode {
        case UInt8(SLOPDESK_DROP_ZONE_NEW_TAB): self = .newTab
        case UInt8(SLOPDESK_DROP_ZONE_OPEN_IN_PLACE): self = .openInPlace
        case UInt8(SLOPDESK_DROP_ZONE_SPLIT_LEFT): self = .splitLeft
        case UInt8(SLOPDESK_DROP_ZONE_SPLIT_RIGHT): self = .splitRight
        default: self = .insertPath
        }
    }
}
