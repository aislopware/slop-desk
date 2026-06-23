// ColorU + blend math contract pins (warp-tokens-color.md §0/§3b). These reproduce Warp's FORMULA,
// so a refactor can't silently shift a derived byte.

import Testing
@testable import AislopdeskDesignSystem

struct ColorUTests {
    // MARK: Hex parse / format round-trips

    @Test
    func `hex parse six digit`() {
        let c = ColorU(hex: "#19AAD8")
        #expect(c == ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 255))
    }

    @Test
    func `hex parse without hash`() {
        #expect(ColorU(hex: "FF8272") == ColorU(r: 0xFF, g: 0x82, b: 0x72, a: 255))
    }

    @Test
    func `hex parse three digit expands`() {
        // #RGB → char-doubled: #abc → #aabbcc.
        #expect(ColorU(hex: "#abc") == ColorU(r: 0xAA, g: 0xBB, b: 0xCC, a: 255))
    }

    @Test
    func `hex parse rejects malformed`() {
        #expect(ColorU(hex: "#12") == nil)
        #expect(ColorU(hex: "#GGGGGG") == nil)
        #expect(ColorU(hex: "#1234567") == nil)
        #expect(ColorU(hex: "") == nil)
    }

    @Test
    func `hex format drops alpha`() {
        #expect(ColorU(r: 0x19, g: 0xAA, b: 0xD8, a: 102).hexString == "#19aad8")
    }

    @Test
    func `hex round trip`() {
        for s in ["#000000", "#ffffff", "#19aad8", "#bc362a", "#e8704e"] {
            #expect(ColorU(hex: s)?.hexString == s)
        }
    }

    @Test
    func `u 32 round trip`() {
        let c = ColorU(u32: 0x19AA_D8FF)
        #expect(c == ColorU(r: 25, g: 170, b: 216, a: 255))
        #expect(c.u32 == 0x19AA_D8FF)
    }

    // MARK: withOpacity (percent → alpha byte)

    @Test
    func `with opacity maps percent to alpha`() {
        let white = ColorU(u32: 0xFFFF_FFFF)
        #expect(white.withOpacity(10).a == 25) // 255*10/100 = 25
        #expect(white.withOpacity(40).a == 102) // 255*40/100 = 102
        #expect(white.withOpacity(100).a == 255)
        #expect(white.withOpacity(0).a == 0)
    }

    @Test
    func `with opacity clamps`() {
        let white = ColorU(u32: 0xFFFF_FFFF)
        #expect(white.withOpacity(-5).a == 0)
        #expect(white.withOpacity(150).a == 255)
    }

    // MARK: blend — straight-alpha src-over (the load-bearing formula)

    @Test
    func `blend fg ten percent over black`() {
        // The spec's canonical example: fg@10% over #000 = #1A1A1A.
        let bg = ColorU(u32: 0x0000_00FF)
        let fg10 = ColorU(u32: 0xFFFF_FFFF).withOpacity(10)
        let out = bg.blend(fg10)
        #expect(out == ColorU(r: 0x1A, g: 0x1A, b: 0x1A, a: 255))
    }

    @Test
    func `blend short circuits`() {
        let bg = ColorU(u32: 0x0000_00FF)
        let opaqueRed = ColorU(u32: 0xFF00_00FF)
        // overlay opaque → overlay.
        #expect(bg.blend(opaqueRed) == opaqueRed)
        // overlay fully transparent → bg.
        #expect(bg.blend(ColorU(r: 255, g: 0, b: 0, a: 0)) == bg)
        // bg fully transparent → overlay.
        #expect(ColorU(r: 0, g: 0, b: 0, a: 0).blend(opaqueRed) == opaqueRed)
    }

    @Test
    func `mid is per channel mean opaque`() {
        let a = ColorU(r: 0, g: 0, b: 0, a: 100)
        let b = ColorU(r: 254, g: 100, b: 50, a: 50)
        #expect(a.mid(b) == ColorU(r: 127, g: 50, b: 25, a: 255))
    }
}
