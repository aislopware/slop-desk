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

#if os(macOS)

package enum SimulatorOrientation: String, CaseIterable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight
    case portraitUpsideDown

    /// The server's own spelling — kebab-case, matching `baguette orientation`'s argument.
    package var wireValue: String {
        switch self {
        case .portrait: "portrait"
        case .landscapeLeft: "landscape-left"
        case .landscapeRight: "landscape-right"
        case .portraitUpsideDown: "portrait-upside-down"
        }
    }

    package enum Turn: Sendable {
        case left
        case right
    }

    /// A quarter turn, wrapping. The cycle is the physical one — turning right four times returns to
    /// where it started — so a rotate button can be pressed forever without reaching a dead end.
    package func turned(_ direction: Turn) -> Self {
        let clockwise: [Self] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
        guard let index = clockwise.firstIndex(of: self) else { return .portrait }
        let step = direction == .right ? 1 : clockwise.count - 1
        return clockwise[(index + step) % clockwise.count]
    }

    /// Whether the device is on its side.
    package var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// How far the PANEL must turn the picture to put the device upright, in degrees clockwise.
    ///
    /// The framebuffer never rotates. Measured 2026-08-04 on an iPhone 17 Pro: a rotated Safari still
    /// streams 1206×2622, with its interface drawn sideways INSIDE that portrait buffer — so nothing
    /// about the bezel geometry or the touch mapping changes when the device turns, and the panel's
    /// only job is to turn what it draws. Do not "fix" this by transposing the screen rect: there is
    /// no landscape framebuffer to fit into it.
    package var viewAngle: Double {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 90
        case .landscapeRight: -90
        case .portraitUpsideDown: 180
        }
    }
}

package enum SimulatorStatusBar {
    /// Apple's marketing status bar: 9:41, full signal, full battery, no charging bolt. The only
    /// reason anyone overrides a status bar is a clean capture, so the panel ships that one preset
    /// rather than a form nobody wants to fill in twice.
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
#endif
