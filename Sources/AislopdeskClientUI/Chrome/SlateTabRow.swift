// SlateTabRow — the sidebar tab row (`TabsPanelRowView`) + the sort/group hamburger (`SortMenuButton`),
// built on the `Slate` tokens and wired to the live store via the navigator. The resting row is the tab
// name on the warm sidebar; ACTIVE is a WHITE CARD (radius-7 fill + 1px cardBorder + faint shadow), hover
// is a flat plate, and a close `×` reveals on hover. No native list selection / vibrancy — this is a flat
// silhouette by design.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SFSafeSymbols
import SwiftUI

/// One sidebar tab row. ACTIVE = white card treatment; hover = flat plate + close `×`.
///
/// E6 WI-4 grew the row from a name-only plate to its full chrome: an optional second-line cwd subtitle
/// and a trailing cluster of the fused status `badge`, the monospaced light-gray `⌘N` SWITCH-SHORTCUT badge,
/// and — on the ACTIVE row — the foreground-process label ("zsh"). Name-only rows stay ~34pt; a subtitle grows
/// the row to ~44pt (`docs/ui-shell/screenshots/tab-badge.png`). The trailing cluster fades under hover `×`.
struct SlateTabRow: View {
    let title: String
    let active: Bool
    /// The row's muted truncating-middle second line (a terminal's git line / cwd, a video pane's host
    /// app). `nil`/empty ⇒ single-line.
    var subtitle: String?
    /// The host's coarse foreground-process label ("zsh"), shown trailing on the ACTIVE row only.
    var processLabel: String?
    /// The single fused status badge (spinner / check / dot / error / hand / coffee / shield). `nil` ⇒ none.
    var badge: TabBadgeKind?
    /// E17 ES-E17-1 / WI-3: whether this pane's input gate is READ-ONLY — renders a small trailing lock glyph
    /// (the sidebar's read-only indicator, twin of the pane's `🔒 READ ONLY ×` pill). Default `false` keeps
    /// existing call sites source-compatible.
    var readOnly: Bool = false
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var hovering = false
    @State private var closeHover = false

    private var hasSubtitle: Bool { !(subtitle ?? "").isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: Slate.Typeface.body, weight: active ? .medium : .regular))
                    .foregroundStyle(Slate.Text.primary)
                    .lineLimit(1)
                if hasSubtitle {
                    Text(subtitle ?? "")
                        .font(.system(size: Slate.Typeface.small))
                        .foregroundStyle(Slate.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            trailingMeta
                .opacity(hovering ? 0 : 1)
        }
        .overlay(alignment: .trailing) {
            closeButton
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 14)
        .frame(height: hasSubtitle ? 44 : 34)
        .background(rowBackground, in: .rect(cornerRadius: Slate.Metric.radiusTab))
        .overlay { if active { RoundedRectangle(cornerRadius: Slate.Metric.radiusTab).strokeBorder(
            Slate.Line.card,
            lineWidth: 1,
        ) } }
        .shadow(color: active ? .black.opacity(0.04) : .clear, radius: 2, y: 1)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .animation(Slate.Anim.smallFade, value: active)
    }

    /// The trailing status cluster: the read-only lock (if locked), the fused `badge` (if any), then the
    /// foreground-process label on the ACTIVE row — all muted, right-aligned. Fades under the hover `×`.
    /// (The persistent `⌘N` switch-shortcut chip is REMOVED per user feedback — the ⌘1…⌘9 chords still
    /// work; the row just no longer advertises them.)
    private var trailingMeta: some View {
        HStack(spacing: 6) {
            if readOnly {
                Image(systemSymbol: .lockFill)
                    .font(.system(size: Slate.Typeface.small, weight: .semibold))
                    .foregroundStyle(Slate.Text.secondary)
                    .accessibilityLabel("Read only")
                    .help("Read only")
            }
            if let badge {
                TabBadgeView(kind: badge)
            }
            if active, let processLabel, !processLabel.isEmpty {
                Text(processLabel)
                    .font(.system(size: Slate.Typeface.small, design: .monospaced))
                    .foregroundStyle(Slate.Text.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Slate.Typeface.small, weight: .medium))
                .foregroundStyle(Slate.Text.icon)
                .frame(width: 18, height: 18)
                .background(
                    closeHover ? Slate.State.selected : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusSmall),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
    }

    private var rowBackground: Color {
        if active { Slate.Surface.selectedCard }
        else if hovering { Slate.State.hover }
        else { .clear }
    }
}

/// The sidebar hamburger — a sort/group popover (`SortMenuButton`). E6 WI-5 made it write the STORE (the
/// single source of truth for row order, persisted) instead of local `@State`: each GROUP row sets
/// ``WorkspaceStore/setTabGrouping(_:)`` and each ORDER row ``WorkspaceStore/setTabSort(_:)``; the checkmarks
/// READ the store. (Carryover binding constraint: "mutate the store order, not local `@State`.") The row is
/// the flat-icon button beside the "TABS" header.
struct SlateSortMenuButton: View {
    /// The live store — owns ``WorkspaceStore/tabGrouping`` / ``WorkspaceStore/tabSort`` (the persisted row
    /// order). Read in the popover (so the `@Observable` store ticks the checkmarks) and written by the rows.
    let store: WorkspaceStore

    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            // The "decrease" variant (three bars narrowing top→bottom) reads as sort/filter, not as a
            // navigation hamburger — per user feedback.
            Image(systemSymbol: .line3HorizontalDecrease)
                .font(.system(size: Slate.Typeface.footnote))
                .foregroundStyle(Slate.Text.icon)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            SortSection("GROUP")
            groupRow("No Grouping", "list.bullet", .none)
            groupRow("By Project", "folder", .byProject)
            groupRow("By Date", "calendar", .byDate)
            SortDivider()
            SortSection("ORDER")
            orderRow("Created Time", "clock", .created)
            orderRow("Updated Time", "clock.arrow.circlepath", .updated)
            orderRow("Manual", "arrow.up.arrow.down", .manual)
        }
        .padding(.vertical, 6)
        .frame(width: 210)
    }

    /// A GROUP row whose checkmark READS ``WorkspaceStore/tabGrouping`` and whose tap WRITES it (persisted).
    private func groupRow(_ title: String, _ icon: String, _ value: TabGrouping) -> some View {
        SortRow(title, icon: icon, on: store.tabGrouping == value) { store.setTabGrouping(value) }
    }

    /// An ORDER row whose checkmark READS ``WorkspaceStore/tabSort`` and whose tap WRITES it (persisted).
    private func orderRow(_ title: String, _ icon: String, _ value: TabSort) -> some View {
        SortRow(title, icon: icon, on: store.tabSort == value) { store.setTabSort(value) }
    }
}

private struct SortSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: Slate.Typeface.small, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Slate.State.header)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SortDivider: View {
    var body: some View {
        Rectangle().fill(Slate.Line.divider).frame(height: 1)
            .padding(.vertical, 5).padding(.horizontal, 10)
    }
}

private struct SortRow: View {
    let title: String
    let icon: String
    let on: Bool
    var action: () -> Void

    init(_ title: String, icon: String, on: Bool, _ action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.on = on
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: Slate.Typeface.footnote))
                    .foregroundStyle(Slate.Text.secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: Slate.Typeface.base)).foregroundStyle(Slate.Text.primary)
                Spacer()
                if on {
                    Image(systemSymbol: .checkmark).font(.system(size: Slate.Typeface.small, weight: .semibold))
                        .foregroundStyle(Slate.Text.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 26)
            .background(hovering ? Slate.State.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
