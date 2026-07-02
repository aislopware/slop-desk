// OverlayHostView — the single mount point that presents EVERY floating overlay above the workspace as
// NATIVE SwiftUI chrome (the "everything outside the workspace + panes is native" directive). It owns NO
// bespoke `Scrim` + hand-drawn card any more: each overlay is a real system `.sheet` driven by the injected
// ``OverlayCoordinator`` flags, and the pane/tab close confirmation is a native `.alert` driven off the
// store's `pendingClose*` parks. The always-mounted ``ToastStackView`` (which renders nothing when empty)
// is the host's only in-tree content — transient notifications float over the workspace without a modal.
//
// One host so every overlay shares one presentation point: because the coordinator only ever drives one
// overlay flag at a time (its `run()` closes-then-opens; the open* methods are the only writers), a single
// `.sheet(item:)` keyed on a computed ``ActiveSheet`` is robust — it can never race two chained
// `.sheet(isPresented:)` modifiers, and a system dismissal (Esc / click-away) routes back through the
// binding's `set(nil)` to the matching `close*()`.
//
// MOUNTING: the root view (`WorkspaceRootView`) attaches this as a top `.overlay` on the macOS
// `WorkspaceSplitRepresentable` and on the iOS `NavigationSplitView` — a `.sheet`/`.alert` presented from an
// overlay composes over the window on both platforms.
//
// SEAM discipline: the host owns NO state — every read/close goes through the coordinator (the single
// `@Observable` reducer) or the store (the close-confirmation parks). The `toggledState` predicate is built
// by the root from the live `WorkspaceChromeState` (macOS) or a no-op (iOS) and handed to the palette, so the
// pure coordinator never learns about chrome. NATIVE styling only (system fonts / controls) — the overlays
// carry their own content; the host adds no design-token chrome.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct OverlayHostView: View {
    /// The live store — passed to the palette / pickers (working-directory badge, sources) and read for the
    /// pane/tab close-confirmation parks (`pendingCloseSpec` / `pendingTabCloseID`).
    let store: WorkspaceStore
    /// The app-global connection — bound by ``ConnectHostView`` (the host/port form is a thin view over it).
    let connection: AppConnection
    /// The single overlay reducer — every overlay's visibility + close routes through it.
    @Bindable var coordinator: OverlayCoordinator
    /// Whether a palette row currently shows its ✓ (toggled-on) gutter. Built by the root from the live chrome
    /// (see ``OverlayHostView/toggledState(for:store:)``) so the pure coordinator stays chrome-agnostic.
    /// Defaults to "nothing toggled" (iOS / previews).
    var toggledState: @MainActor (PaletteItem) -> Bool = { _ in false }

    var body: some View {
        // The always-mounted toast stack is the host's only in-tree content (it renders nothing when empty);
        // every modal overlay is a native `.sheet`/`.alert` presented over the window. Transparent to hits
        // unless a toast is up so the workspace beneath stays interactive.
        ToastStackView(coordinator: coordinator)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!coordinator.toasts.isEmpty)
            .sheet(item: activeSheetBinding) { sheet in
                // System accent inside the sheet too (a sheet roots a fresh environment, so reset the tint on the
                // presented content directly — not only on the presenter below — to be order-independent).
                sheetContent(sheet)
                    .tint(nil)
            }
            .alert(
                closeAlertTitle,
                isPresented: closeAlertBinding,
                actions: {
                    // "Close" is the destructive action (it stops a running command / discards the pane/tab);
                    // Cancel is the safe default. Native roles give the macOS alert its standard button
                    // placement + tinting, replacing the old hand-drawn warn-tinted button row.
                    Button("Close", role: .destructive) { store.confirmPendingClose() }
                    Button("Cancel", role: .cancel) { store.cancelPendingClose() }
                },
                message: { Text(closeAlertMessage) },
            )
            // Native chrome uses the SYSTEM accent, not the workspace theme accent. The WindowGroup tints its
            // whole subtree with `Slate.State.accent` (so stock controls in the workspace/pane chrome adopt the
            // theme); resetting the tint to nil here scopes the overlays' sheets + the close `.alert` back to the
            // macOS default accent so their toggles / bordered buttons / focus rings read as native System-Settings
            // controls. Only affects THIS overlay subtree (+ the sheets/alert it presents) — the workspace beneath
            // keeps the theme tint. Appearance (light/dark) still follows the parent window via each sheet's own
            // `.preferredColorScheme`, matching how a real macOS sheet inherits its window's appearance.
            .tint(nil)
    }

    // MARK: - Active sheet (single robust presentation seam)

    /// Which overlay (if any) should be presented, resolved from the coordinator flags in a fixed priority
    /// order. The coordinator drives one flag at a time, so this is unambiguous; a `.sheet(item:)` keyed on it
    /// presents exactly one overlay and re-presents cleanly when one overlay replaces another (palette → connect).
    private enum ActiveSheet: Identifiable {
        case connect
        case palette
        case cheatSheet
        case remotePicker
        case openQuickly
        case peekReply
        case globalSearch
        var id: Self { self }
    }

    private var activeSheet: ActiveSheet? {
        if coordinator.connectVisible { return .connect }
        if coordinator.paletteVisible { return .palette }
        if coordinator.cheatSheetVisible { return .cheatSheet }
        if coordinator.remotePickerVisible { return .remotePicker }
        if coordinator.openQuicklyVisible { return .openQuickly }
        if coordinator.peekReplyVisible { return .peekReply }
        if coordinator.globalSearchVisible { return .globalSearch }
        return nil
    }

    /// The `item` binding for the single sheet. `get` mirrors ``activeSheet``; `set(nil)` (a system dismissal —
    /// Esc / click-away) routes to the matching `close*()` so the coordinator flag is cleared. A state-driven
    /// dismissal (a view calling its own `close*()`) flips the flag first, so `get` returns nil and the sheet
    /// dismisses without `set` firing — the two paths never double-close (and the closes are idempotent anyway).
    private var activeSheetBinding: Binding<ActiveSheet?> {
        Binding(
            get: { activeSheet },
            set: { if $0 == nil { closeActiveSheet() } },
        )
    }

    private func closeActiveSheet() {
        if coordinator.connectVisible { coordinator.closeConnect() }
        else if coordinator.paletteVisible { coordinator.closePalette() }
        else if coordinator.cheatSheetVisible { coordinator.closeCheatSheet() }
        else if coordinator.remotePickerVisible { coordinator.closeRemotePicker() }
        else if coordinator.openQuicklyVisible { coordinator.closeOpenQuickly() }
        else if coordinator.peekReplyVisible { coordinator.closePeekReply() }
        else if coordinator.globalSearchVisible { coordinator.closeGlobalSearch() }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .connect:
            ConnectHostView(connection: connection, coordinator: coordinator)
        case .palette:
            PaletteView(coordinator: coordinator, store: store, toggledState: toggledState)
        case .cheatSheet:
            KeyboardCheatSheetView(coordinator: coordinator)
        case .remotePicker:
            RemoteWindowPickerModal(coordinator: coordinator)
        case .openQuickly:
            OpenQuicklyView(store: store, coordinator: coordinator, folders: coordinator.folders)
        case .peekReply:
            PeekReplyOverlay(store: store, coordinator: coordinator)
        case .globalSearch:
            GlobalSearchView(store: store, coordinator: coordinator)
        }
    }

    // MARK: - Close confirmation (native .alert)

    /// Whether the pane/tab close confirmation is up — driven by EITHER store park (they are mutually
    /// exclusive). `set(false)` (Esc / a system dismissal) cancels the park, matching the Cancel button.
    private var closeAlertBinding: Binding<Bool> {
        Binding(
            get: { store.pendingCloseSpec != nil || store.pendingTabCloseID != nil },
            set: { if !$0 { store.cancelPendingClose() } },
        )
    }

    /// The alert headline: the pane's title when a pane close is parked ("Close “<pane>”?"), else the tab copy.
    private var closeAlertTitle: String {
        if let spec = store.pendingCloseSpec {
            return spec.title.isEmpty ? "Close this pane?" : "Close “\(spec.title)”?"
        }
        return "Close this tab?"
    }

    /// The policy-aware alert body (E3 carry-over #4): branch the copy on the policy that ACTUALLY gated the
    /// park, scoped to pane vs tab. Reuses the pure ``CloseConfirmationPanel/reason(for:scope:)`` copy the
    /// tests pin, so the wording can't drift from the pinned strings.
    private var closeAlertMessage: String {
        let policy = store.pendingCloseReasonPolicy ?? .process
        let scope: CloseScope = store.pendingCloseSpec != nil ? .pane : .tab
        return CloseConfirmationPanel.reason(for: policy, scope: scope)
    }

    /// The toggled-state predicate the root hands to ``PaletteView`` — built from the live chrome so the
    /// palette's ✓ gutter reflects the real sidebar visibility (a visible panel ⇒ ✓ on its toggle
    /// row). Pure + `static` so it is unit-pinnable without instantiating the view (E2 / WI-6). `@MainActor`
    /// because it reads the `@MainActor` ``WorkspaceChromeState``. Resolves the checkable View toggles — Toggle
    /// Tabs Panel, Pin Window — PLUS the two E17 Shell toggles whose live state lives on
    /// the active pane (Read Only / Secure Keyboard Entry), read off the `store` so the ✓ tracks the real pane
    /// input gate / secure-entry state rather than staying perpetually dark.
    @MainActor
    static func toggledState(
        for chrome: WorkspaceChromeState, store: WorkspaceStore,
    ) -> @MainActor (PaletteItem) -> Bool {
        { item in
            switch item.id {
            case "action.toggleSidebar": !chrome.sidebarCollapsed
            // E19 WI-4: Pin Window is a CHECKABLE toggle — light the ✓ gutter while the window is pinned, so the
            // palette (and the View menu) tell the user the current pinned state. Mirrors the sidebar
            // treatment, reading the SAME live `chrome.pinned` the menu Button + the `NSWindow.level` glue flip.
            case "action.pinWindow": chrome.pinned
            // E17 (audit fix): Read Only / Secure Keyboard Entry are CHECKABLE toggles whose live state lives on
            // the ACTIVE pane (the convergent `paneReadOnly` set / the model's `secureInputActive` mirror), NOT
            // on `chrome` — so the ✓ tracks the real input gate / secure-entry state instead of never lighting.
            case "action.toggleReadOnly": store.isActivePaneReadOnly()
            case "action.secureKeyboardEntry": store.isActivePaneSecureInputActive()
            default: false
            }
        }
    }
}

// MARK: - CloseConfirmationPanel (close-confirmation COPY — the pure wording the native `.alert` renders)

/// The pure close-confirmation copy (E3 carry-over #4). Once a hand-drawn panel, now a caseless namespace for
/// the wording ONLY — the confirmation itself is a native `.alert` (``OverlayHostView``). Kept as a static
/// helper so ``CloseConfirmationPanelTests`` still pins the policy→copy mapping without instantiating a view.
enum CloseConfirmationPanel {
    /// The close-confirmation subtitle for a given resolved policy + close scope. PURE — unit-pinnable. The
    /// wording stays soft: a running process names the consequence; `always` asks plainly (scoped to "pane" vs
    /// "tab"); `multiple_tabs` warns that the window holds several tabs.
    static func reason(for policy: CloseConfirmationPolicy, scope: CloseScope = .tab) -> String {
        switch policy {
        case .process:
            "A process is still running. Closing it will stop the command."
        case .always:
            switch scope {
            case .pane: "Are you sure you want to close this pane?"
            case .tab,
                 .window: "Are you sure you want to close this tab?"
            }
        case .multipleTabs:
            "This window has multiple tabs."
        }
    }
}
#endif
