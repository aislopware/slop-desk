// ThemeImporters tests (E15 WI-5) — the third-party colour-scheme converters: iTerm2 `.itermcolors`,
// Kitty `.conf`, Alacritty `[colors.*]` `.toml`, Ghostty config, plus the otty `.ottytheme` pass-through.
// Pure Foundation, headless: one fixture per format (assembled INLINE so the test is self-contained), the
// light/dark inference, format auto-detect, and the validate-then-drop malformed cases. The filesystem
// `ThemeLibrary.importFile` wiring (slug-collision, write-back) is exercised in a macOS-only block.
//
// No SwiftUI / AppKit. Every fixture is built at runtime (no checked-in colour files), and every malformed
// case asserts a `nil` drop — these would all FAIL against a tree without the importers.

import XCTest
@testable import AislopdeskVideoProtocol

final class ThemeImportersTests: XCTestCase {
    // MARK: - Inline fixtures (assembled at runtime)

    /// An iTerm2 `.itermcolors` XML plist: Ansi i → (red = i/15, 0, 0), background black, foreground white,
    /// cursor mid-grey. Quantised, palette[0] = `000000`, palette[15] = `FF0000`, cursor = `808080`.
    private func iTermComponentDict(_ red: Double, _ green: Double, _ blue: Double) -> String {
        """
        <dict>
        <key>Color Space</key><string>sRGB</string>
        <key>Red Component</key><real>\(red)</real>
        <key>Green Component</key><real>\(green)</real>
        <key>Blue Component</key><real>\(blue)</real>
        </dict>
        """
    }

