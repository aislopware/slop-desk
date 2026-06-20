// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import AislopdeskAgentDetect
import SwiftUI

// MARK: - TabBarView (the active session's tab strip — Muxy-styled)

/// The coding-IDE tab strip for the active session, REWRITTEN to match Muxy's `PaneTabStrip` (not stock
/// pills): a solid `bg` row of RECTANGULAR `TabCell`s (active = `surface` fill + a 2pt `accent` bottom line
/// when active+focused, the primary "this is the active tab" cue), 1pt `border` separators between cells,
/// and a right-aligned group of split / zoom / new-tab `ChromeIconButton`s that act on the active pane (the
/// per-pane header that used to host those was removed — Muxy has no per-pane header). Drives the store's
/// tree ops (`selectTab` / `closeTab` / `newTab` / `renameTab` / `splitPaneTree` / `toggleZoomTree`).
///
/// When `isWindowTitleBar` is set, the whole strip doubles as the window's custom title bar: the scroll
/// region and the trailing controls cluster are backed by `WindowDragRepresentable(alwaysEnabled: true)` so
/// empty space drags the window.
struct TabBarView: View {
    @Bindable var store: WorkspaceStore
    let session: Session

    /// Whether this strip is acting as the window's custom title bar (⇒ it is the window-drag region).
    var isWindowTitleBar: Bool = false

    /// The tab whose inline rename field is open (double-click / context-menu Rename), or `nil`.
    @State private var renamingTab: TabID?
    @State private var renameText: String = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(session.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabSlot(tab: tab, index: index, isActive: index == session.activeTabIndex)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .titleBarDrag(isWindowTitleBar)
            }
            Spacer(minLength: 0)
            controls
        }
        .frame(height: AislopdeskTheme.Metrics.tabHeight)
        .background(AislopdeskTheme.bg)
        .titleBarDrag(isWindowTitleBar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AislopdeskTheme.border).frame(height: 1)
        }
        // ITEM B1: observe the store's ⌘⇧R "Rename Tab" request and open the matching cell's inline field.
        .onChange(of: store.pendingTabRename) { _, requested in openPendingTabRename(requested) }
        .onAppear { openPendingTabRename(store.pendingTabRename) }
        // FIX A: dismiss a half-open inline rename when the session changes (TabBarView is NOT remounted
        // across session switches — same identity, new `session:` value — so @State persists and a stale
        // TabID would silently swallow the edit).
        .onChange(of: session.id) { _, _ in renamingTab = nil }
        // Animate the per-tab sync-input indicator (the keyboard.badge.ellipsis dot) appearing/disappearing.
        .animation(.easeInOut(duration: 0.15), value: store.syncInputTabs)
    }

    /// Opens the inline rename for the requested tab (if it belongs to THIS session's strip) and clears the
    /// store request.
    private func openPendingTabRename(_ requested: TabID?) {
        guard let requested, session.tabs.contains(where: { $0.id == requested }) else { return }
        if let tab = session.tabs.first(where: { $0.id == requested }) { beginRename(tab) }
        store.clearTabRenameRequest()
    }

    // MARK: Tab cell (or its inline rename field)

    @ViewBuilder
    private func tabSlot(tab: Tab, index: Int, isActive: Bool) -> some View {
        if renamingTab == tab.id {
            HStack(spacing: 0) {
                TextField("Tab", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: UIMetrics.fontBody))
                    .foregroundStyle(AislopdeskTheme.fg)
                    .frame(minWidth: 60, maxWidth: 160)
                    .padding(.horizontal, UIMetrics.spacing6)
                    .onSubmit { commitRename(tab.id) }
                    .onEscapeKey { renamingTab = nil }
                #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #endif
            }
            .frame(height: AislopdeskTheme.Metrics.tabHeight)
            // Use surface12 (fg·0.12) for the active inline-rename field so it reads as an
            // open/focused input rather than the same weight as a resting selected tab (surface fg·0.08).
            .background(AislopdeskTheme.surface12)
            .overlay(alignment: .trailing) { Rectangle().fill(AislopdeskTheme.border).frame(width: 1) }
        } else {
            TabCell(
                title: tabTitle(tab),
                icon: tabIcon(tab),
                isActive: isActive,
                agentStatus: store.rollupStatus(forTab: tab.id),
                completion: store.rollupPendingCompletion(forTab: tab.id),
                syncInputActive: store.syncInputTabs.contains(tab.id),
                onSelect: { store.selectTab(index) },
                onRename: { beginRename(tab) },
                onClose: { store.closeTab(tab.id) },
            )
            .contextMenu {
                Button("Rename…") { beginRename(tab) }
                Divider()
                let synced = store.syncInputTabs.contains(tab.id)
                Button(synced ? "Stop Syncing Input" : "Sync Input to All Panes") {
                    store.toggleSyncInput(tabID: tab.id)
                }
                Button("Close Tab", role: .destructive) { store.closeTab(tab.id) }
            }
        }
    }

    // MARK: Right-side controls (act on the active pane — Muxy puts split/new-tab here)

    private var controls: some View {
        HStack(spacing: AislopdeskTheme.Space.xs) {
            if let active = session.activeTab?.activePane {
                ChromeIconButton(systemImage: "square.split.2x1", help: "Split right (⌘D)") {
                    store.focusPaneTree(active)
                    store.splitPaneTree(active, axis: .horizontal, kind: SettingsKey.defaultPaneKind)
                }
                ChromeIconButton(systemImage: "square.split.1x2", help: "Split down (⌘⇧D)") {
                    store.focusPaneTree(active)
                    store.splitPaneTree(active, axis: .vertical, kind: SettingsKey.defaultPaneKind)
                }
                let zoomed = session.activeTab?.zoomedPane == active
                ChromeIconButton(
                    systemImage: zoomed
                        ? "arrow.down.right.and.arrow.up.left.square"
                        : "arrow.up.left.and.arrow.down.right.square",
                    help: zoomed ? "Restore (⌘⌥↩)" : "Zoom (⌘⌥↩)",
                ) {
                    store.focusPaneTree(active)
                    store.toggleZoomTree()
                }
            }
            ChromeIconButton(systemImage: "plus", help: "New tab (⌘T)") {
                store.newTab(kind: SettingsKey.defaultPaneKind)
            }
        }
        .padding(.horizontal, AislopdeskTheme.Space.m)
        .titleBarDrag(isWindowTitleBar)
    }

    // MARK: Title + icon + rename

    /// The tab's title, deriving from the active pane's live OSC title when the tab has no explicit name.
    private func tabTitle(_ tab: Tab) -> String {
        if !tab.title.isEmpty { return tab.title }
        if let active = tab.activePane, let spec = store.tree.spec(for: active) {
            return PanePresentation.displayTitle(store.handle(for: active), spec: spec)
        }
        return "Tab"
    }

    /// The tab's glyph — the active pane's kind icon (one source of truth via `PaneLeafView.icon`).
    private func tabIcon(_ tab: Tab) -> String {
        if let active = tab.activePane, let spec = store.tree.spec(for: active) {
            return PaneLeafView.icon(for: spec.kind)
        }
        return PaneLeafView.icon(for: .terminal)
    }

    private func beginRename(_ tab: Tab) {
        renameText = tabTitle(tab)
        renamingTab = tab.id
    }

    private func commitRename(_ id: TabID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.renameTab(id, to: trimmed)
        renamingTab = nil
    }
}

