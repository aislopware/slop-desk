// Contrast text-tier pick + token-scale value pins.

import CoreGraphics
import Testing
@testable import AislopdeskDesignSystem

struct ContrastTests {
    @Test
    func `luminance endpoints`() {
        #expect(ColorU(u32: 0x0000_00FF).relativeLuminance == 0.0)
        #expect(ColorU(u32: 0xFFFF_FFFF).relativeLuminance == 1.0)
    }

    @Test
    func `contrast ratio black white is max`() {
        // WCAG black/white contrast = 21:1.
        let ratio = ColorU(u32: 0xFFFF_FFFF).contrastRatio(against: ColorU(u32: 0x0000_00FF))
        #expect(abs(ratio - 21.0) < 0.01)
    }

    @Test
    func `pick best foreground on dark picks white`() {
        let white = ColorU(u32: 0xFFFF_FFFF)
        let black = ColorU(u32: 0x0000_00FF)
        let pick = Contrast.pickBestForeground(on: black, candidates: [white, black])
        #expect(pick == white)
    }

    @Test
    func `pick best foreground on light picks black`() {
        let white = ColorU(u32: 0xFFFF_FFFF)
        let black = ColorU(u32: 0x0000_00FF)
        let pick = Contrast.pickBestForeground(on: white, candidates: [white, black])
        #expect(pick == black)
    }

    @Test
    func `dark theme text tiers are white at details opacity`() {
        let c = WarpTheme.dark.colors
        let bg = c.background
        // font_color(bg) on #000 → white; tiers layer Darker opacities (main 90 / sub 60 / hint 40).
        #expect(c.textMain(on: bg) == ColorU(r: 255, g: 255, b: 255, a: 229)) // 90% → a=229
        #expect(c.textSub(on: bg) == ColorU(r: 255, g: 255, b: 255, a: 153)) // 60% → a=153
        #expect(c.textHint(on: bg) == ColorU(r: 255, g: 255, b: 255, a: 102)) // 40% → a=102
    }
}

struct TokenScaleTests {
    @Test
    func radii() {
        #expect(WarpRadius.control == 4) // builder.rs:96
        #expect(WarpRadius.dialog == 8) // dialog.rs:18
        #expect(WarpRadius.pill == 3) // keyboard_shortcut.rs:187
        #expect(WarpRadius.checkbox == 2) // builder.rs:674
    }

    @Test
    func borders() {
        #expect(WarpBorder.width == 1)
        #expect(WarpBorder.radioWidth == 1.5)
    }

    @Test
    func `control sizes`() {
        #expect(WarpSize.controlHeight == 32) // button/params.rs:128
        #expect(WarpSize.controlHeightSmall == 24) // button/params.rs:145
        #expect(WarpSize.iconButton == 24) // icons.rs:6
        #expect(WarpSize.iconGlyph == 16) // 24 - 2*4
        #expect(WarpSize.switchThumb == 18)
        #expect(WarpSize.radioDiameter == 20)
    }

    @Test
    func `chrome sizes`() {
        #expect(WarpSize.titleBarHeight == 34) // view.rs:544
        #expect(WarpSize.titleBarTotalHeight == 35) // 34 + 1 border
        #expect(WarpSize.trafficLightWidth == 64)
        #expect(WarpSize.trafficLightInset == 80) // 64 + 16
        #expect(WarpSize.omnibarMaxWidth == 320) // view.rs:20147
        #expect(WarpSize.railWidth == 248) // vertical_tabs.rs:87
        #expect(WarpSize.railMinWidth == 200)
    }

    @Test
    func typography() {
        #expect(WarpType.uiSize == 12)
        #expect(WarpType.paletteSize == 14)
        #expect(WarpType.headerSize == 18)
        #expect(WarpType.overlineSize == 10)
        #expect(WarpType.monospaceSize == 13)
        #expect(WarpType.uiLineHeight == 1.2)
        #expect(WarpType.docLineHeight == 1.4)
        #expect(WarpType.monospaceFamily == "Hack")
        #expect(WarpType.uiFamily == "Roboto")
    }

    @Test
    func shadow() {
        #expect(WarpShadow.offset == CGSize(width: 0, height: 10))
        #expect(WarpShadow.blur == 10)
        #expect(WarpShadow.spread == 30)
        #expect(WarpShadow.color == ColorU(r: 0, g: 0, b: 0, a: 32))
        #expect(WarpShadow.scrim == ColorU(r: 0, g: 0, b: 0, a: 230))
    }

    @Test
    func `details profile`() {
        // DARKER == LIGHTER in this build; Dark uses Darker.
        #expect(CustomDetails.darker == CustomDetails.lighter)
        #expect(CustomDetails.darker.mainTextOpacity == 90)
        #expect(CustomDetails.darker.subTextOpacity == 60)
        #expect(CustomDetails.darker.hintTextOpacity == 40)
        #expect(CustomDetails.darker.disabledTextOpacity == 20)
    }
}
