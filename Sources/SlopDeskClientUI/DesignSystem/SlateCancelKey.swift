// SlateCancelKey — "Escape means cancel", written once.
//
// The two shells reach the same key by different routes, and the difference is REAL rather than
// cosmetic:
//
//  * macOS routes it through the RESPONDER CHAIN. `cancelOperation(_:)` — which AppKit sends for Esc
//    AND for ⌘. — walks up from whatever is first responder, so `.onExitCommand` fires even when the
//    focus is somewhere else inside the pane. That is the whole reason these surfaces carry it: the
//    primary exit is the terminal renderer's own `keyDown`, and this is the net for the case where
//    Esc lands in the overlay's chain instead of the surface's.
//  * iOS has no `cancelOperation` and no `.onExitCommand`. `.onKeyPress(.escape, phases: .down)` is
//    the nearest thing, and it is narrower — it needs the view or a descendant to hold keyboard
//    focus. On a phone that costs nothing (there is no hardware Esc to route), and on an iPad with a
//    keyboard it is what there is.
//
// ⚠️ So this is NOT a gate that can be deleted by finding the shared API — there isn't one. It is a
// gate that must exist EXACTLY ONCE. It was spelled four times (`ViModeOverlay`, `HintModeOverlay`,
// `TerminalFindBar`, `CommandNavigatorView`), each with its own copy of the paragraph above, which
// is four ways for the rule to drift and four places to fix when SwiftUI finally unifies the two.
// The phone-only cards (`PaletteView`, `OpenQuicklyView`, `GlobalSearchView`) do NOT use this: their
// Mac counterparts are `MacOverlayPanel` windows, which get Esc from `cancelOperation(_:)` in AppKit
// proper, so the SwiftUI card only ever runs on the phone and only ever needs the key press.

#if canImport(SwiftUI)
import SwiftUI

package extension View {
    /// Run `cancel` when the user asks to back out — Esc, or ⌘. on a Mac.
    ///
    /// Attach it to the surface that OWNS the dismissal, not to the control that draws the `×`: the
    /// point of the macOS half is that it catches the key from anywhere below it in the responder
    /// chain, which a leaf cannot do.
    func slateCancelKey(perform cancel: @escaping () -> Void) -> some View {
        #if os(macOS)
        return onExitCommand(perform: cancel)
        #else
        return onKeyPress(.escape, phases: .down) { _ in
            cancel()
            return .handled
        }
        #endif
    }
}
#endif
