// SimulatorOrientation, SimulatorStatusBar — the two device settings the panel exposes, as pure
// values so the wire strings are pinned by a test rather than typed at a call site.
//
// The server has no READ side for either: both routes set, neither reports. So the panel tracks what
// it last asked for, and both reset when the selection changes — a claim about the previous device
// carried onto the next one would rotate from the wrong angle and show the wrong toggle position.
//
// Every value below is one the SERVER accepts, measured against a live one on 2026-08-04 rather than
// guessed from what the status bar shows. It rejects the whole body on one bad field, so a plausible
// synonym costs the entire preset — `batteryState` is `discharging`, never "unplugged".
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

package enum SimulatorStatusBar {
    /// Apple's marketing status bar: 9:41, full signal, full battery, no charging bolt. The only
    /// reason anyone overrides a status bar is a clean capture, so the panel ships that one preset
    /// rather than a form nobody wants to fill in twice.
    ///
    /// The one thing in this file that did NOT descend: it is a request BODY, not a rule — eight
    /// key/value pairs the panel posts verbatim — and crossing it would be marshalling a dictionary
    /// in both directions to have Rust hand back what Swift already holds.
    package static let demo: [String: String] = [
        "time": "9:41",
        "dataNetwork": "wifi",
        "wifiMode": "active",
        "wifiBars": "3",
        "cellularMode": "active",
        "cellularBars": "4",
        "batteryState": "discharging",
        "batteryLevel": "100",
    ]
}
