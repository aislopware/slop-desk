// Adapted from Muxy (https://github.com/muxy-app/muxy) — MIT © 2026 Muxy.
#if canImport(SwiftUI)
import AislopdeskAgentDetect
import SwiftUI

// MARK: - TabBarView (the active session's tab strip — Muxy-styled)

/// The coding-IDE tab strip for the active session, REWRITTEN to match Muxy's `PaneTabStrip` (not stock
/// pills): a solid `bg` row of RECTANGULAR `TabCell`s (active = `activeFill` bg + the SINGLE active cue, a
/// 2pt `accent` bottom line gated on active+key-window — it falls to the neutral `borderComponent` when the
/// window is backgrounded, never falsely lit), 1pt `border` separators between cells, and a right-aligned
/// group of split / zoom / new-tab `ChromeIconButton`s that act on the active pane (the per-pane header that
/// used to host those was removed — Muxy has no per-pane header). Drives the store's tree ops (`selectTab` /
/// `closeTab` / `newTab` / `renameTab` / `splitPaneTree` / `toggleZoomTree`).
///
/// P3a: the strip sits below a 2pt top inset (so cells aren't pinched under the floating traffic lights),
/// migrates the cell text/spacing to the DS type ladder + 4pt spacing scale via the live-scale `.dsFont` /
/// `.dsSpace` modifiers, animates the titled↔icon-only padding collapse with `DSMotion.layout`, and drops
/// the redundant attention glow line (the wash + unread dot remain as the quieter background-tab signal).
///
/// When `isWindowTitleBar` is set, the whole strip doubles as the window's custom title bar: the scroll
/// region and the trailing controls cluster are backed by `WindowDragRepresentable(alwaysEnabled: true)` so
/// empty space drags the window.
struct TabBarView: View {
    /// The 2pt top inset band above the cell row (base points, scaled live via `.dsSpace`). It is ADDITIVE
    /// to the `DSSpace.tabHeight` cell row — the strip's net height is `DSSpace.tabHeight + topInset`. Named
    /// (not a magic `2` inline) so ``TabCellViewModelTests`` can pin the additive-height arithmetic
    /// `DSSpace.tabHeight + topInset == UIMetrics.titleBarHeight` (legacy 32) — the exact relationship the
    /// earlier absorbed-inset bug broke (padding-before-frame is swallowed, not added). HW-only otherwise.
    static let topInset: CGFloat = 2

    @Bindable var store: WorkspaceStore
    let session: Session

    /// Whether this strip is acting as the window's custom title bar (⇒ it is the window-drag region).
    var isWindowTitleBar: Bool = false

    /// The tab whose inline rename field is open (double-click / context-menu Rename), or `nil`.
    @State private var renamingTab: TabID?
    @State private var renameText: String = ""

