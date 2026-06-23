// Theme — the seed-and-derive model (warp-tokens-color.md §1/§3/§7b). A theme stores only a HANDFUL
// of seeds (background, foreground, accent, optional cursor, a `Details` opacity profile, and the
// 16-color ANSI palette). EVERY other token (surfaces, borders, hover/pressed, secondary/disabled
// text, overlays) is DERIVED at runtime by blending fg/accent over bg at a fixed opacity %.
//
// `ThemeSeeds` carries the seeds; the derivation lives in this one place (`ResolvedColors`) so the
// formulas — and their `blend()` rounding — are the single source of truth. `WarpTheme` is the
// default `Theme` carrying Warp's Dark seeds verbatim. A future theme = new seeds, same derivation.

import Foundation

/// The seed inputs of a theme (warp-tokens-color.md §7b). 8 seeds; everything else is derived.
public struct ThemeSeeds: Hashable, Sendable {
    public var background: ColorU
    public var foreground: ColorU
    public var accent: ColorU
    /// Optional cursor seed; `nil` falls back to `accent` (warp-tokens-color.md §1, `color.rs:131-133`).
    public var cursor: ColorU?
    public var details: Details
    public var terminal: TerminalPalette

    public init(
        background: ColorU,
        foreground: ColorU,
        accent: ColorU,
        cursor: ColorU? = nil,
        details: Details,
        terminal: TerminalPalette,
    ) {
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.cursor = cursor
        self.details = details
        self.terminal = terminal
    }
}

/// A theme = its seeds. Default-implemented derivation hangs off `seeds` via `ResolvedColors`.
public protocol Theme: Sendable {
    var seeds: ThemeSeeds { get }
    var name: String { get }
}

public extension Theme {
    /// The resolved (derived) color set — compute once, then build `DesignTokens`/SwiftUI Colors from it.
    var colors: ResolvedColors { ResolvedColors(seeds: seeds) }
}

/// All DERIVED semantic colors for a set of seeds (warp-tokens-color.md §3). Computed eagerly from the
/// seeds so a view never re-runs blends per frame. Reproduces Warp's percentages + blend order exactly.
public struct ResolvedColors: Sendable {
    public let seeds: ThemeSeeds

    public init(seeds: ThemeSeeds) {
        self.seeds = seeds
    }

    // MARK: Seeds (pass-through)

    public var background: ColorU { seeds.background }
    public var foreground: ColorU { seeds.foreground }
    public var accent: ColorU { seeds.accent }
    /// `cursor()` — seed or accent fallback (`color.rs:131-133`).
    public var cursor: ColorU { seeds.cursor ?? seeds.accent }

    // MARK: Neutral surfaces — `bg.blend(fg @ N%)` (warp-tokens-color.md §3b)

    /// `neutral_N` for N ∈ {5,10,15,20,40,60,90}% → surfaces/banner/subshell/tooltip.
    public func neutral(_ pct: Int) -> ColorU { background.blend(foreground.withOpacity(pct)) }

    public var surface1: ColorU { neutral(5) } // ≈ #0D0D0D
    public var surface2: ColorU { neutral(10) } // ≈ #1A1A1A
    public var surface3: ColorU { neutral(15) } // ≈ #262626
    public var neutral4: ColorU { neutral(20) } // ≈ #333333 (subshell bg)
    public var neutral5: ColorU { neutral(40) } // ≈ #666666 (disabled-text basis)
    public var neutral6: ColorU { neutral(60) } // ≈ #999999 (tooltip bg)
    public var neutral7: ColorU { neutral(90) } // ≈ #E6E6E6

    public var subshellBackground: ColorU { neutral4 } // `color.rs:346-348`
    public var blockBannerBackground: ColorU { surface3 } // `color.rs:350-352`
    public var tooltipBackground: ColorU { neutral6 } // `color.rs:354-358`

    // MARK: Foreground overlays — translucent fg (warp-tokens-color.md §3c)

    /// `fg_overlay_N` = `foreground @ N%` (a translucent fg color — borders/dividers/inactive overlays).
    public func fgOverlay(_ pct: Int) -> ColorU { foreground.withOpacity(pct) }

    public var fgOverlay1: ColorU { fgOverlay(5) }
    public var fgOverlay2: ColorU { fgOverlay(10) } // = outline()
    public var fgOverlay3: ColorU { fgOverlay(15) } // = split_pane_border
    public var fgOverlay4: ColorU { fgOverlay(20) }
    public var fgOverlay5: ColorU { fgOverlay(40) }
    public var fgOverlay6: ColorU { fgOverlay(60) }
    public var fgOverlay7: ColorU { fgOverlay(90) }

    /// `outline()` = `fg_overlay_2` = fg@10% — default border/divider (`color.rs:151-153`).
    public var outline: ColorU { fgOverlay2 }
    /// `split_pane_border_color()` = `fg_overlay_3` = fg@15% (`color.rs:249-251`).
    public var splitPaneBorder: ColorU { fgOverlay3 }
    /// `inactive_pane_overlay()` = fg@10% (`color.rs:342-344`).
    public var inactivePaneOverlay: ColorU { fgOverlay2 }

    // MARK: Accent overlays / surfaces (warp-tokens-color.md §3d)

    /// `accent_overlay_N` = `accent @ N%` for N ∈ {10,25,40,60}.
    public func accentOverlay(_ pct: Int) -> ColorU { accent.withOpacity(pct) }

