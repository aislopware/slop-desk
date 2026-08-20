// SlateSearchField — the plain text field for FOOTNOTE-sized chrome inputs (the navigator's search
// bar, both device panels' filter rows).
//
// It is the text LINE and nothing else: the caller owns the plate (fill, radius, leading icon,
// trailing clear affordance), so one field serves rows that look nothing alike. The rule it does own
// is INTRINSIC HEIGHT — no vertical frame, no stretch — because every caller lays its plate out
// around the line's natural height, and a field that stretched would blow those rows open.

#if os(iOS)
import SlopDeskSlate
import SwiftUI

/// A plain, chrome-styled single-line search input.
///
/// A bare `TextField` rather than a `UIViewRepresentable`: `UITextField` draws its own text focused
/// and unfocused alike, so there is no rendering seam here worth wrapping a view around, and the
/// tokens reach a SwiftUI view directly.
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
