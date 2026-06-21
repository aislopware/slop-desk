#if canImport(SwiftUI)
import SwiftUI

// MARK: - WorkspaceRootView (the native shell)

/// The root of the workspace UI: a `NavigationSplitView` whose sidebar is the tab rail
/// (``TabSidebarView``) and whose detail is the active tab's pane area (docs/22 §1.3, §4).
///
/// `NavigationSplitView` is the responsive spine (docs/22 §4): it gives the native macOS source-list
/// sidebar + detail for free on regular width, and collapses the sidebar into the navigation stack
/// on compact width. The ONLY size-class adaptation switch in the whole app lives in ``detail`` — it
/// computes `WorkspaceLayout.isCompact(...)` once and branches:
/// - **regular** → the ``CanvasView``: the tab's pan-only infinite canvas (free-floating panes,
///   drag-to-move, resize, maximize, multi-pane — docs/30).
/// - **compact** → the ``PaneCarouselView``: the SAME canvas projected to one swipeable pane at a time
///   (a tiny-pane plane is unusable on a phone — docs/30 §6.6). The flip is view-only: it swaps the
///   projection without calling `reconcile()`, dropping focus, or tearing down sessions.
///
/// It also publishes its store as the focused scene value (so the menu-bar / iPad ``WorkspaceCommands``
/// target THIS window — docs/22 §5) and hosts the ⌘K ``CommandPaletteView`` overlay.
///
/// The shell carries the macOS minimum size (`minWidth: 720`, `minHeight: 480`) so the floor lives on
/// the WINDOW, never on the pane views (docs/22 §3).
public struct WorkspaceRootView: View {
    @Bindable var store: WorkspaceStore
    /// The ONE app-global connection (docs/31): drives the modal connect-gate + the toolbar status.
    @Bindable var connection: AppConnection
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Reduce-Motion gate for the connection-gate appear/dismiss fade.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The sidebar's visibility — `.automatic` by default (the system shows sidebar + detail on regular
    /// width and collapses on compact). Bound so the toolbar's sidebar toggle and the compact collapse
    /// both work natively. The compact carousel's "show tabs" affordance flips this to `.all` to reveal
    /// the tab drawer.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Whether the ⌘K command palette is presented (docs/22 §5). Window-level UI state: the palette is
    /// overlaid on the whole shell and toggled by the ⌘K chord below — a ⌘-prefixed shortcut, so the
    /// focused terminal never sees it (the §5 conflict rule). `false` ⇒ the overlay renders an empty,
    /// zero-cost branch.
    @State private var showCommandPalette = false

    /// Whether the ⌘/ keyboard-shortcut cheat sheet is presented. Window-level UI state like the palette;
    /// a ⌘-prefixed chord, so the focused terminal never sees it (the §5 conflict rule).
    @State private var showCheatSheet = false

    /// Whether the ⌘⇧J Peek & Reply overlay (P4) is presented. Window-level `@State` like the palette/cheat
    /// sheet — NOT store state (so it never re-mounts the tree); a ⌘-prefixed chord obeys the §5 rule, and
    /// the Pane-menu item flips it through the `peekReplyToggle` focused-scene value below.
    @State private var showPeekReply = false

    /// Whether the app has connected at least once this launch. The canvas (and its panes' auto-connect
    /// `.task`s) only MOUNT after the first successful connect — otherwise a pane behind the gate would
    /// open a channel and build the shared mux WITHOUT the gate's pin, leaving the gate stuck at
    /// `.disconnected`. Once mounted it STAYS mounted across later drops (the gate just overlays), so
    /// panes + their libghostty surfaces are preserved and only the per-channel reconnect runs.
    @State private var hasConnectedOnce = false

    /// The in-flight "Save Current Layout…" name being typed (the alert's TextField binding).
    @State private var saveLayoutName: String = ""
    /// The optional trigger-app name for the layout being saved (auto-switch on host app launch).
    @State private var saveLayoutTriggerApp: String = ""

