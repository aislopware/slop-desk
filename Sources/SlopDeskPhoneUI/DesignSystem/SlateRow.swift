// SlateRow — THE list-row shell (MERIDIAN C2) + the sidebar section header.
//
// `SlateListRowView` is the ONE row anatomy every sidebar/list row shares (the Raycast model): an
// optional leading accessory, a title slot, and a trailing accessory cluster — on a SINGLE
// fixed-height line.
// One shell = one set of constants, so a row can never drift off the system:
//   height    → `heightRow` — every row, always; a row never grows a second line, so the list's
//               rhythm is a constant beat and state changes swap TEXT, not geometry
//   padding   → horizontal `space3`
//   idle      → transparent;  hover → `Slate.Native.State.hover` flat plate
//   active    → a RAISED card: `Slate.Native.Surface.raised` fill + 1px `Slate.Native.Line.card`
//               hairline.
//               NO shadow — at-rest depth is the surface ladder, never a cast shadow (MERIDIAN L5).
// Generic list surfaces (keybindings editor, popover rows) build on this shell. The sidebar TAB row
// (`SlateTabRow`) does NOT — it is the standalone otty `TabsPanelRowView` port with its own measured
// height/inset/shadow.

#if os(iOS)
import QuartzCore
import SlopDeskSlate
import UIKit

