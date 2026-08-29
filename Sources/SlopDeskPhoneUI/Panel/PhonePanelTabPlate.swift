// PhonePanelTabPlate — one of the RIGHT panel's four tabs: a mark AND its name on a plate. In UIKit.
//
// BOTH, on every tab, is the point. The strip spent two rounds with marks alone on the unselected tabs
// and read ragged both times (user-reported 2026-08-04): a folder outline, a narrow solid logo, a wide
// solid dome and a wide screen have no optical mass in common, and equalising their ink to a 2.5pt band
// did not help, because ink height was never what the eye was comparing. A word beside each mark
// settles it without touching the marks at all — the labels are the same height by construction, and
// they push the marks far enough apart that no two of them are read against each other. Marks alone
// were then tried and the strip lost too much (user-directed 2026-08-05).
//
// So the mark identifies and the word names, and a tab that has room shows both. When the bar is narrow
// it gives the words up a rung at a time rather than truncating — the ladder is
// ``PanelTabs/labelling(available:cell:gap:named:selected:)``, one target down, and `showsLabel` is how
// a rung of it is asked for.
//
// ⚠️ ONE AXIS, WHERE THE MAC HAS TWO, and the missing one is not a feature that was dropped. The Mac's
// ``SlopDeskMacUI/MacPanelTabPlate`` carries a quarter turn because a collapsed panel leaves a RAIL down
// the window's trailing edge and the four tabs have to run down it. A phone has no rail: a panel that is
// not presented is already hidden, and the way back is the same toggle that put it away. So there is no
// `plateRotation`, no counter-turning mark, and no `MacPanelTabContent` — the box the Mac needs solely to
// carry a size through a turn. The tab is its own content.
//
// The SELECTED plate is NOT drawn here. It is one travelling `CALayer` owned by ``PhonePanelTabGroup``,
// for the same reason the sidebar's and the tab strip's are: the selection MOVES between tabs, and a
// fill each tab paints for itself can only appear and disappear. Two animation redesigns of that
// appearing and disappearing were rejected — round 1's opacity fades read as cheap, round 2's width
// morph as stuttery — and travel is neither: nothing fades and nothing changes width. All this leaf
// paints is the PRESS tint, and on a phone that is the only pointer state there is.

