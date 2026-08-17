// SimulatorDevice — the host's device set as the panel sees it, decoded from `/simulators.json`.
//
// The server answers two arrays, `running` and `available`, of identical objects. This type folds
// them into ONE list carrying the boot state, because that is what the panel renders: a device does
// not change identity when it boots, and a list that reorders itself under the cursor on every poll
// is the exact opposite of what a person clicking "Boot" wants to see. Order is therefore the
// server's own within each group, running first — stable across polls because the server's is.
//
// `state` is kept as the server's raw string alongside the derived `isBooted`. The strings observed
// are `Booted` and `Shutdown`, but simctl has more (`Booting`, `Shutting Down`, `Creating`) and a
// closed enum here would turn a transient state into a decode failure for the whole list.

#if os(macOS)
import Foundation

package struct SimulatorDevice: Equatable, Identifiable {
    package var id: String { udid }

    package var udid: String
    package var name: String
    package var runtime: String
    /// The server's own state string, verbatim.
    package var state: String
    package var isBooted: Bool

    /// Decode the `/simulators.json` envelope. Returns `nil` only when the top level is not an
    /// object — a malformed DEVICE inside is skipped instead, so one bad entry cannot blank the
    /// panel. Untrusted-input rule: validate then drop.
    package static func decodeList(_ data: Data) -> [Self]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Running first: the device someone is working with belongs at the top, and the group a
        // device sits in is the one thing about the list that legitimately changes under a poll.
        return decodeGroup(root["running"]) + decodeGroup(root["available"])
    }

    private static func decodeGroup(_ value: Any?) -> [Self] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap(decodeDevice)
    }

    private static func decodeDevice(_ entry: [String: Any]) -> Self? {
        // The UDID is the only field with no sane default — it is the identity, and a row that
        // cannot be acted on is worse than an absent one. Name and runtime degrade to a placeholder
        // so a server that adds or renames a field still lists the device.
        guard let udid = entry["udid"] as? String, !udid.isEmpty else { return nil }
        let state = entry["state"] as? String ?? ""
        return Self(
            udid: udid,
            name: entry["name"] as? String ?? udid,
            runtime: entry["runtime"] as? String ?? "",
            state: state,
            // Case-insensitive: the comparison exists to drive an affordance (Boot vs Shutdown), and
            // getting it wrong because of a capitalization change offers the user the button that
            // does nothing.
            isBooted: state.caseInsensitiveCompare("Booted") == .orderedSame,
        )
    }
}
#endif
