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
// measure across that boundary, and the last kind 3 in the ledger. Moved up, the difference is zero and
// the reader is deleted.
//
// The COMPACT island — the chip a selected tab is stamped out of, at
// ``Slate/Metric/islandRadiusCompact`` — used to live here too, as `SlateCompactIsland`, with the
// selection-plate morph (`SlateMorphScope`, `AnyTransition.plateIgnite`) that let one plate travel
// between chips inside a project island. Both tab surfaces that mounted it are AppKit now
// (``SlopDeskMacUI/MacSidebarRow``, ``SlopDeskMacUI/MacPanelTabGroup``), and the AppKit one animates
// the same opening from ``Slate/Anim/plateIgniteScale`` directly, so the three types that drew it here
// had no caller left. The RULE they carried is the token they read, and that token is in `SlopDeskSlate`
// where the Mac and the phone both reach it — which is why deleting the views cost the design nothing.

#if os(iOS)
import QuartzCore
import SlopDeskSlate
import UIKit

/// The PROJECT island — the bed one project's group stands on in the sidebar, header and rows together,
/// washed in that project's identity hue (``Slate/ProjectTint``).
///
/// It does NOT break law 1, and the distinction is the whole point: this island is not LIFTED. It carries
/// no glass, no hairline, no shadow — only the ground's own cream shifted 5% toward a hue, which is a bed
/// the eye feels rather than a surface it reads as floating. The one lifted thing in the window is still
/// the terminal canvas; the one thing stamped out of its material is still the selected tab, and that chip
/// goes on standing INSIDE this bed, which is why the bed inseams its content
/// (``Slate/Metric/projectIslandInset``) instead of letting the chip butt against its edge.
///
/// Approved on the Warp reading (user-directed 2026-08-08) after the same identity spent as a MARK —
/// tinted glyph, dot, spine, header rule — was rejected in all four shapes: a colour that names a group
/// belongs to the group's ground, not to a symbol sitting inside it.
///
/// A CONTAINER, NEVER A LAYER DECORATION, and the reason is the one thing this island actually does beyond
/// painting: it INSEAMS its content. An inset is a thing you do to content — a static function configuring
/// a caller's layer has no content to hold off an edge. The members of ``SlateOverlayCard`` that are pure
/// `layer` work took the decoration shape instead; this one could not, and that is the whole test.
///
/// ⚠️ IT IS ALSO THE ONE SURFACE IN THE FAMILY WITH NO RE-INK. Every other member of the floating
/// vocabulary is mostly EDGE — a `CALayer` border, a cast shadow — and a `CGColor` on a layer is resolved
/// once and stops following the appearance. A bed has neither: its single colour is a view-level
/// `backgroundColor`, which UIKit re-resolves on every trait change by itself. No
/// `registerForTraitChanges`, because there is nothing registered against.
@MainActor
final class SlateProjectIslandView: UIView {
    /// The bed this island stands on, taken from the column's ``Slate/ProjectTint/Deal``.
    ///
    /// The island is TOLD its colour rather than deriving one from a key, because the colour is not a
    /// property of this group alone: a group whose hash collides with the island above it is re-dealt,
    /// and only something holding the whole ordered run can know that.
    var tint: UIColor {
        didSet {
            guard tint != oldValue else { return }
            backgroundColor = tint
        }
    }

    /// The content this bed holds — the project's header and rows together.
    let content: UIView

    /// - Parameters:
    ///   - verticalInset: How far the bed extends past its content vertically. The sidebar spends a full
    ///     `space2` — its beds stack down a column and the gap between two of them is what separates the
    ///     projects. A titlebar-style strip spends NOTHING (user-directed 2026-08-09): a tab there has to
    ///     measure exactly what the tabs across the window measure, and any collar at all made the
    ///     strip's tabs the one taller row in the band.
    ///   - horizontalInset: Same story, one axis over: the sidebar's beds want the inset so a selected
    ///     chip floats inside them, while a strip's beds end where their tabs do — a collar there left a
    ///     stub of tint hanging off each run (user-reported 2026-08-09).
    init(
        tint: UIColor,
        content: UIView,
        verticalInset: CGFloat = Slate.Metric.space2,
        horizontalInset: CGFloat = Slate.Metric.projectIslandInset,
    ) {
        self.tint = tint
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = tint
        layer.cornerRadius = Slate.Metric.islandRadiusCompact
        // ``Slate/Metric/islandRadiusCompact`` is drawn as a SQUIRCLE — one rung above the 8 macOS puts on
        // its own selected sidebar row, so a bed reads as a rounded island rather than as the squarish
        // card it was.
        layer.cornerCurve = .continuous

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // ⚠️ "FILL THE COLUMN, LEADING-ALIGNED" IS TWO RULES, NOT ONE, and Auto Layout needs both spelled
        // or the bed loses half of it. The bed PROPOSES its full width to the content — a row of tabs, or
        // a selected chip, takes it — and a child that DECLINES stays on the leading rail rather than
        // centring. The inequality below is the second half; this low-priority equality is the first, and
        // at `.defaultLow` it sits under a `UILabel`'s own horizontal hugging, so a bare header name still
        // measures itself while a container with no intrinsic width of its own fills the bed. Pinned at
        // full priority instead, a header's name would stretch across the whole sidebar. (A declarative
        // `.frame(maxWidth: .infinity, alignment: .leading)` bundled the pair into one word; the price of
        // spelling them out is also the ability to give each its own priority.)
        let fill = content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -horizontalInset),
            fill,
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }
}
#endif
