// SlateSheetSurface — how a NATIVE sheet is made to wear the floating family's own corner.
//
// A sheet is a real `NSWindow`, and a window's corner is cut by its frame view, not by anything the
// content can reach — so a sheet presenting the Connect form came out at the SYSTEM's radius while every
// other summoned surface in the app wears ``Slate/Metric/radiusPanel``. One window in the set rounded
// differently from the other seven is exactly the kind of seam this design has spent its rounds closing.
//
// The fix is two lines on the sheet's window, and it works because of what they imply: with `isOpaque`
// off and the ground cleared, the window paints NOTHING of its own, so whatever the content draws IS the
// sheet's silhouette — corner included — and AppKit derives the window shadow from the resulting alpha,
// which means the cast follows the new shape without being drawn by hand. MEASURED on Tahoe 26.5 by
// presenting both sheets side by side and reading the corner off the pixels: the stock sheet's topmost
// row is inset 29pt from its own left edge, the cleared one 19pt — the family's corner, not the system's.
//
// ⚠️ GUARDED ON `isSheet`. This modifier reaches the window the content happens to be hosted in, and the
// only window it may ever clear is a sheet. Clearing the workspace window would take the ground out from
// under the whole app.
//
// ⚠️ NOT a way to smuggle the in-window card family into a sheet. The surface here is the paper card's
// two ingredients only — the ground's cream at the family's corner, plus the hairline that draws its
// boundary. It carries NO cast shadow of its own: the window already has one, and two shadows on one
// object is the halo that made the earlier sheet experiments look wrong.

#if canImport(SwiftUI)
import SlopDeskSlate
import SwiftUI

#if os(macOS)
import AppKit

/// Zero-size probe that clears the SHEET window hosting it, so the content's own shape becomes the
/// window's silhouette. A no-op in any other window (and off-screen, where `window` is nil).
private struct SlateSheetWindowStyler: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView { StylerView() }

    func updateNSView(_: NSView, context _: Context) {}

    private final class StylerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // `isSheet` is the whole safety story: this is the one window kind whose ground we own.
            guard let window, window.isSheet else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
#endif

extension View {
    /// Draw this content as the SHEET's own surface: the ground's cream at the floating family's corner,
    /// edged by the same hairline the cards use, with the hosting sheet window cleared underneath so the
    /// shape reads all the way to the corner (see the file note). On iOS the platform owns the
    /// presentation entirely and this is the plain surface, with no window to reach.
    func slateSheetSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: Slate.Metric.radiusPanel, style: .continuous)
        return background(Slate.Surface.field, in: shape)
            // The same rim the paper cards wear — one floating family, one boundary rule.
            .overlay { shape.strokeBorder(Slate.Line.overlayRim, lineWidth: Slate.Metric.hairline) }
            .background {
                #if os(macOS)
                SlateSheetWindowStyler().frame(width: 0, height: 0)
                #endif
            }
    }
}
#endif
