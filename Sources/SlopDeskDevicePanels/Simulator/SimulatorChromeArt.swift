// SimulatorChromeArt — a fetched ``SimulatorChromeBundle``, decoded, and the two rules that decide
// what "decoded" means.
//
// docs/56 stage D, increment 52a. ``SimulatorChromeBundle`` already stops at BYTES on purpose (see its
// header: which resources to ask for is a decision, turning them into a picture is the UI's job, and
// each UI half has its own picture type). That split was right and is unchanged. What it left behind
// was smaller and easier to miss: with two renderers, the two RULES around the decode would each be
// written twice, in two targets, over the same bundle.
//
// ## The two rules, and why neither may be re-derived
//
//   1. **ALL-OR-NOTHING ON THE BODY, BEST-EFFORT ON THE BUTTONS.** Undecodable body bytes mean there
//      is no bezel to draw at all and the stage falls back to the bare screen; an undecodable BUTTON
//      is dropped alone, because a body with one undrawn button is still the right frame around the
//      right screen. A half that got this backwards would either refuse a perfectly good bezel over
//      one missing side button, or draw a body-shaped hole where the device should be.
//   2. **ONE DECODE PER DEVICE, CACHED, ONE ENTRY DEEP.** A bundle is stable for as long as a device
//      is selected, and a view body may be evaluated many times inside that window — decoding four
//      images per evaluation is a per-frame cost for a value that never changes. One entry rather than
//      a map because stepping between two devices re-decodes, which is a once-per-switch cost on
//      artwork the server just sent anyway, and an unbounded map keeps every device's four pictures
//      alive for the life of the panel.
//
// So the fold and the cache descend here, GENERIC over the picture type, and the decode itself stays
// with each half exactly where the bundle's header put it: `NSImage(data:)` on the Mac,
// `Image.decoded(_:)` on the phone. That is the smallest thing that can descend without this target
// naming a view framework — which it must not, and which the supervisor checks.

import Foundation

/// One device's decoded chrome: the geometry, the bare body, and the per-button pair.
///
/// Generic over the picture type so this target names no framework. `Picture` is `NSImage` for the
/// Mac's bezel and SwiftUI's `Image` for the phone's; neither type appears here.
package struct SimulatorChromeArt<Picture> {
    /// The geometry every layout number is a fraction of — the viewport, the screen rect, the buttons.
    package let chrome: SimulatorChrome
    /// The body WITHOUT its buttons. The panel draws those itself so a press can move them.
    package let body: Picture
    /// Per button id: the rest and pressed artwork. A MISSING entry draws nothing and stays clickable,
    /// which is rule 1's second half — the button is still hit-testable and still sends its envelope.
    package let buttons: [String: (rest: Picture, pressed: Picture)]

    /// Decode a bundle. `nil` ⇒ the body bytes are not a picture this platform can read, so there is
    /// no bezel and the caller draws the bare screen.
    package init?(_ bundle: SimulatorChromeBundle, decode: (Data) -> Picture?) {
        guard let body = decode(bundle.body) else { return nil }
        chrome = bundle.chrome
        self.body = body
        buttons = bundle.buttons.reduce(into: [:]) { out, entry in
            guard let rest = decode(entry.value.rest),
                  let pressed = decode(entry.value.pressed) else { return }
            out[entry.key] = (rest, pressed)
        }
    }
}

/// The one decode of a given device's chrome, kept for as long as that device is on screen.
///
/// An INSTANCE rather than a namespace with a static store, and not by taste: a generic type cannot
/// hold a static stored property in Swift, and each half wants its own picture type. Each renderer
/// holds one of these as its own static — one cache per half, which is also the truthful shape, since
/// the two halves never run in the same process.
@MainActor
package final class SimulatorChromeArtCache<Picture> {
    private var cached: (udid: String, art: SimulatorChromeArt<Picture>)?

    package init() {}

    /// Decode `bundle`, reusing the last decode when it is for the same device.
    ///
    /// ⚠️ A FAILED DECODE IS NOT CACHED. It is one `nil` per evaluation for a device whose body bytes
    /// are broken, which is the rare case; caching the failure would mean a bundle re-fetched after a
    /// transient truncation could never draw until the selection moved away and back.
    package func art(
        for bundle: SimulatorChromeBundle, decode: (Data) -> Picture?,
    ) -> SimulatorChromeArt<Picture>? {
        if let cached, cached.udid == bundle.udid { return cached.art }
        guard let art = SimulatorChromeArt(bundle, decode: decode) else { return nil }
        cached = (bundle.udid, art)
        return art
    }
}
