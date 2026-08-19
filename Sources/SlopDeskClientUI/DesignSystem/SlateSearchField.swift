// SlateSearchField — the plain text field for FOOTNOTE-sized chrome inputs (the navigator's search
// bar, both device panels' filter rows).
//
// The two platforms render it DIFFERENTLY, and that is the whole content of this file: the macOS
// half is AppKit because SwiftUI's field has an 11pt rendering bug there, and the iOS half is
// SwiftUI because it does not. Same tokens, same placeholder, same intrinsic-height rule — one
// value, two views, and neither is a fallback for the other.
//
// The jump-free AppKit configuration itself is ``SlopDeskSlate/SlateNativeSearchField`` — the Mac's
// own navigator column mints the same field without a SwiftUI wrapper around it, so the plate is
// described once and this file is the phone-shaped MOUNT of it.

#if canImport(AppKit)
import AppKit
import SlopDeskSlate
import SwiftUI

/// A plain, chrome-styled single-line search input. The caller owns the plate (fill, radius,
/// leading icon, trailing clear affordance) — this is only the text line, jump-free on focus.
package struct SlateSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    @MainActor
    package final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        package init(text: Binding<String>) { self.text = text }

        package func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        /// The field editor exists only once editing begins — the caret can't be inked earlier.
        package func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.insertionPointColor = NSColor(Slate.Text.primary)
        }
    }

    package func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    package func makeNSView(context: Context) -> NSTextField {
        let field = SlateNativeSearchField.makeConfiguredField(
            text: text, delegate: context.coordinator,
        )
        applyInk(field)
        return field
    }

    package func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
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

#else
import SlopDeskSlate
import SwiftUI

/// The same field on the phone, as a plain SwiftUI `TextField`.
///
/// The AppKit half exists to dodge a macOS-only rendering split (the cell draws the string unfocused
/// and the window's shared field editor draws it focused, and at 11pt the two round the vertical
/// centre differently). UIKit has no shared field editor and no such split — a `UITextField` draws
/// its own text in both states — so wrapping one here would be a `UIViewRepresentable` written to
/// avoid a bug that is not on this platform.
///
/// What it DOES keep is the intrinsic-height rule the header calls load-bearing: no vertical frame,
/// no stretch. The caller owns the plate, exactly as on the Mac.
package struct SlateSearchField: View {
    let placeholder: String
    @Binding var text: String

    package init(placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    package var body: some View {
        TextField(
            "",
            text: $text,
            prompt: Text(placeholder).foregroundStyle(Slate.Text.tertiary),
        )
        .textFieldStyle(.plain)
        .font(.system(size: Slate.Typeface.footnote))
        .foregroundStyle(Slate.Text.primary)
        // The chrome's own affordances only. iOS would otherwise capitalise the first letter of a
        // filter query and autocorrect a device name into an English word.
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .tint(Slate.Text.primary)
    }
}
#endif
