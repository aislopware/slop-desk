// MacWorkspaceWindowController — the macOS WINDOW: the AppKit split shell, plus the four things that
// hang off the WINDOW rather than off any column.
//
// The window runs a HIDDEN TITLEBAR — there is no system toolbar carrying items. The workspace's own
// titlebar band (`MacTitlebarBand`, a sibling of the canvas inside `MacContentColumn`) IS the chrome,
// and what this controller adds around the split is: the sidebar toggle pinned to the window's
// top-left corner, the band's aggregate agent reading beside it, and the window title.
//
// It is the macOS half of what used to be `WorkspaceRootView`, one view that reached the iOS
// `NavigationSplitView` and this split shell through a `#if os(...)` down the middle of its body.
// There is not one platform gate left in this file, because the file is the platform (docs/56 §3) —
// the phone's root is `WorkspaceRootViewController` and the two share no ancestor. What they DO share
// they share BELOW the view layer: ``WorkspaceChromePolicy`` (auto-hide, window title),
// ``OverlayCoordinator`` and the store itself.
//
// ⚠️ IT WAS `MacWorkspaceRootView`, A SwiftUI VIEW, AND WHAT IT WRAPPED WAS ALREADY THIS. The body
// was one `WorkspaceSplitRepresentable` — an `NSViewControllerRepresentable` over
// ``SlopDeskSplitViewController`` — with two `.overlay(alignment: .topLeading)`s and five observers
// hung off it. Every one of those five is a thing AppKit says more directly, and each is DELETED in
// its SwiftUI spelling rather than mirrored:
//
//   * `WorkspaceSplitRepresentable` itself. Its `makeNSViewController` is the `init` below and its
//     `updateNSViewController` — which read the two `@Observable` collapse flags to tie the update to
//     them — is ``followChrome()``, one ``ObservationFollow`` reading the same two flags.
//     A representable whose only job is to re-push two booleans into a controller it also created is
//     a hosting seam, and there is nothing left to host it in.
//   * `.overlay(alignment: .topLeading)` ×2 → two subviews of the window's content view, constrained
//     to its leading and top anchors. ⚠️ THE `.ignoresSafeArea()` THOSE OVERLAYS HAD TO BE INSIDE IS
//     GONE WITH THEM, and so is the bug it was fixing: SwiftUI hands a `.hiddenTitleBar` window's
//     content a top safe-area inset the height of the titlebar, so an overlay attached OUTSIDE that
//     modifier parked the sidebar toggle one whole band low, on top of the navigator's search field
//     (measured 2026-08-09). `NSWindow.contentView` has no such inset — `fullSizeContentView` means
//     the content view IS the window's frame — so the two mounts sit at their own numbers with
//     nothing to escape.
//   * `.navigationTitle(...)` → `NSWindow.title`, which is what that modifier set. The window is
//     titlebar-less so the string is not drawn, but it IS the window's name in the Window menu,
//     Mission Control, screenshot filenames and accessibility, and it tracks the focused pane.
//   * `.background(Slate.Surface.field.ignoresSafeArea())` → the content view's own layer colour. It
//     is THE GROUND behind the split (law 1): one opaque tone under all three columns, which
//     backstops any transient gap (a mid-animation collapse) so no bare window colour ever shows. It
//     is also what the window's own 16pt corners bite into.
//   * `.onAppear` / three `.onChange`s → ``wireChromeToggles()`` at ``mount()`` time, and two
//     ``ObservationFollow`` arms. The FOCUS observer keeps its shape exactly: one observer for
//     the tab and the pane together, because a tab switch changes the focused pane too and the two
//     questions must not race each other from separate arms.
//
// ⚠️ NOTHING FLOATS OVER THE SPLIT FROM HERE (docs/56 stage D). Every summoned card is an `NSPanel`
// of the Mac's own (``MacOverlayPanels``), and the last two surfaces — the Connect-to-Host FORM and
// the close-confirmation ALERT, which were never cards — are the platform's own sheets
// (``MacConnectSheet``, ``MacCloseConfirmation``), presented by the delegate against this window.
// That is what the whole ordering argument in docs/56 was for: a hosting view claims every hit inside
// its own bounds, so any always-mounted layer over the split makes the window click-dead everywhere
// its ink is not. There is none, and `connection` is threaded here only for the split beneath.

