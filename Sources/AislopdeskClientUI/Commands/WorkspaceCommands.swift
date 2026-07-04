// WorkspaceCommands — the macOS menu-bar surface over the binding registry (E1 N6, OPTIONAL).
//
// A thin, DISCOVERABILITY-ONLY menu that renders `WorkspaceBindingRegistry.groupedForDisplay` as menu
// sections (Panes / Tabs / Focus / View) so the workspace actions are visible in the
// macOS menu bar. Each item is a plain `Button(title) { route(action, to: store, …) }` that dispatches
// through the SAME single source of truth (`WorkspaceBindingRegistry.route`) the keyboard dispatcher uses.
//
// THE load-bearing rule (E1 trap): NO `.keyboardShortcut` on any item. The app-level `NSEvent` `.keyDown`
// monitor (`WorkspaceKeyDispatcher`) OWNS chord dispatch — including the multi-key tmux/zellij prefix that a
// `.keyboardShortcut` cannot express. A menu shortcut would (a) DOUBLE-FIRE alongside the monitor for a
// single-chord binding, and (b) SWALLOW a prefix sequence's follow-up key before the terminal first
// responder (libghostty) sees it — both wrong. The glyph still SHOWS on each row (a trailing hint Text, not
// a key equivalent) so the menu stays a faithful cheat sheet without binding the chord. See the
// `WorkspaceKeyDispatcher` header + docs/DECISIONS.md (E1 menu-bar entry) for the full rationale.

#if os(macOS)
import AislopdeskWorkspaceCore
import SwiftUI

/// The macOS menu-bar commands for the workspace, attached to the `WindowGroup` via `.commands { }`. Pure
/// discoverability: every item routes through ``WorkspaceBindingRegistry/route(_:to:)`` and carries NO
/// `.keyboardShortcut` (the `NSEvent` dispatcher owns chords — a shortcut here would double-fire / swallow a
/// prefix tail). `@MainActor` because the button actions touch the `@MainActor` store + routing.
@MainActor
struct WorkspaceCommands: Commands {
    /// The single live store every item routes against.
    let store: WorkspaceStore
    /// The view-overlay toggles `route(...)` takes (palette / cheat sheet / find / peek-reply). The app
    /// threads its `@State` switches here so the menu items toggle the same overlays the chords do; `nil`
    /// (the E1 default — those overlays land in later epics) keeps the corresponding actions graceful
    /// no-ops via `route`, never a dead menu item.
    var togglePalette: (() -> Void)?
    var toggleCheatSheet: (() -> Void)?
    var toggleFind: (() -> Void)?
    var togglePeekReply: (() -> Void)?
    var toggleSidebar: (() -> Void)?
    /// E5 / WI-4: the cross-tab Global Search overlay toggle (⇧⌘F, the View ▸ Global Search… menu item).
    /// `nil` keeps the menu item a graceful no-op via `route`, never dead.
    var toggleGlobalSearch: (() -> Void)?
    /// E10 / WI-8 → E11 / WI-7: the View ▸ Jump To… menu item toggle (⌘J). The app re-points it to the
    /// folded-in Jump-To — the Open-Quickly picker at the `.current` pill. `nil` keeps the menu item a
    /// graceful no-op via `route`, never dead.
    var toggleJumpTo: (() -> Void)?
    /// E11 / WI-7: the View ▸ Open Quickly… menu item toggle (⌘⇧O → the merged `.all` pill). `nil` keeps
    /// the menu item a graceful no-op via `route`, never dead. The ⌘⇧O chord itself is owned by the NSEvent
    /// dispatcher (this menu carries no `.keyboardShortcut`); the menu only mirrors it.
    var openQuickly: (() -> Void)?
    /// E19 / WI-4: the View ▸ Pin Window menu item toggle. Pin Window is CHORD-LESS (no default chord is
    /// bound), so unlike the chorded actions the MENU Button is its primary entry — the app
    /// threads `chrome.togglePin()` here so the row is live. `nil` keeps it a graceful no-op via `route`,
    /// never a dead menu item.
    var togglePinWindow: (() -> Void)?
    /// E19 / WI-4: whether the window is currently PINNED — drives the View ▸ Pin Window row's ✓ (Pin
    /// Window is a CHECKABLE toggle, ES-E2-3). Read from the live `chrome.pinned` at the scene's `.commands`
    /// site so the row re-renders its checkmark when the pin flips from the menu / palette / a bound chord.
    var pinWindowOn = false
    /// E3 WI-4 (audit fix): the Window ▸ Close Window actuator (⌘⇧W). A macOS `NSWindow.performClose`
    /// concern, so the app threads `window.performClose(nil)` here (which fires the native `windowShouldClose`
    /// → the existing window-close confirmation gate). `nil` falls back to the store's confirmation park in
    /// `route` — never a dead menu row, but the closure is what makes the menu item actually CLOSE the window.
    var closeWindow: (() -> Void)?

