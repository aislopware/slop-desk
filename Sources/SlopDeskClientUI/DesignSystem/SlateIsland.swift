// SlateIsland — the ONE island, and the compact islands SELECTION cuts from it (user-directed
// 2026-08-08).
//
// There is exactly one lifted SURFACE in the window: the terminal canvas. `slateIsland()` is where it
// is made, so law 1 lives in one place instead of being re-derived per column:
//   • the island paints ``Slate/Surface/island`` — the profile's own glass, never a chrome tone;
//   • it clips to ``Slate/Metric/islandRadius``, a window-scale corner for a window-scale surface;
//   • it floats in a UNIFORM ``Slate/Metric/islandInset`` moat of GROUND on all four sides — it butts
//     up to the top exactly as it does to the bottom (user-directed 2026-08-08). The one exception is
//     a collapsed navigator, where the top side widens to clear the traffic lights;
//   • it carries a hairline edge, because in the light profile the ground and the glass are the same
//     cream (law 4) and the corner alone cannot draw the boundary.
//
// Nothing else calls it. A second call site is the many-islands mistake coming back.
//
// ``SlateCompactIsland`` is the ONE sanctioned exception, and it is not a second surface — it is what
// SELECTION now looks like: the chosen tab is stamped out of the island's own material, so the window
// says "this one" in the single material it already speaks. Same two ingredients (island fill +
// hairline) at ``Slate/Metric/islandRadiusCompact``, which makes a chip read exactly as strongly as
// the canvas does under either profile: an inverted dark chip on the cream ground under Dracula, a
// hairlined cream chip under Alucard. Selection is a TAB gesture only — list rows, popover rows and
// settings keep the semantic raised card (``SlateListRow``).

#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Lift the terminal canvas off the ground as THE island.
    ///
    /// The moat is uniform on all four sides — the island runs right up to the top, level with the
    /// window's own top edge (user-directed 2026-08-08). `clearingWindowControls` is the ONE case
    /// that cannot: with the navigator collapsed this column starts at the window's left edge, and a
    /// moat the size of the ordinary one would slide the island under the traffic lights. There the
    /// top side widens back to the full ``Slate/Metric/bandHeight`` so the lights keep standing on
    /// bare ground.
    @MainActor
    func slateIsland(clearingWindowControls: Bool = false) -> some View {
        let radius = Slate.Metric.islandRadius
        let inset = Slate.Metric.islandInset
        let top = clearingWindowControls ? Slate.Metric.bandHeight : inset
        return background(Slate.Surface.island)
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .overlay {
                // Inset stroke, not a centred one: a stroke on the rounded path would be half eaten
                // by the clip above it, and the island must not change size to draw its own edge.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Slate.Line.divider, lineWidth: Slate.Metric.hairline)
                    .allowsHitTesting(false)
            }
            .padding(.top, top)
            .padding([.leading, .trailing, .bottom], inset)
            .background(Slate.Surface.field)
    }
}

/// A COMPACT island — the shell every SELECTED tab wears (sidebar tab rows, panel surface tabs).
///
/// Takes the whole chip: the plate underneath AND the ink on top. The ink matters as much as the
/// fill — a selected chip carries the ISLAND's polarity, not the chrome's, so under a dark profile
/// the label flips light on the dark chip instead of drawing near-black on it. That is the same
/// ``Slate/glassColorScheme`` override the pane chrome inside the big island already uses; routing
/// every semantic ink in the row through it in one place is what keeps this from becoming a dozen
/// hand-flipped `foregroundStyle`s.
struct SlateCompactIsland<Content: View>: View {
    /// Selected ⇒ the island plate. Unselected rows keep the resting/hover ladder.
    let selected: Bool
    /// The caller's live hover flag — an unselected chip still lights under the pointer.
    var hovering = false
    @ViewBuilder let content: () -> Content

    /// The chrome's own scheme, passed straight back through for an unselected chip: overriding it
    /// unconditionally would pin the resting rows to a scheme instead of leaving them on the app pin.
    @Environment(\.colorScheme) private var chromeScheme

    private var radius: CGFloat { Slate.Metric.islandRadiusCompact }

    private var fill: Color {
        if selected { return Slate.Surface.island }
        return hovering ? Slate.State.hover : .clear
    }

    var body: some View {
        content()
            .environment(\.colorScheme, selected ? Slate.glassColorScheme : chromeScheme)
            .background(fill, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Slate.Line.divider, lineWidth: Slate.Metric.hairline)
                        .allowsHitTesting(false)
                }
            }
            // The light profile's chip is cream on cream — the hairline draws it, and this whisper
            // of a shadow keeps it from reading flat. Dark profiles cast nothing (`cardShadow`
            // resolves clear there): an inverted chip needs no help separating.
            .shadow(color: selected ? Slate.State.cardShadow : .clear, radius: 2, y: 1)
    }
}

/// The PROJECT island — the bed one project's group stands on in the sidebar, header and rows
/// together, washed in that project's identity hue (``Slate/ProjectTint``).
///
/// It does NOT break law 1, and the distinction is the whole point: this island is not LIFTED. It
/// carries no glass, no hairline, no shadow — only the ground's own cream shifted 5% toward a hue,
/// which is a bed the eye feels rather than a surface it reads as floating. The one lifted thing in
/// the window is still the terminal canvas; the one thing stamped out of its material is still the
/// selected tab, and that chip goes on standing INSIDE this bed, which is why the bed inseams its
/// content (``Slate/Metric/projectIslandInset``) instead of letting the chip butt against its edge.
///
/// Approved on the Warp reading (user-directed 2026-08-08) after the same identity spent as a MARK —
/// tinted glyph, dot, spine, header rule — was rejected in all four shapes: a colour that names a
/// group belongs to the group's ground, not to a symbol sitting inside it.
struct SlateProjectIsland<Content: View>: View {
    /// The project's normalized key — `nil` is the keyless bucket, which gets a neutral bed.
    let projectKey: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, Slate.Metric.projectIslandInset)
            .padding(.vertical, Slate.Metric.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Slate.ProjectTint.wash(for: projectKey),
                in: .rect(cornerRadius: Slate.Metric.islandRadiusCompact, style: .continuous),
            )
    }
}
#endif