    /// Reduce-Motion gate for the sync-input dot appear (DSMotion.hover → near-instant crossfade).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // P3a TOP INSET: the cell row sits BELOW a 2pt inset inside the titlebar zone so the cells are not
        // flush against the window edge / floating traffic lights (spec: "tabs aren't pinched under the
        // lights"). HEIGHT MATH (the inset must be ADDITIVE, not absorbed): the cell row is constrained to
        // `DSSpace.tabHeight` (30) FIRST via `.frame`, then `.dsSpace(.top, 2)` is applied AFTER it as the
        // OUTER modifier — so the 2pt band sits OUTSIDE the constrained row (net height = 30 + 2 = 32,
        // restoring the legacy titlebar height) instead of being swallowed into a 30pt frame (which would
        // squeeze the row to 28). The bg + bottom border wrap the OUTER (32pt) box so the strip paints its
        // full height including the inset. `.dsSpace(.top, 2)` is also the FIRST real consumer of the P1
        // live-scale path (it reflows on a P5 density flip because the modifier reads
        // @Environment(DSScale.self)). The whole strip stays a drag region (`.titleBarDrag`) so empty space,
        // INCLUDING the 2pt inset band, still drags the window.
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
        // Constrain the CELL ROW to the migrated height token (30 default) BEFORE the inset. P5: via the
        // tracked `.dsFrame(height:)` so the row reflows LIVE on a density TIER flip (it reads
        // @Environment(DSThemeStore.self) for the tier height + @Environment(DSScale.self) for the multiplier).
        .dsFrame(height: \.tabHeight)
        // ADDITIVE top inset (outer) — net strip height = DSSpace.tabHeight + topInset = 30 + 2 = 32
        // (≈ legacy titlebar height, pinned by TabCellViewModelTests.testStripNetHeightIsAdditive).
        // SplitWorkspaceView.mainColumn's outer container lets the strip's intrinsic 32pt drive the row
        // (`.fixedSize(vertical:)`) so the strip and its container agree (see the tab-height-token-split
        // risk). P5: the strip HEIGHT now live-reflows on a density TIER flip via `.dsFrame(height:)` above
        // (the tracked DSThemeStore + DSScale path) — the inset band tracks the same flip via `.dsSpace`.
        .dsSpace(.top, Self.topInset)
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
        // P5 MOTION: DSMotion.hover (0.13s easeOut), Reduce-Motion-gated to the near-instant crossfade.
        .animation(DSMotion.resolve(DSMotion.hover, reduceMotion: reduceMotion), value: store.syncInputTabs)
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
                    // P3a: migrate to the DS body type token (13pt SF, lh16) + textPrimary via the
                    // live-scale `.dsFont` modifier (reads @Environment(DSScale.self)).
                    .dsFont(.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .frame(minWidth: 60, maxWidth: 160)
                    // P3a: migrate the rename field's horizontal padding off the legacy `UIMetrics.spacing6`
                    // (scaled 12) onto the SAME live-scale `.dsSpace(.horizontal, 8)` path the titled tab
                    // cell uses, so the whole cell reads from one token source (the DSSpace 4pt scale) and
                    // reflows on a P5 density flip instead of leaking a legacy spacing rung.
                    .dsSpace(.horizontal, 8)
                    .onSubmit { commitRename(tab.id) }
                    .onEscapeKey { renamingTab = nil }
                #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                #endif
            }
            // P3a: match the migrated strip height token (the cell row + inline field must agree). P5: via
            // the tracked `.dsFrame(height:)` so it reflows with the strip on a density TIER flip.
            .dsFrame(height: \.tabHeight)
            // The active inline-rename field background. P2 NOTE: `surface12` (the legacy fg·0.12 rung) now
            // flattens onto `activeFill` (white·0.08) — the DS semantic token set has no distinct 0.12 rung,
            // so this fill currently reads at the same weight as a resting selected tab. The field still
            // reads as an open/focused input via its own trailing edge + focus; if a stronger lift is wanted
            // it must be promoted to a dedicated interactive-tint token in P3 (out of P2 colour scope).
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
/// inactive) + agent dot + title + (hover/active) close, with an `activeFill` bg + the SINGLE active cue —
/// a 2pt accent bottom line gated on (isActive && key window), falling to `borderComponent` when the window
/// is backgrounded — a `hoverFill` wash on hover, and a 1pt `border` trailing separator. Width clamps to
/// Muxy's `minWidth 44 … maxWidth 200`; below `titleHideThreshold 80` the title hides to an icon-only chip.
/// Its own `hovering` state keeps the close glyph + hover wash local (no parent re-render per pointer move).
///
/// NOTE: `internal` (not `private`) so the PURE view-model transforms (``Self/activeCue(isActive:isKey:)``,
/// ``Self/titleFont(isActive:)``, ``Self/titleColor(isActive:)``, ``Self/cueColor(_:)``) are reachable from
/// the headless `TabCellViewModelTests` via `@testable import` — no SwiftUI layout is exercised there.
struct TabCell: View {
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

    #if os(macOS)
    /// Whether THIS view's window is the key window. A FREE SwiftUI environment value (no NSWindow access,
    /// hang-safe). The active-tab accent line gates on it so a BACKGROUNDED window's active tab falls to the
    /// neutral `borderComponent` instead of staying falsely lit — the SAME gate ``PaneChromeView`` uses for
    /// its focus ring (`isFocused && controlActiveState == .key`). On iOS this value is always `.active`, so
    /// the `#else` branch of ``Self/activeCue(isActive:isKey:)`` lights on `isActive` alone there.
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    /// Reduce-Motion gate: the titled↔icon-only padding spring + the active-cue accent-line spring fall to a
    /// near-instant crossfade under the system preference (via ``DSMotion/resolve(_:reduceMotion:)``).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Seed at `maxWidth` so the title is SHOWN by default. A `0` sentinel latches the title hidden
    /// forever: hiding the title shrinks the cell below `titleHideThreshold`, so the GeometryReader
    /// re-measures it as narrow and never lifts the hide. Showing-by-default costs at most a one-frame
    /// title→hidden flash on genuinely narrow (many-tab) strips, which is the lesser evil.
    @State private var measuredWidth: CGFloat = Self.maxWidth

