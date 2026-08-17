// WorkspaceRootView — the native 2-column IDE shell.
//
// macOS: an `NSViewControllerRepresentable` (`WorkspaceSplitRepresentable`) owning an
// `SlopDeskSplitViewController` (sidebar | content `NSSplitViewController` items, each an
// `NSHostingController` over a SwiftUI column; modelled on CodeEdit's split shell). The window runs
// `.hiddenTitleBar` — NO system toolbar; the workspace's own hover-reveal titlebar (`SlateTitlebar`, a
// top overlay in `ContentColumn`) IS the chrome (sidebar toggle, "New Tab", centred title menu). iOS: a
// stock `NavigationSplitView` over the same two columns + its own toolbar. (Right-hand inspector /
// Details column REMOVED — keyboard-centric.)
//
// NO custom design-system / token target: SYSTEM semantic colours + fonts + SF Symbols.

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskAgentDetect
import SlopDeskClientCore
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

public struct WorkspaceRootView: View {
    let store: WorkspaceStore
    let connection: AppConnection
    /// The single ``OverlayCoordinator`` (command palette / cheat sheet / toasts / connect / remote-window
    /// picker), built once at app `init` and injected into the scene env. Threaded so the iOS connection
    /// pill (and any macOS status surface) can open Connect-to-Host via ``OverlayCoordinator/openConnect()``.
    let overlay: OverlayCoordinator
    /// The two split-collapse flags + the window-pin flag the toolbar toggles drive (read by the
    /// representable). OWNED BY THE APP (`SlopDeskClientApp` `@State`), NOT view-local `@State` — so the
    /// macOS scene's `.introspect(.window)` closure reads the SAME `chrome.pinned` the titlebar / menu /
    /// palette flip (ONE `NSWindow.level` source of truth, no `NSApplication.windows`).
    let chrome: WorkspaceChromeState
    /// The single live preferences store, injected once at the WindowGroup root (`\.preferencesStore`). Used
    /// by the iOS ``SettingsSheet`` (the gear) AND the macOS split host's sidebar tab context menu ("Prevent
    /// Sleep While Processing" flag). `nil` (no scene injection / a preview) → the gear presents nothing and
    /// the Prevent-Sleep row is hidden.
    @Environment(\.preferencesStore) private var preferencesStore
    /// The live `auto-hide-tabs-panel` mode. Read via `@Default` (NOT the plain
    /// ``SettingsKey/autoHideTabsPanel`` accessor) so SwiftUI re-evaluates the body — re-firing the
    /// `.onChange(of: autoHideTabsPanel)` observer below — when the user flips the Settings picker. Drives
    /// the vertical TABS panel auto-hide together with the active session's tab count (see ``applyAutoHide``).
    @Default(.autoHideTabsPanel) private var autoHideTabsPanel
    #if os(iOS)
    /// Whether the iOS settings sheet is presented — flipped by the toolbar gear, read by the `.sheet`.
    @State private var showSettings = false

