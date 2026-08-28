// SlateSheetSurface — how a NATIVE sheet is made to wear the floating family's own corner.
//
// The Connect form is the one surface in this app the PLATFORM presents: a real sheet, so the system
// owns its entrance, its dismissal and the ground it sits on. What the content still owns is its own
// plate — and every other summoned surface in the app wears ``Slate/Metric/radiusPanel``. One surface
// in the set rounded differently from the other seven is exactly the kind of seam this design has
// spent its rounds closing, so the sheet's content draws the family's corner for itself rather than
// inheriting whatever the presentation would have cut.
//
// ⚠️ NOT a way to smuggle the in-window card family into a sheet. The surface here is the paper card's
// two ingredients only — the ground's cream at the family's corner, plus the hairline that draws its
// boundary. It carries NO cast shadow of its own: the presentation already casts one, and two shadows
// on one object is the halo that made the earlier sheet experiments look wrong.

#if os(iOS)
import QuartzCore
import SlopDeskSlate
import UIKit

/// The SHEET's own surface, as a decoration of the presented controller's own view: the ground's cream at
/// the floating family's corner, edged by the same hairline the cards use. The presentation itself is the
/// platform's — the plate is the only part of it the content can speak for.
///
/// A DECORATION AND NOT A HOSTING VIEW, which for once needs no argument: everything here is a `layer`
/// property. It adds no inset, no chrome and no second layer — a sheet's content already has a root view,
/// and putting another one under it would be a view whose entire job is to hold three properties the root
/// view can hold itself.
///
/// ⚠️ THE ABSENT SHADOW IS THE POINT, and it is the one thing this surface must never grow. Its sibling
/// ``SlatePaperCardSurface`` publishes a `layoutShadow(of:)` half that the caller owes from
/// `layoutSubviews`; there is deliberately no counterpart here, because the PRESENTATION already casts a
/// shadow and two shadows on one object is the halo that made the earlier sheet experiments look wrong.
/// A sheet is also the one surface in the family that cannot fall behind on that contract, since it has
/// no contract to fall behind on.
///
/// ⚠️ NOT a way to smuggle the in-window card family into a sheet. The surface here is the paper card's
/// two ingredients only — the ground's cream at the family's corner, plus the hairline that draws its
/// boundary.
@MainActor
enum SlateSheetSurface {
    /// Draw `view` as the sheet's plate. ONCE, when the controller's view is loaded: this installs a
    /// trait-change registration, and registrations stack on a second call.
    static func apply(to view: UIView) {
        // A VIEW-level fill, so the cream follows the appearance without anything re-applying it. Only
        // the rim below is a `CALayer` `CGColor`, and only it needs the registration.
        view.backgroundColor = Slate.Native.Surface.field
        // Every other summoned surface in this app wears ``Slate/Metric/radiusPanel``, and one surface in
        // the set rounded differently from the other seven is exactly the kind of seam this design has
        // spent its rounds closing — so the sheet's content draws the family's corner for itself rather
        // than inheriting whatever the presentation would have cut.
        view.layer.cornerRadius = Slate.Metric.radiusPanel
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = Slate.Metric.hairline
        // ⚠️ `masksToBounds` is left ALONE rather than turned on: a plate is a background and a rim, and
        // content that wants the corner clipped asks for it at the call site. Turning it on here would
        // also be the one line that could eat a descendant's own cast.
        reink(view)
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (sheet: UIView, _: UITraitCollection) in
            reink(sheet)
        }
    }

    /// The same rim the paper cards wear — one floating family, one boundary rule. Resolved against the
    /// view's own traits, because a `CGColor` is a flat value that stopped following the appearance the
    /// moment it was stored.
    private static func reink(_ view: UIView) {
        view.layer.borderColor = Slate.Native.Line.overlayRim
            .resolvedColor(with: view.traitCollection).cgColor
    }
}
#endif
