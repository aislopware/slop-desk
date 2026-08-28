// PhonePanelSheet — the RIGHT panel's four surfaces on a phone, where there is no right.
//
// The Mac hangs them in a third split column beside navigator | content, with a strip over them and a
// rail where the collapsed column used to be. A phone has room for exactly one of those things at a
// time, so the same four surfaces arrive as a FULL-SCREEN COVER over the workspace: the workbench, a
// simulator or a device is a place you go to, not a column you glance at. That is the whole difference
// — the layout — and it is the difference the split exists to allow (docs/56 §3.5).
//
// WHAT IS NOT DIFFERENT: the surfaces themselves are ``CodePanelSurfaces``, the same view the Mac's
// column hosts; the four tabs are ``PanelTabs/all``, the same list the strip and the rail read; the
// width ladder is ``PanelTabs/labelling(available:cell:gap:named:selected:)``, the same arithmetic,
// asked with this renderer's own measurement; and the selected surface is `chrome.panelSurface`, the
// same shared flag, so a phone and a Mac driving one session agree about which surface is showing.
//
// The THREE MODELS are not held here, for the reason they are not held on the Mac either: a panel that
// is dismissed and re-opened would otherwise re-list every device and re-boot every stream, and the
// parking rules (`SimulatorSidebarModel.park()`) already assume something outlives the surface tree.
// They live on the phone's root view, which lives as long as the app does.

#if os(iOS)
import SFSafeSymbols
import SlopDeskClientCore
import SlopDeskDevicePanels
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SwiftUI
import UIKit

/// The three surface models, owned by whoever outlives the panel's presentation. A class rather than
/// three stored properties so the root view holds ONE `@State` and hands one value down.
@MainActor
package final class PhonePanelModels {
    package let code = CodeSidebarModel()
    package let simulator = SimulatorSidebarModel()
    /// A FOURTH tab rather than a second half of Simulators — the two share not one byte of protocol.
    /// The reasoning is the Mac column's, and it is recorded there.
    package let android = AndroidSidebarModel()

    package init() {}
}

/// The panel as a phone presents it: its own bar, then the surfaces, edge to edge.
package struct PhonePanelSheet: View {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState
    let models: PhonePanelModels
    /// The single overlay coordinator. Handed in rather than read from the environment because a cover
    /// does not inherit the presenter's, and the surfaces under this bar need it twice over: to file a
    /// report, and to have that report drawn (see the stack below).
    let overlay: OverlayCoordinator
    /// The single live preferences store — the terminal font prefs the workbench pushes host-side, so
    /// the editor reads like the terminal beside it. Handed in for the reason `overlay` is (docs/62
    /// stage B): the `\.preferencesStore` key it used to arrive on is gone.
    let preferences: PreferencesStore?
    /// Dismisses the cover. Passed in rather than taken from `\.dismiss` so the presenter can also
    /// re-collapse the shared chrome flag in the same gesture.
    let onClose: () -> Void

    package init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        models: PhonePanelModels, overlay: OverlayCoordinator, preferences: PreferencesStore?,
        onClose: @escaping () -> Void,
    ) {
        self.store = store
        self.connection = connection
        self.chrome = chrome
        self.models = models
        self.overlay = overlay
        self.preferences = preferences
        self.onClose = onClose
    }

    package var body: some View {
        VStack(spacing: 0) {
            PhonePanelBar(
                chrome: chrome,
                codeReloadable: codeReloadable,
                onReload: reload,
                onClose: onClose,
            )
            CodePanelSurfaces(
                store: store, connection: connection, chrome: chrome,
                preferences: preferences, model: models.code,
                simulatorModel: models.simulator, androidModel: models.android,
                overlayCoordinator: overlay,
            )
        }
        .background(Slate.Surface.field)
        // The cover owns the whole screen INCLUDING the home indicator's band: a device stage fitted
        // to a safe area draws a cream stripe under the mirror. The bar keeps its own top inset.
        .ignoresSafeArea(edges: .bottom)
        // THE NOTIFICATION CORNER COMES WITH IT. The surfaces under this bar SPEAK — a simulator boot
        // that failed, a capture that landed on the clipboard — through the same coordinator the
        // workspace's stack reads, and that stack is mounted on the root, which this cover is on top
        // of. Without a second stack here every report the panel makes while it is up would be filed
        // behind the thing that filed it. The palette deliberately does NOT follow: a phone shows one
        // place at a time, and the panel's own bar is its command surface.
        .overlay {
            ToastStackView(coordinator: overlay, onJump: store.jumpToPaneNamedByNotification)
                .allowsHitTesting(!overlay.toasts.isEmpty)
        }
    }

    /// The active pane's project root — the HOST-pushed `projectKey` only, never the cwd fallback.
    /// Ensuring on the transient pre-push cwd spawns a code-server for a root the project does not
    /// have; the Mac's column states the same rule at its own reload seam.
    private var activeProjectRoot: String? {
        guard let pane = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.hostPushedProjectKey(pane)
    }

    /// Whether the workbench is MOUNTED. Behind the open gate there is nothing to reload, and a bump of
    /// the poll generation would boot the very thing the gate exists to defer.
    private var codeReloadable: Bool {
        activeProjectRoot.map(chrome.openedCodeProjects.contains) ?? false
    }

    /// What the bar's one action plate does on the surface currently showing. The Mac wires the same
    /// four answers from its column, for the same reason: what "reload" means is the SURFACE's
    /// business, and the bar only carries the verb.
    private func reload() {
        switch chrome.panelSurface {
        case .code:
            guard let root = activeProjectRoot else { return }
            CodeSidebarWebViewPool.shared.reload(projectRoot: root)
            models.code.requestReload()
        case .simulators:
            models.simulator.requestReload()
        case .android:
            models.android.requestReload()
        case .desktop:
            break
        }
    }
}

