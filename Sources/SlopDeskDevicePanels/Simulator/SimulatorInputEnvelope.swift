// SimulatorInputEnvelope — the client→host half of the simulator dialect: one JSON object per
// gesture, key or button press, sent as a websocket TEXT frame on the same socket the frames arrive
// on.
//
// COORDINATES ARE NOT PIXELS. Every positional envelope carries the `width`/`height` of the surface
// its x/y were measured in, and the host rescales to the device's real framebuffer. That is what lets
// the panel send view-space points directly — no DPI maths on this side, no assumption about the
// device's native resolution, and a window resize mid-drag stays correct because the size travels
// with each event rather than being negotiated once.
//
// Hand-built dictionaries rather than `Codable`: the envelope is a flat heterogeneous bag whose key
// set changes per type (`tap` has x/y, `touch2-move` has x1/y1/x2/y2, `key` has neither), which one
// `Encodable` conformance models only by making every field optional and hoping the right subset is
// populated. A factory per verb makes the wrong combination unrepresentable instead.
//
// `JSONSerialization` with `.sortedKeys` — not for the wire (the server does not care about key
// order) but so the encoder is a pure function of its input and the tests can pin whole strings.

#if os(macOS)
import Foundation

/// One outbound message. Construct through the factories; the raw initializer stays private so a
/// caller cannot assemble a shape the server has no case for.
package struct SimulatorInputEnvelope: Equatable {
    /// The surface the coordinates were measured in. Zero is legal and means "unknown" — the server
    /// treats it as a no-scale hint rather than dividing by it.
    package struct Surface: Equatable {
        package var width: Double
        package var height: Double
    }

    package private(set) var fields: [String: Any]

    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }

    private init(_ fields: [String: Any]) { self.fields = fields }

    private static func positional(
        _ type: String, _ surface: Surface, _ extra: [String: Any],
    ) -> Self {
        var fields: [String: Any] = ["type": type, "width": surface.width, "height": surface.height]
        for (key, value) in extra { fields[key] = value }
        return Self(fields)
    }

    // MARK: Discrete gestures

    /// A tap. `duration` is seconds of contact — the default matches the server's own, and a longer
    /// one is how a long-press is expressed (there is no separate verb for it).
    package static func tap(x: Double, y: Double, duration: Double = 0.05, in surface: Surface) -> Self {
        positional("tap", surface, ["x": x, "y": y, "duration": duration])
    }

    /// A one-finger drag from start to end over `duration` seconds, interpolated host-side. Distinct
    /// from a touch1 down/move/up sequence: this is fire-and-forget, so it suits a scroll wheel or a
    /// trackpad flick, where the client has a delta but no continuous contact to track.
    package static func swipe(
        fromX: Double, fromY: Double, toX: Double, toY: Double,
        duration: Double = 0.25, in surface: Surface,
    ) -> Self {
        positional("swipe", surface, [
            "startX": fromX, "startY": fromY, "endX": toX, "endY": toY, "duration": duration,
        ])
    }

    // MARK: Continuous touch

    package enum TouchPhase: String {
        case down
        case move
        case up
    }

    /// A single continuous contact. The `edge` hint (when the gesture began off-screen) is what lets
    /// the host distinguish a swipe that starts at the bezel — home, app switcher, notification
    /// centre — from one that starts on the content.
    package static func touch(
        _ phase: TouchPhase, x: Double, y: Double, edge: String? = nil, in surface: Surface,
    ) -> Self {
        var extra: [String: Any] = ["x": x, "y": y]
        if let edge { extra["edge"] = edge }
        return positional("touch1-\(phase.rawValue)", surface, extra)
    }

    /// Two simultaneous contacts — pinch, spread, two-finger pan. The host derives the gesture from
    /// how the pair moves; there is no separate pinch verb on this wire.
    package static func touch2(
        _ phase: TouchPhase,
        x1: Double, y1: Double, x2: Double, y2: Double,
        in surface: Surface,
    ) -> Self {
        positional("touch2-\(phase.rawValue)", surface, ["x1": x1, "y1": y1, "x2": x2, "y2": y2])
    }

    // MARK: Hardware and text

    /// A hardware button by its server-side name (`home`, `lock`, `volume-up`, …). `hold` above zero
    /// becomes the `duration` field — the difference between a tap on the side button and the
    /// press-and-hold that summons the power slider.
    package static func button(_ name: String, hold: Double = 0) -> Self {
        var fields: [String: Any] = ["type": "button", "button": name]
        if hold > 0 { fields["duration"] = hold }
        return Self(fields)
    }

    package enum Modifier: String, CaseIterable {
        case shift
        case control
        case option
        case command
    }

    /// One key by its `KeyboardEvent.code` name (`KeyA`, `Enter`, `ArrowLeft`) — the server owns the
    /// HID page/usage table, so this side stays a dumb sender.
    package static func key(_ code: String, modifiers: [Modifier] = []) -> Self {
        var fields: [String: Any] = ["type": "key", "code": code]
        if !modifiers.isEmpty { fields["modifiers"] = modifiers.map(\.rawValue) }
        return Self(fields)
    }

    /// A run of text as synthesized keystrokes. US-ASCII only — anything outside it must go through
    /// ``paste(_:)``, which routes via the simulator's pasteboard instead.
    package static func type(_ text: String) -> Self { Self(["type": "type", "text": text]) }

    /// Text into the focused field via the simulator's pasteboard. The path around `type`'s ASCII
    /// limit, and the only one that carries emoji or CJK.
    package static func paste(_ text: String) -> Self { Self(["type": "paste", "text": text]) }

    /// Pull the simulator's current selection onto the host Mac's clipboard.
    package static func copy() -> Self { Self(["type": "copy"]) }

    // MARK: Encoding

    /// The wire form. `nil` only if a field were non-JSON, which the factories make unreachable —
    /// but it stays optional rather than force-unwrapped, because a trap in an input path is a worse
    /// failure than a dropped gesture.
    package var json: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
