// PhonePanelBar — the panel's own top bar: the four tabs leading, the showing surface's reload
// trailing, the close plate at the far corner.
//
// It is the phone's answer to ``SlopDeskMacUI/MacPanelStrip`` and it keeps that strip's split — tabs
// inside the surface, dismissal at the trailing edge — with ONE thing dropped and one thing changed.
//
// DROPPED: the hide toggle. The Mac's strip hides the column and the reopen lives in the RAIL the
// collapsed column leaves behind, which is the same split the left sidebar has — hide inside the
// surface, reopen outside it. A phone has no rail, because a panel that is not presented is already
// hidden; the plate at this corner is therefore a CLOSE rather than a hide, and the reopen is the same
// toggle that opened it.
//
// CHANGED: what the close plate writes. It calls ``onClose``, which the panel routes to
// `chrome.collapseCodeSidebar()` — the same persisted flag the Mac's split item reads, so a phone and a
// Mac driving one session agree about whether the panel is up.
//
// THE WIDTH LADDER runs here because only this view knows its width. The rung itself is arithmetic one
// target down (``PanelTabs/labelling(available:cell:gap:named:selected:)``); what this view supplies is
// the measurement — how wide each label actually draws — and the width left after the trailing plates
// are paid for.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (UIColor/UIFont) spelling
import UIKit

@MainActor
final class PhonePanelBar: UIView {
    private let chrome: WorkspaceChromeState

    private let tabs = PhonePanelTabGroup(frame: .zero)
    /// The surface's OWN verb — reload, on every surface that has something to reload. It is the one
    /// action plate the bar carries: leaving a device is navigation WITHIN a surface and lives beside
    /// that device's name, so this bar stays surface-level verbs only.
    private let reload: SlatePlateIconButton
    private let close: SlatePlateIconButton

    /// Whether the workbench is mounted at all. Behind the open gate there is nothing to reload, and a
    /// bump of the poll generation would boot the very thing the gate exists to defer.
    var codeReloadable = false { didSet { applyActions() } }

    private var labelling: PanelTabLabelling = .all
    /// Supersedes a callback armed before ``teardown()``. The chrome state is app-lifetime, so without
    /// it a dismissed panel's bar keeps re-arming on it forever (docs/62 hazard 2).
    private var generation = 0

    /// Both verbs arrive at INIT, because ``SlatePlateIconButton`` takes its action at init — a plate
    /// whose verb could be re-pointed later would need the acknowledgement moved off the press, which
    /// is the three-object dance that control exists to have removed. What "reload" means is still the
    /// SURFACE's business and not the bar's; the panel resolves it and hands the answer down.
    init(
        chrome: WorkspaceChromeState,
        onReload: @escaping () -> Void,
        onClose: @escaping () -> Void,
    ) {
        self.chrome = chrome
        reload = SlatePlateIconButton(symbol: .arrowClockwise, action: onReload)
        close = SlatePlateIconButton(symbol: .chevronDown, action: onClose)
        super.init(frame: .zero)
        build()
        follow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Stop following. Called by the panel before it lets go.
    func teardown() {
        generation &+= 1
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Slate.Native.Surface.field

        tabs.onSelect = { [weak self] surface in self?.select(surface) }
        addSubview(tabs)

        // ⚠️ NOT `addTarget` on either plate: ``SlatePlateIconButton`` takes its verb at init and
        // answers the press with the acknowledgement every chrome key gives. The panel hands both verbs
        // in already `[weak self]`-captured, which is the whole of hazard 1's discipline here.
        addSubview(reload)
        addSubview(close)
        reload.accessibilityLabel = "Reload"
        close.accessibilityLabel = "Close the panel"

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Slate.Metric.titlebarHeight),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Slate.Metric.space2),
            tabs.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabs.heightAnchor.constraint(equalToConstant: Slate.Metric.plate),
            // The tabs may not run under the trailing plates: the ladder decides how many words fit,
            // but a rung it admits still has to be given the room it was measured against.
            tabs.trailingAnchor.constraint(
                lessThanOrEqualTo: reload.leadingAnchor, constant: -Slate.Metric.space1,
            ),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Slate.Metric.space2),
            close.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            reload.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -Self.actionGap),
            reload.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
        ])
    }

    /// The action plates trail on their own narrower gap — they are not a group, they are two separate
    /// verbs. The number is the Mac strip's.
    private static let actionGap: CGFloat = 2

    // MARK: The live read

    private func follow() {
        generation &+= 1
        let generation = generation
        var surface: PanelSurface = .code
        withObservationTracking {
            surface = chrome.panelSurface
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    self.follow()
                }
            }
        }
        tabs.select(surface, labelling: labelling)
        applyActions()
    }

    /// A tab tap animates through ONE beat: the plate's TRAVEL, the reload plate's arrival and the
    /// surface swap together. It spends `selectionMorph` rather than `standard` because the plate
    /// crosses the bar instead of changing in place — the same swap the sidebar rows and the horizontal
    /// tab strip made.
    private func select(_ surface: PanelSurface) {
        chrome.panelSurface = surface
        UIView.animate(
            withDuration: Slate.Motion.selectionMorph.duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut],
            animations: { [weak self] in
                guard let self else { return }
                tabs.select(surface, labelling: labelling)
                applyActions()
                layoutIfNeeded()
            },
        )
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
        // ⚠️ FROM THE FLOOR, not typed here. The Mac's strip carries the same four answers as its
        // trailing plate's tooltip, and a sentence spelled once per shell is a translation bug that
        // has already happened — the day one half is reworded the two platforms ship different copy
        // for the same control (docs/56 §3, `shared-vocabulary-ceiling`).
        reload.accessibilityLabel = PanelChromeCopy.reloadHelp(for: chrome.panelSurface)
        // Re-rung on the way through, because a plate arriving or leaving changes the width the ladder
        // is measured against — see ``applyLadder()``.
        setNeedsLayout()
    }

    // MARK: The width ladder

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLadder()
    }

    /// Ask the ladder what this width can afford and re-rung the tabs if the answer changed.
    ///
    /// ⚠️ Measured against the width LEFT after the trailing plates, not the bar's own. The plates are
    /// the fixed cost at the far end; a ladder that spent the whole bar would keep every label and push
    /// the close plate off the trailing edge — where it is the one control that puts the panel away.
    private func applyLadder() {
        let trailing = (reload.isHidden ? 0 : Slate.Metric.plate + Self.actionGap)
            + Slate.Metric.plate + Slate.Metric.space2 * 2
        let available = bounds.width - trailing
        let next = PanelTabs.labelling(
            available: available, cell: Slate.Metric.plate, gap: PhonePanelTabGroup.gap,
            named: { [tabs] tab in
                tabs.plates.first { $0.tab.surface == tab.surface }?.labelCost ?? 0
            },
            selected: chrome.panelSurface,
        )
        guard next != labelling else { return }
        labelling = next
        tabs.select(chrome.panelSurface, labelling: next)
    }
}
#endif
