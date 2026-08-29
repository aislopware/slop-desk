// SlateComponents — the reusable chrome component kit on the token layer.
//
// Small, composable pieces factored out of the chrome so every surface stays consistent and new views are
// quick to assemble: the terminal-dialect `SlateStatusGlyphView` instrument, the zero-state line, and
// the chrome field plate.
// All built on `Slate.*` tokens + `SlateTheme`. See also SlateControls, SlateRow
// (`SlateListRowView` / `SlateSectionHeaderView`).

#if os(iOS)
import QuartzCore
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskWorkspaceModel // AgentReading / AgentReadout — the readout both renderers' glyphs draw
import UIKit

// `SlateCardModifier` / `.slateCard(radius:fill:)` lived here and had ZERO call sites repo-wide: the
// "floating card" idiom it was factored out for became ``SlatePaperCardSurface`` and the overlay
// family's own surfaces, and nothing ever adopted the modifier. Deleted rather than ported — a spelling
// with no reader is not a floor the port owes a second spelling of.

/// The AGENT status instrument, spoken as TEXT in the terminal's own dialect: each reading is a
/// single character in the instrument (mono) face, centred in a fixed 16pt box — the chrome's status
/// voice IS the pane's voice, exactly the glyphs a CLI would print:
///   • `resting`  → `·` muted (an idle prompt — no colour spent);
///   • `awaiting` → `?` bold in the act-now amber (answer me);
///   • `done`     → `●` (the quiet unread-finish dot, as the character a CLI would print).
/// Mounted where ONE pane's agent state gets a compact readout (the iOS toolbar, the Peek & Reply
/// header). The sidebar rows speak the same states through the trailing mark's hue instead
/// (``StatusPresentation/statusDot(working:badge:)``) — so no glyph column rides the rail.
///
/// ⚠️ `working` is the ONE reading that is not typed: it mounts the rail's own spinner, the drawn
/// braille cell. It used to be a typed pulse (`· ✢ ✳ ✶ ✻ ✽` breathing out and back) and the two
/// surfaces then said the same thing two different ways — one pane could be spinning in the sidebar
/// and blooming in the header at the same instant. There is exactly one working mark in this app now,
/// and every mount of it turns in unison off the same wall clock.
///
/// A faithful transliteration of ``SlopDeskMacUI/MacAgentGlyphView``, the AppKit drawing of the same
/// four states: a label and a spinner, both mounted, one of them hidden. Neither renderer rebuilds a
/// subtree per state — the box has to stay put while the glyph inside it changes, so two views taking
/// turns is what a per-state `switch` becomes once it is spelled out.
@MainActor
final class SlateStatusGlyphView: UIView {
    /// The reading is ``AgentReading``, one floor down: the Mac draws the same four states as an
    /// `NSView` (``SlopDeskMacUI/MacAgentGlyphView``, docs/56 stage D), so the alphabet is one value
    /// with two views of it rather than two enums that agree today.
    typealias Reading = AgentReading

    var reading: Reading = .resting { didSet { show() } }
    /// The ink both the typed glyphs and the spinner's dots take.
    var tint: UIColor = .label { didSet { show() } }

    /// The fixed glyph box — star / dot advance widths differ, so the frame pins layout while the
    /// states swap. Shared with the Mac's `NSView` glyph (``AgentReadout/glyphBox``).
    static let box = CGFloat(AgentReadout.glyphBox)

    private let character = UILabel()
    /// ⚠️ The rail's OWN cell, not a second drawing of one — the whole point of the `working` arm, and
    /// the reason no ticker lives in this file: ``SlateAgentSpinnerView`` owns the display link, starts
    /// it on `didMoveToWindow` and invalidates it when the view leaves.
    private let spinner = SlateAgentSpinnerView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        character.translatesAutoresizingMaskIntoConstraints = false
        character.textAlignment = .center
        // VoiceOver hears the READING from whatever mounts this (a toolbar item, a header) — the box
        // itself is one character wide and would only read the character out.
        isAccessibilityElement = false
        addSubview(character)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.box),
            heightAnchor.constraint(equalToConstant: Self.box),
            character.centerXAnchor.constraint(equalTo: centerXAnchor),
            character.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The spinner keeps its own intrinsic size and is CENTRED in the box — a 16pt text box
            // carrying a 14pt mark, exactly as the rail column does it.
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.box, height: Self.box) }

    private func show() {
        spinner.isHidden = reading != .working
        character.isHidden = !spinner.isHidden
        spinner.tint = tint
        switch reading {
        case .resting: relabel("·", weight: .regular)
        case .working: break
        case .awaiting: relabel("?", weight: .bold)
        case .done: relabel("●", weight: .regular)
        }
    }

    private func relabel(_ text: String, weight: UIFont.Weight) {
        character.text = text
        character.font = Slate.Typeface.instrumentNative(Slate.Typeface.body, weight: weight)
        character.textColor = tint
    }
}

