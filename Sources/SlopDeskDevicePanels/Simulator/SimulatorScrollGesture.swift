// SimulatorScrollGesture — a scroll wheel or a trackpad becomes ONE continuous finger on the device.
//
// The MACHINE is `slopdesk_devicepanel::scroll`, shared with the Android panel, reached through the
// `slopdesk_panel_scroll_*` handle. What is left here is the one thing the two panels do not share:
// what a contact becomes on the wire. This lane sends the fitted rect's own coordinates with that
// rect's size beside them, because the host rescales; the Android lane converts to the video's pixel
// grid, because its server drops a mismatched pair.
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
// the moment of lift, and a stream of one-shot swipes has none.
//
// A CLASS, not a struct, for the reason `docs/55` §4b gives: the handle OWNS a boxed gesture, and a
// value type holding one would free it once per copy while every copy still pointed at it.

import CoreGraphics
import CSlopDeskFFI

package final class SimulatorScrollGesture {
    /// Where a scroll event sits in its gesture. Trackpads report this; a classic wheel does not,
    /// which is what ``wheel`` is for — the caller arms an idle timer and calls ``lift(in:)``.
    package enum Phase: UInt8 {
        /// `NSEvent.phase == .began`, or the first `.changed` of a gesture that began off-view.
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
            // The door allocates one small box and nothing else, so a null here is an out-of-memory
            // the process cannot continue past — and a silently inert gesture would read as a panel
            // that quietly stopped scrolling.
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

    /// Feed one scroll event. Returns the envelopes to send, in order.
    ///
    /// `pointer` is where the cursor is, in the fitted rect's space — the contact is planted there,
    /// so a scroll acts on whatever is under the cursor, exactly as it does on a Mac.
    ///
    /// The ORIENTATION is what this lane adds and the Android lane must not: the simulator's
    /// framebuffer never turns while the bezel is DRAWN under a `rotationEffect`, so a delta that
    /// never passed through the view's geometry is a quarter turn out of step with it.
    package func accept(
        delta: CGSize, isPrecise: Bool, phase: Phase, pointer: CGPoint,
        fitted: CGRect, orientation: SimulatorOrientation,
    ) -> [SimulatorInputEnvelope] {
        let surface = SimulatorScreenLayout.surface(fitted: fitted)
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
                orientation.viewAngle, out, cap,
            )
        }.map { Self.envelope($0, in: surface) }
    }

    /// Close a wheel gesture the caller's idle timer has decided is over. No-op with no contact down.
    package func lift(in fitted: CGRect) -> [SimulatorInputEnvelope] {
        let surface = SimulatorScreenLayout.surface(fitted: fitted)
        return contacts { out, cap in
            slopdesk_panel_scroll_lift(handle, out, cap)
        }.map { Self.envelope($0, in: surface) }
    }

    /// Forget the contact without sending anything — the socket went away, so an `up` has nowhere to
    /// go and the device's touch state is moot.
    package func abandon() {
        slopdesk_panel_scroll_abandon(handle)
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

    // MARK: - Marshalling

    /// One event's contacts. `SLOPDESK_PANEL_CONTACT_MAX` is the longest an event can be — the
    /// re-grip — so the buffer is sized once by the door's own advertised bound and the count can
    /// never come back larger than it.
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

    private static func envelope(
        _ contact: SlopDeskPanelContact, in surface: SimulatorInputEnvelope.Surface,
    ) -> SimulatorInputEnvelope {
        .touch(phase(contact.action), x: contact.point.x, y: contact.point.y, in: surface)
    }

    private static func phase(_ action: UInt8) -> SimulatorInputEnvelope.TouchPhase {
        switch action {
        case UInt8(SLOPDESK_PANEL_CONTACT_DOWN): .down
        case UInt8(SLOPDESK_PANEL_CONTACT_MOVE): .move
        // An action this build has no case for lifts rather than plants: a stray `up` is a gesture
        // that ends early, where a stray `down` strands a contact no later event can clear.
        default: .up
        }
    }
}
