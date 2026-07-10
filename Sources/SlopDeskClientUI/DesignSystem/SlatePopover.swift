// SlatePopover — the shared popover-menu chrome (MERIDIAN C3). ONE section-header / row / divider
// vocabulary for every Slate popover (the sidebar sort/group menu, the titlebar's pane menu), so the
// menus can't drift apart in voice or metrics: sections speak the INSTRUMENT voice (L2 — the same
// register as `SlateSectionHeader`), rows are flat hover-plate buttons on the popover ground with ONE
// trailing complication (a selection checkmark or a chord glyph), and the divider is the standard
// hairline. Before C3 the two menus each carried a private copy of all three (SortSection/SortRow/
// SortDivider vs TitleMenuSection/TitleMenuRow/TitleMenuDivider) and had already drifted — different
// row heights, icon colours, and section paddings.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// The caps micro-label heading a popover section ("GROUP", "WORKING DIRECTORY").
struct SlatePopoverSection: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Slate.Typeface.instrument(Slate.Typeface.small, weight: .semibold))
            .tracking(Slate.Typeface.instrumentTracking)
            .foregroundStyle(Slate.State.header)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Slate.Metric.space3)
            .padding(.top, Slate.Metric.space2)
            .padding(.bottom, 2)
    }
}

/// The hairline rule between popover sections.
struct SlatePopoverDivider: View {
    var body: some View {
        Rectangle().fill(Slate.Line.divider).frame(height: Slate.Metric.hairline)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
    }
}

/// One popover menu row: an optional leading icon, the title, and ONE trailing complication — the
/// selection `checked`mark (the sort menu) or a `shortcut` chord glyph (the pane menu); never both
/// (a checked row's state IS its trailing meaning). Flat hover plate, `heightBar` tall.
struct SlatePopoverRow: View {
    var icon: String?
    /// A bespoke leading glyph occupying the icon slot (e.g. a status-badge view) — wins over `icon`.
    /// Type-erased so the row stays non-generic (menu rows, never a hot path).
    var leading: AnyView?
    let title: String
    var shortcut: String?
    var checked: Bool
    /// Muted title — a read-only info row (e.g. the working-directory path), not an action.
    var dim: Bool
    var action: () -> Void

    init(
        _ title: String,
        icon: String? = nil,
        shortcut: String? = nil,
        checked: Bool = false,
        dim: Bool = false,
        action: @escaping () -> Void,
    ) {
        self.title = title
        self.icon = icon
        leading = nil
        self.shortcut = shortcut
        self.checked = checked
        self.dim = dim
        self.action = action
    }

    /// A row whose leading slot carries a bespoke VIEW (the NEEDS-ATTENTION rows reuse the sidebar's
    /// ``TabBadgeView`` glyph here, so the menu and the rail speak one status vocabulary).
    init(
        _ title: String,
        leading: some View,
        shortcut: String? = nil,
        checked: Bool = false,
        dim: Bool = false,
        action: @escaping () -> Void,
    ) {
        self.title = title
        icon = nil
        self.leading = AnyView(leading)
        self.shortcut = shortcut
        self.checked = checked
        self.dim = dim
        self.action = action
    }

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Slate.Metric.space2) {
                if let leading {
                    leading.frame(width: 16)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.secondary)
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: Slate.Typeface.base))
                    .foregroundStyle(dim ? Slate.Text.secondary : Slate.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Slate.Metric.space2)
                if checked {
                    Image(systemSymbol: .checkmark)
                        .font(.system(size: Slate.Typeface.small, weight: .semibold))
                        .foregroundStyle(Slate.Text.secondary)
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: Slate.Typeface.footnote))
                        .foregroundStyle(Slate.Text.secondary)
                }
            }
            .padding(.horizontal, Slate.Metric.space3)
            .frame(height: Slate.Metric.heightBar)
            .background(hovering ? Slate.State.hover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
