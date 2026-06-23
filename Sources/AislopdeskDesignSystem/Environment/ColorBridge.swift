// ColorBridge — SwiftUI `Color` from our `ColorU` primitive. Keeps the color MATH (ColorU/blend) free
// of any SwiftUI dependency; this is the one place the two meet. sRGB, straight (non-premultiplied)
// alpha — the same space ColorU's channels live in.

import SwiftUI

public extension Color {
    /// Bridge a `ColorU` (RGBA8, sRGB straight alpha) into a SwiftUI `Color`.
    init(_ c: ColorU) {
        self.init(
            .sRGB,
            red: Double(c.r) / 255.0,
            green: Double(c.g) / 255.0,
            blue: Double(c.b) / 255.0,
            opacity: Double(c.a) / 255.0,
        )
    }
}
