// VectorIcon — icon artwork carried as its own PATH DATA rather than redrawn by eye.
//
// Two of the rail's marks are not SF Symbols: otty's awaiting-input badge is lucide `hand`, and its
// caffeinate badge is a Material duotone cup, both shipped inside otty as literal `<svg>` strings.
// A previous round approximated them with the nearest system symbol and the result read as a
// different, worse icon — an approximation of a specific drawing is not the drawing. So the `d`
// strings live here VERBATIM (see ``OttyIcon``) and this file is the reader that turns them into a
// `Path`: the artwork is transcribed, never interpreted.
//
// The subset of the SVG path grammar implemented is the whole of it that matters — every command
// (`M m L l H h V v C c S s Q q T t A a Z z`) including elliptical arcs, which lucide's rounded
// finger joints are built from. Anything unrecognised is skipped rather than trapped: this parses
// COMPILED-IN artwork, never untrusted input.

#if canImport(SwiftUI)
import SwiftUI

/// A reader for SVG path data (`d`). Pure geometry — no view, no state — so a glyph's shape is
/// unit-testable by its bounding box and segment count without rendering anything.
package enum SVGPath {
    /// The path `data` describes, in the icon's own viewBox coordinates (y DOWN, matching SwiftUI).
    static func path(_ data: String) -> Path {
        var path = Path()
        var scanner = PathScanner(data)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // The reflected control points `S`/`T` need. Each is cleared by any command that is not its
        // own kind, which is exactly what the spec asks for: a smooth curve after a non-curve
        // reflects the current point onto itself (i.e. no reflection at all).
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        // The command still in force. SVG lets coordinates repeat without repeating the letter —
        // and a repeated `M` means `L` (a moveto's implicit continuation is a line, not a jump).
        var repeated: UInt8?

        while true {
            let command: UInt8
            if let letter = scanner.command() {
                command = letter
                repeated =
                    switch letter {
                    case Ascii.moveAbsolute: Ascii.lineAbsolute
                    case Ascii.moveRelative: Ascii.lineRelative
                    default: letter
                    }
            } else if scanner.hasNumber(), let pending = repeated {
                command = pending
            } else {
                break
            }

            let relative = command >= 0x61 // lowercase letters are relative
            let origin = relative ? current : .zero

            switch command {
            case Ascii.moveAbsolute,
                 Ascii.moveRelative:
                current = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                path.move(to: current)
                subpathStart = current
                lastCubicControl = nil
                lastQuadControl = nil

            case Ascii.lineAbsolute,
                 Ascii.lineRelative:
                current = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil

            case Ascii.horizontalAbsolute,
                 Ascii.horizontalRelative:
                current = CGPoint(x: origin.x + scanner.number(), y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil

            case Ascii.verticalAbsolute,
                 Ascii.verticalRelative:
                current = CGPoint(x: current.x, y: origin.y + scanner.number())
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil

            case Ascii.cubicAbsolute,
                 Ascii.cubicRelative:
                let first = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                let second = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                current = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                path.addCurve(to: current, control1: first, control2: second)
                lastCubicControl = second
                lastQuadControl = nil

            case Ascii.smoothCubicAbsolute,
                 Ascii.smoothCubicRelative:
                let first = reflect(lastCubicControl, about: current)
                let second = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                current = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                path.addCurve(to: current, control1: first, control2: second)
                lastCubicControl = second
                lastQuadControl = nil

            case Ascii.quadAbsolute,
                 Ascii.quadRelative:
                let control = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                current = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control
                lastCubicControl = nil

            case Ascii.smoothQuadAbsolute,
                 Ascii.smoothQuadRelative:
                let control = reflect(lastQuadControl, about: current)
                current = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                path.addQuadCurve(to: current, control: control)
                lastQuadControl = control
                lastCubicControl = nil

            case Ascii.arcAbsolute,
                 Ascii.arcRelative:
                let radii = CGPoint(x: scanner.number(), y: scanner.number())
                let rotation = scanner.number()
                // ⚠️ The two flags are ONE CHARACTER each, not numbers: minified data is allowed to
                // pack them straight against the coordinate that follows (`a2 2 0 014 0`), and a
                // number-shaped read would swallow the lot.
                let largeArc = scanner.flag()
                let sweep = scanner.flag()
                let end = CGPoint(x: origin.x + scanner.number(), y: origin.y + scanner.number())
                appendArc(
                    to: &path, from: current, radii: radii, rotation: rotation,
                    largeArc: largeArc, sweep: sweep, end: end,
                )
                current = end
                lastCubicControl = nil
                lastQuadControl = nil

            case Ascii.closeAbsolute,
                 Ascii.closeRelative:
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                // Unknown letter: drop it and whatever numbers trail it, rather than spinning.
                repeated = nil
                while scanner.hasNumber() { _ = scanner.number() }
            }
        }
        return path
    }

    /// `data` scaled to fill `rect`'s shorter side from a `viewBox`-square canvas, centred. Uniform
    /// so a glyph never stretches, and centred so every icon in the rail shares one optical centre.
    package static func path(_ data: String, viewBox: CGFloat, in rect: CGRect) -> Path {
        let scale = CGFloat.minimum(rect.width, rect.height) / viewBox
        let side = viewBox * scale
        let transform = CGAffineTransform(
            translationX: rect.midX - side / 2, y: rect.midY - side / 2,
        )
        .scaledBy(x: scale, y: scale)
        return path(data).applying(transform)
    }

    /// The mirror of `control` through `point` — the implicit first control point of a smooth curve.
    /// With no previous curve of that kind the reflection IS the current point, which degenerates the
    /// smooth command into an ordinary one, exactly as the spec says.
    private static func reflect(_ control: CGPoint?, about point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    // MARK: - Elliptical arcs

    /// The largest slice of an arc a single cubic approximates within a hair: at 90° the error is
    /// ~0.0003 of the radius, which on a 14pt glyph is four orders of magnitude under a pixel.
    private static let arcSegmentLimit = CGFloat.pi / 2

    /// Append one SVG elliptical arc as cubic segments (W3C SVG 1.1 §F.6.5 endpoint → centre
    /// parameterisation). `Path` has an arc primitive, but only for circles about a known centre —
    /// the endpoint form has to be converted before it can be drawn at all.
    private static func appendArc(
        to path: inout Path, from start: CGPoint, radii: CGPoint, rotation: CGFloat,
        largeArc: Bool, sweep: Bool, end: CGPoint,
    ) {
        // A degenerate radius is a straight line by definition, not an error.
        guard radii.x != 0, radii.y != 0, start != end else {
            if start != end { path.addLine(to: end) }
            return
        }
        var rx = abs(radii.x)
        var ry = abs(radii.y)
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let halfDx = (start.x - end.x) / 2
        let halfDy = (start.y - end.y) / 2
        let x1 = cosPhi * halfDx + sinPhi * halfDy
        let y1 = -sinPhi * halfDx + cosPhi * halfDy

        // Radii too small to span the chord are scaled up until they exactly do (§F.6.6).
        let oversize = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if oversize > 1 {
            let growth = sqrt(oversize)
            rx *= growth
            ry *= growth
        }

        let numerator = CGFloat.maximum(
            0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1,
        )
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (largeArc == sweep ? -1 : 1) * sqrt(numerator / denominator)
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let centre = CGPoint(
            x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
            y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2,
        )

        let startAngle = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
        let endAngle = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx)
        var sweepAngle = endAngle - startAngle
        if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

        let steps = Int(ceil(abs(sweepAngle) / arcSegmentLimit))
        guard steps > 0 else { return }
        let step = sweepAngle / CGFloat(steps)
        // The classic circular-arc bezier magic number, generalised to any sweep.
        let handle = 4.0 / 3.0 * tan(step / 4)
        var angle = startAngle
        for _ in 0..<steps {
            let next = angle + step
            let from = ellipse(centre: centre, rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, angle: angle)
            let to = ellipse(centre: centre, rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, angle: next)
            let fromSlope = slope(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, angle: angle)
            let toSlope = slope(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, angle: next)
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + handle * fromSlope.x, y: from.y + handle * fromSlope.y),
                control2: CGPoint(x: to.x - handle * toSlope.x, y: to.y - handle * toSlope.y),
            )
            angle = next
        }
    }

    /// A point on the rotated ellipse at parametric `angle`.
    private static func ellipse(
        centre: CGPoint, rx: CGFloat, ry: CGFloat, cosPhi: CGFloat, sinPhi: CGFloat, angle: CGFloat,
    ) -> CGPoint {
        let x = rx * cos(angle)
        let y = ry * sin(angle)
        return CGPoint(x: centre.x + cosPhi * x - sinPhi * y, y: centre.y + sinPhi * x + cosPhi * y)
    }

    /// The ellipse's derivative at parametric `angle` — the direction the bezier handles take.
    private static func slope(
        rx: CGFloat, ry: CGFloat, cosPhi: CGFloat, sinPhi: CGFloat, angle: CGFloat,
    ) -> CGPoint {
        let dx = -rx * sin(angle)
        let dy = ry * cos(angle)
        return CGPoint(x: cosPhi * dx - sinPhi * dy, y: sinPhi * dx + cosPhi * dy)
    }

    /// The path grammar's letters, by their ASCII byte — the scanner works in UTF-8 so the data
    /// reads in one pass without building `Character`s.
    private enum Ascii {
        static let moveAbsolute: UInt8 = 0x4D // M
        static let moveRelative: UInt8 = 0x6D // m
        static let lineAbsolute: UInt8 = 0x4C // L
        static let lineRelative: UInt8 = 0x6C // l
        static let horizontalAbsolute: UInt8 = 0x48 // H
        static let horizontalRelative: UInt8 = 0x68 // h
        static let verticalAbsolute: UInt8 = 0x56 // V
        static let verticalRelative: UInt8 = 0x76 // v
        static let cubicAbsolute: UInt8 = 0x43 // C
        static let cubicRelative: UInt8 = 0x63 // c
        static let smoothCubicAbsolute: UInt8 = 0x53 // S
        static let smoothCubicRelative: UInt8 = 0x73 // s
        static let quadAbsolute: UInt8 = 0x51 // Q
        static let quadRelative: UInt8 = 0x71 // q
        static let smoothQuadAbsolute: UInt8 = 0x54 // T
        static let smoothQuadRelative: UInt8 = 0x74 // t
        static let arcAbsolute: UInt8 = 0x41 // A
        static let arcRelative: UInt8 = 0x61 // a
        static let closeAbsolute: UInt8 = 0x5A // Z
        static let closeRelative: UInt8 = 0x7A // z
    }
}

