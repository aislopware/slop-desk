// WindowGlassBackdrop — the NATIVE window-glass canvas backdrop (card-on-glass canvas, 2026-07-04 v3).
//
// The pane cards float on THIS, not on a theme colour: the v1 card-canvas painted its margin with the
// theme sidebar tone, which sat within a few RGB points of the card fill — no depth read, the whole
// reason that design lasted one day. The system's own under-window material is what the native sidebar
// / titlebar already render on, so with this backdrop the entire window reads as ONE continuous liquid-
// glass surface with the themed terminal / remote-window cards floating on top (the Terminal.app 26
// look). It resolves in the window's effective appearance — the workspace pins `preferredColorScheme`
// to the canvas theme's lightness, so a dark Monokai filter gets dark glass, light filters light glass.
//
// macOS: a behind-window `NSVisualEffectView` (`.underWindowBackground`) — the actual window-backdrop
// material, blurring the desktop behind the window; it works in a normal opaque window (the same way
// the system sidebar does) and follows the window's active state. iOS has no behind-window surface —
// the system background is the native equivalent.

#if canImport(SwiftUI)
import SwiftUI

#if os(macOS)
struct WindowGlassBackdrop: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

#else
struct WindowGlassBackdrop: View {
    var body: some View {
        Color(uiColor: .systemBackground)
    }
}
#endif
#endif
