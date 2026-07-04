// WindowGlassBackdrop — the iOS stand-in for the NATIVE window-glass canvas backdrop (card-on-glass
// canvas, 2026-07-04 v3).
//
// macOS needs NO custom backdrop view: a SwiftUI `NavigationSplitView` window already hosts ONE
// window-spanning `NSVisualEffectView` (material `.contentBackground`, behind-window, active) that the
// system sidebar/titlebar render on — verified by dumping the live view hierarchy on macOS 26. The
// detail column simply stays TRANSPARENT (no `.background`) so that same system surface shows through;
// canvas, sidebar surround and header band are then literally one view — they can never drift apart.
// (Two earlier rounds drew a custom behind-window VEV here with `.underWindowBackground` / `.sidebar`
// materials; both resolved visibly off the system's `.contentBackground` — the user's "2 cái background
// khác nhau". Matching materials by hand is a losing game; showing the system's own layer is not.)
//
// iOS has no behind-window surface — the system background is the native equivalent, applied behind the
// detail content in `WorkspaceRootView`.

#if os(iOS)
import SwiftUI

struct WindowGlassBackdrop: View {
    var body: some View {
        Color(uiColor: .systemBackground)
    }
}
#endif