/// A one-pass reader over path data's UTF-8. Separators (whitespace and commas) carry no meaning,
/// and a sign or a decimal point starts a number without any separator before it — which is why the
/// number scan can't be a `split`.
private struct PathScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    /// The next command letter, or `nil` when a coordinate (or the end of the data) comes next.
    mutating func command() -> UInt8? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        let byte = bytes[index]
        let isUpper = byte >= 0x41 && byte <= 0x5A
        let isLower = byte >= 0x61 && byte <= 0x7A
        guard isUpper || isLower else { return nil }
        index += 1
        return byte
    }

    /// Whether a number starts here — the test for "this command repeats".
    mutating func hasNumber() -> Bool {
        skipSeparators()
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        return byte == 0x2B || byte == 0x2D || byte == 0x2E || (byte >= 0x30 && byte <= 0x39)
    }

    /// The next number. Malformed data yields `0` rather than trapping: this reads artwork compiled
    /// into the binary, so a bad glyph must degrade to a shape, never to a crash.
    mutating func number() -> CGFloat {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
        skipDigits()
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            skipDigits()
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            let mark = index
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                skipDigits()
            } else {
                // A trailing `e` that isn't an exponent belongs to whatever comes next.
                index = mark
            }
        }
        guard index > start else {
            index += 1 // never stall on a byte we can't read
            return 0
        }
        guard let text = String(bytes: bytes[start..<index], encoding: .utf8),
              let value = Double(text)
        else { return 0 }
        return CGFloat(value)
    }

    /// One arc flag — a single `0`/`1` character, which is NOT a number scan (see the call site).
    mutating func flag() -> Bool {
        skipSeparators()
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        index += 1
        return byte == 0x31
    }

    private mutating func skipDigits() {
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
    }

    private mutating func skipSeparators() {
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x2C
            else { break }
            index += 1
        }
    }
}

