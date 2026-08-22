// TabBadgeView — the trailing-slot marker for one sidebar tab row: ONLY the privilege modifiers, in
// otty's own drawings (a shield for sudo, a duotone cup for caffeinate) on the muted metadata ink.
// The lifecycle states never render here — every lifecycle state is the trailing status mark
// (`StatusPresentation.statusDot`) — so this view renders NOTHING for them and the slot falls
// through to the shell label. One marker in a fixed 16pt box: state changes never move a pixel of
// layout.
//
// Hang-safety (CLAUDE.md rule #6): a badge NEVER instantiates an `SCStream` / `VTCompressionSession` /
// `VTDecompressionSession` / Metal device — plain SwiftUI drawing, nothing more.

#if os(iOS)
import SFSafeSymbols
import SlopDeskSlate
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

/// The privilege marker for one sidebar tab row. Renders nothing for the lifecycle kinds (those
/// speak through the status mark); AX-labelled so the terse glyph is VoiceOver-legible.
struct TabBadgeView: View {
    let kind: TabBadgeKind

    /// The marker box is 16pt (the `StatusGlyph` box); the glyph centers in this fixed box so rows
    /// keep a stable trailing edge while states swap.
    static let side: CGFloat = 16
    /// The side the vector cup is drawn into — otty's badge box, the same one the rail's hand uses.
    static let artSide: CGFloat = 14

    var body: some View {
        if let style = StatusPresentation.tabBadge(kind) {
            art(style)
                .frame(width: Self.side, height: Self.side)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StatusPresentation.tabBadgeLabel(kind))
                .help(StatusPresentation.tabBadgeLabel(kind))
        }
    }

    @ViewBuilder
    private func art(_ style: TabBadgeStyle) -> some View {
        switch style.art {
        case let .symbol(symbol):
            Image(systemSymbol: symbol)
                .font(.system(size: StatusDot.badgeSymbolSize, weight: StatusDot.symbolWeight))
                .foregroundStyle(style.tint)
        case let .vector(icon):
            VectorIconView(icon: icon, side: Self.artSide, ink: style.tint)
        }
    }
}
#endif
