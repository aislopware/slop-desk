// SimulatorInputEnvelope — the face over the client→host half of the simulator dialect: one JSON
// object per gesture, key or button press, sent as a websocket TEXT frame on the same socket the
// frames arrive on.
//
// The ENCODER is `slopdesk_devicepanel::sim_input`. What is left here is the verb list, because a
// factory per verb is what makes the wrong combination unrepresentable: the envelope is a flat
// heterogeneous bag whose key set changes per type (`tap` has x/y, `touch2-move` has x1/y1/x2/y2,
// `key` has neither), and one door taking every field optional would put that discipline back in the
// caller's hands. Each factory here reaches exactly one door.
//
// COORDINATES ARE NOT PIXELS. Every positional envelope carries the `width`/`height` of the surface
// its x/y were measured in, and the host rescales to the device's real framebuffer. That is what lets
// the panel send view-space points directly — no DPI maths on this side, no assumption about the
// device's native resolution, and a window resize mid-drag stays correct because the size travels
// with each event rather than being negotiated once.
//
// The value is the RENDERED string, not a dictionary. Keys are emitted sorted, so the encoder is a
// pure function of its input and the tests can pin whole strings; equality is string equality for
// the same reason.

import CSlopDeskFFI
import Foundation
import SlopDeskArena

