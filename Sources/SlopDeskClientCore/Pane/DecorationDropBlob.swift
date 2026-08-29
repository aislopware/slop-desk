// DecorationDropBlob — one drop zone's soft ellipse, as the two layers it actually is.
//
// The drop overlay was already almost entirely one implementation: `PaneDropZoneLayout` places the
// five blobs (draw == hit, and the shape is Rust's), `DropZonePresentation` decides the wording, the
// green-terminal-half / blue-pane-half partition, the label offsets and the three-way ink verdict.
// What was still typed twice was the part everyone assumes is a framework spelling and is not —
// TWO `CAShapeLayer`s, an ellipse path each, one cross-fade and one hairline inset. QuartzCore is one
// API on both platforms, so `no-cross-target-clone` counted a nine-line window and a ten-line one
// between `MacPaneDropOverlay` and `PaneDropOverlayView` (docs/56 §3, docs/62 stage I).
//
// ⚠️ CGColor IN, NOT `SlateNativeColor`, AND THAT IS THE WHOLE BOUNDARY. A dynamic colour resolves against
// the trait environment at the moment `.cgColor` is read, so the resolution has to happen where the
// environment is — inside `effectiveAppearance.performAsCurrentDrawingAppearance` on the Mac, against
// `traitCollection` on the phone. Those two sentences are the ONLY divergence left in the blob, and
// they are each two words long. Handing a `SlateNativeColor` down here instead would freeze it against
// whichever appearance happened to be current, which is the trap `SlateHostTypes`' header names.
//
// ⚠️ THE RUNG LOOKUPS DO NOT COME DOWN. `slopdesk-invariants` reads every case of `DropZoneInk` and
// `DropZoneLabelInk` out of the enum and requires BOTH shells to answer each one explicitly, so a
// newly-added rung cannot be inked by a `default:` arm in one renderer only. That ratchet is about
// the two `switch`es, which stay where the ratchet reads them; what descends here is the ARITHMETIC
// around them — the alpha scale that travels with a rung, and the fact that the ring is only ever
// the status colour.
//
// It is a plain object rather than a view: a blob owns layers, and the SUBVIEW it hangs them on has
// to stay per-shell because the overlay interleaves blob-then-label in subview order (a later zone's
// blob washes over an earlier zone's label, which is what the shipping overlay does).

import QuartzCore
import SlopDeskSlate
import SlopDeskWorkspaceCore

/// The wash and the ring for one zone, mounted on a host layer the caller owns.
///
/// Two layers rather than one stroked-and-filled shape, because the ring is drawn INSIDE the shape's
/// edge while `CAShapeLayer` centres its stroke on the path. The ring's path is inset by half a
/// hairline to land there, and a fill that shared that path would shrink by the same amount.
@MainActor
package final class DecorationDropBlob {
    /// The node the two shapes hang on. The caller adds it wherever it is drawing — which is the one
    /// line of this that is per-shell, and only because `NSView.layer` is optional and `UIView`'s is
    /// not. Handing the host layer IN instead would have made this initialiser take an optional or
    /// force one, for nothing.
    package let node = CALayer()

    private let wash = CAShapeLayer()
    private let ring = CAShapeLayer()

    package init() {
        ring.fillColor = nil
        ring.lineWidth = Slate.Metric.hairline
        node.addSublayer(wash)
        node.addSublayer(ring)
    }

    /// Ink both layers, with the colours already resolved against the caller's appearance.
    ///
    /// `animated` spends ``Slate/Motion/reveal`` on the cross-fade — the pointer moving from one zone
    /// to the next is the only thing that ever changes these colours, and it is the same reveal the
    /// whole overlay arrives on.
    package func ink(fill: CGColor, ring rim: CGColor, animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Slate.Motion.reveal.duration)
            CATransaction.setAnimationTimingFunction(Slate.Motion.reveal.timingFunction)
        } else {
            CATransaction.setDisableActions(true)
        }
        wash.fillColor = fill
        ring.strokeColor = rim
        CATransaction.commit()
    }

    /// Re-path both ellipses inside `box`, which is the blob view's own bounds.
    ///
    /// An ellipse inside its own bounds is symmetric under a flip, which is what keeps a blob out of
    /// the top-left/bottom-left question its parent answers. Unanimated on purpose: a resize is not a
    /// reveal, so the ellipses must arrive at their new size with the pane rather than drift there
    /// behind it.
    package func place(in box: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        node.frame = box
        wash.frame = box
        wash.path = CGPath(ellipseIn: box, transform: nil)
        ring.frame = box
        let inset = Slate.Metric.hairline / 2
        ring.path = CGPath(ellipseIn: box.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
    }
}

/// One zone's three colours, already scaled to the alphas its verdict carries.
package struct DecorationDropInk {
    /// The wash.
    package let fill: SlateNativeColor
    /// The ring, which says "release NOW".
    package let ring: SlateNativeColor
    /// The label under the blob.
    package let label: SlateNativeColor
}

/// The verdict → colour arithmetic, once.
@MainActor
package enum DecorationDropOverlayInk {
    /// What one zone wears, given who is hovered and which zones the drag is allowed to land in.
    ///
    /// The ALPHAS travel with the rung for the same reason the wording does — a half that owned the
    /// number would be free to disagree about how faint "at rest" is.
    ///
    /// The ring is only ever ``Slate/Native/Status/ok``, and an inactive zone gets that SAME colour at
    /// zero rather than no stroke at all: a colour can cross-fade to a colour and cannot cross-fade to
    /// nothing, so the ring would pop. The zero is the crossing's own rather than a branch spelled in
    /// a renderer.
    ///
    /// - Parameters:
    ///   - ink: the shell's `DropZoneInk` lookup — the half the ink ratchet reads, so it stays up
    ///     there and arrives here as a function.
    ///   - labelInk: the shell's `DropZoneLabelInk` lookup, for the same reason.
    package static func inks(
        for zone: DropZone,
        active: DropZone?,
        allowed: Set<DropZone>,
        ink: (DropZoneInk) -> SlateNativeColor,
        labelInk: (DropZoneLabelInk) -> SlateNativeColor,
    ) -> DecorationDropInk {
        let wash = DropZonePresentation.wash(
            zone, active: zone == active, allowed: allowed.contains(zone),
        )
        return DecorationDropInk(
            fill: ink(wash.ink).slateScalingAlpha(wash.opacity),
            ring: Slate.Native.Status.ok.slateScalingAlpha(wash.strokeOpacity),
            label: labelInk(wash.labelInk),
        )
    }
}
