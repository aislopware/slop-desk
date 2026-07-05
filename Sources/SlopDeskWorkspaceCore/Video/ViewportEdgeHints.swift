import CoreGraphics
import Foundation

// MARK: - Oversized-viewport edge-hint model (C7 improvement 3)

/// The PURE computed model behind the remote-GUI pane's edge-pan affordance: when the remote window is
/// LARGER than the pane viewport, the oversized-viewport pan (edge-hover) is otherwise invisible, so the
/// view draws slim gradient hints on the edges that have OFF-SCREEN content (like scroll shadows). This
/// maps the existing viewport geometry (content size, visible viewport size, pan offset) onto which of the
/// four edges have hidden content — no view / gesture state here, so it is unit-tested headlessly and the
/// overlay stays a thin renderer.
public struct ViewportEdgeHints: Equatable, Sendable {
    /// Content extends ABOVE the viewport (there is hidden content past the top edge).
    public var top: Bool
    /// Content extends BELOW the viewport.
    public var bottom: Bool
    /// Content extends past the LEADING (left) edge.
    public var leading: Bool
    /// Content extends past the TRAILING (right) edge.
    public var trailing: Bool

    public init(top: Bool = false, bottom: Bool = false, leading: Bool = false, trailing: Bool = false) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
    }

    /// No hidden content on any edge (the window fits, or is panned to a corner with only the opposite edges).
    public static let none = Self()

    /// Whether ANY edge has hidden content (the view mounts the overlay + the first-hover cursor cue only then).
    public var any: Bool { top || bottom || leading || trailing }

    /// Computes the hinted edges from the viewport geometry:
    /// - `contentSize` — the remote window's native (unzoomed×zoom) content size in the pane's coordinate space.
    /// - `viewportSize` — the visible pane rect.
    /// - `offset` — the visible rect's top-left ORIGIN within the content (content coordinates, ≥ 0). Clamped
    ///   here to the valid `[0, content − viewport]` range so a stale / overshooting offset can't invent hints.
    ///
    /// An edge is hinted when content extends beyond the viewport on that side (past `epsilon`, to swallow
    /// sub-pixel rounding). When content fits within the viewport on an axis, neither edge on that axis hints.
    public static func compute(
        contentSize: CGSize,
        viewportSize: CGSize,
        offset: CGPoint,
        epsilon: CGFloat = 0.5,
    ) -> Self {
        // Overflow per axis (how much content exceeds the viewport). Non-positive ⇒ fits ⇒ no hints that axis.
        let overflowX = contentSize.width - viewportSize.width
        let overflowY = contentSize.height - viewportSize.height
        guard contentSize.width > 0, contentSize.height > 0 else { return .none }

        // Clamp the pan offset to the reachable range so an out-of-range offset can't fabricate an edge.
        let maxX = Swift.max(0, overflowX)
        let maxY = Swift.max(0, overflowY)
        let x = clamp(offset.x, 0, maxX)
        let y = clamp(offset.y, 0, maxY)

        return Self(
            top: overflowY > epsilon && y > epsilon,
            bottom: overflowY > epsilon && (maxY - y) > epsilon,
            leading: overflowX > epsilon && x > epsilon,
            trailing: overflowX > epsilon && (maxX - x) > epsilon,
        )
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(v, lo), Swift.max(lo, hi))
    }
}
