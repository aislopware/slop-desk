// AndroidScrollGesture — a scroll wheel or a trackpad becomes ONE continuous finger on the device.
//
// The same machine as ``SimulatorScrollGesture``, and it arrives here for a DIFFERENT reason, which
// is worth being precise about. On the simulator path a continuous finger replaced a `swipe` verb
// that cost 275 ms of the server's main actor per call; it was a performance fix that turned out to
// also be the right model. `scrcpy` has no such verb to be rescued from — but it does have
// `INJECT_SCROLL_EVENT`, and using it would be the mistake:
//
//   - `ACTION_SCROLL` reaches a `RecyclerView` as a discrete wheel notch. It scrolls, and that is all
//     it does: no over-scroll stretch, no edge glow, no fling, no rubber band. Every piece of feedback
//     Android gives a scrolling list comes from the touch path, not the wheel path.
//   - Momentum is computed by `VelocityTracker` from the touch HISTORY at the moment of lift. A
//     stream of scroll notches has no history and therefore no fling — a flick stops dead the
//     instant the trackpad stops sending.
//
// So the finger is not an approximation of a scroll here; it is the only way to get the scroll
// Android's own apps are built around. ``AndroidControlMessage/scroll(...)`` stays for a genuine
// mouse wheel with no phase information, where there is no gesture to reconstruct in the first place.
//
// RE-GRIPPING. A trackpad gesture can travel further than the device is tall, and a finger cannot
// leave the screen and keep scrolling. When the virtual finger reaches the edge this lifts it and
// plants it again at the far side, which is what a hand does. The edge margin matters more on Android
// than on iOS: the bottom band is the gesture-navigation area, where a contact is a Back or a Home
// rather than a scroll.
//
// Pure and struct-shaped so the whole machine is testable without an `NSEvent`: the view feeds it
// deltas and phases, it answers with encoded control messages, and it holds no view, no socket and no
// timer.

#if os(macOS)
import CoreGraphics
import Foundation

struct AndroidScrollGesture {
    /// Where a scroll event sits in its gesture. Trackpads report this; a classic wheel does not,
    /// which is what ``wheel`` is for — the caller arms an idle timer and calls ``lift(in:)``.
    enum Phase {
        case began
        case changed
        /// `.ended` or `.cancelled` — the fingers left the trackpad.
        case ended
        /// A classic wheel notch. No phases exist, so the gesture is opened on the first one and
        /// closed by the caller's idle timer.
        case wheel
    }

    /// How far inside the frame the finger is kept. Two jobs: Android's gesture navigation owns the
    /// outermost band on three edges (Back left and right, Home along the bottom), so a contact
    /// planted there starts a system gesture instead of a scroll; and a re-grip needs somewhere to
    /// land that is not the edge it just left.
    static let edgeMargin: CGFloat = 24

    /// The finger's position in the fitted rect's own space, or `nil` when no contact is down.
    private(set) var finger: CGPoint?

    /// Feed one scroll event. Returns the messages to send, in order.
    ///
    /// `pointer` is where the cursor is, in the fitted rect's space — the contact is planted there,
    /// so a scroll acts on whatever is under the cursor, exactly as it does on a Mac.
    mutating func accept(
        delta: CGSize, isPrecise: Bool, phase: Phase, pointer: CGPoint,
        surface: AndroidScreenLayout.Surface,
    ) -> [Data] {
        guard surface.isUsable else { return [] }
        let fitted = surface.fitted

        if phase == .ended {
            guard let finger else { return [] }
            self.finger = nil
            return [Self.message(.up, at: finger, surface: surface)]
        }

        var messages: [Data] = []
        var point: CGPoint
        if let finger {
            point = finger
        } else {
            point = Self.planted(pointer, in: fitted)
            messages.append(Self.message(.down, at: point, surface: surface))
        }

        let travel = AndroidScreenLayout.scrollVector(delta: delta, isPrecise: isPrecise)
        let target = CGPoint(x: point.x + travel.width, y: point.y + travel.height)
        let clamped = Self.planted(target, in: fitted)
        if clamped != target {
            // Out of room. Lift at the boundary, plant again as far the other way as the margin
            // allows, and let the same event's remaining travel apply from there.
            messages.append(Self.message(.move, at: clamped, surface: surface))
            messages.append(Self.message(.up, at: clamped, surface: surface))
            point = Self.regrip(travel: travel, in: fitted)
            messages.append(Self.message(.down, at: point, surface: surface))
        } else {
            point = clamped
            messages.append(Self.message(.move, at: point, surface: surface))
        }
        finger = point
        return messages
    }

    /// Close a wheel gesture the caller's idle timer has decided is over. No-op with no contact down.
    mutating func lift(in surface: AndroidScreenLayout.Surface) -> [Data] {
        guard let finger else { return [] }
        self.finger = nil
        return [Self.message(.up, at: finger, surface: surface)]
    }

    /// Forget the contact without sending anything — the socket went away, so an `up` has nowhere to
    /// go and the device's touch state is moot.
    mutating func abandon() {
        finger = nil
    }

    /// One contact, converted from the fitted rect the gesture is tracked in to the video pixels the
    /// device will accept.
    static func message(
        _ action: AndroidMotionAction, at point: CGPoint,
        surface: AndroidScreenLayout.Surface,
    ) -> Data {
        let pixel = surface.pixels(point)
        return AndroidControlMessage.touch(
            action: action,
            x: AndroidScreenLayout.clampToInt32(pixel.x),
            y: AndroidScreenLayout.clampToInt32(pixel.y),
            width: surface.width, height: surface.height,
            // A scroll's contact reports the primary button held for the same reason a drag does:
            // Android's `MotionEvent` carries the button state, and a move with none set reads as a
            // hover in views that distinguish the two.
            buttons: action == .up ? [] : .primary,
        )
    }

    /// A point moved inside the frame's safe area. Collapses to the centre when the frame is smaller
    /// than two margins, which is a panel too narrow to scroll in but not a reason to send NaN.
    static func planted(_ point: CGPoint, in fitted: CGRect) -> CGPoint {
        let x = clamp(
            point.x, low: edgeMargin, high: fitted.width - edgeMargin, fallback: fitted.width / 2,
        )
        let y = clamp(
            point.y, low: edgeMargin, high: fitted.height - edgeMargin, fallback: fitted.height / 2,
        )
        return CGPoint(x: x, y: y)
    }

    /// Where the finger lands after running out of screen: at the far end of the axis it was
    /// travelling along, so the next stretch of the same gesture has the full height to move through.
    static func regrip(travel: CGSize, in fitted: CGRect) -> CGPoint {
        let far = { (extent: CGFloat, direction: CGFloat) -> CGFloat in
            direction >= 0 ? edgeMargin : extent - edgeMargin
        }
        let isVertical = abs(travel.height) >= abs(travel.width)
        return planted(
            CGPoint(
                x: isVertical ? fitted.width / 2 : far(fitted.width, travel.width),
                y: isVertical ? far(fitted.height, travel.height) : fitted.height / 2,
            ),
            in: fitted,
        )
    }

    private static func clamp(
        _ value: CGFloat, low: CGFloat, high: CGFloat, fallback: CGFloat,
    ) -> CGFloat {
        guard low <= high else { return fallback }
        return min(max(value, low), high)
    }
}
#endif
