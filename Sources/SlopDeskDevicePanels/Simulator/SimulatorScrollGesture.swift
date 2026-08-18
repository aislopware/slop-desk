// SimulatorScrollGesture — a scroll wheel or a trackpad becomes ONE continuous finger on the device.
//
// ⚠️ THE VERB THIS REPLACES COSTS 275 MILLISECONDS. The panel used to bank scroll travel and fire a
// discrete `swipe` every 24 points. Measured 2026-08-04 by feeding `baguette input` back-to-back
// envelopes and timing its per-envelope acks:
//
//     swipe (duration 0.01)   275.3 ms      touch1-down    0.1 ms
//     swipe (duration 0.05)   281.3 ms      touch1-move    0.0 ms
//     swipe (duration 0.25)   743.7 ms      touch1-up      0.0 ms
//     tap   (duration 0.05)    73.3 ms      touch2-move   25.2 ms
//
// The 275 ms is a FIXED cost — it barely moves between a 10 ms and a 50 ms nominal duration — and it
// is the server's main actor, so nothing else gets serviced while it runs. A single trackpad flick
// banks enough travel for ten of them, which is nearly three seconds of backlog for a gesture that
// took the user a fifth of a second to make. That is the whole of "scrolling feels laggy": the panel
// was buying, at 275 ms each, the one thing a continuous touch stream gives away for nothing.
//
// A REAL FINGER, not a series of flicks. Beyond the cost, a run of discrete swipes cannot express
// what a scroll IS. Each one starts a fresh contact at the same origin, so iOS sees ten unrelated
// short drags rather than one long one: no continuous tracking, no velocity, and therefore no
// momentum — the deceleration that makes a scroll feel like a scroll comes from the touch history at
// the moment of lift, and a stream of one-shot swipes has none. Planting one finger, moving it with
// the wheel, and lifting it when the gesture ends gives UIScrollView exactly the input it was built
// for, and the inertia arrives for free because iOS computes it.
//
// RE-GRIPPING. A trackpad gesture can travel further than the device is tall, and a finger cannot
// leave the screen and keep scrolling. When the virtual finger reaches the edge this lifts it and
// plants it again at the far side, which is what a hand does — and it is why the edge margin exists:
// planting ON the boundary would put the next contact inside iOS's own system-gesture band.
//
// Pure and struct-shaped so the whole machine is testable without an `NSEvent`: the view feeds it
// deltas and phases, it answers with envelopes, and it holds no view, no socket and no timer.

import CoreGraphics

package struct SimulatorScrollGesture {
    /// Where a scroll event sits in its gesture. Trackpads report this; a classic wheel does not,
    /// which is what ``wheel`` is for — the caller arms an idle timer and calls ``lift(at:)``.
    package enum Phase {
        /// `NSEvent.phase == .began`, or the first `.changed` of a gesture that began off-view.
        case began
        case changed
        /// `.ended` or `.cancelled` — the fingers left the trackpad.
        case ended
        /// A classic wheel notch. No phases exist, so the gesture is opened on the first one and
        /// closed by the caller's idle timer.
        case wheel
    }

    package init() {}

    /// The finger's position in the fitted rect's own space, or `nil` when no contact is down.
    package private(set) var finger: CGPoint?

    /// Feed one scroll event. Returns the envelopes to send, in order.
    ///
    /// `pointer` is where the cursor is, in the fitted rect's space — the contact is planted there,
    /// so a scroll acts on whatever is under the cursor, exactly as it does on a Mac.
    package mutating func accept(
        delta: CGSize, isPrecise: Bool, phase: Phase, pointer: CGPoint,
        fitted: CGRect, orientation: SimulatorOrientation,
    ) -> [SimulatorInputEnvelope] {
        let surface = SimulatorScreenLayout.surface(fitted: fitted)
        guard fitted.width > 0, fitted.height > 0 else { return [] }

        if phase == .ended {
            guard let finger else { return [] }
            self.finger = nil
            return [.touch(.up, x: finger.x, y: finger.y, in: surface)]
        }

        var envelopes: [SimulatorInputEnvelope] = []
        var point: CGPoint
        if let finger {
            point = finger
        } else {
            point = Self.planted(pointer, in: fitted)
            envelopes.append(.touch(.down, x: point.x, y: point.y, in: surface))
        }

        let travel = SimulatorScreenLayout.scrollVector(
            delta: delta, isPrecise: isPrecise, orientation: orientation,
        )
        let target = CGPoint(x: point.x + travel.width, y: point.y + travel.height)
        let clamped = Self.planted(target, in: fitted)
        if clamped != target {
            // Out of room. Lift at the boundary, plant again as far the other way as the margin
            // allows, and let the same event's remaining travel apply from there.
            envelopes.append(.touch(.move, x: clamped.x, y: clamped.y, in: surface))
            envelopes.append(.touch(.up, x: clamped.x, y: clamped.y, in: surface))
            point = Self.regrip(travel: travel, in: fitted)
            envelopes.append(.touch(.down, x: point.x, y: point.y, in: surface))
        } else {
            point = clamped
            envelopes.append(.touch(.move, x: point.x, y: point.y, in: surface))
        }
        finger = point
        return envelopes
    }

    /// Close a wheel gesture the caller's idle timer has decided is over. No-op with no contact down.
    package mutating func lift(in fitted: CGRect) -> [SimulatorInputEnvelope] {
        guard let finger else { return [] }
        self.finger = nil
        return [.touch(
            .up, x: finger.x, y: finger.y, in: SimulatorScreenLayout.surface(fitted: fitted),
        )]
    }

    /// Forget the contact without sending anything — the socket went away, so an `up` has nowhere to
    /// go and the device's touch state is moot.
    package mutating func abandon() {
        finger = nil
    }

    /// The safe-area helpers both device panels share — ``DevicePanelGeometry``. A synthetic finger
    /// obeys the same margin whichever platform it is planted on; only the message it becomes differs.
    package static var edgeMargin: CGFloat { DevicePanelGeometry.edgeMargin }

    package static func planted(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        DevicePanelGeometry.planted(point, in: fitted)
    }

    package static func regrip(travel: CGSize, in fitted: CGRect) -> CGPoint {
        DevicePanelGeometry.regrip(travel: travel, in: fitted)
    }
}
