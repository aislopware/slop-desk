// PaneMoveEscapeResponder — the phone's half of escape-to-cancel, as a first responder.
//
// The defect it exists to prevent: an iPad with a hardware keyboard grabs a pane by its handle, the
// drag resolves somewhere the user did not mean, and there is no way OUT of it — every release
// commits whatever zone is under the pointer, so the only bail-out was to steer back onto the
// source pane and hope the centre box resolved. The Mac has had the way out since the affordance
// shipped (``PaneMoveEscapeMonitor``'s local `NSEvent` monitor). The phone had a SINK that mounted
// and did nothing, which docs/56 increment 41 recorded as what it was: a real capability gap, not a
// gate. §3's rule is that layout diverges and capability does not.
//
// ## Why a responder, and not the cancel key every other surface uses
//
// ``View/slateCancelKey(perform:)`` is this module's one spelling of Esc and it CANNOT serve here.
// Its phone half is `.onKeyPress(.escape)`, which needs the view or a descendant to hold keyboard
// FOCUS — and a pane-move drag is a `DragGesture` that never takes any: the terminal the finger
// started over still holds it, which is exactly why the Mac's half is a monitor rather than
// `.onExitCommand`. UIKit has no monitor to install, so a key that no first responder is going to
// deliver can only be read by BECOMING one. The shape is a zero-sized UIKit host's, which reads
// hardware presses for the chord recorder the same way and for the same reason.
//
// ## Armed by the drag, and only where there is a key to press
//
// The grab is edge-triggered on the drag and gated on a hardware keyboard being attached, and the
// gate is not politeness — it is what keeps the feature from breaking the far more common gesture.
// The pane's own responder (`TerminalInputHostView`) is a `UIKeyInput`, so taking first responder
// off it DISMISSES the software keyboard; the dismissal animates, SwiftUI's keyboard avoidance
// re-lays the canvas out under the moving finger, and the drag's coordinate space shifts mid-drag.
// A user with no hardware keyboard loses nothing by this view staying inert — they have no Esc to
// press (the accessory row's `esc` plate is terminal input by design, not a chrome cancel). So the
// grab happens only when `GCKeyboard.coalesced` reports a physical keyboard, which is also the one
// public API that answers that question without waiting for a keystroke. It is read at ARM time,
// not at init, so a keyboard paired after launch is seen.
//
// ## The hand-back
//
// Whoever held the keyboard when the drag started gets it back when the drag ends — remembered
// weakly, restored by identity, and only if this view still actually holds it. That last clause is
// the load-bearing one: a spring-loaded tab reveal can move first responder to another pane's
// responder through `PaneFocusCoordinator` while the drag is still live, and forcing the remembered
// owner back then would take the keyboard off the pane the user just landed on. It is the same
// shape as the Mac's own hand-back (`MacCodeSidebarKeyboard`'s `lastKeyboardOwner`), with the one
// difference UIKit forces: AppKit publishes `window.firstResponder` and UIKit does not, so the
// outgoing owner is found by walking the window for the one public signal there is.
//
// ## The one delta from the Mac's half, stated rather than hidden
//
// The Mac's monitor swallows Esc and returns every OTHER key untouched, so typing during a drag
// still reaches the terminal. Here the keyboard is the drag's for its whole duration: a non-cancel
// press goes on down this view's chain, which is the canvas's SIBLING and not the terminal's
// ancestor, so it reaches nothing. That is the price of the only mechanism iOS offers, it is
// bounded by the length of a held gesture, and it is the same trade a first-responder key reader
// makes while a row records.

#if os(iOS)
import GameController
import SlopDeskWorkspaceCore
import SwiftUI
import UIKit

/// Cancels the live pane-move drag on Esc by holding first responder for exactly as long as the
/// drag is in flight. Mounted by ``PaneMoveEscapeMonitor``'s phone half — nothing else constructs
/// it, because nothing else has a gesture that holds no focus.
struct PaneMoveEscapeResponder: UIViewRepresentable {
    /// Whether a pane-move drag is in flight. The only thing that arms the grab.
    let isActive: Bool
    /// The drag's cancel — the SAME closure the Mac's monitor calls, handed down from the one mount
    /// in `SplitContainer` (clear the view-local move, end the cross-window coordinator). One
    /// implementation of the cancel, actuated by two platform mechanisms.
    let onCancel: () -> Void

    func makeUIView(context _: Context) -> PaneMoveEscapeView {
        let view = PaneMoveEscapeView()
        view.onCancel = onCancel
        view.setArmed(isActive)
        return view
    }

    func updateUIView(_ view: PaneMoveEscapeView, context _: Context) {
        view.onCancel = onCancel
        // Runs on every drag FRAME — the mount's `isActive` is derived from the per-frame move
        // state — which is what makes the arming edge-triggered inside `setArmed` rather than
        // idempotent by luck, and what gives a claim UIKit refused (the view not on a window yet)
        // its retry without a timer.
        view.setArmed(isActive)
    }

    static func dismantleUIView(_ view: PaneMoveEscapeView, coordinator _: ()) {
        // The move layer is conditional (`leaves.count > 1 || paneDrag != nil` in `SplitContainer`),
        // so this view can be torn out WHILE it holds the keyboard — the drag closed its own pane,
        // or the tab went away under it. Disarming here is what returns the keyboard instead of
        // stranding it on a dead view.
        view.setArmed(false)
    }
}