    /// The OUTER WINDOW's width on macOS, fed by ``WindowWidthReader`` (ITEM #6). `nil` until the
    /// reader observes a window (and always `nil` on iOS, which keeps its size-class-primary decision):
    /// the breakpoint then falls back to the detail GeometryReader width. Keying the macOS breakpoint
    /// on the whole window — not the detail column — avoids a transient mid-resize collapse when the
    /// `NavigationSplitView` reports a partially laid-out detail width.
    @State private var windowWidth: CGFloat?

    public init(store: WorkspaceStore, connection: AppConnection) {
        self.store = store
        self.connection = connection
    }

    public var body: some View {
        shell
            // LIVE-SCALE FIX (P1): inject the @Observable DSScale ONCE here, at the very top of the chain —
            // strictly ABOVE the `shell` switch (SplitWorkspaceView vs the dead canvas NavigationSplitView) and
            // therefore above the SplitTreeView no-teardown ZStack + its `ForEach(tab.allPaneIDs())` mount
            // loop. SwiftUI inherits the environment downward, so every `dsFont`/`dsSpace` modifier reads
            // @Environment(DSScale.self) and repaints on a density change. Placed above the macOS frame/window
            // readers so it scopes the WHOLE tree, never inside a mount loop (zero edits to SplitTreeView /
            // the hostedTabs ZStack). This replaces the dead UIScale notification path (no view subscribed).
            .environment(DSScale.shared)
            // P5: inject DSThemeStore alongside DSScale so the `.dsFrame(height:)` chrome heights (TabBar /
            // PaneStatusBar) reflow LIVE on a density TIER flip — the height VALUE comes from the tier
            // (DSThemeStore.density.<height>), which DSScale's multiplier alone cannot carry. Same injection
            // point (strictly ABOVE the shell switch + the SplitTreeView no-teardown mount loop), so a tier
            // flip is a pure geometry repaint that never changes the leaf PaneID set / tears down a surface.
            .environment(DSThemeStore.shared)
        #if os(macOS)
            .frame(minWidth: 720, minHeight: 480)
            // ITEM #6: observe the outer window's width so the compact breakpoint keys on the whole window,
            // not the detail column. A zero-size background reader; iOS keeps its size-class-primary path
            // (no reader, `windowWidth` stays nil).
            .background(WindowWidthReader(width: $windowWidth))
        #endif
            // Publish the store so the scene-level ``WorkspaceCommands`` (menu bar / iPad ⌘-HUD) resolve
            // THIS window's store via `@FocusedValue(\.workspaceStore)` — one window today, the key window
            // automatically with multi-window later (docs/22 §5).
            .publishingWorkspaceStore(store)
            // The ⌘K command palette overlay (docs/22 §5): a Spotlight-style floating card with its own
            // dimming backdrop, top-third placement. An unconditional overlay because the view renders an
            // empty branch when hidden (zero cost) — and an overlay, not a `.sheet`, so it owns its own
            // backdrop + placement rather than fighting sheet chrome.
            // The ⌘K palette + ⌘/ cheat-sheet overlays, in their own modifier so the root body's chain stays
            // inside the Swift type-checker's budget. Both render an empty branch when hidden (zero cost).
            .modifier(WorkspaceOverlayModals(
                store: store,
                showPalette: $showCommandPalette,
                showCheatSheet: $showCheatSheet,
                showPeekReply: $showPeekReply,
            ))
            // The app-global connect-gate (docs/31): a modal over the WHOLE shell — including the sidebar +
            // palette — whenever the one connection is not `.connected`. Placed here (above the regular↔compact
            // switch in `detail`) so a projection flip never re-mounts it. The canvas is unusable until
            // connected; on a mid-session drop it reappears ("reconnecting…") and auto-dismisses on recovery.
            .overlay {
                if !isConnected {
                    ConnectionGateView(connection: connection)
                        .transition(.opacity)
                }
            }
            // The fade's missing driver: `.transition(.opacity)` alone pops without an animation tied to
            // the value that inserts/removes the gate. Value-scoped so nothing else animates off this.
            // P5 MOTION: DSMotion.appear (the gate fades in/out), Reduce-Motion-gated to the near-instant
            // crossfade so a motion-sensitive user gets an instant swap rather than the eased fade.
            .animation(DSMotion.resolve(DSMotion.appear, reduceMotion: reduceMotion), value: isConnected)
            // Latch "connected at least once" so the canvas mounts on first connect and stays mounted across
            // later drops (panes preserved; the gate just overlays). Seed it now in case we launch connected.
            .onChange(of: connection.status) { _, _ in if isConnected { hasConnectedOnce = true } }
            .onAppear { if isConnected { hasConnectedOnce = true } }
            // ⌘R with the sidebar column collapsed was a silent no-op (the rename field lives in the
            // sidebar). Reveal the rail first — Xcode's reveal-navigator-on-rename behaviour; the sidebar
            // acts on the still-pending request when it mounts.
            .onChange(of: store.pendingRename) { _, pending in
                if pending != nil { columnVisibility = .all }
            }
            // Toggle the palette with ⌘K. The chord lives on the VISIBLE menu-bar "Command Palette" item
            // (``WorkspaceCommands``) — discoverable + scene-targeted — reached through this focused-scene
            // value rather than a hidden background button. A ⌘-prefixed chord obeys the §5 conflict rule
            // (the terminal never receives it), and `focusedSceneValue` keeps it reachable while a pane has
            // keyboard focus (exactly like `\.workspaceStore`).
            .focusedSceneValue(\.commandPaletteToggle, CommandPaletteToggle { showCommandPalette.toggle() })
            .focusedSceneValue(\.cheatSheetToggle, CommandPaletteToggle { showCheatSheet.toggle() })
            // ⌘⇧J Peek & Reply (P4): toggle the inline-reply overlay. When already open it closes; when opening,
            // it opens unconditionally — the overlay resolves its own target on appear and shows a graceful
            // empty / read-only peek when nothing needs attention (so the chord is never a silent dead key).
            .focusedSceneValue(\.peekReplyToggle, CommandPaletteToggle { showPeekReply.toggle() })
            // The busy-shell close guard (store.pendingClose): ⌘W / a close affordance on a pane whose
            // shell is mid-command parks here instead of killing the command. The dialog reads the pane's
            // title at present-time; Cancel (the automatic dismiss) clears the pending id.
            .confirmationDialog(
                pendingCloseTitle,
                isPresented: Binding(
                    get: { store.pendingClose != nil },
                    set: { if !$0 { store.cancelPendingClose() } },
                ),
            ) {
                Button("Close Pane", role: .destructive) { store.confirmPendingClose() }
            } message: {
                Text("A command is still running in this pane. Closing it ends the session and the command.")
            }
            // "Save Current Layout…" name prompt (store.pendingSaveLayout). The TextField defaults to a
            // suggestion; an empty name is a no-op (saveLayoutPreset trims+guards).
            .alert("Save Layout", isPresented: Binding(
                get: { store.pendingSaveLayout },
                set: { if !$0 { store.clearSaveLayoutRequest() } },
            )) {
                TextField("Layout name", text: $saveLayoutName)
                TextField("Auto-switch when this host app launches (optional)", text: $saveLayoutTriggerApp)
                Button("Save") {
                    store.saveLayoutPreset(name: saveLayoutName, triggerAppName: saveLayoutTriggerApp)
                    saveLayoutName = ""
                    saveLayoutTriggerApp = ""
                    store.clearSaveLayoutRequest()
                }
                Button("Cancel", role: .cancel) {
                    saveLayoutName = ""
                    saveLayoutTriggerApp = ""
                    store.clearSaveLayoutRequest()
                }
            } message: {
                Text(
                    """
                    Save the current panes, groups, and focus as a named layout you can switch back to. \
                    Optionally bind it to a host app so it switches in automatically when that app launches.
                    """,
                )
            }
            // Snippet sheets (value-entry + manager) live in their own modifier so the root body's modifier
            // chain stays inside the Swift type-checker's budget.
            .modifier(SnippetModals(store: store))
    }

