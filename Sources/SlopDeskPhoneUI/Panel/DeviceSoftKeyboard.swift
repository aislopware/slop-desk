// DeviceSoftKeyboard — typing into a mirrored device on a phone that has no keyboard attached.
//
// Both mirrors already type: `pressesBegan` reads a `UIKey`, asks the shared rule what it means, and
// sends text or a keycode. That path needs a HARDWARE keyboard. On a Mac there is always one, so the
// capability was complete there and looked complete here — but the phone this ships on most often has
// no keys at all, and on that phone the mirrored device could be tapped, swiped, rotated and
// screenshotted while remaining impossible to type a single character into. The Android half had one
// way round it (the tray's "Paste the clipboard into the device"); the simulator had none.
//
// So this is a PHONE-ONLY affordance closing a phone-only hole, which is the shape the split allows:
// the capability — put text into the device — is the Mac's too, and only the way it is reached
// differs. Nothing here is a second implementation of anything. The bytes go out through the very
// same two calls the hardware path uses, and even BACKSPACE is spelled as the HID usage a real key
// would have reported (`softDeleteUsage`), so the keycode it becomes is still the shared rule's
// answer rather than a constant copied into Swift.
//
// ## Why a registry rather than a flag drilled down
//
// The plate that raises the keyboard sits on the STAGE's toolbar; the responder that receives the
// text is inside the mirror, four representables below it. Threading a `Bool` through both stacks
// would put a typing flag in the signature of every view between them — including two that exist
// only to draw a bezel around a picture. The mirror on screen registers itself instead, exactly as
// the code panel's keyboard ownership is a registered fact rather than a passed one
// (`CodeSidebarKeyboardState`). It is sound BECAUSE of the phone's layout: the panel shows one
// surface, a surface shows one device, so "the mirror on screen" is never ambiguous — and a mirror
// leaving the screen clears the flag on its way out, so the plate cannot be lit for a stage that is
// gone.

#if os(iOS)
import SlopDeskSlate
import SwiftUI
import UIKit

/// The mirror's half of the deal: raise or drop the keyboard, and take what is typed.
@MainActor
protocol DeviceSoftKeyboardHost: AnyObject {
    func setSoftKeyboard(_ armed: Bool)
}

/// Which mirror is on screen, and whether it is currently taking typed text.
@MainActor
@Observable
final class DeviceSoftKeyboard {
    static let shared = DeviceSoftKeyboard()
    private init() {}

    /// Whether the keyboard is up over the mirror. Observed by the stage's plate, so the key is lit
    /// while it is — and, because the mirror writes it back on `resignFirstResponder`, the plate also
    /// goes dark when the keyboard is dismissed by the system's own gesture rather than by the plate.
    private(set) var isTyping = false

    /// The mirror currently mounted. Weak — a stage that has gone away must not be kept alive by a
    /// registry, and a stale entry would send text into a socket that is already closed.
    private weak var host: (any DeviceSoftKeyboardHost)?

    /// Whether a mirror is mounted at all — the plate is hidden without one, rather than offering to
    /// type into an empty stage.
    var hasHost: Bool { host != nil }

    func register(_ host: any DeviceSoftKeyboardHost) {
        self.host = host
    }

    /// A mirror leaving the screen. Guarded on identity: views come and go in either order across a
    /// device switch, and a departing OLD mirror must not unregister the new one that just arrived.
    func unregister(_ host: any DeviceSoftKeyboardHost) {
        guard self.host === host else { return }
        self.host = nil
        isTyping = false
    }

    /// The plate. Idempotent in both directions.
    func toggle() {
        guard let host else { return }
        isTyping.toggle()
        host.setSoftKeyboard(isTyping)
    }

    /// The mirror reporting what actually happened — the keyboard can go down without the plate being
    /// touched (the system's dismiss gesture, a responder change), and a plate lit against a keyboard
    /// that is not there is worse than no plate.
    func report(isTyping: Bool) {
        self.isTyping = isTyping
    }

    /// The USB HID usage a real Backspace key reports. Sent through the same resolve door the
    /// hardware path uses rather than named as a keycode here, so the two spellings of "backspace"
    /// stay one — this file knows a KEY, not a device's table.
    static let softDeleteUsage: UInt16 = 42

    /// The plate's word. Phone-only, so it lives with the phone-only affordance rather than in a
    /// shared presentation both shells read.
    static let plateHelp = "Type into the device"
}

/// The zero-sized responder the soft keyboard actually belongs to.
///
/// A separate view rather than the mirror itself, and that is the whole trick: `UIKeyInput` is what
/// raises the keyboard, and a mirror that adopted it would raise one on every TAP, because the mirror
/// takes first responder on touch so that a hardware keyboard follows the last device touched. Kept
/// as a CHILD of the mirror so the two answers stay ordered without a second rule — while this view
/// holds first responder a hardware press still walks up to the mirror's own `pressesBegan`, so an
/// iPad with a keyboard attached loses nothing by the plate having been pressed.
@MainActor
final class DeviceSoftKeyInput: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    /// Told when the keyboard actually goes down, however it went down.
    var onResign: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    // MARK: UIKeyInput

    /// Always `true`, so the keyboard draws its delete key as live. The mirror holds no text to
    /// report on — the device does, and what it holds is not knowable from here — and answering
    /// `false` would grey out the one key most needed to fix a typo on the device.
    var hasText: Bool { true }

    func insertText(_ text: String) { onText?(text) }

    func deleteBackward() { onDeleteBackward?() }
}
#endif
