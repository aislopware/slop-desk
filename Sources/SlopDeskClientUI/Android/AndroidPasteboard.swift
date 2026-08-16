// AndroidPasteboard — the clipboard hop for a captured frame, and the text hop the other way.
//
// Its own type so the model stays free of AppKit and each write is one testable-by-inspection line
// rather than four inside an action. The twin of ``SimulatorPasteboard``, with the device direction
// added: `scrcpy` can push a string INTO the device's clipboard, which the simulator server has no
// equivalent for.

#if os(macOS)
import AppKit
import Foundation
import SlopDeskWorkspaceCore

enum AndroidPasteboard {
    /// Puts a capture on the general pasteboard as an image. Returns the decoded image so a caller
    /// can tell "the bytes were not an image" from "the write happened" — a truncated PNG is a
    /// problem worth reporting, not a silent no-op.
    @discardableResult
    static func write(png: Data) -> NSImage? { ClientPasteboard.write(image: png) }

    /// What is on the Mac's clipboard as text, or `nil` when it holds something else. The read side
    /// of "paste into the device": the panel takes the Mac's clipboard and sends it, rather than
    /// asking the device for its own — which it deliberately cannot do, since a `GET_CLIPBOARD` would
    /// make the device write a reply into the video stream. See ``AndroidControlMessage``.
    static func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
#endif
