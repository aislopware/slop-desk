// AndroidDeviceKind — which kind of Android device a row is, as `slopdesk_devicepanel::android`
// answers it.
//
// Same job as ``SimulatorDeviceKind`` and the same reason: a device set is a long list of
// near-identical strings, and the family is what the eye can sort on in one pass.
//
// What differs is the SOURCE, and it is better here. The simulator panel has to infer the family from
// the product name, because `/simulators.json` carries no device-type field and the route that does
// costs a request per device. Android states it outright — `ro.build.characteristics` on a running
// device, `tag.id` on an AVD on disk — so the crate's rule is a lookup rather than a guess, with the
// name only as a fallback for the devices that report `default`.
//
// The trap it turns on is worth knowing from this side too, because it is what makes `infer` a door
// rather than a dictionary: `ro.build.characteristics` is a comma-separated list whose commonest
// value on an emulator is `emulator,nosdcard` — and `nosdcard` CONTAINS `car`. The rule reads TOKENS
// for exactly that reason, and `slopdesk-devicepanel` pins it by name.

import CSlopDeskFFI
import Foundation
import SFSafeSymbols

package enum AndroidDeviceKind: String, CaseIterable, Sendable {
    case phone
    case tablet
    case watch
    case tv
    case automotive

    /// The silhouette, reconstituted from the NAME the crate publishes.
    ///
    /// THE TABLET IS DRAWN LANDSCAPE, and the same glyph set as the simulator panel is deliberate —
    /// `slopdesk_devicepanel::android::DeviceKind::symbol` carries both arguments.
    package var symbol: SFSymbol { SFSymbol(rawValue: Self.families[rank].symbol) }

    /// The heading a group of these sits under.
    package var groupTitle: String { Self.families[rank].title }

    /// Sort rank for the group headings — the crate's kind byte, which is also this case's index
    /// into ``families``. A heading order that lived in a `CaseIterable` declaration is one that a
    /// reordering nobody meant as a design change silently becomes.
    package var rank: Int {
        switch self {
        case .phone: Int(SLOPDESK_ANDROID_KIND_PHONE)
        case .tablet: Int(SLOPDESK_ANDROID_KIND_TABLET)
        case .watch: Int(SLOPDESK_ANDROID_KIND_WATCH)
        case .tv: Int(SLOPDESK_ANDROID_KIND_TV)
        case .automotive: Int(SLOPDESK_ANDROID_KIND_AUTOMOTIVE)
        }
    }

    /// The family for a device, from the platform's hint first, its name second and its geometry
    /// last.
    ///
    /// An absent measurement crosses as `0`, which the crate reads as "this device reported no
    /// screen" rather than as a very small one — the same non-answer a missing hint makes.
    package static func infer(
        hint: String?, name: String, width: Int?, height: Int?, density: Int?,
    ) -> Self {
        let byte = devicePanelLend(hint ?? "") { hintBytes, hintLen in
            devicePanelLend(name) { nameBytes, nameLen in
                slopdesk_android_device_kind(
                    hintBytes, hintLen, nameBytes, nameLen,
                    Int64(width ?? 0), Int64(height ?? 0), Int64(density ?? 0),
                )
            }
        }
        return allCases.first { $0.rank == Int(byte) } ?? .phone
    }

    /// The family for a decoded device.
    package static func infer(_ device: AndroidDevice) -> Self {
        infer(
            hint: device.formFactor, name: device.name,
            width: device.width, height: device.height, density: device.density,
        )
    }

    /// One family's two published strings.
    struct Family {
        let symbol: String
        let title: String
    }

    /// The crate's table, read ONCE, in rank order. PADDED for the reason
    /// ``SimulatorDeviceKind/families`` gives.
    static let families: [Family] = {
        var blob = DevicePanelBlob { out, cap in slopdesk_android_device_kinds(out, cap) }
        let published = blob.count16()
        var rows = (0..<published).map { _ -> Family in
            let strings = blob.texts(2)
            return Family(symbol: strings[0], title: strings[1])
        }
        while rows.count < allCases.count { rows.append(Family(symbol: "iphone", title: "")) }
        return rows
    }()
}
