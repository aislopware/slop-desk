// CopyReceiptChip — the transient `COPIED · 1,204 CHARS` confirmation chip, the ONE view behind both
// copy-confirmation mounts: bottom-trailing INSIDE the pane for pane-scoped copies (⌘C selection,
// copy-mode yank, navigator / hint copies — feedback lives at its trigger), and bottom-center at the
// window level for pane-less copies (palette "Copy Path", rail "Copy Window Title" — their trigger
// sheet/menu is gone by the time the write lands, the Raycast-HUD case).
//
// Deliberately NOT a toast: a toast card on a high-frequency terminal action reads as spam and can
// occlude the prompt line (the ghostty `app-notifications = no-clipboard-copy` lesson). This is a
// fade-only chip — no spatial travel, no icon, no layout shift anywhere: pure typography in the
// instrument voice carrying the one number that answers "did I get the whole thing?". A rapid re-copy
// RETARGETS the mounted chip (the count hard-cuts, `.task(id: epoch)` restarts the dwell) rather than
// re-animating — mechanical, per MERIDIAN L4.
//
// `Slate.*` tokens only (the ds-leaks ratchet). The wording lives on the pure `CopyReceipt` (pinned by
// `CopyReceiptTests`), never composed here.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

struct CopyReceiptChip: View {
    /// How long the chip dwells before expiring — long enough to read a short count at a glance,
    /// short enough that the pane is ornament-free again before the next thought.
    static let dwell: Duration = .seconds(1.5)

    let receipt: CopyReceipt
    /// Called when the dwell elapses — the owner clears its receipt (`clearCopyReceipt()`), unmounting
    /// the chip through the fade the mount site animates.
    let onExpire: () -> Void

    var body: some View {
        HStack(spacing: Slate.Metric.space1) {
            Text("COPIED")
                .foregroundStyle(Slate.Text.secondary)
            Text("·")
                .foregroundStyle(Slate.Text.tertiary)
            Text(receipt.detail)
                .foregroundStyle(Slate.Text.primary)
        }
        // The shared instrument-chip treatment (`InstrumentChipShell`) — one shell for this chip and
        // every `NoticeChip`, so the two can never drift apart visually.
        .modifier(InstrumentChipShell(accessibility: receipt.label))
        // Dwell timer, keyed on the receipt's epoch: a re-copy while mounted restarts it (the retarget).
        // A CANCELLED sleep must NOT expire — cancellation means either a newer receipt owns the chip
        // or the chip unmounted; calling `onExpire` then would kill the successor's dwell.
        .task(id: receipt.epoch) {
            guard await (try? Task.sleep(for: Self.dwell)) != nil else { return }
            onExpire()
        }
    }
}
#endif
