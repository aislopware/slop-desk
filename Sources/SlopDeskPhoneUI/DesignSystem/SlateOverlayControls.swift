// SlateOverlayControls — the floating family's shared CONTROLS, one component per recurring shape.
//
// ``SlateOverlayCard`` gives every overlay the same SURFACE (glass, rim, plates, keycaps); this file gives
// them the same FURNITURE. Before it, each card hand-rolled its own copy of the same five shapes — the
// caps micro-label, the labelled input, the search bar, the Cancel/confirm footer, the warning line — and
// the copies drifted: one card's label sat a point tighter than another's, one search bar deferred its
// focus grab and another didn't. A surface family only reads as a family while its parts are literally the
// same parts, so the shapes live here once and the overlays compose them.
//
// The ink is `Slate.Native.Overlay` throughout (neutral, system-semantic — never the terminal theme), and
// the editable controls stay NATIVE (`.roundedRect`, the system face at the system size): the card is
// ours, what sits in it is the system's. The system controls take the app's one neutral accent (the
// AccentColor asset), so nothing here re-tints anything.
//
// No AppKit, so this compiles for iOS with the rest of `SlopDeskClientUI`.

#if os(iOS)
import SFSafeSymbols
import SlopDeskSlate
import UIKit

/// A section-level caps micro-label in the instrument voice — a LIST region's caption ("RECENT", the
/// palette's category headers), never a form-field's name. Field labels are sentence-case system text
/// (see ``SlateLabeledFieldView``): a caps-mono run above every input read as instrument engraving, and
/// the photographed form carried three of them stacked. Caps survive only where the palette family
/// already wears them well — naming a run of rows, one per region.
///
/// TRACKING IS AN ATTRIBUTE, NOT A PROPERTY, which is why the text goes through an attributed run rather
/// than straight onto `text`: letter spacing reaches a `UILabel` only as `.kern` on the string. The value
/// is `Slate.Typeface.instrumentTracking` either way — the spacing is the design's, not the renderer's.
@MainActor
final class SlateCapsLabelView: UILabel {
    init(_ text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textColor = Slate.Native.Overlay.tertiary
        // `instrumentNative` memoises the descriptor walk — see its ⚠️ in SlateDesign.swift, where
        // minting one unmemoised costs microseconds per label.
        font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .medium)
        attributedText = NSAttributedString(
            string: text.uppercased(),
            attributes: [.kern: Slate.Typeface.instrumentTracking],
        )
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}

/// One labelled form input: a sentence-case label in the system face (`base`/medium/`secondary` — the
/// register modern form dialogs use; the caps-mono label was photographed and rejected as engraving),
/// then a REAL text field under it.
///
/// `.roundedRect` at the system size is the whole point — it is the SYSTEM's field, so it takes the
/// focus ring, the selection and the height a user expects instead of a look-alike plate that comes up
/// short. A hand-drawn plate was tried and rejected on sight as cramped.
///
/// A two-way binding is one property and one callback here (``text`` and ``onTextChange``). Pretending
/// otherwise — wiring an observable value up the middle of a form — is how a UIKit surface grows a
/// reactive layer it does not need.
@MainActor
final class SlateLabeledFieldView: UIView, UITextFieldDelegate {
    /// Fires on every edit. The caller owns the value; this view never interprets it.
    var onTextChange: (String) -> Void = { _ in }

    var text: String {
        get { field.text ?? "" }
        set { field.text = newValue }
    }

    /// Writing `true` grabs the keyboard; writing `false` gives it up. Reading asks the field, so a tap
    /// into a sibling field is reflected without anything having to publish it.
    ///
    /// The same spelling as ``SlateSearchBarView/isTakingInput`` — and NOT `isFocused`, which is already
    /// `UIView`'s and is the focus ENGINE's property rather than the responder chain's.
    ///
    /// ⚠️ NO OPENING GRAB HERE, unlike the search bar. That component opens a picker and is the only
    /// input on its card, so it can take the keyboard on `didMoveToWindow` unasked; a FORM has four of
    /// these and only the form knows which one leads. So the grab is the caller's, at the callback where
    /// the view is on screen — `becomeFirstResponder()` fails silently before that.
    var isTakingInput: Bool {
        get { field.isFirstResponder }
        set { _ = newValue ? field.becomeFirstResponder() : field.resignFirstResponder() }
    }

    private let caption = UILabel()
    private let field = UITextField()

