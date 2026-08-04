// AndroidDeviceKind — which kind of Android device a row is.
//
// Same job as ``SimulatorDeviceKind`` and the same reason: a device set is a long list of
// near-identical strings, and the family is what the eye can sort on in one pass.
//
// What differs is the SOURCE, and it is better here. The simulator panel has to infer the family from
// the product name, because `/simulators.json` carries no device-type field and the route that does
// costs a request per device. Android states it outright — `ro.build.characteristics` on a running
// device, `tag.id` on an AVD on disk — so this is a lookup rather than a guess, with the name only as
// a fallback for the devices that report `default`.
//
// Note the platform's words do not partition cleanly: an emulator reports `emulator,nosdcard`, which
// says how it runs and not what it is, and a tablet AVD's `tag.id` is `google_apis` like every other.
// So the hint is checked for the DISTINCTIVE tokens and everything else falls through to the size
// test below — that is why this cannot be a plain dictionary.

#if os(macOS)
import Foundation
import SFSafeSymbols

enum AndroidDeviceKind: String, CaseIterable, Sendable {
    case phone
    case tablet
    case watch
    case tv
    case automotive

    /// THE TABLET IS DRAWN LANDSCAPE, for the reason `docs/47` records for the iPad: `iphone` and
    /// `ipad` differ only in ASPECT, and aspect is the one channel that does not survive being 13
    /// points tall. Turning it on its side changes the SILHOUETTE, which reads at any size.
    ///
    /// The same glyph set as the simulator panel, deliberately. These marks say PHONE, TABLET, WATCH
    /// — a shape, not a brand — and drawing an Android tablet with a different rectangle than an iPad
    /// would claim a distinction the reader does not need to make: the two panels are different tabs,
    /// and the row already carries the device's name and its Android version.
    var symbol: SFSymbol {
        switch self {
        case .phone: .iphone
        case .tablet: .ipadLandscape
        case .watch: .applewatch
        case .tv: .appletv
        case .automotive: .carFill
        }
    }

    /// The heading a group of these sits under.
    var groupTitle: String {
        switch self {
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .watch: "Wear"
        case .tv: "TV"
        case .automotive: "Automotive"
        }
    }

    /// Sort rank for the group headings, so the panel's order does not depend on which devices the
    /// host happens to have, or on `CaseIterable`'s declaration order leaking into the UI by
    /// accident.
    var rank: Int {
        switch self {
        case .phone: 0
        case .tablet: 1
        case .watch: 2
        case .tv: 3
        case .automotive: 4
        }
    }

    /// A tablet's shortest side, in dp. Android's own resource qualifier for a tablet layout is
    /// `sw600dp`, so this is the platform's line rather than one invented here.
    static let tabletShortestWidthDP = 600

    /// The family for a device, from the platform's hint first and its geometry second.
    ///
    /// The geometry test is what catches the case the hint cannot: every emulator, phone or tablet,
    /// reports `emulator,nosdcard`. `config.ini` gives an un-booted AVD exact `hw.lcd.*`, so the dp
    /// conversion is available on a row that has never run — which is the whole reason the panel can
    /// group a cold device list correctly at all.
    static func infer(
        hint: String?, name: String, width: Int?, height: Int?, density: Int?,
    ) -> Self {
        // TOKENS, not a substring search, and this is the trap the whole function turns on:
        // `ro.build.characteristics` is a comma-separated list whose commonest value on an emulator
        // is `emulator,nosdcard` — and `nosdcard` CONTAINS `car`. A substring test therefore reads
        // every ordinary emulator as an automotive head unit. The hint is split on its separators and
        // each token matched on its own.
        let tokens = (hint ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }
        let says = { (predicate: (Substring) -> Bool) in tokens.contains(where: predicate) }
        if says({ $0.contains("watch") || $0.contains("wear") }) { return .watch }
        if says({ $0.contains("automotive") || $0 == "car" }) { return .automotive }
        if says({ $0 == "tv" || $0 == "atv" || $0.contains("television") }) { return .tv }
        if says({ $0.contains("tablet") }) { return .tablet }

        // The name is checked before the size because a device profile that says so is more certain
        // than a threshold — a `Pixel_Tablet` AVD created at an unusual density would otherwise be
        // classified by arithmetic when it had already said what it was.
        let foldedName = name.lowercased()
        if foldedName.contains("wear") || foldedName.contains("watch") { return .watch }
        if foldedName.contains("tv") { return .tv }
        if foldedName.contains("tablet") || foldedName.contains("fold") { return .tablet }

        if let shortest = shortestWidthDP(width: width, height: height, density: density) {
            return shortest >= tabletShortestWidthDP ? .tablet : .phone
        }
        return .phone
    }

    /// `smallestScreenWidthDp` — the shorter side in density-independent pixels. `density` is Android's
    /// DPI bucket, where 160 is the definition of 1dp = 1px.
    static func shortestWidthDP(width: Int?, height: Int?, density: Int?) -> Int? {
        guard let width, let height, let density, width > 0, height > 0, density > 0 else {
            return nil
        }
        return min(width, height) * 160 / density
    }

    /// The family for a decoded device.
    static func infer(_ device: AndroidDevice) -> Self {
        infer(
            hint: device.formFactor, name: device.name,
            width: device.width, height: device.height, density: device.density,
        )
    }
}
#endif