// MARK: - Window-drag helper

private extension View {
    /// Backs the receiver with the window-drag region when this strip is the custom title bar (Muxy:
    /// `WindowDragRepresentable(alwaysEnabled: isWindowTitleBar)`), else a no-op.
    @ViewBuilder
    func titleBarDrag(_ enabled: Bool) -> some View {
        if enabled {
            background(WindowDragRepresentable(alwaysEnabled: true))
        } else {
            self
        }
    }
}

// MARK: - TabCell (one rectangular Muxy tab)

/// A single rectangular tab cell in the Muxy idiom: icon (+ a top-trailing unread/completion accent dot when
/// inactive) + agent dot + title + (hover/active) close, with a `surface` fill + 2pt `accent` bottom line
/// when active, a `hover` wash on hover, and a 1pt `border` trailing separator. Width clamps to Muxy's
/// `minWidth 44 … maxWidth 200`; below `titleHideThreshold 80` the title hides to an icon-only chip. Its own
/// `hovering` state keeps the close glyph + hover wash local (no parent re-render per pointer move).
private struct TabCell: View {
    static let minWidth: CGFloat = 44
    static let maxWidth: CGFloat = 200
    static let titleHideThreshold: CGFloat = 80

    let title: String
    let icon: String
    let isActive: Bool
    let agentStatus: ClaudeStatus
    let completion: PaneCompletionBadge?
    /// Whether per-tab sync-input is ON for this cell's tab (⌘⇧I / Zellij ToggleActiveSyncTab).
    var syncInputActive: Bool = false
    let onSelect: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    /// Seed at `maxWidth` so the title is SHOWN by default. A `0` sentinel latches the title hidden
    /// forever: hiding the title shrinks the cell below `titleHideThreshold`, so the GeometryReader
    /// re-measures it as narrow and never lifts the hide. Showing-by-default costs at most a one-frame
    /// title→hidden flash on genuinely narrow (many-tab) strips, which is the lesser evil.
    @State private var measuredWidth: CGFloat = Self.maxWidth