    /// `mono` monospaces the CONTENT (a port, a number being read back); a hostname is a name and
    /// keeps the system face.
    init(label: String, prompt: String, mono: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.text = label
        caption.textColor = Slate.Native.Overlay.secondary
        caption.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.borderStyle = .roundedRect
        field.attributedPlaceholder = NSAttributedString(
            string: prompt, attributes: [.foregroundColor: Slate.Native.Overlay.tertiary],
        )
        field.font = mono
            ? .monospacedSystemFont(ofSize: Slate.Typeface.body, weight: .regular)
            : .systemFont(ofSize: Slate.Typeface.body)
        field.delegate = self
        field.addTarget(self, action: #selector(edited), for: .editingChanged)

        addSubview(caption)
        addSubview(field)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: Slate.Metric.space1),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func edited() { onTextChange(text) }
}

/// The card-top search input every list overlay opens with: a quiet magnifier, a plain field in the
/// family ink, the input-strip height.
///
/// ⚠️ THERE IS NO DEFERRED FOCUS HERE, AND THAT IS THE POINT. This component's original reason to exist
/// was a timing workaround: a declarative focus flag written in the same tick a view appears is set
/// BEFORE the backing responder is minted, so the framework silently dropped it, and the grab had to hop
/// a runloop through `DispatchQueue.main.async`. Every copy of this bar carried that idiom by hand and
/// one copy forgot, which is the drift the shared component ended.
///
/// UIKit has no such window. A `UITextField` IS its responder from `init`, and the moment the view enters
/// a window — `didMoveToWindow`, which UIKit calls for us — the responder chain it needs to join already
/// exists. So the workaround was not transliterated, it was DROPPED, and the grab is one unconditional
/// line at the one callback that means "you are now mountable". Re-adding a dispatch hop would be cargo
/// cult: the only thing it could still do is move the grab a runloop LATER than the frame the card
/// animates in on.
///
/// FOCUS STAYS THE CALLER'S — ``isTakingInput`` to write and read it, ``onFocusChange`` to hear the
/// user's own taps. The overlays re-grab it on their own events (an advance, a filter change), which a
/// component-private focus could not serve.
@MainActor
final class SlateSearchBarView: UIView, UITextFieldDelegate {
    var onTextChange: (String) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    /// Fires when the USER moved focus, never when ``isTakingInput`` was written — the caller already
    /// knows about its own writes, and echoing them is how a binding loop starts.
    var onFocusChange: (Bool) -> Void = { _ in }

    var text: String {
        get { field.text ?? "" }
        set { field.text = newValue }
    }

    /// Writing `true` grabs the responder; writing `false` gives it up. Reading asks the field, so a
    /// tap elsewhere is reflected without anything having to publish it.
    ///
    /// ⚠️ NOT `isFocused`, which is the obvious name and is already `UIView`'s — the focus-engine
    /// property, about a tvOS/pointer focus ring rather than about the keyboard. Shadowing it
    /// compiles only with `override`, and overriding it would answer the focus engine's question with
    /// the responder chain's answer.
    var isTakingInput: Bool {
        get { field.isFirstResponder }
        set { _ = newValue ? field.becomeFirstResponder() : field.resignFirstResponder() }
    }

    private let magnifier: UIImageView?
    private let field = UITextField()
    /// Set once the bar has taken its opening focus, so a view that leaves a window and comes back
    /// (a card re-shown, a cell recycled) does not steal the responder from wherever it went.
    private var hasTakenOpeningFocus = false

    init(prompt: String, showsMagnifier: Bool = true) {
        magnifier = showsMagnifier ? UIImageView() : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        field.translatesAutoresizingMaskIntoConstraints = false
        field.borderStyle = .none // no bezel of its own: the card is the surface
        field.font = .systemFont(ofSize: Slate.Typeface.body)
        field.textColor = Slate.Native.Overlay.primary
        field.tintColor = Slate.Native.Overlay.primary // the caret is the text's ink, not an accent
        field.attributedPlaceholder = NSAttributedString(
            string: prompt, attributes: [.foregroundColor: Slate.Native.Overlay.tertiary],
        )
        field.returnKeyType = .go
        field.delegate = self
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        addSubview(field)

        var leading = leadingAnchor
        var inset = Slate.Metric.space4
        if let magnifier {
            magnifier.translatesAutoresizingMaskIntoConstraints = false
            magnifier.image = UIImage(systemSymbol: .magnifyingglass)
            magnifier.tintColor = Slate.Native.Overlay.secondary
            magnifier.contentMode = .scaleAspectFit
            magnifier.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.body,
            )
            magnifier.isAccessibilityElement = false
            addSubview(magnifier)
            NSLayoutConstraint.activate([
                magnifier.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: Slate.Metric.space4,
                ),
                magnifier.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            leading = magnifier.trailingAnchor
            inset = Slate.Metric.space2
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightInput),
            field.leadingAnchor.constraint(equalTo: leading, constant: inset),
            field.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.space4,
            ),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasTakenOpeningFocus else { return }
        hasTakenOpeningFocus = true
        field.becomeFirstResponder()
    }

