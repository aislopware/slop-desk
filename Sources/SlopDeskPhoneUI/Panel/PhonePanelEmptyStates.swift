// PhonePanelEmptyStates — the RIGHT panel's three wordless-until-something-happens surfaces, in UIKit
// (docs/62 stage D): the centred empty state, the centred spinner, and the open gate.
//
// All three are the SAME anatomy — a dim glyph, one primary line, one secondary line, centred in the
// whole surface — because the panel has one empty-state voice (MERIDIAN C3) and seven situations that
// speak in it. The gate adds a button and nothing else; that is what makes it the same surface rather
// than a fourth one.
//
// What each says is ``CodePanelPresentation``'s, one target down and shared with the Mac. What is here
// is the drawing: which `UIFont`, which rung of the text ladder, and the fact that a centred stack in
// UIKit is a stack pinned to a centre rather than a `frame(maxWidth:maxHeight:)`.
//
// The AppKit half is ``SlopDeskMacUI/MacPanelEmptyStates`` and this is a faithful transliteration of
// it, down to the two custom spacings and the "detail is the only line that may wrap" constraint. Two
// things differ, and both are the platform rather than the design: the spinner is a
// `UIActivityIndicatorView` (which animates on its own once started, so the window dance the Mac's
// needs is a `didMoveToWindow` rather than a `viewDidMoveToWindow`), and the plate button answers the
// PRESS as well as the hover — a phone has no pointer, so a plate that only lights under a cursor
// never lights at all. ``SlateEmptyStateActionButton`` reached the same conclusion for the pane area's
// empty states, and for the same reason.

#if os(iOS)
import QuartzCore
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

/// The centred empty state: dim glyph, title, detail.
///
/// The DETAIL is selectable on both halves. It is the one line a reader may need to act on — a
/// provisioning command, most of the time — and a command you cannot select is a command you have to
/// retype. On iOS "selectable" is a long-press menu rather than a drag, so it arrives as a
/// `UITextView` with editing and scrolling off rather than as a label with a flag flipped.
@MainActor
final class PhonePanelEmptyStateView: UIView {
    init(_ reading: PanelEmptyState) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = UIImageView(
            image: UIImage(
                systemName: reading.systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: Slate.Typeface.display * 0.6, weight: .regular,
                ),
            ),
        )
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = Slate.Native.Text.tertiary

        let title = UILabel()
        title.text = reading.title
        title.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        title.textColor = Slate.Native.Text.primary
        title.textAlignment = .center
        title.numberOfLines = 0

        let detail = Self.selectableDetail(reading)

        let stack = PhonePanelCentredStack([glyph, title, detail])
        addSubview(stack)
        stack.pin(inside: self)
        // The detail is the only line that can wrap, so it is the only one given a width to wrap
        // WITHIN — without this the stack widens to the longest sentence and the panel scrolls.
        detail.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true

        // ONE element to a screen reader. The glyph is an illustration of the two lines beside it and
        // says nothing they do not; read as its own element it would announce a symbol name.
        glyph.isAccessibilityElement = false
        isAccessibilityElement = false
        accessibilityElements = [detail]
        detail.accessibilityLabel = [reading.title, reading.detail].joined(separator: ". ")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The detail line, selectable without being editable.
    ///
    /// A `UITextView` rather than a `UILabel`, because `UILabel` has no selection on this platform at
    /// all and the alternative — a long-press menu hand-built over a label — would be a second copy
    /// interaction in an app that already has one everywhere else.
    private static func selectableDetail(_ reading: PanelEmptyState) -> UITextView {
        let detail = UITextView()
        detail.text = reading.detail
        detail.font = reading.detailIsCommand
            ? Slate.Typeface.instrumentNative(Slate.Typeface.footnote)
            : .systemFont(ofSize: Slate.Typeface.footnote)
        detail.textColor = Slate.Native.Text.secondary
        detail.textAlignment = .center
        detail.isEditable = false
        detail.isSelectable = true
        // A text view that could scroll would take the drag the surface underneath wants, and there is
        // never more here than three lines. Off, it sizes to its content like the label it replaces.
        detail.isScrollEnabled = false
        detail.backgroundColor = .clear
        // `UITextView` ships an inset and a line-fragment padding a `UILabel` does not have; left in,
        // the detail sits visibly off-centre from the title above it.
        detail.textContainerInset = .zero
        detail.textContainer.lineFragmentPadding = 0
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.setContentCompressionResistancePriority(.required, for: .vertical)
        return detail
    }
}

/// The centred spinner surface — the code-server boot, the two service boots and the pre-push
/// `projectKey` wait share it, because all four are short-lived and all four resolve on their own.
@MainActor
final class PhonePanelWaitingView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(_ label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        spinner.color = Slate.Native.Text.secondary
        spinner.hidesWhenStopped = false

        let text = UILabel()
        text.text = label
        text.font = .systemFont(ofSize: Slate.Typeface.footnote)
        text.textColor = Slate.Native.Text.secondary
        text.textAlignment = .center
        text.numberOfLines = 0

        let stack = PhonePanelCentredStack([spinner, text])
        addSubview(stack)
        stack.pin(inside: self)

        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .updatesFrequently
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// UIKit spinners animate only while asked to, exactly as AppKit's do. A spinner left running under
    /// an unmounted surface is a timer nobody looks at, so the animation rides window membership rather
    /// than the init — which on this platform also covers the panel being dismissed, where the Mac's
    /// column is only ever faded.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { spinner.stopAnimating() } else { spinner.startAnimating() }
    }
}

