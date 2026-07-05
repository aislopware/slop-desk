// PaneResizeScrim — the "this pane is resizing" cover (REBUILD-V2, L2).
//
// WHY: both resize paths leave a remote pane's content briefly WRONG. A pane-divider drag is committed only
// on release (so the two panes' content is frozen at the pre-drag size while the seam moves), and a
// sidebar/inspector/window-edge resize reflows the SwiftUI frame every step while the host terminal grid is
// held (so the libghostty surface is stretched without a reflow). Either way, the pixels under the cursor
// don't match the layout you're dragging toward. A calm, faint veil reads the moment as a deliberate
// "resizing" state instead of a glitchy stretch, and the real reflow lands cleanly once on release.
//
// Purely decorative: the caller fades it in/out via `.opacity` (so the plate stays in the tree, cheap) and
// keeps it non-hit-testing. Just a translucent paper veil — NO glyph, NO label. SYSTEM/DS colours only.

#if canImport(SwiftUI)
import SwiftUI

struct PaneResizeScrim: View {
    var body: some View {
        // A soft translucent veil in the terminal's own paper colour — dims the frozen / stretched surface so
        // it reads as a deliberate "resizing" haze without fully hiding it. Tune the opacity to taste.
        NativePaneColor.terminalBackground
            .opacity(0.6)
    }
}
#endif
