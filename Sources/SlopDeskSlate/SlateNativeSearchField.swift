// SlateNativeSearchField — the FOOTNOTE-sized chrome input's AppKit configuration, in one place.
//
// The navigator's search bar is an `NSSearchField` the Mac's column owns outright (docs/56 stage D);
// the device panels' filter rows are still a SwiftUI ``SlateSearchField`` wrapping the same class.
// Both plates are the same input, so the jump-free configuration below is minted once and neither
// half re-spells it.
//
// The macOS reason, in full. SwiftUI `TextField` is the wrong tool at this one size: at
// `Slate.Typeface.footnote` (11pt) its text renders 1pt LOWER unfocused than focused, so
// click-to-focus visibly bumps the line up. Root cause is AppKit's dual text path — the unfocused
// `NSTextFieldCell` draws the string itself while focus swaps in the window's shared field editor
// (an `NSTextView`), and the two round vertical centering independently; at 11pt they disagree by
// exactly 1pt (12pt+ happens to agree, which is why the overlay fields at `Typeface.body` keep the
// SwiftUI idiom). A bezel-less `NSTextField` left at its INTRINSIC height is stable: the cell's
// bounds are its own preferred metrics, so both paths resolve the same origin — measured jump 0.0 vs
// SwiftUI's 1.0 at the same size, and the line sits optically centered in the plate. The intrinsic
// height is the load-bearing part: the field must never be stretched vertically (the container plate
// centers it), or the cell/field-editor rounding split reopens.

#if canImport(AppKit)
import AppKit

/// The chrome text line, configured. The caller owns the plate (fill, radius, leading icon, trailing
/// clear affordance) — this is only the line, jump-free on focus.
@MainActor
package enum SlateNativeSearchField {
    /// The jump-critical configuration, factored out so a headless test can pin it (a `Context`
    /// cannot be constructed outside SwiftUI).
    package static func makeConfiguredField(
        text: String, delegate: NSTextFieldDelegate?,
    ) -> NSTextField {
        let field = NSTextField(string: text)
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
}
#endif
