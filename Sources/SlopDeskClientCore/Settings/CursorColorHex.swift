// CursorColorHex — the 6-hex ↔ RGB bridge the Appearance → Cursor colour wells persist through.
//
// `TerminalPreferences.cursorColor` / `.cursorTextColor` hold a libghostty `cursor-color` string: six hex
// digits, no leading `#`, empty meaning "follow the theme". `TerminalConfigBuilder` emits it verbatim. What
// a colour WELL hands back is a platform colour object, so something has to convert — and after increment
// 49 there are two wells, an `NSColorWell` on the Mac and a SwiftUI `ColorPicker` on the phone.
//
// So the conversion lives one floor under both halves, and each half keeps only its own colour type's
// channel accessor: `Color.resolve(in:)` up in `SlopDeskPhoneUI`, `NSColor.usingColorSpace(.sRGB)` up in
// `SlopDeskMacUI`. This file is what they ask.
//
// THE DECISION IS NOT HERE. The parse, the format, the clamp, the NaN rule and the rounding are
// `slopdesk_terminal::cursor_color`, which is also where `is_valid_hex` and the config-value trim already
// lived — the same crate that EMITS `cursor-color = …` now decides what may be read back into it, so a
// well cannot accept a spelling the emitter goes on to drop. What is left below is the crossing: a
// `String` in, a packed `Int32` back; three `Double`s in, six ASCII bytes back. See `docs/55`.
//
// The Rust port found two live disagreements between this file's Swift and the rule it documented — a
// leading `+` or `-` used to parse, and Foundation's `.whitespaces` includes U+200B where the config trim
// does not. Both are written up in the crate's module comment rather than restated here, because a comment
// in one language asserting a fact about the other is the artifact `docs/55` §8 calls the most dangerous
// thing in the repo. `CursorColorHexTests` still pins this file's two entry points headlessly, which is why
// it was AppKit-free to begin with.

import CSlopDeskFFI

/// The pure conversion between a 6-hex `cursor-color` string and integer / unit RGB channels.
package enum CursorColorHex {
    /// The bytes an answer from ``hex(r:g:b:)`` is: six ASCII hex digits, no `#`.
    private static let hexByteCount = 6

    /// Parse a 6-hex RGB string (no leading `#`) into 0…255 channels.
    ///
    /// `nil` for an empty string (which means "Default" — follow the theme), the wrong length, or any
    /// non-hex character; the caller then falls back to the effective default colour. Case-insensitive.
    package static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        let bytes = Array(hex.utf8)
        // The door answers `(r << 16) | (g << 8) | b`, or `-1` for a string that names no colour. The
        // sentinel cannot collide with an answer because the packing only ever writes 24 bits — that is
        // the door's own property, argued for where it is enforced, and this side only reads the sign.
        let packed = bytes.withUnsafeBufferPointer { input in
            slopdesk_cursor_color_rgb(input.baseAddress, input.count)
        }
        guard packed >= 0 else { return nil }
        return (Int((packed >> 16) & 0xFF), Int((packed >> 8) & 0xFF), Int(packed & 0xFF))
    }

    /// Format unit RGB doubles (each clamped to `0…1`, NaN → `0`) into an UPPERCASE 6-hex string with no
    /// `#` — exactly the shape `TerminalConfigBuilder` forwards as `cursor-color = …`.
    package static func hex(r: Double, g: Double, b: Double) -> String {
        // An EXACT size, not a guess: the answer is three channels of two hex digits and nothing else, so
        // the `docs/55` §4 retry below a full buffer is unreachable. `prefix` rather than a `guard` on the
        // length for the same reason — there is no failure here for a `nil` arm to mean.
        var out = [UInt8](repeating: 0, count: hexByteCount)
        let written = out.withUnsafeMutableBufferPointer { buffer in
            slopdesk_cursor_color_hex(r, g, b, buffer.baseAddress, buffer.count)
        }
        // The bytes are `0`–`9` and `A`–`F` written by a Rust `{:02X}`, so no code unit above 0x7F can
        // reach here and the failable initialiser would have a `nil` arm with no failure mode behind it.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: out.prefix(written), as: UTF8.self)
    }
}
