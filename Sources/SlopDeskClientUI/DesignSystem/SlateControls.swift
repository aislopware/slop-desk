// SlateControls — the reusable chrome controls on the token layer (REBUILD-V2, L6/L9).
//
// The hover-plate button idiom:
//   idle  → transparent plate, icon tint
//   hover → plate fills with `Slate.State.hover`, ~120ms `smallFade`
// No springs — every transition uses the timing curves in `Slate.Anim`.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// A small icon button with a rounded hover plate: transparent when idle, fills on hover.
struct SlatePlateButton: View {
    let symbol: SFSymbol
    var help: String?
    var size: CGFloat = Slate.Metric.iconSize
    var plate: CGFloat = Slate.Metric.plate
    var tint: Color = Slate.Text.icon
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemSymbol: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: plate, height: plate)
                .background(
                    hovering ? Slate.State.hover : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusControl),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .slateHelp(help)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
    }
}

/// The `Menu` twin of ``SlatePlateButton``: the SAME transparent-plate/hover-fill idiom around an icon
/// that drops a menu. `.menuStyle(.button)` + `.buttonStyle(.plain)` are load-bearing — without them a
/// `Menu` renders its label inside the system pull-down bezel, so a menu control sits in a pill while
/// the plate buttons beside it stay flat (two chromes in one bar).
struct SlatePlateMenu<Content: View>: View {
    let symbol: SFSymbol
    var help: String?
    var tint: Color = Slate.Text.icon
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemSymbol: symbol)
                .font(.system(size: Slate.Metric.iconSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: Slate.Metric.plate, height: Slate.Metric.plate)
                .background(
                    hovering ? Slate.State.hover : .clear,
                    in: .rect(cornerRadius: Slate.Metric.radiusControl),
                )
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
        .slateHelp(help)
    }
}

extension View {
    /// Applies a `.help(_:)` only when a tooltip string is present (keeps call sites terse).
    @ViewBuilder
    func slateHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
#endif
