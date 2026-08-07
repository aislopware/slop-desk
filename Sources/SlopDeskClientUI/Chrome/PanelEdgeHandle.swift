// PanelEdgeHandle — the collapsed right panel's reopen affordance: a drawer pull hugging the
// window's TRAILING edge (user-directed 2026-08-07, rail round). It replaced the floating
// titlebar reopen plate: a control floating over the island's top-right corner read as adrift,
// while a handle fused to the very edge the drawer opens from is anchored by construction — the
// visual grammar of a pull tab. Slim and quiet at rest, it steps up a surface rung on hover; the
// chevron points the way the drawer will come. Vertically centred: the middle of the edge is
// where a drawer pull lives, and the island's top corner stays clean.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

struct PanelEdgeHandle: View {
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemSymbol: .chevronLeft)
                .font(.system(size: Slate.Typeface.footnote, weight: .semibold))
                .foregroundStyle(hovering ? Slate.Text.primary : Slate.Text.icon)
                .frame(
                    width: Slate.Metric.edgeHandleThickness,
                    height: Slate.Metric.edgeHandleLength,
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Leading corners only — the trailing side is FUSED to the window edge (a fully rounded
        // pill floating 0pt off the edge would read as another orphan).
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: Slate.Metric.radiusCard,
                bottomLeadingRadius: Slate.Metric.radiusCard,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous,
            )
            .fill(hovering ? Slate.Surface.lift : Slate.Surface.raised),
        )
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .help("Show the right panel")
        .accessibilityLabel("Show the right panel")
    }
}
#endif
