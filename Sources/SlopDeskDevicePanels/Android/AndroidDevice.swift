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

import CSlopDeskFFI
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
    // The DECODE is not here either, any more. `slopdesk_devicepanel::android_bridge::decode_list`
    // reads the reply line, and this file reads back the row — which puts the bridge's whole
    // grammar, request and reply, in the one crate that already builds the request. It was the last
    // `JSONSerialization` call in the Android half, and the last reason the invariant that bans
    // that call under this directory had to carry an exemption naming this file.
    //
    // One behaviour CHANGED with the move, deliberately: an empty string is now an absent field
    // rather than a present empty one. A host that answered `"serial": ""` used to hand the panel a
    // serial it would go on to spell into `adb -s ""` — a different command from the one meant.

    /// Decode the bridge's `list` reply. `nil` only when the envelope itself is not an object or
    /// reports failure — a malformed DEVICE inside is skipped instead, so one bad entry cannot blank
    /// the panel. Untrusted-input rule: validate then drop.
    package static func decodeList(_ data: Data) -> [Self]? {
        var blob = DevicePanelBlob { out, cap in
            devicePanelLend(data) { bytes, count in
                slopdesk_android_device_list(bytes, count, out, cap)
            }
        }
        // The refusal is the ABSENCE of bytes, because a host with no device attached still answers
        // and an empty rail is a different picture from the last one the panel saw.
        guard !blob.isRefusal else { return nil }
        let count = blob.count32()
        return (0..<count).map { _ in decodeDevice(&blob) }
    }

    /// One row, in the order the door wrote it. Every field has a floor — a name falls back to the
    /// key, a state to the empty word — so a walk that runs short loses fields rather than shifting
    /// each one into its neighbour's slot.
    private static func decodeDevice(_ blob: inout DevicePanelBlob) -> Self {
        let key = blob.text()
        let name = blob.text()
        let serial = blob.text()
        let avdName = blob.text()
        let state = blob.text()
        let isEmulator = blob.byte() != 0
        let manufacturer = blob.text()
        let model = blob.text()
        let release = blob.text()
        let apiLevel = blob.optionalCount()
        let abi = blob.text()
        let width = blob.optionalCount()
        let height = blob.optionalCount()
        let density = blob.optionalCount()
        let formFactor = blob.text()
        return Self(
            key: key,
            name: name,
            serial: serial.isEmpty ? nil : serial,
            avdName: avdName.isEmpty ? nil : avdName,
            state: state,
            isEmulator: isEmulator,
            manufacturer: manufacturer.isEmpty ? nil : manufacturer,
            model: model.isEmpty ? nil : model,
            release: release.isEmpty ? nil : release,
            apiLevel: apiLevel,
            abi: abi.isEmpty ? nil : abi,
            width: width,
            height: height,
            density: density,
            formFactor: formFactor.isEmpty ? nil : formFactor,
        )
    }
}
