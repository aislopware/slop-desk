// MacPanelTabGroup — the four panel tabs and the ONE selection plate that travels between them.
//
// The strip and the rail are the same four tabs on two axes, so the run and the travel are written
// once here and mounted twice. The AXIS is the parameter: across, the tabs hug their labels and the
// width ladder decides how many get to say their name; down, each is framed to a FIXED length so the
// four agree (a column of tabs each as long as its own word reads as a ragged list) and turned a
// quarter turn.
//
// THE PLATE TRAVELS; IT DOES NOT FADE. Two redesigns of a per-tab fill were rejected — round 1's
// opacity fades read as cheap, round 2's width morph as stuttery — and this is neither: nothing fades
// and nothing changes width. The plate keeps the size the current rung gives it and only moves. On its
// FIRST appearance there is nothing to move from, so it IGNITES in place at
// ``Slate/Anim/plateIgniteScale`` of its own height, exactly as the sidebar's and the tab strip's do.
//
// The strip and the rail keep SEPARATE groups rather than sharing one, and that is deliberate: only
// one of them is ever mounted (the rail exists precisely when the strip does not), and a plate cannot
// travel to a tab that is not on screen. It is the same contract the horizontal tab strip keeps with
// the sidebar's list.
//
// ⚠️ LAID OUT BY HAND. The travelling plate reads its tabs' frames, and a stack view would make them
// this view's GRANDCHILDREN — whose frames during this view's `layout()` are whatever the previous
// pass left, the trap the navigator's plate hit and got a chip one word wide. Framing them here means
// the plate is always reading a rectangle this same pass wrote.
//
// The quarter turn is NOT a frame rotation — see ``MacPanelTabPlate``. Every tab here is framed to the
// footprint it occupies on its axis, and the turning happens one view further down.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling

@MainActor
final class MacPanelTabGroup: NSView {
    /// Which way the run reads. `.horizontal` is the panel's strip, `.vertical` the collapsed rail.
    enum Axis {
        case horizontal
        /// Turned a quarter turn CLOCKWISE, so the names read top-to-bottom down the window's trailing
        /// edge. Each tab is framed to ``Slate/Metric/panelRailTabLength``.
        case vertical
    }

    /// The four plates, in ``PanelTabs/all`` order.
    let plates: [MacPanelTabPlate]
    /// What a tab click does. The strip only moves the selection; the RAIL also expands the panel onto
    /// the surface, because a railed panel shows nothing and a tab that merely moved a hidden selection
    /// would be a control with nothing to show for itself.
    var onSelect: (PanelSurface) -> Void = { _ in }

    /// The run's gap. The tabs sit closer to EACH OTHER than to anything else: two lit plates side by
    /// side touched at the strip's own 2pt spacing read as one long fill, where `space1` opens a
    /// channel between them and still holds the group together.
    static let gap = Slate.Metric.space1

    private let axis: Axis
    private let plate = CALayer()
    private var selected: PanelSurface?

