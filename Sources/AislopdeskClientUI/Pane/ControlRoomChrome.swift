// ControlRoomChrome — the per-card overlay of the Control Room overview (design-craft big-swing B,
// 2026-07-04). The cards themselves are the LIVE, transform-shrunk tab layers (`SplitContainer` owns
// that); this file draws what sits ON each card: a ring (accent for the tab you came from), a glass
// title chip (session-qualified for a retained non-active session's tab), and a busy dot when any
// pane in the tab is running. The whole layer is the overview's click surface — a card click flies
// into that tab, a backdrop click just exits.

#if canImport(SwiftUI)
import AislopdeskWorkspaceCore
import SwiftUI

/// One overview card's chrome: ring + glass title chip + busy dot. Sized/positioned by the caller
/// to the card's `ControlRoomLayout` slot.
struct ControlRoomCardChrome: View {
    let title: String
    /// Non-nil for a tab of a retained NON-active session — shown as a muted qualifier.
    let sessionName: String?
    /// The tab the user came from (the shown tab) carries the accent ring.
    let isCurrent: Bool
    /// Any pane in the tab has a busy shell — the "something is running here" dot.
    let isBusy: Bool
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: Slate.Metric.paneCornerRadius, style: .continuous)
            .strokeBorder(
                isCurrent ? Slate.theme.accent.opacity(0.45) : GlassPanel.ring,
                lineWidth: hovering ? 2 : 1,
            )
            .background(
                // A whisper of accent lift on hover — the "this card is clickable" cue.
                RoundedRectangle(cornerRadius: Slate.Metric.paneCornerRadius, style: .continuous)
                    .fill(Slate.theme.accent.opacity(hovering ? 0.06 : 0)),
            )
            .overlay(alignment: .bottom) {
                HStack(spacing: 6) {
                    if isBusy {
                        Circle().fill(Slate.theme.accent).frame(width: 6, height: 6)
                    }
                    if let sessionName {
                        Text(sessionName).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(title).foregroundStyle(.primary)
                }
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassPanel(radius: 7, shadowRadius: 8)
                .padding(.bottom, 10)
                .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: Slate.Metric.paneCornerRadius, style: .continuous))
            .onHover { hovering = $0 }
    }
}
#endif
