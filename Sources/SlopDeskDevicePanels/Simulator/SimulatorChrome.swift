// SimulatorChrome — the physical device around the screen, as `slopdesk_devicepanel::sim_chrome`
// decodes it from `/simulators/<udid>/definition.json`.
//
// The LAWS are the crate's. What is left on this side is a cursor walk turning one delivery into
// `CGSize`/`CGRect` and `String` — the same shape ``DeviceSectionReading`` has, and for the same
// reason: the panel is drawn by TWO renderers (`SwiftUI` on the phone, `AppKit` on the Mac) and a
// decode spelled twice is two devices' worth of geometry to keep in step.
//
// ## Why it moved
//
// The panel drew the stream as a bare rectangle on grey before any of this. That is what an iOS
// screen is NOT: a phone has a body, the body has side buttons, and the screen has rounded corners
// that clip the content. The server already knows all of it, so drawing a real device is a decode
// away — and a decode is exactly the thing that is wrong SILENTLY. A screen rect off by a few
// viewport units puts the video through the case.
//
// ## What the door decides, and this file does not
//
// Every refusal and every drop: a degenerate viewport or screen rect fails the whole decode (there
// is nothing to draw, and everything here divides by those numbers), one unusable button is dropped
// alone, and `envelopeButton` falls back to the id. ``bleed`` is computed there too — it is the
// union of every button frame with the viewport, written in the same percent-of-viewport formula
// the buttons are placed by, and a second speller of it is how a side button ends up clipped at one
// renderer's edge and not the other's.
//
// ``Button/frame(in:)`` stays here because it is not a decision: it is the door's own percentages
// composed at a size only the view knows.
//
// ## Percentages, not points
//
// Every button box is a fraction of the VIEWPORT, so one decode scales to any panel width without a
// second layout pass. Boxes legitimately fall OUTSIDE 0–100%: side buttons protrude from the body
// (`leftPct` is negative on the left rail, past 100 on the right), which is also why they draw UNDER
// the bezel image — the bezel's own edge is what makes a protruding button look seated rather than
// pasted on.
//
// This route answers for a SHUT-DOWN device too: it is DeviceKit data about the model, not state of
// a running process. That is what lets the list preview a device's real silhouette before it is
// booted.

import CoreGraphics
import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

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
    /// The whole viewport including whatever protrudes past it. Side buttons stick out of the body,
    /// so laying out to the viewport alone would clip them at the panel's edge. The door computes it
    /// from the same formula ``Button/frame(in:)`` uses.
    package var bleed: CGRect

    /// Decode one `definition.json`, or `nil` when there is no drawable device in it.
    package static func decode(_ data: Data) -> Self? {
        let delivery = simulatorLend(data) { bytes, count in
            wsAnswerBytes { out, cap in slopdesk_sim_chrome(bytes, count, out, cap) }
        }
        guard !delivery.isEmpty else { return nil }
        var blob = DevicePanelBlob(delivery)
        // Read in the door's own order, which is this file's DECLARATION order field for field — see
        // the door. A scratch local per field is where a swapped pair would still type-check.
        let model = blob.text()
        let bleed = CGRect(
            x: blob.number(), y: blob.number(),
            width: blob.number(), height: blob.number(),
        )
        let screen = Screen(
            viewport: CGSize(width: blob.number(), height: blob.number()),
            rect: CGRect(
                x: blob.number(), y: blob.number(),
                width: blob.number(), height: blob.number(),
            ),
            clipRadius: blob.number(),
            barePath: blob.text(), restPath: blob.text(),
        )
        let count = blob.count16()
        let buttons = (0..<count).map { _ in
            Button(
                id: blob.text(),
                leftPercent: blob.number(), topPercent: blob.number(),
                widthPercent: blob.number(), heightPercent: blob.number(),
                restPath: blob.text(), pressedPath: blob.text(),
                envelopeButton: blob.text(),
            )
        }
        return Self(model: model, screen: screen, buttons: buttons, bleed: bleed)
    }
}

extension DevicePanelBlob {
    /// One `[8 bytes big-endian]` `Double` bit pattern, or `0` past the end.
    ///
    /// The number half of ``DevicePanelBlob``'s framing, and it lives beside the two faces that read
    /// one rather than in the shared cursor: the simulator's decode doors are the only ones in the
    /// family whose delivery carries geometry, and a `Double` is the one field where the near side
    /// compares with `==` — the bit pattern is what makes that hold, where a decimal round trip
    /// would not.
    ///
    /// Past the end reads `0`, which is ``DevicePanelBlob``'s own short-delivery discipline: a
    /// layout disagreement loses fields rather than shifting every later one into its neighbour's
    /// slot.
    package mutating func number() -> Double {
        var bits: UInt64 = 0
        for _ in 0..<8 { bits = bits << 8 | UInt64(byte()) }
        return Double(bitPattern: bits)
    }
}

/// Lends one `Data` to a door as the `(bytes, len)` pair the crate reads.
///
/// The `Data`-shaped sibling of ``devicePanelLend(_:_:)``, which lends a `String`. The closure scope
/// IS the safety contract — the pointer is live for exactly the call inside it — so nothing else
/// goes in it. Empty lends a non-null pointer to zero bytes, which every decode door already reads
/// as the same non-answer an unparseable document makes.
func simulatorLend<T>(_ data: Data, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    var bytes = [UInt8](data)
    return bytes.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress, buffer.count)
    }
}
