// IslandChipStack — the transient + durable chips that stand at the FOOT OF THE ISLAND.
//
// These three used to hang off the window root (`OverlayHostView`), which put them at the bottom
// centre of the WINDOW — a point that includes the navigator and the code panel, so the stack drifted
// off the terminal it was talking about, and its 16pt window inset parked it right on the island's
// bottom edge, over the live prompt line (user-reported 2026-08-09). Mounted on the pane canvas
// instead, the stack is centred on the ISLAND and stands clear of its foot; ``Metric/islandChipInset``
// is the whole of that clearance.
//
// ⚠️ THE TWO TRANSIENT CHIPS ARE PAPER; THE DURABLE ONE IS GLASS, and the line between them is DURATION.
// A notice ARRIVES and leaves — it is a message from the app, so it wears the floating family's paper
// capsule (``SlatePaperCapsule``, which carries the measurements). The connection chip LIVES here for as
// long as a pane is unhealthy, and a cream plate glowing over the terminal for minutes is the glare the
// transient pair is small and short-lived enough to avoid — so it stays in the glass's own vocabulary
// (``InstrumentChipShell``'s ink tiers), where a persistent object belongs.
//
// The stack also gained the pane-scoped copy receipt (user-directed 2026-08-11): a copy used to confirm
// itself bottom-trailing INSIDE its pane, so one event had two homes. Now every copy speaks from here.
//
// `Slate.*` tokens only (the ds-leaks ratchet).

#if canImport(SwiftUI)
import SlopDeskClientCore
import SlopDeskWorkspaceCore
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

    /// THE copy receipt — whichever of the two owners has one. A copy is one event with one home now
    /// (user-directed 2026-08-11): pane-scoped copies publish on the active pane's model and pane-less ones
    /// (palette "Copy Path", rail "Copy Window Title") on the coordinator, but both surface HERE.
    ///
    /// The coordinator wins a tie because it is the later, more deliberate act: a pane-less copy is an
    /// explicit menu/palette command, while a pane receipt may be seconds-stale ⌘C. In practice they do not
    /// collide — one copy happens at a time — and the chip's dwell is keyed on the whole receipt, so a
    /// hand-off between the two owners still restarts the clock.
    private var copyReceipt: CopyReceipt? { coordinator.copyReceipt ?? store.activePaneCopyReceipt() }

    var body: some View {
        VStack(spacing: Slate.Metric.space2) {
            if let receipt = copyReceipt {
                CopyReceiptChip(receipt: receipt, onExpire: clearCopyReceipt)
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
        .animation(Slate.Anim.smallFade, value: copyReceipt)
        .animation(Slate.Anim.smallFade, value: coordinator.notice)
    }

    /// Expiry clears BOTH owners. Each is idempotent and only one can be non-nil at a time in practice, so
    /// this cannot strand a receipt the other owner still wants shown — while clearing only the winner
    /// would leave the loser's stale receipt to pop straight back the moment the chip faded out.
    private func clearCopyReceipt() {
        coordinator.clearCopyReceipt()
        store.clearActivePaneCopyReceipt()
    }
}

// MARK: - ConnectionAlertChip (the durable collapsed-sidebar connection indicator)

/// The compact connection-health chip: an amber/red status dot + a count label
/// ("1 reconnecting" / "2 disconnected") shown at the island's foot while the tabs panel is collapsed and
/// some pane is unhealthy. A `Button` (unlike the non-interactive receipt chips) so a click focuses the
/// worst-affected pane.
///
/// ONE SILHOUETTE, TWO MATERIALS. It shares the notice capsule's shape, size and rhythm — same capsule,
/// same padding, same type size — so the column reads as one family; it keeps the GLASS's own palette
/// because it is the DURABLE member (see this file's header: a cream plate glowing over the terminal for
/// as long as a pane stays down is the glare the transient pair is short-lived enough to avoid). Matching
/// the shape is what keeps that material difference reading as a ROLE rather than as two unrelated chips
/// stacked by accident.
///
/// ⚠️ Its label is ``Slate/Terminal/ink``, not `ink2`. The comment ink measures **2.19 : 1** on this
/// plate — the very number that sent the transient chips to paper (``SlatePaperCapsule``), and this chip
/// carried it too, unnoticed, while saying that a connection is DOWN. On the glass the primary ink is the
/// only rung that clears the plate (9.16 : 1), and a durable alarm has no excuse to whisper.
struct ConnectionAlertChip: View {
    let alert: WorkspaceConnectionAlert
    let onTap: () -> Void

    /// The status dot's diameter — off the grid, matched to the capsule's type size rather than picked.
    private var dotSize: CGFloat { Slate.Metric.space2 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Slate.Metric.space1) {
                Circle()
                    .fill(Self.tint(for: alert.worst))
                    .frame(width: dotSize, height: dotSize)
                Text(alert.label)
                    .font(.system(size: Slate.Typeface.base, weight: .medium))
                    .foregroundStyle(Slate.Terminal.ink)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Slate.Metric.space4)
            .padding(.vertical, Slate.Metric.space2)
            .background(Slate.Terminal.raised, in: .capsule)
            // ``Slate/Terminal/rim``, never `edge` — `edge` matches the plate's own tone and draws
            // nothing (the 2026-08-10 invisible-border fix, which this chip shares).
            .overlay { Capsule().strokeBorder(Slate.Terminal.rim, lineWidth: Slate.Metric.hairline) }
            // ⚠️ The rim's whisker clip — see ``SlatePaperCapsule``, which carries the diagnosis. This is
            // the chip the ticks were CAUGHT on, because its rim is the one with real contrast: on the
            // cream the same defect is there and simply too faint to see, which is exactly why the fix
            // belongs to the SILHOUETTE and not to whichever member happened to expose it.
            .clipShape(.capsule)
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