/// The responder itself. Deliberately NOT a `UIKeyInput`, for the reason above:
/// becoming first responder must not raise the software keyboard — a keyboard that appeared because
/// the user grabbed a pane would be the same layout shift the hardware-keyboard gate exists to
/// avoid.
final class PaneMoveEscapeView: UIView {
    /// The drag's cancel. Set on every SwiftUI pass so it never closes over a stale drag.
    var onCancel: () -> Void = {}

    /// The responder this view displaced, given the keyboard back when the drag ends. Weak: a pane
    /// that closed mid-drag must not be kept alive by the thing that borrowed its keyboard.
    private weak var displaced: UIResponder?

    /// Whether the grab is live. It also gates ``canBecomeFirstResponder``, so between drags
    /// nothing in UIKit — a chain search, a `becomeFirstResponder` from above — can hand this view
    /// a keyboard it has no use for.
    private var armed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Zero-sized at the mount already; this is the second half of the same promise. The drag's
        // touches belong to the grab handle and the canvas under it, and a press arrives at the
        // FIRST RESPONDER rather than by hit-test, so refusing touches costs this view nothing.
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { armed }

    // MARK: The grab

    /// Arms or disarms the grab for the drag's current state. Edge-triggered — called on every drag
    /// frame — and it is where the hardware-keyboard gate lives, so `isActive` stays the pure "is a
    /// drag in flight" the mount already knows and this view answers "is there a key to press".
    func setArmed(_ isDragging: Bool) {
        let wanted = isDragging && Self.hardwareKeyboardAttached
        guard wanted != armed else { return }
        armed = wanted
        if wanted { claim() } else { release() }
    }

    /// Take the keyboard for the length of the drag, remembering who had it.
    private func claim() {
        guard !isFirstResponder else { return }
        displaced = window.flatMap(Self.firstResponder(under:))
        guard becomeFirstResponder() else {
            // UIKit refused — this view is not on a window yet, or a transition is in flight. Claim
            // nothing and remember nothing: a half-taken grab is what strands a keyboard. The next
            // drag frame calls back through `setArmed` and tries again.
            displaced = nil
            armed = false
            return
        }
    }

    /// Give the keyboard back to whoever the claim displaced.
    private func release() {
        let owner = displaced
        displaced = nil
        // Only hand back what is actually still held. First responder can have moved on mid-drag —
        // a spring-loaded tab reveal re-focuses through `PaneFocusCoordinator`, whose whole subject
        // is serializing exactly this — and forcing `owner` back then would take the keyboard off
        // the pane the user just landed on. The grab is not re-taken either (`setArmed` is
        // edge-triggered and stays armed), so that drag simply finishes without its cancel key: the
        // coordinator's focus is the newer intent, and a tug-of-war over first responder is the
        // "I typed into the wrong pane" bug it exists to prevent.
        guard isFirstResponder else { return }
        // A restore UIKit refuses (the remembered view was dismantled with the drag) must still end
        // with this view out of the way, or the grab outlives the gesture that armed it.
        if owner?.becomeFirstResponder() != true { resignFirstResponder() }
    }

    // MARK: The key

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, Self.isCancel(key) else {
                unhandled.insert(press)
                continue
            }
            onCancel()
        }
        // Everything that is not the cancel key goes on down the chain — the shape both other press
        // readers in this module use. It will not reach the terminal (see the header's stated
        // delta); passing it on is still right, because the chain is where a system gesture or a
        // menu shortcut lives and swallowing the unknown is what traps the user.
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    /// Whether this press is the cancel key.
    ///
    /// By HID USAGE, read through the one `UIKey` reader this module has (``PhoneKey/Press/init(_:)``,
    /// shared with the terminal responder and the chord recorder) — a second answer to "which key is
    /// this" is what that spelling exists to prevent, and a press identified by the character it
    /// COMMITTED is the defect that cost the phone its whole nav block (`docs/29` #7). The number
    /// itself is `UIKeyboardHIDUsage`'s own case, spelled once for this module in ``PhoneKeyUsage``.
    ///
    /// Modifiers are deliberately not consulted, which is the Mac's rule too: its monitor asks
    /// `slopdesk_key_capture_is_escape` about the key code ALONE, so ⌘Esc and ⌥Esc bail out of a
    /// drag on both halves.
    private static func isCancel(_ key: UIKey) -> Bool {
        PhoneKey.Press(key).hidUsage == PhoneKeyUsage.escape
    }

    /// Whether a physical keyboard is attached — i.e. whether there is an Esc key to press at all.
    /// `GCKeyboard.coalesced` is the only public API that answers without waiting for a keystroke,
    /// and reading it lazily (at arm time, one drag in) is what keeps the launch-time race — the
    /// framework populates it when it first sees a keyboard — out of the answer.
    private static var hardwareKeyboardAttached: Bool { GCKeyboard.coalesced != nil }

    /// The first responder in `view`'s subtree, or `nil` if the keyboard is nobody's.
    ///
    /// UIKit publishes no `window.firstResponder` the way AppKit does, and `UIView.isFirstResponder`
    /// is the one public signal there is, so the owner is found by walking down from the window.
    /// Once per drag, over a tree that is already mounted — not per frame, and never per press.
    private static func firstResponder(under view: UIView) -> UIResponder? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(under: subview) { return found }
        }
        return nil
    }
}
#endif
