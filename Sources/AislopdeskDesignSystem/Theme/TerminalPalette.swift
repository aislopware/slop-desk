// TerminalPalette — the 16-color ANSI palette (normal + bright) carried as a theme seed
// (warp-tokens-color.md §1, §2b). Each ANSI color is opaque (`a = OPAQUE`). The UI chrome is mostly
// derived from bg/fg/accent (NOT the ANSI palette), but the palette feeds three specific places:
// prompt/status segments, semantic block coloring (yellow/red), and the `ansiFg`/`ansiBg` tints
// (warp-tokens-color.md §6).

import Foundation

/// The 8 ANSI colors of one intensity row (normal OR bright).
/// (warp-tokens-color.md §1, `AnsiColors`, `theme/mod.rs:475-518`.)
public struct AnsiColors: Hashable, Sendable {
    public var black: ColorU
    public var red: ColorU
    public var green: ColorU
    public var yellow: ColorU
    public var blue: ColorU
    public var magenta: ColorU
    public var cyan: ColorU
    public var white: ColorU

    public init(
        black: ColorU, red: ColorU, green: ColorU, yellow: ColorU,
        blue: ColorU, magenta: ColorU, cyan: ColorU, white: ColorU,
    ) {
        self.black = black
        self.red = red
        self.green = green
        self.yellow = yellow
        self.blue = blue
        self.magenta = magenta
        self.cyan = cyan
        self.white = white
    }
}

/// `TerminalColors { normal, bright }` — 16 colors total (warp-tokens-color.md §1, `theme/mod.rs:573-583`).
public struct TerminalPalette: Hashable, Sendable {
    public var normal: AnsiColors
    public var bright: AnsiColors

    public init(normal: AnsiColors, bright: AnsiColors) {
        self.normal = normal
        self.bright = bright
    }
}

public extension TerminalPalette {
    /// Warp Dark ANSI palette (warp-tokens-color.md §2b, `default_themes.rs:11-30`).
    static let warpDark = TerminalPalette(
        normal: AnsiColors(
            black: hex("#616161"),
            red: hex("#FF8272"),
            green: hex("#B4FA72"),
            yellow: hex("#FEFDC2"),
            blue: hex("#A5D5FE"),
            magenta: hex("#FF8FFD"),
            cyan: hex("#D0D1FE"),
            white: hex("#F1F1F1"),
        ),
        bright: AnsiColors(
            black: hex("#8E8E8E"),
            red: hex("#FFC4BD"),
            green: hex("#D6FCB9"),
            yellow: hex("#FEFDD5"),
            blue: hex("#C1E3FE"),
            magenta: hex("#FFB1FE"),
            cyan: hex("#E5E6FE"),
            white: hex("#FEFFFF"),
        ),
    )

    /// Internal hex helper — the literals above are all well-formed `#RRGGBB`, so the force-unwrap
    /// is total (a typo here would crash a unit test, never ship a bad value).
    private static func hex(_ s: String) -> ColorU {
        // swiftlint:disable:next force_unwrapping
        ColorU(hex: s)!
    }
}
