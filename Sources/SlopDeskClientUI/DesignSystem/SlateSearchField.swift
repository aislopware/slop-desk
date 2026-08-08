// SlateSearchField — the AppKit-backed plain text field for FOOTNOTE-sized chrome inputs
// (the navigator's search bar). SwiftUI `TextField` is the wrong tool at this one size: at
// `Slate.Typeface.footnote` (11pt) its text renders 1pt LOWER unfocused than focused, so
// click-to-focus visibly bumps the line up. Root cause is AppKit's dual text path — the
// unfocused `NSTextFieldCell` draws the string itself while focus swaps in the window's shared
// field editor (an `NSTextView`), and the two round vertical centering independently; at 11pt
// they disagree by exactly 1pt (12pt+ happens to agree, which is why the overlay fields at
// `Typeface.body` keep the SwiftUI idiom). A bezel-less `NSTextField` left at its INTRINSIC
// height is stable: the cell's bounds are its own preferred metrics, so both paths resolve the
// same origin — measured jump 0.0 vs SwiftUI's 1.0 at the same size, and the line sits
// optically centered in the plate. The intrinsic height is the load-bearing part: the field
// must never be stretched vertically (the container plate centers it), or the cell/field-editor
// rounding split reopens.

#if canImport(AppKit)
import AppKit
import SwiftUI

/// A plain, chrome-styled single-line search input. The caller owns the plate (fill, radius,
/// leading icon, trailing clear affordance) — this is only the text line, jump-free on focus.
struct SlateSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Reports keyboard-focus moves so the caller can draw its focus ring on the plate it owns.
    /// AppKit-sourced on purpose: focus lands via `becomeFirstResponder` (a click into the field —
    /// the delegate's `controlTextDidBeginEditing` waits for the first CHANGE, which would leave a
    /// clicked-but-untyped field ringless) and leaves via `textDidEndEditing`.
    var onFocusChange: ((Bool) -> Void)?

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        /// The field editor exists only once editing begins — the caret can't be inked earlier.
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.insertionPointColor = NSColor(Slate.Text.primary)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    /// The NSTextField subclass that reports focus moves — see ``SlateSearchField/onFocusChange``.
    final class FocusReportingField: NSTextField {
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocusChange?(true) }
            return accepted
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onFocusChange?(false)
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = Self.makeConfiguredField(text: text, delegate: context.coordinator)
        (field as? FocusReportingField)?.onFocusChange = onFocusChange
        applyInk(field)
        return field
    }

    /// The jump-critical configuration, factored out so a headless test can pin it (a `Context`
    /// cannot be constructed outside SwiftUI).
    static func makeConfiguredField(text: String, delegate: NSTextFieldDelegate?) -> NSTextField {
        let field = FocusReportingField(string: text)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none // the plate is the affordance; no system halo
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true // long queries scroll horizontally, never wrap/clip
        field.font = .systemFont(ofSize: Slate.Typeface.footnote)
        field.delegate = delegate
        // Intrinsic height is the jump-free invariant (see header) — refuse vertical stretch.
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        (field as? FocusReportingField)?.onFocusChange = onFocusChange
        // External writes only (the clear button) — echoing every keystroke back would fight the
        // field editor's caret.
        if field.stringValue != text { field.stringValue = text }
        applyInk(field) // theme flips re-run the parent body, which lands here
    }

    /// Ink + placeholder ride the LIVE theme tokens — recomputed on every update pass.
    private func applyInk(_ field: NSTextField) {
        field.textColor = NSColor(Slate.Text.primary)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(Slate.Text.tertiary),
                .font: NSFont.systemFont(ofSize: Slate.Typeface.footnote),
            ],
        )
    }
}
#endif
