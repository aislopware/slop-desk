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

import SwiftUI

/// Android's robot head at `side` points square, in the current foreground style.
struct AndroidRobotMark: View {
    /// The mark's box. A tab plate passes the same measure it gives an SF Symbol, so the two tabs'
    /// marks are the same optical size.
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
    // the antennae reach up, which puts the drawn mass — antenna tips at 0.27, flat base at 0.76 —
    // centred on the box rather than the dome alone being centred and the whole thing riding high.
    private static let baseline: CGFloat = 0.76
    private static let radius: CGFloat = 0.40
    /// Measured from straight up, in degrees. Android's own mark splays them near 40°.
    private static let antennaAngle: CGFloat = 38
    private static let antennaReach: CGFloat = 1.55
    private static let antennaWidth: CGFloat = 0.075
    private static let eyeRadius: CGFloat = 0.05
    private static let eyeOffset = CGPoint(x: 0.16, y: 0.16)

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
