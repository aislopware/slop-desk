// PaneContainer — one placed leaf = the flush, borderless pane content (otty port).
//
// Resolves the pane's `LivePaneSession` handle + `PaneSpec` from the store, routes by pane kind to the
// content view (terminal → `TerminalLeafView`; `.remoteGUI`/`.systemDialog` → the `VideoWindowFactory`
// seam, else a native placeholder). otty renders the terminal as a FLUSH, borderless panel on paper — there
// is NO floating card, NO accent ring, NO drop shadow and NO inset gutter. The per-pane controls
// (split/close) hover-reveal as a top overlay instead of a resting header bar; focus is conveyed only by
// dimming the unfocused panes (otty's `⌘D` split treatment). Tap anywhere focuses the pane via the store.
//
// The whole pane is keyed `.id(PaneID)` by the SplitContainer so the surface/connection are never reused
// across panes (identity hazard). SYSTEM colours/fonts only.
//
// DEFERRED (clean seams, do NOT wire in L2):
//   - TODO(L5): the per-pane agent footer coordinator + overflow context menu.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

struct PaneContainer: View {
    let store: WorkspaceStore
    let paneID: PaneID
    /// Whether this pane is the active tab's active (focused) pane.
    let isFocused: Bool
    /// EAGER/STATIC render path for headless ImageRenderer snapshots.
    var staticMirror: Bool = false

    /// The live session for this pane (terminal model / input bar), if materialized.
    private var live: LivePaneSession? { store.handle(for: paneID) as? LivePaneSession }

    private var spec: PaneSpec? { store.tree.activeSession?.specs[paneID] }

    /// The pane's kind drives which leaf view renders. Reads the live handle's kind (falls back to spec).
    private var kind: PaneKind { live?.kind ?? spec?.kind ?? .terminal }

    /// Whether this is a video (PATH 2) pane. `PaneKind.isVideo` is internal to WorkspaceCore, so the
    /// equivalent check is inlined here (the case set matches `PaneKind.isVideo`).
    private var isVideo: Bool { kind == .remoteGUI || kind == .systemDialog }

    /// The leaf content, routed by pane kind. A terminal pane renders the `TerminalLeafView` over the
    /// terminal-renderer seam; a video pane shows a native placeholder for now.
    @ViewBuilder private var paneContent: some View {
        if isVideo {
            // TODO(L5): mount the `VideoWindowFactory` seam (descriptor/context, host-window picker, key
            // injection) for real remote-window streaming. L2 shows a native placeholder.
            remotePlaceholder
        } else {
            TerminalLeafView(
                live: live,
                isFocused: isFocused,
                staticMirror: staticMirror,
            )
        }
    }

    private var remotePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemSymbol: kind == .systemDialog ? .lockShield : .display)
                .font(.system(size: Otty.Typeface.display, weight: .regular))
                .foregroundStyle(Otty.Text.secondary)
            Text(kind == .systemDialog ? "system dialog" : "remote window")
                .font(.system(size: Otty.Typeface.body, weight: .semibold))
                .foregroundStyle(Otty.Text.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePaneColor.terminalBackground)
    }

    var body: some View {
        paneContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Otty.Surface.card)
            // otty: the terminal is a FLUSH, borderless panel on paper — fills the leaf rect edge-to-edge.
            // No rounded card, no accent ring, no drop shadow, no gutter, and NO per-pane header bar (the
            // active pane's title + split/close controls live in the titlebar `⋯` menu). Adjacent split
            // panes are separated only by the `PaneDivider` hairline `SplitContainer` places between leaves.
            .contentShape(Rectangle())
            .onTapGesture { store.focusPaneTree(paneID) }
            // Focus is conveyed ONLY by dimming the unfocused panes (otty's `⌘D` split treatment) — no ring.
            .opacity(isFocused ? 1 : Otty.Anim.unfocusedPaneOpacity)
            .animation(Otty.Anim.standard, value: isFocused)
    }
}
#endif
