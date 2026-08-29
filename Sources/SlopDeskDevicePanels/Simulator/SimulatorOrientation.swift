// SimulatorOrientation — one of the two device settings the panel exposes, as a pure value so the
// wire strings are pinned by a test rather than typed at a call site.
//
// The server has no READ side for it, nor for the status bar beside it: both routes set, neither
// reports. So the panel tracks what it last asked for, and both reset when the selection changes —
// a claim about the previous device carried onto the next one would rotate from the wrong angle and
// show the wrong toggle position.
//
// The status bar's own preset is NOT here any more: it is a request BODY, and the body is
// `slopdesk_sim_status_bar_body`, posted through ``SimulatorControlling/setStatusBar(host:port:udid:demo:)``
// as a flag. The server rejects the whole body on one bad field, so the eight pairs belong on the
// side that builds the request rather than in a dictionary a caller can edit.
//
// ## The orientation is a Rust value with a Swift face
//
// The CASES stay here, because they are what a `switch` in a view body reads and what a stored
// property on the model holds. Everything that is a RULE about them — the wire spelling, the
// clockwise cycle, the view angle, the title — is `slopdesk_devicepanel::simulator::Orientation`,
// reached by the byte below. A quarter-turn cycle written out as a Swift array is the shape that
// looks obviously right and is off by one in the direction nobody tests.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

package enum SimulatorOrientation: String, CaseIterable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight
    case portraitUpsideDown

    /// The byte the crate carries this as — its own discriminant, in this order.
    package var crateByte: UInt8 {
        switch self {
        case .portrait: UInt8(SLOPDESK_SIMULATOR_ORIENTATION_PORTRAIT)
        case .landscapeLeft: UInt8(SLOPDESK_SIMULATOR_ORIENTATION_LANDSCAPE_LEFT)
        case .landscapeRight: UInt8(SLOPDESK_SIMULATOR_ORIENTATION_LANDSCAPE_RIGHT)
        case .portraitUpsideDown: UInt8(SLOPDESK_SIMULATOR_ORIENTATION_PORTRAIT_UPSIDE_DOWN)
        }
    }

    /// The orientation for a crate byte. A byte no build wrote reads as UPRIGHT, which is the
    /// ordinary case and deliberately so: every rule that branches on orientation treats portrait as
    /// "nothing to say", so an unknown value costs a fact line rather than a wrong rotation.
    package init(crateByte: UInt8) {
        self = Self.allCases.first { $0.crateByte == crateByte } ?? .portrait
    }

    /// The server's own spelling — kebab-case, matching `baguette orientation`'s argument.
    package var wireValue: String {
        SimulatorVocabulary.words[30 + Int(crateByte)]
    }

    package enum Turn: Sendable {
        case left
        case right
    }

    /// A quarter turn, wrapping. The cycle is the physical one — turning right four times returns to
    /// where it started — so a rotate button can be pressed forever without reaching a dead end.
    package func turned(_ direction: Turn) -> Self {
        Self(crateByte: slopdesk_simulator_orientation_turned(crateByte, direction == .right))
    }

    /// Whether the device is on its side.
    package var isLandscape: Bool {
        slopdesk_simulator_orientation_is_landscape(crateByte)
    }

    /// How far the PANEL must turn the picture to put the device upright, in degrees clockwise.
    ///
    /// The framebuffer never rotates. Measured 2026-08-04 on an iPhone 17 Pro: a rotated Safari still
    /// streams 1206×2622, with its interface drawn sideways INSIDE that portrait buffer — so nothing
    /// about the bezel geometry or the touch mapping changes when the device turns, and the panel's
    /// only job is to turn what it draws. Do not "fix" this by transposing the screen rect: there is
    /// no landscape framebuffer to fit into it.
    package var viewAngle: Double {
        slopdesk_simulator_orientation_view_angle(crateByte)
    }
}
