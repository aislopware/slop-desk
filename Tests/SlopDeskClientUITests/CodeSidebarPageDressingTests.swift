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

    func testStyleSheetCarriesBothJetBrainsMonoVariableFaces() {
        let sheet = CodeSidebarPageDressing.styleSheet(
            nerdFontBase64: nil, monoUprightBase64: "QQ==", monoItalicBase64: "Qg==",
        )
        XCTAssertTrue(sheet.contains("font-family: \"JetBrains Mono\""))
        // Both faces declare the full variable weight range; only one is italic.
        XCTAssertEqual(sheet.components(separatedBy: "font-weight: 100 800;").count, 3)
        XCTAssertTrue(sheet.contains("font-style: normal;"))
        XCTAssertTrue(sheet.contains("font-style: italic;"))
        XCTAssertTrue(sheet.contains("data:font/ttf;base64,QQ=="))
        XCTAssertTrue(sheet.contains("data:font/ttf;base64,Qg=="))
    }

    func testStyleSheetWithoutFontsStillSoftensAndDressesTheLetterpress() {
        // A missing bundle resource degrades to the softening + letterpress sheet — never empty.
        let sheet = CodeSidebarPageDressing.styleSheet(nerdFontBase64: nil)
        XCTAssertFalse(sheet.contains("@font-face"))
        XCTAssertTrue(sheet.contains(".editor-group-watermark .letterpress"))
        XCTAssertTrue(sheet.contains(".tabs-container > .tab"))
    }

    func testSofteningRecutsTabsAsRoundedPlatesAndTouchesNoColours() {
        // The Slate softening is GEOMETRY only — tabs become floating rounded plates on the
        // control radius (6), lists/sliders/inputs round, and no rule ever sets a colour (the
        // theme owns every colour; a colour here would drift the moment the theme changes).
        let css = CodeSidebarPageDressing.slateSofteningCSS
        XCTAssertTrue(css.contains(".tabs-container > .tab"))
        XCTAssertTrue(css.contains("calc(var(--editor-group-tab-height) - 8px)"))
        // The label's stock line-height equals the FULL tab-height var — the shrunk plate must
        // recut it too, or the glyphs overflow the plate and the underline strikes through them.
        XCTAssertTrue(css.contains(".tab .tab-label"))
        XCTAssertEqual(css.components(separatedBy: "calc(var(--editor-group-tab-height) - 8px)").count, 3)
        // A Slate plate carries selection by background fill — the underline containers go.
        XCTAssertTrue(css.contains(".tab-border-bottom-container"))
        XCTAssertTrue(css.contains("display: none !important"))
        XCTAssertTrue(css.contains(".monaco-list-row"))
        XCTAssertTrue(css.contains(".scrollbar > .slider"))
        XCTAssertFalse(css.lowercased().contains("color"))
        XCTAssertFalse(css.contains("#"))
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

    func testFontFamilyNamesMatchTheHostSeededStack() {
        // The host seeds `editor.fontFamily: "'JetBrains Mono', ui-monospace, 'Symbols Nerd
        // Font', monospace"` (CodeServerManager.seededUserSettings — a different module, so the
        // NAMES are pinned here as strings): the @font-faces must declare the exact families that
        // stack references.
        XCTAssertEqual(CodeSidebarPageDressing.monoFontFamilyName, "JetBrains Mono")
        XCTAssertEqual(CodeSidebarPageDressing.nerdFontFamilyName, "Symbols Nerd Font")
    }

    func testBundledFontsResolveForTheInjection() throws {
        // The @font-face payloads read the bundled TTFs (the nerd symbols the terminal chrome
        // registers, and the two JetBrains Mono variable faces — the terminal's own family) — the
        // resources must resolve (a rename breaks the injection silently otherwise).
        let nerd = try Data(contentsOf: XCTUnwrap(NerdSymbolFont.bundledFontURL))
        XCTAssertGreaterThan(nerd.count, 100_000)
        let upright = try Data(contentsOf: XCTUnwrap(JetBrainsMonoFont.bundledUprightURL))
        XCTAssertGreaterThan(upright.count, 100_000)
        let italic = try Data(contentsOf: XCTUnwrap(JetBrainsMonoFont.bundledItalicURL))
        XCTAssertGreaterThan(italic.count, 100_000)
    }

    // MARK: Clipboard bridge

    func testClipboardBridgeWrapsBothWriteEntryPointsAndPostsToTheHandler() {
        let script = CodeSidebarPageDressing.clipboardBridgeScript()
        XCTAssertTrue(script.contains("window.webkit.messageHandlers.slopdeskClipboard.postMessage"))
        XCTAssertTrue(script.contains("clipboard.writeText = function"))
        XCTAssertTrue(script.contains("clipboard.write = function"))
        // Re-injection guard (SPA soft navigations must not re-wrap the wrap).
        XCTAssertTrue(script.contains("__slopdeskClipboardBridged"))
        // The original call stays best-effort — its rejection is swallowed, never surfaced (the
        // native write already succeeded; a surfaced rejection would toast a false copy error).
        XCTAssertTrue(script.contains(".catch(function () {})"))
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
