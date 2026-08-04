// AndroidRobotMark — the Android head, drawn, because no icon set ships one.
//
// It exists for a reason the design system otherwise resists. Every other mark in this project is a
// SHAPE rather than a brand: `docs/47` records the device rows deliberately drawing a phone, a tablet
// and a watch instead of an Apple or a Google device, because a row already carries the device's name
// and a logo there would be a claim the reader does not need. A TAB is the opposite case. The two
// device tabs name PLATFORMS, they sit side by side, and drawn as shapes they were `iphone` next to
// `candybarphone` — two rounded rectangles differing by a corner radius, which at plate height is no
// difference at all. A platform is the one thing its own mark says faster than any silhouette can.
//
// Apple's half is an SF Symbol. Android's is not in SF Symbols, in Apple's icon sets, or anywhere else
// this app can link against, so it is a path.
//
// THE EYES ARE HOLES, not dots, and that is why the head is a single even-odd fill: dots would need a
// colour of their own, and the plate underneath changes tone when the tab is selected — so painted
// eyes would either match the resting plate and vanish when selected, or match the selected plate and
// float when it is not. Knocked out, they are whatever the plate is, always.
//
// The antennae are a SEPARATE shape layered beneath rather than a third subpath of the same one.
// Even-odd cancels overlap, so an antenna crossing the dome's rim would subtract a notch from it
// exactly where the two meet.
//
// IT FILLS ITS BOX (user-directed 2026-08-04). The first cut drew the dome at four fifths of the
// width and half the height, on the theory that a mark wants air around it — which is true of a
// symbol on Apple's optical grid, where the grid IS the air, and false of a path in a plain frame,
// where the frame's own padding already supplies it. Rendered beside `folder` and `display` at true
// size the head read as a smaller mark rather than a wider one. The dome is now the full width of
// its box and the whole drawing is centred on what it actually draws.

import SwiftUI

/// Android's robot head at `side` points square, in the current foreground style.
struct AndroidRobotMark: View {
    /// The mark's box — ``Slate/Metric/brandMark``, not the type size the plate's symbols take. A
    /// drawn brand mark and an SF Symbol do not weigh the same at the same measure; the token has
    /// the account.
    let side: CGFloat

    var body: some View {
        ZStack {
            Antennae()
            Head().fill(style: FillStyle(eoFill: true))
        }
        .frame(width: side, height: side)
    }

    // MARK: Geometry

    // Proportions of the box, so the mark is resolution- and size-independent. The dome sits low and
    // the antennae reach up, which puts the drawn mass — antenna tips at 0.23, flat base at 0.805 —
    // centred on the box rather than the dome alone being centred and the whole thing riding high.
    //
    // The head is the WIDEST part, and that is a constraint rather than an observation: an antenna
    // tip sits `sin(38°) × reach` from the centre, so any reach past 1.62 radii would push the tips
    // outside the dome and make the mark's width depend on the antennae instead of the head.
    private static let baseline: CGFloat = 0.805
    private static let radius: CGFloat = 0.47
    /// Measured from straight up, in degrees. Android's own mark splays them near 40°.
    private static let antennaAngle: CGFloat = 38
    private static let antennaReach: CGFloat = 1.55
    private static let antennaWidth: CGFloat = 0.085
    private static let eyeRadius: CGFloat = 0.058
    private static let eyeOffset = CGPoint(x: 0.19, y: 0.19)

    private struct Head: Shape {
        func path(in rect: CGRect) -> Path {
            let side = min(rect.width, rect.height)
            let centre = CGPoint(
                x: rect.midX, y: rect.minY + side * AndroidRobotMark.baseline,
            )
            let radius = side * AndroidRobotMark.radius

            var path = Path()
            // 180° → 360° passes through 270°, which is UP in a y-down space: the dome, with `close`
            // laying the flat side back along the baseline.
            path.addArc(
                center: centre, radius: radius,
                startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false,
            )
            path.closeSubpath()

            for direction in [CGFloat(-1), 1] {
                let eye = CGPoint(
                    x: centre.x + direction * side * AndroidRobotMark.eyeOffset.x,
                    y: centre.y - side * AndroidRobotMark.eyeOffset.y,
                )
                let size = side * AndroidRobotMark.eyeRadius
                path.addEllipse(in: CGRect(
                    x: eye.x - size, y: eye.y - size, width: size * 2, height: size * 2,
                ))
            }
            return path
        }
    }

    private struct Antennae: Shape {
        func path(in rect: CGRect) -> Path {
            let side = min(rect.width, rect.height)
            let centre = CGPoint(
                x: rect.midX, y: rect.minY + side * AndroidRobotMark.baseline,
            )
            let radius = side * AndroidRobotMark.radius

            var path = Path()
            for direction in [CGFloat(-1), 1] {
                // Straight up is 270° in a y-down space; the antennae splay either side of it.
                let angle = (270 + direction * AndroidRobotMark.antennaAngle) * .pi / 180
                let ray = CGPoint(x: cos(angle), y: sin(angle))
                let along = { (distance: CGFloat) in
                    CGPoint(x: centre.x + ray.x * distance, y: centre.y + ray.y * distance)
                }
                // From the rim outward, so the shaft is entirely outside the dome it grows from.
                path.move(to: along(radius))
                path.addLine(to: along(radius * AndroidRobotMark.antennaReach))
            }
            return path.strokedPath(StrokeStyle(
                lineWidth: side * AndroidRobotMark.antennaWidth, lineCap: .round,
            ))
        }
    }
}
