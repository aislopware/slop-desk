// CodeSidebarPageDressingTests — pins the pure string builders behind the workbench's injected
// finishing coat (nerd-font @font-face + slopcat letterpress). The WKUserScript wiring itself is
// WebKit-only and deliberately unreachable here (hang-safety: no WKWebView in unit tests).

import XCTest
@testable import SlopDeskClientUI

final class CodeSidebarPageDressingTests: XCTestCase {
    // MARK: Style sheet

    func testStyleSheetCarriesFontFaceAndLetterpressOverride() {
        let sheet = CodeSidebarPageDressing.styleSheet(nerdFontBase64: "QUJD")
        XCTAssertTrue(sheet.contains("@font-face"))
        XCTAssertTrue(sheet.contains("font-family: \"Symbols Nerd Font\""))
        XCTAssertTrue(sheet.contains("data:font/ttf;base64,QUJD"))
        XCTAssertTrue(sheet.contains(".monaco-workbench .editor-group-watermark .letterpress"))
        XCTAssertTrue(sheet.contains("!important"))
    }

    func testStyleSheetWithoutFontStillDressesTheLetterpress() {
        // A missing bundle resource degrades to the letterpress-only sheet — never an empty coat.
        let sheet = CodeSidebarPageDressing.styleSheet(nerdFontBase64: nil)
        XCTAssertFalse(sheet.contains("@font-face"))
        XCTAssertTrue(sheet.contains(".editor-group-watermark .letterpress"))
    }

    func testLetterpressPayloadIsTheSlopcatWithLiteralInk() {
        // A data-URI SVG resolves `currentColor` to black — the brand file's ink must have been
        // made literal, and the stock watermark's subtlety baked on the root.
        let svg = CodeSidebarPageDressing.slopcatLetterpressSVG
        XCTAssertFalse(svg.contains("currentColor"))
        XCTAssertTrue(svg.contains("#727072"))
        XCTAssertTrue(svg.contains("opacity=\".3\""))
        XCTAssertTrue(svg.contains("slopcat-cut"))
        // And the sheet embeds exactly that payload.
        let embedded = Data(svg.utf8).base64EncodedString()
        XCTAssertTrue(
            CodeSidebarPageDressing.styleSheet(nerdFontBase64: nil).contains(embedded),
        )
    }

    // MARK: Seed agreement

    func testFontFamilyNameMatchesTheHostSeededFallbackStack() {
        // The host seeds `editor.fontFamily: "ui-monospace, Menlo, 'Symbols Nerd Font', monospace"`
        // (CodeServerManager.seededUserSettings — a different module, so the NAME is pinned here as
        // a string): the @font-face must declare the exact family that stack references.
        XCTAssertEqual(CodeSidebarPageDressing.nerdFontFamilyName, "Symbols Nerd Font")
    }

    func testBundledNerdFontResolvesForTheInjection() throws {
        // The @font-face payload reads the SAME bundled TTF the terminal chrome registers — the
        // resource must resolve (a rename breaks the injection silently otherwise).
        let url = try XCTUnwrap(NerdSymbolFont.bundledFontURL)
        let bytes = try Data(contentsOf: url)
        XCTAssertGreaterThan(bytes.count, 100_000)
    }

    // MARK: User script

    func testUserScriptGuardsOnStyleElementID() {
        let script = CodeSidebarPageDressing.userScript(styleSheet: "body {}")
        XCTAssertTrue(script.contains("getElementById(\"slopdesk-dressing\")"))
        XCTAssertTrue(script.contains("style.id = \"slopdesk-dressing\""))
        XCTAssertTrue(script.contains("appendChild(style)"))
    }

    func testUserScriptEmbedsTheSheetAsAJavaScriptLiteral() {
        let script = CodeSidebarPageDressing.userScript(styleSheet: "a { content: \"x\"; }\nb {}")
        XCTAssertTrue(script.contains(#""a { content: \"x\"; }\nb {}""#))
    }

    func testJavaScriptStringLiteralEscapesTheJSHazards() {
        // Quotes, backslashes, newlines, control chars — and the two scalars JSON permits raw but
        // pre-ES2019 JS treats as line terminators.
        XCTAssertEqual(
            CodeSidebarPageDressing.javaScriptStringLiteral("a\"b\\c\nd\re"),
            #""a\"b\\c\nd\re""#,
        )
        XCTAssertEqual(
            CodeSidebarPageDressing.javaScriptStringLiteral("x\u{2028}y\u{2029}z\u{01}"),
            #""x\u2028y\u2029z\u0001""#,
        )
        XCTAssertEqual(CodeSidebarPageDressing.javaScriptStringLiteral(""), "\"\"")
    }
}