    init(axis: Axis) {
        self.axis = axis
        plates = PanelTabs.all.map {
            MacPanelTabPlate(tab: $0, plateRotation: axis == .vertical ? Self.quarterTurn : 0)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        plate.cornerRadius = Slate.Metric.islandRadiusCompact
        plate.cornerCurve = .continuous
        plate.borderWidth = Slate.Metric.hairline
        plate.isHidden = true
        layer?.addSublayer(plate)

        for tab in plates {
            // ⚠️ LEFT AT `translates = true`, unlike the plate's own two children. A tab HAS an
            // intrinsic size, and taking it out of the engine turns that size into constraints the
            // engine then enforces — which on the rail is exactly wrong: every tab there is framed to
            // one fixed length so the four agree, and the engine promptly shrank each back to the
            // width of its own word. This view writes the frame from its own `layout()`, which is
            // where an autoresizing constraint is regenerated rather than replayed.
            tab.onClick = { [weak self] in self?.onSelect(tab.tab.surface) }
            addSubview(tab)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// TOP-DOWN, so the rail's four tabs run in ``PanelTabs/all`` order the way they are read — Files,
    /// Simulators, Emulators, Desktop — instead of AppKit's default bottom-up, which stood the list on
    /// its head. Harmless on the horizontal axis, where every y here is a centring.
    override var isFlipped: Bool { true }

    /// Clockwise, in degrees. AppKit's rotation is counter-clockwise-positive, so a clockwise quarter
    /// turn is negative; the mark takes exactly this back out.
    private static let quarterTurn: CGFloat = -90

    // MARK: Measure + lay out

    override var intrinsicContentSize: NSSize {
        switch axis {
        case .horizontal:
            let width = plates.reduce(CGFloat.zero) { $0 + $1.idealWidth }
                + Self.gap * CGFloat(plates.count - 1)
            return NSSize(width: width, height: Slate.Metric.plate)
        case .vertical:
            let height = Slate.Metric.panelRailTabLength * CGFloat(plates.count)
                + Self.gap * CGFloat(plates.count - 1)
            return NSSize(width: Slate.Metric.heightControl, height: height)
        }
    }

    /// Both axes frame each tab to the footprint it OCCUPIES; on the rail that is a plate-wide column
    /// one ``Slate/Metric/panelRailTabLength`` tall, and the tab turns its own content inside it.
    override func layout() {
        super.layout()
        var offset: CGFloat = 0
        for tab in plates {
            switch axis {
            case .horizontal:
                let width = tab.idealWidth
                tab.frame = CGRect(
                    x: offset, y: (bounds.height - Slate.Metric.plate) / 2,
                    width: width, height: Slate.Metric.plate,
                )
                offset += width + Self.gap
            case .vertical:
                let length = Slate.Metric.panelRailTabLength
                // The tab is framed to the footprint it OCCUPIES — a plate-wide column, one fixed
                // length tall. What turns is its content, one view down (``MacPanelTabPlate``), so
                // the rectangle here is the one the pointer and the travelling plate both read.
                tab.frame = CGRect(
                    x: (bounds.width - Slate.Metric.plate) / 2, y: offset,
                    width: Slate.Metric.plate, height: length,
                )
                offset += length + Self.gap
            }
            // ⚠️ MARKED DIRTY BY HAND. A frame write only marks a view for layout when its SIZE
            // changes, and on this axis every tab keeps one size for its whole life — the run only
            // ever moves. Without this, a tab whose first layout ran against a zero-bounds group (the
            // pass `select` forces before the view has ever been sized) keeps that pass's subview
            // frames forever: measured on the rail, the Android tab photographed with a 0×0 mark.
            tab.needsLayout = true
            tab.layoutSubtreeIfNeeded()
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
        needsLayout = true
        guard moved else { return }
        move(igniting: igniting)
    }

    private func move(igniting: Bool) {
        guard let target = plates.first(where: { $0.tab.surface == selected }) else {
            plate.isHidden = true
            return
        }
        layoutSubtreeIfNeeded()
        let frame = plateFrame(for: target)
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
        plate.frame = plateFrame(for: target)
        CATransaction.commit()
    }

    /// Where the plate stands: the tab's FOOTPRINT in this view, which is its frame on both axes —
    /// nothing here is turned, only the content inside each tab is.
    private func plateFrame(for tab: MacPanelTabPlate) -> CGRect { tab.frame }

    // MARK: Paint

    override var wantsUpdateLayer: Bool { true }

    /// The selected plate is a COMPACT ISLAND — the same chip the sidebar's rows and the band's tabs
    /// wear (user-directed 2026-08-08): the panel's four surfaces are tabs, so they answer "which one"
    /// in the window's one material rather than in an accent wash of their own.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            plate.backgroundColor = Slate.Native.Surface.island.cgColor
            plate.borderColor = Slate.Native.Terminal.edge.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
