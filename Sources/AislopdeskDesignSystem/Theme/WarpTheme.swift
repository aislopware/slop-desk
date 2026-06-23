// WarpTheme — the DEFAULT `Theme`, carrying Warp's built-in "Dark" seeds verbatim
// (warp-tokens-color.md §2a, ORCH-DECISIONS F1): background #000000, foreground #FFFFFF,
// terminal accent #19AAD8 (teal — NOT the Claude orange), Details=Darker, the Dark ANSI palette.
//
// This is the abstraction's default; the `Theme` protocol lets a future theme supply different seeds
// and reuse the same derivation.

import Foundation

/// Warp's default Dark theme.
public struct WarpTheme: Theme {
    public let seeds: ThemeSeeds
    public let name: String

    public init() {
        name = "Dark"
        seeds = ThemeSeeds(
            background: ColorU(u32: 0x0000_00FF), // #000000 (default_themes.rs:264)
            foreground: ColorU(u32: 0xFFFF_FFFF), // #FFFFFF (default_themes.rs:265)
            accent: ColorU(u32: 0x19AA_D8FF), // #19AAD8 teal (default_themes.rs:266)
            cursor: nil, // None → falls back to accent (default_themes.rs:267)
            details: .darker, // Darker (default_themes.rs:268)
            terminal: .warpDark, // Dark ANSI palette (§2b)
        )
    }

    /// The shared default theme instance.
    public static let dark = Self()
}
