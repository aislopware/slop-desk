// MacPanelRail — what the RIGHT panel leaves behind when it collapses (user-directed 2026-08-09), in
// AppKit.
//
// The panel used to vanish outright, and the only way back was a plate that appeared on hover at the
// window's trailing edge. That plate had nowhere good to stand: with the island rising to the band's
// line, the window's top-right corner belongs to the glass, and a chrome plate parked there either
// straddled the island's 26pt corner (half on cream, half sunk in the glass — unreadable) or had to be
// pushed so far inboard that it no longer read as the panel's own control.
//
// So the panel does not vanish. It narrows to this rail — one plate wide — carrying:
//   • the panel TOGGLE at the top, on the band's control line, at exactly the x the panel's own hide
//     toggle stands at when the panel is open, so the control the user aims at never moves; and
//   • the four surface TABS below it, turned a quarter turn so they run DOWN the rail instead of
//     across the strip. Same tabs, same selection, same travelling plate — only the axis changed,
//     which is the move the horizontal tab strip already makes when the LEFT sidebar collapses.
//
// A rail tab EXPANDS the panel onto its surface. A railed panel shows no surface at all, so a tab that
// only moved the selection would be a control with nothing to show for itself; picking a surface is
// how you ask for it back.
//
// The rail is GROUND, like the panel it stands in for — it paints nothing of its own.
//
// It ARRIVES AND LEAVES; it does not appear (user-reported 2026-08-09 — mounted on the flag it stood,
// already turned on its side, on top of a terminal that had not yet made room for it). So it is
// mounted at all times and TRAVELS instead, which is the only way to time the two halves of the
// gesture independently — see ``travel(railed:animated:)``.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // Slate + Slate.Native — the ONE ladder, natively

@MainActor
final class MacPanelRail: NSView {
    private let chrome: WorkspaceChromeState

    private let toggle = MacPlateIconButton(symbolName: "sidebar.right")
    private let tabs = MacPanelTabGroup(axis: .vertical)

    init(chrome: WorkspaceChromeState) {
        self.chrome = chrome
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Backed, because the travel is a layer transform and the fade a layer opacity — see
        // ``travel(railed:animated:)``.
        wantsLayer = true

        toggle.toolTip = "Show the right panel"
        toggle.onClick = { [weak chrome] in chrome?.toggleCodeSidebar() }
        tabs.onSelect = { [weak chrome] surface in
            chrome?.panelSurface = surface
            chrome?.revealCodeSidebar()
        }
        addSubview(toggle)
        addSubview(tabs)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Slate.Metric.panelRailWidth),
            toggle.centerXAnchor.constraint(equalTo: centerXAnchor),
            // The toggle hangs from the band's control line like every other control in the band;
            // the tabs start a grid step under it.
            toggle.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.bandControlInset),
            tabs.centerXAnchor.constraint(equalTo: centerXAnchor),
            tabs.topAnchor.constraint(
                equalTo: toggle.bottomAnchor, constant: Slate.Metric.space1,
            ),
            // The rail is exactly as tall as what it carries: it stands at the column's TOP corner,
            // not down its whole edge, so a bottom pinned to the tabs is what gives it a height at
            // all. (Its parent gives it no bottom anchor for the same reason.)
            bottomAnchor.constraint(equalTo: tabs.bottomAnchor),
        ])
        follow()
        travel(railed: false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: The arrival

    /// Whether the panel is currently standing in as this rail.
    private(set) var railed = false

    /// Slide AND fade the rail in or out of the column's trailing edge.
    ///
    /// The two halves are timed differently on purpose:
    ///   • COLLAPSING — the rail waits out most of the panel's exit and only then slides in, so it
    ///     lands in ground the panel has already vacated. Same arrive-on-land contract the horizontal
    ///     tab strip keeps with the navigator, off the same rung, so the window only ever has ONE
    ///     column gesture running.
    ///   • EXPANDING — no delay and a quick out: the rail clears the corner before the panel's own
    ///     edge reaches it. A late exit is what makes a sliding panel look like it is shoving
    ///     furniture.
    ///
    /// Slide AND fade because the distance is one plate: an object crossing 40pt on the emphasized
    /// curve arrives before the eye has caught it, and the opacity is what makes the arrival read.
    ///
    /// ⚠️ The slide is a LAYER TRANSFORM, never the frame. This view is positioned by Auto Layout, and
    /// an animated frame is overwritten by the next layout pass — the translation composes on top of
    /// whatever that pass resolves.
    func travel(railed: Bool, animated: Bool) {
        guard railed != self.railed || !animated else { return }
        self.railed = railed
        let shift = railed ? 0 : Slate.Metric.panelRailWidth
        let opacity: Float = railed ? 1 : 0
        guard animated, let layer else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.transform = CATransform3DMakeTranslation(shift, 0, 0)
            layer?.opacity = opacity
            CATransaction.commit()
            return
        }
        let curve = railed ? Slate.Motion.columnSlide : Slate.Motion.fadeOut
        let delay = railed ? Slate.Motion.columnSlide.duration * 0.55 : 0
        let from = layer.presentation() ?? layer
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = from.transform
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from.opacity
        for animation in [slide, fade] {
            animation.duration = curve.duration
            animation.timingFunction = curve.timingFunction
            animation.beginTime = CACurrentMediaTime() + delay
            // BACKWARDS, so the delay is a HOLD at the old value rather than a jump to the new one:
            // without it the rail would land the instant the flag flipped and then animate from where
            // it already was, which is the "it appeared" bug this whole method exists to fix.
            animation.fillMode = .backwards
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(shift, 0, 0)
        layer.opacity = opacity
        CATransaction.commit()
        layer.add(slide, forKey: "travel")
        layer.add(fade, forKey: "travelFade")
    }

    /// A rail at zero opacity is still a rail: it stands over the island's trailing moat while the
    /// panel is open, and would eat clicks meant for the glass.
    override func hitTest(_ point: NSPoint) -> NSView? {
        railed ? super.hitTest(point) : nil
    }

    private func follow() {
        var surface: PanelSurface = .code
        withObservationTracking {
            surface = chrome.panelSurface
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.selectionMorph.duration
            context.timingFunction = Slate.Motion.selectionMorph.timingFunction
            context.allowsImplicitAnimation = true
            tabs.select(surface, labelling: .all)
        }
    }
}
