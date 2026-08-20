// CursorColorHex — the 6-hex ↔ RGB bridge the Appearance → Cursor colour wells persist through.
//
// `TerminalPreferences.cursorColor` / `.cursorTextColor` hold a libghostty `cursor-color` string: six hex
// digits, no leading `#`, empty meaning "follow the theme". `TerminalConfigBuilder` emits it verbatim. What
// a colour WELL hands back is a platform colour object, so something has to convert — and after increment
// 49 there are two wells, an `NSColorWell` on the Mac and a SwiftUI `ColorPicker` on the phone.
//
// So the conversion lives here, one floor under both halves, and each half keeps only its own colour type's
// channel accessor: `Color.resolve(in:)` up in `SlopDeskPhoneUI`, `NSColor.usingColorSpace(.sRGB)` up in
// `SlopDeskMacUI`. The parse, the format, the clamp and the NaN rule are the DECISION and are spelled once
// — a second hex parser is the kind of duplicate that keeps passing both halves' tests while rounding one
// channel differently.
//
// It moved down from what is now `SlopDeskPhoneUI/Settings/CursorPreviewView.swift` in increment 49 and is otherwise
// unchanged; `CursorColorHexTests` still pins it headlessly, which is why it was AppKit-free to begin with.

import Foundation

/// The pure conversion between a 6-hex `cursor-color` string and integer / unit RGB channels.
package enum CursorColorHex {
    /// Parse a 6-hex RGB string (no leading `#`) into 0…255 channels.
    ///
    /// `nil` for an empty string (which means "Default" — follow the theme), the wrong length, or any
    /// non-hex character; the caller then falls back to the effective default colour. Case-insensitive.
    package static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    /// Format unit RGB doubles (each clamped to `0…1`, NaN → `0`) into an UPPERCASE 6-hex string with no
    /// `#` — exactly the shape `TerminalConfigBuilder` forwards as `cursor-color = …`.
    package static func hex(r: Double, g: Double, b: Double) -> String {
        String(format: "%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    /// One unit-double channel → a `0…255` int, rounded to nearest. NaN → `0` (a safe default); ±infinity
    /// falls through to the ordered, NaN-faithful clamp (→ `1` / `0`) rather than a `min`/`max` ternary.
    private static func channel(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        let clamped = Double.minimum(1, Double.maximum(0, value))
        return Int((clamped * 255).rounded())
    }
}
