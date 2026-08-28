// WorkspaceRootViewController — the phone/iPad shell, and the keystone the rest of the UIKit
// rebuild hangs off (docs/62 stage D).
//
// This replaces the deleted `WorkspaceRootView`, a `NavigationSplitView` with five `.overlay`s, a
// `.sheet`, a `.fullScreenCover` and three `.onChange` observers. Everything it expressed as a
// modifier stack is expressed here as containment: two child controllers under a
// `UISplitViewController`, one passthrough layer over them, and two presentations.
//
// ## The iPad IS the desktop layout, and that is a `UISplitViewController` fact
//
// `.doubleColumn` gives a regular-width iPad the SAME two-column reading the Mac's
// `SlopDeskSplitViewController` gives a window — navigator beside content, a draggable divider, the
// panel arriving as a third surface — and gives a compact iPhone the pushed navigation stack that is
// the only honest layout at that width. ONE controller, two behaviours the system already knows how
// to switch between; the SwiftUI half needed `horizontalSizeClass` reads to fake the same thing.
//
// ## The collapse flag is shared, and the loop it closes is the one real trap here
//
// `chrome.sidebarCollapsed` is written by FOUR things — ⌘⇧L, the toolbar button, the palette row, and
// the auto-hide policy — and read by the split's display mode. The split ALSO writes back when the
// user drags the divider or swipes the column away. That is a cycle, and the deleted SwiftUI half
// closed it with a `Binding` whose setter could not tell a user gesture from a value it had just
// published itself. Two things break it here, and neither is a flag on this class:
//
//   1. The system's own edges are routed through ``WorkspaceChromePolicy/applySidebarCollapsed(_:chrome:)``,
//      whose `!=` guard drops an echo before it can be recorded as a manual override. It was written
//      for the SwiftUI binding's echo and is exactly as correct for a delegate callback.
//   2. ``applyChrome()`` compares before it actuates, so a re-arm that changed nothing does not
//      animate a column.
//
// ## What is NOT here
//
// The composition, the notification sinks and the clipboard loops are ``PhoneAppDelegate``'s — they
// belong to the PROCESS. The scene lifecycle is ``PhoneSceneDelegate``'s. This class owns the WINDOW's
// content and nothing with a lifetime longer than it.

#if os(iOS)
import Observation
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskVideoProtocol // ConfigRevision — the config-file edge the tracked read arms on
import SlopDeskWorkspaceCore
import UIKit

/// The window's content: a two-column split, an overlay layer, and the chrome wiring both need.
@MainActor
public final class WorkspaceRootViewController: UIViewController {
    private let store: WorkspaceStore
    private let connection: AppConnection
    private let overlay: OverlayCoordinator
    private let chrome: WorkspaceChromeState
    private let preferences: PreferencesStore

    private let split = UISplitViewController(style: .doubleColumn)
    private let navigator: NavigatorColumnViewController
    private let content: ContentColumnViewController

    /// The always-mounted passthrough layer carrying the palette, the toast corner and the clipboard
    /// questions. ALWAYS MOUNTED for the reason the SwiftUI `.overlay` was: an arriving card animates
    /// in without a re-mount, and the layer takes hits only where there is something to take them.
    private let overlayLayer: PhoneOverlayLayerView

    /// The panel presentation, while it is up. The Mac hangs its four surfaces in a third split
    /// column; a phone has room for exactly one such thing at a time, so they arrive as a full-screen
    /// presentation driven by the SAME `codeSidebarCollapsed` flag the Mac's split item reads — which
    /// is what makes `revealCodeSidebar()` work here for free.
    private var panel: PhonePanelViewController?

    /// The cheat sheet, while it is up. A real sheet rather than a card in ``overlayLayer``: it is the
    /// one overlay the phone presents natively (docs/56 stage D), and the two halves meet only at
    /// ``CheatSheetContent``.
    private var cheatSheet: UIViewController?

