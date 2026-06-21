#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - WorkspaceCommands (native menu-bar / hardware-keyboard shortcuts)

/// The native command surface for the workspace: a `Pane` menu whose every item is
/// a `.keyboardShortcut`-decorated `Button` that builds a ``WorkspaceCommand`` and applies it — via
/// the one tested `apply(_:to:)` free function — to the focused scene's ``WorkspaceStore`` (docs/22
/// §5). This is the *thin adapter* the architecture calls for: it owns no logic, it maps a menu
/// click / shortcut onto the same pure command enum the ``CommandInterpreter`` produces and the
/// compact on-screen affordances emit.
///
/// ### The conflict rule, expressed in shortcuts (load-bearing — docs/22 §5)
/// Every shortcut here is ⌘- or ⌥-prefixed, mirroring ``CommandInterpreter/defaultBindings`` exactly
/// — because each item *derives* its shortcut from that table rather than re-declaring the chord by
/// hand (one source of truth). That is what lets plain keys and Ctrl-letters fall through to the
/// focused terminal untouched (`TerminalInputHost.encode` returns `nil` for ⌘/⌥ combos): the menu
/// bar claims a chord only when it carries ⌘ or ⌥, so the shell keeps every bare key. Focus-move is
/// ⌥⌘+arrows specifically because the plain arrows belong to the shell. There is no bare-key shortcut
/// anywhere in this file.
///
/// ### One surface, two platforms
/// On macOS this renders as menu-bar menus. On iPadOS the same `Commands` drive the hardware-keyboard
/// shortcut HUD (hold ⌘) and the discoverability list — so the iPad gets the identical command
/// surface for free, with no separate `UIKeyCommand` table to keep in sync.
///
/// ### Targeting the active window
/// Items act on `@FocusedValue(\.workspaceStore)` — the store the key scene published via
/// `.publishingWorkspaceStore(_:)`. When no workspace window is key the value is `nil` and every item
/// disables itself, which is the native, correct grey-out.
///
/// Mount it on the `WindowGroup` scene: `WindowGroup { … }.commands { WorkspaceCommands() }`.
public struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceStore) private var store: WorkspaceStore?
    @FocusedValue(\.commandPaletteToggle) private var paletteToggle: CommandPaletteToggle?
    @FocusedValue(\.cheatSheetToggle) private var cheatSheetToggle: CommandPaletteToggle?
    @FocusedValue(\.peekReplyToggle) private var peekReplyToggle: CommandPaletteToggle?

    public init() {}

    public var body: some Commands {
        // REPLACE the default File > New Window (⌘N): in a one-window IDE app a second window is never
        // what ⌘N / ⌘T mean — they create tabs/panes. The LIVE IDE shell (`.tree`) routes through the
        // single ``WorkspaceBindingRegistry``; the retained-but-dead canvas keeps its ``WorkspaceCommand``
        // items so the canvas tests/menu stay intact.
        CommandGroup(replacing: .newItem) {
            if store?.liveModel == .canvas {
                commandButton("New Pane", .newPaneDefault)
                Divider()
                commandButton("New Terminal Pane", .newPane(.terminal))
                commandButton("New Remote Window Pane", .newPane(.remoteGUI))
                Divider()
                commandButton("Duplicate Pane", .duplicatePane)
            } else {
                actionButton("New Tab", .newTab)
                actionButton("New Session", .newSession)
                Divider()
                actionButton("Split Right", .splitRight)
                actionButton("Split Down", .splitDown)
                Divider()
                Button("Close Pane") {
                    guard let store else {
                        #if os(macOS)
                        NSApp.keyWindow?.performClose(nil)
                        #endif
                        return
                    }
                    WorkspaceBindingRegistry.route(.closePane, to: store)
                }
                .modifier(OptionalShortcut(WorkspaceBindingRegistry.resolvedChord(for: .closePane)?.shortcut))
                actionButton("Close Tab", .closeTab)
            }
        }
        #if os(macOS)
        // Portable workspace backup / share, next to the OS's import/export menu slot.
        CommandGroup(after: .importExport) {
            Button("Export Workspace…") { exportWorkspace() }
                .disabled(store == nil)
            Button("Import Workspace…") { importWorkspace(mode: .replace) }
                .disabled(store == nil)
            Button("Merge Workspace from File…") { importWorkspace(mode: .mergeAppend) }
                .disabled(store == nil)
        }
        #endif
        // Surface the ⌘K command palette as a VISIBLE menu item in the View menu (it was a hidden
        // background button — the chord worked but nothing advertised it). Routed through the focused
        // scene's toggle so it targets the key window; disabled when no workspace window is key.
        CommandGroup(after: .toolbar) {
            Button("Command Palette") { paletteToggle?.toggle() }
                .modifier(OptionalShortcut(WorkspaceBindingRegistry.resolvedChord(for: .commandPalette)?.shortcut))
                .disabled(paletteToggle == nil)
            Button("Keyboard Shortcuts") { cheatSheetToggle?.toggle() }
                .modifier(OptionalShortcut(WorkspaceBindingRegistry.resolvedChord(for: .cheatSheet)?.shortcut))
                .disabled(cheatSheetToggle == nil)
            actionButton("Toggle Sidebar", .toggleSidebar)
            // The canvas interaction prefs are inert on the tree shell — surface them only on the
            // retained-but-dead canvas (the SAME @AppStorage keys the per-pane pill menu toggles).
            if store?.liveModel == .canvas {
                Divider()
                SnapPreferenceToggles()
            }
        }
        // The Pane menu reads as a workspace-level menu alongside the OS chrome. `CommandMenu`'s
        // trailing closure is a `@ViewBuilder` (Buttons + Dividers), not nested `Commands`. The LIVE IDE
        // shell (`.tree`) renders the registry-driven tree menu; the canvas keeps its `apply(_:to:)` menu.
        CommandMenu("Pane") {
            if store?.liveModel == .canvas {
                paneMenu
            } else {
                treePaneMenu
            }
        }
    }

    // MARK: - Tree pane menu (the LIVE IDE shell — every item routes through WorkspaceBindingRegistry)

    /// The IDE-shell `Pane` menu, every item sourced from + routed through the single
    /// ``WorkspaceBindingRegistry`` (so the chord glyph the menu shows can never drift from the chord that
    /// actually fires). Grouped panes / tabs / sessions / focus / view, with the ⌘1…⌘9 select-tab chords
    /// surfaced as a submenu.
    @ViewBuilder
    private var treePaneMenu: some View {
        actionButton("Split Right", .splitRight)
        actionButton("Split Down", .splitDown)
        actionButton("Break Pane to Tab", .breakPaneToTab)
        // Floating panes (zellij toggle-float / new floating pane). A registry binding fires ONLY via its
        // menu item (there is no NSEvent monitor — sync-input / jumpToAttention prove the pattern), so these
        // two menu items are what make ⌘⇧F / ⌃⌘F actually dispatch.
        actionButton("Float Pane", .toggleFloat)
        actionButton("New Floating Pane", .spawnFloating)
        actionButton("Rename Tab…", .renamePane) // ITEM B1: ⌘⇧R renames the active tab on the tree shell

        // Layouts (tmux/zellij select-layout): re-tile the active tab's panes into an algorithmic layout.
        // The five named presets are menu/palette-only (no chord); "Cycle Layout" carries ⌃⌘L. A registry
        // binding fires ONLY via its menu item (no NSEvent monitor — same as float / sync-input), so THIS
        // submenu is what makes ⌃⌘L actually dispatch; the "Cycle Layout" item is REQUIRED.
        Menu("Layouts") {
            actionButton("Even Horizontal", .applyLayout(.evenHorizontal))
            actionButton("Even Vertical", .applyLayout(.evenVertical))
            actionButton("Main Vertical", .applyLayout(.mainVertical))
            actionButton("Main Horizontal", .applyLayout(.mainHorizontal))
            actionButton("Tiled", .applyLayout(.tiled))
            Divider()
            actionButton("Cycle Layout", .cycleLayout)
        }

        Divider()

        actionButton("Focus Left", .focusLeft)
        actionButton("Focus Right", .focusRight)
        actionButton("Focus Up", .focusUp)
        actionButton("Focus Down", .focusDown)

        Divider()

        actionButton("New Tab", .newTab)
        actionButton("Next Tab", .nextTab)
        actionButton("Previous Tab", .prevTab)
        Menu("Select Tab") {
            ForEach(1...9, id: \.self) { n in
                actionButton("Tab \(n)", .selectTab(n))
            }
        }

        Divider()

        actionButton("New Session", .newSession)
        actionButton("Maximize Pane", .toggleZoom)
        // Sync Input to All Panes (⌘⇧I): fan every keystroke in the active tab to all its sibling panes
        // (zellij's ToggleActiveSyncTab). Sourced from the registry so the chord glyph + the fired chord
        // can't drift — and so the chord actually dispatches (a registry binding fires ONLY via this menu;
        // there is no NSEvent monitor). The live on/off state shows in the tab bar + pane status bar.
        actionButton("Sync Input to All Panes", .toggleSyncInput)
        // Jump to Pane Needing Attention (⌘⇧U, P3): focus the oldest pane that is blocked
        // (needsPermission) or done across all tabs/sessions — the supervision "take me to who needs me".
        actionButton("Jump to Pane Needing Attention", .jumpToAttention)
        // Peek & Reply (⌘⇧J, P4): open the inline overlay over the oldest blocked pane so the human ANSWERS
        // it without a context switch. Like Command Palette, this is a VIEW @State overlay reached through a
        // focused-scene toggle — NOT `apply(_:to:)` — so it routes through `peekReplyToggle`, not
        // `actionButton`. A registry binding fires ONLY via its menu item (no NSEvent monitor — same as
        // sync-input / jumpToAttention), so THIS item is what makes ⌘⇧J actually dispatch; it is REQUIRED.
        Button("Peek & Reply") { peekReplyToggle?.toggle() }
            .modifier(OptionalShortcut(WorkspaceBindingRegistry.resolvedChord(for: .peekAndReply)?.shortcut))
            .disabled(peekReplyToggle == nil)

        Divider()

        // WB2 Warp-style Blocks: the Command Navigator + jump-to-block prev/next, targeting the active
        // terminal pane (the chord glyph is registry-derived, so the menu + the fired chord can't drift).
        actionButton("Command Navigator", .commandNavigator)
        actionButton("Jump to Previous Block", .jumpPreviousBlock)
        actionButton("Jump to Next Block", .jumpNextBlock)
        // Copy Mode (P5b, ⌘⇧C): arm modal keyboard scrollback navigation over the active terminal pane. A
        // registry binding fires ONLY via its menu item (no NSEvent monitor — same as sync-input / float),
        // so THIS item is what makes ⌘⇧C actually dispatch; it is REQUIRED, not optional.
        actionButton("Copy Mode", .toggleCopyMode)
    }

    /// A menu `Button` for a tree ``WorkspaceAction`` that routes through ``WorkspaceBindingRegistry`` and
    /// derives its key equivalent from the SAME registry binding (so the displayed chord and the fired
    /// chord cannot drift). Disabled when no workspace store is key.
    private func actionButton(_ title: String, _ action: WorkspaceAction) -> some View {
        Button(title) {
            if let store { WorkspaceBindingRegistry.route(action, to: store) }
        }
        .disabled(store == nil)
        // W13: derive the shortcut from the OVERRIDE-AWARE resolution so a user rebind (Settings ▸
        // Keyboard Shortcuts → ``KeybindingPreferences``) updates the menu glyph + the fired chord
        // together. Empty overrides ⇒ the registry default (W6 behaviour unchanged).
        .modifier(OptionalShortcut(WorkspaceBindingRegistry.resolvedChord(for: action)?.shortcut))
    }

    // MARK: - Pane menu (tabs are gone — everything is on the single canvas)

    @ViewBuilder
    private var paneMenu: some View {
        // "New Pane" creates a terminal pane (the Pane-menu twin of File ▸ New Terminal Pane). It carries
        // NO explicit chord: ⌘T maps to `.newPane(.terminal)` in the bindings table, so the File-menu
        // "New Terminal Pane" item ALREADY shows + owns ⌘T (table-derived). Declaring ⌘T here too put the
        // same key-equivalent on two visible menu items, which AppKit arbitrates by dispatching to one and
        // leaving the other's ⌘T glyph a decoy. (The stale prior comment claimed ⌘N lived on the File item,
        // but ⌘N now maps to `.newPaneDefault`.) `CommandInterpreterTests` pins ⌘T → `.newPane(.terminal)`.
        Button("New Pane") {
            if let store { apply(.newPane(.terminal), to: store) }
        }
        .disabled(store == nil)
        commandButton("New Group", .newGroup)
        // Explicit "Group Selected Panes" — disabled until ≥1 pane is multi-selected (⌃⌘G also groups the
        // selection when there is one). Carries the ⌥⌘G hint from the bindings table like every other item.
        Button("Group Selected Panes") {
            if let store { apply(.groupSelection, to: store) }
        }
        .disabled(store == nil || (store?.selectedPanes.isEmpty ?? true))
        .modifier(OptionalShortcut(Self.shortcut(for: .groupSelection)))
        commandButton("Select All Panes", .selectAllPanes)

        Divider()

        commandButton("Focus Left", .focus(.left))
        commandButton("Focus Right", .focus(.right))
        commandButton("Focus Up", .focus(.up))
        commandButton("Focus Down", .focus(.down))

        Divider()

        commandButton("Cycle Forward", .cycleFocus(forward: true))
        commandButton("Cycle Back", .cycleFocus(forward: false))

        Divider()

        commandButton("Center on Pane", .centerFocusedPane)
        commandButton("Center on All", .centerAll)
        commandButton("Tidy Layout", .tidy)
        arrangeMenu

        Divider()

        commandButton("Maximize Pane", .toggleZoom)
        commandButton("Overview", .toggleOverview)
        commandButton("Broadcast Input", .toggleBroadcast)
        commandButton("Manage Snippets…", .manageSnippets)
        commandButton("Rename Pane…", .renamePane)
        // Recovery affordance: surface "Reconnect Pane" in the menu bar (it was palette-only +
        // keyless, so a failed/dropped pane had no discoverable in-place recovery).
        commandButton("Reconnect Pane", .reconnectPane)
        commandButton("Close Pane", .closePane)
        commandButton("Reopen Closed Pane", .reopenClosedPane)

        Divider()

        // Viewport bookmarks: recall items are titled with the LIVE bookmark name (the focused
        // pane's title at save time) and disabled while their slot is empty; save items always
        // overwrite. The chords (⌘n / ⇧⌘n) derive from the bindings table like every other item.
        // Named layout presets: switch to a saved canvas, or snapshot the current one. Titled "Saved
        // Layouts" so it never collides with the LIVE `.tree` shell's "Layouts" re-tile submenu (the two
        // shells are mutually exclusive, but distinct titles keep the grep / revival clear).
        Menu("Saved Layouts") {
            Button("Save Current Layout…") {
                if let store { apply(.saveLayout, to: store) }
            }
            .disabled(store == nil)
            if let store, !store.layoutPresetNames.isEmpty {
                Divider()
                ForEach(store.layoutPresetNames, id: \.self) { name in
                    Button("Switch to “\(name)”") { store.switchToLayoutPreset(name: name) }
                }
                Divider()
                Menu("Delete Layout") {
                    ForEach(store.layoutPresetNames, id: \.self) { name in
                        Button(name, role: .destructive) { store.deleteLayoutPreset(name: name) }
                    }
                }
            }
        }

        Menu("Bookmarks") {
            ForEach(1..<10, id: \.self) { n in
                Button(store?.workspace.bookmarks[n].map { "Go to \($0.name)" } ?? "Go to Bookmark \(n)") {
                    if let store { apply(.recallBookmark(n), to: store) }
                }
                .disabled(store?.workspace.bookmarks[n] == nil)
                .modifier(OptionalShortcut(Self.shortcut(for: .recallBookmark(n))))
            }
            Divider()
            ForEach(1..<10, id: \.self) { n in
                Button("Save Bookmark \(n)") {
                    if let store { apply(.saveBookmark(n), to: store) }
                }
                .disabled(store == nil)
                .modifier(OptionalShortcut(Self.shortcut(for: .saveBookmark(n))))
            }
        }
    }

    /// Align + distribute the Arrange targets (the multi-selection when ≥2 selected, else all panes).
    /// Routed through `apply(_:to:)` (no chords needed) so the verbs land in the ⌘K recents ring like
    /// every other action — the items disable when no store is key.
    private var arrangeMenu: some View {
        Menu("Arrange") {
            Button("Align Left") { if let store { apply(.align(.left), to: store) } }
            Button("Align Right") { if let store { apply(.align(.right), to: store) } }
            Button("Align Top") { if let store { apply(.align(.top), to: store) } }
            Button("Align Bottom") { if let store { apply(.align(.bottom), to: store) } }
            Button("Align Center Horizontally") { if let store { apply(.align(.centerHorizontal), to: store) } }
            Button("Align Center Vertically") { if let store { apply(.align(.centerVertical), to: store) } }
            Divider()
            Button("Distribute Horizontally") { if let store { apply(.distribute(horizontal: true), to: store) } }
            Button("Distribute Vertically") { if let store { apply(.distribute(horizontal: false), to: store) } }
        }
        .disabled(store == nil)
    }

    // MARK: - Item builder

    /// A menu `Button` that applies `command` to the focused store, disabled when no store is key.
    /// The keyboard shortcut is *derived* from ``CommandInterpreter/defaultBindings`` — the same
    /// reverse-lookup `CommandPaletteView.shortcutHint` uses — rather than hand-declared, so the menu
    /// and the interpreter can never drift apart. A command with no default chord simply gets no
    /// shortcut (the `nil` case is handled by ``OptionalShortcut``).
    private func commandButton(_ title: String, _ command: WorkspaceCommand) -> some View {
        Button(title) {
            if let store { apply(command, to: store) }
        }
        .disabled(store == nil)
        .modifier(OptionalShortcut(Self.shortcut(for: command)))
    }

    /// Reverse-looks-up the CANONICAL default chord bound to `command` (deterministic — see
    /// ``CommandInterpreter/defaultChords(for:)``; a command may carry alias chords) and converts it
    /// to a native `KeyboardShortcut`; `nil` when `command` has no default binding.
    private static func shortcut(for command: WorkspaceCommand) -> KeyboardShortcut? {
        CommandInterpreter.defaultChords(for: command).first?.shortcut
    }

    #if os(macOS)
    /// Writes a portable workspace document (host stripped) to a user-chosen file.
    private func exportWorkspace() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "workspace.aislopdesk.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.exportWorkspaceData().write(to: url)
    }

    /// Reads a workspace document and applies it in `mode` (replace the canvas, or merge its panes in
    /// beside the current ones), keeping the local host. A non-document file is silently ignored (the
    /// store's import returns false and leaves the workspace intact).
    private func importWorkspace(mode: WorkspaceStore.WorkspaceImportMode) {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        _ = store.importWorkspace(data, mode: mode)
    }
    #endif
}

