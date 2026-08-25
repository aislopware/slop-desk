// AndroidScrollGesture — a scroll wheel or a trackpad becomes ONE continuous finger on the device.
//
// The MACHINE is `slopdesk_devicepanel::scroll`, the same one ``SimulatorScrollGesture`` reaches, and
// it arrives here for a DIFFERENT reason, which is worth being precise about. On the simulator path a
// continuous finger replaced a `swipe` verb that cost 275 ms of the server's main actor per call; it
// was a performance fix that turned out to also be the right model. `scrcpy` has no such verb to be
// rescued from — but it does have `INJECT_SCROLL_EVENT`, and using it would be the mistake:
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
// What stays on THIS side is the conversion: a contact comes back in the fitted rect's own space, and
// the server accepts a positional message only in the video's pixel grid, paired with the exact size
// it is encoding. No angle is passed — `scrcpy` rotates on the DEVICE, so the frame here is always
// already the right way up and there is nothing for a delta to be out of step with.

import CoreGraphics
import CSlopDeskFFI
import Foundation

package final class AndroidScrollGesture {
    /// Where a scroll event sits in its gesture. Trackpads report this; a classic wheel does not,
    /// which is what ``wheel`` is for — the caller arms an idle timer and calls ``lift(in:)``.
    package enum Phase: UInt8 {
        case began = 0
        case changed = 1
        /// `.ended` or `.cancelled` — the fingers left the trackpad.
        case ended = 2
        /// A classic wheel notch. No phases exist, so the gesture is opened on the first one and
        /// closed by the caller's idle timer.
        case wheel = 3
    }

    private let handle: OpaquePointer

    package init() {
        guard let handle = slopdesk_panel_scroll_new() else {
            // One small box and nothing else, so a null here is an out-of-memory the process cannot
            // continue past — and a silently inert gesture would read as a panel that stopped
            // scrolling for no reason.
            preconditionFailure("slopdesk_panel_scroll_new returned null")
        }
        self.handle = handle
    }

    deinit { slopdesk_panel_scroll_free(handle) }

    /// The finger's position in the fitted rect's own space, or `nil` when no contact is down.
    package var finger: CGPoint? {
        var point = SlopDeskVideoPoint()
        guard slopdesk_panel_scroll_finger(handle, &point) else { return nil }
        return CGPoint(x: point.x, y: point.y)
    }

    /// Feed one scroll event. Returns the messages to send, in order.
    ///
    /// `pointer` is where the cursor is, in the fitted rect's space — the contact is planted there,
    /// so a scroll acts on whatever is under the cursor, exactly as it does on a Mac.
    package func accept(
        delta: CGSize, isPrecise: Bool, phase: Phase, pointer: CGPoint,
        surface: AndroidScreenLayout.Surface,
    ) -> [Data] {
        guard surface.isUsable else { return [] }
        let fitted = surface.fitted
        return contacts { out, cap in
            slopdesk_panel_scroll_accept(
                handle,
                SlopDeskVideoSize(width: delta.width, height: delta.height),
                isPrecise, phase.rawValue,
                SlopDeskVideoPoint(x: pointer.x, y: pointer.y),
                SlopDeskVideoRect(
                    x: fitted.origin.x, y: fitted.origin.y,
                    width: fitted.size.width, height: fitted.size.height,
                ),
                // No un-rotation: the frame is never drawn turned. That is the whole difference
                // between this call and the simulator panel's.
                0, out, cap,
            )
        }.map { Self.message($0, surface: surface) }
    }

    /// Close a wheel gesture the caller's idle timer has decided is over. No-op with no contact down.
    package func lift(in surface: AndroidScreenLayout.Surface) -> [Data] {
        contacts { out, cap in
            slopdesk_panel_scroll_lift(handle, out, cap)
        }.map { Self.message($0, surface: surface) }
    }

    /// Forget the contact without sending anything — the socket went away, so an `up` has nowhere to
    /// go and the device's touch state is moot.
    package func abandon() {
        slopdesk_panel_scroll_abandon(handle)
    }

    /// One contact, converted from the fitted rect the gesture is tracked in to the video pixels the
    /// device will accept.
    package static func message(
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

    // MARK: - Marshalling

    /// One event's contacts. `SLOPDESK_PANEL_CONTACT_MAX` is the longest an event can be — the
    /// re-grip — so the buffer is sized once by the door's own advertised bound.
    private func contacts(
        _ door: (UnsafeMutablePointer<SlopDeskPanelContact>?, Int) -> Int,
    ) -> [SlopDeskPanelContact] {
        var out = [SlopDeskPanelContact](
            repeating: SlopDeskPanelContact(), count: Int(SLOPDESK_PANEL_CONTACT_MAX),
        )
        let count = out.withUnsafeMutableBufferPointer { door($0.baseAddress, $0.count) }
        guard count > 0, count <= out.count else { return [] }
        return Array(out[0..<count])
    }

    private static func message(
        _ contact: SlopDeskPanelContact, surface: AndroidScreenLayout.Surface,
    ) -> Data {
        message(
            action(contact.action), at: CGPoint(x: contact.point.x, y: contact.point.y),
            surface: surface,
        )
    }

    private static func action(_ code: UInt8) -> AndroidMotionAction {
        switch code {
        case UInt8(SLOPDESK_PANEL_CONTACT_DOWN): .down
        case UInt8(SLOPDESK_PANEL_CONTACT_MOVE): .move
        // An action this build has no case for lifts rather than plants: a stray `up` is a gesture
        // that ends early, where a stray `down` strands a contact no later event can clear.
        default: .up
        }
    }
}