    private func iTermFixture() -> Data {
        var entries = ""
        for index in 0..<16 {
            let red = Double(index) / 15.0
            entries += "<key>Ansi \(index) Color</key>\n\(iTermComponentDict(red, 0, 0))\n"
        }
        entries += "<key>Background Color</key>\n\(iTermComponentDict(0, 0, 0))\n"
        entries += "<key>Foreground Color</key>\n\(iTermComponentDict(1, 1, 1))\n"
        entries += "<key>Cursor Color</key>\n\(iTermComponentDict(0.5, 0.5, 0.5))\n"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(entries)</dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    /// A Kitty `.conf`: `colorN` = `#NN0000` (NN = 2-hex of N), plus fg/bg/cursor/selection. A comment line
    /// proves `#`-prefixed lines are ignored.
    private func kittyFixture(background: String = "#1d1f21", foreground: String = "#c5c8c6") -> String {
        var text = """
        # Kitty colour scheme
        foreground \(foreground)
        background \(background)
        cursor #ffffff
        selection_background #444444
        """
        for index in 0..<16 {
            text += "\ncolor\(index) #\(String(format: "%02X", index))0000"
        }
        return text
    }

    /// An Alacritty `.toml`: `[colors.primary]` fg/bg, `[colors.normal]` (palette 0–7), `[colors.bright]`
    /// (8–15), `[colors.cursor]`, `[colors.selection]`. `normal.black` uses the `0x` literal form on purpose
    /// (proves both `#rrggbb` and `0xrrggbb` are accepted).
    private func alacrittyFixture(background: String = "#1d1f21") -> String {
        var text = """
        [colors.primary]
        background = "\(background)"
        foreground = "#c5c8c6"

        [colors.cursor]
        text = "#1d1f21"
        cursor = "#ffffff"

        [colors.selection]
        background = "#444444"

        [colors.normal]
        black = "0x0A0B0C"

        """
        let normalRest = ["red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for (offset, name) in normalRest.enumerated() {
            text += "\(name) = \"#\(String(format: "%02X", offset + 1))0000\"\n"
        }
        text += "\n[colors.bright]\n"
        let bright = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for (offset, name) in bright.enumerated() {
            text += "\(name) = \"#\(String(format: "%02X", offset + 8))0000\"\n"
        }
        return text
    }

    /// A Ghostty config: `palette = N=#NN0000`, plus fg/bg/cursor/selection. Index 3 uses a BARE hex (no `#`)
    /// to prove `normalizeHex` accepts it.
    private func ghosttyFixture(background: String = "#1d1f21") -> String {
        var text = """
        # Ghostty theme
        foreground = #c5c8c6
        background = \(background)
        cursor-color = #ffffff
        cursor-text = #1d1f21
        selection-background = #444444
        """
        for index in 0..<16 {
            let value = index == 3 ? "0a0a0a" : "#\(String(format: "%02X", index))0000"
            text += "\npalette = \(index)=\(value)"
        }
        return text
    }

    // MARK: - iTerm2

    func testImportITerm2ConvertsComponentsToHex() {
        guard let doc = ThemeImporters.importITerm2(iTermFixture(), fallbackName: "Solar") else {
            XCTFail("expected a valid iTerm2 import")
            return
        }
        XCTAssertEqual(doc.displayName, "Solar")
        XCTAssertEqual(doc.slug, "solar")
        XCTAssertEqual(doc.foreground, "FFFFFF")
        XCTAssertEqual(doc.background, "000000")
        XCTAssertEqual(doc.palette.count, 16)
        XCTAssertEqual(doc.palette[0], "000000")
        XCTAssertEqual(doc.palette[15], "FF0000")
        XCTAssertEqual(doc.palette[8], "880000") // round(8/15 * 255) = 136 = 0x88
        XCTAssertEqual(doc.cursor, "808080") // round(0.5 * 255) = 128 = 0x80
        XCTAssertEqual(doc.mode, .dark) // black background
        XCTAssertTrue(doc.isValid)
    }

    func testImportITerm2DropsInvalidPlist() {
        XCTAssertNil(ThemeImporters.importITerm2(Data("not a plist at all".utf8), fallbackName: "x"))
    }

    func testImportITerm2DropsWhenPaletteIncomplete() {
        // A well-formed plist that only declares 8 ANSI colours → short palette → drop.
        var entries = ""
        for index in 0..<8 {
            entries += "<key>Ansi \(index) Color</key>\n\(iTermComponentDict(0, 0, 0))\n"
        }
        entries += "<key>Background Color</key>\n\(iTermComponentDict(0, 0, 0))\n"
        entries += "<key>Foreground Color</key>\n\(iTermComponentDict(1, 1, 1))\n"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
        \(entries)</dict>
        </plist>
        """
        XCTAssertNil(ThemeImporters.importITerm2(Data(xml.utf8), fallbackName: "half"))
    }

    // MARK: - Kitty

    func testImportKittyParsesColorsAndRoles() {
        guard let doc = ThemeImporters.importKitty(kittyFixture(), fallbackName: "Kit") else {
            XCTFail("expected a valid Kitty import")
            return
        }
        XCTAssertEqual(doc.foreground, "c5c8c6")
        XCTAssertEqual(doc.background, "1d1f21")
        XCTAssertEqual(doc.cursor, "ffffff")
        XCTAssertEqual(doc.selectionBackground, "444444")
        XCTAssertEqual(doc.palette.count, 16)
        XCTAssertEqual(doc.palette[0], "000000")
        XCTAssertEqual(doc.palette[1], "010000")
        XCTAssertEqual(doc.palette[15], "0F0000")
        XCTAssertEqual(doc.mode, .dark)
    }

    func testImportKittyDropsOnShortPalette() {
        let text = """
        foreground #ffffff
        background #000000
        color0 #000000
        color1 #ff0000
        """
        XCTAssertNil(ThemeImporters.importKitty(text, fallbackName: "short"))
    }

    func testImportKittyDropsOnBadHex() {
        // 16 entries but color1 is junk → that entry drops → short palette → whole document drops.
        var text = "foreground #ffffff\nbackground #000000"
        for index in 0..<16 {
            let value = index == 1 ? "#ZZZZZZ" : "#\(String(format: "%02X", index))0000"
            text += "\ncolor\(index) \(value)"
        }
        XCTAssertNil(ThemeImporters.importKitty(text, fallbackName: "badhex"))
    }

    // MARK: - Alacritty

    func testImportAlacrittyParsesSectionsAndAcceptsBothHexForms() {
        guard let doc = ThemeImporters.importAlacritty(alacrittyFixture(), fallbackName: "Ala") else {
            XCTFail("expected a valid Alacritty import")
            return
        }
        XCTAssertEqual(doc.foreground, "c5c8c6")
        XCTAssertEqual(doc.background, "1d1f21")
        XCTAssertEqual(doc.cursor, "ffffff")
        XCTAssertEqual(doc.cursorText, "1d1f21")
        XCTAssertEqual(doc.selectionBackground, "444444")
        XCTAssertEqual(doc.palette.count, 16)
        XCTAssertEqual(doc.palette[0], "0A0B0C") // `0x0A0B0C` → 0x stripped, case preserved
        XCTAssertEqual(doc.palette[1], "010000") // `#010000`
        XCTAssertEqual(doc.palette[8], "080000") // first bright entry
        XCTAssertEqual(doc.palette[15], "0F0000")
        XCTAssertEqual(doc.mode, .dark)
    }

    func testImportAlacrittyDropsWhenBrightMissing() {
        let text = """
        [colors.primary]
        background = "#1d1f21"
        foreground = "#c5c8c6"

        [colors.normal]
        black = "#000000"
        red = "#ff0000"
        green = "#00ff00"
        yellow = "#ffff00"
        blue = "#0000ff"
        magenta = "#ff00ff"
        cyan = "#00ffff"
        white = "#ffffff"
        """
        XCTAssertNil(ThemeImporters.importAlacritty(text, fallbackName: "nobright"))
    }

    /// Alacritty themes online idiomatically SINGLE-QUOTE their `'#rrggbb'` hex colours (TOML literal strings).
    /// The importer must accept them — the `#` inside a literal is a hex, not a comment. REVERT-TO-CONFIRM-FAIL:
    /// without literal-string support the colour values truncate at the `#` and the whole import drops.
    func testImportAlacrittyAcceptsSingleQuotedLiteralHex() {
        var text = """
        [colors.primary]
        background = '#1d1f21' # the backdrop
        foreground = '#c5c8c6'

        [colors.cursor]
        cursor = '#ffffff'

        [colors.selection]
        background = '#444444'

        [colors.normal]

        """
        let normal = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        for (offset, name) in normal.enumerated() {
            text += "\(name) = '#\(String(format: "%02X", offset))0000'\n"
        }
        text += "\n[colors.bright]\n"
        for (offset, name) in normal.enumerated() {
            text += "\(name) = '#\(String(format: "%02X", offset + 8))0000'\n"
        }

        guard let doc = ThemeImporters.importAlacritty(text, fallbackName: "Single") else {
            XCTFail("expected a valid single-quoted Alacritty import")
            return
        }
        XCTAssertEqual(doc.foreground, "c5c8c6")
        XCTAssertEqual(doc.background, "1d1f21", "the `#` inside the single-quoted literal was not eaten")
        XCTAssertEqual(doc.cursor, "ffffff")
        XCTAssertEqual(doc.selectionBackground, "444444")
        XCTAssertEqual(doc.palette.count, 16)
        XCTAssertEqual(doc.palette[0], "000000")
        XCTAssertEqual(doc.palette[15], "0F0000")
        XCTAssertTrue(doc.isValid)
    }

    /// Even with single-quoted literals, a malformed colour (not a clean hex) still DROPS the document —
    /// validate-then-drop survives the new literal-string path.
    func testImportAlacrittySingleQuotedMalformedDrops() {
        let text = """
        [colors.primary]
        background = '#zzzzzz'
        foreground = '#c5c8c6'

        [colors.normal]
        black = '#000000'
        """
        XCTAssertNil(ThemeImporters.importAlacritty(text, fallbackName: "bad"))
    }

    // MARK: - Ghostty

    func testImportGhosttyParsesIndexedPaletteAndBareHex() {
        guard let doc = ThemeImporters.importGhostty(ghosttyFixture(), fallbackName: "Ghost") else {
            XCTFail("expected a valid Ghostty import")
            return
        }
        XCTAssertEqual(doc.foreground, "c5c8c6")
        XCTAssertEqual(doc.background, "1d1f21")
        XCTAssertEqual(doc.cursor, "ffffff")
        XCTAssertEqual(doc.cursorText, "1d1f21")
        XCTAssertEqual(doc.selectionBackground, "444444")
        XCTAssertEqual(doc.palette.count, 16)
        XCTAssertEqual(doc.palette[0], "000000")
        XCTAssertEqual(doc.palette[3], "0a0a0a") // bare hex (no `#`) accepted
        XCTAssertEqual(doc.palette[15], "0F0000")
        XCTAssertEqual(doc.mode, .dark)
    }

    func testImportGhosttyDropsWhenForegroundMissing() {
        var text = "background = #000000"
        for index in 0..<16 {
            text += "\npalette = \(index)=#\(String(format: "%02X", index))0000"
        }
        XCTAssertNil(ThemeImporters.importGhostty(text, fallbackName: "nofg"))
    }

    // MARK: - Light/dark inference (per format)

    func testInfersLightSlotFromLightBackground() {
        let kitty = ThemeImporters.importKitty(
            kittyFixture(background: "#f5f5f5", foreground: "#222222"), fallbackName: "Paperish",
        )
        XCTAssertEqual(kitty?.mode, .light)

        let ghostty = ThemeImporters.importGhostty(ghosttyFixture(background: "#fafafa"), fallbackName: "Lite")
        XCTAssertEqual(ghostty?.mode, .light)
    }

    func testInfersDarkSlotFromDarkBackground() {
        XCTAssertEqual(ThemeImporters.importKitty(kittyFixture(), fallbackName: "Dim")?.mode, .dark)
    }

    // MARK: - Dispatch + auto-detect

    func testParseDispatchesByFormat() {
        let doc = ThemeImporters.parse(Data(kittyFixture().utf8), format: .kitty, fallbackName: "Nord")
        XCTAssertEqual(doc?.slug, "nord")
        XCTAssertEqual(doc?.palette.count, 16)
    }

    func testParseOttythemeDelegatesAndPreservesChrome() {
        let toml = """
        [meta]
        name = "Mine"

        [terminal]
        foreground = "#FFFFFF"
        background = "#000000"
        palette = [
          "#000000", "#FF5555", "#55FF55", "#FFFF55",
          "#5555FF", "#FF55FF", "#55FFFF", "#BBBBBB",
          "#444444", "#FF8888", "#88FF88", "#FFFF88",
          "#8888FF", "#FF88FF", "#88FFFF", "#FFFFFF"
        ]

        [sidebar]
        background = "#101010"
        """
        let doc = ThemeImporters.parse(Data(toml.utf8), format: .ottytheme, fallbackName: "file")
        XCTAssertEqual(doc?.displayName, "Mine")
        XCTAssertEqual(doc?.sidebar, "101010") // chrome preserved by the `.ottytheme` path
    }

    func testDetectFormatByExtension() {
        XCTAssertEqual(ThemeImporters.detectFormat(pathExtension: "itermcolors", contents: ""), .iterm2)
        XCTAssertEqual(ThemeImporters.detectFormat(pathExtension: "conf", contents: ""), .kitty)
        XCTAssertEqual(ThemeImporters.detectFormat(pathExtension: "toml", contents: ""), .alacritty)
        XCTAssertEqual(ThemeImporters.detectFormat(pathExtension: "ottytheme", contents: ""), .ottytheme)
    }

    func testDetectFormatByContentSniff() {
        XCTAssertEqual(ThemeImporters.detectFormat(pathExtension: "", contents: ghosttyFixture()), .ghostty)
        XCTAssertEqual(ThemeImporters.detectFormat(pathExtension: "", contents: alacrittyFixture()), .alacritty)
        XCTAssertEqual(ThemeImporters.detectFormat(pathExtension: "", contents: kittyFixture()), .kitty)
        let plist = "<?xml version=\"1.0\"?>\n<plist version=\"1.0\"><dict></dict></plist>"
        XCTAssertEqual(ThemeImporters.detectFormat(pathExtension: "", contents: plist), .iterm2)
        XCTAssertNil(ThemeImporters.detectFormat(pathExtension: "", contents: "this matches nothing"))
    }

    func testFormatDisplayLabels() {
        XCTAssertEqual(
            ThemeImporters.Format.allCases.map(\.displayLabel),
            ["Otty", "iTerm2", "Kitty", "Alacritty", "Ghostty"],
        )
    }

    // MARK: - ThemeLibrary.importFile (filesystem; macOS only)

    #if os(macOS)

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func writeSource(_ name: String, _ contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testImportFileWritesOttythemeAndScans() throws {
        let source = try writeSource("Nord.conf", kittyFixture())
        let result = try ThemeLibrary.importFile(at: source, format: .kitty, into: tempDir)
        XCTAssertEqual(result.slug, "nord")
        XCTAssertEqual(result.url.lastPathComponent, "nord.ottytheme")

        let scanned = ThemeLibrary.scan(directory: tempDir)
        XCTAssertEqual(scanned.map(\.slug), ["nord"])
        XCTAssertEqual(scanned.first?.palette.count, 16)
    }

    func testImportFileAutoDetectsFormat() throws {
        let source = try writeSource("Nord.conf", kittyFixture())
        let result = try ThemeLibrary.importFile(at: source, format: nil, into: tempDir)
        XCTAssertEqual(result.slug, "nord")
    }

    func testImportFileSuffixesCollidingSlug() throws {
        let source = try writeSource("Nord.conf", kittyFixture())
        let first = try ThemeLibrary.importFile(at: source, format: .kitty, into: tempDir)
        let second = try ThemeLibrary.importFile(at: source, format: .kitty, into: tempDir)
        XCTAssertEqual(first.slug, "nord")
        XCTAssertEqual(second.slug, "nord-1")
        XCTAssertEqual(Set(ThemeLibrary.scan(directory: tempDir).map(\.slug)), ["nord", "nord-1"])
    }

    func testImportFileAvoidsBuiltinSlugCollision() throws {
        let source = try writeSource("Nord.conf", kittyFixture())
        let result = try ThemeLibrary.importFile(at: source, format: .kitty, into: tempDir, builtinSlugs: ["nord"])
        XCTAssertEqual(result.slug, "nord-1") // must not shadow a shipped built-in named "nord"
    }

    func testImportFileThrowsOnMalformedSource() throws {
        let source = try writeSource("Broken.conf", "foreground #ffffff\nbackground #000000")
        XCTAssertThrowsError(try ThemeLibrary.importFile(at: source, format: .kitty, into: tempDir)) { error in
            XCTAssertEqual(error as? ThemeLibrary.ImportError, .malformed)
        }
    }

    func testImportFileThrowsOnUnreadableSource() {
        let missing = tempDir.appendingPathComponent("nope.conf", isDirectory: false)
        XCTAssertThrowsError(try ThemeLibrary.importFile(at: missing, format: .kitty, into: tempDir)) { error in
            XCTAssertEqual(error as? ThemeLibrary.ImportError, .unreadable)
        }
    }

    func testImportFileThrowsOnUnknownFormat() throws {
        let source = try writeSource("mystery.xyz", "this matches nothing")
        XCTAssertThrowsError(try ThemeLibrary.importFile(at: source, format: nil, into: tempDir)) { error in
            XCTAssertEqual(error as? ThemeLibrary.ImportError, .unknownFormat)
        }
    }
    #endif
}