/// One list row: `leading` accessory + `title` slot + trailing accessories, on one fixed-height line.
///
/// ⚠️ FOUR SLOTS, FOUR PROPERTIES — not four generic parameters. This shell was
/// `SlateListRow<Leading, Title, TitleTrailing, TrailingOverlay>` while it was SwiftUI, because a
/// `@ViewBuilder` slot is a compile-time thing and every call site paid for one type parameter per
/// slot. UIKit's slot is a `UIView?` a caller assigns, whose `didSet` mounts it and re-runs the row's
/// constraints — the same anatomy with none of the generics. `MacSidebarRow` reached this shape from
/// the identical starting point one platform earlier (docs/56).
///
/// ⚠️ THE HOVER FLAG IS NOT PASSED TO THE SLOTS. SwiftUI would have re-invoked
/// `titleTrailing(isHovering)` and `trailingOverlay(isHovering)` on every hover edge, minting fresh
/// views; a `UIView` slot cannot be re-minted per edge without churning the layout, so the SHELL owns
/// the transition instead and CROSS-FADES the two it was given — `titleTrailing` out,
/// `trailingOverlay` in. That is exactly what the pair was for at every call site (status meta ↔
/// close ×), and it is what the Mac already does: a fixed reserve, so the fade never reflows the
/// title. A row with no `trailingOverlay` never fades anything, which leaves the hover-indifferent
/// callers untouched.
@MainActor
final class SlateListRowView: UIView {
    /// Active/selected treatment — the raised card. Default resting row.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            paint()
        }
    }

    /// Tap action for the whole row. `nil` ⇒ no-op (a presentation-only row) — the recognizer stays
    /// installed either way, so a row does not start and stop swallowing taps as its handler comes
    /// and goes.
    var onTap: (() -> Void)?

    /// EXTERNAL hover, for a row whose events are owned by something else — an overlay whose drag
    /// source swallows the events this shell's own recogniser needs senses hover with its own tracking
    /// area and drives the row through here. `nil` (every other caller) keeps the recogniser.
    var hoverOverride: Bool? {
        didSet {
            guard hoverOverride != oldValue else { return }
            paint()
        }
    }

    /// The leading accessory slot — an icon, a mark, nothing.
    var leading: UIView? { didSet { mount(leading, replacing: oldValue) } }
    /// The title slot. It is the one that YIELDS: it carries the low compression resistance, so a
    /// long title truncates rather than pushing the trailing cluster off the row.
    var title: UIView? { didSet { mount(title, replacing: oldValue) } }
    /// The trailing cluster, right of the title. Fades OUT under hover when a ``trailingOverlay`` is
    /// mounted to take its place.
    var titleTrailing: UIView? { didSet { mount(titleTrailing, replacing: oldValue) } }
    /// The hover-revealed overlay at the same trailing inset — the home for a close `×`. Fades IN.
    var trailingOverlay: UIView? { didSet { mount(trailingOverlay, replacing: oldValue) } }

    private var hovering = false
    private var isHovering: Bool { hoverOverride ?? hovering }
    /// Everything but the height, torn down and rebuilt whenever a slot changes.
    private var slotConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusTab
        layer.cornerCurve = .continuous
        // ⚠️ The card hairline is ALWAYS one hairline wide and goes CLEAR when the row is resting,
        // rather than widening from zero. A width animation would move the row's content inset by a
        // pixel on every selection change; a colour animation is the cross-fade `smallFade` on the
        // active flag is asking for.
        layer.borderWidth = Slate.Metric.cardBorderWidth
        heightAnchor.constraint(equalToConstant: Slate.Metric.heightRow).isActive = true

        // The row draws no text of its own, so it stays a CONTAINER for VoiceOver: every word in it
        // belongs to a slot the caller filled, and an element here would swallow them. (`false` is
        // the `UIView` default; it is written out because it is a decision, not an omission.)
        isAccessibilityElement = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        // `.onHover` — a pointer/trackpad on iPadOS reaches this; a finger never does, and a row that
        // is only ever touched simply stays in its resting treatment, which is correct.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))

        // A `CGColor` on a layer is resolved at assignment, so the ONE trait that can change what it
        // should be has to re-run the paint. (`traitCollectionDidChange` is deprecated on this tree.)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (row: Self, _: UITraitCollection) in
            row.paint(animated: false)
        }
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc
    private func tapped() { onTap?() }

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

    /// Swap one slot's view and re-run the row's constraints. `didSet` does not fire from `init`, so
    /// this is also the only path that ever adds a subview — one paint path, no second spelling.
    private func mount(_ view: UIView?, replacing old: UIView?) {
        guard view !== old else { return }
        old?.removeFromSuperview()
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        restage()
        paint(animated: false)
    }

    /// The row's whole layout: a `space2` run, a minimum `space2` of slack before the trailing
    /// cluster, and the overlay pinned at the same trailing inset.
    /// ⚠️ NOT a `UIStackView`: that slack is an INEQUALITY — the title may end anywhere left of the
    /// cluster — and a stack's spacing is an equality. Pinning the cluster to the trailing edge and
    /// capping the title against it is the same layout with the slack intact.
    private func restage() {
        NSLayoutConstraint.deactivate(slotConstraints)
        slotConstraints = []

        var leadingEdge = leadingAnchor
        var leadingInset = Slate.Metric.space3
        if let leading {
            slotConstraints += [
                leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space3),
                leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
            leadingEdge = leading.trailingAnchor
            leadingInset = Slate.Metric.space2
        }

        // The cluster and the overlay share the trailing inset — that is what lets them cross-fade in
        // place instead of sliding past each other.
        for trailing in [titleTrailing, trailingOverlay].compactMap(\.self) {
            slotConstraints += [
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space3),
                trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.setContentHuggingPriority(.required, for: .horizontal)
        }

        if let title {
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            slotConstraints += [
                title.leadingAnchor.constraint(equalTo: leadingEdge, constant: leadingInset),
                title.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
            if let titleTrailing {
                slotConstraints.append(title.trailingAnchor.constraint(
                    lessThanOrEqualTo: titleTrailing.leadingAnchor, constant: -Slate.Metric.space2,
                ))
            } else {
                slotConstraints.append(title.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -Slate.Metric.space3,
                ))
            }
        }
        NSLayoutConstraint.activate(slotConstraints)
    }

    /// The whole visual state in one place: fill, hairline and the hover cross-fade. Animated by
    /// default, silent before the row is in a window — a row configured between `init()` and its
    /// `addSubview` must arrive already wearing its treatment, not animate into it.
    private func paint(animated: Bool? = nil) {
        let fill: UIColor =
            if active {
                Slate.Native.Surface.raised
            } else if isHovering {
                Slate.Native.State.hover
            } else {
                .clear
            }
        let border: UIColor = active ? Slate.Native.Line.card : .clear
        // ⚠️ `layer.opacity`, not `alpha`. `alpha` needs a `UIView.animate` block, which cannot carry
        // this token's bezier — only its duration. Setting the SUBLAYER's opacity from outside such a
        // block runs the layer's implicit animation, which takes both off the transaction. `.opacity`
        // is the layer property a declarative fade lowers to anyway (docs/62 §3.2).
        // Full presence or none — not a token rung: `Slate.Opacity` is a ladder of DOSES (a wash, a
        // rim, a dim), and "is this view here" is not a dose. `MacSidebarRow` spells its own version
        // of this cross-fade the same bare way.
        let fades = trailingOverlay != nil
        let clusterOpacity: Float = fades && isHovering ? 0 : 1
        let overlayOpacity: Float = isHovering ? 1 : 0

        CATransaction.begin()
        if animated ?? (window != nil) {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = fill.resolvedColor(with: traitCollection).cgColor
        layer.borderColor = border.resolvedColor(with: traitCollection).cgColor
        titleTrailing?.layer.opacity = clusterOpacity
        trailingOverlay?.layer.opacity = overlayOpacity
        CATransaction.commit()
    }
}

