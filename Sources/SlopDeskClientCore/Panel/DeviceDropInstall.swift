// DeviceDropInstall — a file dropped on a simulator stage, read and handed to the model.
//
// Both stages accept a drop, and the two frameworks disagree about everything UP TO the URL — AppKit
// asks an `NSDraggingInfo`'s pasteboard for `NSURL`, UIKit asks a `UIDropSession` to load `URL`s — and
// about nothing after it. What follows the URL is Foundation and the model, so it descends whole.

import Foundation
import SlopDeskDevicePanels

package enum DeviceDropInstall {
    /// Read the bytes at `url` and hand them to `model`, reporting the one failure that is worth a
    /// line rather than a silence.
    ///
    /// ⚠️ THE URL CARRIES A SANDBOX EXTENSION that has to be opened before the bytes can be read. Both
    /// clients are sandboxed, so without the `startAccessingSecurityScopedResource` pair the read fails
    /// on every drop that came from outside the app — and fails as "unreadable", which is the least
    /// informative way for a sandbox denial to arrive.
    @MainActor
    package static func install(_ url: URL, into model: SimulatorSidebarModel) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let contents = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            model.report(SimulatorPresentation.unreadableDrop(url.lastPathComponent))
            return
        }
        await model.send(file: url, contents: contents)
    }
}
