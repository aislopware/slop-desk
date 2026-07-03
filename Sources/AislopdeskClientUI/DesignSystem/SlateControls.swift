// SlateControls — small reusable chrome controls, styled NATIVELY (system semantic styles; the Slate
// token layer is retiring from chrome — native-chrome migration, 2026-07-03).
//
// The hover-plate button idiom survives (idle → transparent plate; hover → a faint fill) because macOS
// borderless buttons outside a toolbar show no hover affordance of their own — but the colors/timing are
// system-semantic now, not theme tokens.

#if canImport(SwiftUI)
import SFSafeSymbols
import SwiftUI

/// A small icon button with a rounded hover plate: transparent when idle, fills faintly on hover.
struct SlatePlateButton: View {
    let symbol: SFSymbol
    var help: String?
    var size: CGFloat = 13
    var plate: CGFloat = 24
    var tint: Color = .secondary
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemSymbol: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: plate, height: plate)
                .background(
                    hovering ? Color.primary.opacity(0.08) : .clear,
                    in: .rect(cornerRadius: 6),
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .slateHelp(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
