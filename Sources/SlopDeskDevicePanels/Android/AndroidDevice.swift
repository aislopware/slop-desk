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

import Foundation

package struct AndroidDevice: Equatable, Identifiable {
    /// Stable across a boot. An AVD keeps its name when it acquires a serial, so a device the user
    /// selected stays selected through the boot rather than vanishing and reappearing as a new row.
    package var id: String { key }

    package var key: String
    package var name: String
    /// `adb`'s transport id. `nil` until the device is running — which is also what makes it the
    /// gate on every operation that needs one.
    package var serial: String?
    package var avdName: String?
    /// `adb`'s own word, verbatim.
    package var state: String
    package var isEmulator: Bool
    package var manufacturer: String?
    package var model: String?
    package var release: String?
    package var apiLevel: Int?
    package var abi: String?
    package var width: Int?
    package var height: Int?
    package var density: Int?
    /// The platform's raw form-factor word — `ro.build.characteristics` for a running device,
    /// `tag.id` for an AVD on disk. Resolved to a glyph in ``AndroidDeviceKind``, not here.
    package var formFactor: String?

    // ⚠️ `isRunning`, `isAttachedButUnusable`, `aspectRatio` and `summary` ARE NOT HERE. They are
    // `slopdesk_devicepanel::android`, reached through the extension at the foot of
    // `AndroidPresentation.swift` — the first three as ONE bitfield over the raw `(serial, state,
    // isEmulator)` triple, because they are four reads of the same two fields and asking them
    // separately would cross `adb`'s state word four times per row per redraw.
    //
    // What is left here is DECODING, which is the whole job of this type: the bridge's JSON in, a
    // record out. A rule spelled beside a decode is a rule the panel's other half cannot be tested
    // against, and `isRunning` was already spelled twice inside one file pair before there was a
    // second renderer.

    /// Decode the bridge's `list` reply. `nil` only when the envelope itself is not an object or
    /// reports failure — a malformed DEVICE inside is skipped instead, so one bad entry cannot blank
    /// the panel. Untrusted-input rule: validate then drop.
    package static func decodeList(_ data: Data) -> [Self]? {
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