    var body: some Commands {
        // One top-level menu per display category, in the registry's display order. A `CommandMenu` inserts
        // a brand-new top-level menu (after the app's standard menus) — the workspace's own action verbs.
        //
        // `CommandsBuilder` has NO `ForEach` (unlike `ViewBuilder`): `ForEach` is a `View`, not `Commands`, so
        // the category fan-out is UNROLLED here over the fixed `WorkspaceAction.Category.allCases`. The rows
        // stay registry-driven — `commandMenu(for:)` reads each category's bindings out of the single
        // `groupedForDisplay` table — so adding a category there still requires a line here, but the binding
        // set per menu never drifts from the cheat sheet / palette.
        commandMenu(for: .panes)
        commandMenu(for: .tabs)
        commandMenu(for: .focus)
        commandMenu(for: .view)
    }

    /// One top-level `CommandMenu` for a display category, its rows pulled from ``WorkspaceBindingRegistry``'s
    /// ``WorkspaceBindingRegistry/groupedForDisplay`` (the single source the cheat sheet + palette also read).
    /// A category with no bindings yields an EMPTY menu body — harmless, and a future epic that adds the first
    /// binding to a now-empty section lights it up with no further wiring here.
    private func commandMenu(for category: WorkspaceAction.Category) -> some Commands {
        let rows = WorkspaceBindingRegistry.groupedForDisplay
            .first { $0.category == category }?.bindings ?? []
        return CommandMenu(category.rawValue) {
            ForEach(rows, id: \.id) { binding in
                menuItem(for: binding)
            }
        }
    }

    /// One menu row. The collapsed ⌘1…⌘9 "Select Tab" representative expands into a real submenu (the
    /// registry comment promises the menu "builds its own Select Tab submenu"); every other binding is a
    /// plain shortcut-LESS button that routes its action and shows its glyph as a trailing hint.
    @ViewBuilder
    private func menuItem(for binding: WorkspaceBinding) -> some View {
        if binding.id == WorkspaceBindingRegistry.selectTabRepresentative.id {
            Menu("Select Tab") {
                ForEach(WorkspaceBindingRegistry.selectTabBindings, id: \.id) { tab in
                    actionButton(tab)
                }
            }
        } else if binding.id == "view.pinWindow" {
            // E19 / WI-4: Pin Window is a CHECKABLE toggle — render it as a `Toggle` so the View menu
            // shows a ✓ while the window is pinned (a `Button` cannot show menu state). `isOn` reads the live
            // `pinWindowOn`; flipping it routes through the SAME chord-less `togglePinWindow` closure the
            // palette + a user-bound chord drive (no `.keyboardShortcut` — the menu-shortcutless rule holds).
            pinWindowToggle(binding)
        } else {
            actionButton(binding)
        }
    }

    /// The View ▸ Pin Window row as a checkable `Toggle` (ES-E2-3): the ✓ tracks the live `pinWindowOn`
    /// (`chrome.pinned`), and toggling it routes through `togglePinWindow`. Carries NO `.keyboardShortcut`
    /// (Pin Window is chord-less; the menu-shortcutless rule forbids one here regardless).
    private func pinWindowToggle(_ binding: WorkspaceBinding) -> some View {
        Toggle(menuTitle(for: binding), isOn: Binding(
            get: { pinWindowOn },
            set: { _ in togglePinWindow?() },
        ))
        .disabled(binding.action.requiresActivePane && activePaneID == nil)
    }

    /// A shortcut-LESS button that dispatches `binding.action` through the shared registry routing. The
    /// glyph (if any) is appended to the title as a hint — NOT a `.keyboardShortcut` (that would let the
    /// menu fire the chord, double-firing with the `NSEvent` monitor / swallowing a prefix follow-up).
    private func actionButton(_ binding: WorkspaceBinding) -> some View {
        Button(menuTitle(for: binding)) {
            WorkspaceBindingRegistry.route(
                binding.action,
                to: store,
                togglePalette: togglePalette,
                toggleCheatSheet: toggleCheatSheet,
                toggleFind: toggleFind,
                togglePeekReply: togglePeekReply,
                toggleSidebar: toggleSidebar,
                toggleGlobalSearch: toggleGlobalSearch,
                toggleJumpTo: toggleJumpTo,
                openQuickly: openQuickly,
                togglePinWindow: togglePinWindow,
                closeWindow: closeWindow,
            )
        }
        // Grey the item out when its action needs an active pane and there is none (mirrors the palette /
        // cheat-sheet enablement) — read off the store's tree so the menu reflects live state.
        .disabled(binding.action.requiresActivePane && activePaneID == nil)
    }

    /// The row title, with the chord glyph appended as a plain-text hint when the binding has one. We do
    /// NOT use `.keyboardShortcut`, so the glyph would otherwise be invisible — appending it keeps the menu
    /// a faithful cheat sheet (e.g. "Split Right  ⌘D") without binding the key.
    private func menuTitle(for binding: WorkspaceBinding) -> String {
        guard let glyph = WorkspaceBindingRegistry.glyph(for: binding.action) else { return binding.title }
        return "\(binding.title)  \(glyph)"
    }

    /// The active pane id (drives item enablement). `nil` when no pane is focused.
    private var activePaneID: PaneID? {
        store.tree.activeSession?.activeTab?.activePane
    }
}
#endif
