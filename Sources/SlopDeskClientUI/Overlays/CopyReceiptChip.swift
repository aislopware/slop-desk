// CopyReceiptChip — the transient `Copied · 1,204 characters` confirmation chip.
//
// ONE MOUNT, at the foot of the ISLAND (``IslandChipStack``), for every copy the app makes: the
// pane-scoped ones (⌘C selection, copy-mode yank, navigator / hint copies) and the pane-less ones
// (palette "Copy Path", rail "Copy Window Title"). It used to have TWO — pane-scoped copies drew
// bottom-trailing INSIDE the pane on a "feedback lives at its trigger" rationale, pane-less ones at the
// island's foot — so ONE event had two homes and the user had to learn both to know where to look
// (user-directed 2026-08-11). The trigger rationale did not survive the split it created: a copy is the
// same event wherever it starts, and the island's foot is the one place every notice in this family
// already speaks from.
//
// Deliberately NOT a toast: a toast card on a high-frequency terminal action reads as spam and can
// occlude the prompt line (the ghostty `app-notifications = no-clipboard-copy` lesson). This is a
// fade-only chip — no spatial travel, no icon, no layout shift anywhere: pure typography carrying the one
// number that answers "did I get the whole thing?". A rapid re-copy RETARGETS the mounted chip (the count
// hard-cuts, the dwell restarts) rather than re-animating — mechanical, per MERIDIAN L4.
//
// `Slate.*` tokens only (the ds-leaks ratchet). The wording lives on the pure `CopyReceipt` (pinned by
// `CopyReceiptTests`), never composed here; the FORM is ``NoticeCapsule``, shared with every `NoticeChip`.

#if canImport(SwiftUI)
import SlopDeskWorkspaceCore
import SwiftUI

struct CopyReceiptChip: View {
    let receipt: CopyReceipt
    /// Called when the dwell elapses — the owner clears its receipt (`clearCopyReceipt()`), unmounting
    /// the chip through the fade the mount site animates.
    let onExpire: () -> Void

    var body: some View {
        // The shared capsule (`NoticeCapsule`) — one form for this chip and every `NoticeChip`, so the
        // two can never drift apart visually.
        NoticeCapsule(label: "Copied", detail: receipt.detail, accessibility: receipt.label)
            // Dwell timer keyed on the WHOLE receipt, not on `epoch` alone. Epoch was enough while one
            // owner minted every receipt; now that the single mount is fed by two independent counters
            // (the pane model's and the overlay coordinator's, ``IslandChipStack``), two different copies
            // can carry the same epoch number and the chip would inherit the dead one's nearly-elapsed
            // timer — the exact bug epoch exists to prevent, arriving by a new route. `CopyReceipt` is
            // `Equatable` over its counts too, so a hand-off only fails to restart when the two receipts
            // are indistinguishable, where restarting would change nothing.
            //
            // A CANCELLED sleep must NOT expire — cancellation means either a newer receipt owns the chip
            // or the chip unmounted; calling `onExpire` then would kill the successor's dwell.
            .task(id: receipt) {
                guard await (try? Task.sleep(for: CopyReceipt.dwell)) != nil else { return }
                onExpire()
            }
    }
}
#endif
