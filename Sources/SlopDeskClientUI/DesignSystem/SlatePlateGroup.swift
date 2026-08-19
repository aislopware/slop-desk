// SlatePlateGroup — the TRAY: several plate controls that read as one instrument.
//
// A strip of loose ``PlateIconButton``s is legible at three and illegible at ten. Past about five the
// eye stops seeing verbs and starts seeing texture — every glyph the same size, the same ink and the
// same distance from its neighbours, so nothing says which of them belong together or which one is
// reached for most. Hairline separators between them help less than they look like they should: a
// 1pt rule between two 24pt plates is a smaller signal than the gap it sits in.
//
// A tray is the stronger signal because it is a SHAPE. Plates inside one share a fill and a corner,
// so a rail of ten becomes three objects — turn it, drive it, capture it — and the count stops
// mattering. The fill is the search plate's own (`State.hover`, 4–5%), which is deliberate: this
// panel already puts an inset control on that tint, and a tray at any heavier weight would read as a
// bezel — the at-rest ornament MERIDIAN spends nothing on.
//
// A TRAY RELIGHTS ITS MEMBERS. A plate's own hover fill IS the tray's fill, so inside one it would
// vanish; a member on a tray takes the next rung up (`State.selected`) for hover and a real
// `Surface.raised` for the latched state, which reads as a lit key rather than a slightly different
// grey. That is what the environment flag below carries — set by the tray, read by the plate, so no
// call site has to remember to say where its button is sitting.

#if canImport(SwiftUI)
import SlopDeskSlate
import SwiftUI

/// Several plate controls on one tray — a single fill, a single corner, no gaps between members.
///
/// Members butt against each other on purpose. The tray's job is to say "these are one instrument",
/// and a gap between two members inside it argues the opposite while costing the width that made the
/// grouping necessary.
struct SlatePlateGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .background(Slate.State.hover, in: .rect(cornerRadius: Slate.Metric.radiusControl))
        .environment(\.slateOnPlateTray, true)
    }
}

extension EnvironmentValues {
    /// Whether the reading view sits on a ``SlatePlateGroup`` tray — which shifts a plate's hover and
    /// latched fills up a rung so they stay visible against it. Read by ``PlateIconButton``; nothing
    /// else should key on it, and no call site sets it directly.
    @Entry var slateOnPlateTray: Bool = false
}
#endif
