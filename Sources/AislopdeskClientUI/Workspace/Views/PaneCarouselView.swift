#if canImport(SwiftUI)
import SwiftUI

// MARK: - PaneCarouselView (the compact projection — docs/31)

/// The **compact** rendering of the single canvas: a paged `TabView` carousel that shows exactly ONE
/// pane at a time (an always-on zoom), swipeable between panes, with page-indicator dots. It is a pure
/// VIEW-time projection of the SAME canvas the regular ``CanvasView`` renders — an N-pane canvas opens
/// here as N swipeable pages, losslessly — so a regular↔compact flip is view-only: it must NOT call
/// `reconcile()`, drop focus, or tear down sessions (docs/22 §4). Nothing here mutates the canvas
/// shape; it only moves *focus*.
///
/// ### Selection is the focused pane (the binding is the whole contract)
/// `TabView`'s selection is BOUND to `workspace.focusedPane` through a computed `Binding`: reading it
/// returns the focused pane, writing it (a swipe / a dot tap) routes through `store.focus(_:)`. Focus
/// is therefore the single source of truth for "which page is showing" in both directions.
///
/// ### First-responder arbitration (BUG-E) + identity (docs/22 §7)
/// A `.page` `TabView` keeps adjacent pages ALIVE during a swipe, so compact can mount more than one
/// ``TerminalInputHost`` at a time — each page routes its host through the SAME ``PaneFocusCoordinator``
/// the canvas uses so only the focused page's host claims first responder. Each page carries
/// `.id(PaneID)` so SwiftUI never reuses a `GhosttySurface` / pipeline / input `Coordinator` across
/// panes or tears down the live session backing a page.
struct PaneCarouselView: View {
    /// The store: read for the canvas / pages / handles, written for focus + add-pane.
    @Bindable var store: WorkspaceStore

    /// Optional affordance to reveal the sidebar (the `NavigationSplitView` sidebar). The Integrate
    /// phase wires this to flip the shell's `NavigationSplitViewVisibility`; left `nil` the button is
    /// hidden (the native navigation chrome already exposes the sidebar on compact).
    var onShowSidebar: (() -> Void)?

    init(store: WorkspaceStore, onShowSidebar: (() -> Void)? = nil) {
        self.store = store
        self.onShowSidebar = onShowSidebar
    }

    private var canvas: Canvas { store.workspace.canvas }

    var body: some View {
        Group {
            if !canvas.items.isEmpty {
                content
            } else {
                emptyState
            }
        }
        .background(.background)
    }

    // MARK: Carousel

    @ViewBuilder
    private var content: some View {
        let pages = CompactLayoutResolver.pages(for: canvas)

        VStack(spacing: 0) {
            topBar(pages: pages)
            Divider()

            TabView(selection: focusBinding) {
                ForEach(pages, id: \.id) { page in
                    pageView(for: page)
                        .padding(8)
                        .tag(page.id)
                }
            }
            #if os(iOS)
            // Page style with dot indicators; one pane visible, horizontal swipe between panes.
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            #else
            // macOS narrow-window compact: TabView has no page style, but the SAME selection binding
            // keeps the focused pane showing. The top bar's prev/next + dots drive paging.
            .tabViewStyle(.automatic)
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One page: the focused-pane chrome + content, keyed by stable ``PaneID``. Every page renders as
    /// focused (it is the only visible pane — an always-on zoom).
    @ViewBuilder
    private func pageView(for page: CompactPage) -> some View {
        if let spec = canvas.spec(for: page.id) {
            PaneChromeView(
                id: page.id,
                spec: spec,
                handle: store.handle(for: page.id),
                isFocused: true,
                isZoomed: store.workspace.maximizedPane == page.id,
                store: store
            ) {
                PaneLeafView(
                    handle: store.handle(for: page.id),
                    spec: spec,
                    isFocused: true,
                    focusCoordinator: store.focusCoordinator,
                    store: store
                )
            }
            // Stable identity across swipes / reshape / a regular↔compact flip (docs/22 §4, §7): never
            // tear down or rewire the live session backing this page.
            .id(page.id)
            #if os(macOS)
            .tabItem { Text(spec.title) }
            #endif
        }
    }

    // MARK: Top bar (sidebar + add + page position)

    /// A slim top affordance: open the sidebar, a page-position chip, prev/next, and a `+` to add a pane.
    @ViewBuilder
    private func topBar(pages: [CompactPage]) -> some View {
        HStack(spacing: 10) {
            if let onShowSidebar {
                Button(action: onShowSidebar) {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(.borderless)
                .help("Show panes")
                .accessibilityLabel("Show panes")
            }

            Text(focusedTitle)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .lineLimit(1)

            if pages.count > 1 {
                Text("\(CompactLayoutResolver.selectedIndex(focusedPane: store.workspace.focusedPane, in: canvas) + 1)/\(pages.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 8)

            // Prev / next page (wraps, like ⌘]/⌘[).
            if pages.count > 1 {
                Button { store.move(.previous) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Previous pane")
                    .accessibilityLabel("Previous pane")
                Button { store.move(.next) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .help("Next pane")
                    .accessibilityLabel("Next pane")
            }

            addMenu
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The title of the focused pane (or a neutral fallback), for the compact top bar.
    private var focusedTitle: String {
        store.workspace.focusedPane.flatMap { canvas.spec(for: $0)?.title } ?? "Panes"
    }

    /// The `+` affordance: add a new pane of a chosen kind to the canvas (adds a swipe page).
    private var addMenu: some View {
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
            Image(systemName: "plus")
        } primaryAction: {
            store.addPane(kind: .terminal)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
        .help("Add pane")
        .accessibilityLabel("Add pane")
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Panes", systemImage: "rectangle.dashed")
        } description: {
            Text("Add a pane to get started.")
        } actions: {
            Button("New Pane") { store.addPane(kind: .terminal) }
        }
    }

    // MARK: Selection binding (focus IS the page)

    /// The carousel's selection, bound to `workspace.focusedPane`. Reading returns the focused pane (so
    /// a programmatic `store.move(...)` slides the carousel); writing routes a swipe / dot tap through
    /// `store.focus(_:)` — a view-only focus change that never reshapes the canvas. The setter guards
    /// against an out-of-canvas id so a transient projection swap can't push focus to a stale pane.
    private var focusBinding: Binding<PaneID> {
        Binding(
            get: { store.workspace.focusedPane ?? canvas.allIDs().first ?? PaneID() },
            set: { newID in
                guard newID != store.workspace.focusedPane, canvas.contains(newID) else { return }
                store.focus(newID)
            }
        )
    }
}
#endif
