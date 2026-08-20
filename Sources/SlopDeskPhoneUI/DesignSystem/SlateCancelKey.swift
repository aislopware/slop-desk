// SlateCancelKey — "Escape means cancel", written once.
//
// `.onKeyPress(.escape, phases: .down)` is the whole mechanism, and it is NARROWER than the word
// "Escape" suggests: it needs the view or a descendant to hold keyboard focus, so it is a net under
// the surface's own key handling rather than a catch-all. On a phone that costs nothing — there is
// no hardware Esc to route — and on an iPad with a keyboard it is what there is. It is why the pane
// surfaces that carry it treat it as the SECOND exit: the primary one is the terminal renderer's own
// `keyDown`, and this catches the case where Esc lands in the overlay's focus instead.
//
// ⚠️ It must exist EXACTLY ONCE. It was spelled four times (`ViModeOverlay`, `HintModeOverlay`,
// `TerminalFindBar`, `CommandNavigatorView`), which is four ways for the rule to drift and four
// places to fix when it changes.

#if os(iOS)
import SwiftUI

package extension View {
    /// Run `cancel` when the user asks to back out with Esc.
    ///
    /// Attach it to the surface that OWNS the dismissal, not to the control that draws the `×`: the
    /// key press reaches this view while it OR A DESCENDANT holds focus, so the owning surface still
    /// sees an Esc that landed in one of its children, which a leaf cannot.
    func slateCancelKey(perform cancel: @escaping () -> Void) -> some View {
        onKeyPress(.escape, phases: .down) { _ in
            cancel()
            return .handled
        }
    }
}
#endif
