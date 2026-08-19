// SimulatorChrome — the physical device around the screen, decoded from `/simulators/<udid>/definition.json`.
//
// The panel drew the stream as a bare rectangle on grey before this. That is what an iOS screen is
// NOT: a phone has a body, the body has side buttons, and the screen has rounded corners that clip
// the content. The server already knows all of it — the route hands back DeviceKit's own bezel
// artwork plus the geometry to place it — so drawing a real device is a decode away, and inventing
// the proportions locally would be both wrong and a per-model maintenance job forever.
//
// PERCENTAGES, not points. Every button box is a fraction of the VIEWPORT, so one decode scales to
// any panel width without a second layout pass. Boxes legitimately fall OUTSIDE 0–100%: side buttons
// protrude from the body (`leftPct` is negative on the left rail, past 100 on the right), which is
// also why they draw UNDER the bezel image — the bezel's own edge is what makes a protruding button
// look seated rather than pasted on.
//
// This route answers for a SHUT-DOWN device too: it is DeviceKit data about the model, not state of a
// running process. That is what lets the list preview a device's real silhouette before it is booted.
//
// Untrusted input by the project's rule — validate then drop. A degenerate viewport or screen rect
// fails the whole decode (there is nothing to draw); one unusable button is dropped alone.

import CoreGraphics
import Foundation

package struct SimulatorChrome: Equatable, Sendable {
    package struct Screen: Equatable, Sendable {
        /// The bezel image's own pixel size, and the coordinate space every other number here is in.
        package var viewport: CGSize
        /// Where the live pixels go inside that viewport.
        package var rect: CGRect
        /// The screen's corner radius, in viewport units. Not cosmetic: unclipped video overhangs the
        /// body's rounded corners and reads as a rendering bug.
        package var clipRadius: CGFloat
        /// The body WITHOUT its side buttons drawn in. The panel wants this one — it draws the buttons
        /// itself so they can move under a press. `rest` is the same body with them baked in, kept for
        /// a still preview where nothing is pressable.
        package var barePath: String
        package var restPath: String
    }

    package struct Button: Equatable, Sendable, Identifiable {
        package var id: String
        /// Fractions of the viewport, 0–100, and deliberately allowed outside that range.
        package var leftPercent: CGFloat
        package var topPercent: CGFloat
        package var widthPercent: CGFloat
        package var heightPercent: CGFloat
        package var restPath: String
        package var pressedPath: String
        /// What to send when it is clicked — the server's own button name, taken from the envelope it
        /// supplies rather than assumed to equal `id`.
        package var envelopeButton: String

        /// The button's frame inside a viewport drawn at `size`.
        package func frame(in size: CGSize) -> CGRect {
            CGRect(
                x: size.width * leftPercent / 100,
                y: size.height * topPercent / 100,
                width: size.width * widthPercent / 100,
                height: size.height * heightPercent / 100,
            )
        }
    }

    package var model: String
    package var screen: Screen
    package var buttons: [Button]

    /// The whole viewport including whatever protrudes past it. Side buttons stick out of the body, so
    /// laying out to the viewport alone would clip them at the panel's edge.
    package var bleed: CGRect {
        let viewport = CGRect(origin: .zero, size: screen.viewport)
        return buttons.reduce(viewport) { $0.union($1.frame(in: screen.viewport)) }
    }

    package static func decode(_ data: Data) -> Self? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screen = decodeScreen(root["screen"]) else { return nil }
        let identity = root["identity"] as? [String: Any]
        return Self(
            model: identity?["model"] as? String ?? "",
            screen: screen,
            buttons: (root["buttons"] as? [[String: Any]] ?? []).compactMap(decodeButton),
        )
    }

    private static func decodeScreen(_ value: Any?) -> Screen? {
        guard let screen = value as? [String: Any],
              let viewport = screen["viewport"] as? [String: Any],
              let rect = screen["rect"] as? [String: Any],
              let images = screen["bezelImage"] as? [String: Any],
              let bare = images["bare"] as? String, !bare.isEmpty,
              let rest = images["rest"] as? String, !rest.isEmpty else { return nil }
        let size = CGSize(width: number(viewport["width"]), height: number(viewport["height"]))
        let frame = CGRect(
            x: number(rect["x"]), y: number(rect["y"]),
            width: number(rect["width"]), height: number(rect["height"]),
        )
        // A zero anywhere here means there is no drawable device, and every consumer divides by these.
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        return Screen(
            viewport: size, rect: frame,
            clipRadius: max(0, number(screen["clipRadius"])),
            barePath: bare, restPath: rest,
        )
    }

    private static func decodeButton(_ entry: [String: Any]) -> Button? {
        guard let id = entry["id"] as? String, !id.isEmpty,
              let box = entry["box"] as? [String: Any],
              let images = entry["images"] as? [String: Any],
              let rest = images["rest"] as? String, !rest.isEmpty,
              let pressed = images["pressed"] as? String, !pressed.isEmpty else { return nil }
        let width = number(box["widthPct"])
        let height = number(box["heightPct"])
        // A button with no area cannot be drawn or hit. Dropping it alone keeps the other three.
        guard width > 0, height > 0 else { return nil }
        let envelope = entry["envelope"] as? [String: Any]
        return Button(
            id: id,
            leftPercent: number(box["leftPct"]), topPercent: number(box["topPct"]),
            widthPercent: width, heightPercent: height,
            restPath: rest, pressedPath: pressed,
            envelopeButton: envelope?["button"] as? String ?? id,
        )
    }

    /// A JSON number reaches `JSONSerialization` as an integer or a double depending only on how it
    /// was written, and every field here is legitimately either — `"x": 18` beside `"leftPct": -1.15`
    /// in the same object. One accessor covers both rather than a pair of casts at each field.
    private static func number(_ value: Any?) -> CGFloat {
        if let double = value as? Double { return CGFloat(double) }
        if let integer = value as? Int { return CGFloat(integer) }
        return 0
    }
}
