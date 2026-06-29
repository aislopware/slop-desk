// WorkspaceRootView — the native 3-column IDE shell (REBUILD-V2, L1 + L4a toolbar/inspector).
//
// macOS: an `NSViewControllerRepresentable` (`WorkspaceSplitRepresentable`) owning an
// `AislopdeskSplitViewController` (an `NSSplitViewController` with sidebar | content | inspector items,
// each an `NSHostingController` over a SwiftUI column). Modelled on CodeEdit's split shell. The window runs
// `.windowStyle(.hiddenTitleBar)` — there is NO system unified toolbar; otty's own hover-reveal titlebar
// (`OttyTitlebar`, hosted as a top overlay inside `ContentColumn`) IS the chrome (sidebar/Details toggles,
// "New Tab", the centred title menu). iOS: a stock `NavigationSplitView` over the same three columns + its
// own toolbar.
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
    /// The shared Details-panel tab selection (E9/WI-7). Owned here so BOTH inspector mounts (the macOS split
    /// item via the representable, the iOS detail column) read ONE selection, and the four `Details: *` jump
    /// commands can write it through the `selectDetailsTab` closure installed in `wireChromeToggles()`.
    @State private var details = DetailsPanelState()
    /// E19/A18 (WI-7): the live otty `auto-hide-tabs-panel` mode. Read via `@Default` (NOT the plain
    /// ``SettingsKey/autoHideTabsPanel`` accessor) so SwiftUI re-evaluates the body — and thus re-fires the
    /// `.onChange(of: autoHideTabsPanel)` observer below — when the user flips the Settings picker. Drives the
    /// vertical TABS panel auto-hide together with the active session's tab count (see ``applyAutoHide``).
    @Default(.autoHideTabsPanel) private var autoHideTabsPanel
    #if os(iOS)
    /// Whether the iOS settings sheet (WI-5) is presented — flipped by the toolbar gear, read by the `.sheet`.
    @State private var showSettings = false
    /// E12 WI-6 (iOS): the bottom-sheet Composer's per-mount chrome (the sheet is outside any pane leaf).
    @State private var composerSheetChrome = ComposerLeafChrome()
    /// E12 WI-6 (iOS): a stable fallback model so the sheet content has a non-optional composer even on the
    /// frame where the resolved float/pin target is briefly `nil` (the sheet is dismissed then, so the
    /// fallback's content never shows).
    @State private var composerSheetFallback = ComposerModel()
    /// ES-E9-5 (iOS reveal): on COMPACT width a three-column `NavigationSplitView` collapses to a single
    /// stack, so a `Details: *` jump that only set `details.selected` would switch an OFF-SCREEN column — the
    /// reveal half was inert (nothing read `chrome.inspectorCollapsed` on iOS). This binding maps that SAME
    /// reveal flag to the split's `preferredCompactColumn`: when a command reveals the panel
    /// (`inspectorCollapsed == false`) the `.detail` (Inspector) column is surfaced on compact width; manual
    /// back-navigation writes the flag back. (Regular width always shows the detail column, so this is a no-op
    /// there.) Reading `chrome` here ties the body to the flag the install closure flips.
    private var detailsCompactColumnBinding: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { Self.compactColumn(inspectorCollapsed: chrome.inspectorCollapsed) },
            set: { chrome.inspectorCollapsed = ($0 != .detail) },
        )
    }

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

    /// The single live preferences store, injected once at the WindowGroup root (`\.preferencesStore`) and
    /// handed to the iOS ``SettingsSheet``. `nil` (no scene injection / a preview) → the gear presents nothing.
    @Environment(\.preferencesStore) private var preferencesStore
    /// E13 (ES-E13-1/ES-E13-2 iOS halves): the app-owned Agents install-hooks controller, injected once at the
    /// WindowGroup root (`\.agentHooksController`) and handed to the iOS ``SettingsSheet`` so the Agents card +
    /// the Agent-Behaviour toggles are LIVE on iOS (the macOS `Settings` scene injects it on its own side).
    /// `nil` (no scene injection / a preview) → the card renders the disabled "Connect a session" state.
    @Environment(\.agentHooksController) private var agentHooksController
    #endif
    /// Installs the Details-panel toggle on the app-level keybinding dispatcher. The dispatcher is built at
    /// app `init` (before this view's `chrome` exists), so on appear the root view hands it
    /// `chrome.toggleInspector` and ⌘⇧R (otty's Toggle Details Panel) routes through the SAME NSEvent monitor
    /// that owns every other chord. `nil` (the default / iOS / tests) leaves the chord a graceful no-op. A
    /// plain closure keeps `WorkspaceKeyDispatcher` internal (no public-API widening).
    private let installDetailsToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the sidebar / Tabs-panel toggle on the app-level keybinding dispatcher (same late-wiring story
    /// as `installDetailsToggle`): on appear the root view hands it `chrome.toggleSidebar` so ⌘⇧L (otty's
    /// Toggle Tabs Panel) flips the LIVE `chrome.sidebarCollapsed` the native split reads — not the legacy
    /// `store.sidebarCollapsed` (which nothing reads on macOS). `nil` (the default / iOS / tests) is a no-op.
    private let installSidebarToggle: ((@escaping () -> Void) -> Void)?
    /// Installs the four `Details: *` jump commands' tab-selector on the app-level keybinding dispatcher
    /// (same late-wiring story as `installDetailsToggle`): on appear the root view hands it a closure that
    /// sets `details.selected` AND reveals the panel (`chrome.inspectorCollapsed = false`), so a routed
    /// `selectDetailsTab(_:)` action switches the Details tab through the SAME NSEvent monitor / menu that
    /// owns every command. `nil` (the default / iOS / tests) leaves the four commands graceful no-ops.
    private let installSelectDetailsTab: ((@escaping (DetailsPanelTab) -> Void) -> Void)?
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
        installDetailsToggle: ((@escaping () -> Void) -> Void)? = nil,
        installSidebarToggle: ((@escaping () -> Void) -> Void)? = nil,
        installSelectDetailsTab: ((@escaping (DetailsPanelTab) -> Void) -> Void)? = nil,
        installPinToggle: ((@escaping () -> Void) -> Void)? = nil,
    ) {
        self.store = store
        self.connection = connection
        self.overlay = overlay
        self.chrome = chrome
        self.installDetailsToggle = installDetailsToggle
        self.installSidebarToggle = installSidebarToggle
        self.installSelectDetailsTab = installSelectDetailsTab
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

    public var body: some View {
        #if os(macOS)
        // No system unified toolbar / header — the window runs `.hiddenTitleBar` and otty's hover-reveal
        // titlebar (`OttyTitlebar`, hosted inside `ContentColumn`) IS the chrome.
        WorkspaceSplitRepresentable(
            store: store, connection: connection, chrome: chrome, details: details, overlay: overlay,
        )
        .ignoresSafeArea()
        // E12 WI-6 (pin): a PINNED composer is promoted OUT of its pane subtree to a WINDOW-level bottom
        // mount, so it rides along across tab switches (the otty pin). Mounted UNDER the overlay host (the
        // palette / toasts stay above it). Self-hides when nothing is pinned / when the pinned composer is
        // floating. `store.pinnedComposer` resolves it across ALL live panes, so a tab switch never tears
        // it down.
        .overlay(alignment: .bottom) {
            PinnedComposerBar(store: store)
        }
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
            )
        }
        // E12 WI-6 (float): drive the non-activating floating `NSPanel` from the FLOATING composer. Reading
        // `store.floatingComposer` HERE (in the body) registers the observation that re-invokes the host's
        // `updateNSView` when the float toggle flips. Zero-size — the panel is a separate window that stays
        // on top WITHOUT activating the app.
        .background {
            ComposerFloatPanelHost(floating: store.floatingComposer)
        }
        // E12 WI-6: the otty "pinned state is persisted" rule is honoured PER-PANE — `LivePaneSession.adopt`
        // restores each pane's pin (keyed by its stable `PaneID`) on launch and wires `onPinnedChange` to
        // persist later toggles. No window-level write here: a single global Bool could not say WHICH pane
        // was pinned.
        // Wire ⌘⇧R (Toggle Details) + ⌘⇧L (Toggle Tabs Panel / sidebar) to the live chrome once it
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
        #else
        NavigationSplitView(
            columnVisibility: sidebarColumnVisibility,
            preferredCompactColumn: detailsCompactColumnBinding,
        ) {
            NavigatorColumn(store: store)
        } content: {
            ContentColumn(store: store, connection: connection, chrome: chrome)
        } detail: {
            InspectorColumn(store: store, connection: connection, details: details, onConnect: openConnect)
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
            )
        }
        // ES-E9-5: wire the four `Details: *` palette commands to the live `chrome`/`details` on iOS too (the
        // palette is cross-platform; iOS has no NSEvent dispatcher, so the palette + this closure ARE the
        // surface). The macOS path wires the same closure in `wireChromeToggles()`. ALSO wire the per-pane
        // hardware-keyboard interceptor's overlay toggles (iPad has no app-level NSEvent monitor, so a focused
        // terminal's ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌃↩ / ⌘⌥J would otherwise die at a nil toggle).
        .onAppear {
            wireOverlaySelectDetailsTab()
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
        // hosts the same cross-platform section structs as the macOS strip. The live `WorkspaceStore` rides
        // the `\.workspaceStore` slot so Advanced → Workspace export/import works on iOS too.
        .sheet(isPresented: $showSettings) {
            if let preferencesStore {
                // E13: thread the app-owned controller into the sheet so the Agents card / behaviour toggles
                // are live on iOS (a sheet does not inherit the presenter's custom environment values).
                SettingsSheet(store: preferencesStore, agentHooks: agentHooksController)
                    .workspaceStore(store)
            }
        }
        // E12 WI-6 (iOS): iOS has no floating window over other apps, so BOTH the float and the pin reduce
        // to a re-presented bottom sheet (the documented ceiling, spec `agents__composer.md`). Present while
        // a float/pin target exists; dismissing docks the float back AND unpins. Reading
        // `store.floatingComposer` / `store.pinnedComposer` in the binding registers the observation that
        // opens / closes the sheet with the toggle.
        .composerSheet(
            isPresented: composerSheetPresented,
            composer: iosComposerTarget?.composer ?? composerSheetFallback,
            chrome: composerSheetChrome,
            agentActive: iosComposerTarget?.agentActive ?? false,
        )
        // E12 WI-6: pin persistence is PER-PANE (restored + persisted in `LivePaneSession.adopt`, keyed by
        // the stable `PaneID`), not a window-level global Bool — so a relaunch re-pins the exact pane.
        #endif
    }

    #if os(iOS)
    /// The composer to present in the iOS sheet (E12 WI-6) — a FLOATING composer (the float button) or a
    /// PINNED one (re-presented across navigation). Float wins when both are set (it is the active gesture).
    private var iosComposerTarget: ResolvedComposer? {
        store.floatingComposer ?? store.pinnedComposer
    }

    /// Binding driving the iOS Composer sheet: present while a float/pin target exists; dismissing it
    /// (swipe-down / programmatic) docks the float back AND unpins (on iOS the sheet IS the pin surface, so
    /// closing it is "stop riding along"). A no-op when there is no target.
    private var composerSheetPresented: Binding<Bool> {
        Binding(
            get: { iosComposerTarget != nil },
            set: { present in
                guard !present, let target = iosComposerTarget else { return }
                target.composer.isFloating = false
                target.composer.setPinned(false)
            },
        )
    }
    #endif

    #if os(macOS)
    /// Hand the app-level dispatcher the chrome toggles (Details ⌘⇧R + sidebar ⌘⇧L), each bound to THIS
    /// view's live `chrome`. Called on appear (the dispatcher predates `chrome`, so the closures are installed
    /// late). `[chrome]` captures the same `@Observable` instance the representable + titlebar read, so each
    /// NSEvent chord and the matching titlebar button flip ONE flag.
    private func wireChromeToggles() {
        installDetailsToggle? { [chrome] in chrome.toggleInspector() }
        installSidebarToggle? { [chrome] in chrome.toggleSidebar() }
        // The four `Details: *` jump commands (ES-E9-5): set the shared tab selection AND reveal the panel
        // (otty opens a hidden Details panel on a tab jump). `[chrome, details]` captures the SAME instances
        // the representable + the hosted `InspectorColumn` read, so a routed `selectDetailsTab(_:)` switches
        // the visible tab and un-collapses the inspector split item in one shot.
        installSelectDetailsTab? { [chrome, details] tab in
            Self.revealDetailsTab(tab, chrome: chrome, details: details)
        }
        // Route the palette's chrome-toggle rows through the SAME live `chrome` the chords + titlebar drive,
        // so "Toggle Tabs Panel"/"Toggle Details Panel" from the palette flip the flag the split + the ✓ read
        // (not the dead `store.sidebarCollapsed`). Bound here because `chrome` predates the app-built overlay.
        overlay.toggleSidebar = { [chrome] in chrome.toggleSidebar() }
        overlay.toggleInspector = { [chrome] in chrome.toggleInspector() }
        // E19 WI-4 (Pin Window): route the palette / any command surface AND a user-bound chord (chord-less by
        // default) to the SAME live `chrome.pinned` the menu Button + the macOS `NSWindow.level` glue read.
        overlay.togglePinWindow = { [chrome] in chrome.togglePin() }
        installPinToggle? { [chrome] in chrome.togglePin() }
        wireOverlaySelectDetailsTab()
    }
    #endif

    /// Cross-platform (ES-E9-5): bind the overlay coordinator's `selectDetailsTab` to THIS view's live
    /// `chrome`/`details` so the command palette's four `Details: *` rows — and, on macOS, the View ▸
    /// Details: * menu rows routed through the same coordinator closure (threaded in `AislopdeskClientApp`) —
    /// set the shared `DetailsPanelState.selected` AND reveal the panel. The palette is cross-platform, so the
    /// four commands run on iOS too (where there is no NSEvent dispatcher). `[chrome, details]` captures the
    /// SAME instances both inspector mounts read, so the visible tab switches in one shot.
    private func wireOverlaySelectDetailsTab() {
        overlay.selectDetailsTab = { [chrome, details] tab in
            Self.revealDetailsTab(tab, chrome: chrome, details: details)
        }
    }

    /// Hand the live store the overlay-toggle closures the per-pane hardware-keyboard ``TerminalKeyInterceptor``
    /// threads into `route` (``WorkspaceStore/overlayKeyToggles``), each pointed at the injected
    /// ``OverlayCoordinator``. iOS-relevant: the iPad has no app-level NSEvent monitor, so without these a
    /// focused terminal's ⌘⇧P / ⇧⌘F / ⌘⇧O / ⌘J / ⌘⌃↩ / ⌘⌥J resolved to a `nil` toggle and did nothing. On
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
            sendToChat: { [overlay] in overlay.toggleSendToChat() },
            peekReply: { [overlay] in overlay.togglePeekReply() },
        )
    }

    /// The single source of truth for what a `Details: *` jump DOES to the shared workspace state: switch the
    /// visible Details tab AND reveal the panel. Both install paths (the macOS chord/menu in
    /// `wireChromeToggles()` and the cross-platform overlay in `wireOverlaySelectDetailsTab()`) call this, so
    /// they can never drift to "selects the tab but forgets to reveal" — the bug that left the iOS reveal half
    /// inert. The reveal flag (`inspectorCollapsed = false`) drives the macOS split item AND, on iOS compact
    /// width, `detailsCompactColumnBinding` → the `.detail` column. Static + cross-platform so the contract is
    /// unit-testable without a live view (see `OverlayCoordinatorMountTests`).
    static func revealDetailsTab(_ tab: DetailsPanelTab, chrome: WorkspaceChromeState, details: DetailsPanelState) {
        details.selected = tab
        chrome.inspectorCollapsed = false
    }

    /// Pure map from the shared `inspectorCollapsed` reveal flag to the iOS `NavigationSplitView` compact
    /// column: a revealed Details panel (`!collapsed`) surfaces the `.detail` (Inspector) column on compact
    /// width; collapsed leaves the `.content` column up. Drives `detailsCompactColumnBinding` (iOS). Kept
    /// cross-platform (`NavigationSplitViewColumn` exists on macOS too) so the iOS reveal mapping is unit-tested
    /// in the macOS `swift test` Gate, not only at iOS compile time.
    static func compactColumn(inspectorCollapsed: Bool) -> NavigationSplitViewColumn {
        inspectorCollapsed ? .content : .detail
    }

    /// Pure map from the shared `sidebarCollapsed` flag to the iOS `NavigationSplitView` column visibility: a
    /// collapsed sidebar hides the leading TABS column (`.doubleColumn` = content + detail), a revealed sidebar
    /// shows `.all`. Drives ``sidebarColumnVisibility`` (iOS) so the WI-7 auto-hide policy (which sets
    /// `chrome.sidebarCollapsed`) hides/reveals the TABS panel on iPad too — the shared flag is not a dead
    /// toggle there. Kept cross-platform (`NavigationSplitViewVisibility` exists on macOS) so the mapping is
    /// unit-tested in the macOS `swift test` Gate, not only at iOS compile time.
    static func sidebarVisibility(sidebarCollapsed: Bool) -> NavigationSplitViewVisibility {
        sidebarCollapsed ? .doubleColumn : .all
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
        let collapsed = (visibility == .doubleColumn || visibility == .detailOnly)
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
    /// or a `desired` that differs from the last value the policy itself drove. ON that edge the otty default-state
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
/// E12 WI-6 — the WINDOW-level mount for a PINNED composer (the architecturally non-trivial "promote out of
/// the pane subtree"). otty's pin keeps the composer visible across ALL tab switches; here it mounts as a
/// bottom strip ABOVE the AppKit split (a SwiftUI `.overlay` composes over the
/// `NSViewControllerRepresentable`). `store.pinnedComposer` resolves the pinned composer across EVERY live
/// pane, so switching to another tab never tears it down — the bar rides along. Hidden when nothing is
/// pinned, when the pinned composer is FLOATING (the ``ComposerFloatPanel`` owns it then), or when the
/// composer is dismissed (`⎋`) with an empty queue.
struct PinnedComposerBar: View {
    let store: WorkspaceStore
    /// Per-mount chrome — the window-level mount is outside any pane leaf, so it owns its own (the bar is
    /// the normal Composer; queue-input mode stays off here).
    @State private var chrome = ComposerLeafChrome()

    var body: some View {
        if let pinned = store.pinnedComposer, mount(pinned.composer) {
            let composer = pinned.composer
            VStack(spacing: 0) {
                PromptQueueStrip(composer: composer)
                ComposerBar(composer: composer, chrome: chrome)
            }
            .frame(maxWidth: .infinity)
            .background(NativePaneColor.terminalBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(Otty.Line.divider).frame(height: Otty.Metric.hairline)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(Otty.Anim.reveal, value: composer.isVisible)
        }
    }

    /// Mount the pinned bar only while this window-level slot is its HOME: pinned, NOT floating (the panel
    /// owns it then), and either visible or holding queued chips (so `⎋` still hides an empty pinned bar).
    private func mount(_ composer: ComposerModel) -> Bool {
        guard !composer.isFloating else { return false }
        return composer.isVisible || !composer.promptQueue.isEmpty
    }
}

/// Bridges the AppKit `AislopdeskSplitViewController` into SwiftUI. The controller (and the three SwiftUI
/// columns it hosts) owns the long-lived shell; SwiftUI just mounts it. Keeping the shell in AppKit (not a
/// SwiftUI `HSplitView`) is the load-bearing no-teardown choice for the libghostty panes. `updateNSView…`
/// pushes the chrome collapse flags into the split items each update (the toolbar toggles flip them).
struct WorkspaceSplitRepresentable: NSViewControllerRepresentable {
    let store: WorkspaceStore
    let connection: AppConnection
    let chrome: WorkspaceChromeState
    /// The shared Details-tab selection (E9/WI-7) — forwarded into the controller so the hosted
    /// `InspectorColumn` reads the SAME selection the root view's `selectDetailsTab` closure writes.
    let details: DetailsPanelState
    /// The overlay reducer — threaded so the controller can wire the inspector's Status row to
    /// `openConnect()` (ES-E2-6, the macOS connect affordance). Captured once in `makeNSViewController`.
    let overlay: OverlayCoordinator

    func makeNSViewController(context _: Context) -> AislopdeskSplitViewController {
        AislopdeskSplitViewController(
            store: store, connection: connection, chrome: chrome, details: details,
            onConnect: { [overlay] in overlay.openConnect() },
        )
    }

    func updateNSViewController(_ controller: AislopdeskSplitViewController, context _: Context) {
        // Reading the @Observable flags here ties this update to their changes; apply them to the items.
        controller.applyCollapse(
            sidebarCollapsed: chrome.sidebarCollapsed,
            inspectorCollapsed: chrome.inspectorCollapsed,
        )
    }
}
#endif
#endif
