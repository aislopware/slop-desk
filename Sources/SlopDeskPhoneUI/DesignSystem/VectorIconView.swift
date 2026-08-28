// SlateVectorIconView — the phone's renderer for the shared vector artwork.
//
// The artwork itself, its viewBox and the `d`-string reader are `SlopDeskSlate` (``VectorIcon``,
// ``OttyIcon``, ``SVGPath``): a drawing transcribed once. What is here is one of its two RENDERERS —
// the Mac's is `MacVectorIconView`, an `NSView` over the same paths. Two renderers, one drawing.
//
// ⚠️ A THIRD RENDERER USED TO LIVE HERE: a SwiftUI `VectorIconView` over `Canvas`, which walked the
// `d`-strings and filled them on every pass. It is deleted along with the rest of the tree's SwiftUI.
// One detail of it was load-bearing and is preserved below in the shape-layer spelling: the fills use
// the EVEN-ODD rule, not the default winding, because a Material duotone punches its holes with a
// second subpath wound the SAME way as the outer one (the cup's inner wall), which non-zero fills in
// solid.

#if os(iOS)
import QuartzCore
import SlopDeskSlate
import UIKit

/// One ``VectorIcon`` as `CAShapeLayer`s, drawn at a given side length in one ink. Stroke width
/// scales with the glyph (it is authored in viewBox units), so the drawing stays the source's
/// drawing at any size.
///
/// ⚠️ SHAPE LAYERS, not an override of `draw(_:)`. The Mac's `MacVectorIconView` draws into a CG
/// context because these glyphs sit in a sidebar row that repaints rarely; on the phone the same
/// glyph rides a SCROLLING
/// list, and a `draw(_:)` re-runs the `d`-string walk, the path build and the fill on every pass
/// through the layer's backing store. A `CAShapeLayer` hands the path to the render server ONCE: after
/// that a scroll, a fade or a transform is composited without the CPU seeing the icon again, and the
/// stroke stays resolution-independent through it. The paths themselves are rebuilt only when the
/// bounds or the ink actually change — `layoutSubviews` runs on every layout pass and most of them
/// change neither.
@MainActor
final class SlateVectorIconView: UIView {
    var ink: UIColor {
        didSet {
            guard ink != oldValue else { return }
            applyInk()
        }
    }

    private let icon: VectorIcon
    private let side: CGFloat
    /// The fills first, then the outlines — Core Animation composites sublayers in array order, which
    /// is the same back-to-front order both other renderers draw in.
    private var shapes: [CAShapeLayer] = []
    /// The bounds the current paths were built for. A layout pass that did not resize the view must
    /// not rebuild them.
    private var pathBounds: CGRect = .null

    init(icon: VectorIcon, side: CGFloat, ink: UIColor) {
        self.icon = icon
        self.side = side
        self.ink = ink
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        buildLayers()
        // The ink is DYNAMIC (`Slate.Native.*` resolves per appearance) and a `CGColor` on a layer is
        // not — it was fixed at the appearance current when it was assigned. Re-inking on the ONE
        // trait that can change it is the only thing a raw `CGColor` cannot do for itself.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
            view.applyInk()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != pathBounds else { return }
        pathBounds = bounds
        layoutPaths()
    }

    /// One layer per drawn element, created once. The `fillRule` is the ⚠️ both other renderers carry:
    /// a Material duotone punches its holes with a second subpath wound the SAME way as the outer one,
    /// which the default non-zero rule would fill in solid.
    private func buildLayers() {
        for fill in icon.fills {
            let shape = CAShapeLayer()
            shape.fillRule = .evenOdd
            shape.opacity = Float(fill.opacity)
            shape.lineWidth = 0
            shape.strokeColor = nil
            layer.addSublayer(shape)
            shapes.append(shape)
        }
        for _ in icon.outlines {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
            shapes.append(shape)
        }
        applyInk()
    }

    private func layoutPaths() {
        // The stroke is authored in viewBox units, so it scales with the glyph — the drawing stays the
        // source's drawing at any size.
        let scale = CGFloat.minimum(bounds.width, bounds.height) / icon.viewBox
        var index = 0
        for fill in icon.fills {
            shapes[index].frame = bounds
            shapes[index].path = SVGPath.path(fill.data, viewBox: icon.viewBox, in: bounds).cgPath
            index += 1
        }
        for outline in icon.outlines {
            shapes[index].frame = bounds
            shapes[index].path = SVGPath.path(outline, viewBox: icon.viewBox, in: bounds).cgPath
            shapes[index].lineWidth = icon.strokeWidth * scale
            index += 1
        }
    }

    private func applyInk() {
        // ⚠️ RESOLVED against this view's traits, not left dynamic. A `CGColor` taken off a dynamic
        // `UIColor` without resolving it captures whatever appearance happened to be current, which on
        // a phone pinned to light (``SlateAppearancePin``) is right by luck rather than by rule.
        let resolved = ink.resolvedColor(with: traitCollection).cgColor
        var index = 0
        for _ in icon.fills {
            shapes[index].fillColor = resolved
            index += 1
        }
        for _ in icon.outlines {
            shapes[index].strokeColor = resolved
            index += 1
        }
    }
}
#endif
