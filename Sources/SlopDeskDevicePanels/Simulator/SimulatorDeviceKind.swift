// SimulatorDeviceKind — which Apple device a row is, as `slopdesk_devicepanel::simulator` answers it.
//
// The list drew one identical dot per row before this, so an iPad and an Apple Watch were
// distinguishable only by reading the name. A device set is a long list of near-identical strings
// ("iPhone 17", "iPhone 17 Pro", "iPhone 17 Pro Max"), and the family is the thing the eye can sort
// on in one pass — which is exactly what a glyph is for.
//
// The CLASSIFICATION and the two words are the crate's, for the reason every other table on this
// surface is: two renderers draw this panel, and a silhouette chosen in one of them is a silhouette
// the other has to be told about by hand. What stays here is the closed Swift type the call sites
// switch on and the `SFSymbol` the name is reconstituted into.
//
// The crate's KIND BYTE is the rank, so ``rank`` reads it rather than restating an order — a heading
// order that lives in a `CaseIterable` declaration is one that a reordering nobody meant as a design
// change silently becomes.

import CSlopDeskFFI
import Foundation
import SFSafeSymbols

package enum SimulatorDeviceKind: String, CaseIterable, Sendable {
    case phone
    case pad
    case watch
    case tv
    case vision

    /// The silhouette, reconstituted from the NAME the crate publishes.
    ///
    /// THE PAD IS DRAWN LANDSCAPE ON PURPOSE — `slopdesk_devicepanel::simulator::DeviceKind::symbol`
    /// carries the argument, measured across every candidate pair 2026-08-04. All five silhouettes
    /// are mutually distinct at 13pt, which is the property `testEveryFamilyDrawsItsOwnShape` pins
    /// by name.
    package var symbol: SFSymbol { SFSymbol(rawValue: Self.families[rank].symbol) }

    /// The heading a group of these sits under. Plural because it always titles a group.
    package var groupTitle: String { Self.families[rank].title }

    /// Sort rank for the group headings — the crate's kind byte, which is also this case's index
    /// into ``families``.
    package var rank: Int {
        switch self {
        case .phone: Int(SLOPDESK_SIMULATOR_KIND_PHONE)
        case .pad: Int(SLOPDESK_SIMULATOR_KIND_PAD)
        case .watch: Int(SLOPDESK_SIMULATOR_KIND_WATCH)
        case .tv: Int(SLOPDESK_SIMULATOR_KIND_TV)
        case .vision: Int(SLOPDESK_SIMULATOR_KIND_VISION)
        }
    }

    /// The family a model name names.
    ///
    /// A byte no build of the crate wrote takes the phone, which is the same call the rule itself
    /// makes about a name it does not recognise: a wrong-but-plausible silhouette beats a row that
    /// looks broken, and the name is right there beside it.
    package static func infer(from name: String) -> Self {
        let byte = devicePanelLend(name) { bytes, len in
            slopdesk_simulator_device_kind(bytes, len)
        }
        return allCases.first { $0.rank == Int(byte) } ?? .phone
    }

    /// One family's two published strings.
    struct Family {
        let symbol: String
        let title: String
    }

    /// The crate's table, read ONCE, in rank order.
    ///
    /// PADDED, never trusted, like every other table on this surface: a crate and a face that
    /// disagree about the count lose ONE row's words rather than wearing each other's from the gap
    /// onward. A `rank` past the end would trap on the subscript, so the read is padded up to the
    /// case count here rather than at each accessor.
    static let families: [Family] = {
        var blob = DevicePanelBlob { out, cap in slopdesk_simulator_device_kinds(out, cap) }
        let published = blob.count16()
        var rows = (0..<published).map { _ -> Family in
            let strings = blob.texts(2)
            return Family(symbol: strings[0], title: strings[1])
        }
        while rows.count < allCases.count { rows.append(Family(symbol: "iphone", title: "")) }
        return rows
    }()
}
