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

    /// Whether the app has connected at least once this launch. The canvas (and its panes' auto-connect
    /// `.task`s) only MOUNT after the first successful connect — otherwise a pane behind the gate would
    /// open a channel and build the shared mux WITHOUT the gate's pin, leaving the gate stuck at
    /// `.disconnected`. Once mounted it STAYS mounted across later drops (the gate just overlays), so
    /// panes + their libghostty surfaces are preserved and only the per-channel reconnect runs.
    @State private var hasConnectedOnce = false

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
        .overlay { CommandPaletteView(store: store, isPresented: $showCommandPalette) }
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
        // Latch "connected at least once" so the canvas mounts on first connect and stays mounted across
        // later drops (panes preserved; the gate just overlays). Seed it now in case we launch connected.
        .onChange(of: connection.status) { _, _ in if isConnected { hasConnectedOnce = true } }
        .onAppear { if isConnected { hasConnectedOnce = true } }
        // Toggle the palette with ⌘K. The chord lives on the VISIBLE menu-bar "Command Palette" item
        // (``WorkspaceCommands``) — discoverable + scene-targeted — reached through this focused-scene
        // value rather than a hidden background button. A ⌘-prefixed chord obeys the §5 conflict rule
        // (the terminal never receives it), and `focusedSceneValue` keeps it reachable while a pane has
        // keyboard focus (exactly like `\.workspaceStore`).
        .focusedSceneValue(\.commandPaletteToggle, CommandPaletteToggle { showCommandPalette.toggle() })
    }

    // MARK: Detail (the ONE responsive switch — docs/22 §4)

    @ViewBuilder
    private var detail: some View {
        GeometryReader { geo in
            // ITEM #6: resolve the breakpoint against the OUTER WINDOW width on macOS (steadier than
            // the detail column mid-resize), falling back to this detail GeometryReader width when the
            // window width is unknown (always on iOS, where the size class stays primary).
            let compact = WorkspaceLayout.isCompact(
                horizontalSizeClassCompact: horizontalSizeClass == .compact,
                detailWidth: geo.size.width,
                windowWidth: windowWidth
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

    /// The window title: the focused pane's title, falling back to "Aislopdesk" when the canvas is empty.
    private var windowTitle: String {
        store.focusedPane.flatMap { store.workspace.canvas.spec(for: $0)?.title } ?? "Aislopdesk"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Panes", systemImage: "rectangle.dashed")
        } description: {
            Text("Add a pane to get started.")
        } actions: {
            Button("New Pane") { store.addPane(kind: .terminal) }
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
                Label(connection.status.label, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(PaneConnectionStatus.from(connection.status).color)
            }
            .help("Connection: \(connection.target.host) — \(connection.status.label)")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { store.addPane(kind: .terminal) } label: {
                    Label("Terminal", systemImage: PaneLeafView.icon(for: .terminal))
                }
                Button { store.addPane(kind: .claudeCode) } label: {
                    Label("Claude Code", systemImage: PaneLeafView.icon(for: .claudeCode))
                }
                Button { store.addPane(kind: .remoteGUI) } label: {
                    Label("Remote Window", systemImage: PaneLeafView.icon(for: .remoteGUI))
                }
            } label: {
                Label("New Pane", systemImage: "plus")
            } primaryAction: {
                store.addPane(kind: .terminal)
            }
            .help("New pane")
        }
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

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
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
            guard let window else { width.wrappedValue = nil; return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            publish(window)
        }

        /// Removes the observer (called on dismantle / before re-scoping) so the reader never leaks.
        func stop() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
        }

        @objc private func windowDidResize(_ note: Notification) {
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