/// The quiet ZERO-STATE line for a list surface — one tertiary-ink body line, centred, with breathing
/// room. Every "no results / no matches / nothing yet" in a palette, search or popover list is this one
/// object (round 13 — four surfaces had hand-rolled the identical block), so the app's empty voice
/// stays text-only and uniform: no illustration, no glyph, no card.
/// The full-pane empty state with its display glyph is a different intent — ``SlateEmptyStateView``.
///
/// ⚠️ `message`, `ink` and `inset` are INIT parameters rather than settable properties. `inset` is the
/// only one that could not be: it is spent as constraint constants, and a line whose padding can be
/// re-set would have to restage them for a value no caller has ever changed after the fact. The other
/// two follow it so the type has one way in.
@MainActor
final class SlateNoResultsLineView: UIView {
    private let label = UILabel()

    /// - Parameters:
    ///   - ink: overlay cards pass their own neutral world's ink (``Slate/Native/Overlay/tertiary``).
    ///   - inset: the vertical breathing room — the roomy default for a results pane; a dense popover
    ///     passes a tighter rung.
    init(
        message: String,
        ink: UIColor = Slate.Native.Text.tertiary,
        inset: CGFloat = Slate.Metric.space4,
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.font = .systemFont(ofSize: Slate.Typeface.body)
        label.textColor = ink
        label.textAlignment = .center
        label.numberOfLines = 0
        addSubview(label)
        NSLayoutConstraint.activate([
            // The line takes the width it is given and centres its text inside it — it never sizes
            // itself to the message.
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}

extension UIView {
    /// The CHROME panel's text-input plate: the hover fill every panel search field already stood on,
    /// plus the boundary it never had. The overlay family's `slateFieldPlate()` is this one's twin — it
    /// has ringed its fields all along, on the reasoning that an unringed field is indistinguishable
    /// from a label, and the panels are what never got the same treatment.
    ///
    /// The fill alone is `quinarySystemFill` — 1.02:1 against the cream ground, which is to say the
    /// field had no perceivable edge at all and read as a gap in the panel rather than a place to type.
    /// The border is what makes it a field. It is deliberately kept LIGHT (1.99:1, user-chosen
    /// 2026-08-08 over a heavier edge that clears the 3.0 non-text floor): the control is still
    /// identified by its own magnifier and placeholder, both well above the reading floor, so the edge
    /// reinforces a boundary rather than carrying it alone.
    ///
    /// Four call sites shared this plate by hand before it was one function; the button plates
    /// deliberately do NOT take it — a button group is not somewhere to type.
    ///
    /// ⚠️ A CONFIGURATOR, not a wrapper — it paints the receiver, because a `UIView` already HAS the
    /// background and the border that a declarative plate had to be handed as two extra layers. Call it
    /// ONCE per view: a second call stacks a second trait registration, and the plate would then re-ink
    /// itself twice for no gain.
    @MainActor
    func slateChromeFieldPlate() {
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        // The fill is a plain `UIColor` on a `UIView`, which UIKit re-resolves for itself; only the
        // BORDER is a `CGColor`, and a `CGColor` is whatever appearance was current when it was taken.
        backgroundColor = Slate.Native.State.hover
        slateInkFieldEdge()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.slateInkFieldEdge()
        }
    }

    @MainActor
    private func slateInkFieldEdge() {
        layer.borderColor = Slate.Native.Line.field.resolvedColor(with: traitCollection).cgColor
    }
}
#endif