    /// (iOS) Maps the shared `chrome.sidebarCollapsed` flag (driven by the auto-hide policy, read by macOS's
    /// split) onto the `NavigationSplitView`'s `columnVisibility`, so the TABS panel hides/reveals on iPad.
    /// Getter derives visibility via `Self.sidebarVisibility`; setter routes a user swipe through
    /// `Self.applySidebarVisibility`, which writes the flag back AND records `manualSidebarOverride` on a
    /// genuine collapse/reveal — so the auto-hide policy honors an iPad swipe like ⌘⇧L. The SECOND manual
    /// entry point besides `toggleSidebar()`.
    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { Self.sidebarVisibility(sidebarCollapsed: chrome.sidebarCollapsed) },
            set: { Self.applySidebarVisibility($0, chrome: chrome) },
        )
    }

    /// The app-owned Agents install-hooks controller, injected once at the WindowGroup root
    /// (`\.agentHooksController`) and handed to the iOS ``SettingsSheet`` so the Agents card + Agent-Behaviour
    /// toggles are LIVE on iOS (macOS's `Settings` scene injects it on its own side). `nil` (no scene
    /// injection / a preview) → the card renders the disabled "Connect a session" state.
    @Environment(\.agentHooksController) private var agentHooksController
    #endif
    /// Installs the sidebar / Tabs-panel toggle on the app-level keybinding dispatcher. The dispatcher is
    /// built at app `init` (before `chrome` exists), so on appear the root view hands it `chrome.toggleSidebar`
    /// — ⌘⇧L flips the LIVE `chrome.sidebarCollapsed` the native split reads, not the legacy
    /// `store.sidebarCollapsed` (which nothing reads on macOS). `nil` (default / iOS / tests) is a no-op. A
    /// plain closure keeps `WorkspaceKeyDispatcher` internal (no public-API widening).
    private let installSidebarToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the RIGHT code panel's toggle on the app-level keybinding dispatcher (same late-wiring
    /// as `installSidebarToggle`): hands it `chrome.toggleCodeSidebar` so ⌘⇧R flips the LIVE
    /// `chrome.codeSidebarCollapsed` the native split reads. `nil` (default / iOS / tests) is a no-op.
    private let installCodeSidebarToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the code panel's keyboard hand-off on the dispatcher (same late-wiring): ⌥⌘R moves
    /// the keyboard into the embedded editor and back. `nil` (default / iOS / tests) is a no-op.
    private let installFocusCodePanel: ((@escaping () -> Void) -> Void)?
    /// Installs the "Pin Window" toggle on the app-level keybinding dispatcher (same late-wiring as
    /// `installSidebarToggle`): hands it `chrome.togglePin` so a user-bound chord for the chord-less
    /// `.pinWindow` action routes through the SAME NSEvent monitor. `nil` (default / iOS / tests) is a no-op —
    /// Pin Window's primary entry is then the menu Button + palette.
    private let installPinToggle: ((@escaping () -> Void) -> Void)?

    /// The cross-container pane-drag rendezvous — app-owned (like `chrome`) and threaded into the macOS
    /// split host, which re-injects it into both hosted columns. `nil` (previews / iOS) keeps the pane
    /// drag canvas-only.
    private let paneDrag: PaneDragCoordinator?

    // INTERNAL init (not `public`): constructed only inside this module (`SlopDeskClientApp`), and `chrome`
    // is the internal `WorkspaceChromeState`. Keeps the chrome model internal (no public-API widening).
    package init(
        store: WorkspaceStore,
        connection: AppConnection,
        overlay: OverlayCoordinator,
        chrome: WorkspaceChromeState,
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
        self.installSidebarToggle = installSidebarToggle
        self.installCodeSidebarToggle = installCodeSidebarToggle
        self.installFocusCodePanel = installFocusCodePanel
        self.installPinToggle = installPinToggle
        self.paneDrag = paneDrag
    }

    /// The active tab's active pane's live session, if materialized — the source of the active pane's ping
    /// + agent status surfaced in the toolbar.
    private var activeLive: LivePaneSession? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The active pane's agent status (`.none` when no agent / no live pane).
    private var activeAgentStatus: ClaudeStatus { activeLive?.claudeStatus ?? .none }

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

    public var body: some View {
        #if os(macOS)
        // No system toolbar — the window runs `.hiddenTitleBar`; its own hover-reveal titlebar
        // (`SlateTitlebar`, inside `ContentColumn`) IS the chrome.
        WorkspaceSplitRepresentable(
            store: store, connection: connection, chrome: chrome, overlay: overlay,
            preferences: preferencesStore, paneDrag: paneDrag,
        )
        // THE SIDEBAR TOGGLE, mounted at WINDOW level rather than in either column (user-directed
        // 2026-08-09). Both columns travel when the panel collapses — the split animates the item
        // width — so a button hosted inside one of them rides that slide and crawls under the traffic
        // lights on its way. Here it cannot move at all: it is pinned to the window's own top-left
        // corner, and the click's acknowledgement is the plate + glyph morph (see
        // ``WindowSidebarToggle``). Mounted BELOW the overlay layer so a modal card covers it like
        // everything else.
        //
        // ⚠️ INSIDE the `.ignoresSafeArea()` below, not after it. The window is `.hiddenTitleBar` but
        // SwiftUI still hands its content a top safe-area inset the height of the titlebar, and the
        // split only escapes it by ignoring it. An overlay attached OUTSIDE that modifier is laid out
        // in the inset content instead, which parks this button one whole band low — on top of the
        // navigator's search field (measured 2026-08-09).
        .overlay(alignment: .topLeading) { WindowSidebarToggle(chrome: chrome) }
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
        // The floating-overlay layer (palette / cheat sheet / connect / remote-window picker / toasts)
        // composes above the AppKit split (SwiftUI overlays compose over an `NSViewControllerRepresentable`).
        // `toggledState` is built from the LIVE chrome so the palette's ✓ gutter tracks real visibility.
        .overlay {
            OverlayHostView(
                store: store,
                connection: connection,
                coordinator: overlay,
                toggledState: OverlayHostView.toggledState(for: chrome, store: store),
            )
        }
        // Wire ⌘⇧L (Toggle Tabs Panel) to the live chrome once it exists. The dispatcher is built at app
        // `init` (before `chrome`), so we hand it the toggles here — `[chrome]` captures the same
        // @Observable the representable + titlebar read, so the NSEvent chord and titlebar button drive ONE flag.
        .onAppear { wireChromeToggles() }
        // Drive the vertical TABS panel auto-hide. On a tab-count TRANSITION or a Settings mode flip, apply
        // `SidebarAutoHidePolicy` to the live `chrome.sidebarCollapsed` — but only when the policy has an
        // opinion (`.auto`) AND the 1↔>1 tab-count regime crossed, so a manual ⌘⇧L is never fought by an
        // unrelated tab open/close (`applyAutoHide` gates on the regime edge + a manual-override bit).
        // `.default`/`.always` leave it alone. `initial: true` runs the policy ONCE on first render too
        // (SwiftUI `.onChange` skips first appearance) — else a persisted `.auto` single-tab session would
        // launch with the sidebar REVEALED until the user added/removed a tab. `sidebarCollapsed` is not
        // persisted, so applying at launch is safe (the first application reads as a regime edge and actuates).
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
        .navigationTitle(Self.windowTitle(for: store))
        #else
        NavigationSplitView(
            columnVisibility: sidebarColumnVisibility,
        ) {
            NavigatorColumn(
                store: store, preferences: preferencesStore,
            )
        } detail: {
            ContentColumn(store: store, connection: connection, chrome: chrome)
        }
        // The columns read the reducer from the environment (the island's chip stack does, and macOS's
        // split host injects it per hosting controller for the same reason) — iOS shares one tree, so
        // one injection at the root covers both columns.
        .overlayCoordinator(overlay)
        .toolbar { iosToolbar }
        // The floating-overlay layer mounts on iOS too (palette / connect / remote-window picker / toasts —
        // a ZStack overlay on both platforms). The ✓ gutter tracks the live chrome + the active pane's
        // read-only / secure-entry state — the SAME predicate the macOS host uses.
        .overlay {
            OverlayHostView(
                store: store,
                connection: connection,
                coordinator: overlay,
                toggledState: OverlayHostView.toggledState(for: chrome, store: store),
            )
        }
        // Wire the palette's cwd resolver + the per-pane hardware-keyboard interceptor's overlay toggles
        // (iPad has no app-level NSEvent monitor, so a focused terminal's ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J would
        // otherwise die at a nil toggle).
        .onAppear {
            wireOverlayCwdResolver()
            wireOverlayKeyToggles()
        }
        // Drive the TABS panel auto-hide on iPad too — the SAME shared policy macOS runs. On a tab-count
        // TRANSITION or a Settings mode flip, apply `SidebarAutoHidePolicy` to `chrome.sidebarCollapsed`
        // (mapped to the split's `columnVisibility` via `sidebarColumnVisibility`), only when the policy has an
        // opinion (`.auto`) and the 1↔>1 regime crossed — so a manual reveal/hide is never fought by an
        // unrelated tab open/close. `initial: true` applies ONCE at launch too (SwiftUI `.onChange` skips first
        // appearance), so a single-tab `.auto` session opens with the TABS panel already hidden.
        .onChange(of: activeTabCount, initial: true) { applyAutoHidePolicy() }
        .onChange(of: autoHideTabsPanel) { applyAutoHidePolicy() }
        // The toolbar gear presents the in-app settings sheet (iOS has no `Settings` scene). The sheet hosts
        // the same cross-platform section structs as the macOS strip.
        .sheet(isPresented: $showSettings) {
            if let preferencesStore {
                // Thread the app-owned controller into the sheet so the Agents card / behaviour toggles are
                // live on iOS (a sheet does not inherit the presenter's custom environment values).
                SettingsSheet(store: preferencesStore, agentHooks: agentHooksController, workspace: store)
            }
        }
        #endif
    }

    #if os(macOS)
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
        TerminalPointerShield.isActive = { [overlay] in overlay.anyModalVisible }
        wireOverlayCwdResolver()
    }
    #endif

    /// Bind the overlay coordinator's `resolveActiveCwd` to the focused pane's live ``MetadataClient`` so
    /// opening the command palette EAGERLY resolves its working directory (host `cwd()` RPC) and mirrors it
    /// into `pane/cwd` — which the WORKING DIRECTORY header's cwd pill (and the titlebar / rail)
    /// read reactively. Without this the pill stayed blank on a freshly-connected pane at a prompt: the only
    /// other `pane/cwd` writer (a command completing via OSC 133;D) had not fired. Reuses the EXACT
    /// live-metadata path Open-Quickly uses (`store.handle(for:) as? LivePaneSession → activeMetadataClient`),
    /// so it spends NO new wire message. `[store]` captures the live store; a disconnected pane / nil client /
    /// empty cwd is a silent no-op (validate-then-drop). Cross-platform (macOS via `wireChromeToggles()`, iOS
    /// via the `.onAppear`).
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

    /// Hand the live store the overlay-toggle closures the per-pane hardware-keyboard ``TerminalKeyInterceptor``
    /// threads into `route` (``WorkspaceStore/overlayKeyToggles``), each pointed at the injected
    /// ``OverlayCoordinator``. iPad has no app-level NSEvent monitor, so without these a focused terminal's
    /// ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J resolved to a `nil` toggle and did nothing. On macOS the dispatcher owns
    /// these chords before the surface, so this is harmless there but keeps the seam single-sourced.
    private func wireOverlayKeyToggles() {
        store.overlayKeyToggles = WorkspaceOverlayKeyToggles(
            palette: { [overlay] in overlay.togglePalette() },
            cheatSheet: { [overlay] in overlay.toggleCheatSheet() },
            globalSearch: { [overlay] in overlay.toggleGlobalSearch() },
            jumpTo: { [overlay] in overlay.toggleOpenQuickly(filter: .current) },
            openQuickly: { [overlay] in overlay.toggleOpenQuickly(filter: .all) },
            peekReply: { [overlay] in overlay.togglePeekReply() },
        )
    }

    /// Pure map from the shared `sidebarCollapsed` flag to the iOS `NavigationSplitView` column visibility:
    /// collapsed → `.detailOnly` (TWO-column shell now the inspector is removed, so "everything but the
    /// sidebar" is the detail alone), revealed → `.all`. Kept cross-platform (`NavigationSplitViewVisibility`
    /// exists on macOS) so the mapping is unit-tested in the macOS `swift test` gate, not only at iOS compile
    /// time.
    static func sidebarVisibility(sidebarCollapsed: Bool) -> NavigationSplitViewVisibility {
        sidebarCollapsed ? .detailOnly : .all
    }

    /// The iOS ``sidebarColumnVisibility`` SETTER side: a user swipe of the leading TABS column — the SECOND
    /// manual entry point besides ``WorkspaceChromeState/toggleSidebar`` — writes the shared
    /// `chrome.sidebarCollapsed` flag AND, when it GENUINELY flips it (a real collapse/reveal, not a SwiftUI
    /// echo of the value the auto-hide policy just set), records `manualSidebarOverride` so
    /// ``applyAutoHide(mode:tabCount:chrome:)`` honors the iPad swipe like ⌘⇧L. Without this an iPad user who
    /// swipes the panel away at >1 tabs would have it forcibly REVEALED on the next within-regime tab
    /// open/close (policy sees no override → re-asserts `desired=false`). The `!= chrome.sidebarCollapsed`
    /// guard distinguishes a genuine swipe from the binding echo SwiftUI fires when the getter-derived value is
    /// written back unchanged, so a policy-driven change is never mis-recorded as manual. Static +
    /// cross-platform so the contract is unit-tested without a live split / NSWindow (see
    /// `SidebarAutoHideWiringTests`).
    static func applySidebarVisibility(_ visibility: NavigationSplitViewVisibility, chrome: WorkspaceChromeState) {
        // TWO-column shell: `.detailOnly` is the only "sidebar hidden" visibility (`.doubleColumn` shows
        // both columns of a two-column split, so it must read as REVEALED — unlike the old 3-column map).
        let collapsed = (visibility == .detailOnly)
        guard collapsed != chrome.sidebarCollapsed else { return }
        chrome.manualSidebarOverride = true
        chrome.sidebarCollapsed = collapsed
    }

    /// The single place the `auto-hide-tabs-panel` policy ACTUATES. Apply the pure
    /// ``SidebarAutoHidePolicy/desiredCollapsed(mode:tabCount:)`` decision to the live
    /// `chrome.sidebarCollapsed`, but ONLY when the policy has an opinion (mode `.auto`); a `nil` opinion
    /// (`.default`/`.always`) is left untouched.
    ///
    /// The `.auto` decision flips ONLY across the 1↔>1 tab-count regime (`desired == tabCount <= 1`), so
    /// actuation is gated on a regime EDGE — the first application (`lastAutoHideCollapsed == nil`) or a
    /// `desired` differing from the last value the policy drove. ON that edge the default-state opinion
    /// ("hidden when only one tab") re-asserts: clear any manual override and actuate. WITHIN a regime (an
    /// UNRELATED tab open/close — e.g. 2→3 tabs — that does not flip `desired`) a manual ⌘⇧L is honored and
    /// NEVER fought. The `!= desired` write guard avoids a redundant `@Observable` invalidation. Static +
    /// cross-platform so the contract is unit-tested without a live view (see `SidebarAutoHideWiringTests`).
    static func applyAutoHide(mode: AutoHideTabsPanelMode, tabCount: Int, chrome: WorkspaceChromeState) {
        guard let desired = SidebarAutoHidePolicy.desiredCollapsed(mode: mode, tabCount: tabCount) else { return }
        let isRegimeEdge = chrome.lastAutoHideCollapsed != desired
        chrome.lastAutoHideCollapsed = desired
        if isRegimeEdge {
            // 1↔>1 transition (or first apply): the auto default-state opinion wins, manual override cleared.
            chrome.manualSidebarOverride = false
        } else if chrome.manualSidebarOverride {
            // Same regime + a live manual override: leave the user's ⌘⇧L choice in place.
            return
        }
        if chrome.sidebarCollapsed != desired {
            chrome.sidebarCollapsed = desired
        }
    }

    /// Thin view-side glue over the static, unit-tested ``applyAutoHide(mode:tabCount:chrome:)`` — read the
    /// live inputs (the `@Default` mode + the active session's tab count) and actuate. Called from the
    /// `.onChange` observers on both shells so the tested unit stays the policy.
    private func applyAutoHidePolicy() {
        Self.applyAutoHide(mode: autoHideTabsPanel, tabCount: activeTabCount, chrome: chrome)
    }

    /// The macOS WINDOW title: the active pane's display label — the SAME ``RailRowsBuilder/rowTitle`` the
    /// sidebar row + hover-reveal titlebar show — so the window's name (Window menu / Mission Control /
    /// screenshot files / accessibility) tracks the FOCUSED pane instead of a static app name. Reading the
    /// active pane + its spec here registers the `@Observable` store's dependencies, so a pane switch, a live
    /// OSC-0/2 title, or a `cd` (which changes the cwd folder name) re-titles the window. Falls back to the
    /// product name for an empty workspace (no active pane / session). Static + pure so the mapping is
    /// unit-pinned without a live `NSWindow` (see `WindowTitleTests`).
    @MainActor
    static func windowTitle(for store: WorkspaceStore) -> String {
        guard let session = store.tree.activeSession,
              let paneID = session.activeTab?.activePane
        else { return productName }
        let spec = session.specs[paneID]
        let kind = spec?.kind ?? .terminal
        // The `paneForegroundProcess` read is GUARDED by the SAME `RailStructureKey.titledByProcess`
        // escape-order check the sidebar's structural fingerprint uses: an unconditional read would make
        // `.navigationTitle` — hence the WHOLE root view body — a dependent of the WHOLE process dict, so a
        // background pane's 1Hz process tick would re-evaluate the root view even though only a cwd-less,
        // non-renamed terminal pane's title ever depends on that dict.
        let cwd = store.paneCwd(for: paneID)
        let titledByProcess = RailStructureKey.titledByProcess(kind: kind, spec: spec, cwd: cwd)
        let title = RailRowsBuilder.rowTitle(
            kind: kind, spec: spec, cwd: cwd, liveTitle: store.liveProgramTitle(for: paneID),
            processLabel: titledByProcess ? store.paneForegroundProcess[paneID] : nil,
        )
        // The titlebar is SYSTEM-drawn — no custom-font splice can reach it, so a nerd-font glyph
        // is STRIPPED rather than shown as a notdef box (the one surface that degrades by removal).
        let stripped = NerdSymbolFont.strippingSymbols(title)
        return stripped.isEmpty ? productName : stripped
    }

    /// The window-title fallback (empty workspace / no active pane) — the product name.
    static let productName = "SlopDesk"

    #if os(iOS)
    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        // iOS uses NavigationSplitView's own column-visibility chrome; surface the connection cluster (the
        // SAME `ConnectionCluster` as the macOS sidebar/titlebar — one connection surface per app; the old
        // iOS-only `ConnectionStatusPill` had drifted into its own voice) + the agent indicator + a New-Tab
        // affordance.
        ToolbarItem(placement: .principal) {
            ConnectionCluster(
                connection: connection,
                pingMS: ConnectionTelemetry.pingMS(store),
                fps: ConnectionTelemetry.fps(store),
                kbps: ConnectionTelemetry.kbps(store),
                onConnect: openConnect,
            )
        }
        ToolbarItem(placement: .primaryAction) {
            if let reading = StatusPresentation.agentReading(activeAgentStatus) {
                StatusGlyph(reading: reading, tint: StatusPresentation.agentTint(activeAgentStatus))
                    .accessibilityLabel("Agent \(StatusPresentation.agentLabel(activeAgentStatus))")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // The command palette (⌘⇧P) — iOS has no app-level NSEvent monitor (macOS's
            // `WorkspaceKeyDispatcher` owns that chord), so without this button the palette had NO entry point
            // on iPad. The hardware-keyboard chord is also routed (see `wireOverlayKeyToggles()`); this is the
            // touch affordance.
            Button { overlay.togglePalette() } label: { Image(systemSymbol: .command) }
                .help("Command Palette")
        }
        ToolbarItem(placement: .primaryAction) {
            // The `+` mints a focused terminal pane directly (the kind chooser is retired).
            Button { store.newTerminalPane(.newTab) } label: { Image(systemSymbol: .plus) }
                .help("New Tab")
        }
        ToolbarItem(placement: .primaryAction) {
            // The settings gear — iOS has no `Settings` scene (⌘, is macOS-only), so settings present as an
            // in-app sheet. Disabled until the preferences store is injected (so the gear never opens an empty
            // sheet in a preview / pre-scene state).
            Button { showSettings = true } label: { Image(systemSymbol: .gearshape) }
                .help("Settings")
                .disabled(preferencesStore == nil)
        }
    }
    #endif

    /// Opens the Connect-to-Host flow via the injected coordinator (sets `overlay.connectVisible`). A give-up
    /// state still runs Retry inside the pill itself.
    private func openConnect() {
        overlay.openConnect()
    }
}

#if os(macOS)
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
    /// The live ``PreferencesStore`` (`\.preferencesStore`) — forwarded into the controller so the sidebar's
    /// ``NavigatorColumn`` tab context menu can surface the host-LOCAL "Prevent Sleep While Processing" flag.
    /// The NSHostingController columns do not inherit the WindowGroup environment, hence the explicit thread.
    /// `nil` (no scene injection / a preview) hides the row.
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
#endif
#endif
