// SlateCancelKey — "Escape means cancel", written once.
//
// A `UIKeyCommand` published from `keyCommands` is the whole mechanism, and it is wider than the view
// that draws the overlay: UIKit walks the responder chain, so the surface that OWNS the dismissal sees
// an Esc that landed in one of its children. On a phone that costs nothing — there is no hardware Esc
// to route — and on an iPad with a keyboard it is what there is. It is why the pane surfaces that carry
// it treat it as the SECOND exit: the primary one is the terminal renderer's own key handling, and this
// catches the case where Esc lands in the overlay instead.
//
// ⚠️ It must exist EXACTLY ONCE. It was spelled four times (`ViModeOverlay`, `HintModeOverlay`,
// `TerminalFindBar`, `CommandNavigatorView`), which is four ways for the rule to drift and four
// places to fix when it changes.

#if os(iOS)
import UIKit

package extension UIKeyCommand {
    /// "Escape means cancel", as the key command a responder publishes. The surfaces that need it
    /// return it from `keyCommands`.
    ///
    /// ⚠️ A SELECTOR, NOT A CLOSURE, and it is not an oversight. `UIKeyCommand` dispatches through the
    /// responder chain by `action:`, and a closure would have to be parked on some object the chain can
    /// still reach — which is a retained side table keyed by command identity, i.e. exactly the
    /// bookkeeping the Mac's `MacClosureMenuItem` was written to avoid in the one place it was
    /// unavoidable. Here it IS avoidable: the owning controller has a method, and the chain is what
    /// finds it.
    ///
    /// ATTACH IT TO THE SURFACE THAT OWNS THE DISMISSAL, not to the control that draws the `×`. The
    /// responder chain is what gives that reach, and it gives it without depending on a focus ring
    /// existing — which the declarative `.onKeyPress(.escape)` this replaced could not do: that one
    /// needed the view or a descendant to hold keyboard focus before Esc could reach it at all.
    ///
    /// `wantsPriorityOverSystemBehavior` is deliberately LEFT OFF. Esc has no chrome-level system
    /// behaviour on iOS worth pre-empting, and the one thing it does own — dismissing the keyboard's
    /// own candidate/composition UI — is the case this app must NOT steal: `PhoneKey` (`PhoneKey.swift`)
    /// treats an in-flight composition as the keyboard's, and a cancel that closed the overlay out from
    /// under a half-typed IME string would discard input the user is still holding. The overlay's own
    /// Esc is the SECOND exit, exactly as the file header says; it should lose a race it is second in.
    @MainActor
    static func slateCancel(action: Selector) -> UIKeyCommand {
        UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: action)
    }
}
#endif
