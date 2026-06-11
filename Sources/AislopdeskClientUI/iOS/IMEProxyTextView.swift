#if os(iOS)
import UIKit

/// The IME / hardware-key first-responder surface (doc 17 §2.5).
///
/// This is the **single** text first responder, so the responder order is never ambiguous: a
/// `UITextView` already implements `UITextInput`, and CJK marked-text composition flows through
/// the marked-text machinery (`setMarkedText`/`textViewDidChange`), **not** `pressesBegan`. We
/// therefore put the hardware-key overrides (`pressesBegan`/`pressesEnded`) **on this same view**
/// — that is the only view that actually receives `UIPress` events while it is first responder.
///
/// The split is by *kind of key*, decided by ``InputRouting``:
/// - **Special keys** (arrows / Esc / Tab / Return / Delete) and **Ctrl/Alt+letter** are
///   intercepted here in `pressesBegan`, routed to the owner's key-encoding path
///   (``onKeyPress``/``onKeyRelease`` → `KeyRepeater` → bytes), and **consumed** (we do not call
///   `super` for them), so the text system never inserts a newline, moves the caret, or deletes.
/// - **Ordinary printable text + CJK composition** falls through to `super`, lands in the text
///   document, and is surfaced via ``onText`` → bytes (`ghostty_surface_text` in the real
///   surface). We clear the document after each commit so the view is a pure byte funnel.
///
/// The view is alpha-0.01 + clear + first-responder-capable, so iOS routes the system keyboard's
/// composed text to it without showing a document.
public final class IMEProxyTextView: UITextView, UITextViewDelegate {
    /// Fires with each committed text run (post-IME-composition). The owner encodes it to
    /// bytes (`ghostty_surface_text` in the real surface) and sends via `AislopdeskClient.sendInput`.
    public var onText: ((String) -> Void)?

    /// A special / modifier key (the key-encoding path) went down. The owner feeds it into its
    /// ``KeyRepeater`` for auto-repeat. These presses are **consumed** here (not passed to the
    /// text system), so e.g. Return never inserts `\n` and arrows never move a caret.
    public var onKeyPress: ((InputRouting.KeyPress) -> Void)?
    /// A previously-pressed key-encoding key went up. The owner stops repeating it.
    public var onKeyRelease: ((InputRouting.KeyPress) -> Void)?

    /// Floating-cursor hooks (doc 17 §2.5): the spacebar long-press floating cursor is delivered
    /// by iOS to the text-input first responder, which is this view. The owner wires these to a
    /// ``FloatingCursorController`` so the horizontal travel becomes ← / → arrow bytes. We do not
    /// move a real caret (there is no document here), so we forward the points without calling
    /// `super`'s caret manipulation.
    public var onFloatingCursorBegin: ((CGPoint) -> Void)?
    public var onFloatingCursorUpdate: ((CGPoint) -> Void)?
    public var onFloatingCursorEnd: (() -> Void)?

