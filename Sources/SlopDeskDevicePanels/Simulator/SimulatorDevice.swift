// SimulatorDevice — the host's device set as the panel sees it, as
// `slopdesk_devicepanel::sim_devices` decodes it from `/simulators.json`.
//
// The LAWS are the crate's, and they are the ones that fail quietly. The server answers two arrays,
// `running` and `available`, of identical objects; the door folds them into ONE list carrying the
// boot state, because that is what the panel renders. A device does not change identity when it
// boots, and a list that reorders itself under the cursor on every poll is the exact opposite of
// what a person clicking "Boot" wants to see. Order is therefore the server's own within each
// group, running first — stable across polls because the server's is.
//
// `state` is kept as the server's raw string alongside the derived `isBooted`. The strings observed
// are `Booted` and `Shutdown`, but simctl has more (`Booting`, `Shutting Down`, `Creating`) and a
// closed enum would turn a transient state into a decode failure for the whole list. `isBooted` is
// derived on the far side because the comparison is case-INSENSITIVE and that is a decision: it
// drives which affordance the row offers, and getting it wrong shows the button that does nothing.
//
// `nil` back means exactly one thing — a top level that is not an object. A malformed DEVICE inside
// is skipped, so one bad entry cannot blank the panel, and a host with no simulators installed
// answers an EMPTY list rather than a failure. That is why the count rides inside the delivery: the
// door's `0` is the refusal, and zero devices is not one.

import CSlopDeskFFI
import Foundation
import SlopDeskWorkspaceModel

package struct SimulatorDevice: Equatable, Identifiable {
    package var id: String { udid }

    package var udid: String
    package var name: String
    package var runtime: String
    /// The server's own state string, verbatim.
    package var state: String
    package var isBooted: Bool

    /// Decode the `/simulators.json` envelope. `nil` only for a top level that is not an object —
    /// see the header.
    package static func decodeList(_ data: Data) -> [Self]? {
        let delivery = simulatorLend(data) { bytes, count in
            wsAnswerBytes { out, cap in slopdesk_sim_device_list(bytes, count, out, cap) }
        }
        guard !delivery.isEmpty else { return nil }
        var blob = DevicePanelBlob(delivery)
        let count = blob.count16()
        return (0..<count).map { _ in
            // The boot byte leads its row, so it is read before the words it belongs to.
            let isBooted = blob.byte() == 1
            return Self(
                udid: blob.text(), name: blob.text(),
                runtime: blob.text(), state: blob.text(),
                isBooted: isBooted,
            )
        }
    }
}
