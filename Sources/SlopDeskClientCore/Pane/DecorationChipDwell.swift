// DecorationChipDwell — what a transient island chip SAYS, and how long it says it for
//
// The island's two transient chips (the copy receipt and the notice) are a capsule with a label, an
// optional keycap, a detail and a clock. Three of those four are values, and the clock is a `Timer`
// over a `Duration` — Foundation on both shells, with no AppKit or UIKit member anywhere in it. Both
// shells nevertheless carried:
//
//   * the same seven-parameter `present` signature, and the same five-line argument list per caller;
//   * the same `identity`/`dwellTimer`/`onExpire` triple;
//   * the same `stopDwell`/`restartDwell` pair, down to the `attoseconds / 1e18` conversion and the
//     `MainActor.assumeIsolated` inside the timer's callback.
//
// ⚠️ THE IDENTITY GATE IS THE POINT, NOT THE TIMER. A chip that is re-targeted while its clock runs
// must restart the clock ONLY when the new content is a different event — a re-apply of the same
// receipt has to leave the running dwell alone, or a repeating observation would keep a chip on
// screen forever. That rule is the reason this is one implementation: it is the kind of condition a
// second copy gets subtly wrong (keying on `epoch` alone, which is the bug the receipt's comment
// records) while still looking right.

import Foundation
import SlopDeskSlate
import SlopDeskWorkspaceCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Everything a transient chip draws, in the order it draws it, plus the clock it runs on.
///
/// It exists so the two shells' `present` is ONE argument rather than six — the six were identical at
/// every call site, and a value that both halves build the same way is a value, not a signature.
package struct DecorationChipCopy {
    package let label: String
    /// The chord the chip offers, drawn as a KEYCAP rather than as text. `nil` when there is nothing
    /// to press, which is most notices.
    package let keycap: String?
    package let detail: String
    /// The one-string spoken form — the full sentence, uncut.
    package let accessibility: String
    /// What makes this a DIFFERENT event from the last one. A re-apply carrying the same identity
    /// leaves the running dwell alone.
    package let identity: AnyHashable
    package let dwell: Duration

    package init(
        label: String,
        keycap: String?,
        detail: String,
        accessibility: String,
        identity: AnyHashable,
        dwell: Duration,
    ) {
        self.label = label
        self.keycap = keycap
        self.detail = detail
        self.accessibility = accessibility
        self.identity = identity
        self.dwell = dwell
    }

    /// A clipboard-copy confirmation.
    ///
    /// Keyed on the WHOLE receipt, not on `epoch` alone: the single mount is fed by two independent
    /// counters, so two different copies can carry the same epoch and the chip would inherit the dead
    /// one's nearly-elapsed timer — the exact bug epoch exists to prevent, arriving by a new route.
    /// `CopyReceipt` is `Equatable` over its counts too, so a hand-off only fails to restart when the
    /// two receipts are indistinguishable, where restarting would change nothing.
    package static func receipt(_ receipt: CopyReceipt) -> Self {
        Self(
            label: CopyReceiptChip.label,
            keycap: nil,
            detail: receipt.detail,
            accessibility: receipt.label,
            identity: AnyHashable(receipt),
            dwell: CopyReceipt.dwell,
        )
    }

    /// A transient `label · detail` notice, whose own epoch is already the event identity.
    package static func notice(_ notice: ChipNotice) -> Self {
        Self(
            label: notice.label,
            keycap: notice.keycap,
            detail: notice.detail,
            accessibility: notice.accessibilityText,
            identity: AnyHashable(notice.epoch),
            dwell: notice.dwell,
        )
    }
}

/// The transient chip's clock: one shot, restarted per identity.
///
/// A `Timer` rather than a `Task`, so a chip that is re-targeted mid-dwell cannot leave a cancelled
/// sleep to fire the OLD owner's expiry — the failure the deleted SwiftUI half spent its
/// `guard await (try? …) != nil` on.
@MainActor
package final class DecorationChipDwell {
    private var identity: AnyHashable?
    private var timer: Timer?
    /// Re-set on every apply, so an expiry always calls the CURRENT owner's clear.
    private var onExpire: () -> Void = {}

    package init() {}

    /// Take a new content identity and (re)arm the clock, or leave a running clock alone.
    package func arm(_ copy: DecorationChipCopy, onExpire: @escaping () -> Void) {
        self.onExpire = onExpire
        guard copy.identity != identity else { return }
        identity = copy.identity
        stop()
        let seconds = Double(copy.dwell.components.seconds)
            + Double(copy.dwell.components.attoseconds) / 1e18
        guard seconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            // Foundation fires a scheduled timer on the main run loop without saying so in the type.
            MainActor.assumeIsolated { self?.onExpire() }
        }
    }

    package func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// The durable connection chip's one row, inset by the capsule's own padding.
///
/// ⚠️ NOT ``SlateHostView/slateEdges(of:)``: this is a padded pin, and the two spacings are the
/// capsule's rhythm rather than a general inset — a chip whose row filled its plate would have its
/// dot touching the capsule's edge.
@MainActor
package enum DecorationAlertChipRow {
    package static func constraints(
        in chip: SlateHostView,
        row: SlateHostView,
    ) -> [NSLayoutConstraint] {
        row.translatesAutoresizingMaskIntoConstraints = false
        return [
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: Slate.Metric.space4),
            row.trailingAnchor.constraint(
                equalTo: chip.trailingAnchor, constant: -Slate.Metric.space4,
            ),
            row.topAnchor.constraint(equalTo: chip.topAnchor, constant: Slate.Metric.space2),
            row.bottomAnchor.constraint(
                equalTo: chip.bottomAnchor, constant: -Slate.Metric.space2,
            ),
        ]
    }
}
