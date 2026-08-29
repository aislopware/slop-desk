// DeviceDrill — the four device-panel surfaces' shared half of "two depths, one column".
//
// Both device panels (Simulators, Android) show the same subject at two depths — the host's device
// set, and one device being driven — and both replace one with the other rather than sitting them
// side by side. Four controllers wrote that move: two shells × two panels. What they genuinely
// disagree about is the ANIMATION (`NSAnimationContext` + `animator()` against `CATransaction` and
// `UIView.animate`), and that stays in each shell. What they were only ACCIDENTALLY writing four
// times is the arithmetic and the mount, which is here.
//
// ⚠️ THE NUDGE'S RUNG IS DECIDED ONCE. `space4` entering, `-space4` leaving, and the negation is what
// makes the pair read as one movement rather than as two transitions that happen to be opposites. It
// was typed at four sites, so a taste change to the depth cue was a four-file edit with three chances
// to leave one behind — exactly the drift `no-cross-target-clone` exists to catch.

#if os(macOS)
import AppKit
#else
import UIKit
#endif

import SlopDeskDevicePanels
import SlopDeskSlate

package enum DeviceDrill {
    /// How far, and which way, a depth is nudged. ENTERING, the deeper surface arrives from the
    /// trailing edge; LEAVING, the shallower one arrives from the leading edge.
    ///
    /// A NUDGE, not a page slide: a full-width push of a live H.264 surface spends a whole beat
    /// compositing a video layer across the panel to say what a few points of parallax already say.
    /// The depth cue is the offset's DIRECTION; the fade carries the rest.
    package static func shift(entering: Bool) -> CGFloat {
        entering ? Slate.Metric.space4 : -Slate.Metric.space4
    }

    /// Mount `surface` filling `host`, offset horizontally by `offset`, and hand back the two
    /// constraints that carry the slide.
    ///
    /// BOTH DEPTHS ARE MOUNTED MID-DRILL and neither may squeeze the other while they overlap, which
    /// is why this pins four edges rather than stacking. The vertical pair is anonymous — nothing
    /// animates it — so only the horizontal pair comes back.
    @MainActor
    package static func mount(
        _ surface: SlateHostView, in host: SlateHostView, offsetBy offset: CGFloat,
    ) -> DeviceDrillSlide {
        surface.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(surface)
        let leading = surface.leadingAnchor.constraint(
            equalTo: host.leadingAnchor, constant: offset,
        )
        let trailing = surface.trailingAnchor.constraint(
            equalTo: host.trailingAnchor, constant: offset,
        )
        NSLayoutConstraint.activate([
            leading, trailing,
            surface.topAnchor.constraint(equalTo: host.topAnchor),
            surface.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return DeviceDrillSlide(leading: leading, trailing: trailing)
    }
}

/// The horizontal pair a mounted depth slides on. A STRUCT of two constraints rather than two stored
/// properties per controller, because they are only ever written together and a controller that kept
/// one of them stale would slide a surface into a parallelogram.
package struct DeviceDrillSlide {
    package let leading: NSLayoutConstraint
    package let trailing: NSLayoutConstraint
}

package extension AndroidSidebarModel {
    /// The way IN to one device's stage.
    ///
    /// It lives on the MODEL rather than in either surface because the selection write is what CARRIES
    /// the drill — the panel's transition vocabulary belongs to whatever owns both depths, and the two
    /// halves declare no animation of their own for it.
    ///
    /// The GUARD is ``AndroidPresentation/canEnter(_:)``, asked here and again at the card's own tap,
    /// because a card that lights under the finger and then does nothing is worse than one that never
    /// lit.
    func drillIn(to device: AndroidDevice) {
        guard AndroidPresentation.canEnter(device) else { return }
        select(device.key)
    }
}
