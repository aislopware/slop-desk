// SlateNativeSearchField — the FOOTNOTE-sized chrome input's AppKit configuration, in one place.
//
// TWO Mac surfaces spell this input — the navigator's search bar (``MacNavigatorColumn``) and the
// device panels' filter rows (``MacDevicePanelParts``) — and they are the same plate, so the
// jump-free configuration below is minted once and neither of them re-spells it.
//
// It is now AppKit's alone. The phone's ``SlateSearchField`` used to be an `NSViewRepresentable` over
// this very class; increment 63 made `SlopDeskPhoneUI` iOS-only and that wrapper went with the arm,
// leaving a plain SwiftUI `TextField` there. The measurement below is a macOS text-path fact, so
// nothing was lost in the split — but do not read this file as one half of a pair any more.
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
