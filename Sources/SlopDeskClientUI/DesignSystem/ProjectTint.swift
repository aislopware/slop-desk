// ProjectTint — the per-project identity colour behind the sidebar section swatches. Each project
// key maps onto one of the theme's ``SlateTheme/projectTints`` chromatics via a LAUNCH-STABLE pure
// hash (FNV-1a over UTF-8), so a project keeps its colour across relaunches and across both
// machines. Swift's own `hashValue` is per-process seeded and would reshuffle every swatch on each
// launch — never route this through `Hashable`.

#if canImport(SwiftUI)
import SwiftUI

enum ProjectTint {
    /// The stable tint index for a project key: FNV-1a-64 over the key's UTF-8, reduced mod `count`.
    /// Pure + deterministic — pinned in `ProjectTintTests` so an algorithm change (which would
    /// silently recolour every user's projects on update) can't land unnoticed.
    static func index(of key: String, count: Int) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01B3
        }
        return Int(hash % UInt64(count))
    }

    /// The swatch colour for a project key. The keyless "Other" bucket has no identity to colour and
    /// keeps the muted metadata ink — a chromatic there would invent an identity it doesn't have.
    @MainActor
    static func color(for key: String?) -> Color {
        guard let key else { return Slate.Text.tertiary }
        let tints = Slate.theme.projectTints
        return tints[index(of: key, count: tints.count)]
    }
}
#endif