// MARK: - Snap preference toggles (View menu)

/// The canvas smart-snap / grid prefs as menu Toggles. A tiny standalone view so the `@AppStorage`
/// bindings live in a `View` context (a `Commands` struct cannot host them directly); the keys are
/// shared verbatim with ``PaneMenuView``'s in-popover toggles and ``CanvasItemView``/``CanvasView``'s
/// consumers. On macOS, hold ⌘ during a drag for a one-off bypass.
private struct SnapPreferenceToggles: View {
    @AppStorage(SettingsKey.snapPanes) private var snapPanes = true
    @AppStorage(SettingsKey.snapGrid) private var snapGrid = true
    @AppStorage(SettingsKey.showGrid) private var showGrid = true
    @AppStorage(SettingsKey.nonOverlap) private var nonOverlap = true

    var body: some View {
        Toggle("Snap to Panes", isOn: $snapPanes)
        Toggle("Snap to Grid", isOn: $snapGrid)
        Toggle("Show Grid", isOn: $showGrid)
        Toggle("Keep Windows From Overlapping", isOn: $nonOverlap)
    }
}

// MARK: - Optional shortcut

/// Applies a `KeyboardShortcut` only when one is present — `.keyboardShortcut(_:)` has no nil-taking
/// overload, so this `ViewModifier` branches on the optional. Lets ``WorkspaceCommands`` derive every
/// shortcut from the bindings table while gracefully handling a command that has no default chord.
private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyboardShortcut?

    init(_ shortcut: KeyboardShortcut?) { self.shortcut = shortcut }

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}
#endif
