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

    public init() {}

    public var body: some Commands {
        // REPLACE the default File > New Window (⌘N): in a one-window canvas app a second window is
        // never what ⌘N means — it now creates panes, per kind. ⌘N mirrors ⌘T (the Pane-menu alias)
        // for terminals; ⇧⌘N / ⌥⌘N create the other kinds directly (every prior creation path was
        // Terminal-only).
        CommandGroup(replacing: .newItem) {
            commandButton("New Pane", .newPaneDefault)
            Divider()
            commandButton("New Terminal Pane", .newPane(.terminal))
            commandButton("New Claude Code Pane", .newPane(.claudeCode))
            commandButton("New Remote Window Pane", .newPane(.remoteGUI))
            Divider()
            commandButton("Duplicate Pane", .duplicatePane)
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
                .keyboardShortcut("k", modifiers: .command)
                .disabled(paletteToggle == nil)
            Button("Keyboard Shortcuts") { cheatSheetToggle?.toggle() }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(cheatSheetToggle == nil)
            Divider()
            // The canvas interaction prefs, surfaced app-globally for discoverability — the SAME
            // @AppStorage keys the per-pane pill menu toggles, so the two surfaces cannot drift.
            // Bound Toggles render as native checkmarked menu items.
            SnapPreferenceToggles()
        }
        // The Pane menu reads as a workspace-level menu alongside the OS chrome. `CommandMenu`'s
        // trailing closure is a `@ViewBuilder` (Buttons + Dividers), not nested `Commands` — every
        // Button funnels its `WorkspaceCommand` through `apply(_:to:)`.
        CommandMenu("Pane") {
            paneMenu
        }
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
        // Named layout presets: switch to a saved canvas, or snapshot the current one.
        Menu("Layouts") {
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
