// WorkspaceRootView — the native 2-column IDE shell (REBUILD-V2, L1 + L4a toolbar).
//
// macOS: an `NSViewControllerRepresentable` (`WorkspaceSplitRepresentable`) owning an
// `AislopdeskSplitViewController` (an `NSSplitViewController` with sidebar | content items,
// each an `NSHostingController` over a SwiftUI column). Modelled on CodeEdit's split shell. The window runs
// `.windowStyle(.hiddenTitleBar)` — there is NO system unified toolbar; the workspace's own hover-reveal
// titlebar (`SlateTitlebar`, hosted as a top overlay inside `ContentColumn`) IS the chrome (sidebar toggle,
// "New Tab", the centred title menu). iOS: a stock `NavigationSplitView` over the same two columns + its
// own toolbar. (The right-hand inspector / Details column is REMOVED — keyboard-centric.)
//
// NO custom design-system / token target (deleted in L0): SYSTEM semantic colours + fonts + SF Symbols.

#if canImport(SwiftUI)
import AislopdeskAgentDetect
import AislopdeskWorkspaceCore
import Defaults
import SFSafeSymbols
import SwiftUI

public struct WorkspaceRootView: View {
    let store: WorkspaceStore
    let connection: AppConnection
    /// The single ``OverlayCoordinator`` (command palette / cheat sheet / toasts / connect / remote-window
    /// picker), built once at app `init` and injected into the scene env. WI-1 threads it so the iOS
    /// connection pill (and any macOS status surface) can open the Connect-to-Host overlay via
    /// ``OverlayCoordinator/openConnect()``; the `OverlayHostView` mount that renders the panels lands in WI-5.
    let overlay: OverlayCoordinator
    /// The two split-collapse flags + the window-pin flag the toolbar toggles drive (read by the
    /// representable). OWNED BY THE APP (`AislopdeskClientApp` `@State`) and passed in — NOT view-local
    /// `@State` — so the macOS scene's blessed `.introspect(.window)` closure reads the SAME `chrome.pinned`
    /// the titlebar / menu / palette flip (E19 WI-4: ONE `NSWindow.level` source of truth, no
    /// `NSApplication.windows`).
    let chrome: WorkspaceChromeState
    /// The single live preferences store, injected once at the WindowGroup root (`\.preferencesStore`). Used by
    /// the iOS ``SettingsSheet`` (the gear) AND threaded into the macOS split host so the sidebar's tab context
    /// menu can surface the "Prevent Sleep While Processing" flag (Batch 4). Cross-platform (was iOS-only). `nil`
    /// (no scene injection / a preview) → the gear presents nothing and the Prevent-Sleep row is hidden.
    @Environment(\.preferencesStore) private var preferencesStore
    /// E19/A18 (WI-7): the live `auto-hide-tabs-panel` mode. Read via `@Default` (NOT the plain
    /// ``SettingsKey/autoHideTabsPanel`` accessor) so SwiftUI re-evaluates the body — and thus re-fires the
    /// `.onChange(of: autoHideTabsPanel)` observer below — when the user flips the Settings picker. Drives the
    /// vertical TABS panel auto-hide together with the active session's tab count (see ``applyAutoHide``).
    @Default(.autoHideTabsPanel) private var autoHideTabsPanel
    #if os(iOS)
    /// Whether the iOS settings sheet (WI-5) is presented — flipped by the toolbar gear, read by the `.sheet`.
    @State private var showSettings = false

