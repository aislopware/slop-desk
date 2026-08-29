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
import SlopDeskClientCore
import SlopDeskSlate
import SlopDeskVideoProtocol // ConfigRevision — the config-file edge the tracked read arms on
import SlopDeskWorkspaceCore
import UIKit

/// The window's content: a two-column split, an overlay layer, and the chrome wiring both need.
@preconcurrency
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

    /// The "are you sure you want to close this?" alert, driven off the store's park. The SECOND
    /// natively-presented overlay, and presented for the reason the cheat sheet is: it is summoned by a
    /// deliberate gesture rather than raised by a remote program, so the layer's drop-a-second-present
    /// hazard cannot reach it. It follows the store itself — this controller only tells it where to
    /// present from.
    private let closeConfirmation: PhoneCloseConfirmation

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

    /// ⚠️ `package`, NOT `public`, and the compiler is the one that decided. `WorkspaceChromeState` is
    /// `package` (`App/WorkspaceChromeState.swift:20`), so a `public init` taking one does not compile
    /// — "initializer cannot be declared public because its parameter uses a package type". The right
    /// fix is to lower the initializer rather than to raise the chrome: the only caller is
    /// `PhoneSceneDelegate.swift:58`, inside this very module, so nothing outside the package ever
    /// built one. The CLASS stays `public` because the app target names the type.
    package init(
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
        closeConfirmation = PhoneCloseConfirmation(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    // MARK: - Mounting

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Slate.Native.Surface.field

        mountSplit()
        mountConnectionIsland()
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
    /// This deliberately re-applies rather than calling ``follow()`` again: arming is NOT idempotent, so
    /// a second `follow()` would leave two live chains and double every subsequent re-arm. The arm taken
    /// at load is still the live one; this just actuates what it already read.
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !canPresent else { return }
        canPresent = true
        reapply()
        // Armed HERE and once, for the same reason `canPresent` exists: the first reading applies
        // synchronously, and a park restored under a launch would try to present before there is a
        // presenter in the hierarchy.
        closeConfirmation.start(host: self)
    }

    /// Actuate against the CURRENT values, outside the tracker. Reading here does not subscribe, and
    /// must not: the arm from ``follow()`` is still the live one, and a second arm would double every
    /// re-arm after it.
    private func reapply() {
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

    /// The link island, into the CONTENT column's toolbar.
    ///
    /// Mounted from here rather than from `ContentColumnViewController` because the item belongs to the
    /// chrome cluster and that controller is the canvas cluster's — it owns the `navigationItem` the
    /// split gives it, and this owns what goes in it. The two halves meet at exactly this line, which is
    /// the arrangement that file's own header describes.
    ///
    /// TRAILING, and alone there: it is the one item on the row that is a READING rather than a verb, and
    /// the toolbar's leading edge belongs to the split's own column-toggle button on a compact width.
    /// Held only by the bar item — a `UIBarButtonItem` retains its custom view, and the island's live
    /// observation is retained by the subscription rather than by a handle, so a second stored reference
    /// here would only be a second thing to keep in step.
    private func mountConnectionIsland() {
        let island = ConnectionIslandView(
            store: store,
            connection: connection,
            // The tap opens the Connect editor, which is the same overlay the palette's "Connect to
            // Host…" row reaches — one door, two ways in.
            onConnect: { [overlay] in overlay.openConnect() },
        )
        content.navigationItem.rightBarButtonItem = UIBarButtonItem(customView: island)
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

    /// Everything this controller actuates from, in one reading. A struct rather than a tuple because
    /// five fields past three stop being readable at the `apply` end.
    private struct Chrome {
        let sidebarCollapsed: Bool
        let panelCollapsed: Bool
        let cheatSheetVisible: Bool
        let tabCount: Int
        let autoHide: AutoHideTabsPanelMode
    }

    /// Re-arm on every field this controller actuates from, then actuate — through the tree's one
    /// spelling of that, ``ObservationFollow``. Armed once from `viewDidLoad`, and never re-armed: the
    /// subject never moves, so the handle is discarded and the arm ends with this controller.
    private func follow() {
        ObservationFollow.arm(self) { root in
            Chrome(
                sidebarCollapsed: root.chrome.sidebarCollapsed,
                panelCollapsed: root.chrome.codeSidebarCollapsed,
                cheatSheetVisible: root.overlay.cheatSheetVisible,
                tabCount: root.store.tree.activeSession?.tabs.count ?? 0,
                // ⚠️ INSIDE the read, and that placement is the whole point — this is what arms the
                // tracker on ``ConfigRevision``, the only observable edge a config-file edit has. Moved
                // into `apply` (read where the policy runs, say) it observes nothing and a settings flip
                // stays invisible until something unrelated happens to wake this.
                autoHide: root.autoHideTabsPanel,
            )
        } apply: { root, chrome in
            root.applyAutoHidePolicy(mode: chrome.autoHide, tabCount: chrome.tabCount)
            root.applyChrome(
                sidebarCollapsed: chrome.sidebarCollapsed, panelCollapsed: chrome.panelCollapsed,
                cheatSheetVisible: chrome.cheatSheetVisible,
            )
        }
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
        // ONE PRESENTATION AT A TIME, and the two are actuated in a fixed order rather than in one
        // pass. Leaving the applied value UNSET when a step is refused is what makes the refusal
        // recoverable: the next pass sees the mismatch still there and actuates it. Recording it
        // anyway — the obvious shape — would swallow the transition forever.
        guard canPresent, !isTransitioning else { return }
        if appliedPanelCollapsed != panelCollapsed {
            // A dismissal is always allowed; only a PRESENTATION has to wait for the surface in front
            // of it to leave. Refusing the dismissal too would deadlock the pair: the cheat sheet
            // could never come down to let the panel go up.
            guard panelCollapsed || canStartPresentation else { return }
            appliedPanelCollapsed = panelCollapsed
            if panelCollapsed { dismissPanel() } else { presentPanel() }
            return
        }
        if appliedCheatSheetVisible != cheatSheetVisible {
            guard !cheatSheetVisible || canStartPresentation else { return }
            appliedCheatSheetVisible = cheatSheetVisible
            if cheatSheetVisible { presentCheatSheet() } else { dismissCheatSheet() }
        }
    }

    /// Whether `present(_:animated:)` from this controller would actually do something.
    ///
    /// ⚠️ UIKIT DROPS A SECOND PRESENTATION, silently and with only a console line. It is not a queue:
    /// `present` while `presentedViewController != nil` does nothing at all. Both surfaces here are
    /// presented from `self` and both are driven by shared observable flags, so "⌘/ while the panel is
    /// up" reaches this — and the flag would then read as actuated with nothing on screen. The deleted
    /// SwiftUI half never hit it because the runtime serialised `.sheet` and `.fullScreenCover`
    /// itself; in UIKit that serialisation has to be written down.
    private var canStartPresentation: Bool { presentedViewController == nil }

    /// Set for the length of a present/dismiss animation. UIKit is equally deaf DURING one: a `present`
    /// issued while a dismissal is still animating is dropped the same way. The completion clears this
    /// and calls ``reapply()``, so a value that arrived mid-flight is actuated rather than lost.
    private var isTransitioning = false

    /// One transition, with the busy flag held across it and a re-apply behind it.
    private func transition(_ body: (@escaping () -> Void) -> Void) {
        isTransitioning = true
        body { [weak self] in
            guard let self else { return }
            isTransitioning = false
            reapply()
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
        transition { done in present(panel, animated: true, completion: done) }
    }

    private func dismissPanel() {
        guard let panel else { return }
        self.panel = nil
        transition { done in panel.dismiss(animated: true, completion: done) }
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
        transition { done in present(sheet, animated: true, completion: done) }
    }

    private func dismissCheatSheet() {
        guard let cheatSheet else { return }
        self.cheatSheet = nil
        transition { done in cheatSheet.dismiss(animated: true, completion: done) }
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
