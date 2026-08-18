// SimulatorChromeAssets — a fetched `SimulatorChromeBundle`, decoded into pictures this platform
// can draw.
//
// The FETCH is the domain's (`SlopDeskDevicePanels.SimulatorChromeBundle`): which resources a bezel
// references, and what makes a fetch a failure, is the same answer on every platform. What is not
// the same is the picture type, so the bytes stop at the module edge and this decodes them.
//
// The decoded values are SwiftUI `Image`s, not the platform's own picture type, so nothing here is
// platform-shaped at all — the decode itself is ``Image/decoded(_:)``, which is the client's one
// place that names `NSImage` or `UIImage`.
//
// Decoding is cached by device, because a bundle is stable for as long as a device is selected and a
// SwiftUI body may be evaluated many times inside that window — decoding four images per evaluation
// is a per-frame cost for a value that never changes. The cache is keyed on the bundle's udid and
// holds one entry: stepping between two devices re-decodes, which is a once-per-switch cost on
// artwork the server just sent us anyway.

import Foundation
import SlopDeskDevicePanels
import SwiftUI

@MainActor
struct SimulatorChromeAssets {
    var chrome: SimulatorChrome
    /// The body WITHOUT its buttons — the panel draws those itself so a press can move them.
    var body: Image
    /// Per button id: the rest and pressed artwork. Missing entries draw nothing but stay clickable,
    /// which keeps a partial fetch usable rather than dead.
    var buttons: [String: (rest: Image, pressed: Image)]

    /// `nil` ⇒ the body bytes are not an image, so there is no bezel to draw and the panel falls
    /// back to the bare screen. Button art that fails to decode is dropped instead: a body with one
    /// undrawn button is still the right frame around the right screen.
    init?(_ bundle: SimulatorChromeBundle) {
        guard let body = Image.decoded(bundle.body) else { return nil }
        chrome = bundle.chrome
        self.body = body
        buttons = bundle.buttons.reduce(into: [:]) { out, entry in
            guard let rest = Image.decoded(entry.value.rest),
                  let pressed = Image.decoded(entry.value.pressed) else { return }
            out[entry.key] = (rest, pressed)
        }
    }
}

/// The one decode of a given device's chrome, kept for as long as that device is on screen.
@MainActor
enum SimulatorChromeDecoder {
    private static var cached: (udid: String, assets: SimulatorChromeAssets)?

    /// Decode `bundle`, reusing the last decode when it is for the same device. `nil` ⇒ undrawable
    /// body (see ``SimulatorChromeAssets/init(_:)``), which the stage renders as a bare screen.
    static func assets(for bundle: SimulatorChromeBundle) -> SimulatorChromeAssets? {
        if let cached, cached.udid == bundle.udid { return cached.assets }
        guard let assets = SimulatorChromeAssets(bundle) else { return nil }
        cached = (bundle.udid, assets)
        return assets
    }
}
