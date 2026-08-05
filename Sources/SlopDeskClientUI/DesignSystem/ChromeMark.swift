// ChromeMark — Google Chrome's wheel, drawn, for ``AndroidRobotMark``'s reason: no icon set this app
// can link against ships it.
//
// MONOCHROME, in the strip's ink, like every other mark (user-directed 2026-08-05 — the first cut
// drew it in Google's four brand colours and it was the only coloured thing in the app's chrome).
// What the colours were carrying, the SHAPE has to carry instead: three arcs of a ring with a dot in
// the middle. That is why the seams here are GAPS and the artwork's are not — in colour the three
// sectors are told apart by hue and meet edge to edge, and in one ink a ring with no breaks in it is
// just a ring.
//
// THE BREAKS ARE HOLES, not paint — ``AndroidRobotMark``'s eyes lesson, and the same trap. The plate
// under the mark changes tone when the tab is selected, so a gap painted in the resting plate's
// colour would either vanish when selected or float when it is not. Left as gaps in a single
// even-odd fill, they are whatever the plate is.
//
// Bearings are the logo's: three 120° arcs, the top one centred on straight up and the seam between
// the lower two pointing straight down.

import SwiftUI

/// Chrome's wheel at `side` points square, in the current foreground style.
struct ChromeMark: View {
    /// The mark's box — ``Slate/Metric/chromeMark``.
    let side: CGFloat

    var body: some View {
        Wheel().fill(style: FillStyle(eoFill: true))
            .frame(width: side, height: side)
    }

    // MARK: Geometry

    // Proportions of the box, so the mark is resolution- and size-independent. The ring is thinner
    // than the artwork's sectors: those are solid wedges read as colour, and this one is read as a
    // line, which the strip's other marks are drawn as too.
    private static let ringOuter: CGFloat = 0.5
    private static let ringInner: CGFloat = 0.325
    private static let hubRadius: CGFloat = 0.185
    /// Half the break between two arcs, in degrees. Wide enough to survive the strip's 12 points —
    /// at that size the ring's stroke is barely two points, and a break narrower than the stroke
    /// reads as an artefact rather than a seam.
    private static let breakAngle: CGFloat = 9

    /// Compass bearings in a y-down space, where 270° is straight up: an arc centred on the top and
    /// the other two meeting at the bottom.
    private static let starts: [CGFloat] = [210, 330, 90]

    private struct Wheel: Shape {
        func path(in rect: CGRect) -> Path {
            let side = min(rect.width, rect.height)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let outer = side * ChromeMark.ringOuter
            let inner = side * ChromeMark.ringInner

            var path = Path()
            for start in ChromeMark.starts {
                let from = start + ChromeMark.breakAngle
                let to = start + 120 - ChromeMark.breakAngle
                path.addArc(
                    center: centre, radius: outer,
                    startAngle: .degrees(Double(from)), endAngle: .degrees(Double(to)),
                    clockwise: false,
                )
                path.addArc(
                    center: centre, radius: inner,
                    startAngle: .degrees(Double(to)), endAngle: .degrees(Double(from)),
                    clockwise: true,
                )
                path.closeSubpath()
            }
            let hub = side * ChromeMark.hubRadius
            path.addEllipse(in: CGRect(
                x: centre.x - hub, y: centre.y - hub, width: hub * 2, height: hub * 2,
            ))
            return path
        }
    }
}
