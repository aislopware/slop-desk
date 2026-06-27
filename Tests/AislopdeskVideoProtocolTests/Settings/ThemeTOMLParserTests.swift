// ThemeTOMLParser tests (E15 WI-4) — the hand-rolled `.ottytheme` parser. Pure Foundation, headless:
// happy-path parse, `[meta]`/fallback naming, mode inference, `inherits` overlay, and the hostile cases the
// validate-then-drop discipline must reject (missing `[terminal]`, short / bad-hex palette, missing
// foreground, unbalanced garbage). No SwiftUI / AppKit / filesystem is touched.

import XCTest
@testable import AislopdeskVideoProtocol

final class ThemeTOMLParserTests: XCTestCase {
    // A canonical dark 16-entry palette, one entry per line group for legibility.
    private static let darkPaletteTOML = """
    palette = [
      "#000000", "#FF5555", "#55FF55", "#FFFF55",
      "#5555FF", "#FF55FF", "#55FFFF", "#BBBBBB",
      "#444444", "#FF8888", "#88FF88", "#FFFF88",
      "#8888FF", "#FF88FF", "#88FFFF", "#FFFFFF"
    ]
    """

    private func validDarkTheme() -> String {
        """
        [meta]
        name = "Midnight"
        mode = "dark"

        [terminal]
        foreground = "#E0E0FF"
        background = "#0A0A14"
        \(Self.darkPaletteTOML)
        cursor = "#E0E0FF"
        selection-background = "#222244"

        [token]
        accent = "#88AAFF"

        [ui]
        title-bar-bg = "#111122"
        tab-bar-bg = "#0C0C18"
        """
    }

    // MARK: happy path

    func testParsesValidThemeWithAllSections() {
        guard let doc = ThemeTOMLParser.parse(validDarkTheme()) else {
            XCTFail("expected a valid document")
            return
        }
        XCTAssertEqual(doc.displayName, "Midnight")
        XCTAssertEqual(doc.slug, "midnight")
        XCTAssertEqual(doc.mode, .dark)
        XCTAssertEqual(doc.foreground, "E0E0FF")
        XCTAssertEqual(doc.background, "0A0A14")
        XCTAssertEqual(doc.palette.count, 16)
        XCTAssertEqual(doc.palette[1], "FF5555")
        XCTAssertEqual(doc.palette[15], "FFFFFF")
        XCTAssertEqual(doc.cursor, "E0E0FF")
        XCTAssertEqual(doc.selectionBackground, "222244")
        XCTAssertEqual(doc.accent, "88AAFF")
        // [ui] legacy chrome keys map onto the dedicated regions.
        XCTAssertEqual(doc.titlebar, "111122")
        XCTAssertEqual(doc.sidebar, "0C0C18")
        XCTAssertTrue(doc.isValid)
    }

    func testSingleLinePaletteParses() {
        // A palette on ONE physical line (no continuation) — built at runtime so the source line stays short.
        let entries = (0..<16).map { "\"#0000\(String(format: "%02X", $0))\"" }.joined(separator: ",")
        let toml = """
        [terminal]
        foreground = "#FFFFFF"
        background = "#000000"
        palette = [\(entries)]
        """
        let doc = ThemeTOMLParser.parse(toml, fallbackName: "inline")
        XCTAssertEqual(doc?.palette.count, 16)
        XCTAssertEqual(doc?.displayName, "inline")
        XCTAssertEqual(doc?.slug, "inline")
    }

    func testNoneBackgroundIsAccepted() {
        let toml = """
        [terminal]
        foreground = "#FFFFFF"
        background = "none"
        \(Self.darkPaletteTOML)
        """
        let doc = ThemeTOMLParser.parse(toml, fallbackName: "ghost")
        XCTAssertEqual(doc?.background, "none")
        XCTAssertEqual(doc?.isValid, true)
    }

    // MARK: naming + mode inference

    func testMetaNameOverridesFallbackName() {
        guard let doc = ThemeTOMLParser.parse(validDarkTheme(), fallbackName: "midnight") else {
            XCTFail("expected a valid document")
            return
        }
        XCTAssertEqual(doc.displayName, "Midnight") // [meta] name wins
    }

    func testInfersDarkModeFromDarkBackgroundWhenMetaAbsent() {
        let toml = """
        [terminal]
        foreground = "#E0E0FF"
        background = "#0A0A14"
        \(Self.darkPaletteTOML)
        """
        let doc = ThemeTOMLParser.parse(toml, fallbackName: "midnight")
        XCTAssertEqual(doc?.mode, .dark)
        XCTAssertEqual(doc?.displayName, "midnight") // falls back to the file name
    }