    /// The values ``applyChrome()`` last actuated. A re-arm of the observation tracker fires on any
    /// touched field, and most re-arms change none of these.
    private var appliedSidebarCollapsed: Bool?
    private var appliedPanelCollapsed: Bool?
    private var appliedCheatSheetVisible = false

    /// Suppresses the write-back while ``applyChrome()`` is actuating the split. The delegate
    /// callbacks below fire synchronously from `preferredDisplayMode`, and without this the policy
    /// would see the app's own actuation as a user swipe. The `!=` guard inside
    /// `applySidebarCollapsed` already drops the common case; this covers the ordering where the
    /// callback arrives BEFORE the flag it is echoing has settled.
    private var isActuating = false

    /// The inputs the auto-hide policy last ran against, so a re-arm that changed neither does not
    /// re-run it. `nil` until the first run — which must happen at launch, the way the deleted
    /// `.onChange(of:initial: true)` did, so a single-tab `.auto` session opens with the TABS panel
    /// already hidden.
    ///
    /// ⚠️ BOTH halves, not just the count. The deleted view carried a SECOND `.onChange`, on the mode
    /// itself; a setting flipped to `.auto` while the tab count sits still is exactly the case a
    /// count-only guard drops on the floor.
    private var lastAutoHide: (mode: AutoHideTabsPanelMode, tabCount: Int)?

    /// Whether this controller's view has reached a window, and so whether ``applyChrome()`` may
    /// present. ⚠️ A presentation attempted from `viewDidLoad` FAILS SILENTLY — there is no presenter
    /// in the hierarchy yet — and `codeSidebarCollapsed` is persisted, so the launch that restores an
    /// open panel is precisely the launch that would lose it. The applied values are left untouched
    /// while this is `false`, which is what makes ``viewDidAppear(_:)``'s single re-apply enough.
    private var canPresent = false

    public init(
        store: WorkspaceStore, connection: AppConnection, overlay: OverlayCoordinator,
        chrome: WorkspaceChromeState, preferences: PreferencesStore,
    ) {
        self.store = store
        self.connection = connection
        self.overlay = overlay
        self.chrome = chrome
        self.preferences = preferences
        navigator = NavigatorColumnViewController(store: store, chrome: chrome, overlay: overlay)
        content = ContentColumnViewController(
            store: store, connection: connection, chrome: chrome, overlay: overlay,
        )
        overlayLayer = PhoneOverlayLayerView(store: store, connection: connection, overlay: overlay)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: - Mounting

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field

        mountSplit()
        mountOverlayLayer()

        wireOverlayCwdResolver()
        wireOverlayKeyToggles()
        wireChromeActions()

        follow()
    }

