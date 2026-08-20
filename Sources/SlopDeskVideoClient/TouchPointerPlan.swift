// TouchPointerPlan — the pure decisions behind "a finger on a remote DESKTOP".
//
// The phone already forwards touch to two remote surfaces (`AndroidScreenUIView`,
// `SimulatorScreenUIView`) and both say the same thing in their headers: a finger on the mirror IS
// the finger, so nothing is synthesized. A remote *desktop* is the opposite case — there is no touch
// to inject, only a POINTER — so the translation has to be written down somewhere, and the one place
// it must not be written is inside a `touchesMoved` that no test can reach (the iOS video surface is
// a `CAMetalLayer` over a VideoToolbox decoder; hang-safety keeps it out of XCTest entirely).
//
// So this file holds the arithmetic and the classification, `MetalLayerBackedView` holds the UIKit
// plumbing and the contact bookkeeping, and the split is the same one `ViewportPan` /
// `SwipePeelPlanner` / `BackgroundPointerPolicy` already draw for the Mac's half.
//
// ⚠️ PORT CANDIDATE. Every other pure gesture decision in this module is a Swift face over the Rust
// `client_gestures` crate (`ScrollRoutePinner`, `PinchZoomKeyPlanner`, `PinchZeroPolicy`,
// `ViewportPan`). This one is Swift because it was written in a change that could not touch
// `rust/`; it is deliberately shaped as free functions over scalars so the move is a body swap.

import Foundation

/// What a live TWO-CONTACT gesture over a remote desktop drives. Decided ONCE, the first time the
/// pair moves past its slop, and held to the gesture's end — the ``ScrollRoutePinner`` rule, for the
/// same reason: a gesture is one intent, and re-deciding it per event lets a pinch's tail scroll the
/// remote document (or a scroll's tail zoom the pane).
public enum TouchPairRoute: Sendable, Equatable {
    /// The span between the contacts changed: LOCAL viewport zoom, plus the centroid pan that rides
    /// with it (the map idiom — you zoom and reposition in one gesture).
    case zoom
    /// The pair translated while the viewport is already zoomed in: LOCAL pan. Nothing reaches the
    /// host. Panning has to be reachable somewhere, and at >1× it is what the user means far more
    /// often than a remote scroll.
    case pan
    /// The pair translated at 1×: a HOST scroll wheel at the centroid — the same continuous,
    /// phase-carrying scroll the Mac's trackpad sends, so the host replays a native inertial scroll
    /// rather than a phase-less wheel tick.
    case scroll
}

/// The pure half of the phone's touch → host-pointer translation.
///
/// The vocabulary these numbers implement, spelled once:
///
/// | gesture | meaning |
/// | --- | --- |
/// | tap | left click at the host point under the finger (`tapCount` rides through as the click count, so a double-tap is a real double-click) |
/// | long press | right click at that point — the only way a phone reaches a context menu |
/// | one-finger drag | left-button drag: press where the finger landed, track, release on lift |
/// | two-finger drag at 1× | host scroll at the centroid |
/// | two-finger drag while zoomed | local viewport pan |
/// | pinch | local viewport zoom (+ the pan that rides with it) |
public enum TouchPointerPlan {
    /// How far (points) a one-finger contact may wander and still be a TAP rather than a drag. Wide
    /// enough that a thumb press does not smear into a text selection, tight enough that a
    /// deliberate 12 pt drag on a scrollbar thumb is one.
    public static let tapSlop: Double = 10

    /// How long (seconds) a contact must rest inside ``tapSlop`` before it becomes a right click.
    /// The system long-press interval — a phone user already has this timing in their hands.
    public static let longPressDelay: Double = 0.5

    /// How much the span between two contacts must change (points) before the pair reads as a PINCH.
    /// Generous on purpose: two fingers laid down for a scroll are never perfectly parallel, and a
    /// pair that classified as a zoom on 4 pt of finger splay would jump the viewport on every
    /// scroll.
    public static let pinchSpanSlop: Double = 24

    /// How far a pair's centroid must travel (points) before the pair is classified at all. Below
    /// this the gesture is still undecided and NOTHING is sent — a two-finger rest must not scroll.
    public static let pairTravelSlop: Double = 8

    /// The client zoom ladder for the phone's viewport. The floor is 1× (unlike the Mac's 0.25×):
    /// the stream already `.fit`-letterboxes into the pane, so minifying below fit shows nothing but
    /// more background.
    public static let minZoom: Double = 1
    public static let maxZoom: Double = 8