import AppKit
import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskVideoProtocol // ConfigRevision — what makes the config-backed reads below live
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

@MainActor
final class MacWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private let store: WorkspaceStore
    /// The single ``OverlayCoordinator`` (command palette / cheat sheet / toasts / connect / remote-window
    /// picker), built once by ``ClientComposition`` and injected here. The window binds its chrome
    /// toggles + cwd resolver (see ``wireChromeToggles()``).
    private let overlay: OverlayCoordinator
    /// The two split-collapse flags + the window-pin flag the chrome toggles drive (read by
    /// ``followChrome()``). OWNED BY THE COMPOSITION, NOT controller-local state — so the delegate's
    /// pin follow reads the SAME `chrome.pinned` the titlebar / menu / palette flip (ONE
    /// `NSWindow.level` source of truth, no `NSApplication.windows`).
    private let chrome: WorkspaceChromeState

    /// Installs the sidebar / Tabs-panel toggle on the app-level keybinding dispatcher. The dispatcher is
    /// built at app `init` (before this window exists), so on load the controller hands it
    /// `chrome.toggleSidebar` — ⌘⇧L flips the LIVE `chrome.sidebarCollapsed` the native split reads, not
    /// the legacy `store.sidebarCollapsed` (which nothing reads on macOS). `nil` (previews / tests) is a
    /// no-op. A plain closure keeps ``WorkspaceKeyDispatcher`` out of this controller's signature.
    private let installSidebarToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the RIGHT code panel's toggle on the app-level keybinding dispatcher (same late-wiring
    /// as `installSidebarToggle`): hands it `chrome.toggleCodeSidebar` so ⌘⇧R flips the LIVE
    /// `chrome.codeSidebarCollapsed` the native split reads. `nil` (previews / tests) is a no-op.
    private let installCodeSidebarToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the code panel's keyboard hand-off on the dispatcher (same late-wiring): ⌥⌘R moves
    /// the keyboard into the embedded editor and back. `nil` (previews / tests) is a no-op.
    private let installFocusCodePanel: ((@escaping () -> Void) -> Void)?
    /// Installs the "Pin Window" toggle on the app-level keybinding dispatcher (same late-wiring as
    /// `installSidebarToggle`): hands it `chrome.togglePin` so a user-bound chord for the chord-less
    /// `.pinWindow` action routes through the SAME NSEvent monitor. `nil` (previews / tests) is a no-op —
    /// Pin Window's primary entry is then the menu item + palette.
    private let installPinToggle: ((@escaping () -> Void) -> Void)?

    /// THE SHELL. Owned outright — the representable used to create it in `makeNSViewController` and
    /// hand SwiftUI the retain; the controller holds it as its own `contentViewController`, which is
    /// the arrangement that was being simulated.
    private let split: SlopDeskSplitViewController
    private let sidebarToggle = MacWindowSidebarToggleView()
    private let rollup: RailStatusRollupMount

    /// Called once, the first time the grid-mode window sizing can see REAL terminal cell metrics.
    /// The introspect closure got this for free by re-firing on every scene re-render; a window
    /// controller fires once, so the one thing that genuinely needed a second look asks for it by
    /// name. See ``retryGridSizeWhenCellMetricsArrive(_:)``.
    private var gridSizeRetry: (() -> Void)?
    private var gridSizeRetried = false

    init(
        store: WorkspaceStore,
        connection: AppConnection,
        overlay: OverlayCoordinator,
        chrome: WorkspaceChromeState,
        // Defaulted, like every parameter below it: a preview or a test window that never opens a tab
        // context menu has no preferences to hand over, and the row it would surface hides itself.
        preferences: PreferencesStore? = nil,
        paneDrag: PaneDragCoordinator? = nil,
        installSidebarToggle: ((@escaping () -> Void) -> Void)? = nil,
        installCodeSidebarToggle: ((@escaping () -> Void) -> Void)? = nil,
        installFocusCodePanel: ((@escaping () -> Void) -> Void)? = nil,
        installPinToggle: ((@escaping () -> Void) -> Void)? = nil,
    ) {
        self.store = store
        self.overlay = overlay
        self.chrome = chrome
        self.installSidebarToggle = installSidebarToggle
        self.installCodeSidebarToggle = installCodeSidebarToggle
        self.installFocusCodePanel = installFocusCodePanel
        self.installPinToggle = installPinToggle
        split = SlopDeskSplitViewController(
            store: store, connection: connection, chrome: chrome, preferences: preferences,
            onConnect: { [overlay] in overlay.openConnect() },
            overlay: overlay,
            paneDrag: paneDrag,
        )
        rollup = RailStatusRollupMount(store: store, chrome: chrome)

        // THE WINDOW ITSELF, at the geometry the scene declared with `.defaultSize` / `.defaultPosition`.
        // `.remember` seeds the CREATION geometry from the saved frame so the window never paints a
        // wrong-size first frame; the fallback is the odiff reference geometry (1280×800 — fresh
        // install, other modes, automation). ``SlopDeskMacApp/applyInitialWindowSize(to:store:chrome:
        // fontPointSize:)`` then reconciles exactly, which is what `.defaultPosition` being
        // PROPORTIONAL (a `UnitPoint`, not a frame) always required.
        let seed = SlopDeskMacApp.rememberedFrameSeed
        let content = NSRect(
            x: 0, y: 0,
            width: seed?.frame.width ?? 1280,
            height: seed?.frame.height ?? 800,
        )
        let window = NSWindow(
            contentRect: content,
            // `.fullSizeContentView` is `.windowStyle(.hiddenTitleBar)`'s other half: the window keeps
            // its traffic lights and gives the content view the whole frame, which is what lets the
            // band draw where a titlebar would be.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // `.automatic` resizability, spelled as the floors the split's own items already state: the
        // window may not be dragged narrower than the columns can be.
        window.contentMinSize = NSSize(
            width: SlopDeskSplitViewController.defaultSidebarWidth
                + SlopDeskSplitViewController.contentMinWidth,
            height: 400,
        )
        // ⚠️ NO `setFrameAutosaveName`, and that is not an oversight — see
        // ``SlopDeskMacApp/applyRememberedFrame(to:)``: the `.remember` mode owns both halves of the
        // save itself, at end-of-gesture granularity, under the app's own Defaults key.
        super.init(window: window)
        window.delegate = self
        window.contentViewController = split
        if seed == nil { window.center() }
        mount()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Everything that hangs off the window once it exists: the ground, the two window-level chrome
    /// mounts, the late toggle wiring and the three follows.
    ///
    /// ⚠️ CALLED FROM `init`, NOT FROM `windowDidLoad()`, and the difference is not stylistic.
    /// `windowDidLoad()` is the NIB path's hook — it runs after `loadWindow()` inflates a window from
    /// a `windowNibName`. A controller built through `init(window:)` hands AppKit an already-made
    /// window, so `loadWindow()` never runs and the hook never fires. Putting this body there would
    /// have compiled, shown a window, and silently mounted no chrome, wired no toggle and armed no
    /// follow — the exact failure mode a hidden titlebar makes hardest to see, because the window
    /// still looks nearly right. The window is fully formed two lines above; this is simply the rest
    /// of `init`, named so the reason survives.
    private func mount() {
        guard let window, let root = window.contentView else { return }

        // THE GROUND behind the split (law 1) — one opaque tone under all three columns, which
        // backstops any transient gap (a mid-animation collapse) so no bare window colour ever
        // shows. It is also what the window's own 16pt corners bite into.
        root.wantsLayer = true
        root.layer?.backgroundColor = Slate.Native.Surface.field.cgColor

        // THE SIDEBAR TOGGLE, mounted at WINDOW level rather than in either column (user-directed
        // 2026-08-09). Both columns travel when the panel collapses — the split animates the item
        // width — so a button hosted inside one of them rides that slide and crawls under the traffic
        // lights on its way. Here it cannot move at all: it is pinned to the window's own top-left
        // corner, and the click's acknowledgement is the plate's own fill rung (see
        // ``MacWindowSidebarToggleView``).
        root.addSubview(sidebarToggle)
        // The band's AGGREGATE AGENT READING, mounted beside the toggle for the SAME reason and with
        // the opposite consequence: the toggle is here so it can never move, this is here so it can
        // move BETWEEN the two places it belongs — flush with the navigator's gutter while the
        // column is up, back against the toggle once the column is gone (``RailStatusRollupMount``).
        root.addSubview(rollup)

        NSLayoutConstraint.activate([
            sidebarToggle.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: MacWindowSidebarToggleView.leadingInset,
            ),
            sidebarToggle.topAnchor.constraint(
                equalTo: root.topAnchor, constant: MacWindowSidebarToggleView.topInset,
            ),
            // The rollup is a full-width STRIP the cluster slides across (it takes no hits of its
            // own — see ``RailStatusRollupMount/hitTest(_:)``), so it spans the band rather than
            // being placed at one x.
            rollup.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rollup.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rollup.topAnchor.constraint(equalTo: root.topAnchor),
            rollup.heightAnchor.constraint(equalToConstant: Slate.Metric.titlebarHeight),
        ])

        // Wire ⌘⇧L (Toggle Tabs Panel) and its three siblings to the live chrome. The dispatcher is
        // built at app `init` (before this window), so the toggles install here.
        wireChromeToggles()
        followChrome()
        followTitle()
        followFocus()
    }

    // MARK: The split's collapse

    /// Push the two `@Observable` collapse flags into the split's items, and re-arm.
    ///
    /// ⚠️ THIS IS `WorkspaceSplitRepresentable.updateNSViewController`, WITHOUT THE REPRESENTABLE. That
    /// method's comment said it out loud — "reading the @Observable flags here ties this update to
    /// their changes" — which is a description of an observation arm written for a framework that
    /// supplied one implicitly. It reads the same two flags and calls the same one method; what
    /// is gone is the machinery that made a whole view tree the unit of re-evaluation.
    private func followChrome() {
        ObservationFollow.arm(self) { controller in
            (
                sidebar: controller.chrome.sidebarCollapsed,
                codeSidebar: controller.chrome.codeSidebarCollapsed,
            )
        } apply: { controller, reading in
            controller.split.applyCollapse(
                sidebarCollapsed: reading.sidebar, codeSidebarCollapsed: reading.codeSidebar,
            )
            controller.sidebarToggle.apply(collapsed: reading.sidebar) { [chrome = controller.chrome] in
                chrome.toggleSidebar()
            }
        }
    }

    // MARK: The title

    /// The macOS WINDOW title tracks the FOCUSED pane (user: the window stayed a static "Terminal").
    /// With the titlebar hidden this text is not drawn, but it IS the window's name in the Window
    /// menu, Mission Control / Exposé, screenshot filenames and accessibility.
    /// ``WorkspaceChromePolicy/windowTitle(for:)`` reads the active pane + its spec, so the
    /// `@Observable` store re-titles the window on a pane switch, a live OSC-0/2 title, or a `cd`
    /// (the cwd folder name).
    ///
    /// ⚠️ IT IS ITS OWN FOLLOW, not a line inside another one. The title reads deep into the store —
    /// the active pane's spec, its process, its cwd — and folding it into the collapse follow's `read`
    /// would re-push the split's items on every character a shell prints into a title sequence. (The
    /// other half of that fear — work smuggled into the tracked block widening it — is now
    /// ``ObservationFollow``'s `read`/`apply` signature rather than this comment's to hold.)
    private func followTitle() {
        ObservationFollow.arm(self) { controller in
            WorkspaceChromePolicy.windowTitle(for: controller.store)
        } apply: { controller, title in
            controller.window?.title = title
            // The grid-mode sizing wants REAL cell metrics and a fresh window has none; a title change
            // is the first thing that happens after a terminal surface lays out and reports them, so it
            // is where the one deferred re-measure is taken. See
            // ``retryGridSizeWhenCellMetricsArrive(_:)``.
            controller.takeGridSizeRetry()
        }
    }

    /// Hand back the one deferred window re-size for `grid` mode.
    ///
    /// ⚠️ THIS EXISTS BECAUSE `.introspect(.window)` RE-FIRED AND A WINDOW CONTROLLER DOES NOT, and it
    /// is the ONE place that difference cost something rather than saving it. The scene applied the
    /// initial size on every re-render, guarded by an associated-object one-shot that
    /// ``SlopDeskMacApp/applyInitialWindowSize(to:store:chrome:fontPointSize:)`` deliberately left
    /// UNSET while a `grid` window was still on the font-derived fallback cell — so a later fire
    /// recomputed to the exact cols×rows once libghostty reported its true advance. There are no later
    /// fires now, so the retry is explicit, taken once, and dropped.
    func retryGridSizeWhenCellMetricsArrive(_ retry: @escaping () -> Void) {
        gridSizeRetry = retry
    }

    private func takeGridSizeRetry() {
        guard !gridSizeRetried, let retry = gridSizeRetry else { return }
        gridSizeRetried = true
        gridSizeRetry = nil
        retry()
    }

    // MARK: The auto-hide policy

    /// The live `auto-hide-tabs-panel` mode. It reads ``ConfigRevision/generation`` first: `AppConfig`
    /// is a plain locked global, so the bare ``SettingsKey/autoHideTabsPanel`` accessor registers no
    /// dependency and the follow would never re-arm. Reading the revision inside the tracked block is
    /// what re-fires the policy when the user saves their config file.
    private var autoHideTabsPanel: AutoHideTabsPanelMode {
        _ = ConfigRevision.shared.generation
        return SettingsKey.autoHideTabsPanel
    }

    /// The active session's tab count — the auto-hide policy's input. `nil` (no active session yet)
    /// reads as `0`, which collapses under `.auto` (nothing to switch between).
    private var activeTabCount: Int { store.tree.activeSession?.tabs.count ?? 0 }

    /// Where the workspace's focus is sitting, and what asked for it — the triple the code panel's
    /// per-tab focus region is resolved against on every change (see ``honourFocusRegion(from:to:)``).
    /// The intent rides along because a tab switch and a cross-tab pane jump land identically.
    private struct FocusLanding: Equatable {
        var tab: TabID?
        var pane: PaneID?
        var intent: WorkspaceStore.FocusIntent?
    }

    private var focusLanding: FocusLanding {
        let tab = store.tree.activeSession?.activeTab
        return FocusLanding(tab: tab?.id, pane: tab?.activePane, intent: store.lastFocusIntent)
    }

    /// The last landing acted on, so the follow can tell WHAT MOVED — the `(previous, current)` pair
    /// SwiftUI's `.onChange` handed over for free.
    private var lastLanding: FocusLanding?
    /// The tab count last acted on, for the same reason: the auto-hide policy gates on the 1↔>1
    /// REGIME edge and needs the previous side of it.
    private var lastTabCount: Int?

    /// THE KEYBOARD FOLLOWS THE WORKSPACE, and each tab keeps its own answer to "terminal or code
    /// panel?". ONE follow for both, because a tab switch changes the focused pane too and the two
    /// questions must not race each other from separate arms — the same reason the SwiftUI original
    /// gave for putting them in one `.onChange`.
    ///
    /// The auto-hide policy rides the same follow because it reads the same tab list: splitting them
    /// would mean two blocks both observing `store.tree.activeSession`, waking each other.
    private func followFocus() {
        ObservationFollow.arm(self) { controller in
            (
                landing: controller.focusLanding,
                tabCount: controller.activeTabCount,
                mode: controller.autoHideTabsPanel,
            )
        } apply: { controller, reading in
            if let previous = controller.lastLanding, previous != reading.landing {
                controller.honourFocusRegion(from: previous, to: reading.landing)
            }
            controller.lastLanding = reading.landing
            // Drive the vertical TABS panel auto-hide. On a tab-count TRANSITION or a Settings mode
            // flip, apply the policy to the live `chrome.sidebarCollapsed` — but only when the policy
            // has an opinion (`.auto`) AND the 1↔>1 tab-count regime crossed, so a manual ⌘⇧L is never
            // fought by an unrelated tab open/close
            // (``WorkspaceChromePolicy/applyAutoHide(mode:tabCount:chrome:)`` gates on the regime edge
            // + a manual-override bit). `.default`/`.always` leave it alone.
            //
            // ⚠️ The FIRST arm runs it too — this is the `initial: true` the SwiftUI observer carried.
            // Without it a persisted `.auto` single-tab session would launch with the sidebar REVEALED
            // until the user added or removed a tab. `sidebarCollapsed` is not persisted, so applying
            // at launch is safe (the first application reads as a regime edge and actuates).
            if controller.lastTabCount != reading.tabCount || controller.lastTabCount == nil {
                controller.lastTabCount = reading.tabCount
                WorkspaceChromePolicy.applyAutoHide(
                    mode: reading.mode, tabCount: reading.tabCount, chrome: controller.chrome,
                )
            }
        }
    }

    /// Put the keyboard where the workspace's new focus says it belongs.
    ///
    /// A TAB SWITCH hands the arriving tab its own focus region: a tab the user was last editing in
    /// gets the code panel back, and any other tab gets its terminal — including when the panel is
    /// holding the keyboard, which is otherwise inherited by whatever tab you switch to. The region
    /// is per-tab because that is how it reads: leaving tab A mid-edit, working in tab B and coming
    /// back to A should put the caret back in A's editor (user-reported 2026-08-10).
    ///
    /// A PANE FOCUS inside the tab already on screen (a split's new leaf, ⌘-arrow, a rail row) says
    /// the terminal is what the user wants, and the panel must let go of the keyboard — the pane
    /// tree gates every pane's focus on the panel's ownership, so a move made while the editor holds
    /// it was previously swallowed whole.
    ///
    /// A pane TELEPORT that also crosses tabs (a palette hit, a Global Search landing) is a PANE
    /// landing, not a tab switch, even though it changes the active tab as well — the two are told
    /// apart by ``WorkspaceStore/FocusIntent``, which the store's two focus choke points record and
    /// nothing else does. A focus move that passes through neither (a split's new leaf, a close's
    /// landing, another client's focus arriving in the document) carries no fresh intent and is read
    /// off the shape of the change instead.
    private func honourFocusRegion(from previous: FocusLanding, to current: FocusLanding) {
        switch CodeSidebarFocusPolicy.landingAction(
            intentNamedPane: current.intent?.kind == .pane,
            intentIsFresh: previous.intent?.seq != current.intent?.seq,
            tabChanged: previous.tab != current.tab,
            paneChanged: previous.pane != current.pane,
        ) {
        case .honourTabRegion:
            let live = Set(store.tree.sessions.flatMap { $0.tabs.map(\.id) })
            CodeSidebarWebViewPool.shared.noteActiveTabChanged(to: current.tab, liveTabs: live)
        case .yieldToPane:
            CodeSidebarWebViewPool.shared.noteWorkspacePaneFocused(tab: current.tab)
        case .none:
            break
        }
    }

    // MARK: The late wiring

    /// Hand the app-level dispatcher the chrome toggles (sidebar ⌘⇧L), bound to the live chrome.
    /// Called from ``mount()`` (the dispatcher predates this window, so the closures install late).
    /// `[chrome]` captures the same `@Observable` the split + titlebar read, so each NSEvent chord and
    /// the matching titlebar button flip ONE flag.
    private func wireChromeToggles() {
        installSidebarToggle? { [chrome] in chrome.toggleSidebar() }
        // The RIGHT code panel's ⌘⇧R — same late-wiring onto the same live chrome.
        installCodeSidebarToggle? { [chrome] in chrome.toggleCodeSidebar() }
        // ⌥⌘R: the keyboard's way into the embedded editor and back. The pool decides the direction
        // from where first responder actually is; the chrome flag only says whether the panel has to
        // be revealed first, and `toggleCodeSidebar` is the reveal (it is a two-way toggle, and this
        // branch runs only while collapsed).
        let focusCodePanel: @MainActor () -> Void = { [chrome] in
            CodeSidebarWebViewPool.shared.toggleKeyboardFocus(
                panelCollapsed: chrome.codeSidebarCollapsed,
                reveal: { chrome.toggleCodeSidebar() },
            )
        }
        installFocusCodePanel?(focusCodePanel)
        overlay.focusCodePanel = focusCodePanel
        // Route the palette's chrome-toggle row through the SAME live `chrome` the chord + titlebar drive, so
        // "Toggle Tabs Panel" flips the flag the split + the ✓ read (not the dead `store.sidebarCollapsed`).
        // Bound here because `chrome` predates the app-built overlay.
        overlay.toggleSidebar = { [chrome] in chrome.toggleSidebar() }
        overlay.toggleCodeSidebar = { [chrome] in chrome.toggleCodeSidebar() }
        // Pin Window: route the palette / any command surface AND a user-bound chord (chord-less by default)
        // to the SAME live `chrome.pinned` the menu item + the macOS `NSWindow.level` glue read.
        overlay.togglePinWindow = { [chrome] in chrome.togglePin() }
        installPinToggle? { [chrome] in chrome.togglePin() }
        // The terminal's AppKit tracking area fires under a modal card (rect-based — no occlusion),
        // so the production renderer reads this shield before forwarding pointer positions to a
        // mouse-reporting TUI. Bound to the SAME modal flag the columns gate their hit-testing on, so
        // the whole workspace goes pointer-deaf under a card at once.
        //
        // OR'd with the PANE-LOCAL family, which that flag cannot see: the Command Navigator (⌃⌘O)
        // is mounted inside one leaf rather than by the overlay coordinator — deliberately, so a
        // card over one pane does not deafen the sidebar — and the terminal it covers is exactly the
        // one whose tracking area keeps firing. The shield itself is process-wide either way, so the
        // two questions can only be joined here.
        TerminalPointerShield.isActive = { [overlay] in
            overlay.anyModalVisible || MacPaneCardShield.isPresenting
        }
        wireOverlayCwdResolver()
    }

    /// Bind the overlay coordinator's `resolveActiveCwd` to the focused pane's live ``MetadataClient`` so
    /// opening the command palette EAGERLY resolves its working directory (host `cwd()` RPC) and mirrors it
    /// into `pane/cwd` — which the WORKING DIRECTORY header's cwd pill (and the titlebar / rail)
    /// read reactively. Without this the pill stayed blank on a freshly-connected pane at a prompt: the only
    /// other `pane/cwd` writer (a command completing via OSC 133;D) had not fired. Reuses the EXACT
    /// live-metadata path Open-Quickly uses (`store.handle(for:) as? LivePaneSession → activeMetadataClient`),
    /// so it spends NO new wire message. `[store]` captures the live store; a disconnected pane / nil client /
    /// empty cwd is a silent no-op (validate-then-drop). The phone binds the same seam from its own root.
    private func wireOverlayCwdResolver() {
        overlay.resolveActiveCwd = { [store] in
            guard let id = store.tree.activeSession?.activeTab?.activePane,
                  let client = (store.handle(for: id) as? LivePaneSession)?.connection?.activeMetadataClient
            else { return }
            Task { @MainActor in
                guard let cwd = await client.cwd(), !cwd.isEmpty else { return }
                store.setLastKnownCwd(cwd, for: id)
            }
        }
    }
}
