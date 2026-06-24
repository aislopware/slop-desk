// OttyControls — the reusable otty chrome controls on the token layer (REBUILD-V2, L6/L9).
//
// Adapted from the reverse-engineering's `Sources/UI/ReplicaKit.swift` (`PlateIconButton`) + the hover
// rule extracted from the binary CSS (Docs/05 §4):
//   idle  → transparent plate, icon tint
//   hover → plate fills with `Otty.State.hover`, ~120ms `smallFade`
// No springs — every transition uses the otty timing curves in `Otty.Anim`.

#if canImport(SwiftUI)
import SwiftUI

/// A small icon button with a rounded hover plate — otty's `PanelToggleButton`/`HoverIconButton` idiom.
struct OttyPlateButton: View {
    let systemName: String
    var help: String?
    var size: CGFloat = Otty.Metric.iconSize
    var plate: CGFloat = Otty.Metric.plate
    var tint: Color = Otty.Text.icon
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: plate, height: plate)
                .background(
                    hovering ? Otty.State.hover : .clear,
                    in: .rect(cornerRadius: Otty.Metric.radiusControl),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .ottyHelp(help)
        .onHover { hovering = $0 }
        .animation(Otty.Anim.smallFade, value: hovering)
    }
}

extension View {
    /// Applies a `.help(_:)` only when a tooltip string is present (keeps call sites terse).
    @ViewBuilder
    func ottyHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
#endif
