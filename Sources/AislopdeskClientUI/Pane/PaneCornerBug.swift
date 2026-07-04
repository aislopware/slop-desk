// PaneCornerBug — the FLEET corner ornament (visible-design pass, 2026-07-04): every pane card
// permanently carries a small broadcast-multiview-style "bug" in its top-leading corner — the
// session's identity dot (solid while the shell is busy, dimmed at rest) plus the tab's name on a
// tiny glass chip. The camera-wall idiom: with several cards up, the canvas reads as a monitoring
// wall — which agent is which, and which ones are working, at a glance, without focusing anything.
//
// Discipline: fixed corner (identity must sit in the SAME place on every card, or it isn't a bug,
// it's clutter), caption2 + glass so it whispers over content, top-LEADING because the top-trailing
// corner belongs to the transient pill stack (vi/read-only/secure/elapsed/find). Never hit-tests —
// clicks land on the terminal underneath.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

struct PaneCornerBug: View {
    let store: WorkspaceStore
    let paneID: PaneID
    /// The owning tab's display name — the card's identity line on the wall.
    let title: String
    /// The owner SESSION's identity colour (per-session colour identity, 2026-07-04).
    let accent: Color

    /// The idle dot's knock-back — rest whispers, busy is solid.
    static let idleDotOpacity: Double = 0.45

    var body: some View {
        let busy = store.paneIsBusy(paneID)
        HStack(spacing: 5) {
            Circle()
                .fill(accent.opacity(busy ? 1 : Self.idleDotOpacity))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .glassPanel(radius: 6, shadowRadius: 4)
        .allowsHitTesting(false)
        .accessibilityLabel(busy ? "\(title), running" : title)
    }
}
#endif
