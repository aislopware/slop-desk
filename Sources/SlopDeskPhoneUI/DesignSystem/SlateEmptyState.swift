// SlateEmptyState — the workspace empty-state voice (MERIDIAN C3), PHONE HALF. The pane area's
// "nothing here" states share ONE quiet composition — a muted symbol, a short title, a one-line cause,
// and (when there is one) the single next action — instead of the native `ContentUnavailableView`,
// whose voice and metrics sit outside the Slate system.
//
// THE COPY IS NOT HERE ANY MORE. Each cause carries its own symbol, title, caption and action label on
// ``PaneEmptyCause`` itself (`SlopDeskClientCore`, pinned by `PaneEmptyCopyTests`), so this view and
// ``SlopDeskMacUI/MacSlateEmptyState`` cannot say two different things about the same connection. The
// four tables are `String`-valued, so they DESCENDED rather than being pinned as a cross-renderer pair
// — docs/56 §3's P6: only a table with a `Color` in it is stuck above `SlopDeskSlate`.
//
// At-rest = zero ornament (the standing bar): plain text on the pane face, no card, no shadow; the
// only chrome is the action's raised plate — which IS the action, not decoration.

#if os(iOS)
import QuartzCore
import SlopDeskClientCore
import SlopDeskSlate
import UIKit

/// The workspace empty state: a muted symbol, a short title, a one-line cause, and the single next
/// action when there is one.
///
/// A faithful transliteration of ``SlopDeskMacUI/MacSlateEmptyState``, the AppKit drawing of the same
/// composition, down to the two custom spacings and the hidden-not-disabled action.
@MainActor
final class SlateEmptyStateView: UIView {
    /// WHY the surface is empty. The cause is ``PaneEmptyCause``, one target down: it is a reading of
    /// the CONNECTION, not a view, and both renderers have to reach the same verdict from the same
    /// status. Assigning re-composes the state.
    var cause: PaneEmptyCause = .neverConnected { didSet { apply() } }

    /// Fires the cause's single next action (Connect editor / New Tab). Ignored when the cause has
    /// none.
    ///
    /// ⚠️ IT CARRIES THE CAUSE, where a declarative version's would have been a bare `() -> Void`. A
    /// view re-made from scratch on every cause change mints its closure already knowing which cause it
    /// answers; this view OUTLIVES the cause — the same object shows `neverConnected`, then `linkDown`
    /// — and a handler that has to infer which one it was just fired for is a handler that can be
    /// wrong. The Mac reached the identical conclusion from the identical constraint.
    var onAction: (PaneEmptyCause) -> Void = { _ in }

    /// The whole composition: the prose, then the action.
    private let column = UIStackView()
    /// The symbol, the title and the caption — one stack, because they are also ONE thing to a screen
    /// reader (see ``apply()``), and an accessibility element needs a real view with a real frame to
    /// be focusable at all.
    private let prose = UIStackView()
    private let glyph = UIImageView()
    private let title = UILabel()
    private let caption = UILabel()
    private let action = SlateEmptyStateActionButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.alignment = .center
        // Twice the column rhythm: the caption-to-action gap is deliberately wider than the gaps
        // inside the prose, so the action reads as an answer to the paragraph rather than its last
        // line.
        column.spacing = Slate.Metric.space2 * 2
        prose.axis = .vertical
        prose.alignment = .center
        prose.spacing = Slate.Metric.space2

        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = Slate.Native.Text.tertiary
        title.font = .systemFont(ofSize: Slate.Typeface.body, weight: .medium)
        title.textColor = Slate.Native.Text.primary
        caption.font = .systemFont(ofSize: Slate.Typeface.base)
        caption.textColor = Slate.Native.Text.secondary
        for label in [title, caption] {
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        action.addTarget(self, action: #selector(acted), for: .touchUpInside)

        for view in [glyph, title, caption] { prose.addArrangedSubview(view) }
        // The symbol sits one rung further from the title than the title does from the caption — it
        // is an illustration of the state, not the first word of the sentence.
        prose.setCustomSpacing(Slate.Metric.space2 + Slate.Metric.space1, after: glyph)
        column.addArrangedSubview(prose)
        column.addArrangedSubview(action)

        addSubview(column)
        NSLayoutConstraint.activate([
            // The column is CENTRED in whatever space it is given, never stretched to fill it.
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.widthAnchor.constraint(
                lessThanOrEqualTo: widthAnchor, constant: -Slate.Metric.space4 * 2,
            ),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func acted() { onAction(cause) }

    private func apply() {
        glyph.image = UIImage(
            systemName: cause.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Typeface.display, weight: .ultraLight,
            ),
        )
        title.text = cause.title
        caption.text = cause.caption
        if let label = cause.actionLabel {
            action.title = label
            action.isHidden = false
        } else {
            // HIDDEN, not disabled — a cause with no next action has no button at all, and a dimmed
            // one would read as an action that is temporarily out of reach.
            action.isHidden = true
        }

        // ⚠️ TWO elements, not one. Folding the whole composition into a single combined element —
        // the obvious reading of "this is one empty state" — would leave the surface's ONLY action
        // reachable solely as a trait on a paragraph. The prose is one element (the symbol carries no
        // words the caption does not already say) and the button stays its own, which is what the
        // Mac's half does and what a screen reader can actually act on.
        glyph.isAccessibilityElement = false
        prose.isAccessibilityElement = true
        prose.accessibilityLabel = [cause.title, cause.caption].joined(separator: ". ")
    }
}

/// The empty state's single next action — the raised plate that IS the action, not decoration
/// (at-rest = zero ornament; it is the only chrome on the surface).
///
/// A bespoke `UIControl` rather than a `UIButton` for the same reason the Mac's is not an `NSButton`:
/// the plate is a Slate composition (fill rung, hairline, radius, `smallFade`), and a system button
/// would have to be stripped of its own before it could wear one.
@MainActor
final class SlateEmptyStateActionButton: UIControl {
    var title: String = "" {
        didSet {
            label.text = title
            // The plate is the element, not the label inside it, so the words have to be handed up.
            accessibilityLabel = title
        }
    }

    private let label = UILabel()
    private var hovering = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        layer.borderWidth = Slate.Metric.hairline
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        label.textColor = Slate.Native.Text.primary
        label.isAccessibilityElement = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.heightBar),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))

        isAccessibilityElement = true
        accessibilityTraits = .button

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (plate: Self, _: UITraitCollection) in
            plate.paint(animated: false)
        }
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ THE PLATE ANSWERS THE PRESS AS WELL AS THE HOVER, which the Mac's does not. The Mac is a
    /// pointer surface, where hover IS the feedback; a phone has no pointer, so a plate that only
    /// lights under a cursor never lights at all and the one action on the screen reads as dead. Same
    /// rung, same fade — only the event that reaches it is new.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            paint()
        }
    }

    @objc
    private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let inside =
            switch recognizer.state {
            case .began,
                 .changed: true
            default: false
            }
        guard hovering != inside else { return }
        hovering = inside
        paint()
    }

    private func paint(animated: Bool? = nil) {
        let fill = hovering || isHighlighted ? Slate.Native.State.hover : Slate.Native.Surface.raised
        CATransaction.begin()
        if animated ?? (window != nil) {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = fill.resolvedColor(with: traitCollection).cgColor
        layer.borderColor = Slate.Native.Line.subtle.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }
}
#endif