/// A sidebar section header: uppercase, tertiary, small — two labels and an optional trailing
/// accessory slot (e.g. "+"), on three insets.
///
/// The `caption` is a qualifier that belongs to the TITLE and is drawn immediately after it, one ink
/// quieter, in the same engraved register. Distinct from ``accessory``, which is pinned to the far
/// trailing edge where a CONTROL belongs: a qualifier sent there stops reading as part of the heading
/// the wider the surface gets, until at panel width it is a lone readout marooned across an empty
/// rule.
@MainActor
final class SlateSectionHeaderView: UIView {
    /// Drawn UPPERCASE, in the INSTRUMENT voice (MERIDIAN L2) — mono + wide tracking, the "engraved
    /// on the tool" register that marks taxonomy against the prose rows below.
    var title: String = "" { didSet { relabel() } }
    /// The qualifier that belongs to the TITLE, one ink quieter, immediately after it.
    var caption: String? { didSet { relabel() } }
    /// The far-trailing CONTROL slot (e.g. "+"). Assigning re-runs the header's constraints.
    var accessory: UIView? { didSet { mount(accessory, replacing: oldValue) } }

    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private var accessoryConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for label in [titleLabel, captionLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 1
            addSubview(label)
        }
        titleLabel.textColor = Slate.Native.State.header
        // ⚠️ The tracking is spelled as an attributed `.kern`, which is why ``relabel`` exists at all:
        // a `UILabel` has no tracking property, and `.kern` is per-string, so the text and its letter
        // spacing have to be set in the same breath.
        titleLabel.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .semibold)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        captionLabel.textColor = Slate.Native.Text.tertiary
        captionLabel.font = Slate.Typeface.instrumentNative(Slate.Typeface.small, weight: .regular)
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // UIKit has an explicit trait for what this view IS, and it has to be said: nothing infers a
        // heading from a hand-built stack the way a declarative `Section` would have.
        titleLabel.accessibilityTraits = .header

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.space2),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Slate.Metric.space1),
            captionLabel.leadingAnchor.constraint(
                equalTo: titleLabel.trailingAnchor, constant: Slate.Metric.space2,
            ),
            // Centre, not baseline — the two labels share a size, so the two coincide anyway.
            captionLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        restageAccessory()
        relabel()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func mount(_ view: UIView?, replacing old: UIView?) {
        guard view !== old else { return }
        old?.removeFromSuperview()
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        restageAccessory()
    }

    /// The slack between the caption and the accessory: an inequality against whichever edge is on
    /// the right, so neither label can ever run under the control.
    private func restageAccessory() {
        NSLayoutConstraint.deactivate(accessoryConstraints)
        accessoryConstraints = []
        if let accessory {
            accessoryConstraints = [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
                accessory.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor),
            ]
        } else {
            accessoryConstraints = [
                captionLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -Slate.Metric.space2,
                ),
            ]
        }
        NSLayoutConstraint.activate(accessoryConstraints)
    }

    private func relabel() {
        titleLabel.attributedText = NSAttributedString(
            string: title.uppercased(),
            attributes: [.kern: Slate.Typeface.instrumentTracking],
        )
        captionLabel.text = caption
        captionLabel.isHidden = caption == nil
    }
}
#endif
