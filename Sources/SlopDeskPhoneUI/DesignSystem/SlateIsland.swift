// SlateIsland — the PROJECT island: the bed one project's group of tabs stands on.
//
// IT IS THE ONLY ISLAND LEFT IN THIS FILE, and the name is now a note about where the other one
// went. `slateIsland()` used to live here — the ONE lifted surface in the window, the terminal
// canvas: the glass, the window-scale corner, the four-sided moat of ground and the hairline rim,
// all in one modifier so law 1 was spelled once instead of re-derived per column. Its single call
// site was `ContentColumn`, and docs/56 stage F (P5) moved the whole of it up into
// ``SlopDeskMacUI/MacContentColumn`` — constraints for the moat, one `CALayer` for the other three
// properties. The rule it existed to hold did not move: it is still one island, still spelled in one
// place, and there is still no second call site to make a second one from.
//
// WHY IT MOVED IS NOT TIDINESS. The moat was the whole of the difference between the AppKit view
// hosting the canvas and the canvas itself — the difference `DropTargetFrameReader` was written to
// measure from the SwiftUI side, and the last kind 3 in the ledger. Moved up, the difference is zero
// and the reader is deleted.
//
// The COMPACT island — the chip a selected tab is stamped out of, at
// ``Slate/Metric/islandRadiusCompact`` — used to live here too, as `SlateCompactIsland`, with the
// selection-plate morph (`SlateMorphScope`, `AnyTransition.plateIgnite`) that let one plate travel
// between chips inside a project island. Both tab surfaces that mounted it are AppKit now
// (``SlopDeskMacUI/MacSidebarRow``, ``SlopDeskMacUI/MacPanelTabGroup``), and the AppKit one animates
// the same opening from ``Slate/Anim/plateIgniteScale`` directly, so the three SwiftUI types had no
// caller left. The RULE they carried is the token they read, and that token is in `SlopDeskSlate`
// where both halves can reach it — which is why deleting the views cost the design nothing.

#if os(iOS)
import SlopDeskSlate
import SwiftUI

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