    public init() {
        super.init(frame: .zero, textContainer: nil)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func configure() {
        delegate = self
        isHidden = false                // must be in the hierarchy + focusable
        alpha = 0.01                    // visually invisible but still receives input
        backgroundColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        keyboardType = .asciiCapable
        // No scroll / no visible caret artifacts.
        isScrollEnabled = false
        textContainerInset = .zero
    }

    // MARK: UITextViewDelegate

    /// Each insertion (including the final commit of a CJK composition) arrives here. We emit
    /// the text and immediately clear so the next composition starts clean.
    public func textViewDidChange(_ textView: UITextView) {
        // Only emit when there is no in-flight marked text (composition still ongoing).
        guard textView.markedTextRange == nil else { return }
        let committed = textView.text ?? ""
        guard !committed.isEmpty else { return }
        onText?(committed)
        textView.text = ""
    }

    /// The **software** keyboard's Backspace key does not generate `UIPress` events — it calls
    /// `deleteBackward()` directly. The document is always empty (we clear after each commit), so
    /// we surface it as a single Delete key press on the key-encoding path (→ DEL byte), the
    /// same authoritative path a hardware Backspace takes. We never call `super` (there is no
    /// document to mutate), so DEL is emitted exactly once.
    public override func deleteBackward() {
        // During an active IME / Telex composition the document is NOT empty (the steady-state
        // "always empty" assumption only holds at rest). A backspace there is meant to edit the
        // MARKED TEXT — route it back to the text system (which mutates the composition and fires
        // `textViewDidChange`, still withheld from `onText` until `markedTextRange == nil`), and
        // emit NO DEL. Emitting a DEL byte here would both swallow the composition edit and send a
        // spurious Delete to the host. Only emit the host DEL in the empty-document steady state.
        if markedTextRange != nil {
            super.deleteBackward()
            return
        }
        // R10: a SOFTWARE-keyboard Backspace has NO paired `UIPress` release (it calls `deleteBackward()`
        // directly), so a bare `onKeyPress` arms the owner's `KeyRepeater` and never disarms it — after
        // the 350 ms initial delay it floods a DEL byte at 20 Hz (deleting the whole input line and
        // continuing) until the user presses a different special key / loses focus / the view is torn
        // down. Emit a ONE-SHOT instead: the press fires a single DEL synchronously and ARMS the repeat,
        // then the immediate release (same RepeatKey identity `"S:\u{7F}"`) CANCELS the timer before it
        // can fire — exactly one DEL, no runaway. (Hardware Backspace is unaffected: it flows through
        // `pressesBegan`/`pressesEnded`, which already produce a paired release.)
        let del = InputRouting.KeyPress(characters: "\u{7F}", isSpecial: true)
        onKeyPress?(del)
        onKeyRelease?(del)
    }

    // MARK: Hardware keyboard (pressesBegan/Ended → InputRouting → owner's KeyRepeater)
    //
    // This view is the first responder, so it (not any ancestor) receives `UIPress` events.
    // Key-encoding presses are intercepted + consumed here; everything else (plain printable,
    // CJK composition triggers) falls through to `super` so the text system runs normally.

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key,
                  let classified = Self.classify(key),
                  InputRouting.routesToKeyEncoding(classified) else {
                unhandled.insert(press)
                continue
            }
            onKeyPress?(classified)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        handlePressesEnded(presses) { unhandled in super.pressesEnded(unhandled, with: event) }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        handlePressesEnded(presses) { unhandled in super.pressesCancelled(unhandled, with: event) }
    }

    /// Shared release path for `pressesEnded` / `pressesCancelled`. For ANY key that classifies to a
    /// non-modifier press, ALWAYS surface a release — even one that no longer routes to key-encoding.
    /// This is the runaway-repeat fix: when a modifier is released BEFORE its letter, the letter's
    /// release classifies as a PLAIN key (control flag gone) and the old `routesToKeyEncoding` gate
    /// dropped it, so a held Ctrl/Alt+letter repeat never stopped (a 20Hz control-code flood). The
    /// owner's `KeyRepeater` ignores a release for a key it is not holding, so an unrelated release is
    /// a harmless no-op. A non-key-encoding press is still handed to the text system (its keyDown went
    /// to `super`), so plain-text key handling is unchanged.
    private func handlePressesEnded(_ presses: Set<UIPress>, passUnhandled: (Set<UIPress>) -> Void) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let classified = Self.classify(key) else {
                unhandled.insert(press)
                continue
            }
            onKeyRelease?(classified)   // ALWAYS attempt a release (repeater no-ops if not held)
            if !InputRouting.routesToKeyEncoding(classified) {
                unhandled.insert(press)  // plain text key — the text system handles its release too
            }
        }
        passUnhandled(unhandled)
    }

    /// Maps a UIKit `UIKey` into the platform-agnostic ``InputRouting/KeyPress``. Returns `nil`
    /// for a bare modifier press (no usable key) so it is left to `super`.
    static func classify(_ key: UIKey) -> InputRouting.KeyPress? {
        InputRouting.KeyPress(
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            control: key.modifierFlags.contains(.control),
            option: key.modifierFlags.contains(.alternate),
            command: key.modifierFlags.contains(.command),
            shift: key.modifierFlags.contains(.shift),
            isSpecial: Self.isSpecial(key)
        )
    }

    /// True for the non-printable special keys (arrows, Esc, Tab, Return, Delete) that take the
    /// key-encoding path. Recognised by `UIKeyboardHIDUsage`.
    private static func isSpecial(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardEscape, .keyboardTab, .keyboardReturnOrEnter, .keyboardReturn,
             .keyboardDeleteOrBackspace, .keyboardDeleteForward,
             .keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow:
            return true
        default:
            return false
        }
    }

    // MARK: Floating cursor (UITextInput)

    /// iOS streams these while the user long-presses the spacebar and drags. We surface the
    /// points to the owner's ``FloatingCursorController`` (delta → arrow bytes) instead of moving
    /// a non-existent caret, so we deliberately do not call `super`.
    public override func beginFloatingCursor(at point: CGPoint) {
        onFloatingCursorBegin?(point)
    }

    public override func updateFloatingCursor(at point: CGPoint) {
        onFloatingCursorUpdate?(point)
    }

    public override func endFloatingCursor() {
        onFloatingCursorEnd?()
    }
}
#endif