    func testInfersLightModeFromLightBackgroundWhenMetaAbsent() {
        // Only the background luminance drives inference, so the palette content is immaterial here.
        let toml = """
        [terminal]
        foreground = "#222222"
        background = "#F5F5F5"
        \(Self.darkPaletteTOML)
        """
        let doc = ThemeTOMLParser.parse(toml, fallbackName: "paper")
        XCTAssertEqual(doc?.mode, .light)
    }

    func testExplicitMetaModeBeatsLuminanceInference() {
        // A dark background but an explicit light mode — the explicit declaration wins.
        let toml = """
        [meta]
        mode = "light"

        [terminal]
        foreground = "#E0E0FF"
        background = "#0A0A14"
        \(Self.darkPaletteTOML)
        """
        let doc = ThemeTOMLParser.parse(toml, fallbackName: "odd")
        XCTAssertEqual(doc?.mode, .light)
    }

    // MARK: comments

    func testCommentsAndTrailingCommentsAreIgnoredButHexSurvives() {
        let toml = """
        # a leading comment line
        [terminal]
        foreground = "#E0E0FF" # the text colour
        background = "#0A0A14"  # backdrop
        \(Self.darkPaletteTOML)
        """
        let doc = ThemeTOMLParser.parse(toml, fallbackName: "commented")
        XCTAssertEqual(doc?.foreground, "E0E0FF") // `#` inside the quoted hex was NOT treated as a comment
        XCTAssertEqual(doc?.background, "0A0A14")
        XCTAssertEqual(doc?.palette.count, 16)
    }

    // MARK: single-quoted (literal) strings — the Alacritty idiom

    /// TOML LITERAL strings (`'…'`) carry a `'#rrggbb'` hex with a `#` that must NOT be eaten as a comment, and
    /// a trailing `# comment` after the closing quote IS still stripped. REVERT-TO-CONFIRM-FAIL: without literal
    /// support `stripComment` truncates the value at the `#` and the document drops.
    func testSingleQuotedLiteralHexParsesAndHashIsNotAComment() {
        let toml = """
        [terminal]
        foreground = '#E0E0FF' # the text colour
        background = '#0A0A14'
        \(Self.darkPaletteTOML)
        """
        let doc = ThemeTOMLParser.parse(toml, fallbackName: "literal")
        XCTAssertEqual(doc?.foreground, "E0E0FF", "the `#` inside a single-quoted literal is a hex, not a comment")
        XCTAssertEqual(doc?.background, "0A0A14")
        XCTAssertEqual(doc?.palette.count, 16)
        XCTAssertEqual(doc?.isValid, true)
    }

    /// A single-quoted value that parses as a literal but is NOT a clean hex still DROPS the whole document
    /// (validate-then-drop survives the new literal-string path).
    func testMalformedSingleQuotedValueStillDrops() {
        let toml = """
        [terminal]
        foreground = '#ZZZZZZ'
        background = '#000000'
        \(Self.darkPaletteTOML)
        """
        XCTAssertNil(ThemeTOMLParser.parse(toml, fallbackName: "badliteral"))
    }

    // MARK: stable slug from the on-disk file name

    /// The slug tracks the FILE NAME (the `.ottytheme` basename passed as `fallbackName`), not the mutable
    /// `[meta] name` — so a persisted `customLightSlug`/`customDarkSlug` keeps resolving after a display-name
    /// change. REVERT-TO-CONFIRM-FAIL: deriving the slug from `displayName` yields `"renamed-theme"`.
    func testSlugDerivesFromFileNameNotDisplayName() {
        let toml = """
        [meta]
        name = "Renamed Theme"

        [terminal]
        foreground = "#FFFFFF"
        background = "#000000"
        \(Self.darkPaletteTOML)
        """
        let doc = ThemeTOMLParser.parse(toml, fallbackName: "my-cool-theme")
        XCTAssertEqual(doc?.displayName, "Renamed Theme")
        XCTAssertEqual(doc?.slug, "my-cool-theme", "slug tracks the file name, not the display name")
    }

    // MARK: inheritance

    private func parentDocument() -> ThemeDocument {
        ThemeDocument(
            displayName: "Base",
            slug: "base",
            mode: .dark,
            foreground: "CCCCCC",
            background: "101010",
            palette: [
                "101010", "FF6188", "A9DC76", "FFD866", "FC9867", "AB9DF2", "78DCE8", "FCFCFA",
                "727072", "FF6188", "A9DC76", "FFD866", "FC9867", "AB9DF2", "78DCE8", "FCFCFA",
            ],
            accent: "78DCE8",
        )
    }