    @objc
    private func edited() { onTextChange(text) }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        onSubmit()
        return false // keep the responder: the overlays submit and stay open
    }

    func textFieldDidBeginEditing(_: UITextField) { onFocusChange(true) }
    func textFieldDidEndEditing(_: UITextField) { onFocusChange(false) }
}

/// A form card's closing line: Cancel and the confirming action, trailing-aligned, on the card's own
/// padding.
///
/// No rule above it — the card's edge already ends the surface, and a divider here is the stacked-boxes
/// look a grouped form left behind. The buttons stay NATIVE configurations (`.plain()` and
/// `.borderedProminent()`), which is what lets the confirm button take the app's one neutral accent
/// without this file naming a colour.
///
/// ⚠️ ESC AND ↩ ARE `UIKeyCommand`s, NOT A PROPERTY ON THE BUTTON. There is no view-level cancel/default
/// role to set; the responder chain answers `keyCommands` instead. The two meanings are the standard
/// ones and they are declared here rather than at the card, so a footer keeps its chords wherever it is
/// mounted.
@MainActor
final class SlateCardFooterView: UIView {
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}

    var confirmDisabled: Bool = false {
        didSet { confirm.isEnabled = !confirmDisabled }
    }

    private let cancel = UIButton(configuration: .plain())
    private let confirm = UIButton(configuration: .borderedProminent())

    init(confirmTitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelled), for: .touchUpInside)

        confirm.translatesAutoresizingMaskIntoConstraints = false
        confirm.setTitle(confirmTitle, for: .normal)
        confirm.addTarget(self, action: #selector(confirmed), for: .touchUpInside)

        addSubview(cancel)
        addSubview(confirm)
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: topAnchor),
            cancel.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -Slate.Metric.space4,
            ),
            confirm.topAnchor.constraint(equalTo: topAnchor),
            confirm.bottomAnchor.constraint(equalTo: cancel.bottomAnchor),
            // Trailing-aligned: the leading edge is a `greaterThanOrEqualTo`, which is what
            // `Spacer(minLength: 0)` said.
            cancel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            confirm.leadingAnchor.constraint(
                equalTo: cancel.trailingAnchor, constant: Slate.Metric.space2,
            ),
            confirm.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Slate.Metric.space4,
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(cancelled),
        )
        let enter = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(confirmed))
        // Off the discoverability sheet: these are the system's own two meanings, and naming them
        // there reads as an app-specific chord the user has to learn.
        escape.wantsPriorityOverSystemBehavior = false
        enter.wantsPriorityOverSystemBehavior = false
        return confirmDisabled ? [escape] : [escape, enter]
    }

    @objc
    private func cancelled() { onCancel() }

    @objc
    private func confirmed() {
        guard !confirmDisabled else { return }
        onConfirm()
    }
}

/// A validation / failure line.
///
/// Amber, because this one IS a status: the neutrality rule is about the chrome not competing for
/// attention, never about suppressing an actual signal. The label wraps rather than truncating
/// (`numberOfLines = 0`) — a warning cut off at the card's edge is a warning that did not arrive.
@MainActor
final class SlateWarningRowView: UIView {
    private let glyph = UIImageView()
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = UIImage(systemSymbol: .exclamationmarkTriangleFill)
        glyph.tintColor = .systemOrange
        glyph.contentMode = .scaleAspectFit
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.isAccessibilityElement = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = .systemOrange
        label.font = .preferredFont(forTextStyle: .callout)
        label.numberOfLines = 0

        addSubview(glyph)
        addSubview(label)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
            // The glyph sits on the FIRST line's baseline box, not the wrapped block's centre — a
            // three-line warning with a vertically centred triangle reads as a bullet for the middle
            // line.
            glyph.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            label.leadingAnchor.constraint(
                equalTo: glyph.trailingAnchor, constant: Slate.Metric.space2,
            ),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        isAccessibilityElement = true
        accessibilityLabel = text
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}
#endif
