// MacCodePanelColumn — the RIGHT column's root, in AppKit (docs/56 stage D).
//
// Two SIBLINGS, not a stack of one inside the other:
//   1. ``MacPanelStrip`` — the panel's own top strip: the four surface tabs, the showing surface's
//      reload plate, and the panel's hide toggle at the far trailing corner.
//   2. the four SURFACES, still SwiftUI (`SlopDeskClientUI/CodePanelSurfaces`), pinned under it.
//
// The surfaces are the next thing to cross rather than an exception to the split. Three of the four
// are already AppKit under a thin SwiftUI wrapper — a `WKWebView` for the workbench and an
// `AVSampleBufferDisplayLayer` for each device stage — so what a port would remove is the wrapper, not
// a framework choice; the phone will want the same four surfaces on its own layout, which is what
// makes them surfaces rather than chrome. docs/56 §3.5: a surface crosses whole.
//
// THE THREE MODELS ARE OWNED HERE, and that is the load-bearing change. They used to be `@State` on
// the SwiftUI column, which worked by accident: the strip's reload plate was inside the same tree.
// The strip is one framework over now, so the thing it reloads has to outlive — and stand outside —
// the view that draws it. It also states plainly what the parking rules already relied on: these
// models survive a surface unmount on purpose (see `SimulatorSidebarModel.park()`), because a device
// stream left running for a panel nobody can see costs a host encoder and two sockets.

import AppKit
import SlopDeskClientCore
import SlopDeskClientUI // CodePanelSurfaces, until the surfaces cross
import SlopDeskDevicePanels
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskWorkspaceCore
import SwiftUI

@MainActor
final class MacCodePanelColumn: NSViewController {
    private let store: WorkspaceStore
    private let chrome: WorkspaceChromeState
    /// Held for ``loadView()``'s shield, which goes hit-test deaf while a modal card is up — AppKit
    /// tracking areas are rect-based and keep firing under a floating card.
    private let overlay: OverlayCoordinator?

    private let model = CodeSidebarModel()
    private let simulatorModel = SimulatorSidebarModel()
    /// A FOURTH tab rather than a second half of Simulators: the two share not one byte of protocol —
    /// `baguette`'s websocket against `scrcpy` over `adb`, AVC against Annex-B, JSON envelopes against
    /// packed control messages — and folding them into one surface would mean a list whose rows
    /// dispatch on platform and a stage whose every control has two implementations. They are two
    /// device sets that happen to look alike in a sidebar.
    private let androidModel = AndroidSidebarModel()

    private let strip: MacPanelStrip
    private let surfaces: NSViewController

    init(
        store: WorkspaceStore, connection: AppConnection, chrome: WorkspaceChromeState,
        preferences: PreferencesStore?, overlay: OverlayCoordinator?,
    ) {
        self.store = store
        self.chrome = chrome
        self.overlay = overlay
        strip = MacPanelStrip(chrome: chrome)
        surfaces = WorkspaceColumnHosts.codePanelSurfaces(
            store: store, connection: connection, chrome: chrome, preferences: preferences,
            model: model, simulatorModel: simulatorModel, androidModel: androidModel,
            overlay: overlay,
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        let root = MacModalShield(overlay: overlay)
        root.wantsLayer = true
        root.onAppearanceChange = { [weak root] in
            root?.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        }

        addChild(surfaces)
        let canvas = surfaces.view
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(strip)
        root.addSubview(canvas)

        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: strip.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        root.layer?.backgroundColor = Slate.Native.Surface.field.cgColor
        wireStrip()
    }

    /// What the strip's one action plate does on the surface currently showing, and whether it has
    /// anything to do at all. Both answers are the SURFACE's business, which is why they are handed to
    /// the strip rather than resolved in it.
    private func wireStrip() {
        strip.onReload = { [weak self] in
            guard let self else { return }
            switch chrome.panelSurface {
            case .code:
                guard let root = activeProjectRoot else { return }
                CodeSidebarWebViewPool.shared.reload(projectRoot: root)
                model.requestReload()
            case .simulators:
                simulatorModel.requestReload()
            case .android:
                androidModel.requestReload()
            case .desktop:
                break
            }
        }
        followReloadable()
    }

    /// Whether the workbench is MOUNTED — behind the open gate there is nothing to reload, and a bump
    /// of the poll generation would boot the very thing the gate exists to defer.
    private func followReloadable() {
        var reloadable = false
        withObservationTracking {
            reloadable = activeProjectRoot.map(chrome.openedCodeProjects.contains) ?? false
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.followReloadable() }
            }
        }
        strip.codeReloadable = reloadable
    }

    /// The active pane's project root — the HOST-pushed `projectKey` (wire type 34) ONLY, never the cwd
    /// fallback the sidebar sections tolerate. Ensuring on the transient pre-push cwd spawns a
    /// code-server for a root the project does not have.
    private var activeProjectRoot: String? {
        guard let pane = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.hostPushedProjectKey(pane)
    }
}