    func testInheritsOverlaysOnlyExplicitKeys() {
        let child = """
        inherits = "Base"

        [meta]
        name = "Child"

        [terminal]
        foreground = "#123456"
        """
        let parent = parentDocument()
        let doc = ThemeTOMLParser.parse(child, fallbackName: "child") { name in
            name == "Base" ? parent : nil
        }
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.displayName, "Child")
        XCTAssertEqual(doc?.slug, "child")
        XCTAssertEqual(doc?.foreground, "123456") // explicitly overridden
        XCTAssertEqual(doc?.background, parent.background) // inherited
        XCTAssertEqual(doc?.palette, parent.palette) // inherited (not restated)
        XCTAssertEqual(doc?.accent, parent.accent) // inherited optional
    }

    func testInheritsFromMissingParentFallsBackToSelfComplete() {
        // The file does NOT specify enough on its own (no palette) and the parent can't be resolved → drop.
        let child = """
        inherits = "DoesNotExist"

        [terminal]
        foreground = "#123456"
        background = "#000000"
        """
        let doc = ThemeTOMLParser.parse(child, fallbackName: "orphan") { _ in nil }
        XCTAssertNil(doc) // incomplete + no parent → validate-then-drop
    }

    // MARK: hostile / malformed (validate-then-drop)

    func testMissingTerminalSectionIsDropped() {
        let toml = """
        [meta]
        name = "Empty"
        """
        XCTAssertNil(ThemeTOMLParser.parse(toml, fallbackName: "empty"))
    }

    func testShortPaletteIsDropped() {
        let toml = """
        [terminal]
        foreground = "#FFFFFF"
        background = "#000000"
        palette = ["#000000","#FF5555","#55FF55","#FFFF55","#5555FF","#FF55FF","#55FFFF","#BBBBBB"]
        """
        XCTAssertNil(ThemeTOMLParser.parse(toml, fallbackName: "short"))
    }

    func testBadHexInPaletteIsDropped() {
        // 16 entries, but index 1 is not a clean hex → the whole document drops.
        let toml = """
        [terminal]
        foreground = "#FFFFFF"
        background = "#000000"
        palette = [
          "#000000", "ZZZZZZ", "#55FF55", "#FFFF55",
          "#5555FF", "#FF55FF", "#55FFFF", "#BBBBBB",
          "#444444", "#FF8888", "#88FF88", "#FFFF88",
          "#8888FF", "#FF88FF", "#88FFFF", "#FFFFFF"
        ]
        """
        XCTAssertNil(ThemeTOMLParser.parse(toml, fallbackName: "badhex"))
    }

    func testMissingForegroundIsDropped() {
        let toml = """
        [terminal]
        background = "#000000"
        \(Self.darkPaletteTOML)
        """
        XCTAssertNil(ThemeTOMLParser.parse(toml, fallbackName: "nofg"))
    }

    func testBadOptionalColourDropsDocument() {
        let toml = """
        [terminal]
        foreground = "#FFFFFF"
        background = "#000000"
        \(Self.darkPaletteTOML)
        cursor = "nope"
        """
        XCTAssertNil(ThemeTOMLParser.parse(toml, fallbackName: "badcursor"))
    }

    func testGarbageDoesNotCrashAndDrops() {
        XCTAssertNil(ThemeTOMLParser.parse("", fallbackName: "empty"))
        XCTAssertNil(ThemeTOMLParser.parse("not a theme at all", fallbackName: "junk"))
        XCTAssertNil(ThemeTOMLParser.parse("[terminal]\nforeground = \"#fff", fallbackName: "unterminated"))
        XCTAssertNil(ThemeTOMLParser.parse("palette = [ [ [ unbalanced", fallbackName: "brackets"))
    }

    // MARK: luminance helper (mode inference building block)

    func testLuminanceRejectsNonHexAndOrdersDarkBelowLight() {
        XCTAssertNil(ThemeTOMLParser.luminance("#000000")) // `#`-prefixed → not a clean hex
        XCTAssertNil(ThemeTOMLParser.luminance("ZZZZZZ"))
        guard let black = ThemeTOMLParser.luminance("000000"),
              let white = ThemeTOMLParser.luminance("FFFFFF")
        else {
            XCTFail("expected luminance for clean hex")
            return
        }
        XCTAssertLessThan(black, 0.5)
        XCTAssertGreaterThan(white, 0.5)
    }
}
