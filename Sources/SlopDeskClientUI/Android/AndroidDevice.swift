// AndroidDevice — the host's Android device set as the panel sees it, decoded from the bridge's
// `list` reply.
//
// The host answers ONE array, already folded: a booted AVD appears once, as its running record, and
// the AVDs that are not running follow. So unlike the simulator panel there is no pair of groups to
// merge here — the ordering decision was made host-side, in `merge` (`rust/slopdesk-androidd/src/catalog.rs`),
// where the two halves are actually known.
//
// `state` is kept as `adb`'s raw word alongside the derived ``isRunning``. `adb` says `device`,
// `offline`, `unauthorized`, `authorizing`, `connecting`, `recovery`, `sideload` — a closed enum here
// would turn a transient state into a decode failure for the whole list.
//
// ## The figures on a shut-down row are real
//
// `docs/47` records that a shut-down iOS simulator knows only its name, runtime, state and udid, and
// that the geometry available for it is chrome data that silently falls back to a lookalike — wrong
// for four of eleven devices, which is why the simulator panel shows no size on an idle row. Android
// inverts that: an AVD's `config.ini` is its DEFINITION, so ``width``/``height``/``density``/``model``
// on an un-booted row are exact. The list is designed around this — an Android row can carry figures
// where the iOS row could carry only a name.

#if os(macOS)
import Foundation

struct AndroidDevice: Equatable, Identifiable {
    /// Stable across a boot. An AVD keeps its name when it acquires a serial, so a device the user
    /// selected stays selected through the boot rather than vanishing and reappearing as a new row.
    var id: String { key }

    var key: String
    var name: String
    /// `adb`'s transport id. `nil` until the device is running — which is also what makes it the
    /// gate on every operation that needs one.
    var serial: String?
    var avdName: String?
    /// `adb`'s own word, verbatim.
    var state: String
    var isEmulator: Bool
    var manufacturer: String?
    var model: String?
    var release: String?
    var apiLevel: Int?
    var abi: String?
    var width: Int?
    var height: Int?
    var density: Int?
    /// The platform's raw form-factor word — `ro.build.characteristics` for a running device,
    /// `tag.id` for an AVD on disk. Resolved to a glyph in ``AndroidDeviceKind``, not here.
    var formFactor: String?

    /// Running AND reachable. A device that is `unauthorized` is attached but will refuse every
    /// shell, so it must not offer a mirror button that can only fail.
    var isRunning: Bool { serial != nil && state == "device" }

    /// Attached but not usable — the state that needs an explanation rather than an action. The user
    /// has to accept a debugging prompt on the device itself; nothing this panel sends can do it.
    var isAttachedButUnusable: Bool { serial != nil && state != "device" }

    /// The screen's physical proportions, when known. Used to draw the frame before the first video
    /// packet names a size — otherwise a freshly-opened device is a blank rectangle of the wrong
    /// shape for as long as the encoder takes to start.
    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    /// The one-line fact under the headline: what this device IS, in the terms someone picking one
    /// out of a list needs. Assembled from whatever is known rather than templated, so a row missing
    /// a field reads as a shorter sentence instead of one with a hole in it.
    var summary: String {
        var parts: [String] = []
        if let release { parts.append("Android " + release) }
        else if let apiLevel { parts.append("API \(apiLevel)") }
        if let width, let height { parts.append("\(width)×\(height)") }
        if !isEmulator, let manufacturer, let model, !model.hasPrefix(manufacturer) {
            parts.append(manufacturer)
        }
        return parts.joined(separator: " · ")
    }

    /// Decode the bridge's `list` reply. `nil` only when the envelope itself is not an object or
    /// reports failure — a malformed DEVICE inside is skipped instead, so one bad entry cannot blank
    /// the panel. Untrusted-input rule: validate then drop.
    static func decodeList(_ data: Data) -> [Self]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let entries = root["devices"] as? [[String: Any]]
        else { return nil }
        return entries.compactMap(decodeDevice)
    }

    private static func decodeDevice(_ entry: [String: Any]) -> Self? {
        // The key is the identity, and a row that cannot be selected is worse than an absent one.
        // Everything else degrades, so a host that adds or renames a field still lists the device.
        guard let key = entry["key"] as? String, !key.isEmpty else { return nil }
        return Self(
            key: key,
            name: entry["name"] as? String ?? key,
            serial: entry["serial"] as? String,
            avdName: entry["avd"] as? String,
            state: entry["state"] as? String ?? "",
            isEmulator: entry["isEmulator"] as? Bool ?? false,
            manufacturer: entry["manufacturer"] as? String,
            model: entry["model"] as? String,
            release: entry["release"] as? String,
            apiLevel: entry["api"] as? Int,
            abi: entry["abi"] as? String,
            width: entry["width"] as? Int,
            height: entry["height"] as? Int,
            density: entry["density"] as? Int,
            formFactor: entry["formFactor"] as? String,
        )
    }
}
#endif
