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
// macOS: a behind-window `NSVisualEffectView` with the `.sidebar` material — the SAME material the
// NavigationSplitView sidebar and the titlebar band render on (user direction 2026-07-04: "màu nền
// giống như header, nền ở dưới sidebar"), so sidebar → toolbar → canvas is one seamless surface;
// `.underWindowBackground` (the first cut) resolved visibly darker/more opaque and read as a third
// tone. Follows the window's active state. iOS has no behind-window surface — the system background
// is the native equivalent.

#if canImport(SwiftUI)
import SwiftUI

#if os(macOS)
struct WindowGlassBackdrop: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
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
