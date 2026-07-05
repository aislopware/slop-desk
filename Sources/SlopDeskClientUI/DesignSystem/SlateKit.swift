// SlateKit — small reusable chrome controls built on the polished `Slate` token layer (SlateDesign.swift):
//   • `PlateIconButton` — the hover-plate icon button: a borderless SF-Symbol button that grows a faint
//     rounded hover plate, 0.12s small-fade. Used by the titlebar + sidebar chrome.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// A hover-plate icon button — a borderless SF-Symbol with a faint rounded hover plate (radius 6).
struct PlateIconButton: View {
    let symbol: SFSymbol
    var size: CGFloat = Slate.Metric.iconSize
    var plate: CGFloat = Slate.Metric.plate
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemSymbol: symbol)
                .font(.system(size: size))
                .foregroundStyle(Slate.Text.icon)
                .frame(width: plate, height: plate)
                .background(hovering ? Slate.State.hover : .clear, in: .rect(cornerRadius: Slate.Metric.radiusControl))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Slate.Anim.smallFade, value: hovering)
    }
}
#endif