/// The open gate — what a project shows before its first-ever workbench open (user-directed
/// 2026-08-07).
///
/// Same anatomy as the empty states so the panel keeps one voice, with two differences that are both
/// the gate's subject rather than its style: the detail is the FULL root in the instrument face,
/// middle-truncated to one line, and there is a button.
@MainActor
final class PhoneCodeOpenGateView: UIView {
    init(projectRoot: String, open: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = UIImageView(
            image: UIImage(
                systemName: CodeOpenGateReading.systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: Slate.Typeface.display * 0.6, weight: .regular,
                ),
            ),
        )
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = Slate.Native.Text.tertiary

        let title = UILabel()
        title.text = CodeOpenGateReading.title(projectRoot: projectRoot)
        title.font = .systemFont(ofSize: Slate.Typeface.base, weight: .medium)
        title.textColor = Slate.Native.Text.primary
        title.textAlignment = .center
        title.numberOfLines = 0

        // MIDDLE truncation, one line: the head names the volume and the tail names the checkout, and
        // those are the two ends that tell two same-named projects apart. Truncating the tail would
        // drop exactly the half that answers the question the gate is asking.
        let path = UILabel()
        path.text = projectRoot
        path.font = Slate.Typeface.instrumentNative(Slate.Typeface.footnote)
        path.textColor = Slate.Native.Text.secondary
        path.textAlignment = .center
        path.lineBreakMode = .byTruncatingMiddle
        path.numberOfLines = 1

        let button = PhonePanelPlateButton(title: CodeOpenGateReading.openTitle, action: open)

        let stack = PhonePanelCentredStack([glyph, title, path, button])
        // The button carries the panel's one text-button idiom and stands a rung apart from the lines
        // above it — a verb pressed against its own explanation reads as a fourth line of prose.
        stack.setCustomSpacing(Slate.Metric.space4, after: path)
        addSubview(stack)
        stack.pin(inside: self)
        path.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true

        glyph.isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}

// MARK: - The two pieces all three share

/// A vertical, centre-aligned stack on the panel's empty-state rhythm.
@MainActor
final class PhonePanelCentredStack: UIStackView {
    init(_ views: [UIView]) {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .center
        spacing = Slate.Metric.space2
        translatesAutoresizingMaskIntoConstraints = false
        for view in views { addArrangedSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Centre inside `host` with the panel's own margin, and never wider than it.
    ///
    /// Centred with `centerY`, NOT pinned top and bottom: a stack pinned to both edges of a surface
    /// that is 900pt tall one moment and 200pt the next stretches its spacing rather than staying a
    /// group, and the empty state is a group.
    func pin(inside host: UIView) {
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            centerYAnchor.constraint(equalTo: host.centerYAnchor),
            widthAnchor.constraint(
                lessThanOrEqualTo: host.widthAnchor, constant: -Slate.Metric.space4 * 2,
            ),
        ])
    }
}

/// The panel's one text-button idiom — the same plate the stage views' "Try Again" wears and the gate's
/// "Open" is.
///
/// A bespoke `UIControl` rather than a `UIButton` for the reason ``SlateEmptyStateActionButton`` is
/// one: the plate is a Slate composition (fill rung, radius, `smallFade`), and a system button would
/// have to be stripped of its own before it could wear one.
@MainActor
final class PhonePanelPlateButton: UIControl {
    private let action: () -> Void
    private let label = UILabel()
    /// iPadOS with a trackpad has hover exactly as the Mac does; a touch-only device simply never sets
    /// it, which is why the press below carries the whole acknowledgement there.
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            paint()
        }
    }

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // `radiusControl`, the same rung the Mac's plate takes — the two halves draw one button, and a
        // corner is the part of it a reader can see disagree.
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous

        label.text = title
        label.font = .systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        label.textColor = Slate.Native.Text.primary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isAccessibilityElement = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
        ])
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
        addTarget(self, action: #selector(fire), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button

        // ⚠️ A `CGColor` on a layer is RESOLVED, not dynamic: it was fixed at the appearance current
        // when it was assigned. The registration names the ONE trait this plate depends on rather than
        // waking on every trait change.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (plate: Self, _: UITraitCollection) in
            plate.paint(animated: false)
        }
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// ⚠️ THE PLATE ANSWERS THE PRESS AS WELL AS THE HOVER, which the Mac's does not. A phone has no
    /// pointer, so a plate that only lights under a cursor never lights at all and the one action on
    /// the screen reads as dead. Same rung, same fade — only the event that reaches it is new.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            paint()
        }
    }

    @objc
    private func hovered(_ recogniser: UIHoverGestureRecognizer) {
        switch recogniser.state {
        case .began, .changed: hovering = true
        default: hovering = false
        }
    }

    /// UIKit already withholds `.touchUpInside` for a press dragged off the control, which is the same
    /// contract the Mac's plate writes out by hand in its `mouseUp`.
    @objc
    private func fire() { action() }

    private func paint(animated: Bool? = nil) {
        let fill = hovering || isHighlighted ? Slate.Native.State.selected : Slate.Native.Surface.raised
        CATransaction.begin()
        if animated ?? (window != nil) {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = fill.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }
}
#endif
