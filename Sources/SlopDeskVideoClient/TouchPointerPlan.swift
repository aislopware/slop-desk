// TouchPointerPlan — the pure decisions behind "a finger on a remote DESKTOP".
//
// The phone already forwards touch to two remote surfaces (`AndroidScreenUIView`,
// `SimulatorScreenUIView`) and both say the same thing in their headers: a finger on the mirror IS
// the finger, so nothing is synthesized. A remote *desktop* is the opposite case — there is no touch
// to inject, only a POINTER — so the translation has to be written down somewhere, and the one place
// it must not be written is inside a `touchesMoved` that no test can reach (the iOS video surface is
// a `CAMetalLayer` over a VideoToolbox decoder; hang-safety keeps it out of XCTest entirely).
//
// So the rules live in `client_gestures` beside the Mac's half (`ScrollRoutePinner`,
// `PinchZoomKeyPlanner`, `PinchZeroPolicy`, `ViewportPan`) and this file is the FACE over them:
// argument marshalling, no arithmetic and no numbers. `MetalLayerBackedView` keeps the UIKit
// plumbing and the contact bookkeeping, which is the same split as before — one language less.

import CSlopDeskFFI
import SlopDeskVideoProtocol

/// What a live TWO-CONTACT gesture over a remote desktop drives. Decided ONCE, the first time the
/// pair moves past its slop, and held to the gesture's end — the ``ScrollRoutePinner`` rule, for the
/// same reason: a gesture is one intent, and re-deciding it per event lets a pinch's tail scroll the
/// remote document (or a scroll's tail zoom the pane).
///
/// A VOCABULARY, in doc 55 §6's sense: the cases exist here because a `switch` in the view reads
/// them, and what crosses is the discriminant `SLOPDESK_TOUCH_ROUTE_*` names. Nothing decides
/// anything on this side.
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
    /// How far (points) a one-finger contact may wander and still be a TAP rather than a drag.
    public static let tapSlop = slopdesk_touch_constant(0)

    /// How long (seconds) a contact must rest inside ``tapSlop`` before it becomes a right click.
    public static let longPressDelay = slopdesk_touch_constant(1)

    /// How much the span between two contacts must change (points) before the pair reads as a PINCH.
    public static let pinchSpanSlop = slopdesk_touch_constant(2)

    /// How far a pair's centroid must travel (points) before the pair is classified at all.
    public static let pairTravelSlop = slopdesk_touch_constant(3)

    /// The floor of the client zoom ladder — 1×, unlike the Mac's 0.25×.
    public static let minZoom = slopdesk_touch_constant(4)

    /// The ceiling of that ladder.
    public static let maxZoom = slopdesk_touch_constant(5)

    /// One zoom STEP of the footer's − / + controls.
    public static let zoomStep = slopdesk_touch_constant(6)

    /// Whether a one-finger contact has left the tap slop — i.e. it is a DRAG now, and the pending
    /// long press is off.
    public static func escapesTapSlop(dx: Double, dy: Double) -> Bool {
        slopdesk_touch_escapes_tap_slop(dx, dy)
    }

    /// Classify a two-contact gesture, or `nil` while it is still undecided.
    ///
    /// `spanDelta` is the signed change in the distance between the two contacts since the pair
    /// landed; `centroidTravel` is how far their midpoint has moved since then; `zoom` is the
    /// viewport's CURRENT client zoom.
    public static func classifyPair(
        spanDelta: Double, centroidTravel: Double, zoom: Double,
    ) -> TouchPairRoute? {
        let answer = slopdesk_touch_classify_pair(spanDelta, centroidTravel, zoom)
        guard answer.decided else { return nil }
        switch UInt32(answer.route) {
        case SLOPDESK_TOUCH_ROUTE_ZOOM: return .zoom
        case SLOPDESK_TOUCH_ROUTE_PAN: return .pan
        case SLOPDESK_TOUCH_ROUTE_SCROLL: return .scroll
        default: return nil
        }
    }

    /// The zoom a pinch lands on: the zoom the gesture started from, scaled by the live span ratio,
    /// clamped to the ladder. `spanRatio` is `currentSpan / baseSpan`.
    public static func pinchedZoom(base: Double, spanRatio: Double) -> Double {
        slopdesk_touch_pinched_zoom(base, spanRatio)
    }

    /// One footer zoom STEP from `zoom` (`stepIn` = the + button), clamped to the ladder.
    public static func steppedZoom(_ zoom: Double, stepIn: Bool) -> Double {
        slopdesk_touch_stepped_zoom(zoom, stepIn)
    }

    /// Clamp to `[minZoom, maxZoom]`, and SNAP to exactly 1× near unity.
    public static func clampZoom(_ zoom: Double) -> Double {
        slopdesk_touch_clamp_zoom(zoom)
    }

    /// Clamp a normalized pan offset to what the renderer can actually show at `zoom`.
    public static func clampPan(_ pan: Double, zoom: Double) -> Double {
        slopdesk_touch_clamp_pan(pan, zoom)
    }

    /// The `CGScrollPhase` byte for a host scroll built out of touches (`1` began, `2` changed,
    /// `4` ended).
    public static func scrollPhase(isFirst: Bool, isLast: Bool) -> UInt8 {
        slopdesk_touch_scroll_phase(isFirst, isLast)
    }

    /// Clamp `UITouch.tapCount` into the wire `UInt8`, floored at 1.
    public static func clickCount(_ tapCount: Int) -> UInt8 {
        slopdesk_touch_click_count(Int64(tapCount))
    }
}

