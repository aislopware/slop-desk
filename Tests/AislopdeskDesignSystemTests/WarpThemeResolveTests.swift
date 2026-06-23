// WarpThemeResolveTests — pin the Dark theme's seeds + resolved derived values to the spec
// (warp-tokens-color.md §2/§3). Exact ColorU equality so a derivation refactor can't silently drift.

import Testing
@testable import AislopdeskDesignSystem

struct WarpThemeResolveTests {
    let c = WarpTheme.dark.colors

    // MARK: Seeds (warp-tokens-color.md §2a)

    @Test
    func seeds() {
        #expect(c.background == ColorU(u32: 0x0000_00FF)) // #000000
        #expect(c.foreground == ColorU(u32: 0xFFFF_FFFF)) // #FFFFFF
        #expect(c.accent == ColorU(u32: 0x19AA_D8FF)) // #19AAD8 teal
        #expect(c.cursor == c.accent) // cursor nil → accent fallback
        #expect(WarpTheme.dark.name == "Dark")
    }

    // MARK: Neutral surfaces — bg.blend(fg @ N%) (warp-tokens-color.md §3b)

    @Test
    func `neutral surfaces`() {
        #expect(c.surface1 == ColorU(r: 0x0D, g: 0x0D, b: 0x0D, a: 255)) // fg@5%  ≈ #0D0D0D
        #expect(c.surface2 == ColorU(r: 0x1A, g: 0x1A, b: 0x1A, a: 255)) // fg@10% = #1A1A1A
        #expect(c.surface3 == ColorU(r: 0x26, g: 0x26, b: 0x26, a: 255)) // fg@15% = #262626
        #expect(c.neutral4 == ColorU(r: 0x33, g: 0x33, b: 0x33, a: 255)) // fg@20% = #333333
        #expect(c.neutral5 == ColorU(r: 0x66, g: 0x66, b: 0x66, a: 255)) // fg@40% = #666666
        #expect(c.neutral6 == ColorU(r: 0x99, g: 0x99, b: 0x99, a: 255)) // fg@60% = #999999
        #expect(c.neutral7 == ColorU(r: 0xE6, g: 0xE6, b: 0xE6, a: 255)) // fg@90% = #E6E6E6
    }

    @Test
    func `neutral aliases`() {
        #expect(c.subshellBackground == c.neutral4)
        #expect(c.blockBannerBackground == c.surface3)
        #expect(c.tooltipBackground == c.neutral6)
    }

    // MARK: Foreground overlays — translucent fg (warp-tokens-color.md §3c)

    @Test
    func `fg overlays`() {
        // fg@N% → white with alpha = 255*N/100.
        #expect(c.fgOverlay1 == ColorU(r: 255, g: 255, b: 255, a: 12)) // 5%  → a=12
        #expect(c.fgOverlay2 == ColorU(r: 255, g: 255, b: 255, a: 25)) // 10% → a=25
        #expect(c.fgOverlay3 == ColorU(r: 255, g: 255, b: 255, a: 38)) // 15% → a=38
    }

    @Test
    func `outline and split border`() {
        #expect(c.outline == c.fgOverlay2) // outline() = fg_overlay_2 (fg@10%)
        #expect(c.splitPaneBorder == c.fgOverlay3) // split = fg_overlay_3 (fg@15%)
        #expect(c.inactivePaneOverlay == c.fgOverlay2)
    }

    // MARK: Accent overlays (warp-tokens-color.md §3d)

    @Test
    func `accent overlays`() {
        // accent #19AAD8 with alpha = 255*N/100.
        #expect(c.accentOverlay1 == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 25)) // 10% → a=25
        #expect(c.accentOverlay2 == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 63)) // 25% → a=63 (selection)
        #expect(c.accentOverlay3 == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 102)) // 40% → a=102 (pressed)
        #expect(c.accentOverlay4 == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 153)) // 60% → a=153 (hover)
    }

    // MARK: Fixed status literals (warp-tokens-color.md §3a)

    @Test
    func `fixed status literals`() {
        #expect(c.uiWarning == ColorU(u32: 0xC280_00FF)) // #C28000
        #expect(c.uiError == ColorU(u32: 0xBC36_2AFF)) // #BC362A
        #expect(c.uiYellow == ColorU(u32: 0xE5A0_1AFF)) // #E5A01A
        #expect(c.uiGreen == ColorU(u32: 0x1CA0_5AFF)) // #1CA05A
        #expect(c.success == ColorU(u32: 0x008E_41FF)) // #008E41
    }

    @Test
    func `selection and agent accents`() {
        // text_selection = #76A7FA @ 40% = rgba(118,167,250,102).
        #expect(c.textSelection == ColorU(r: 118, g: 167, b: 250, a: 102))
        // Agent accents are SEPARATE from the (teal) terminal accent.
        #expect(AgentAccent.claudeOrange == ColorU(u32: 0xE870_4EFF)) // #E8704E
        #expect(AgentAccent.footerBrand == ColorU(u32: 0xD977_57FF)) // #D97757
        #expect(c.accent != AgentAccent.claudeOrange) // teal ≠ orange
    }

    // MARK: Terminal ANSI palette spot-checks (warp-tokens-color.md §2b)

    @Test
    func `ansi palette`() {
        #expect(c.seeds.terminal.normal.magenta == ColorU(u32: 0xFF8F_FDFF)) // #FF8FFD (prompt pwd)
        #expect(c.seeds.terminal.normal.green == ColorU(u32: 0xB4FA_72FF)) // #B4FA72 (git)
        #expect(c.seeds.terminal.bright.white == ColorU(u32: 0xFEFF_FFFF)) // #FEFFFF
        #expect(c.seeds.terminal.normal.black == ColorU(u32: 0x6161_61FF)) // #616161
    }
}