#if os(iOS)
import QuartzCore
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhonePanelTabPlate: UIControl {
    let tab: PanelTabReading
    var onTap: () -> Void = {}

    private let mark: UIView & PhonePanelMark
    private let label = UILabel()
    private var showsLabel = true

    init(tab: PanelTabReading) {
        self.tab = tab
        mark =
            switch tab.mark {
            case let .symbol(name): PhoneSymbolMark(symbolName: name)
            case .android: PhoneAndroidMark()
            }
        super.init(frame: .zero)
        layer.cornerRadius = Slate.Metric.islandRadiusCompact
        layer.cornerCurve = .continuous
        backgroundColor = .clear

        label.text = tab.label
        label.numberOfLines = 1
        // ⚠️ OUT OF THE ENGINE, both children. This view frames them from ``layoutSubviews()``, and a
        // subview left at `translates = true` gets an autoresizing constraint per edge minted from
        // whatever frame it had when the engine first engaged — which is then solved straight back over
        // every frame written by hand. The Mac's twin records the same trap and the measurement behind
        // it (the Android mark carried `width == 0` for its whole life and photographed as nothing).
        mark.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        mark.isUserInteractionEnabled = false
        label.isUserInteractionEnabled = false
        addSubview(mark)
        addSubview(label)

        addTarget(self, action: #selector(fire), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityLabel = tab.accessibilityLabel
        accessibilityHint = tab.accessibilityHint

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (plate: Self, _: UITraitCollection) in
            plate.repaint(animated: false)
        }
        repaint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: The two states

    // SELECTION IS `UIControl.isSelected`, not a second stored flag beside it. A `private var
    // selected` does not compile here at all — it reads as an override of the inherited property,
    // and a private one cannot override an open one — but the reason to delete it rather than rename
    // around it is that the control already HAS this state: two flags means a plate whose
    // `accessibilityTraits` and whose UIKit state can disagree. The Mac twin stores its own because
    // `NSView` has nothing to inherit.
    func apply(selected: Bool, showsLabel: Bool) {
        guard isSelected != selected || showsLabel != self.showsLabel else { return }
        isSelected = selected
        self.showsLabel = showsLabel
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        repaint()
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            repaint()
        }
    }

    // MARK: Measure

    /// A named tab is `[collar][mark][gap][label][collar]`; a bare one is the SQUARE cell the action
    /// plates at the other end of the same bar occupy — NOT a plate hugging its mark, because the marks
    /// are 10 to 17 points across and hugging gives four different widths and a row of ragged gaps.
    var idealWidth: CGFloat {
        guard showsLabel else { return Slate.Metric.plate }
        return Slate.Metric.space2 + markSize.width + Slate.Metric.space1
            + textWidth + Slate.Metric.space2
    }

    /// What this tab's LABEL costs the bar beyond its bare cell — the ladder's `named` input. Asked of
    /// the view because only the renderer can measure its own type (docs/62 §7: the platform measures,
    /// Rust decides, the view places).
    ///
    /// ⚠️ MEASURED AGAINST THE SELECTED WEIGHT, always. The label goes MEDIUM when selected and REGULAR
    /// when not, and medium is the wider of the two — a ladder that costed the resting weight would
    /// admit a rung the tab cannot afford the moment the reader selects it, and the word would then be
    /// clipped by exactly the weight difference on whichever tab was tapped.
    var labelCost: CGFloat {
        Slate.Metric.space2 + markSize.width + Slate.Metric.space1
            + textWidth + Slate.Metric.space2 - Slate.Metric.plate
    }

    /// Ceiled, so a fractional measure cannot land back on the same edge the ladder just refused.
    private var textWidth: CGFloat {
        let font = UIFont.systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        return NSAttributedString(string: tab.label, attributes: [.font: font])
            .size().width.rounded(.up)
    }

    /// The mark's CELL, which each kind reports for itself.
    private var markSize: CGSize { mark.intrinsicContentSize }

    override var intrinsicContentSize: CGSize {
        CGSize(width: idealWidth, height: Slate.Metric.plate)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.isHidden = !showsLabel
        let size = markSize
        let markX = showsLabel ? Slate.Metric.space2 : (bounds.width - size.width) / 2
        mark.frame = CGRect(
            x: markX, y: (bounds.height - size.height).rounded() / 2,
            width: size.width, height: size.height,
        )
        guard showsLabel else { return }
        let text = label.intrinsicContentSize
        label.frame = CGRect(
            x: mark.frame.maxX + Slate.Metric.space1,
            y: (bounds.height - text.height).rounded() / 2,
            width: textWidth, height: text.height,
        )
    }

    // MARK: Paint

    /// The SELECTED fill belongs to the travelling plate — see this file's header. The PRESS is this
    /// leaf's, and only while nothing is selected here: a press tint under the plate is invisible and
    /// would only pay for a repaint.
    private func repaint(animated: Bool = true) {
        let fill: UIColor = isHighlighted && !isSelected ? Slate.Native.State.hover : .clear
        CATransaction.begin()
        if animated, window != nil {
            CATransaction.setAnimationDuration(Slate.Motion.smallFade.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.smallFade.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = fill.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()

        let ink = isSelected ? Slate.Native.Text.primary : Slate.Native.Text.icon
        // MEDIUM when selected, REGULAR when not — weight and ink carrying the state together, the same
        // pair every other latched control in this chrome uses.
        label.font = .systemFont(
            ofSize: Slate.Typeface.footnote, weight: isSelected ? .medium : .regular,
        )
        label.textColor = ink
        mark.paint(ink, traits: traitCollection)
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }

    @objc
    private func fire() { onTap() }
}

// MARK: - The two kinds of mark

/// A tab's mark, in the ink the tab is currently wearing.
@MainActor
protocol PhonePanelMark: UIView {
    func paint(_ ink: UIColor, traits: UITraitCollection)
}

/// A symbol on Apple's optical grid, at the BAR's icon measure (``Slate/Metric/iconSize``) — the one the
/// action plates at the other end of the same bar use, and NOT the label's type size. A glyph and a word
/// are not the same kind of thing, and sizing both from `footnote` had the tabs drawing at 11 while the
/// reload key beside them drew at 13.
@MainActor
private final class PhoneSymbolMark: UIImageView, PhonePanelMark {
    private let symbolName: String

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        contentMode = .center
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// The glyph's own box. A `UIImageView` reports its image's size, which for a symbol is whatever the
    /// configuration rendered — square at the icon measure once painted, and the measure itself before
    /// the first paint, so the ladder never measures a zero-width mark.
    override var intrinsicContentSize: CGSize {
        image?.size ?? CGSize(width: Slate.Metric.iconSize, height: Slate.Metric.iconSize)
    }

    /// ⚠️ THE INK IS BAKED IN, not a `tintColor`. The `.alwaysOriginal` mode is what every other Slate
    /// glyph in this target uses, so a plate handed a resolved colour draws exactly that colour rather
    /// than inheriting whatever tint an enclosing controller happens to carry.
    func paint(_ ink: UIColor, traits: UITraitCollection) {
        image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Slate.Metric.iconSize, weight: .medium,
            ),
        )?.withTintColor(ink.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
        invalidateIntrinsicContentSize()
    }
}

/// The Android head, drawn — see ``AndroidMarkPath``, which owns every proportion. This view owns
/// nothing but the fill.
///
/// ⚠️ NO FLIP, where the Mac's twin needs one. Every angle in ``AndroidMarkPath`` is stated in the
/// y-DOWN space `CGPath` uses, which is UIKit's own; AppKit draws y-up and has to flip. Same path, same
/// robot, one fewer transform.
@MainActor
private final class PhoneAndroidMark: UIView, PhonePanelMark {
    private var ink: UIColor = Slate.Native.Text.icon

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Square — the ONE mark in the app carrying a measure of its own, because it is a drawn path with
    /// no optical grid behind it.
    override var intrinsicContentSize: CGSize {
        CGSize(width: Slate.Metric.androidMark, height: Slate.Metric.androidMark)
    }

    func paint(_ ink: UIColor, traits: UITraitCollection) {
        self.ink = ink.resolvedColor(with: traits)
        setNeedsDisplay()
    }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // The GEOMETRY is asked here — `AndroidMarkPath`'s angles are stated in the y-down space this
        // view already draws in, which is the whole of what the Mac's twin needs a flip for — and the
        // LADDER that paints it is the floor's (`SlateVectorDraw.androidMark`), which both shells had
        // transcribed call for call.
        SlateVectorDraw.androidMark(
            head: AndroidMarkPath.head(in: bounds),
            antennae: AndroidMarkPath.antennae(in: bounds),
            lineWidth: AndroidMarkPath.antennaLineWidth(in: bounds),
            ink: ink.cgColor,
            into: context,
        )
    }
}
#endif
