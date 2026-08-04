// SimulatorChromeAssets — the decoded bezel plus the artwork it references, fetched together.
//
// One value rather than a geometry object and a pile of loose images: the view needs all of it or
// none of it, and a bezel drawn without its button images is a body with holes where the buttons
// should be. The load is therefore all-or-nothing on the BODY (no bare bezel image, no chrome) and
// best-effort on the BUTTONS — a model whose button art the server cannot produce still gets a
// correct body and a screen in the right place, which is the part that matters.
//
// The images are `NSImage`, so this type is main-actor bound and never crosses a task boundary as a
// value. That is fine: it is built inside one `Task` and handed to the model on the main actor.

#if os(macOS)
import AppKit
import Foundation

@MainActor
struct SimulatorChromeAssets {
    var chrome: SimulatorChrome
    /// The body WITHOUT its buttons — the panel draws those itself so a press can move them.
    var body: NSImage
    /// Per button id: the rest and pressed artwork. Missing entries draw nothing but stay clickable,
    /// which keeps a partial fetch usable rather than dead.
    var buttons: [String: (rest: NSImage, pressed: NSImage)]

    static func load(
        udid: String, host: String, port: UInt16, control: SimulatorControlling,
    ) async -> Self? {
        guard let chrome = try? await control.chrome(host: host, port: port, udid: udid),
              let bodyData = try? await control.resource(
                  host: host, port: port, reference: chrome.screen.barePath,
              ),
              let body = NSImage(data: bodyData) else { return nil }

        var buttons: [String: (rest: NSImage, pressed: NSImage)] = [:]
        for button in chrome.buttons {
            async let restData = try? control.resource(
                host: host, port: port, reference: button.restPath,
            )
            async let pressedData = try? control.resource(
                host: host, port: port, reference: button.pressedPath,
            )
            guard let rest = await restData.flatMap(NSImage.init(data:)),
                  let pressed = await pressedData.flatMap(NSImage.init(data:)) else { continue }
            buttons[button.id] = (rest, pressed)
        }
        return Self(chrome: chrome, body: body, buttons: buttons)
    }
}

/// The clipboard hop for a captured frame. Its own type so the model stays free of AppKit and the
/// pasteboard write is one testable-by-inspection line rather than four inside an action.
enum SimulatorPasteboard {
    /// Puts the capture on the general pasteboard as an image. Returns the decoded image so a caller
    /// can tell "the bytes were not an image" from "the write happened" — a JPEG that fails to decode
    /// is a server problem worth reporting, not a silent no-op.
    @discardableResult
    static func write(jpeg: Data) -> NSImage? {
        guard let image = NSImage(data: jpeg) else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        return image
    }
}
#endif
