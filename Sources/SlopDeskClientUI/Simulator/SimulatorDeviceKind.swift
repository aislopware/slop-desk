// SimulatorDeviceKind — which Apple device a row is, derived from its model name.
//
// The list drew one identical dot per row before this, so an iPad and an Apple Watch were
// distinguishable only by reading the name. A device set is a long list of near-identical strings
// ("iPhone 17", "iPhone 17 Pro", "iPhone 17 Pro Max"), and the family is the thing the eye can sort
// on in one pass — which is exactly what a glyph is for.
//
// FROM THE NAME, not from the server. `/simulators.json` carries no device-type field, and the
// definition route that does costs one request per device — for a glyph, on a list that polls. The
// names are Apple's own product names and are what the whole ecosystem already keys on.
//
// Order of the checks is the point: "iPad" must be tested before "iPhone" only because neither
// contains the other, but `visionOS`'s device is "Apple Vision Pro" and `watchOS`'s is "Apple Watch
// Series N" — both contain "Apple", so matching on the specific token is what keeps them apart.
// Anything unrecognised falls back to the phone glyph rather than a question mark: a wrong-but-plausible
// silhouette beats a row that looks broken, and the name is right there beside it.

#if os(macOS)
import Foundation
import SFSafeSymbols

enum SimulatorDeviceKind: String, CaseIterable, Sendable {
    case phone
    case pad
    case watch
    case tv
    case vision

    /// THE PAD IS DRAWN LANDSCAPE ON PURPOSE. `iphone` and `ipad` differ only in ASPECT, and aspect is
    /// the one channel that does not survive being 13 points tall — rendered side by side at the size
    /// the rows actually use, they are two small vertical rounded rectangles and the reader is back to
    /// reading the name (measured across every candidate pair 2026-08-04: `gen3`/`gen2` is the same
    /// shape, and `apps.*` turns both into speckle at this size, which is worse). Turning the pad on
    /// its side changes the SILHOUETTE, and silhouette reads at any size. It also happens to be how
    /// the two devices are held.
    ///
    /// It is not a claim about orientation. Nothing else in this panel says orientation with a device
    /// outline — the stage's rotate controls are arrows and its fact line spells the word — so there
    /// is no second meaning for a turned rectangle to collide with. And the mark is only ever drawn in
    /// the list: beside a shut-down device, which has no orientation, or on a card, whose framebuffer
    /// never rotates anyway.
    ///
    /// Checked against the rest of the set, since a landscape rectangle is the shape a television
    /// would want: `appletv` is not a wide box but a square carrying the Apple TV wordmark, so the two
    /// stay apart. All five silhouettes are mutually distinct at 13pt, which is the property
    /// `testEveryFamilyDrawsItsOwnShape` pins by name.
    var symbol: SFSymbol {
        switch self {
        case .phone: .iphone
        case .pad: .ipadLandscape
        case .watch: .applewatch
        case .tv: .appletv
        case .vision: .visionPro
        }
    }

    /// The heading a group of these sits under. Plural because it always titles a group.
    var groupTitle: String {
        switch self {
        case .phone: "iPhone"
        case .pad: "iPad"
        case .watch: "Apple Watch"
        case .tv: "Apple TV"
        case .vision: "Apple Vision"
        }
    }

    /// Sort rank for the group headings, so the panel's order does not depend on which device set the
    /// host happens to have or on `CaseIterable`'s declaration order leaking into the UI by accident.
    var rank: Int {
        switch self {
        case .phone: 0
        case .pad: 1
        case .watch: 2
        case .tv: 3
        case .vision: 4
        }
    }

    static func infer(from name: String) -> Self {
        let folded = name.lowercased()
        if folded.contains("ipad") { return .pad }
        if folded.contains("watch") { return .watch }
        if folded.contains("vision") { return .vision }
        if folded.contains("tv") { return .tv }
        return .phone
    }
}
#endif
