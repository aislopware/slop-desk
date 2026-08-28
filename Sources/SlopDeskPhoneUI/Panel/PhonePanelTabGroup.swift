// PhonePanelTabGroup — the four panel tabs and the ONE selection plate that travels between them.
//
// The Mac writes this run twice over, on two axes: across the panel's own strip and down the RAIL the
// collapsed column leaves behind (``SlopDeskMacUI/MacPanelTabGroup``, whose `Axis` is the parameter).
// A phone has ONE axis. A panel that is not presented is already hidden, and the way back is the same
// toggle that put it away — there is no collapsed column and so no rail for a second run to live in.
// So the axis parameter, the fixed rail length, the quarter turn and the turned-tab footprint are all
// absent here, and their absence is the layout difference the split exists to allow (docs/56 §3.5)
// rather than a capability that was dropped.
//
// THE PLATE TRAVELS; IT DOES NOT FADE. Two redesigns of a per-tab fill were rejected — round 1's
// opacity fades read as cheap, round 2's width morph as stuttery — and this is neither: nothing fades
// and nothing changes width. The plate keeps the size the current rung gives it and only moves. On its
// FIRST appearance there is nothing to move from, so it IGNITES in place at
// ``Slate/Anim/plateIgniteScale`` of its own height, exactly as the sidebar's and the tab strip's do.
//
// ⚠️ LAID OUT BY HAND. The travelling plate reads its tabs' frames, and a `UIStackView` would make them
// this view's GRANDCHILDREN — whose frames during this view's `layoutSubviews()` are whatever the
// previous pass left, the trap the Mac's navigator plate hit and got a chip one word wide. Framing them
// here means the plate is always reading a rectangle this same pass wrote.

#if os(iOS)
import QuartzCore
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhonePanelTabGroup: UIView {
    /// The four plates, in ``PanelTabs/all`` order.
    let plates: [PhonePanelTabPlate]
    /// What a tab tap does. Set by the bar, which owns the chrome flag the four tabs select into.
    var onSelect: (PanelSurface) -> Void = { _ in }

    /// The run's gap. The tabs sit closer to EACH OTHER than to anything else: two lit plates side by
    /// side touched at the bar's own 2pt spacing read as one long fill, where `space1` opens a channel
    /// between them and still holds the group together.
    static let gap = Slate.Metric.space1

    private let plate = CALayer()
    private var selected: PanelSurface?

    override init(frame: CGRect) {
        plates = PanelTabs.all.map(PhonePanelTabPlate.init(tab:))
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        plate.cornerRadius = Slate.Metric.islandRadiusCompact
        plate.cornerCurve = .continuous
        plate.borderWidth = Slate.Metric.hairline
        plate.isHidden = true
        // BELOW the tabs, never over them: the plate is the ground a selected tab stands on, and a
        // sublayer added after the subviews' layers would paint its fill across the mark and the word.
        layer.insertSublayer(plate, at: 0)

        for tab in plates {
            // ⚠️ LEFT AT `translates = true`, unlike the plate's own two children. A tab HAS an intrinsic
            // size, and taking it out of the engine turns that size into constraints the engine then
            // enforces over the frames written below. This view writes the frame from its own
            // `layoutSubviews()`, which is where an autoresizing constraint is regenerated rather than
            // replayed.
            tab.onTap = { [weak self] in self?.onSelect(tab.tab.surface) }
            addSubview(tab)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (group: Self, _: UITraitCollection) in
            group.repaintPlate()
        }
        repaintPlate()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: Measure + lay out

    override var intrinsicContentSize: CGSize {
        let width = plates.reduce(CGFloat.zero) { $0 + $1.idealWidth }
            + Self.gap * CGFloat(plates.count - 1)
        return CGSize(width: width, height: Slate.Metric.plate)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var offset: CGFloat = 0
        for tab in plates {
            let width = tab.idealWidth
            tab.frame = CGRect(
                x: offset, y: (bounds.height - Slate.Metric.plate) / 2,
                width: width, height: Slate.Metric.plate,
            )
            offset += width + Self.gap
            // ⚠️ MARKED DIRTY BY HAND. A frame write only marks a view for layout when its SIZE changes,
            // and a tab that gave its word up keeps one width for as long as the rung holds — the run
            // then only ever moves. Without this, a tab whose first layout ran against a zero-bounds
            // group (the pass `select` forces before the view has ever been sized) keeps that pass's
            // subview frames forever, and the mark photographs at 0×0.
            tab.setNeedsLayout()
            tab.layoutIfNeeded()
        }
        layoutPlate(animated: false)
    }

    // MARK: The travel

    /// Point the plate at `surface` and repaint every tab's ink.
    func select(_ surface: PanelSurface, labelling: PanelTabLabelling) {
        let igniting = selected == nil
        let moved = selected != surface
        selected = surface
        for tab in plates {
            tab.apply(
                selected: tab.tab.surface == surface,
                showsLabel: PanelTabs.names(tab.tab, at: labelling, selected: surface),
            )
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        guard moved else { return }
        move(igniting: igniting)
    }

    private func move(igniting: Bool) {
        guard let target = plates.first(where: { $0.tab.surface == selected }) else {
            plate.isHidden = true
            return
        }
        layoutIfNeeded()
        let frame = target.frame
        plate.isHidden = false
        guard !igniting else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plate.frame = frame
            CATransaction.commit()
            let grow = CABasicAnimation(keyPath: "transform.scale.y")
            grow.fromValue = Slate.Anim.plateIgniteScale
            grow.toValue = 1
            grow.duration = Slate.Motion.selectionMorph.duration
            grow.timingFunction = Slate.Motion.selectionMorph.timingFunction
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Slate.Motion.selectionMorph.duration
            fade.timingFunction = Slate.Motion.selectionMorph.timingFunction
            plate.add(grow, forKey: "ignite")
            plate.add(fade, forKey: "igniteFade")
            return
        }
        let travel = CABasicAnimation(keyPath: "frame")
        travel.duration = Slate.Motion.selectionMorph.duration
        travel.timingFunction = Slate.Motion.selectionMorph.timingFunction
        plate.frame = frame
        plate.add(travel, forKey: "travel")
    }

    private func layoutPlate(animated: Bool) {
        guard let target = plates.first(where: { $0.tab.surface == selected }), !plate.isHidden
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        plate.frame = target.frame
        CATransaction.commit()
    }

    // MARK: Paint

    /// The selected plate is a COMPACT ISLAND — the same chip the sidebar's rows and the band's tabs
    /// wear (user-directed 2026-08-08): the panel's four surfaces are tabs, so they answer "which one"
    /// in the window's one material rather than in an accent wash of their own.
    ///
    /// ⚠️ Repainted from the trait registration, not once at init: a `CGColor` on a layer is a RESOLVED
    /// colour, fixed at the appearance current when it was assigned, so a plate painted once survives a
    /// light/dark switch as the old theme's chrome tone.
    private func repaintPlate() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = Slate.Native.Surface.island
            .resolvedColor(with: traitCollection).cgColor
        plate.borderColor = Slate.Native.Terminal.edge
            .resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }
}
#endif