    /// One zoom STEP of the footer's − / + controls (the Mac's ladder, same ratio).
    public static let zoomStep: Double = 1.25

    /// Whether a one-finger contact has left the tap slop — i.e. it is a DRAG now, and the pending
    /// long press is off. Compared squared so no `sqrt` sits in a 120 Hz touch path.
    public static func escapesTapSlop(dx: Double, dy: Double) -> Bool {
        let horizontal = dx * dx
        let vertical = dy * dy
        return horizontal + vertical > tapSlop * tapSlop
    }

    /// Classify a two-contact gesture, or `nil` while it is still undecided.
    ///
    /// `spanDelta` is the signed change in the distance between the two contacts since the pair
    /// landed; `centroidTravel` is how far their midpoint has moved since then; `zoom` is the
    /// viewport's CURRENT client zoom. Span wins over travel: a pinch always drags its centroid a
    /// little, and misreading that as a scroll sends the remote document flying.
    public static func classifyPair(
        spanDelta: Double, centroidTravel: Double, zoom: Double,
    ) -> TouchPairRoute? {
        if abs(spanDelta) >= pinchSpanSlop { return .zoom }
        guard centroidTravel >= pairTravelSlop else { return nil }
        // `zoom` is the compositor scale the user is looking through; at 1× there is nothing to pan
        // (the whole stream is in the pane), so the pair can only mean a remote scroll.
        return zoom > minZoom ? .pan : .scroll
    }

    /// The zoom a pinch lands on: the zoom the gesture started from, scaled by the live span ratio,
    /// clamped to the ladder. `spanRatio` is `currentSpan / baseSpan`; a non-finite or non-positive
    /// ratio (a degenerate pair — both contacts on the same pixel) holds the base.
    public static func pinchedZoom(base: Double, spanRatio: Double) -> Double {
        guard spanRatio.isFinite, spanRatio > 0 else { return clampZoom(base) }
        return clampZoom(base * spanRatio)
    }

    /// One footer zoom STEP from `zoom` (`stepIn` = the + button), clamped to the ladder.
    public static func steppedZoom(_ zoom: Double, stepIn: Bool) -> Double {
        clampZoom(stepIn ? zoom * zoomStep : zoom / zoomStep)
    }

    /// Clamp to `[minZoom, maxZoom]`, and SNAP to exactly 1× near unity so repeated − steps settle on
    /// actual-size instead of stopping at 1.024× forever (the Mac's `applyZoom` rule).
    public static func clampZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return minZoom }
        var clamped = Double.minimum(Double.maximum(zoom, minZoom), maxZoom)
        if abs(clamped - 1) < 0.06 { clamped = 1 }
        return clamped
    }

    /// Clamp a normalized pan offset to what the renderer can actually show at `zoom`.
    ///
    /// The iOS surface pans by moving the renderer's UV crop, and the crop's own limit is
    /// `0.5·(1 − 1/zoom)` on each axis — the same number `InputEventEncoder.normalize` inverts, which
    /// is why it is clamped HERE rather than left to the shader: a pan the encoder clamps and the
    /// renderer does not is a click that lands somewhere the user is not looking. At 1× the limit is
    /// 0, so the crop is pinned centred and there is nothing to pan.
    public static func clampPan(_ pan: Double, zoom: Double) -> Double {
        let z = clampZoom(zoom)
        guard z > minZoom else { return 0 }
        let limit = 0.5 * (1 - 1 / z)
        return Double.minimum(Double.maximum(pan, -limit), limit)
    }

    /// The `CGScrollPhase` byte for a host scroll built out of touches (`1` began, `2` changed,
    /// `4` ended). The phone has no `mayBegin` (no trackpad rest) and no momentum tail (UIKit hands
    /// the view no coast events), so `momentumPhase` is always `0` — the host's replay then ends the
    /// gesture at the lift instead of inventing an inertia the finger never had.
    public static func scrollPhase(isFirst: Bool, isLast: Bool) -> UInt8 {
        if isLast { return 4 }
        return isFirst ? 1 : 2
    }

    /// Clamp `UITouch.tapCount` into the wire `UInt8`, floored at 1. UIKit counts consecutive taps
    /// without bound the way AppKit's `clickCount` does, and the host reads it only as a click-state
    /// hint — so saturating is right and trapping would be a crash on a very fast tapper.
    public static func clickCount(_ tapCount: Int) -> UInt8 {
        UInt8(clamping: Swift.max(1, tapCount))
    }
}
