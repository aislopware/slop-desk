// MacWorkspaceRootView — the macOS WINDOW ROOT: the AppKit split shell, plus the four things that
// hang off the WINDOW rather than off either column.
//
// The window runs `.hiddenTitleBar` — there is NO system toolbar. The workspace's own titlebar band
// (`MacTitlebarBand`, a sibling of the hosted canvas inside `MacContentColumn`) IS the chrome, and what this root
// adds around the split is: the sidebar toggle pinned to the window's top-left corner, the band's
// aggregate agent reading beside it, the floating-overlay layer above both, and the window title.
//
// It is the macOS half of what used to be `WorkspaceRootView`, one view that reached the iOS
// `NavigationSplitView` and this split shell through a `#if os(...)` down the middle of its body.
// There is not one platform gate left in this file, because the file is the platform (docs/56 §3) —
// the phone's root is `WorkspaceRootView` and the two share no view ancestor. What they DO share
// they share BELOW the view layer: ``WorkspaceChromePolicy`` (auto-hide, window title),
// ``OverlayCoordinator`` and the store itself.
//
// The shell inside it is still SwiftUI-hosted (`WorkspaceSplitRepresentable` over the AppKit
// `SlopDeskSplitViewController`, whose two items are `NSHostingController`s over the columns). Stage
// D drains those columns upward one surface at a time; this file is where they land.
//
// ⚠️ IT IS OFF THE DRAINING FLOOR (docs/56 §3.5, increment 56b), and `slopdesk-invariants` keeps it
// off. This file imported `SlopDeskClientUI` for exactly two things and no more: the sidebar toggle,
// which is ``MacWindowSidebarToggle`` in AppKit now and DELETED from the shared target in the same
// change (the phone never drew it — no window corner, no traffic lights, no split item), and the
// `\.preferencesStore` environment key, which is an init parameter threaded from ``SlopDeskMacApp``.
// The environment read was buying nothing the thread does not: the store's only consumer down here
// is the navigator's tab context menu, which lives in an `NSHostingController` column that never
// inherited the WindowGroup environment anyway — so it was already being forwarded EXPLICITLY into
// the split (see ``WorkspaceSplitRepresentable/preferences``), and the `@Environment` was one hop of
// implicit plumbing feeding one hop of explicit plumbing. A parameter says the same thing once.

