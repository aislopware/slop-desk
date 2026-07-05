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

extension View {
    /// Applies a `.help(_:)` only when a tooltip string is present (keeps call sites terse).
    @ViewBuilder
    func slateHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
#endif
