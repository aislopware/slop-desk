// PaneImmersiveCapture — the pane's immersive system-key capture, as ONE platform seam.
//
// Immersive mode sends the OS-reserved chords (⌘Tab, ⌘Space, ⌘`, the F-keys) to the remote host
// instead of letting macOS act on them, and the mechanism is a CGEvent tap: a macOS API with no iOS
// counterpart, and no prospect of one. That is a genuine platform impossibility, not a missing
// feature — so the gate stays. What could not stay is WHERE it was written.
//
// ## The defect this file exists to close
//
// The capture is a LIFECYCLE, not a call: engage on mount, suspend on focus/injectability edges,
// re-engage when the model's remembered wish comes back, tear down on unmount, and a toggle that has
// four outcomes. Left at the call site, that is SEVEN `#if os(macOS)` blocks scattered through
// ``GuiLeafView`` — a stored property, three view modifiers, a computed read, a toggle body, and a
// pair of private helpers — and each one is a place where the phone half was written as an implicit
// empty `#else` that nobody can see from the surrounding code. docs/56 §3 is explicit that a gate
// which is genuinely a platform impossibility must be spelled EXACTLY ONCE, in one place, the way
// ``Image/decoded(_:)`` names `NSImage`/`UIImage` once for the whole client and ``View/slateCancelKey(perform:)``
// names the two cancel keys once for every overlay.
//
// So this type is that one place. On macOS it is a thin policy layer over
// ``SystemKeyCaptureController`` (which owns the tap and every suspension gate); on iOS every method
// is a no-op and ``isSupported`` is `false`. The pane holds ONE of these and branches on nothing.
//
// ## `isSupported` is what keeps the button honest
//
// A no-op twin is only safe when the affordance disappears with it — a toggle that is drawn and does
// nothing is the "listed and inert" defect the palette and binding tables spent two increments
// closing. So the footer reads ``isSupported`` to decide whether the immersive chip exists at all,
// rather than carrying its own `#if`, and the capability is DATA there exactly as a row's platform is.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// One pane's immersive capture. Held as `@State` so the tap dies with the mount — a leaked engaged
/// tap keeps swallowing the session's keyboard with no owner left to disengage it.
@MainActor
final class PaneImmersiveCapture {
    /// Whether this half can capture system keys at all. `false` on iOS — there is no CGEvent tap, and
    /// the footer uses this to omit the toggle rather than draw one that does nothing.
    static var isSupported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    #if os(macOS)
    /// The tap owner. One per pane VIEW: the tap must die with its mount, while the user's on/off
    /// WISH lives on ``RemoteWindowModel/immersiveDesired`` so a detach/reattach remount re-engages
    /// instead of silently dropping the mode.
    private let controller = SystemKeyCaptureController()
    #endif

    init() {}

    /// Whether a tap is live (capture itself may be SUSPENDED behind a gate). `false` on iOS.
    var isEngaged: Bool {
        #if os(macOS)
        controller.isEngaged
        #else
        false
        #endif
    }

    /// The CALLER's suspension gate — pane focus lost, or the sink withheld by a read-only flip.
    /// A SUSPENSION, never a tear-down: swallowing stops, the engagement (and therefore the user's
    /// toggle) survives, and capture resumes by itself the moment the gate re-opens. The old
    /// disengage-on-every-edge design made the toggle silently flake off on any popover or focus blip.
    func setSuspended(_ suspended: Bool) {
        #if os(macOS)
        controller.setSuspended(suspended)
        #endif
    }

    /// RE-ENGAGE from the model's remembered wish — the mount, detach/reattach and relaunch-restore
    /// path, where a fresh view's controller starts disengaged while the wish is still ON. Engages only
    /// once the pane is focused (its window is key, which is the right window for the suspend/resume
    /// observers) and injectable; missing Accessibility trust leaves the wish latched but the tap down,
    /// with no prompt from a passive remount — the user re-toggles to get one.
    func autoEngage(model: RemoteWindowModel?, isFocused: Bool) {
        #if os(macOS)
        guard model?.immersiveEffective == true,
              !controller.isEngaged,
              isFocused,
              model?.canInjectSystemKeys == true,
              SystemKeyCaptureController.isTrusted else { return }
        engage(model: model)
        #endif
    }

    /// The model's EFFECTIVE wish changed UNDER a mounted view — a re-target re-seeds the latch, and
    /// the window entering/leaving native fullscreen flips the override. Keep the tap truthful both
    /// ways: wish OFF tears an engaged tap down, wish ON re-engages through the usual gates.
    func wishChanged(to wish: Bool, model: RemoteWindowModel?, isFocused: Bool) {
        #if os(macOS)
        if wish {
            autoEngage(model: model, isFocused: isFocused)
        } else if controller.isEngaged {
            // Drop the mirror-sync first — it would only re-clear an already-off wish.
            controller.onDisengage = nil
            controller.disengage()
        }
        #endif
    }

    /// UNMOUNT. An unmounted pane must never keep swallowing the keyboard — but an unmount must NOT
    /// clear the model's immersive WISH either (a detach/reattach remount re-engages from it), so the
    /// mirror-sync is dropped before the tap comes down. The wish clears only on the manual toggle-off
    /// and the ⌃⌥⌘E escape chord.
    func teardown() {
        #if os(macOS)
        controller.onDisengage = nil
        controller.disengage()
        #endif
    }

    /// Flips immersive capture for this pane — the footer chip's action, with four outcomes:
    ///
    ///  1. a live tap disengages (its `onDisengage` clears the model's wish);
    ///  2. a wish whose tap never re-engaged (Accessibility trust revoked since the relaunch that
    ///     restored it) just drops the wish, so the chip's tint stops claiming a mode that is not on;
    ///  3. an untrusted first attempt surfaces the system prompt instead of failing silently;
    ///  4. otherwise engage, and latch the wish only if the tap actually came up.
    func toggle(model: RemoteWindowModel?) {
        #if os(macOS)
        if controller.isEngaged {
            controller.disengage() // onDisengage clears the model's wish
            return
        }
        if model?.immersiveEffective == true {
            // `setImmersiveDesired(false)` clears BOTH the latch and the fullscreen auto-arm.
            model?.setImmersiveDesired(false)
            return
        }
        guard model?.canInjectSystemKeys == true else { return }
        guard SystemKeyCaptureController.isTrusted else {
            SystemKeyCaptureController.promptForTrust()
            return
        }
        if engage(model: model) { model?.setImmersiveDesired(true) }
        #endif
    }

    #if os(macOS)
    /// Arms `onDisengage` (the wish's mirror-sync) and engages the tap against the CURRENT key window.
    /// The toggle click / focused remount happened in this pane's window, so it IS the key window right
    /// now — arming the controller's window-key suspend/resume on it matters because another window of
    /// the SAME app going key (Settings, a second satellite) keeps the app active and the pane focused,
    /// so neither the app-active observer nor the focus edge would pause the swallowed keyboard.
    @discardableResult
    private func engage(model: RemoteWindowModel?) -> Bool {
        guard let model else { return false }
        controller.onDisengage = { [weak model] in model?.setImmersiveDesired(false) }
        return controller.engage(
            forward: { [weak model] keyCode, flags, isDown in
                model?.systemKeyInjector?(keyCode, flags, isDown)
            },
            keyWindow: NSApp.keyWindow,
        )
    }
    #endif
}
#endif