/// One icon: its outlines (stroked) or its fills (with the duotone's per-layer opacity), in a square
/// viewBox. A value, so the artwork is data and the drawing is one shared view.
package struct VectorIcon: Equatable {
    /// The square the path data is authored in — 24 for both of otty's, as for lucide and Material.
    package var viewBox: CGFloat = 24
    /// Stroked outlines, in viewBox units. Empty for a filled icon.
    package var outlines: [String] = []
    /// The stroke's width IN VIEWBOX UNITS, so it scales with the glyph exactly as the source does.
    package var strokeWidth: CGFloat = 2
    /// Filled layers, painted in order. The `opacity` is the duotone's own — a Material icon says
    /// its secondary surface with `.3`, not with a second colour.
    package var fills: [Layer] = []

    package struct Layer: Equatable {
        package let data: String
        package var opacity: Double = 1
    }
}

/// The icons otty draws that are NOT SF Symbols, carried as the exact path data otty ships.
///
/// Both are rendered by otty into a 14×14 image and tinted with a semantic theme colour — the same
/// shape and the same size we mount them at, so a rail row here and a rail row there draw the same
/// artwork rather than a family resemblance.
package enum OttyIcon {
    /// The awaiting-input badge: lucide `hand` — an open palm, outlined, 2-unit stroke with round
    /// caps and joins. otty tints it with its warning colour, which is the amber our own hue budget
    /// already spends on "a question is waiting".
    package static let hand = VectorIcon(
        outlines: [
            "M18 11V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2",
            "M14 10V4a2 2 0 0 0-2-2a2 2 0 0 0-2 2v2",
            "M10 10.5V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2v8",
            "M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0"
                + " 0 1 2.83-2.82L7 15",
        ],
        strokeWidth: 2,
    )

    /// The caffeinate badge: a Material duotone cup — the mug's body at 30% behind the outline and
    /// saucer at full weight. Replaces the `∞` this slot used to spell out.
    package static let coffee = VectorIcon(
        fills: [
            VectorIcon.Layer(
                data: "M8 15h6c1.1 0 2-.9 2-2V5H6v8c0 1.1.9 2 2 2", opacity: 0.3,
            ),
            VectorIcon.Layer(
                data: "M2 19h18v2H2zm2-6c0 2.21 1.79 4 4 4h6c2.21 0 4-1.79 4-4v-3h2c1.11 0 2-.89"
                    + " 2-2V5c0-1.11-.89-2-2-2H4zm14-8h2v3h-2zM6 5h10v8c0 1.1-.9 2-2 2H8c-1.1"
                    + " 0-2-.9-2-2z",
            ),
        ],
    )
}

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
