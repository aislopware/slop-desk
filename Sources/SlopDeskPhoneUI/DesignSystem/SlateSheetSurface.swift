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
import SlopDeskSlate
import SwiftUI

extension View {
    /// Draw this content as the SHEET's own surface: the ground's cream at the floating family's corner,
    /// edged by the same hairline the cards use. The presentation itself is the platform's — the plate is
    /// the only part of it the content can speak for.
    func slateSheetSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: Slate.Metric.radiusPanel, style: .continuous)
        return background(Slate.Surface.field, in: shape)
            // The same rim the paper cards wear — one floating family, one boundary rule.
            .overlay { shape.strokeBorder(Slate.Line.overlayRim, lineWidth: Slate.Metric.hairline) }
    }
}
#endif
