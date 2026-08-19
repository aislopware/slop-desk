// TerminalLeafPolicy — the terminal leaf's decisions, taken out of the leaf (docs/56 §3).
//
// Three statics used to live on `TerminalLeafView` as `static` members of a `some View`. None of them
// names a view type, none of them draws, and two of them are the trigger for a socket — so a UI target
// was the one place they could not be reached from both halves. They are the leaf's POLICY: what a
// `.task(id:)` key must be for the task to fire at the right instant, and what a failed host verb is
// CALLED.
//
// The two task keys are here for a reason beyond the layering. `.task(id:)` re-fires only when its key
// CHANGES, so each key carries two separate claims — it must be `nil` while the gate is shut, and it
// must MOVE when the gate opens. A key that is already the pane's id while the hold stands is a task
// that ran once, too early, and never again: a pane dark for the rest of the launch, with no crash and
// no log line. Stated as a value, both claims are unit-pinned (`DialTaskKeyTests`).

import Foundation
import SlopDeskWorkspaceCore
import SlopDeskWorkspaceModel

/// The pure rules behind the terminal leaf's two `.task(id:)` keys and its host-action failure copy.
package enum TerminalLeafPolicy {
    /// What the connect-on-appear task waits for: this pane, once its id is one the host answers for.
    ///
    /// `nil` while this launch's `adoptWorkspace` is outstanding. The layout on screen is then the one
    /// read off `workspace.json`, staged optimistically — a PREDICTION — and a host that already has a
    /// workspace is about to replace every pane in it. Dialling inside that window spawns a shell per
    /// stale id on the host and abandons it a round trip later
    /// (``WorkspaceStore/panesMayDial``).
    ///
    /// Two claims, and they are separate. It must be `nil` while the hold stands, or the pane dials the
    /// very id the hold exists to keep off the wire. And it must MOVE on the release, or the task ran
    /// once, too early, and never again.
    package static func dialTaskKey(pane: PaneID?, mayDial: Bool) -> PaneID? {
        guard mayDial else { return nil }
        return pane
    }

    /// What the `SLOPDESK_AUTOTYPE` OUT-path proof seam waits for: the marked pane, actually CONNECTED.
    ///
    /// Two things have to hold, and they are separate claims. It must be `nil` for anything but the
    /// marked pane on a live channel — bytes typed into a dialling pane go nowhere and would spend the
    /// one shot doing it. And it must MOVE as that pane connects: a key that is already the pane's id
    /// while the channel is still dialling is a task that runs once, too early, and never again. That
    /// is an OUT path dead for the rest of the launch, and the whole seam otherwise only fails on
    /// hardware, in `check-macos.sh --connect`.
    package static func autotypeTaskKey(pane: PaneID?, isTarget: Bool, status: ConnectionStatus?) -> PaneID? {
        guard let pane, isTarget, case .connected = status else { return nil }
        return pane
    }

    /// The failure-toast subject for a host path action.
    ///
    /// The subject is the ACTION that failed, not a sentence about failing: the `FAILED` eyebrow on the
    /// card already carries that, and lower-case keeps the instrument register the rest of the card is
    /// set in.
    ///
    /// `@MainActor` only because ``HostPathActions`` is — the copy itself is a table.
    @MainActor
    package static func pathActionFailureTitle(_ action: HostPathActions.Action) -> String {
        switch action {
        case .open: "open on host"
        case .openCode: "open in code panel"
        case .reveal: "reveal on host"
        }
    }
}