    /// Below the threshold the cell collapses to an icon-only chip (Muxy hides the title on narrow tabs).
    private var titleHidden: Bool { measuredWidth < Self.titleHideThreshold }

    var body: some View {
        HStack(spacing: AislopdeskTheme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: UIMetrics.fontBody))
                .foregroundStyle(isActive ? AislopdeskTheme.fg : AislopdeskTheme.fgMuted)
                .overlay(alignment: .topTrailing) { unreadDot }
                .overlay(alignment: .bottomLeading) { syncInputDot }
            AgentStatusDot(status: agentStatus, size: 6)
            CompletionBadge(badge: completion, size: 6)
            if !titleHidden {
                Text(title)
                    .font(.system(size: UIMetrics.fontBody))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(isActive ? AislopdeskTheme.fg : AislopdeskTheme.fgMuted)
            }
            if !titleHidden { closeButton }
        }
        .padding(.horizontal, titleHidden ? AislopdeskTheme.Space.s : AislopdeskTheme.Space.xl)
        .frame(height: AislopdeskTheme.Metrics.tabHeight)
        .frame(minWidth: Self.minWidth, maxWidth: Self.maxWidth)
        .background {
            GeometryReader { geo in
                Color.clear.onAppear { measuredWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in measuredWidth = width }
            }
        }
        .background(isActive ? AislopdeskTheme.surface : (hovering ? AislopdeskTheme.hover : .clear))
        .overlay(alignment: .bottom) {
            // The active-tab accent line — the primary focus cue (Muxy: 2pt accent bottom line).
            Rectangle()
                .fill(isActive ? AislopdeskTheme.accent : .clear)
                .frame(height: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(AislopdeskTheme.border).frame(width: 1)
        }
        .contentShape(Rectangle())
        // ITEM B2: the double-tap must win over the single-tap (a leading `onTapGesture` swallows it).
        .highPriorityGesture(TapGesture(count: 2).onEnded { onRename() })
        .onTapGesture { onSelect() }
        // Middle-click closes the tab (Muxy idiom) — a no-op view off macOS.
        .overlay { MiddleClickView(action: onClose).accessibilityHidden(true) }
        #if os(macOS)
            .onHover { hovering = $0 }
        #endif
    }

    /// The top-trailing unread/completion accent dot on the icon, shown only on an INACTIVE tab (the active
    /// tab is in view, so its agent/completion state is already visible inline). Muxy: a 6pt accent circle.
    @ViewBuilder
    private var unreadDot: some View {
        let pending = agentStatus == .done || agentStatus == .needsPermission || completion != nil
        if pending, !isActive {
            Circle()
                .fill(AislopdeskTheme.accent)
                .frame(width: 6, height: 6)
                .offset(x: 3, y: -3)
        }
    }

    /// Bottom-leading sync-input indicator: a small `keyboard.badge.ellipsis` SF Symbol in accent colour
    /// shown whenever ``syncInputActive`` is true, on both active and inactive tabs (sync is per-tab, so
    /// it is visible at all times while armed). Mirrors the ``unreadDot`` overlay pattern.
    @ViewBuilder
    private var syncInputDot: some View {
        if syncInputActive {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(AislopdeskTheme.accent)
                .offset(x: -3, y: 3)
        }
    }

    /// The close glyph — shown on hover or when active (Muxy hides it on narrow inactive tabs); always
    /// shown on iOS (no hover) when active.
    @ViewBuilder
    private var closeButton: some View {
        let show: Bool = {
            #if os(macOS)
            return hovering || isActive
            #else
            return isActive
            #endif
        }()
        if show {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: UIMetrics.fontCaption, weight: .bold))
                    .foregroundStyle(AislopdeskTheme.fgDim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
            .accessibilityLabel("Close tab")
        }
    }
}
#endif
