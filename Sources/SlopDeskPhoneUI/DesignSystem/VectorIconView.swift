// VectorIconView — the SwiftUI renderer for the shared vector artwork.
//
// The artwork itself, its viewBox and the `d`-string reader are `SlopDeskSlate` (``VectorIcon``,
// ``OttyIcon``, ``SVGPath``): a drawing transcribed once. What is here is one of its two RENDERERS —
// the Mac's is `MacVectorIconView`, an `NSView` over the same paths (docs/56 stage D). Two renderers,
// one drawing, on the ``AgentSpinner`` terms.

#if os(iOS)
import SlopDeskSlate
import SwiftUI

/// One ``VectorIcon`` drawn at a given side length in one ink. Stroke width scales with the glyph
/// (it is authored in viewBox units), so the drawing stays the source's drawing at any size.
struct VectorIconView: View {
    let icon: VectorIcon
    let side: CGFloat
    let ink: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let scale = CGFloat.minimum(size.width, size.height) / icon.viewBox
            for layer in icon.fills {
                let path = SVGPath.path(layer.data, viewBox: icon.viewBox, in: rect)
                // ⚠️ EVEN-ODD, not the default winding: a Material duotone punches its holes with a
                // second subpath wound the SAME way as the outer one (the cup's inner wall), which
                // non-zero would fill in solid.
                context.fill(path, with: .color(ink.opacity(layer.opacity)), style: FillStyle(eoFill: true))
            }
            for outline in icon.outlines {
                let path = SVGPath.path(outline, viewBox: icon.viewBox, in: rect)
                context.stroke(
                    path, with: .color(ink),
                    style: StrokeStyle(
                        lineWidth: icon.strokeWidth * scale, lineCap: .round, lineJoin: .round,
                    ),
                )
            }
        }
        .frame(width: side, height: side)
    }
}
#endif
