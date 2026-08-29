// DeviceBezelGeometry — where a piece of a simulator's artwork lands on screen.
//
// A bezel draws three kinds of thing at three sizes — the case body, the screen rect, and one frame
// per physical button — and every one of them is the SAME arithmetic: take the rectangle the artwork
// declares in its own points, move it into the BLEED's space by subtracting the bleed's origin, and
// scale it by however much the band could give the device. Six sites wrote that by hand, three per
// shell, each spelling `(minX - origin.x) * scale` again.
//
// This is Core Graphics only, which is the whole reason it descends: `CGRect`, `CGPoint` and `CGFloat`
// are one type on both platforms, so the seat has nothing framework-shaped left in it. What genuinely
// stays in each shell is the CONTAINER's convention — AppKit's `frameCenterRotation` against UIKit's
// `transform`, and a flipped assembly against an unflipped one — which is why the two `layout` bodies
// still differ above and below this call.

import CoreGraphics

package enum DeviceBezelGeometry {
    /// Where `rect` — measured in the artwork's own points — lands, given the artwork's `bleed` box
    /// and the scale the band resolved to.
    ///
    /// The BLEED is the origin, not the screen: an artwork whose case overhangs its nominal frame
    /// declares a bleed with a negative origin, and every piece drawn inside it has to move by the
    /// same amount or the case and its buttons come apart by exactly that overhang.
    package static func seat(_ rect: CGRect, in bleed: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.minX - bleed.origin.x) * scale, y: (rect.minY - bleed.origin.y) * scale,
            width: rect.width * scale, height: rect.height * scale,
        )
    }
}
