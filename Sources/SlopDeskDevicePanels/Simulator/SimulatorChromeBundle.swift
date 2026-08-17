// SimulatorChromeBundle — a device's bezel and the artwork it references, fetched together, as BYTES.
//
// One value rather than a geometry object and a pile of loose images: the panel needs all of it or
// none of it, and a bezel drawn without its button images is a body with holes where the buttons
// should be. The fetch is therefore all-or-nothing on the BODY and best-effort on the BUTTONS — a
// model whose button art the server cannot produce still gets a correct body and a screen in the
// right place, which is the part that matters.
//
// ## Why bytes and not images
//
// This used to be `SimulatorChromeAssets`, holding `NSImage`, which is why it lived in the view
// target and dragged the whole panel MODEL in with it (docs/56). What is actually a decision here is
// WHICH resources to ask for and what makes a fetch a failure; turning the answer into a picture is
// the UI's job, and each UI half has its own picture type. So the bytes stop here and each half
// decodes them — the macOS one into `NSImage`, the iOS one into `UIImage`.
//
// The old shape validated the body by decoding it (`NSImage(data:) != nil` ⇒ fetch succeeded). That
// check moves with the decoding: a body whose bytes are not an image now produces a bundle the UI
// declines to draw, and the panel falls back to the bare screen — the same screen the old nil did.

#if os(macOS)
import Foundation

package struct SimulatorChromeBundle: Sendable, Equatable {
    /// The device this artwork belongs to. Carried so a decoder can cache per device without being
    /// told separately which device it is looking at.
    package let udid: String
    package let chrome: SimulatorChrome
    /// The body WITHOUT its buttons — the panel draws those itself so a press can move them.
    package let body: Data
    /// Per button id, the rest and pressed artwork. A missing entry draws nothing but stays
    /// clickable, which keeps a partial fetch usable rather than dead.
    package let buttons: [String: ButtonArt]

    package struct ButtonArt: Sendable, Equatable {
        package let rest: Data
        package let pressed: Data

        package init(rest: Data, pressed: Data) {
            self.rest = rest
            self.pressed = pressed
        }
    }

    package init(udid: String, chrome: SimulatorChrome, body: Data, buttons: [String: ButtonArt]) {
        self.udid = udid
        self.chrome = chrome
        self.body = body
        self.buttons = buttons
    }

    /// Fetch one device's chrome. `nil` ⇒ no bezel is available, which the panel draws as a bare
    /// screen rather than as an error: a working screen with no body around it is still a working
    /// screen, and a banner over one is worse than a missing frame.
    package static func load(
        udid: String, host: String, port: UInt16, control: SimulatorControlling,
    ) async -> Self? {
        guard let chrome = try? await control.chrome(host: host, port: port, udid: udid),
              let body = try? await control.resource(
                  host: host, port: port, reference: chrome.screen.barePath,
              ), !body.isEmpty else { return nil }

        var buttons: [String: ButtonArt] = [:]
        for button in chrome.buttons {
            async let restData = try? control.resource(
                host: host, port: port, reference: button.restPath,
            )
            async let pressedData = try? control.resource(
                host: host, port: port, reference: button.pressedPath,
            )
            guard let rest = await restData, !rest.isEmpty,
                  let pressed = await pressedData, !pressed.isEmpty else { continue }
            buttons[button.id] = ButtonArt(rest: rest, pressed: pressed)
        }
        return Self(udid: udid, chrome: chrome, body: body, buttons: buttons)
    }
}
#endif
