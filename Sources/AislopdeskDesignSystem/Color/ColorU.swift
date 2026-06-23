// ColorU — an RGBA8 color value (4 × UInt8), a faithful port of Warp's `pathfinder_color::ColorU`
// (re-exported by `warpui_core::color`; warp-tokens-color.md §0). The entire derived-token system is
// built on this primitive + a small set of blend helpers (ColorBlend.swift). Headless / pure: no
// SwiftUI dependency lives here, so the math is unit-testable in isolation and a SwiftUI bridge is
// layered on top (Environment/DesignTokens).
//
// Byte order matches Warp: `from_u32(0xRRGGBBAA)` → r = >>24, g = (>>16)&0xff, b = (>>8)&0xff,
// a = low byte (warp-tokens-color.md §0, `AnsiColor::from_u32` proof at theme/mod.rs:146-152).
// YAML hex (`#RRGGBB`/`#RGB`) parses with a = OPAQUE (255); serialization drops alpha.

import Foundation

/// An RGBA color with 8 bits per channel — the design-system's color primitive.
///
/// Mirrors Warp's `ColorU` (warp-tokens-color.md §0). `Opacity` in Warp is a **percent** (0...100),
/// distinct from the alpha byte; see `withOpacity(_:)` which maps percent → alpha byte exactly as
/// Warp's `coloru_with_opacity` (`a' = a * pct / 100`).
public struct ColorU: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = Self.opaque) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// The opaque alpha byte (255). Distinct from `Opacity` percent. (warp-tokens-color.md §0, `OPAQUE`).
    public static let opaque: UInt8 = 255

    /// `from_u32(0xRRGGBBAA)` — Warp byte order (warp-tokens-color.md §0).
    public init(u32: UInt32) {
        r = UInt8((u32 >> 24) & 0xFF)
        g = UInt8((u32 >> 16) & 0xFF)
        b = UInt8((u32 >> 8) & 0xFF)
        a = UInt8(u32 & 0xFF)
    }

    /// Pack back into `0xRRGGBBAA`.
    public var u32: UInt32 {
        (UInt32(r) << 24) | (UInt32(g) << 16) | (UInt32(b) << 8) | UInt32(a)
    }

    // MARK: Hex (de)serialization — theme YAML wire format

    /// Parse `#RRGGBB` (6) or `#RGB` (3, char-doubled) → `ColorU` with `a = OPAQUE`.
    /// An optional leading `#` is accepted. Returns `nil` for any malformed input (validate-then-drop:
    /// never trap on a hostile/foreign theme string). YAML hex carries no alpha (warp-tokens-color.md §0).
    public init?(hex: String) {
        var s = Substring(hex)
        if s.first == "#" { s = s.dropFirst() }
        let chars = Array(s)
        let hexDigits: [UInt8]
        switch chars.count {
        case 3:
            // #RGB → expand by char-doubling.
            hexDigits = chars.flatMap { [$0, $0] }.compactMap(Self.nibble)
            guard hexDigits.count == 6 else { return nil }
        case 6:
            hexDigits = chars.compactMap(Self.nibble)
            guard hexDigits.count == 6 else { return nil }
        default:
            return nil
        }
        r = (hexDigits[0] << 4) | hexDigits[1]
        g = (hexDigits[2] << 4) | hexDigits[3]
        b = (hexDigits[4] << 4) | hexDigits[5]
        a = Self.opaque
    }

    private static func nibble(_ c: Character) -> UInt8? {
        guard let v = c.hexDigitValue, v >= 0, v <= 15 else { return nil }
        return UInt8(v)
    }

    /// Serialize as `#rrggbb` (lowercase, alpha dropped — matches Warp's `#{:02x}{:02x}{:02x}`).
    public var hexString: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }
}
