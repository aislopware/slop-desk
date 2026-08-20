// KeybindingCaptureHost — the phone's chord recorder, as a first responder.
//
// The Mac records a chord with a local `NSEvent` monitor scoped to its Settings window; a phone has
// no monitor, so the recorder is a VIEW that holds first responder for exactly as long as one row is
// recording and reports every hardware press to it. Zero-sized and non-interactive: it is mounted
// beside the row it records for and must never take a touch the list wanted.
//
// It decides nothing. Which press cancels, which clears and which binds is
// `slopdesk_workspace::phone_key::capture_verdict`, reached through ``PhoneKey/captureOutcome(_:)``
// — the same four answers, in the same numbering, the Mac's recorder gets, because the two write
// into ONE override map (`docs/56` increment 30).
//
// The software keyboard cannot produce a ⌘ or a ⌃, so recording needs a hardware keyboard attached.
// That is a fact about the keyboard rather than a gate this half applies: a bare press still arrives
// and still answers, and Esc is what the user presses to leave a recording they cannot finish.

#if os(iOS)
import SlopDeskWorkspaceCore
import SwiftUI
import UIKit

/// An invisible first responder that reports every hardware key press while `isRecording`.
struct KeybindingCaptureHost: View {
    /// Whether the recorder currently holds first responder.
    let isRecording: Bool
    /// Called for each press while recording, on the main actor.
    let onPress: (PhoneKey.Press) -> Void

    var body: some View {
        KeybindingCaptureResponder(isRecording: isRecording, onPress: onPress)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}

/// Mounts ``KeybindingCaptureView`` and moves first responder with the recording state.
private struct KeybindingCaptureResponder: UIViewRepresentable {
    let isRecording: Bool
    let onPress: (PhoneKey.Press) -> Void

    func makeUIView(context _: Context) -> KeybindingCaptureView {
        let view = KeybindingCaptureView()
        view.onPress = onPress
        return view
    }

    func updateUIView(_ view: KeybindingCaptureView, context _: Context) {
        view.onPress = onPress
        // Idempotent by construction — `becomeFirstResponder` on the current first responder is a
        // no-op, and SwiftUI re-runs this on every state change the row makes while recording.
        if isRecording {
            view.becomeFirstResponder()
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

/// The responder itself. Not a `UIKeyInput`, so becoming first responder does NOT raise the software
/// keyboard — the one thing that would make a settings list unusable while a row records.
final class KeybindingCaptureView: UIView {
    var onPress: ((PhoneKey.Press) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }

    /// Every press is the recorder's while it is recording — including Esc and Backspace, which is
    /// exactly why nothing goes on down the chain: a chain that saw Esc would dismiss the sheet the
    /// user was recording in.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else {
                unhandled.insert(press)
                continue
            }
            onPress?(PhoneKey.Press(key))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
}

extension PhoneKey.Press {
    /// One `UIKey` as the rules' vocabulary. The usage is the key's identity under every layout; the
    /// string is only ever the layout's base, for a ⌃ fold or a binding lookup.
    ///
    /// One spelling of this, for every view that reads a `UIKey` — the terminal's responder, the
    /// chord recorder, and the pane drag's cancel key. A second would be a second answer to "which
    /// key is this", which is the duplicate the whole HID-usage rule exists to prevent.
    init(_ key: UIKey) {
        let modifiers = key.modifierFlags
        self.init(
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            hidUsage: UInt16(key.keyCode.rawValue),
            control: modifiers.contains(.control),
            option: modifiers.contains(.alternate),
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
        )
    }
}
#endif
