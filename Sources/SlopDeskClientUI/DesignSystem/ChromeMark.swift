// ChromeMark — Google Chrome's wheel, drawn, for ``AndroidRobotMark``'s reason: no icon set this app
// can link against ships it.
//
// It is the ONE mark in the strip that carries its own colour, and that is deliberate rather than an
// oversight. The tab beside it says "Chrome"; a monochrome Chrome wheel is three seams in a disc,
// which reads as an aperture or a pie chart and names nothing. The logo is only a logo in its four
// colours, so a mark that has to say WHICH browser the panel drives is drawn in them. Selection is
// unaffected: the plate fill and the label's weight carry that state here exactly as they do for
// every other tab, and a brand mark that dimmed when unselected would read as disabled.
//
// THE RING IS A HOLE, not white paint — ``AndroidRobotMark``'s eyes lesson, and the same trap. The
// plate under the mark changes tone when the tab is selected, so a white ring would either match the
// resting plate and vanish when selected, or match the selected plate and float when it is not.
// Knocked out of the sectors' annulus with an even-odd fill, the gap is whatever the plate is.
//
// The three sectors are the logo's simplified construction: 120° each, the red one centred on top
// and the green/yellow seam pointing straight down. The real artwork bends red's lower edge into a
// windshield over the blue hub; at strip size that curve is a fraction of a point and costs more
// than it says.

import SwiftUI

/// Chrome's wheel at `side` points square, in Google's brand colours.
struct ChromeMark: View {
    /// The mark's box — ``Slate/Metric/chromeMark``.
    let side: CGFloat

    var body: some View {
        ZStack {
            ForEach(Self.sectors, id: \.start) { sector in
                Sector(start: sector.start)
                    .fill(sector.colour, style: FillStyle(eoFill: true))
            }
            Circle()
                .fill(Self.hub)
                .frame(width: side * Self.hubRadius * 2, height: side * Self.hubRadius * 2)
        }
        .frame(width: side, height: side)
    }

    // MARK: Geometry

    // Proportions of the box, so the mark is resolution- and size-independent, and taken from the
    // artwork: a coloured annulus from just past half the radius out to the rim, a hub a little
    // under half the radius, and a hairline between them. The first cut opened that gap to twice
    // the artwork's on the theory that a sub-point gap cannot be seen — rendered at true size it
    // read as a dark ring cutting the wheel in two, because on a dark plate the gap is not a
    // hairline of white, it is a hairline of BACKGROUND, and widening it makes a hole.
    private static let ringOuter: CGFloat = 0.5
    private static let ringInner: CGFloat = 0.265
    private static let hubRadius: CGFloat = 0.225

    /// Compass bearings, in a y-down space where 270° is straight up. Red spans the top; the seam
    /// between green and yellow points straight down, as it does in the artwork.
    private static let sectors: [(start: CGFloat, colour: Color)] = [
        (start: 210, colour: Color(brandHex: 0xEA4335)), // red, top
        (start: 330, colour: Color(brandHex: 0xFBBC04)), // yellow, lower right
        (start: 90, colour: Color(brandHex: 0x34A853)), // green, lower left
    ]

    private static let hub = Color(brandHex: 0x4285F4)

    /// One 120° wedge of the annulus: the outer arc out, the inner arc back, so an even-odd fill
    /// leaves the hole the hub sits in rather than a solid pie slice.
    private struct Sector: Shape {
        let start: CGFloat

        func path(in rect: CGRect) -> Path {
            let side = min(rect.width, rect.height)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let outer = side * ChromeMark.ringOuter
            let inner = side * ChromeMark.ringInner
            let end = start + 120

            var path = Path()
            path.addArc(
                center: centre, radius: outer,
                startAngle: .degrees(Double(start)), endAngle: .degrees(Double(end)),
                clockwise: false,
            )
            path.addArc(
                center: centre, radius: inner,
                startAngle: .degrees(Double(end)), endAngle: .degrees(Double(start)),
                clockwise: true,
            )
            path.closeSubpath()
            return path
        }
    }
}

private extension Color {
    /// A brand colour from its published hex. Brand marks are the one place in this app that does
    /// NOT read from ``Slate`` — a theme token would let a palette change repaint someone's logo.
    init(brandHex hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
        )
    }
}