/// One outbound message. Construct through the factories; the raw initializer stays private so a
/// caller cannot assemble a shape the server has no case for.
package struct SimulatorInputEnvelope: Equatable {
    /// The surface the coordinates were measured in. Zero is legal and means "unknown" — the server
    /// treats it as a no-scale hint rather than dividing by it.
    package struct Surface: Equatable {
        package var width: Double
        package var height: Double
    }

    /// The wire form. `nil` only if the door refused, which the factories make unreachable — but it
    /// stays optional rather than forced, because a trap in an input path is a worse failure than a
    /// dropped gesture.
    package let json: String?

    private init(_ rendered: String) { json = rendered.isEmpty ? nil : rendered }

    // MARK: Discrete gestures

    /// The server's OWN defaults, read through the door rather than written down again here — a
    /// second copy of a number the server owns is a number that can drift from it.
    package static let defaultTapDuration = slopdesk_sim_default_tap_duration()
    package static let defaultSwipeDuration = slopdesk_sim_default_swipe_duration()

    /// A tap. `duration` is seconds of contact — the default matches the server's own, and a longer
    /// one is how a long-press is expressed (there is no separate verb for it).
    package static func tap(
        x: Double, y: Double,
        duration: Double = Self.defaultTapDuration,
        in surface: Surface,
    ) -> Self {
        Self(ffiAnswerText(capacity: 160) { out, cap in
            slopdesk_sim_input_tap(x, y, duration, surface.record, out, cap)
        })
    }

    /// A one-finger drag from start to end over `duration` seconds, interpolated host-side. Distinct
    /// from a touch1 down/move/up sequence: this is fire-and-forget, so it suits a scroll wheel or a
    /// trackpad flick, where the client has a delta but no continuous contact to track.
    package static func swipe(
        fromX: Double, fromY: Double, toX: Double, toY: Double,
        duration: Double = Self.defaultSwipeDuration, in surface: Surface,
    ) -> Self {
        Self(ffiAnswerText(capacity: 200) { out, cap in
            slopdesk_sim_input_swipe(
                fromX, fromY, toX, toY, duration, surface.record, out, cap,
            )
        })
    }

    // MARK: Continuous touch

    /// Which end of a contact this event is. The NAMES are the door's — the wire spells them into
    /// `touch1-down` and friends — so this side carries only the code.
    package enum TouchPhase: UInt8 {
        case down = 0
        case move = 1
        case up = 2
    }

    /// A single continuous contact. The `edge` hint (when the gesture began off-screen) is what lets
    /// the host distinguish a swipe that starts at the bezel — home, app switcher, notification
    /// centre — from one that starts on the content.
    package static func touch(
        _ phase: TouchPhase, x: Double, y: Double, edge: String? = nil, in surface: Surface,
    ) -> Self {
        Self(ffiLend(edge ?? "") { bytes in
            ffiAnswerText(capacity: 160) { out, cap in
                slopdesk_sim_input_touch(
                    phase.rawValue, x, y, bytes.baseAddress, bytes.count, edge != nil,
                    surface.record, out, cap,
                )
            }
        })
    }

    /// Two simultaneous contacts — pinch, spread, two-finger pan. The host derives the gesture from
    /// how the pair moves; there is no separate pinch verb on this wire.
    package static func touch2(
        _ phase: TouchPhase,
        x1: Double, y1: Double, x2: Double, y2: Double,
        in surface: Surface,
    ) -> Self {
        Self(ffiAnswerText(capacity: 200) { out, cap in
            slopdesk_sim_input_touch2(phase.rawValue, x1, y1, x2, y2, surface.record, out, cap)
        })
    }

    // MARK: Hardware and text

    /// A hardware button by its server-side name (`home`, `lock`, `volume-up`, …). `hold` above zero
    /// becomes the `duration` field — the difference between a tap on the side button and the
    /// press-and-hold that summons the power slider.
    package static func button(_ name: String, hold: Double = 0) -> Self {
        Self(ffiLend(name) { bytes in
            ffiAnswerText(capacity: 120) { out, cap in
                slopdesk_sim_input_button(bytes.baseAddress, bytes.count, hold, out, cap)
            }
        })
    }

    /// A held key, as the bit the door reads it by. `CaseIterable` is what lets a caller fold a
    /// platform's own modifier set into this one without a switch per case.
    package enum Modifier: UInt8, CaseIterable {
        case shift = 1
        case control = 2
        case option = 4
        case command = 8
    }

    /// One key by its `KeyboardEvent.code` name (`KeyA`, `Enter`, `ArrowLeft`) — the server owns the
    /// HID page/usage table, so this side stays a dumb sender.
    package static func key(_ code: String, modifiers: [Modifier] = []) -> Self {
        let held = modifiers.reduce(UInt8(0)) { $0 | $1.rawValue }
        return Self(ffiLend(code) { bytes in
            ffiAnswerText(capacity: 160) { out, cap in
                slopdesk_sim_input_key(bytes.baseAddress, bytes.count, held, out, cap)
            }
        })
    }

    /// A run of text as synthesized keystrokes. US-ASCII only — anything outside it must go through
    /// ``paste(_:)``, which routes via the simulator's pasteboard instead.
    package static func type(_ text: String) -> Self {
        render(route: UInt8(SLOPDESK_SIM_TEXT_TYPE), text)
    }

    /// Text into the focused field via the simulator's pasteboard. The path around `type`'s ASCII
    /// limit, and the only one that carries emoji or CJK.
    package static func paste(_ text: String) -> Self {
        render(route: UInt8(SLOPDESK_SIM_TEXT_PASTE), text)
    }

    /// Pull the simulator's current selection onto the host Mac's clipboard.
    package static func copy() -> Self {
        Self(ffiAnswerText(capacity: 32) { out, cap in slopdesk_sim_input_copy(out, cap) })
    }

    private static func render(route: UInt8, _ body: String) -> Self {
        Self(ffiLend(body) { bytes in
            // Arbitrary user input, so the guess is the text plus the object around it; the door
            // reports the true size and the retry pays for anything longer.
            ffiAnswerText(capacity: bytes.count + 64) { out, cap in
                slopdesk_sim_input_text(route, bytes.baseAddress, bytes.count, out, cap)
            }
        })
    }
}

/// The surface as the door's record — a struct copy, no allocation, nothing to free. An extension
/// rather than a member so the C type stays out of the value every caller in the package holds.
private extension SimulatorInputEnvelope.Surface {
    var record: SlopDeskSimSurface { SlopDeskSimSurface(width: width, height: height) }
}
