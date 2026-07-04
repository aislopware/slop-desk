// SlateRow — the sidebar/list row idiom on the token layer (REBUILD-V2, L7/L9 restyle).
//
// Row hover/selection rule:
//   idle     → transparent, icon tint, secondary title
//   hover    → `Slate.State.hover` plate, title → primary
//   selected → a WHITE CARD: `Slate.Surface.selectedCard` fill + a 1px `Slate.Line.card` border + a faint
//              `black@0.04` shadow (radius 2, y 1) — a white-card-on-paper active tab, NOT a flat
//              neutral-gray plate.
// A radius-7 item card, `smallFade` on hover. The whole row is a plain button.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// One navigator/sidebar row: leading SF Symbol + title (+ optional subtitle), with hover/selection styling.
struct SlateSidebarRow: View {
    let symbol: SFSymbol
    let title: String
    var subtitle: String?
    /// A right-aligned tab badge (e.g. the shell name "zsh"). `nil` ⇒ no badge.
    var badge: String?
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Slate.Metric.space2) {
                Image(systemSymbol: symbol)
                    .font(.system(size: Slate.Metric.iconSize))
                    .foregroundStyle(isSelected ? Slate.Text.primary : Slate.Text.icon)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: Slate.Typeface.base))
                        .foregroundStyle(isSelected ? Slate.Text.primary : Slate.Text.secondary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: Slate.Typeface.small))
                            .foregroundStyle(Slate.Text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: Slate.Typeface.small))
                        .foregroundStyle(Slate.Text.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, 6)
            .background { rowBackground }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .animation(Slate.Anim.smallFade, value: isSelected)
    }

    /// The selected row is a white card (fill + hairline border + faint shadow); hover is a flat plate.
    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Slate.Metric.radiusTab, style: .continuous)
        if isSelected {
            shape
                .fill(Slate.Surface.selectedCard)
                .overlay(shape.strokeBorder(Slate.Line.card, lineWidth: 1))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        } else if hovering {
            shape.fill(Slate.State.hover)
        } else {
            Color.clear
        }
    }
}

/// A sidebar section header: uppercase, tertiary, small — with an optional trailing accessory (e.g. "+").
struct SlateSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: Slate.Typeface.small, weight: .semibold))
                .foregroundStyle(Slate.State.header)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, Slate.Metric.space2)
        .padding(.top, Slate.Metric.space2)
        .padding(.bottom, Slate.Metric.space1)
    }
}

extension SlateSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
#endif