    public var accentOverlay1: ColorU { accentOverlay(10) }
    /// `accent_overlay_2` = accent@25% — block selection / find-bar selection (`color.rs:284-286, 593-595`).
    public var accentOverlay2: ColorU { accentOverlay(25) }
    /// `accent_overlay_3` = accent@40% — primary button PRESSED (`color.rs:597-599`).
    public var accentOverlay3: ColorU { accentOverlay(40) }
    /// `accent_overlay_4` = accent@60% — primary button HOVER (`color.rs:601-603`).
    public var accentOverlay4: ColorU { accentOverlay(60) }

    /// `accent_bg` = `bg.blend(accent @ 40%)` (`color.rs:572-575`).
    public var accentBg: ColorU { background.blend(accent.withOpacity(40)) }
    /// `accent_bg_strong` = `bg.blend(accent @ 60%)` (`color.rs:567-570`).
    public var accentBgStrong: ColorU { background.blend(accent.withOpacity(60)) }
    /// `accent_fg` = `fg.blend(accent @ 40%)` (`color.rs:583-587`).
    public var accentFg: ColorU { foreground.blend(accent.withOpacity(40)) }
    /// `accent_fg_strong` = `fg.blend(accent @ 60%)` (`color.rs:577-581`).
    public var accentFgStrong: ColorU { foreground.blend(accent.withOpacity(60)) }
    /// `accent_hover` = `accent.blend(fg @ 40%)` (`color.rs:450-454`).
    public var accentHover: ColorU { accent.blend(foreground.withOpacity(40)) }
    /// `accent_pressed` = `accent.blend(bg @ 30%)` (`color.rs:459-464`).
    public var accentPressed: ColorU { accent.blend(background.withOpacity(30)) }

    // MARK: Text tiers — contrast-picked fg @ details opacity (warp-tokens-color.md §3e)

    /// `font_color(bg)` — contrast-aware ink: white vs theme-fg, whichever contrasts better.
    /// (On Dark bg #000000 this is the foreground white.)
    public func fontColor(on bg: ColorU) -> ColorU {
        Contrast.pickBestForeground(
            on: bg,
            candidates: [foreground, ColorU(u32: 0xFFFF_FFFF), ColorU(u32: 0x0000_00FF)],
        )
    }

    /// `main_text_color(bg)` = contrast-fg @ `mainTextOpacity` (90%) (`color.rs:165-167`).
    public func textMain(on bg: ColorU) -> ColorU {
        fontColor(on: bg).withOpacity(seeds.details.profile.mainTextOpacity)
    }

    /// `sub_text_color(bg)` = contrast-fg @ `subTextOpacity` (60%) (`color.rs:169-171`).
    public func textSub(on bg: ColorU) -> ColorU {
        fontColor(on: bg).withOpacity(seeds.details.profile.subTextOpacity)
    }

    /// `hint_text_color(bg)` = contrast-fg @ `hintTextOpacity` (40%) (`color.rs:173-177`).
    public func textHint(on bg: ColorU) -> ColorU {
        fontColor(on: bg).withOpacity(seeds.details.profile.hintTextOpacity)
    }

    /// `disabled_text_color(bg)` = contrast-fg @ `hintTextOpacity` (40%) (`color.rs:179-181`;
    /// note Warp's disabled tier uses the 40% hint opacity, matching the resolved-table 40%).
    public func textDisabled(on bg: ColorU) -> ColorU {
        fontColor(on: bg).withOpacity(seeds.details.profile.hintTextOpacity)
    }

    /// `semantic_text_disabled` = `bg.blend(fg @ 40%)` (figma-matched) (`color.rs:483-488`).
    public var semanticTextDisabled: ColorU { background.blend(foreground.withOpacity(40)) }

    /// Convenience tiers resolved on `surface2` (the standard UI surface) — active/inactive/disabled UI text.
    public var activeUIText: ColorU { textMain(on: surface2) } // `color.rs:183-185`
    public var nonactiveUIText: ColorU { textSub(on: surface2) } // `color.rs:187-189`
    public var disabledUIText: ColorU { textDisabled(on: surface2) } // `color.rs:191-193`

    // MARK: Buttons (warp-tokens-color.md §3f)

    /// `foreground_button_color()` = `bg.blend(fg @ 30%)` (`color.rs:226-233`).
    public var foregroundButton: ColorU { background.blend(foreground.withOpacity(30)) }
    /// `accent_button_color()` = `accent.blend(fg @ 0%)` = accent (`color.rs:235-242`).
    public var accentButton: ColorU { accent.blend(foreground.withOpacity(0)) }

    // MARK: ANSI-derived tints (warp-tokens-color.md §3g)

    /// `ansi_bg(c)` = `background.blend(c @ 50%)` (`color.rs:362-424`).
    public func ansiBg(_ c: ColorU) -> ColorU { background.blend(c.withOpacity(50)) }
    /// `ansi_fg(c)` = `foreground.blend(c @ 50%)`.
    public func ansiFg(_ c: ColorU) -> ColorU { foreground.blend(c.withOpacity(50)) }
    /// `ansi_overlay_1(c)` = `c @ 10%`.
    public func ansiOverlay1(_ c: ColorU) -> ColorU { c.withOpacity(10) }
    /// `ansi_overlay_2(c)` = `c @ 50%`.
    public func ansiOverlay2(_ c: ColorU) -> ColorU { c.withOpacity(50) }

    // MARK: Fixed status literals (theme-independent; surfaced here for ergonomics — §3a)

    public var uiWarning: ColorU { UIStatus.warning }
    public var uiError: ColorU { UIStatus.error }
    public var uiYellow: ColorU { UIStatus.yellow }
    public var uiGreen: ColorU { UIStatus.green }
    public var success: ColorU { UIStatus.success }
    public var textSelection: ColorU { UIStatus.textSelection }
    public var blurBackdrop: ColorU { UIStatus.blurBackdrop }
}