/// The panel's own top bar: the four tabs leading, the surface's reload trailing, the close plate at
/// the far corner. It is the phone's answer to ``MacPanelStrip`` and it keeps that strip's split —
/// tabs inside the surface, dismissal at the trailing edge — with one thing dropped: there is no hide
/// toggle, because a cover that is not presented is already hidden.
private struct PhonePanelBar: View {
    let chrome: WorkspaceChromeState
    let codeReloadable: Bool
    let onReload: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: Self.actionGap) {
            PhonePanelTabRow(chrome: chrome)
            Spacer(minLength: Slate.Metric.space1)
            if reloadHelp != nil {
                SlatePlateButton(symbol: .arrowClockwise, help: reloadHelp, action: onReload)
            }
            SlatePlateButton(symbol: .chevronDown, help: "Close the panel", action: onClose)
        }
        .padding(.horizontal, Slate.Metric.space2)
        .frame(height: Slate.Metric.titlebarHeight)
        .background(Slate.Surface.field)
    }

    /// The action plates trail on their own narrower gap — they are not a group, they are two separate
    /// verbs. The number is the Mac strip's.
    private static let actionGap: CGFloat = 2

    /// Which verb the trailing plate carries, and whether it carries one at all. Desktop is announced
    /// but empty, so it has nothing to reload; the workbench has nothing to reload until it is open.
    private var reloadHelp: String? {
        switch chrome.panelSurface {
        case .code: codeReloadable ? "Reload the workbench" : nil
        case .simulators: "Reload the simulator list"
        case .android: "Reload the device list"
        case .desktop: nil
        }
    }
}

/// The four tabs, drawn for a finger. Same list, same ladder, same selected flag as the Mac's strip;
/// what differs is that a tap has no hover to precede it, so the SELECTED plate is the only lit one.
private struct PhonePanelTabRow: View {
    let chrome: WorkspaceChromeState

