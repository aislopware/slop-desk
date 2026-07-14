// StageZone — the STAGE (the Stage re-scope, docs/DECISIONS.md 2026-07-14): the dedicated tabbed zone
// for NON-TERMINAL content (streamed remote windows now; webview/editor later), docked on the canvas's
// trailing edge INSIDE the content column. The split tree to its left is terminal-only; glance left =
// terminals, glance right = everything else.
//
// Zone rules (Zed-dock discipline):
//   • Own tab strip; ONE tab's stream decodes at a time (single-active-decode) — a background tab's
//     GuiLeafView is unmounted, which releases its `liveVideoCap` slot (the video pipeline lives on the
//     MODEL — `RemoteWindowModel` — so remount on re-select is safe; only decode stops).
//   • Empty stage ⇒ the zone is NOT mounted at all (collapse-to-zero, no placeholder) — opening a
//     window auto-reveals it. Mount/unmount is a HARD CUT (never animate leaf frames).
//   • Input capture: clicking into the stream moves keyboard ownership into the zone
//     (`store.stageFocused` via the shared `focusPaneTree` funnel); clicking any terminal releases it.
//
// SEAM discipline: like `PaneContainer`, this file never imports video/Metal — `GuiLeafView` mounts the
// `VideoWindowFactory` seam. SYSTEM/Slate tokens only.

#if canImport(SwiftUI)
import Defaults
import SFSafeSymbols
import SlopDeskWorkspaceCore
import SwiftUI

struct StageZone: View {
    let store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            StageTabStrip(store: store)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Slate.Surface.face)
    }

    /// The SELECTED tab's content — the one mounted `GuiLeafView` (single-active-decode: a background
    /// tab has no view, so its `onDisappear`/visibility lifecycle released the decode slot). Keyed
    /// `.id(PaneID)` so a surface/coordinator is never reused across panes (the identity hazard).
    @ViewBuilder private var content: some View {
        if let id = store.activeStagePaneID {
            GuiLeafView(
                live: store.handle(for: id) as? LivePaneSession,
                isFocused: store.stageFocused,
                store: store,
                paneID: id,
                isVisible: true,
            )
            .id(id)
        }
    }
}

// MARK: - Tab strip

/// The stage's own tab strip: one row per staged window, instrument voice, flat (MERIDIAN — the
/// selected tab is a raised plate, no underline ornament). Overflow scrolls horizontally.
private struct StageTabStrip: View {
    let store: WorkspaceStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Slate.Metric.space1) {
                ForEach(store.stagePaneIDs, id: \.raw) { id in
                    StageTabButton(
                        store: store,
                        paneID: id,
                        isSelected: id == store.activeStagePaneID,
                    )
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
        }
        .frame(height: Slate.Metric.paneHeaderHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Slate.Surface.face)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
        }
    }
}

/// One stage tab: kind glyph + title, hover-revealed close ×. Selecting routes through the store's
/// single-active-decode handoff (`activateStagePane`); closing tears the stream down.
private struct StageTabButton: View {
    let store: WorkspaceStore
    let paneID: PaneID
    let isSelected: Bool

    @State private var hovering = false

    private var spec: PaneSpec? { store.tree.spec(for: paneID) }
    private var title: String {
        spec.map { $0.lastKnownTitle ?? $0.title } ?? "Window"
    }

    private var symbol: SFSymbol {
        spec?.kind == .systemDialog ? .lockShield : .display
    }

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(isSelected ? Slate.Text.primary : Slate.Text.secondary)
            Text(title)
                .font(.system(size: Slate.Typeface.small, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Slate.Text.primary : Slate.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            // Hover-revealed close. `Color.clear` reserves the slot so revealing it never shifts the
            // title (zero-shift — the tab-row discipline).
            ZStack {
                Color.clear.frame(width: Slate.Metric.iconSize, height: Slate.Metric.iconSize)
                if hovering {
                    Button {
                        store.closeStagePane(paneID)
                    } label: {
                        Image(systemSymbol: .xmark)
                            .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                            .foregroundStyle(Slate.Text.icon)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .slateHelp("Close window tab")
                }
            }
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.vertical, Slate.Metric.space1)
        .background(
            isSelected ? Slate.Surface.raised : (hovering ? Slate.State.hover : .clear),
            in: .rect(cornerRadius: Slate.Metric.radiusControl),
        )
        .contentShape(.rect)
        .onTapGesture { store.activateStagePane(paneID) }
        .onHover { hovering = $0 }
    }
}

// MARK: - Zone divider (canvas | stage)

/// The hand-draggable seam between the terminal canvas and the Stage. Same discipline as
/// ``PaneDivider``: live layout each frame, host grid-resize DEFERRED to release
/// (`setTerminalResizeSuspended` brackets the drag), accent hairline while dragging, gesture-state
/// cleanup that survives a cancelled drag. Dragging LEFT grows the stage.
struct StageDivider: View {
    /// The stage width binding (the content column owns + persists it).
    @Binding var width: CGFloat
    /// Clamp bounds resolved by the owner against the live column geometry.
    let range: ClosedRange<CGFloat>
    let store: WorkspaceStore

    /// Hit-band width (the drawn hairline is 1 pt inside it).
    private static let grabWidth: CGFloat = 8

    @GestureState private var gestureActive = false
    @State private var startWidth: CGFloat?

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            Rectangle()
                .fill(gestureActive ? Slate.State.accent : NativePaneColor.separator)
                .frame(width: gestureActive ? Slate.Metric.dividerHoverWidth : Slate.Metric.hairline)
        }
        .frame(width: Self.grabWidth)
        #if os(macOS)
            .pointerStyle(.columnResize)
        #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($gestureActive) { _, state, _ in state = true }
                    .onChanged { value in
                        if startWidth == nil {
                            startWidth = width
                            store.setTerminalResizeSuspended(true)
                        }
                        let base = startWidth ?? width
                        // Dragging toward leading (negative translation) grows the stage.
                        width = (base - value.translation.width).clamped(to: range)
                    },
            )
            // Fires on end AND cancel (`gestureActive` resets either way) — flush the settled grid and
            // persist the width exactly once.
            .onChange(of: gestureActive) { _, active in
                if !active, startWidth != nil {
                    startWidth = nil
                    store.setTerminalResizeSuspended(false)
                    Defaults[.stageWidth] = Double(width)
                }
            }
    }
}

extension CGFloat {
    /// Clamp to a closed range — shared by the stage divider drag and the content column's live clamp.
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

#endif
