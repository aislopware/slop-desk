#if os(iOS)
import UIKit

/// A hidden `UITextView` dedicated to IME / marked-text (CJK) composition (doc 17 §2.5).
///
/// Why a *separate, hidden* text view and not `UITextInput` on the key-receiving view: the
/// responder order between a view that handles `pressesBegan` and one that implements
/// `UITextInput` is **undefined**, which breaks multi-stage CJK input (Claude Code has
/// Japanese users). So we give IME its own dedicated proxy: ordinary printable text + CJK
/// composition flow through here → ``onText`` → bytes; `Ctrl`/`Alt`+letter and special keys
/// are routed straight to key encoding by the owner (see ``InputRouting``) and never reach
/// this view.
///
/// The proxy is zero-size + clear + offscreen-ish but first-responder-capable, so iOS routes
/// the system keyboard's composed text to it. We clear its text after each commit so it
/// behaves like a pure byte funnel, never accumulating a document.
public final class IMEProxyTextView: UITextView, UITextViewDelegate {
    /// Fires with each committed text run (post-IME-composition). The owner encodes it to
    /// bytes (`ghostty_surface_text` in the real surface) and sends via `RworkClient.sendInput`.
    public var onText: ((String) -> Void)?

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

    /// Backspace at the start of the (empty) document: route a Delete byte rather than a
    /// no-op. The owner handles the actual key encoding; here we just surface it as text "".
    public override func deleteBackward() {
        if (text ?? "").isEmpty {
            onText?("\u{7F}")   // DEL — the owner may special-case; kept simple here
        } else {
            super.deleteBackward()
        }
    }
}
#endif