    /// Below the threshold the cell collapses to an icon-only chip (Muxy hides the title on narrow tabs).
    private var titleHidden: Bool { measuredWidth < Self.titleHideThreshold }

    // MARK: - Pure view-model transforms (unit-tested headlessly — no SwiftUI layout)

    /// The single active-tab cue, a PURE function of (isActive, isKey). Mirrors ``PaneChromeView``'s
    /// focus-ring gate exactly: active + key window ⇒ the 2pt `accent` line; active + BACKGROUNDED window ⇒
    /// the line falls to the neutral `borderComponent` (never falsely lit, never dimming the other tabs);
    /// inactive ⇒ no line. There is exactly ONE active cue now — the glow LINE (the redundant 3rd cue) is
    /// dropped, and the active bg fill is the SAME for both window states (only the line colour moves), so a
    /// backgrounded window's active tab keeps its `activeFill` bg and loses ONLY the accent line.
    enum Cue: Equatable { case accent, neutral, none }

    /// The active-cue decision. `isKey` is the macOS key-window flag; on iOS callers pass `true` (the
    /// platform has no backgrounded-key distinction, so an active tab always lights — mirroring
    /// ``PaneChromeView``'s `#else return isFocused`).
    static func activeCue(isActive: Bool, isKey: Bool) -> Cue {
        guard isActive else { return .none }
        return isKey ? .accent : .neutral
    }

    /// Resolves a ``Cue`` to its line colour: `accent` ⇒ the DS solid accent; `neutral` ⇒ the neutral
    /// component border (backgrounded-window fallback); `none` ⇒ clear (inactive, no line).
    @MainActor
    static func cueColor(_ cue: Cue) -> Color {
        switch cue {
        case .accent: DSColor.accentSolid
        case .neutral: DSColor.borderComponent
        case .none: .clear
        }
    }

    /// The title's type token, a PURE function of `isActive`: the active tab is `DSFont.emphasis`
    /// (13pt semibold) and an inactive tab is `DSFont.body` (13pt regular). The tab ICON weight-matches the
    /// adjacent title via the same token so icon + text read as one type system.
    static func titleFont(isActive: Bool) -> DSFont { isActive ? .emphasis : .body }

    /// The title's colour, a PURE function of `isActive`: active ⇒ `textPrimary`; inactive ⇒ `textTertiary`
    /// (the recessive resting state — NEVER a dim/opacity wash; the cue is the accent line, not dimming).
    @MainActor
    static func titleColor(isActive: Bool) -> Color {
        isActive ? DSColor.textPrimary : DSColor.textTertiary
    }

    /// Whether the active line should LIGHT (accent), resolving the macOS key-window flag. Used by `body`.
    private var resolvedCue: Cue {
        #if os(macOS)
        return Self.activeCue(isActive: isActive, isKey: controlActiveState == .key)
        #else
        return Self.activeCue(isActive: isActive, isKey: true)
        #endif
    }

