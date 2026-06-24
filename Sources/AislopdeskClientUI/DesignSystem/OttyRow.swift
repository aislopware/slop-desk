// OttyRow — otty's sidebar/list row idiom on the token layer (REBUILD-V2, L7/L9).
//
// Reconstructs the binary's row hover/selection rule (Docs/05 §4 + ReplicaKit `selRow`/`hoverBg`):
//   idle     → transparent, icon tint, secondary title
//   hover    → `Otty.State.hover` plate, title → primary
//   selected → `Otty.State.selected` (NEUTRAL gray, NOT accent), title → primary
// A radius-6 item plate, 8pt padding, `smallFade` on hover. The whole row is a plain button.

#if canImport(SwiftUI)
import SwiftUI

/// One navigator/sidebar row: leading SF Symbol + title (+ optional subtitle), with otty hover/selection.
struct OttySidebarRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Otty.Metric.space2) {
                Image(systemName: systemImage)
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
            }
            .padding(.horizontal, Otty.Metric.space2)
            .padding(.vertical, 5)
            .background(rowBackground, in: .rect(cornerRadius: Otty.Metric.radiusItem))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
    }

    private var rowBackground: Color {
        if isSelected { Otty.State.selected }
        else if hovering { Otty.State.hover }
        else { .clear }
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
