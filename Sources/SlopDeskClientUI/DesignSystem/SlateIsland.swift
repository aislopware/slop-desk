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
    ///
    /// That widening is a 32pt step, and it used to be INSTANT (user-directed 2026-08-09). Collapsing
    /// the navigator animates the column's width but the island's top moat jumped in one frame, so
    /// the one surface the window is built around lost a band of height while everything around it
    /// was still gliding. The moat now OPENS on the same curve and the same duration as the column
    /// that caused it — no delay, because the two edges belong to a single move: the island widens
    /// leftward and shortens downward at once.
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
            // Keyed on the MEASUREMENT, not on the flag: only a moat that actually changes size may
            // animate, so no other chrome change can drag the island's geometry into a transaction.
            .animation(Slate.Anim.columnSlide, value: top)
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
    /// The MORPH namespace shared by one list of chips. Supply it and the selected plate stops being
    /// a per-row background that cross-fades and becomes ONE plate that TRAVELS from the old row to
    /// the new one (user-directed 2026-08-09: selection "jumped"). `nil` — a lone chip with no
    /// siblings to travel between — keeps the plain fade.
    var morph: Namespace.ID?
    @ViewBuilder let content: () -> Content

    /// The chrome's own scheme, passed straight back through for an unselected chip: overriding it
    /// unconditionally would pin the resting rows to a scheme instead of leaving them on the app pin.
    @Environment(\.colorScheme) private var chromeScheme

    /// One geometry id per list: every chip sharing a `morph` namespace also shares this, which is
    /// exactly what makes the plate a single travelling object rather than N appearing ones.
    private static var morphID: String { "slate.compactIsland.selection" }

    private var radius: CGFloat { Slate.Metric.islandRadiusCompact }

    var body: some View {
        content()
            .environment(\.colorScheme, selected ? Slate.glassColorScheme : chromeScheme)
            .background(alignment: .center) { plate }
    }

    /// The chip's ground. Selected draws the island plate — fill and hairline as ONE view, which is
    /// what lets the morph carry both across; hover draws the resting tint; at rest nothing.
    ///
    /// NO DROP SHADOW (user-directed 2026-08-09). The chip used to cast a 4% whisper, written when
    /// the plate was cream on a cream ground and needed help separating. The single profile put the
    /// island's DARK glass under the chip while the ground stayed cream, so the two are now ~13:1
    /// apart and the fill alone says everything the shadow was for — leaving it made a travelling
    /// plate drag a soft edge behind it, which is the one thing a flat vocabulary cannot afford.
    @ViewBuilder
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if selected {
            let pill = shape
                .fill(Slate.Surface.island)
                .overlay(shape.strokeBorder(Slate.Line.divider, lineWidth: Slate.Metric.hairline))
                .allowsHitTesting(false)
            if let morph {
                pill.matchedGeometryEffect(id: Self.morphID, in: morph)
            } else {
                pill
            }
        } else if hovering {
            shape.fill(Slate.State.hover).allowsHitTesting(false)
        }
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
    /// How far the bed extends past its content vertically. The sidebar spends a full `space2` — its
    /// beds stack down a column and the gap between two of them is what separates the projects. The
    /// titlebar strip spends `space1` instead (user-directed 2026-08-09): there the bed has to leave
    /// clearance ABOVE and BELOW itself inside a fixed 40pt band, and a full rung made it fill the
    /// band edge to edge and read as a painted header rather than a bed.
    var verticalInset: CGFloat = Slate.Metric.space2
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, Slate.Metric.projectIslandInset)
            .padding(.vertical, verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Slate.ProjectTint.wash(for: projectKey),
                in: .rect(cornerRadius: Slate.Metric.islandRadiusCompact, style: .continuous),
            )
    }
}
#endif
