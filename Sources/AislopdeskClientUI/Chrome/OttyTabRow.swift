// OttyTabRow — otty's sidebar tab row (`TabsPanelRowView`) + the sort/group hamburger (`SortMenuButton`),
// ported from /Volumes/Lacie/Workspace/oss/otty-reversed (`OttyReplica.swift`) onto the `Otty` tokens and
// wired to the live store via the navigator. The resting row is the tab name on the warm sidebar; ACTIVE is
// otty's signature WHITE CARD (radius-7 fill + 1px cardBorder + faint shadow), hover is a flat plate, and a
// close `×` reveals on hover. No native list selection / vibrancy — this is the flat otty silhouette.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// One sidebar tab row. ACTIVE = white card (otty's active-tab treatment); hover = flat plate + close `×`.
struct OttyTabRow: View {
    let title: String
    let active: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var hovering = false
    @State private var closeHover = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: Otty.Typeface.body, weight: active ? .medium : .regular))
                .foregroundStyle(Otty.Text.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            closeButton
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(rowBackground, in: .rect(cornerRadius: Otty.Metric.radiusTab))
        .overlay { if active { RoundedRectangle(cornerRadius: Otty.Metric.radiusTab).strokeBorder(
            Otty.Line.card,
            lineWidth: 1,
        ) } }
        .shadow(color: active ? .black.opacity(0.04) : .clear, radius: 2, y: 1)
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
        .animation(Otty.Anim.smallFade, value: active)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemSymbol: .xmark)
                .font(.system(size: Otty.Typeface.small, weight: .medium))
                .foregroundStyle(Otty.Text.icon)
                .frame(width: 18, height: 18)
                .background(closeHover ? Otty.State.selected : .clear, in: .rect(cornerRadius: Otty.Metric.radiusSmall))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { closeHover = $0 }
    }

    private var rowBackground: Color {
        if active { Otty.Surface.selectedCard }
        else if hovering { Otty.State.hover }
        else { .clear }
    }
}

/// otty's sidebar hamburger — a sort/group popover (`SortMenuButton`). Grouping/order are presentational for
/// now (otty's own affordance); the row is the flat-icon button beside the "TABS" header.
struct OttySortMenuButton: View {
    @State private var show = false
    @State private var group = 0 // 0 No Grouping · 1 By Project · 2 By Date
    @State private var order = 0 // 0 Created · 1 Updated

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemSymbol: .line3Horizontal)
                .font(.system(size: Otty.Typeface.footnote))
                .foregroundStyle(Otty.Text.icon)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            SortSection("GROUP")
            SortRow("No Grouping", icon: "list.bullet", on: group == 0) { group = 0 }
            SortRow("By Project", icon: "folder", on: group == 1) { group = 1 }
            SortRow("By Date", icon: "calendar", on: group == 2) { group = 2 }
            SortDivider()
            SortSection("ORDER")
            SortRow("Created Time", icon: "clock", on: order == 0) { order = 0 }
            SortRow("Updated Time", icon: "clock.arrow.circlepath", on: order == 1) { order = 1 }
        }
        .padding(.vertical, 6)
        .frame(width: 210)
    }
}

private struct SortSection: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: Otty.Typeface.small, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Otty.State.header)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SortDivider: View {
    var body: some View {
        Rectangle().fill(Otty.Line.divider).frame(height: 1)
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
                Image(systemName: icon).font(.system(size: Otty.Typeface.footnote)).foregroundStyle(Otty.Text.secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: Otty.Typeface.base)).foregroundStyle(Otty.Text.primary)
                Spacer()
                if on {
                    Image(systemSymbol: .checkmark).font(.system(size: Otty.Typeface.small, weight: .semibold))
                        .foregroundStyle(Otty.Text.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 26)
            .background(hovering ? Otty.State.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
