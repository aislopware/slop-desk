// SlateIsland — the ONE island, and the compact islands SELECTION cuts from it (user-directed
// 2026-08-08).
//
// There is exactly one lifted SURFACE in the window: the terminal canvas. `slateIsland()` is where it
// is made, so law 1 lives in one place instead of being re-derived per column:
//   • the island paints ``Slate/Surface/island`` — the profile's own glass, never a chrome tone;
//   • it clips to ``Slate/Metric/islandRadius``, a window-scale corner for a window-scale surface;
//   • it floats in an ``Slate/Metric/islandInset`` moat of GROUND on the sides and the bottom, and
//     its TOP starts where the band ends — the whole ``Slate/Metric/bandHeight``, unconditionally;
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
    /// THE TOP IS THE BAND (user-directed 2026-08-09). The sides and the bottom keep the ordinary
    /// ``Slate/Metric/islandInset`` moat, but the top side is the full ``Slate/Metric/bandHeight``,
    /// in EVERY state — because that is the one line the window has to keep straight. The navigator
    /// opens its 40pt traffic-light strip there, the code panel opens its surface-tab strip there,
    /// and every column's content starts underneath: with a 12pt top moat the middle column alone
    /// began 28pt higher, so the band read as broken by the island's corner rather than as one
    /// unbroken strip across the window.
    ///
    /// This retires `clearingWindowControls`, which used to widen the top only while the navigator
    /// was collapsed and this column held the window's left edge. Keeping the lights on bare ground
    /// was never the whole reason for the widening — it was the visible half of a rule that applies
    /// to the strip end to end, and applying it in one state made a 32pt step that had to be
    /// animated in step with the column slide. There is no step left to animate.
    @MainActor
    func slateIsland() -> some View {
        let radius = Slate.Metric.islandRadius
        let inset = Slate.Metric.islandInset
        let top = Slate.Metric.bandHeight
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
    /// The bed this island stands on, taken from the column's ``Slate/ProjectTint/Deal``.
    ///
    /// The island is TOLD its colour rather than deriving one from a key, because the colour is not
    /// a property of this group alone: a group whose hash collides with the island above it is
    /// re-dealt, and only something holding the whole ordered run can know that. Handing the island
    /// a key would put a second, un-repaired path to the same bed one call site away — see the note
    /// on ``Slate/ProjectTint/Deal``.
    let tint: Color
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
                tint,
                in: .rect(cornerRadius: Slate.Metric.islandRadiusCompact, style: .continuous),
            )
    }
}
#endif
