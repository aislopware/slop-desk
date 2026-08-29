// SlateVectorDraw — the two mark drawings that are Core Graphics and nothing else
//
// Both shells render the status mark by hand into a `CGContext`, and both had transcribed the same two
// bodies: the stroked lucide glyph, and the braille cell's eight dots. Neither body touches AppKit or
// UIKit — `saveGState`, `setLineCap`, `fillEllipse` and `CGColor` are ONE api on both platforms, the
// same fact that dissolved the two `ViewEdges` copies — so the copies were never paying for a framework
// difference. They were paying for nothing.
//
// THE INK CROSSES AS A `CGColor`, deliberately. `NSColor` and `UIColor` are the one genuinely
// per-platform type in these bodies, and resolving to `CGColor` at the call site is also the only place
// where the trait environment is right: a dynamic colour must be read inside `draw(_:)`, which is where
// every caller already is.
//
// ⚠️ THE Y AXIS IS THE CALLER'S, NOT THIS FILE'S. `BrailleCell.position` answers in a TOP-DOWN box —
// UIKit's own space, and the space the geometry was authored in — while an unflipped `NSView` draws
// bottom-up. Rather than take a `flipped` flag and rebuild the arithmetic on one side (which would make
// the two shells' pixels differ in the last bit for no reason anyone could see), the caller hands over
// the `anchor` its dots are measured FROM and a `step` of ±1. Each shell's expression survives verbatim.

import CoreGraphics

package enum SlateVectorDraw {
    /// One stroked icon, scaled out of its own viewBox into `rect`.
    ///
    /// The width scales WITH the glyph (`strokeWidth` is in viewBox units), so a 14pt mark and a 24pt
    /// one are the same drawing at two sizes rather than two weights. Round caps and joins are lucide's
    /// own convention and every icon in ``OttyIcon`` is authored for them.
    package static func stroke(
        _ icon: VectorIcon, in rect: CGRect, ink: CGColor, into context: CGContext,
    ) {
        let scale = CGFloat.minimum(rect.width, rect.height) / icon.viewBox
        context.saveGState()
        context.setStrokeColor(ink)
        context.setLineWidth(icon.strokeWidth * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for outline in icon.outlines {
            context.addPath(SVGPath.cgPath(outline, viewBox: icon.viewBox, in: rect))
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The Android head: antennae stroked, dome filled even-odd, in that order.
    ///
    /// THE ORDER IS THE DRAWING. The antennae go down FIRST and as their OWN path because the head is
    /// filled even-odd — an antenna crossing the dome's rim inside that one path would subtract a
    /// notch from it exactly where the two meet. Both panel tab plates had this ladder transcribed,
    /// and every call in it (`setFillColor`, `setLineCap`, `addPath`, `fillPath`) is one api on both
    /// frameworks.
    ///
    /// THE GEOMETRY IS THE CALLER'S — `AndroidMarkPath` answers in a y-DOWN space, which is UIKit's
    /// own and is NOT an unflipped `NSView`'s, so which rect the mark is measured in and whether the
    /// context has been flipped to meet it are the shell's questions and stay at the call site. What
    /// crosses is the three products of asking them.
    package static func androidMark(
        head: CGPath, antennae: CGPath, lineWidth: CGFloat, ink: CGColor, into context: CGContext,
    ) {
        context.saveGState()
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.addPath(antennae)
        context.strokePath()
        context.addPath(head)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    /// The braille cell's dots, at the brightness ``AgentSpinner/lit(_:hole:)`` gives each.
    ///
    /// `anchor` is the corner the dot positions are measured from and `step` is +1 in a top-down space
    /// (UIKit) or -1 in a bottom-up one (an unflipped `NSView`); `x` is always left-to-right. A dot at
    /// zero brightness is SKIPPED rather than filled transparent — same pixels, one less fill.
    ///
    /// ⚠️ `fillEllipse` rather than a bezier path per dot: this loop runs on a display link, so a path
    /// object per dot is EIGHT heap allocations (each with its own backing `CGPath`) per frame per
    /// glyph, thrown away before the next tick — measured in a scratch `swiftc -O` harness drawing the
    /// same eight dots at 28.6 µs/frame with the paths against 22.5 µs without, a fifth of the frame
    /// for objects nothing reads. A navigator full of thinking agents runs this once per mark per
    /// display refresh.
    ///
    /// The dimmed ink is `CGColor.copy(alpha:)` and the fill is `setFillColor(_:)`, which is the form
    /// that KEEPS the colour space — the three call sites this replaced each carried a note that
    /// `setFillColor(red:green:blue:alpha:)` would buy the last of the gap and pay for it by filling in
    /// a different space. That trade is still refused; it is only spelled once now.
    package static func brailleCell(
        into context: CGContext, ink: CGColor, hole: Double, box: CGSize, anchor: CGPoint,
        step: CGFloat, zoom: CGFloat,
    ) {
        let side = StatusDot.dotDiameter * zoom
        for index in 0..<BrailleCell.dotCount {
            let lit = AgentSpinner.lit(index, hole: hole)
            guard lit > 0, let dot = ink.copy(alpha: CGFloat(lit)) else { continue }
            let point = BrailleCell.position(of: index, in: box, zoom: zoom)
            context.setFillColor(dot)
            context.fillEllipse(in: CGRect(
                x: anchor.x + point.x - side / 2, y: anchor.y + step * point.y - side / 2,
                width: side, height: side,
            ))
        }
    }
}
