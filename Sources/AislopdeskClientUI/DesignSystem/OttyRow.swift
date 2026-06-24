// OttyRow — otty's sidebar/list row idiom on the token layer (REBUILD-V2, L7/L9 → otty-fidelity restyle).
//
// Reconstructs the binary's row hover/selection rule (Docs/05 §4 + ReplicaKit `card`/`hoverBg`):
//   idle     → transparent, icon tint, secondary title
//   hover    → `Otty.State.hover` plate, title → primary
//   selected → a WHITE CARD: `Otty.Surface.selectedCard` fill + a 1px `Otty.Line.card` border + a faint
//              `black@0.04` shadow (radius 2, y 1) — otty's signature white-card-on-paper active tab
//              (ReplicaKit `card`, OttyReplica TabRowView), NOT a flat neutral-gray plate.
// A radius-7 item card, `smallFade` on hover. The whole row is a plain button.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// One navigator/sidebar row: leading SF Symbol + title (+ optional subtitle), with otty hover/selection.
struct OttySidebarRow: View {
    let symbol: SFSymbol
    let title: String
    var subtitle: String?
    /// otty's right-aligned tab badge (e.g. the shell name "zsh"). `nil` ⇒ no badge.
    var badge: String?
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Otty.Metric.space2) {
                Image(systemSymbol: symbol)
                    .font(.system(size: Otty.Metric.iconSize))
                    .foregroundStyle(isSelected ? Otty.Text.primary : Otty.Text.icon)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: Otty.Typeface.base))
                        .foregroundStyle(isSelected ? Otty.Text.primary : Otty.Text.secondary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: Otty.Typeface.small))
                            .foregroundStyle(Otty.Text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: Otty.Typeface.small))
                        .foregroundStyle(Otty.Text.tertiary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, Otty.Metric.space2)
            .padding(.vertical, 6)
            .background { rowBackground }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
        .animation(Otty.Anim.smallFade, value: isSelected)
    }

    /// The selected row is otty's white card (fill + hairline border + faint shadow); hover is a flat plate.
    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Otty.Metric.radiusTab, style: .continuous)
        if isSelected {
            shape
                .fill(Otty.Surface.selectedCard)
                .overlay(shape.strokeBorder(Otty.Line.card, lineWidth: 1))
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        } else if hovering {
            shape.fill(Otty.State.hover)
        } else {
            Color.clear
        }
    }
}

/// A sidebar section header: uppercase, tertiary, small — with an optional trailing accessory (e.g. "+").
struct OttySectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: Otty.Typeface.small, weight: .semibold))
                .foregroundStyle(Otty.State.header)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, Otty.Metric.space2)
        .padding(.top, Otty.Metric.space2)
        .padding(.bottom, Otty.Metric.space1)
    }
}

extension OttySectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
#endif