/// What changed between the buttons a client has already forwarded as DOWN and the ones an indirect
/// pointer is holding now — a bit set whose bit INDEX is the wire's own ``MouseButton`` ordinal, so
/// ``IndirectPointerPlan/buttons(in:)`` walks it with a shift rather than a table.
public struct PointerButtonChange: Sendable, Equatable {
    /// Buttons to send a press for.
    public let pressed: UInt8
    /// Buttons to send a release for.
    public let released: UInt8
    /// The new held set — hand it back as the next call's `held`.
    public let held: UInt8
}

/// The pure half of "an iPad with a trackpad is a real pointer".
///
/// A finger has one button and the client SYNTHESIZES the press from a tap; an indirect pointer has
/// real buttons and reports them as a LEVEL on every event, so the client stops synthesizing and
/// starts diffing. That is a different failure mode, and the expensive one: a client that forwarded
/// the level either never presses or never releases, and a button left down outlives the pane on a
/// host whose event source is process-global.
///
/// The same FACE rule as ``TouchPointerPlan`` — argument marshalling, no arithmetic and no numbers.
public enum IndirectPointerPlan {
    /// Diff a UIKit `UIEvent.buttonMask` against what has already been forwarded.
    ///
    /// Safe to call from a MOVE as well as a press: the same mask twice answers "nothing changed",
    /// which is the property that lets one call site serve `touchesBegan`, `touchesMoved` and
    /// `touchesEnded` — UIKit reports the mask on every event, and a button pressed mid-drag arrives
    /// on a move.
    public static func buttonTransitions(held: UInt8, mask: Int) -> PointerButtonChange {
        let answer = slopdesk_pointer_button_transitions(held, UInt32(truncatingIfNeeded: mask))
        return PointerButtonChange(pressed: answer.pressed, released: answer.released, held: answer.held)
    }

    /// The buttons in a bit set, in wire order, as the ``MouseButton`` each bit indexes.
    ///
    /// Empty for an empty set, so a caller loops over the answer instead of testing the set first.
    public static func buttons(in set: UInt8) -> [MouseButton] {
        MouseButton.allCases.filter { set & (1 << $0.rawValue) != 0 }
    }

    /// The `CGScrollPhase` byte for a `UIGestureRecognizer.State` raw value — the trackpad's half of
    /// what ``TouchPointerPlan/scrollPhase(isFirst:isLast:)`` answers for a finger.
    ///
    /// A cancelled or failed recogniser ENDS rather than cancelling: the host has one replay for a
    /// finished gesture and none for an abandoned one, and this half already made that call for
    /// touches (a cancelled contact is LIFTED, not forgotten).
    public static func scrollPhase(gestureState: Int) -> UInt8 {
        slopdesk_scroll_phase_for_gesture_state(UInt8(truncatingIfNeeded: gestureState))
    }
}
