// SlatePlateGroup — the TRAY: several plate controls that read as one instrument.
//
// A strip of loose ``SlatePlateIconButton``s is legible at three and illegible at ten. Past about five
// the eye stops seeing verbs and starts seeing texture — every glyph the same size, the same ink and
// the same distance from its neighbours, so nothing says which of them belong together or which one is
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
// grey. The tray writes that fact onto each member as it mounts it (`SlatePlateIconButton.onTray`), so
// no call site has to remember to say where its button is sitting.

#if os(iOS)
import SlopDeskSlate
import UIKit

/// Several plate controls on one tray — a single fill, a single corner, no gaps between members.
///
/// ⚠️ THE TRAY FLAG IS A PROPERTY, NOT A CHANNEL, and that is worth naming because the declarative
/// spelling of this tray could not do it that way: a view that is handed its children cannot reach into
/// them, so the flag had to travel down the environment and be picked up by a matching read in every
/// plate — a channel with two ends and a default that silently means "not on a tray" for anything that
/// forgets to read it. A `UIView` holds its members, so the tray simply sets ``SlatePlateIconButton``'s
/// `onTray` on the way in: one write, at the one moment the answer is known, with nothing to forget.
///
/// The fill is ``Slate/Native/State/hover`` (4–5%) rather than the Mac tray's `Overlay.well`, and
/// `MacDevicePanelPlateTray`'s comment says why the two differ: `MacPlateIconButton` reads no tray flag,
/// so that tray has to step its own fill DOWN to stay under a member's hover. These members relight
/// themselves, so this tray keeps the fill the design named.
///
/// A dynamic `UIColor` straight onto `backgroundColor` — no `CGColor`, so no re-inking on a trait
/// change. The tray's fill is STATIC (nothing about it animates), and UIKit re-resolves a dynamic
/// colour assigned to `backgroundColor` on every appearance change by itself; the resolve-and-re-apply
/// dance ``SlatePlateIconButton`` carries is the price of a layer property, which is the price of a
/// fill that has to fade.
@MainActor
final class SlatePlateTray: UIStackView {
    /// Typed on the plate rather than on `UIView`, because handing the tray something that cannot
    /// relight itself is the one mistake this class exists to make impossible.
    init(_ plates: [SlatePlateIconButton]) {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        // Members butt against each other on purpose. The tray's job is to say "these are one
        // instrument", and a gap between two members inside it argues the opposite while costing the
        // width that made the grouping necessary.
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Slate.Metric.radiusControl
        layer.cornerCurve = .continuous
        backgroundColor = Slate.Native.State.hover
        for plate in plates {
            // A TRAY RELIGHTS ITS MEMBERS: a plate's own hover fill IS the tray's fill, so inside one
            // it would vanish. Set BEFORE the plate is mounted, which is also why `onTray`'s `didSet`
            // repaints and does not acknowledge — a fill change off-window is invisible, and the one
            // effect that would be visible (the glyph bounce) belongs to `morphOn`, which is guarded on
            // `window != nil` for exactly this reason.
            plate.onTray = true
            addArrangedSubview(plate)
        }
    }

    // ⚠️ NOT `init?` here, unlike every other control in this family. `UIStackView` REDECLARES
    // `initWithCoder:` as a non-null designated initializer, where `UIView`/`UIControl`/`UIButton`
    // leave it `nullable` — so the failable override the rest of the family carries does not compile
    // on this one class.
    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("not from a nib") }
}
#endif
