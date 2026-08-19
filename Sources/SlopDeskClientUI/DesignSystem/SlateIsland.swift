// SlateIsland — the ONE island, and the compact islands SELECTION cuts from it (user-directed
// 2026-08-08).
//
// There is exactly one lifted SURFACE in the window: the terminal canvas. `slateIsland()` is where it
// is made, so law 1 lives in one place instead of being re-derived per column:
//   • the island paints ``Slate/Surface/island`` — the profile's own glass, never a chrome tone;
//   • it clips to ``Slate/Metric/islandRadius`` — the FRAME's own corner, so the glass never rounds
//     harder than the window holding it;
//   • it floats in an ``Slate/Metric/islandInset`` moat of GROUND, the same on all four sides, so
//     its top edge rises INTO the band and lands ON the line the band's plates hang from — except
//     while the navigator is hidden and the band runs over this column, when the top opens to
//     ``Slate/Metric/bandHeight``;
//   • it carries a hairline edge, and that edge is the GLASS's own (``Slate/Terminal/edge``), not the
//     chrome separator — see the note on ``View/slateIsland(clearingBand:)``.
//
// Nothing else calls it. A second call site is the many-islands mistake coming back.
//
// The COMPACT island — the chip a selected tab is stamped out of, at
// ``Slate/Metric/islandRadiusCompact`` — used to live here too, as `SlateCompactIsland`, with the
// selection-plate morph (`SlateMorphScope`, `AnyTransition.plateIgnite`) that let one plate travel
// between chips inside a project island. Both tab surfaces that mounted it are AppKit now
// (``SlopDeskMacUI/MacSidebarRow``, ``SlopDeskMacUI/MacPanelTabGroup``), and the AppKit one animates
// the same opening from ``Slate/Anim/plateIgniteScale`` directly, so the three SwiftUI types had no
// caller left. The RULE they carried is the token they read, and that token is in `SlopDeskSlate`
// where both halves can reach it — which is why deleting the views cost the design nothing.

#if canImport(SwiftUI)
import SlopDeskSlate
import SwiftUI

extension View {
    /// Lift the terminal canvas off the ground as THE island.
    ///
    /// THE MOAT IS UNIFORM (user-directed 2026-08-09): the island rises to ``Slate/Metric/bandInset``
    /// on the top side exactly as it insets on the other three, so it reaches INTO the band rather
    /// than starting a row under it — the three columns open together instead of the middle one
    /// beginning low. Hanging the island BELOW the whole band was tried in two band heights and
    /// rejected both times.
    ///
    /// AND THAT MOAT IS NOW THE BAND'S OWN CONTROL LINE. With the moat at 8 the island's top edge
    /// coincides with ``Slate/Metric/bandControlInset`` — the y every plate in the band hangs from —
    /// so the glass's top edge, the sidebar toggle, the panel's surface tabs and the collapsed-state
    /// tab chips all start on ONE line, and the traffic lights (16pt discs, centred on that row's own
    /// centre) sit inside it. At 12 the island's edge shared its line with nothing, which is what the
    /// user read as the top of the window being slightly out of true.
    ///
    /// `clearingBand` is the one state that cannot have it: with the navigator collapsed this column
    /// holds the window's left edge, and the band above it fills with the lights, the toggle and the
    /// horizontal tab strip — cream chips and tinted project beds that cannot stand on the glass.
    /// There the top side opens to the full ``Slate/Metric/bandHeight`` so the band keeps its ground.
    /// The collapsed PANEL needs no such exception: it leaves a rail of ground beside the
    /// island instead of parking a plate on the glass.
    ///
    /// That widening is a step of most of the band, and it must never be INSTANT: collapsing the
    /// navigator animates the column's width, so the moat opens on the same curve and duration —
    /// the island widens leftward and shortens downward as one move.
    ///
    /// THE RIM IS THE GLASS'S OWN EDGE, NOT THE CHROME SEPARATOR (user-directed 2026-08-10). The
    /// hairline used to be ``Slate/Line/divider``, written when a light profile existed and the
    /// ground and the glass were the same cream; under the one appearance that separator resolves on
    /// the LIGHT side (near-black at a tenth) and lands on `#22212C`, so it draws nothing at all and
    /// the island's whole boundary is the ground's 13:1 tone step. That boundary is a loan from the
    /// ground: paint the ground any darker and the island loses its edge with it. ``Slate/Terminal/edge``
    /// is the profile's own selection tone, a step LIGHTER than the glass, which is the platform
    /// idiom for a lifted dark surface (a dark separator is a light hairline, not a dark one), and it
    /// is the same line the panes inside are parted by — one line vocabulary, inside and out.
    /// It also makes the edge the island's own property: on any ground, the rim still says where the
    /// glass ends.
    @MainActor
    func slateIsland(clearingBand: Bool = false) -> some View {
        let radius = Slate.Metric.islandRadius
        let inset = Slate.Metric.islandInset
        let top = clearingBand ? Slate.Metric.bandHeight : Slate.Metric.bandInset
        return background(Slate.Surface.island)
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .overlay {
                // Inset stroke, not a centred one: a stroke on the rounded path would be half eaten
                // by the clip above it, and the island must not change size to draw its own edge.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Slate.Terminal.edge, lineWidth: Slate.Metric.hairline)
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
    /// titlebar strip spends NOTHING (user-directed 2026-08-09): a tab there has to measure exactly
    /// what the panel's tabs across the window measure, and any collar at all made the strip's tabs
    /// the one taller row in the band.
    var verticalInset: CGFloat = Slate.Metric.space2
    /// How far it extends past its content horizontally. Same story, one axis over: the sidebar's
    /// beds want the inset so a selected chip floats inside them, while the titlebar strip's beds
    /// end where their tabs do — a collar there left a stub of tint hanging off each run
    /// (user-reported 2026-08-09).
    var horizontalInset: CGFloat = Slate.Metric.projectIslandInset
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                tint,
                in: .rect(cornerRadius: Slate.Metric.islandRadiusCompact, style: .continuous),
            )
    }
}
#endif