    var body: some View {
        HStack(spacing: AislopdeskTheme.Space.m) {
            Image(systemName: icon)
                // P3a: weight-match the icon to the adjacent title via the SAME DS type token (semibold on
                // active, regular on inactive) so icon + text read as one type system. `.dsFont` also sets
                // the SF Symbol point size (13pt emphasis / body) live-scaled through @Environment.
                .dsFont(Self.titleFont(isActive: isActive))
                .foregroundStyle(Self.titleColor(isActive: isActive))
                .overlay(alignment: .topTrailing) { unreadDot }
                .overlay(alignment: .bottomLeading) { syncInputDot }
            // P5: pass the UNSCALED base (6) — AgentStatusDot applies the live scale via `.dsScaledFrame`.
            AgentStatusDot(status: agentStatus, size: 6)
            CompletionBadge(badge: completion, size: UIMetrics.scaled(6))
            if !titleHidden {
                Text(title)
                    // P3a: active title = DSFont.emphasis (13pt semibold) textPrimary; inactive =
                    // DSFont.body (13pt regular) textTertiary. Migrated to the live-scale `.dsFont` path.
                    .dsFont(Self.titleFont(isActive: isActive))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(Self.titleColor(isActive: isActive))
            }
            if !titleHidden { closeButton }
        }
        // P3a: tab-cell horizontal padding migrates to the spec's 8(titled)/4(icon-only) via the live-scale
        // `.dsSpace` path (a tightening from the legacy 10/4), ANIMATED by DSMotion.layout so the
        // titled↔icon-only collapse springs instead of jumping abruptly.
        .dsSpace(.horizontal, titleHidden ? 4 : 8)
        .animation(DSMotion.resolve(DSMotion.layout, reduceMotion: reduceMotion), value: titleHidden)
        .dsFrame(height: \.tabHeight)
        .frame(minWidth: Self.minWidth, maxWidth: Self.maxWidth)
        .background {
            GeometryReader { geo in
                Color.clear.onAppear { measuredWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in measuredWidth = width }
            }
        }
        // P3a: active-tab bg = DSColor.activeFill (white·0.08, == legacy surface, byte-identical so the
        // resting fill is unchanged). The fill is the SAME in both key/backgrounded window states — only the
        // accent LINE below moves — so a backgrounded window never dims the tab. NEVER an opacity dim.
        .background(isActive ? DSColor.activeFill : (hovering ? DSColor.hoverFill : .clear))
        // P3 TAB GLOW: a soft status-coloured wash announces a BACKGROUND tab that needs attention
        // (blocked / done) so the human notices it without switching to it. This is a background-tab
        // SUPERVISION cue (status colour), NOT the active/focus cue — kept per spec ("let the sidebar/pane
        // attention ring own that" applies to the redundant glow LINE, which is dropped below). NEVER dims.
        .background(attentionGlowBackground)
        // P3a SINGLE ACTIVE CUE: the one 2pt accent line, gated on (isActive && controlActiveState == .key)
        // via `resolvedCue`. Active + key ⇒ accent; active + backgrounded ⇒ falls to the neutral
        // `borderComponent` (never falsely lit); inactive ⇒ clear. The redundant glow LINE + its pulse are
        // removed (the wash above remains as the quieter background-attention signal).
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Self.cueColor(resolvedCue))
                .frame(height: 2)
                // P5 MOTION: the active-tab accent line is the tab SELECTION cue, so its colour move springs
                // via DSMotion.select (slight overshoot reads premium on dark) — gated behind Reduce Motion
                // (→ near-instant crossfade). Keyed on `resolvedCue` so it fires exactly on a select / key-
                // window flip; it animates the CUE colour only, never an opacity dim of the other tabs.
                .animation(DSMotion.resolve(DSMotion.select, reduceMotion: reduceMotion), value: resolvedCue)
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
    /// tab is in view, so its agent/completion state is already visible inline). Muxy: a 6pt circle — P3
    /// colours it in the SEMANTIC status colour (blocked=red, done=green) so the cue reads the urgency, not
    /// just "something happened"; a bare completion badge keeps the neutral accent.
    @ViewBuilder
    private var unreadDot: some View {
        let pending = agentStatus == .done || agentStatus == .needsPermission || completion != nil
        if pending, !isActive {
            Circle()
                .fill(attentionColor ?? AislopdeskTheme.accent)
                .frame(width: 6, height: 6)
                .offset(x: 3, y: -3)
        }
    }

    // MARK: P3 attention glow (supervision cockpit)

    /// The semantic status colour when this tab's rollup needs attention (needsPermission → red /
    /// done → green), else `nil`. A pure function of `agentStatus` so it clears automatically.
    private var attentionColor: Color? {
        switch agentStatus {
        case .needsPermission: AislopdeskTheme.statusRed
        case .done: AislopdeskTheme.statusGreen
        default: nil
        }
    }

    /// A soft status-coloured wash behind a tab needing attention (≈8% fill) — a quiet background cue that
    /// a tab is blocked / done. Clear otherwise.
    @ViewBuilder
    private var attentionGlowBackground: some View {
        if let color = attentionColor {
            color.opacity(0.08)
        }
    }

    // P3a: the redundant THIRD active/attention cue — the bottom glow LINE + halo + `TabAttentionPulse`
    // breathe — was removed (spec line 160: "Drop the third attention glow line; let the sidebar/pane
    // attention ring own that"). The quieter background-attention signals remain: the `attentionGlowBackground`
    // wash + the `unreadDot`. The single ACTIVE cue is now the gated accent line in `body`.

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

// P3a: `TabAttentionPulse` (the breathe for the dropped tab attention glow LINE) was removed with the line
// itself — the spec's single-active-cue rule retires the redundant 3rd cue. The pane attention ring keeps
// its own `AttentionPulse` (in PaneChromeView); the tab background wash + unread dot are steady.
#endif
