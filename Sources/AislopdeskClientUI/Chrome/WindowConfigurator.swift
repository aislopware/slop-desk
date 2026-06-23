// WindowConfigurator (macOS) — sinks the window chrome so our `WindowTopBar` sits UNDER the native
// traffic lights (warp-window-chrome.md §2/§3): transparent titlebar + full-size content view so our
// 35pt bar draws to the window edge while the OS-drawn traffic lights float over its reserved 80pt
// left inset.

#if os(macOS)
import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async { [weak probe] in
            guard let window = probe?.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.backgroundColor = .clear
        }
        return probe
    }

    func updateNSView(_: NSView, context _: Context) {}
}
#endif