    /// The first pass that may PRESENT. ``follow()`` ran at load — early enough for the auto-hide
    /// policy and the split's display mode, both of which work on a view that has not been shown —
    /// but left the two presentations for here.
    ///
    /// This deliberately re-applies rather than calling ``follow()`` again: `withObservationTracking`
    /// arms ONE registration per call and the re-arm happens inside `onChange`, so a second `follow()`
    /// would leave two live trackers and double every subsequent re-arm. The tracker armed at load is
    /// still the live one; this just actuates what it already read.
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !canPresent else { return }
        canPresent = true
        applyChrome(
            sidebarCollapsed: chrome.sidebarCollapsed, panelCollapsed: chrome.codeSidebarCollapsed,
            cheatSheetVisible: overlay.cheatSheetVisible,
        )
    }

    private func mountSplit() {
        split.setViewController(navigator, for: .primary)
        split.setViewController(content, for: .secondary)
        // TILE, not `.overlay`/`.displace`: the iPad reading is the Mac's, where the navigator takes
        // its own width out of the window rather than floating over the content. A terminal that got
        // re-laid-out under a floating column would reflow its grid on every reveal.
        split.preferredSplitBehavior = .tile
        split.preferredPrimaryColumnWidthFraction = 0.26
        split.minimumPrimaryColumnWidth = 220
        split.maximumPrimaryColumnWidth = 360
        split.delegate = self

        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: view.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        split.didMove(toParent: self)
    }

    /// The overlay layer sits ABOVE the split and below nothing — it is the last thing in this
    /// controller's hierarchy, so a card always covers the columns. It is a passthrough view: hit
    /// testing falls through wherever it is not drawing, which is what lets it stay mounted while the
    /// user works in a terminal underneath it.
    private func mountOverlayLayer() {
        overlayLayer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayLayer)
        NSLayoutConstraint.activate([
            overlayLayer.topAnchor.constraint(equalTo: view.topAnchor),
            overlayLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        overlayLayer.onJumpToPane = { [store] name in
            store.jumpToPaneNamedByNotification(name)
        }
    }

    // MARK: - Following the shared chrome

    /// Re-arm on every field this controller actuates from, then actuate. The tree's UIKit idiom
    /// (`MacTitlebarBand.follow()`): `withObservationTracking` fires ONCE, so the re-arm is the
    /// subscription, and the `DispatchQueue.main.async` hop is required because `onChange` runs
    /// INSIDE the mutation — reading a value there gets the old one.
    private func follow() {
        var sidebarCollapsed = false
        var panelCollapsed = false
        var cheatSheetVisible = false
        var tabCount = 0
        var autoHide = AutoHideTabsPanelMode.default
        withObservationTracking {
            sidebarCollapsed = chrome.sidebarCollapsed
            panelCollapsed = chrome.codeSidebarCollapsed
            cheatSheetVisible = overlay.cheatSheetVisible
            tabCount = store.tree.activeSession?.tabs.count ?? 0
            // ⚠️ INSIDE the tracked block, and that placement is the whole point — the read below is
            // what arms the tracker on ``ConfigRevision``, the only observable edge a config-file edit
            // has. Hoisted out (read where the policy runs, say) it observes nothing and a settings
            // flip stays invisible until something unrelated happens to wake this.
            autoHide = autoHideTabsPanel
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        applyAutoHidePolicy(mode: autoHide, tabCount: tabCount)
        applyChrome(
            sidebarCollapsed: sidebarCollapsed, panelCollapsed: panelCollapsed,
            cheatSheetVisible: cheatSheetVisible,
        )
    }

    /// Actuate the split's display mode and the two presentations, each guarded against a value that
    /// did not change. The guards are what make the re-arm cheap: any touched field wakes `follow()`,
    /// and almost none of them mean a column has to move.
    private func applyChrome(sidebarCollapsed: Bool, panelCollapsed: Bool, cheatSheetVisible: Bool) {
        if appliedSidebarCollapsed != sidebarCollapsed {
            appliedSidebarCollapsed = sidebarCollapsed
            isActuating = true
            // `.oneBesideSecondary` rather than `.automatic` on the reveal: `.automatic` lets the
            // system pick, and on a regular-width iPad it can pick the overlay reading — which is the
            // one behaviour the tile choice above exists to refuse.
            split.preferredDisplayMode = sidebarCollapsed ? .secondaryOnly : .oneBesideSecondary
            isActuating = false
        }
        // The two presentations wait for a window. Leaving the applied values UNSET while they wait is
        // what makes the wait recoverable: `viewDidAppear` re-applies, sees the mismatch still there,
        // and puts the panel up. Recording the value here instead would swallow it forever.
        guard canPresent else { return }
        if appliedPanelCollapsed != panelCollapsed {
            appliedPanelCollapsed = panelCollapsed
            if panelCollapsed { dismissPanel() } else { presentPanel() }
        }
        if appliedCheatSheetVisible != cheatSheetVisible {
            appliedCheatSheetVisible = cheatSheetVisible
            if cheatSheetVisible { presentCheatSheet() } else { dismissCheatSheet() }
        }
    }

    /// Thin glue over ``WorkspaceChromePolicy/applyAutoHide(mode:tabCount:chrome:)`` — actuate the
    /// tracked inputs, so the tested unit stays the policy. Runs on the FIRST pass as well as on every
    /// transition of EITHER input, which is what the deleted view's two `.onChange`s bought.
    private func applyAutoHidePolicy(mode: AutoHideTabsPanelMode, tabCount: Int) {
        guard lastAutoHide?.mode != mode || lastAutoHide?.tabCount != tabCount else { return }
        lastAutoHide = (mode, tabCount)
        WorkspaceChromePolicy.applyAutoHide(mode: mode, tabCount: tabCount, chrome: chrome)
    }

    /// ⚠️ `AppConfig` is a plain locked global, not `@Observable` — reading the generation is what ties
    /// a settings flip to this controller's tracker. The deleted view read it for the same reason,
    /// with the same comment; dropping the read makes the mode change invisible until something else
    /// happens to wake the tracker.
    private var autoHideTabsPanel: AutoHideTabsPanelMode {
        _ = ConfigRevision.shared.generation
        return SettingsKey.autoHideTabsPanel
    }

    // MARK: - The two presentations

    /// THE RIGHT PANEL, as a phone can have one. A cover does not inherit the presenter's custom
    /// environment — in SwiftUI that forced every value to become an `init` parameter (docs/62 stage
    /// B), and in UIKit it is simply how a controller is built, which is the whole of what stage B
    /// was working around.
    private func presentPanel() {
        guard panel == nil else { return }
        let panel = PhonePanelViewController(
            store: store, connection: connection, chrome: chrome, overlay: overlay,
            preferences: preferences,
        )
        panel.modalPresentationStyle = .fullScreen
        // Every dismissal — the close plate, a swipe down — routes through the shared flag, so the
        // workstyle choice persists exactly as the Mac's hide toggle writes it.
        panel.onClose = { [chrome] in chrome.collapseCodeSidebar() }
        self.panel = panel
        present(panel, animated: true)
    }

    private func dismissPanel() {
        guard let panel else { return }
        self.panel = nil
        panel.dismiss(animated: true)
    }

    private func presentCheatSheet() {
        guard cheatSheet == nil else { return }
        let sheet = KeyboardCheatSheetViewController(coordinator: overlay)
        sheet.modalPresentationStyle = .formSheet
        // `cheatSheetVisible` is `private(set)`, so every system dismissal (the swipe, Esc on a
        // hardware keyboard) has to route back through `closeCheatSheet()` rather than just tearing
        // the controller down — otherwise the coordinator still believes the sheet is up and the next
        // ⌘/ toggles it shut.
        sheet.onDismiss = { [overlay] in overlay.closeCheatSheet() }
        cheatSheet = sheet
        present(sheet, animated: true)
    }

    private func dismissCheatSheet() {
        guard let cheatSheet else { return }
        self.cheatSheet = nil
        cheatSheet.dismiss(animated: true)
    }

    // MARK: - Wiring the shared seams

    /// Bind the overlay coordinator's `resolveActiveCwd` to the focused pane's live ``MetadataClient``
    /// so opening the command palette EAGERLY resolves its working directory (host `cwd()` RPC) and
    /// mirrors it into `pane/cwd` — which the WORKING DIRECTORY header's cwd pill (and the titlebar /
    /// rail) read reactively. Without this the pill stayed blank on a freshly-connected pane at a
    /// prompt: the only other `pane/cwd` writer (a command completing via OSC 133;D) had not fired.
    /// Reuses the EXACT live-metadata path Open-Quickly uses, so it spends NO new wire message. A
    /// disconnected pane / nil client / empty cwd is a silent no-op (validate-then-drop). The Mac
    /// binds the same seam from its own root.
    private func wireOverlayCwdResolver() {
        overlay.resolveActiveCwd = { [store] in
            guard let id = store.tree.activeSession?.activeTab?.activePane,
                  let client = (store.handle(for: id) as? LivePaneSession)?.connection?
                  .activeMetadataClient
            else { return }
            Task { @MainActor in
                guard let cwd = await client.cwd(), !cwd.isEmpty else { return }
                store.setLastKnownCwd(cwd, for: id)
            }
        }
    }

    /// Hand the live store the overlay-toggle closures the per-pane hardware-keyboard
    /// ``TerminalKeyInterceptor`` threads into `route` (``WorkspaceStore/overlayKeyToggles``), each
    /// pointed at the injected ``OverlayCoordinator``. iPad has no app-level NSEvent monitor, so
    /// without these a focused terminal's ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J resolved to a `nil` toggle and
    /// did nothing.
    private func wireOverlayKeyToggles() {
        store.overlayKeyToggles = WorkspaceOverlayKeyToggles(
            palette: { [overlay] in overlay.togglePalette() },
            cheatSheet: { [overlay] in overlay.toggleCheatSheet() },
            globalSearch: { [overlay] in overlay.toggleGlobalSearch() },
            jumpTo: { [overlay] in overlay.toggleOpenQuickly(filter: .current) },
            openQuickly: { [overlay] in overlay.toggleOpenQuickly(filter: .all) },
            peekReply: { [overlay] in overlay.togglePeekReply() },
            // The two PANELS, on the same road for the same reason: ⌘⇧L and ⌘⇧R reach the focused
            // terminal surface first here, and both name a panel that exists on this platform.
            sidebar: { [chrome] in chrome.toggleSidebar() },
            codeSidebar: { [chrome] in chrome.toggleCodeSidebar() },
            focusCodePanel: { [chrome] in chrome.revealCodeSidebar() },
        )
    }

    /// Point the coordinator's chrome actuators at the LIVE ``WorkspaceChromeState`` — the phone's half
    /// of what `MacWorkspaceRootView.wireChromeToggles()` does, and what makes the command palette's
    /// View rows do something here rather than nothing. Three of the four were dead on this platform
    /// because the closures default to empty and only the Mac's root ever bound them.
    ///
    /// FOCUS CODE PANEL IS A REVEAL HERE, not a toggle of the keyboard's owner. The Mac's version asks
    /// the webview pool which way to move first responder; there is no responder duel on iOS, so the
    /// honest reading of "focus the code panel" on a device that shows one surface at a time is "put
    /// it up".
    private func wireChromeActions() {
        overlay.toggleSidebar = { [chrome] in chrome.toggleSidebar() }
        overlay.toggleCodeSidebar = { [chrome] in chrome.toggleCodeSidebar() }
        overlay.focusCodePanel = { [chrome] in chrome.revealCodeSidebar() }
        // NO settings action, and that is the whole policy: settings are a config FILE with defaults
        // good enough that nobody has to open it. macOS's palette row opens that file in an editor; a
        // phone has neither the editor nor the file, so the row is a graceful no-op there rather than
        // a control that raises a surface which no longer exists.
    }
}

// MARK: - The split's own edges

extension WorkspaceRootViewController: UISplitViewControllerDelegate {
    /// A user swipe of the leading column — the SECOND manual entry point besides ⌘⇧L — routed
    /// through the shared policy, whose `!=` guard drops the echo of a value this controller just
    /// actuated. ``isActuating`` covers the ordering where the callback arrives before that flag has
    /// settled; without either, an iPad user's swipe would be re-revealed by the auto-hide policy on
    /// the next unrelated tab open/close.
    public func splitViewController(
        _: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode,
    ) {
        guard !isActuating else { return }
        let collapsed = displayMode == .secondaryOnly
        appliedSidebarCollapsed = collapsed
        WorkspaceChromePolicy.applySidebarCollapsed(collapsed, chrome: chrome)
    }

    /// On an iPhone the split collapses to a single stack, and the honest answer to "which column is
    /// showing" is the CONTENT — a workspace opens on its panes, not on its tab list.
    public func splitViewController(
        _: UISplitViewController, topColumnForCollapsingToProposedTopColumn _: UISplitViewController.Column,
    ) -> UISplitViewController.Column {
        .secondary
    }
}
#endif