    /// E19/A18 (WI-7, iOS): map the shared `chrome.sidebarCollapsed` flag — the one the auto-hide policy drives
    /// (and macOS's split reads) — onto the `NavigationSplitView`'s `columnVisibility`, so the TABS panel
    /// actually hides/reveals on iPad rather than the flag being a dead toggle there. The getter derives the
    /// visibility from the flag (`Self.sidebarVisibility`); the setter routes a user swipe of the leading column
    /// through `Self.applySidebarVisibility`, which writes the flag back AND records `manualSidebarOverride` on a
    /// genuine collapse/reveal so the auto-hide policy honors an iPad swipe the same way it honors ⌘⇧L (WI-7) —
    /// the SECOND manual entry point besides `toggleSidebar()`. Mirrors ``detailsCompactColumnBinding``.
    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { Self.sidebarVisibility(sidebarCollapsed: chrome.sidebarCollapsed) },
            set: { Self.applySidebarVisibility($0, chrome: chrome) },
        )
    }

    /// E13 (ES-E13-1/ES-E13-2 iOS halves): the app-owned Agents install-hooks controller, injected once at the
    /// WindowGroup root (`\.agentHooksController`) and handed to the iOS ``SettingsSheet`` so the Agents card +
    /// the Agent-Behaviour toggles are LIVE on iOS (the macOS `Settings` scene injects it on its own side).
    /// `nil` (no scene injection / a preview) → the card renders the disabled "Connect a session" state.
    @Environment(\.agentHooksController) private var agentHooksController
    #endif
    /// Installs the sidebar / Tabs-panel toggle on the app-level keybinding dispatcher. The dispatcher is
    /// built at app `init` (before this view's `chrome` exists), so on appear the root view hands it
    /// `chrome.toggleSidebar` so ⌘⇧L (the
    /// Toggle Tabs Panel chord) flips the LIVE `chrome.sidebarCollapsed` the native split reads — not the legacy
    /// `store.sidebarCollapsed` (which nothing reads on macOS). `nil` (the default / iOS / tests) is a no-op. A
    /// plain closure keeps `WorkspaceKeyDispatcher` internal (no public-API widening).
    private let installSidebarToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the remote-windows-column toggle (⌘⇧E) on the app-level keybinding dispatcher — the
    /// TabSide partition twin of `installSidebarToggle`, wired to `chrome.toggleWindowsPanel()` on appear.
    /// `nil` (the default / iOS / tests) is a no-op.
    private let installWindowsToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the "Pin Window" toggle on the app-level keybinding dispatcher (same late-wiring story as
    /// `installSidebarToggle`): on appear the root view hands it `chrome.togglePin` so a user-bound chord for
    /// the chord-less `.pinWindow` action routes through the SAME NSEvent monitor. `nil` (the default / iOS /
    /// tests) is a no-op — Pin Window's primary entry is then the menu Button + palette (E19 WI-4).
    private let installPinToggle: ((@escaping () -> Void) -> Void)?

    // INTERNAL init (not `public`): `WorkspaceRootView` is constructed only inside this module
    // (`AislopdeskClientApp`), and `chrome` is the internal `WorkspaceChromeState`. Narrowing the init keeps
    // the chrome model internal (CLAUDE.md "no public-API widening") instead of publishing the type.
    init(
        store: WorkspaceStore,
        connection: AppConnection,
        overlay: OverlayCoordinator,
        chrome: WorkspaceChromeState,
        installSidebarToggle: ((@escaping () -> Void) -> Void)? = nil,
        installWindowsToggle: ((@escaping () -> Void) -> Void)? = nil,
        installPinToggle: ((@escaping () -> Void) -> Void)? = nil,
    ) {
        self.store = store
        self.connection = connection
        self.overlay = overlay
        self.chrome = chrome
        self.installSidebarToggle = installSidebarToggle
        self.installWindowsToggle = installWindowsToggle
        self.installPinToggle = installPinToggle
    }

    /// The active tab's active pane's live session, if materialized — the source of the active pane's ping
    /// + agent status surfaced in the toolbar (and the inspector's Session section).
    private var activeLive: LivePaneSession? {
        guard let id = store.tree.activeSession?.activeTab?.activePane else { return nil }
        return store.handle(for: id) as? LivePaneSession
    }

    /// The active pane's smoothed RTT (ms) — ping lives on the per-pane channel (`ConnectionViewModel`).
    private var activePingMS: Double? { activeLive?.connection?.latencyMS }

    /// The active pane's agent status (`.none` when no agent / no live pane).
    private var activeAgentStatus: ClaudeStatus { activeLive?.claudeStatus ?? .none }

    /// E19/A18 (WI-7): the active session's tab count — the auto-hide policy's input. `nil` (no active session
    /// materialized yet) reads as `0`, which collapses under `.auto` (there is nothing to switch between). The
    /// `.onChange(of: activeTabCount)` observer fires the policy on a tab open/close TRANSITION, never on every
    /// render — so a manual ⌘⇧L is never fought.
    private var activeTabCount: Int { store.tree.activeSession?.tabs.count ?? 0 }

    /// TabSide partition: the active session's GUI (remote-window) tab count — the right column's
    /// auto-reveal input (reveal on 0→>0, collapse on >0→0; a manual ⌘⇧E wins within a regime).
    private var guiTabCount: Int { store.tabCount(on: .gui) }

    public var body: some View {
        #if os(macOS)
        // No system unified toolbar / header — the window runs `.hiddenTitleBar` and its own hover-reveal
        // titlebar (`SlateTitlebar`, hosted inside `ContentColumn`) IS the chrome.
        WorkspaceSplitRepresentable(
            store: store, connection: connection, chrome: chrome, overlay: overlay,
            preferences: preferencesStore,
        )
        .ignoresSafeArea()
        // The floating-overlay layer (palette / cheat sheet / connect / remote-window picker / toasts)
        // floats above the AppKit split — SwiftUI overlays compose over an `NSViewControllerRepresentable`.
        // `toggledState` is built from the LIVE chrome so the palette's ✓ gutter tracks the real
        // sidebar/inspector visibility.
        .overlay {
            OverlayHostView(
                store: store,
                connection: connection,
                coordinator: overlay,
                toggledState: OverlayHostView.toggledState(for: chrome, store: store),
                sidebarCollapsed: chrome.sidebarCollapsed,
            )
        }
        // Wire ⌘⇧L (Toggle Tabs Panel / sidebar) to the live chrome once it
        // exists. The dispatcher is built at app `init` (before `chrome`), so we hand it the toggles here
        // — `[chrome]` captures the same @Observable instance the representable + titlebar read, so the
        // NSEvent chord and the titlebar button drive ONE flag.
        .onAppear { wireChromeToggles() }
        // E19/A18 (WI-7): drive the vertical TABS panel auto-hide. On a tab-count TRANSITION or a Settings
        // mode flip, apply `SidebarAutoHidePolicy` to the live `chrome.sidebarCollapsed` — but only when the
        // policy has an opinion (`.auto`) AND the 1↔>1 tab-count regime actually crossed, so a manual ⌘⇧L is
        // never fought by an unrelated tab open/close (`applyAutoHide` gates on the regime edge + a manual-
        // override bit). `.default`/`.always` leave it alone. `initial: true` runs the policy ONCE on first
        // render too — SwiftUI `.onChange` does not fire on first appearance, so without it a launch with a
        // persisted `.auto` mode + a single-tab session opened with the sidebar REVEALED (the exact case `.auto`
        // handles) until the user added/removed a tab. `sidebarCollapsed` is not persisted, so applying at launch
        // is safe (the first application reads as a regime edge and actuates).
        .onChange(of: activeTabCount, initial: true) { applyAutoHidePolicy() }
        .onChange(of: autoHideTabsPanel) { applyAutoHidePolicy() }
        // TabSide partition: auto-reveal the right remote-windows column when a GUI tab appears and
        // re-collapse when the last one closes (0↔>0 edges re-assert + clear a manual ⌘⇧E override;
        // within a regime the manual choice is honored — the sidebar auto-hide discipline, mirrored).
        .onChange(of: guiTabCount, initial: true) {
            Self.applyGuiAutoReveal(guiTabCount: guiTabCount, chrome: chrome)
        }
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
        .toolbar { iosToolbar }
        // The floating-overlay layer mounts on iOS too (palette / connect / remote-window picker / toasts read
        // as a ZStack overlay on both platforms). The ✓ gutter tracks the live chrome + the active pane's
        // read-only / secure-entry state — the SAME predicate the macOS host uses (the palette is cross-platform).
        .overlay {
            OverlayHostView(
                store: store,
                connection: connection,
                coordinator: overlay,
                toggledState: OverlayHostView.toggledState(for: chrome, store: store),
                sidebarCollapsed: chrome.sidebarCollapsed,
            )
        }
        // Wire the palette's cwd resolver + the per-pane hardware-keyboard interceptor's overlay toggles
        // (iPad has no app-level NSEvent monitor, so a focused
        // terminal's ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J would otherwise die at a nil toggle).
        .onAppear {
            wireOverlayCwdResolver()
            wireOverlayKeyToggles()
        }
        // E19/A18 (WI-7): drive the TABS panel auto-hide on iPad too — the SAME shared policy macOS runs. On a
        // tab-count TRANSITION or a Settings mode flip, apply `SidebarAutoHidePolicy` to `chrome.sidebarCollapsed`
        // (here mapped to the split's `columnVisibility` via `sidebarColumnVisibility`), only when the policy has
        // an opinion (`.auto`) and the 1↔>1 regime crossed — so a manual reveal/hide is never fought by an
        // unrelated tab open/close (`applyAutoHide` gates on the regime edge + a manual-override bit).
        // `initial: true` applies the policy ONCE at launch too (SwiftUI `.onChange` skips first appearance), so a
        // single-tab `.auto` session opens with the TABS panel already hidden instead of waiting for a tab add/remove.
        .onChange(of: activeTabCount, initial: true) { applyAutoHidePolicy() }
        .onChange(of: autoHideTabsPanel) { applyAutoHidePolicy() }
        // WI-5: the toolbar gear presents the in-app settings sheet (iOS has no `Settings` scene). The sheet
        // hosts the same cross-platform section structs as the macOS strip.
        .sheet(isPresented: $showSettings) {
            if let preferencesStore {
                // E13: thread the app-owned controller into the sheet so the Agents card / behaviour toggles
                // are live on iOS (a sheet does not inherit the presenter's custom environment values).
                SettingsSheet(store: preferencesStore, agentHooks: agentHooksController)
            }
        }
        #endif
    }

    #if os(macOS)
    /// Hand the app-level dispatcher the chrome toggles (sidebar ⌘⇧L), each bound to
    /// THIS view's live state. Called on appear (the dispatcher predates `chrome`, so the closures are
    /// installed late). `[chrome]` captures the same `@Observable` instance the representable + titlebar
    /// read, so each NSEvent chord and the matching titlebar button flip ONE flag.
    private func wireChromeToggles() {
        installSidebarToggle? { [chrome] in chrome.toggleSidebar() }
        // TabSide partition: ⌘⇧E (Toggle Windows Panel) — the right column's twin of the sidebar wiring.
        installWindowsToggle? { [chrome] in chrome.toggleWindowsPanel() }
        // Route the palette's chrome-toggle row through the SAME live `chrome` the chord + titlebar drive,
        // so "Toggle Tabs Panel" from the palette flips the flag the split + the ✓ read
        // (not the dead `store.sidebarCollapsed`). Bound here because `chrome` predates the app-built overlay.
        overlay.toggleSidebar = { [chrome] in chrome.toggleSidebar() }
        overlay.toggleWindowsPanel = { [chrome] in chrome.toggleWindowsPanel() }
        // E19 WI-4 (Pin Window): route the palette / any command surface AND a user-bound chord (chord-less by
        // default) to the SAME live `chrome.pinned` the menu Button + the macOS `NSWindow.level` glue read.
        overlay.togglePinWindow = { [chrome] in chrome.togglePin() }
        installPinToggle? { [chrome] in chrome.togglePin() }
        wireOverlayCwdResolver()
    }
    #endif

    /// Batch-5b (A): bind the overlay coordinator's `resolveActiveCwd` to the focused pane's live
    /// ``MetadataClient`` so opening the command palette EAGERLY resolves its working directory (host `cwd()`
    /// RPC) and mirrors it into ``PaneSpec/lastKnownCwd`` — which the WORKING DIRECTORY header's cwd pill (and
    /// the titlebar / rail) read reactively. Without this the pill stayed blank on a freshly-connected pane at a
    /// prompt: the only other `lastKnownCwd` writer (a command completing via OSC 133;D) had not fired.
    /// Reuses the EXACT live-metadata path
    /// Open-Quickly uses (`store.handle(for:) as? LivePaneSession → activeMetadataClient`), so it
    /// spends NO new wire message. `[store]` captures the live store; a disconnected pane / nil client / empty
    /// cwd is a silent no-op (validate-then-drop). Cross-platform — called on
    /// both platforms (macOS via `wireChromeToggles()`, iOS via the `.onAppear`).
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
    /// ``OverlayCoordinator``. iOS-relevant: the iPad has no app-level NSEvent monitor, so without these a
    /// focused terminal's ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌥J resolved to a `nil` toggle and did nothing. On
    /// macOS the dispatcher owns these chords before the surface, so this is harmless there (the interceptor
    /// never sees them) but keeps the seam single-sourced. The `[overlay]` capture mirrors the macOS dispatcher
    /// wiring in ``AislopdeskClientApp``.
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

    /// Pure map from the shared `sidebarCollapsed` flag to the iOS `NavigationSplitView` column visibility: a
    /// collapsed sidebar hides the leading TABS column (`.detailOnly` — the shell is TWO columns now that the
    /// inspector is removed, so "everything but the sidebar" is the detail alone), a revealed sidebar
    /// shows `.all`. Drives ``sidebarColumnVisibility`` (iOS) so the WI-7 auto-hide policy (which sets
    /// `chrome.sidebarCollapsed`) hides/reveals the TABS panel on iPad too — the shared flag is not a dead
    /// toggle there. Kept cross-platform (`NavigationSplitViewVisibility` exists on macOS) so the mapping is
    /// unit-tested in the macOS `swift test` Gate, not only at iOS compile time.
    static func sidebarVisibility(sidebarCollapsed: Bool) -> NavigationSplitViewVisibility {
        sidebarCollapsed ? .detailOnly : .all
    }

    /// The iOS ``sidebarColumnVisibility`` SETTER side: a user-driven swipe of the leading TABS column — the
    /// SECOND manual entry point besides ``WorkspaceChromeState/toggleSidebar`` — writes the shared
    /// `chrome.sidebarCollapsed` flag AND, when it GENUINELY flips that flag (a real collapse/reveal, not a
    /// SwiftUI echo of the value the auto-hide policy just set), records `manualSidebarOverride` so
    /// ``applyAutoHide(mode:tabCount:chrome:)`` honors the iPad swipe the SAME way it honors ⌘⇧L (WI-7: "do NOT
    /// fight a manual ⌘⇧L"). Without this an iPad user who swipes the panel away at >1 tabs would have it
    /// forcibly REVEALED on the next within-regime tab open/close (the policy sees no override → re-asserts
    /// `desired=false`). The `!= chrome.sidebarCollapsed` guard distinguishes a genuine user swipe from the
    /// binding echo SwiftUI fires when the getter-derived value is written back unchanged, so a policy-driven
    /// change is never mis-recorded as manual. Static + cross-platform so the contract is unit-tested without a
    /// live split / NSWindow (see `SidebarAutoHideWiringTests`).
    static func applySidebarVisibility(_ visibility: NavigationSplitViewVisibility, chrome: WorkspaceChromeState) {
        // TWO-column shell: `.detailOnly` is the only "sidebar hidden" visibility (`.doubleColumn` shows
        // both columns of a two-column split, so it must read as REVEALED — unlike the old 3-column map).
        let collapsed = (visibility == .detailOnly)
        guard collapsed != chrome.sidebarCollapsed else { return }
        chrome.manualSidebarOverride = true
        chrome.sidebarCollapsed = collapsed
    }

    /// E19/A18 (WI-7): the single place the `auto-hide-tabs-panel` policy ACTUATES. Apply the pure
    /// ``SidebarAutoHidePolicy/desiredCollapsed(mode:tabCount:)`` decision to the live `chrome.sidebarCollapsed`,
    /// but ONLY when the policy has an opinion (mode `.auto`); a `nil` opinion (mode `.default`/`.always`) is left
    /// untouched.
    ///
    /// The decision the `.auto` opinion encodes flips ONLY across the 1↔>1 tab-count regime (`desired == tabCount
    /// <= 1`), so the actuation is gated on a regime EDGE — the first application (`lastAutoHideCollapsed == nil`)
    /// or a `desired` that differs from the last value the policy itself drove. ON that edge the default-state
    /// opinion ("hidden when only one tab") legitimately re-asserts: clear any manual override and actuate. WITHIN
    /// a regime (an UNRELATED tab open/close — e.g. 2→3 tabs — that does not flip `desired`) a manual ⌘⇧L is
    /// honored and NEVER fought (E19-carryovers WI-7: "do NOT fight a manual ⌘⇧L"). The `!= desired` write guard
    /// still avoids a redundant `@Observable` invalidation. Static + cross-platform so the contract is unit-tested
    /// without a live view (see `SidebarAutoHideWiringTests`).
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

    /// TabSide partition: the GUI column's auto-reveal policy. `desired collapsed = (guiTabCount == 0)`
    /// — the column shows exactly while there is something to show. Actuation is gated on the 0↔>0
    /// regime EDGE (the first application, or a flip of `desired`): ON an edge the auto opinion wins and
    /// any manual ⌘⇧E override is cleared; WITHIN a regime (another GUI tab opened/closed without
    /// crossing zero) a manual toggle is honored and never fought. Static + pure over the chrome model so
    /// the contract is unit-tested without a live split (mirrors ``applyAutoHide(mode:tabCount:chrome:)``).
    static func applyGuiAutoReveal(guiTabCount: Int, chrome: WorkspaceChromeState) {
        let desired = guiTabCount == 0
        let isRegimeEdge = chrome.lastAutoGuiCollapsed != desired
        chrome.lastAutoGuiCollapsed = desired
        if isRegimeEdge {
            chrome.manualGuiOverride = false
        } else if chrome.manualGuiOverride {
            return
        }
        if chrome.guiCollapsed != desired {
            chrome.guiCollapsed = desired
        }
    }

    /// Thin view-side glue over the static, unit-tested ``applyAutoHide(mode:tabCount:chrome:)`` — read the live
    /// inputs (the `@Default` mode + the active session's tab count) and actuate. Called from the `.onChange`
    /// observers on both shells so the view body stays declarative and the tested unit stays the policy.
    private func applyAutoHidePolicy() {
        Self.applyAutoHide(mode: autoHideTabsPanel, tabCount: activeTabCount, chrome: chrome)
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        // iOS uses NavigationSplitView's own column-visibility chrome; surface the connection pill + the
        // agent indicator + a New-Tab affordance. (Sidebar/inspector toggles are the system idiom there.)
        ToolbarItem(placement: .principal) {
            ConnectionStatusPill(connection: connection, pingMS: activePingMS, onTap: openConnect)
        }
        ToolbarItem(placement: .primaryAction) {
            if let symbol = StatusPresentation.agentSymbol(activeAgentStatus) {
                Image(systemName: symbol)
                    .foregroundStyle(StatusPresentation.agentTint(activeAgentStatus))
                    .accessibilityLabel("Agent \(StatusPresentation.agentLabel(activeAgentStatus))")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // The command palette (⌘⇧P) — iOS has no app-level NSEvent monitor (macOS's `WorkspaceKeyDispatcher`
            // owns that chord there), so without this button the palette — the cross-platform "command surface" —
            // had NO entry point on iPad at all. The hardware-keyboard chord is also routed (see
            // `wireOverlayKeyToggles()`); this is the touch affordance.
            Button { overlay.togglePalette() } label: { Image(systemSymbol: .command) }
                .help("Command Palette")
        }
        ToolbarItem(placement: .primaryAction) {
            // The `+` opens a focused `.chooser` pane (the in-pane chooser UX — same as macOS's titlebar),
            // which renders `InPaneChooserView` for the Terminal/Remote pick. (The old centred
            // `PaneChooserModel` popover was removed in the in-pane-chooser refactor.)
            Button { store.openChooserPane(.newTab) } label: { Image(systemSymbol: .plus) }
                .help("New Tab")
        }
        ToolbarItem(placement: .primaryAction) {
            // WI-5: the settings gear — iOS has no `Settings` scene (⌘, is macOS-only), so settings present
            // as an in-app sheet. Disabled until the preferences store is injected (so the gear never opens
            // an empty sheet in a preview / pre-scene state).
            Button { showSettings = true } label: { Image(systemSymbol: .gearshape) }
                .help("Settings")
                .disabled(preferencesStore == nil)
        }
    }
    #endif

    /// Opens the Connect-to-Host flow via the injected coordinator (sets `overlay.connectVisible`). The
    /// `ConnectHostView` the flag drives lands in WI-5; WI-1 only routes the affordance here. A give-up
    /// state still runs Retry inside the pill itself.
    private func openConnect() {
        overlay.openConnect()
    }
}

#if os(macOS)
/// Bridges the AppKit `AislopdeskSplitViewController` into SwiftUI. The controller (and the two SwiftUI
/// columns it hosts) owns the long-lived shell; SwiftUI just mounts it. Keeping the shell in AppKit (not a
/// SwiftUI `HSplitView`) is the load-bearing no-teardown choice for the libghostty panes. `updateNSView…`
/// pushes the chrome collapse flag into the split item each update (the toolbar toggle flips it).
struct WorkspaceSplitRepresentable: NSViewControllerRepresentable {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState
    /// The overlay reducer — threaded so the controller can wire the sidebar's status affordance to
    /// `openConnect()` (ES-E2-6, the macOS connect affordance). Captured once in `makeNSViewController`.
    let overlay: OverlayCoordinator
    /// The live ``PreferencesStore`` (`\.preferencesStore`) — forwarded into the controller so the sidebar's
    /// ``NavigatorColumn`` tab context menu can surface the host-LOCAL "Prevent Sleep While Processing" flag
    /// (Batch 4). The NSHostingController columns do not inherit the WindowGroup environment, hence the explicit
    /// thread. `nil` (no scene injection / a preview) hides the row.
    let preferences: PreferencesStore?

    func makeNSViewController(context _: Context) -> AislopdeskSplitViewController {
        AislopdeskSplitViewController(
            store: store, connection: connection, chrome: chrome, preferences: preferences,
            onConnect: { [overlay] in overlay.openConnect() },
            onOpenRemotePicker: { [overlay] in overlay.openRemotePicker() },
        )
    }

    func updateNSViewController(_ controller: AislopdeskSplitViewController, context _: Context) {
        // Reading the @Observable flags here ties this update to their changes; apply them to the items.
        controller.applyCollapse(sidebarCollapsed: chrome.sidebarCollapsed, guiCollapsed: chrome.guiCollapsed)
    }
}
#endif
#endif
