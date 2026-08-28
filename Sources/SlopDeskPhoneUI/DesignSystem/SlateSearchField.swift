// SlateSearchField — the plain text field for FOOTNOTE-sized chrome inputs (the navigator's search
// bar, both device panels' filter rows).
//
// It is the text LINE and nothing else: the caller owns the plate (fill, radius, leading icon,
// trailing clear affordance), so one field serves rows that look nothing alike. The rule it does own
// is INTRINSIC HEIGHT — no vertical frame, no stretch — because every caller lays its plate out
// around the line's natural height, and a field that stretched would blow those rows open.

#if os(iOS)
import SlopDeskSlate
import UIKit

/// The chrome text LINE, configured.
///
/// A `UITextField` SUBCLASS rather than a wrapper view, because the wrapper would be the plate and the
/// plate is the caller's: the navigator's search bar and both device panels' filter rows own their
/// fill, radius, leading icon and trailing clear affordance, and they look nothing alike. Its sibling
/// `SlateSearchBarView` (SlateOverlayControls) is the opposite arrangement for the opposite reason — a
/// summoned card's field IS its own plate, so that one is a `UIView` that draws one.
///
/// INTRINSIC HEIGHT is the rule this line owns: no vertical constraint, no stretch. Every caller lays
/// its plate out around the line's natural height, and a field that stretched would blow those rows
/// open.
///
/// ⚠️ The AppKit twin (`SlopDeskSlate/SlateNativeSearchField`) states that rule far more strongly, and
/// its reason DOES NOT CROSS. On macOS an 11pt `NSTextField` left stretched reopens a 1pt jump between
/// the unfocused cell's drawing and the focused field editor's, because AppKit rounds vertical
/// centering twice on a dual text path. UIKit has one text path and one editor, so there is no jump to
/// reopen here; what carries is only the layout contract — the caller centers the line, and never
/// stretches it.
@MainActor
final class SlateSearchLine: UITextField {
    /// Fires on the user's own typing (`.editingChanged`) and on nothing else. A programmatic write to
    /// `text` does not echo back, so a caller that filters and re-writes cannot start a loop.
    var onTextChange: (String) -> Void = { _ in }

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        borderStyle = .none // the caller's plate is the surface; this field draws no bezel of its own
        font = .systemFont(ofSize: Slate.Typeface.footnote)
        textColor = Slate.Native.Text.primary
        tintColor = Slate.Native.Text.primary // the caret is the text's ink, not an accent
        attributedPlaceholder = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: Slate.Native.Text.tertiary],
        )
        // The chrome's own affordances only. iOS would otherwise capitalise the first letter of a
        // filter query and autocorrect a device name into an English word.
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        // Refuse vertical stretch, allow horizontal give — the intrinsic-height contract above, said
        // to Auto Layout rather than left to the caller to remember.
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addTarget(self, action: #selector(edited), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func edited() { onTextChange(text ?? "") }
}
#endif
