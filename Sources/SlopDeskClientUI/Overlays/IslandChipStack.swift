// IslandChipStack — the transient + durable chips that stand at the FOOT OF THE ISLAND.
//
// These three used to hang off the window root (`OverlayHostView`), which put them at the bottom
// centre of the WINDOW — a point that includes the navigator and the code panel, so the stack drifted
// off the terminal it was talking about, and its 16pt window inset parked it right on the island's
// bottom edge, over the live prompt line (user-reported 2026-08-09). Mounted on the pane canvas
// instead, the stack is centred on the ISLAND and stands clear of its foot; ``Metric/islandChipInset``
// is the whole of that clearance.
//
// The chips also draw in the glass's own vocabulary now — see ``InstrumentChipShell``. The semantic
// `Slate.Text` / `Slate.Surface` tiers are pinned on the light side, so over `#22212C` they rendered as
// dark ink on a fill that barely registered.
//
// `Slate.*` tokens only (the ds-leaks ratchet).

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel
import SwiftUI

struct IslandChipStack: View {
    let store: WorkspaceStore
    /// The scene overlay reducer — owns the window-level copy receipt + the transient notice.
    let coordinator: OverlayCoordinator
    /// Whether the tabs panel is collapsed — the durable connection indicator shows ONLY then (an open
    /// sidebar is the user's normal per-pane surface).
    let sidebarCollapsed: Bool

    /// Read ONCE per body so the chip and its fade animation agree on the same value. Reading
    /// `store.connectionAlert()` registers observation on each pane's `ConnectionViewModel.status`, so the
    /// chip appears / updates / disappears as panes drop and recover.
    private var connectionAlert: WorkspaceConnectionAlert? { store.connectionAlert() }

    var body: some View {
        VStack(spacing: Slate.Metric.space2) {
            if let receipt = coordinator.copyReceipt {
                CopyReceiptChip(receipt: receipt, onExpire: { coordinator.clearCopyReceipt() })
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let notice = coordinator.notice {
                NoticeChip(notice: notice, onExpire: { coordinator.clearNotice() })
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if sidebarCollapsed, let alert = connectionAlert {
                ConnectionAlertChip(alert: alert) { store.jumpToPaneTree(alert.worstPane) }
                    .transition(.opacity)
            }
        }
        // ⚠️ The hit-transparency is PER CHIP, never on this stack: `allowsHitTesting(false)` on an
        // ancestor suppresses hits for everything composed into it, so a flag here would also deafen
        // the connection chip's Button (the lesson `OverlayHostView`'s two-layer note records).
        .padding(.bottom, Slate.Metric.islandChipInset)
        .animation(Slate.Anim.smallFade, value: connectionAlert)
        .animation(Slate.Anim.smallFade, value: coordinator.copyReceipt)
        .animation(Slate.Anim.smallFade, value: coordinator.notice)
    }
}

// MARK: - ConnectionAlertChip (the durable collapsed-sidebar connection indicator)

/// The compact connection-health chip: an amber/red status dot + a count label
/// ("1 reconnecting" / "2 disconnected") shown at the island's foot while the tabs panel is collapsed and
/// some pane is unhealthy. A `Button` (unlike the non-interactive receipt chips) so a click focuses the
/// worst-affected pane. Drawn in the GLASS's vocabulary for the reason the whole family is — see
/// ``InstrumentChipShell``; the status DOT keeps the shared roles, because a health signal is the one
/// thing here that is not on-glass typography.
struct ConnectionAlertChip: View {
    let alert: WorkspaceConnectionAlert
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Slate.Metric.space1) {
                Circle()
                    .fill(Self.tint(for: alert.worst))
                    .frame(width: 7, height: 7)
                Text(alert.label)
                    .font(.system(size: Slate.Typeface.footnote, weight: .medium))
                    .foregroundStyle(Slate.Terminal.ink2)
            }
            .padding(.horizontal, Slate.Metric.space2)
            .padding(.vertical, Slate.Metric.space1)
            .background(Slate.Terminal.raised, in: .rect(cornerRadius: Slate.Metric.radiusControl))
            .overlay(
                RoundedRectangle(cornerRadius: Slate.Metric.radiusControl)
                    .strokeBorder(Slate.Terminal.edge, lineWidth: Slate.Metric.hairline),
            )
        }
        .buttonStyle(.plain)
        .help("\(alert.label) — click to focus the affected pane")
        .accessibilityLabel("\(alert.label). Click to focus the affected pane.")
    }

    /// Amber while a drop is recovering (`.reconnecting`), red once it is down (`.failed` / `.unreachable`) —
    /// the same status roles the toolbar connection pill (`StatusPresentation`) uses.
    private static func tint(for severity: WorkspaceConnectionAlert.Severity) -> Color {
        switch severity {
        case .reconnecting: Slate.Status.warn
        case .failed,
             .unreachable: Slate.Status.err
        }
    }
}
#endif