    // MARK: Shell (W5 — the IDE split shell vs the retained-but-dead canvas shell)

    /// The workspace shell. W5 cutover: when the store's live model is ``WorkspaceStore/LiveModel/tree``
    /// (the app) it is the new IDE ``SplitWorkspaceView`` (sessions sidebar + tab bar + recursive split
    /// content); otherwise the retained-but-dead canvas ``NavigationSplitView`` (so the canvas views keep
    /// compiling + the old tests render). The shared overlays (connect-gate, ⌘K palette, dialogs, snippet
    /// modals, `publishingWorkspaceStore`) wrap WHICHEVER shell — they live below on the `body` chain.
    @ViewBuilder
    private var shell: some View {
        switch store.liveModel {
        case .tree:
            // W5 Muxy cutover: the IDE shell is now self-contained (its own hand-built HStack skeleton +
            // hidden-title-bar window foundation via `WindowConfigurator`), NOT wrapped in this view's
            // `NavigationSplitView`. The old `.toolbar { detailToolbar }` host is gone — its affordances
            // (new tab / split / new session) now live in the shell's tab strip + sessions sidebar, and the
            // app-global connection control moved into the sidebar. The shared overlays (connect-gate, ⌘K
            // palette, dialogs, snippet modals, `publishingWorkspaceStore`) still wrap this from `body`.
            SplitWorkspaceView(store: store)
        case .canvas:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                PaneSidebarView(store: store)
                #if os(macOS)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
                #endif
            } detail: {
                detail
                    .toolbar { detailToolbar }
                    .navigationTitle(windowTitle)
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
            }
        }
    }

    /// The busy-close dialog title, naming the pane it would close (best-effort — falls back to a
    /// generic title if the pane vanished while the dialog was up).
    private var pendingCloseTitle: String {
        // ITEM A1: resolve the spec from the LIVE model (tree or canvas) so the dialog names the leaf it
        // would close on the IDE shell too — the old canvas-only lookup returned a generic title under .tree.
        if let id = store.pendingClose, let spec = store.pendingCloseSpec {
            return "Close “\(PanePresentation.displayTitle(store.handle(for: id), spec: spec))”?"
        }
        return "Close Pane?"
    }

    // MARK: Detail (the ONE responsive switch — docs/22 §4)

    private var detail: some View {
        GeometryReader { geo in
            // ITEM #6: resolve the breakpoint against the OUTER WINDOW width on macOS (steadier than
            // the detail column mid-resize), falling back to this detail GeometryReader width when the
            // window width is unknown (always on iOS, where the size class stays primary).
            let compact = WorkspaceLayout.isCompact(
                horizontalSizeClassCompact: horizontalSizeClass == .compact,
                detailWidth: geo.size.width,
                windowWidth: windowWidth,
            )

            Group {
                if !hasConnectedOnce {
                    // Pre-first-connect: render nothing (the gate covers the whole shell). Mounting the
                    // canvas here would fire the panes' auto-connect and build the mux without the pin.
                    Color.clear
                } else if !store.workspace.canvas.items.isEmpty {
                    if compact {
                        // Compact (iPhone / iPad-compact): the SAME canvas projected to one swipeable
                        // pane at a time (docs/22 §4). The carousel's "show panes" reveals the shell
                        // sidebar by flipping `columnVisibility`. A regular↔compact flip swaps ONLY
                        // this branch — view-only, no reconcile / focus drop / session teardown.
                        PaneCarouselView(store: store, onShowSidebar: { columnVisibility = .all })
                    } else {
                        CanvasView(store: store)
                    }
                } else {
                    emptyState
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(.background)
    }

    /// Whether the app-global connection is up (gate dismissed, canvas usable).
    private var isConnected: Bool {
        if case .connected = connection.status { return true }
        return false
    }

    /// The window title: the focused pane's LIVE title (OSC 0/2 when the shell set one — same source
    /// as the pill and the sidebar rows), falling back to "Aislopdesk" when the canvas is empty.
    private var windowTitle: String {
        guard let id = store.focusedPane, let spec = store.workspace.canvas.spec(for: id) else {
            return "Aislopdesk"
        }
        return PanePresentation.displayTitle(store.handle(for: id), spec: spec)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Panes", systemImage: "rectangle.dashed")
        } description: {
            Text("Add a pane to get started.")
        } actions: {
            Button("New Pane") { store.addPane(kind: SettingsKey.defaultPaneKind) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // App-global connection status + disconnect (docs/31): one host-level affordance, distinct from
        // the per-pane channel dots. A menu so the host is visible and Disconnect re-shows the gate.
        ToolbarItem(placement: .navigation) {
            Menu {
                Text("\(connection.target.host):\(String(connection.target.port))")
                Divider()
                Button("Disconnect", role: .destructive) { Task { await connection.disconnect() } }
            } label: {
                Label(ConnectionPresenter.shortLabel(for: connection.status), systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(PaneConnectionStatus.from(connection.status).color)
            }
            .help("Connection: \(connection.target.host) — \(ConnectionPresenter.headline(for: connection.status))")
        }
        ToolbarItem(placement: .primaryAction) {
            switch store.liveModel {
            case .tree:
                // The IDE shell: the primary "+" opens a new TAB; the menu offers split / new session.
                Menu {
                    Button { store.newTab(kind: SettingsKey.defaultPaneKind) } label: {
                        Label("New Tab", systemImage: "plus.rectangle.on.rectangle")
                    }
                    if let active = store.tree.activeSession?.activeTab?.activePane {
                        Button { store.splitPaneTree(active, axis: .horizontal, kind: SettingsKey.defaultPaneKind)
                        } label: {
                            Label("Split Right", systemImage: "rectangle.split.2x1")
                        }
                        Button { store.splitPaneTree(active, axis: .vertical, kind: SettingsKey.defaultPaneKind)
                        } label: {
                            Label("Split Down", systemImage: "rectangle.split.1x2")
                        }
                    }
                    Divider()
                    Button { store.newSession(name: "Local", kind: SettingsKey.defaultPaneKind) } label: {
                        Label("New Session", systemImage: "square.stack.3d.up")
                    }
                } label: {
                    Label("New Tab", systemImage: "plus")
                } primaryAction: {
                    store.newTab(kind: SettingsKey.defaultPaneKind)
                }
                .help("New tab")
            case .canvas:
                Menu {
                    Button { store.addPane(kind: .terminal) } label: {
                        Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
                    }
                    Button { store.addPane(kind: .remoteGUI) } label: {
                        Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
                    }
                } label: {
                    Label("New Pane", systemImage: "plus")
                } primaryAction: {
                    store.addPane(kind: SettingsKey.defaultPaneKind)
                }
                .help("New pane")
            }
        }
    }
}

// MARK: - WorkspaceOverlayModals (the ⌘K palette + ⌘/ cheat-sheet overlays, factored off the root chain)

/// Hosts the two floating overlays as a `ViewModifier` so ``WorkspaceRootView``'s body stays inside the
/// Swift type-checker's per-expression budget (the same reason ``SnippetModals`` exists). Both views
/// render nothing when their binding is false.
private struct WorkspaceOverlayModals: ViewModifier {
    let store: WorkspaceStore
    @Binding var showPalette: Bool
    @Binding var showCheatSheet: Bool
    @Binding var showPeekReply: Bool
    /// Reduce-Motion gate for the three overlay appear/dismiss drivers.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay { CommandPaletteView(store: store, isPresented: $showPalette) }
            .overlay { KeyboardCheatSheetView(isPresented: $showCheatSheet, liveModel: store.liveModel) }
            // P4 Peek & Reply (⌘⇧J): an inline-reply glass card over the oldest blocked pane. Empty branch
            // when hidden (zero cost), so an unconditional overlay is cheap — like the palette.
            .overlay { PeekReplyView(store: store, isPresented: $showPeekReply) }
            // P5 MOTION: the overlay appear/dismiss drivers route through DSMotion.appear, Reduce-Motion-
            // gated to the near-instant crossfade (so the scale/translate entrance never plays for a
            // motion-sensitive user). Each is value-scoped so nothing else animates off these flags.
            .animation(DSMotion.resolve(DSMotion.appear, reduceMotion: reduceMotion), value: showPalette)
            .animation(DSMotion.resolve(DSMotion.appear, reduceMotion: reduceMotion), value: showCheatSheet)
            .animation(DSMotion.resolve(DSMotion.appear, reduceMotion: reduceMotion), value: showPeekReply)
    }
}

// MARK: - SnippetModals (the snippet value-entry + manager sheets, factored off the root chain)

/// Hosts the two snippet sheets as a single `ViewModifier` so ``WorkspaceRootView``'s body — already a
/// long chain of overlays / alerts / confirmation dialogs — stays comfortably inside the Swift
/// type-checker's per-expression budget (a chain this long otherwise trips "unable to type-check in
/// reasonable time"). No state of its own beyond the store it observes.
private struct SnippetModals: ViewModifier {
    @Bindable var store: WorkspaceStore

    func body(content: Content) -> some View {
        content
            // store.pendingSnippetRun: a parameterized snippet armed from ⌘K asks for its `{{slot}}`
            // values here BEFORE running, so `ssh {{user}}@{{host}}` is resolved rather than injected
            // literally. A no-placeholder snippet never reaches this (it ran already).
            .sheet(isPresented: Binding(
                get: { store.pendingSnippetRun != nil },
                set: { if !$0 { store.clearSnippetRunRequest() } },
            )) {
                if let id = store.pendingSnippetRun {
                    SnippetValuesSheet(store: store, snippetID: id)
                }
            }
            // store.snippetManagerPresented: create / edit / delete command macros. Until this existed
            // the snippet CRUD had no in-app caller — snippets could only be made by hand-editing the
            // workspace JSON. Reached from ⌘K / Pane ▸ Manage Snippets…
            .sheet(isPresented: Binding(
                get: { store.snippetManagerPresented },
                set: { if !$0 { store.dismissSnippetManager() } },
            )) {
                SnippetManagerView(store: store)
            }
    }
}

// MARK: - SnippetValuesSheet (resolve a parameterized snippet's placeholders before running)

/// Collects one value per `{{placeholder}}` a snippet references, shows a live preview of the
/// resolved command, then runs it. Presented by ``WorkspaceRootView`` whenever
/// ``WorkspaceStore/pendingSnippetRun`` is armed (a parameterized snippet was chosen from ⌘K).
///
/// Every placeholder gets a field seeded to "" so the expansion resolves ALL slots — no literal
/// `{{name}}` can leak to the shell (an intentionally-blank field expands to empty, which is a valid
/// value, e.g. an optional flag). The snippet may vanish mid-sheet (deleted elsewhere); the body
/// guards on that and dismisses.
private struct SnippetValuesSheet: View {
    let store: WorkspaceStore
    let snippetID: UUID

    /// One entry per placeholder name (seeded on appear), bound to the text fields.
    @State private var values: [String: String] = [:]
    /// Index-typed focus (NOT a Bool): one shared Bool can't represent "field N is focused" distinctly,
    /// so a `.focused($bool, equals: index == 0 ? true : bool)` self-reference focuses every field at once
    /// for ≥2 placeholders. An `Int?` focus gives correct first-field autofocus + Tab traversal.
    @FocusState private var focusedField: Int?

    private var snippet: Snippet? { store.snippets.first { $0.id == snippetID } }

    var body: some View {
        let snip = snippet
        let slots = snip?.placeholders ?? []
        // The command as it will actually be sent, given the current field values.
        let preview = snip.map { SnippetExpander.expand($0.body, values: filledValues(slots)).text } ?? ""

        return VStack(alignment: .leading, spacing: 14) {
            Text(snip.map { "Run “\($0.name)”" } ?? "Run Snippet")
                .font(.headline)

            if slots.isEmpty {
                Text("This snippet has no placeholders.").foregroundStyle(.secondary)
            } else {
                Form {
                    ForEach(Array(slots.enumerated()), id: \.element) { index, name in
                        TextField(name, text: Binding(
                            get: { values[name] ?? "" },
                            set: { values[name] = $0 },
                        ))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .focused($focusedField, equals: index)
                        .onSubmit(run)
                    }
                }
                .formStyle(.columns)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Will run").font(.caption2).foregroundStyle(.secondary)
                Text(preview.isEmpty ? "—" : preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { store.clearSnippetRunRequest() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(snip == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear {
            // Seed a field for every placeholder so the run resolves them all (no literal {{}} leaks).
            for name in slots where values[name] == nil { values[name] = "" }
            focusedField = 0
        }
    }

    /// The values dict guaranteed to contain every current slot (seeded blanks included), so
    /// `SnippetExpander.expand` never leaves a literal placeholder.
    private func filledValues(_ slots: [String]) -> [String: String] {
        var v = values
        for name in slots where v[name] == nil { v[name] = "" }
        return v
    }

    private func run() {
        guard let snip = snippet else { store.clearSnippetRunRequest()
            return
        }
        store.runSnippet(snip.id, values: filledValues(snip.placeholders))
        store.clearSnippetRunRequest()
    }
}

#if os(macOS)
import AppKit

// MARK: - WindowWidthReader (macOS outer-window geometry — ITEM #6)

/// A zero-size `NSViewRepresentable` that publishes the host `NSWindow`'s width into a binding so the
/// compact breakpoint can key on the OUTER WINDOW instead of the detail column (ITEM #6). The detail
/// `GeometryReader` width can momentarily report a partially laid-out `NavigationSplitView` mid-resize;
/// the window frame is authoritative and steadier.
///
/// It reads `view.window?.frame.width` once the view attaches to a window, and observes
/// `NSWindow.didResizeNotification` for that window to keep it current. The observer is scoped to the
/// specific window and **removed on `dismantleNSView`** (and re-scoped on `updateNSView` if the host
/// window changes) so it never leaks. All UI work runs on the main actor (the representable is
/// `@MainActor` by SwiftUI contract; the notification callback hops to the main actor before touching
/// the binding).
private struct WindowWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat?

    func makeCoordinator() -> Coordinator { Coordinator(width: $width) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached yet at make time; defer the first read + observer install to the
        // next runloop turn, when `view.window` is set.
        DispatchQueue.main.async { context.coordinator.observe(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The host window can change (window restoration / re-parenting); re-scope the observer + re-read.
        context.coordinator.observe(nsView.window)
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// `NSObject` so it can be the target of an `@objc` `didResizeNotification` selector — the same
    /// notification idiom ``TerminalInputResponderView`` uses for keyboard frames, which sidesteps the
    /// Sendable-closure hop a block-based observer would need. `didResizeNotification` is posted on the
    /// main thread, so the selector body is main-actor work; it is annotated `@MainActor`.
    @MainActor
    final class Coordinator: NSObject {
        private let width: Binding<CGFloat?>
        private weak var observedWindow: NSWindow?

        init(width: Binding<CGFloat?>) {
            self.width = width
            super.init()
        }

        /// Scopes the resize observer to `window` (a no-op if already observing it) and publishes the
        /// current width. Removing the prior observer first keeps exactly one live registration.
        func observe(_ window: NSWindow?) {
            guard window !== observedWindow else {
                publish(window)
                return
            }
            stop()
            observedWindow = window
            guard let window else { width.wrappedValue = nil
                return
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification,
                object: window,
            )
            publish(window)
        }

        /// Removes the observer (called on dismantle / before re-scoping) so the reader never leaks.
        func stop() {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResizeNotification, object: observedWindow,
            )
            observedWindow = nil
        }

        @objc
        private func windowDidResize(_ note: Notification) {
            publish(note.object as? NSWindow ?? observedWindow)
        }

        private func publish(_ window: NSWindow?) {
            let next = window?.frame.width
            if width.wrappedValue != next { width.wrappedValue = next }
        }
    }
}
#endif
#endif