import SlopDeskClientCore
import SlopDeskSlate // the ONE design ladder, in its native (NSColor/NSFont) spelling
import SlopDeskVideoProtocol // ConfigRevision — what makes the config-backed reads below live
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct MacWorkspaceRootView: View {
    let store: WorkspaceStore
    let connection: AppConnection
    /// The single ``OverlayCoordinator`` (command palette / cheat sheet / toasts / connect / remote-window
    /// picker), built once by ``ClientComposition`` and injected here. The window root binds its chrome
    /// toggles + cwd resolver (see ``wireChromeToggles()``).
    let overlay: OverlayCoordinator
    /// The two split-collapse flags + the window-pin flag the chrome toggles drive (read by the
    /// representable). OWNED BY THE COMPOSITION, NOT view-local `@State` — so the scene's
    /// `.introspect(.window)` closure reads the SAME `chrome.pinned` the titlebar / menu / palette flip
    /// (ONE `NSWindow.level` source of truth, no `NSApplication.windows`).
    let chrome: WorkspaceChromeState
    /// The single live preferences store, built once by ``ClientComposition`` and handed down from
    /// ``SlopDeskMacApp``, then forwarded into the split host so the sidebar tab context menu can surface
    /// the host-LOCAL "Prevent Sleep While Processing" flag. `nil` (a preview / a test root) hides the row.
    ///
    /// ⚠️ A PARAMETER, NOT `@Environment(\.preferencesStore)` (increment 56b). The key it used to read is
    /// the phone's — it is declared in the draining target, and reading it here was one of the two things
    /// keeping this file's `import SlopDeskClientUI` alive. It also bought nothing: the only consumer below
    /// is inside an `NSHostingController` column, which inherits no WindowGroup environment, so the value
    /// was ALREADY being threaded explicitly into the split. One hop, spelled once.
    let preferences: PreferencesStore?
    /// The live `auto-hide-tabs-panel` mode. COMPUTED, and it reads ``ConfigRevision/generation``
    /// first: `AppConfig` is a plain locked global, so the bare ``SettingsKey/autoHideTabsPanel``
    /// accessor registers no dependency and the body would never re-evaluate. Reading the revision
    /// here is what re-fires the `.onChange(of: autoHideTabsPanel)` observer below when the user saves
    /// their config file. Drives the vertical TABS panel auto-hide with the active session's tab count.
    private var autoHideTabsPanel: AutoHideTabsPanelMode {
        _ = ConfigRevision.shared.generation
        return SettingsKey.autoHideTabsPanel
    }

    /// Installs the sidebar / Tabs-panel toggle on the app-level keybinding dispatcher. The dispatcher is
    /// built at app `init` (before `chrome` exists), so on appear the root view hands it `chrome.toggleSidebar`
    /// — ⌘⇧L flips the LIVE `chrome.sidebarCollapsed` the native split reads, not the legacy
    /// `store.sidebarCollapsed` (which nothing reads on macOS). `nil` (previews / tests) is a no-op. A
    /// plain closure keeps ``WorkspaceKeyDispatcher`` out of this view's signature.
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
    /// Pin Window's primary entry is then the menu Button + palette.
    private let installPinToggle: ((@escaping () -> Void) -> Void)?

    /// The cross-container pane-drag rendezvous — composition-owned (like `chrome`) and threaded into the
    /// split host, which re-injects it into both hosted columns. `nil` (previews) keeps the pane drag
    /// canvas-only.
    private let paneDrag: PaneDragCoordinator?

    init(
        store: WorkspaceStore,
        connection: AppConnection,
        overlay: OverlayCoordinator,
        chrome: WorkspaceChromeState,
        // Defaulted, like every parameter below it: a preview or a test root that never opens a tab
        // context menu has no preferences to hand over, and the row it would surface hides itself.
        preferences: PreferencesStore? = nil,
        installSidebarToggle: ((@escaping () -> Void) -> Void)? = nil,
        installCodeSidebarToggle: ((@escaping () -> Void) -> Void)? = nil,
        installFocusCodePanel: ((@escaping () -> Void) -> Void)? = nil,
        installPinToggle: ((@escaping () -> Void) -> Void)? = nil,
        paneDrag: PaneDragCoordinator? = nil,
    ) {
        self.store = store
        self.connection = connection
        self.overlay = overlay
        self.chrome = chrome
        self.preferences = preferences
        self.installSidebarToggle = installSidebarToggle
        self.installCodeSidebarToggle = installCodeSidebarToggle
        self.installFocusCodePanel = installFocusCodePanel
        self.installPinToggle = installPinToggle
        self.paneDrag = paneDrag
    }

    /// The active session's tab count — the auto-hide policy's input. `nil` (no active session yet) reads as
    /// `0`, which collapses under `.auto` (nothing to switch between). The `.onChange(of: activeTabCount)`
    /// observer fires the policy on a tab open/close TRANSITION, not every render — so a manual ⌘⇧L is never
    /// fought.
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

    var body: some View {
        // No system toolbar — the window runs `.hiddenTitleBar`; its own titlebar band
        // (`MacTitlebarBand`, inside `MacContentColumn`) IS the chrome.
        WorkspaceSplitRepresentable(
            store: store, connection: connection, chrome: chrome, overlay: overlay,
            preferences: preferences, paneDrag: paneDrag,
        )
        // THE SIDEBAR TOGGLE, mounted at WINDOW level rather than in either column (user-directed
        // 2026-08-09). Both columns travel when the panel collapses — the split animates the item
        // width — so a button hosted inside one of them rides that slide and crawls under the traffic
        // lights on its way. Here it cannot move at all: it is pinned to the window's own top-left
        // corner, and the click's acknowledgement is the plate's own fill rung (see
        // ``MacWindowSidebarToggle``, which is AppKit — the SwiftUI original and the symbol bounce
        // it carried went with it). Mounted BELOW the overlay layer so a modal card covers it like
        // everything else.
        //
        // ⚠️ INSIDE the `.ignoresSafeArea()` below, not after it. The window is `.hiddenTitleBar` but
        // SwiftUI still hands its content a top safe-area inset the height of the titlebar, and the
        // split only escapes it by ignoring it. An overlay attached OUTSIDE that modifier is laid out
        // in the inset content instead, which parks this button one whole band low — on top of the
        // navigator's search field (measured 2026-08-09).
        .overlay(alignment: .topLeading) { MacWindowSidebarToggle(chrome: chrome) }
        // The band's AGGREGATE AGENT READING, mounted beside the toggle for the SAME reason and with
        // the opposite consequence: the toggle is here so it can never move, this is here so it can
        // move BETWEEN the two places it belongs — flush with the navigator's gutter while the
        // column is up, back against the toggle once the column is gone (``RailStatusRollupMount``).
        // Inside `.ignoresSafeArea()` for the reason above, and below the overlay layer so a modal
        // card covers it like everything else.
        .overlay(alignment: .topLeading) {
            RailStatusRollupMount(store: store, chrome: chrome)
        }
        .ignoresSafeArea()
        // THE GROUND behind the split (law 1) — one opaque tone under all three columns, which
        // backstops any transient gap (a mid-animation collapse) so no bare window colour ever
        // shows. It is also what the window's own 16pt corners bite into.
        .background(Slate.Surface.field.ignoresSafeArea())
        // ⚠️ NOTHING FLOATS OVER THE SPLIT FROM HERE ANY MORE (docs/56 stage D). Every summoned card
        // is an `NSPanel` of the Mac's own (``MacOverlayPanels``), and the last two surfaces — the
        // Connect-to-Host FORM and the close-confirmation ALERT, which were never cards — are the
        // platform's own sheets now (``MacConnectSheet``, ``MacCloseConfirmation``), presented from
        // the scene against the workspace window. That is what the whole ordering argument in docs/56
        // was for: an `NSHostingView` claims every hit inside its own bounds, so any always-mounted
        // SwiftUI layer over the split makes the window click-dead everywhere its ink is not. There
        // is no such layer left, and `connection` is threaded to this root only for the split beneath.
        //
        // Wire ⌘⇧L (Toggle Tabs Panel) to the live chrome once it exists. The dispatcher is built at app
        // `init` (before `chrome`), so we hand it the toggles here — `[chrome]` captures the same
        // @Observable the representable + titlebar read, so the NSEvent chord and titlebar button drive ONE flag.
        .onAppear { wireChromeToggles() }
        // Drive the vertical TABS panel auto-hide. On a tab-count TRANSITION or a Settings mode flip, apply
        // `SidebarAutoHidePolicy` to the live `chrome.sidebarCollapsed` — but only when the policy has an
        // opinion (`.auto`) AND the 1↔>1 tab-count regime crossed, so a manual ⌘⇧L is never fought by an
        // unrelated tab open/close (``WorkspaceChromePolicy/applyAutoHide(mode:tabCount:chrome:)`` gates on
        // the regime edge + a manual-override bit). `.default`/`.always` leave it alone. `initial: true` runs
        // the policy ONCE on first render too (SwiftUI `.onChange` skips first appearance) — else a persisted
        // `.auto` single-tab session would launch with the sidebar REVEALED until the user added/removed a
        // tab. `sidebarCollapsed` is not persisted, so applying at launch is safe (the first application
        // reads as a regime edge and actuates).
        .onChange(of: activeTabCount, initial: true) { applyAutoHidePolicy() }
        .onChange(of: autoHideTabsPanel) { applyAutoHidePolicy() }
        // THE KEYBOARD FOLLOWS THE WORKSPACE, and each tab keeps its own answer to "terminal or code
        // panel?". One observer for both, because a tab switch changes the focused pane too and the
        // two questions must not race each other from separate `.onChange`s.
        .onChange(of: focusLanding) { previous, current in honourFocusRegion(from: previous, to: current) }
        // The macOS WINDOW title tracks the FOCUSED pane (user: the window stayed a static "Terminal"). With
        // `.hiddenTitleBar` this text is not drawn in a titlebar, but it IS the window's name in the Window
        // menu, Mission Control / Exposé, screenshot filenames and accessibility. `.navigationTitle` is the
        // SwiftUI-native way to set `NSWindow.title` from WindowGroup content (no `NSApplication.windows`
        // reach). `windowTitle(for:)` reads the active pane + its spec, so the `@Observable` store re-titles
        // the window on a pane switch, a live OSC-0/2 title, or a `cd` (the cwd folder name).
        .navigationTitle(WorkspaceChromePolicy.windowTitle(for: store))
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

    /// Hand the app-level dispatcher the chrome toggles (sidebar ⌘⇧L), bound to THIS view's live state.
    /// Called on appear (the dispatcher predates `chrome`, so the closures install late). `[chrome]` captures
    /// the same `@Observable` the representable + titlebar read, so each NSEvent chord and the matching
    /// titlebar button flip ONE flag.
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
        // to the SAME live `chrome.pinned` the menu Button + the macOS `NSWindow.level` glue read.
        overlay.togglePinWindow = { [chrome] in chrome.togglePin() }
        installPinToggle? { [chrome] in chrome.togglePin() }
        // The terminal's AppKit tracking area fires under a modal card (rect-based — no occlusion),
        // so the production renderer reads this shield before forwarding pointer positions to a
        // mouse-reporting TUI. Bound to the SAME modal flag the hosted columns gate their SwiftUI
        // hit-testing on, so the whole workspace goes pointer-deaf under a card at once.
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

    /// Thin view-side glue over ``WorkspaceChromePolicy/applyAutoHide(mode:tabCount:chrome:)`` — read the
    /// live inputs (the `@Default` mode + the active session's tab count) and actuate. Called from the
    /// `.onChange` observers so the tested unit stays the policy.
    private func applyAutoHidePolicy() {
        WorkspaceChromePolicy.applyAutoHide(
            mode: autoHideTabsPanel, tabCount: activeTabCount, chrome: chrome,
        )
    }
}

/// Bridges the AppKit `SlopDeskSplitViewController` into SwiftUI. The controller (and the two SwiftUI
/// columns it hosts) owns the long-lived shell; SwiftUI just mounts it. Keeping the shell in AppKit (not a
/// SwiftUI `HSplitView`) is the load-bearing no-teardown choice for the libghostty panes. `updateNSView…`
/// pushes the chrome collapse flag into the split item each update.
struct WorkspaceSplitRepresentable: NSViewControllerRepresentable {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState
    /// The overlay reducer — threaded so the controller can wire the sidebar's status affordance to
    /// `openConnect()`. Captured once in `makeNSViewController`.
    let overlay: OverlayCoordinator
    /// The live ``PreferencesStore`` — forwarded into the controller so the sidebar's `NavigatorColumn`
    /// tab context menu can surface the host-LOCAL "Prevent Sleep While Processing" flag. The
    /// NSHostingController columns do not inherit the WindowGroup environment, which is why this was an
    /// explicit thread even while the root read the value out of one, and why the root now takes it as a
    /// parameter instead (increment 56b). `nil` (a preview / a test root) hides the row.
    let preferences: PreferencesStore?
    /// The pane-drag rendezvous — forwarded into the controller like `preferences` (same
    /// no-environment-inheritance reason).
    let paneDrag: PaneDragCoordinator?

    func makeNSViewController(context _: Context) -> SlopDeskSplitViewController {
        SlopDeskSplitViewController(
            store: store, connection: connection, chrome: chrome, preferences: preferences,
            onConnect: { [overlay] in overlay.openConnect() },
            overlay: overlay,
            paneDrag: paneDrag,
        )
    }

    func updateNSViewController(_ controller: SlopDeskSplitViewController, context _: Context) {
        // Reading the @Observable flags here ties this update to their changes; apply to the items.
        controller.applyCollapse(
            sidebarCollapsed: chrome.sidebarCollapsed,
            codeSidebarCollapsed: chrome.codeSidebarCollapsed,
        )
    }
}
