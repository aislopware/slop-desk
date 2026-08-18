// MacPanelStrip — the RIGHT panel's own top strip, in AppKit (the otty right-panel pattern): the four
// surface tabs leading, the surface's own action trailing, and the panel's HIDE toggle at the far
// trailing corner.
//
// The tabs belong to the PANEL, over the panel, never over the terminal (user-directed), and the row
// is hung from the band's control line — the tabs share one row of centres with the traffic lights
// three columns over (user-directed 2026-08-09).
//
// The HIDE toggle sits at the far trailing corner and the reopen lives in the rail the collapsed panel
// leaves behind — the same split the left sidebar has: hide inside the surface, reopen outside it. The
// two stand at the SAME x, so the control the pointer aims at never moves.
//
// THE WIDTH LADDER runs here because only this view knows its width. The rung itself is arithmetic one
// floor down (``PanelTabs/labelling(available:cell:gap:named:selected:)``); what this view supplies is
// the measurement — how wide each label actually draws — and the width left after the trailing plates
// are paid for.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // Slate + Slate.Native — the ONE ladder, natively

@MainActor
final class MacPanelStrip: NSView {
    private let chrome: WorkspaceChromeState

    private let tabs = MacPanelTabGroup(axis: .horizontal)
    /// The surface's OWN verb — reload, on every surface that has something to reload. It is the one
    /// action plate the strip carries: leaving a device is navigation WITHIN a surface and lives beside
    /// that device's name, so this strip stays surface-level verbs only.
    private let reload = MacPlateIconButton(symbolName: "arrow.clockwise")
    private let hide = MacPlateIconButton(symbolName: "sidebar.right")

    /// What the reload plate does on the surface currently showing — set by the column, because what
    /// "reload" means is the SURFACE's business and not the strip's.
    var onReload: (() -> Void)?
    /// Whether the workbench is mounted at all. Behind the open gate there is nothing to reload, and a
    /// bump of the poll generation would boot the very thing the gate exists to defer.
    var codeReloadable = false { didSet { applyActions() } }

    private var labelling: PanelTabLabelling = .all

    init(chrome: WorkspaceChromeState) {
        self.chrome = chrome
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        tabs.onSelect = { [weak self] surface in self?.select(surface) }
        addSubview(tabs)

        reload.onClick = { [weak self] in self?.onReload?() }
        hide.onClick = { [weak self] in self?.chrome.toggleCodeSidebar() }
        hide.toolTip = "Hide the right panel"
        addSubview(reload)
        addSubview(hide)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.titlebarHeight),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            // Hung from the band's CONTROL LINE, like every other control in the band.
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: Slate.Metric.bandControlInset),
            tabs.heightAnchor.constraint(equalToConstant: Slate.Metric.plate),
            hide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            hide.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            reload.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -Self.actionGap),
            reload.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
        ])
    }

    /// The action plates trail on the strip's own narrower gap — they are not a group, they are two
    /// separate verbs.
    private static let actionGap: CGFloat = 2

    // MARK: The live read

    private func follow() {
        var surface: PanelSurface = .code
        withObservationTracking {
            surface = chrome.panelSurface
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        tabs.select(surface, labelling: labelling)
        applyActions()
    }

    /// A tab click animates through ONE transaction: the plate's TRAVEL, the reload plate's arrival and
    /// the surface swap together. It spends `selectionMorph` rather than `standard` because the plate
    /// crosses the strip instead of changing in place — the same swap the sidebar rows and the
    /// horizontal tab strip made.
    private func select(_ surface: PanelSurface) {
        chrome.panelSurface = surface
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Slate.Motion.selectionMorph.duration
            context.timingFunction = Slate.Motion.selectionMorph.timingFunction
            context.allowsImplicitAnimation = true
            tabs.select(surface, labelling: labelling)
            applyActions()
            layoutSubtreeIfNeeded()
        }
    }

    /// Which verb the trailing plate carries, and whether it carries one at all. Desktop is announced
    /// but empty, so it has nothing to reload; the workbench has nothing to reload until it is open.
    private func applyActions() {
        let shown: Bool =
            switch chrome.panelSurface {
            case .code: codeReloadable
            case .simulators,
                 .android: true
            case .desktop: false
            }
        reload.isHidden = !shown
        reload.toolTip =
            switch chrome.panelSurface {
            case .code: "Reload the workbench"
            case .simulators: "Reload the simulator list"
            case .android: "Reload the device list"
            case .desktop: nil
            }
    }

    // MARK: The width ladder

    override func layout() {
        super.layout()
        applyLadder()
    }

    /// Ask the ladder what this width can afford and re-rung the tabs if the answer changed.
    ///
    /// ⚠️ Measured against the width LEFT after the trailing plates, not the strip's own. The plates
    /// are the fixed cost at the far end; a ladder that spent the whole strip would keep every label
    /// and push the hide toggle off the panel's trailing edge — where it is the one control the user
    /// needs to get the panel back.
    private func applyLadder() {
        let trailing = (reload.isHidden ? 0 : Slate.Metric.plate + Self.actionGap)
            + Slate.Metric.plate + Slate.Metric.space2 * 2
        let available = bounds.width - trailing
        let next = PanelTabs.labelling(
            available: available, cell: Slate.Metric.plate, gap: MacPanelTabGroup.gap,
            named: { tab in
                tabs.plates.first { $0.tab.surface == tab.surface }?.labelCost ?? 0
            },
            selected: chrome.panelSurface,
        )
        guard next != labelling else { return }
        labelling = next
        tabs.select(chrome.panelSurface, labelling: next)
    }
}