    var body: some View {
        // The ladder needs the width the row actually gets, which only layout knows — the same reason
        // the Mac asks it from `layout()` rather than from its own intrinsic size.
        GeometryReader { proxy in
            let rung = PanelTabs.labelling(
                available: proxy.size.width, cell: Slate.Metric.plate, gap: Slate.Metric.space1,
                named: Self.labelCost, selected: chrome.panelSurface,
            )
            HStack(spacing: Slate.Metric.space1) {
                ForEach(PanelTabs.all, id: \.surface) { tab in
                    PhonePanelTab(
                        tab: tab,
                        selected: chrome.panelSurface == tab.surface,
                        namesItself: PanelTabs.names(tab, at: rung, selected: chrome.panelSurface),
                    ) {
                        chrome.panelSurface = tab.surface
                    }
                }
            }
            .frame(height: proxy.size.height, alignment: .center)
        }
        .frame(height: Slate.Metric.plate)
    }

    /// What one tab's LABEL costs beyond its bare square cell — the ladder's `named` input, measured in
    /// this renderer's own type. `UIFont` rather than a SwiftUI measurement for the reason the ladder
    /// is arithmetic at all: asking SwiftUI would mean BUILDING all three candidate rows to compare
    /// them, and the answer is wanted before anything is built.
    static func labelCost(_ tab: PanelTabReading) -> CGFloat {
        let font = UIFont.systemFont(ofSize: Slate.Typeface.footnote, weight: .medium)
        // Ceiled, so a fractional measure cannot land back on the same edge the ladder just refused.
        let text = tab.label.size(withAttributes: [.font: font]).width.rounded(.up)
        return Slate.Metric.space2 + markWidth(tab.mark) + Slate.Metric.space1 + text
            + Slate.Metric.space2 - Slate.Metric.plate
    }

    /// The mark's own measure. The android head is the ONE mark in the app carrying a size of its own,
    /// because it is a drawn path with no optical grid behind it.
    static func markWidth(_ mark: PanelTabMark) -> CGFloat {
        switch mark {
        case .symbol: Slate.Metric.iconSize
        case .android: Slate.Metric.androidMark
        }
    }
}

/// One tab: a square cell that grows a word when the row can afford it.
private struct PhonePanelTab: View {
    let tab: PanelTabReading
    let selected: Bool
    let namesItself: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Slate.Metric.space1) {
                PhonePanelMark(mark: tab.mark, ink: ink)
                if namesItself {
                    Text(tab.label)
                        .font(.system(size: Slate.Typeface.footnote, weight: selected ? .medium : .regular))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, namesItself ? Slate.Metric.space2 : 0)
            .frame(minWidth: Slate.Metric.plate, minHeight: Slate.Metric.plate)
            .contentShape(.rect)
        }
        .buttonStyle(SlatePlateStyle { pressed in
            selected ? Slate.State.selected : pressed ? Slate.State.hover : .clear
        })
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityHint(tab.accessibilityHint)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var ink: Color { selected ? Slate.Text.primary : Slate.Text.icon }
}

/// A tab's mark: an SF Symbol, or the one head no icon set ships. The head's proportions are
/// ``AndroidMarkPath``'s — the same `CGPath` the Mac's plate strokes and fills, so the two draw one
/// robot rather than two.
private struct PhonePanelMark: View {
    let mark: PanelTabMark
    let ink: Color

    var body: some View {
        switch mark {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: Slate.Metric.iconSize, weight: .medium))
                .foregroundStyle(ink)
                .frame(width: Slate.Metric.iconSize, height: Slate.Metric.iconSize)
        case .android:
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                // The antennae go down FIRST and as their own path: the head is filled even-odd, and
                // an antenna crossing the dome's rim inside that one path would subtract a notch from
                // it exactly where the two meet.
                context.stroke(
                    Path(AndroidMarkPath.antennae(in: rect)),
                    with: .color(ink),
                    style: StrokeStyle(
                        lineWidth: AndroidMarkPath.antennaLineWidth(in: rect), lineCap: .round,
                    ),
                )
                context.fill(Path(AndroidMarkPath.head(in: rect)), with: .color(ink), style: FillStyle(eoFill: true))
            }
            .frame(width: Slate.Metric.androidMark, height: Slate.Metric.androidMark)
        }
    }
}
#endif
