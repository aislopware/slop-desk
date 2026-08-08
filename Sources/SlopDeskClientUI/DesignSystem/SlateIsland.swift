// SlateIsland — the ONE island (user-directed 2026-08-08).
//
// There is exactly one lifted surface in the window: the terminal canvas. This modifier is where it
// is made, so law 1 lives in one place instead of being re-derived per column:
//   • the island paints ``Slate/Surface/island`` — the profile's own glass, never a chrome tone;
//   • it clips to ``Slate/Metric/islandRadius``, the concentric rung under the window's own 16;
//   • it floats in a uniform ``Slate/Metric/islandInset`` moat of GROUND on all four sides, except at
//     the top where the moat widens to the full ``Slate/Metric/bandHeight`` — the band the traffic
//     lights and the hover titlebar stand on IS the moat's top side, not a second surface;
//   • it carries a hairline edge, because in the light profile the ground and the glass are the same
//     cream (law 4) and the corner alone cannot draw the boundary.
//
// Nothing else calls this. A second call site is the many-islands mistake coming back.

#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Lift the terminal canvas off the ground as THE island.
    @MainActor
    func slateIsland() -> some View {
        let radius = Slate.Metric.islandRadius
        let inset = Slate.Metric.islandInset
        return background(Slate.Surface.island)
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .overlay {
                // Inset stroke, not a centred one: a stroke on the rounded path would be half eaten
                // by the clip above it, and the island must not change size to draw its own edge.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Slate.Line.divider, lineWidth: Slate.Metric.hairline)
                    .allowsHitTesting(false)
            }
            .padding(.top, Slate.Metric.bandHeight)
            .padding([.leading, .trailing, .bottom], inset)
            .background(Slate.Surface.field)
    }
}
#endif
