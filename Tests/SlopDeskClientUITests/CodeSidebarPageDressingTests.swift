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
        // The shrunk plate is made by RE-SCOPING the workbench's own tab-height var on the tab
        // (captured into an intermediate on the title, since a self-referential calc is a cyclic
        // custom-property reference) — every stock rule keyed on the var derives the plate height
        // by itself. There must be NO per-rule `- 8px` recuts left: each one was a stock metric
        // chased by hand (the label's line-height, the two tab-icon forms' heights), and any
        // still-present copy means the derivation isn't trusted end to end.
        XCTAssertTrue(css.contains("--slate-tab-plate: calc(var(--editor-group-tab-height) - 8px)"))
        XCTAssertTrue(css.contains("--editor-group-tab-height: var(--slate-tab-plate)"))
        XCTAssertEqual(css.components(separatedBy: "- 8px)").count, 3, "one capture + one comment mention")
        XCTAssertFalse(css.contains(".tab .tab-label"))
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

    // MARK: Focus truth

    func testFocusTruthScriptReplaysTheMissedBlurOnlyWhileTheEngineSaysUnfocused() {
        let script = CodeSidebarPageDressing.focusTruthScript()
        // The engine's own verdict gates every replay — a genuinely focused page is left alone.
        XCTAssertTrue(script.contains("if (document.hasFocus()) { return; }"))
        // Synthetic blur EVENTS on both the active element and the window (the two places the
        // workbench tracks focus).
        XCTAssertTrue(script.contains("el.dispatchEvent(new FocusEvent(\"blur\"))"))
        XCTAssertTrue(script.contains("window.dispatchEvent(new FocusEvent(\"blur\"))"))
        // NEVER `.blur()` — that would clear `document.activeElement`, and WebKit's re-fired
        // `focus` on the preserved element is what brings the caret back on a real hand-off.
        XCTAssertFalse(script.contains(".blur()"))
        // Re-injection guard.
        XCTAssertTrue(script.contains("__slopdeskFocusTruth"))
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

    // MARK: Recommendation tips

    func testRecommendationTipsCatalogueParsesWithExactlyTheConsumedKeys() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(CodeSidebarRecommendationTips.json.utf8),
        )
        let catalogue = try XCTUnwrap(object as? [String: Any])
        // The four keys this workbench consumes — nothing gated off or desktop-only rides along
        // (`webExtensionTips` needs no-remote-server, `exeBasedExtensionTips` scans local
        // executables; see the catalogue's header).
        XCTAssertEqual(
            catalogue.keys.sorted(),
            [
                "configBasedExtensionTips",
                "extensionRecommendations",
                "keymapExtensionTips",
                "languageExtensionTips",
            ],
        )
        // The ungated RECOMMENDED filler must be a real list.
        let languageTips = try XCTUnwrap(catalogue["languageExtensionTips"] as? [String])
        XCTAssertGreaterThan(languageTips.count, 5)
        XCTAssertTrue(languageTips.contains("ms-python.python"))
        XCTAssertFalse((catalogue["extensionRecommendations"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertFalse((catalogue["configBasedExtensionTips"] as? [String: Any] ?? [:]).isEmpty)
    }

    func testRecommendationTipsCatalogueNeverRaisesInstallPrompts() {
        // `important: true` makes the workbench toast an install prompt on file open; the panel
        // recommends passively (section + badge). The canonical 2-space formatting makes the
        // textual pin exact.
        XCTAssertFalse(CodeSidebarRecommendationTips.json.contains("\"important\": true"))
    }

    func testRecommendationTipsScriptGraftsOnlyMissingKeysIntoTheBootMeta() {
        let script = CodeSidebarPageDressing.recommendationTipsScript(tipsJSON: "{\"k\": 1}")
        XCTAssertTrue(script.contains("getElementById(\"vscode-workbench-web-configuration\")"))
        XCTAssertTrue(script.contains("JSON.parse(\"{\\\"k\\\": 1}\")"))
        // Fill-only-missing: a future code-server that ships its own tips must win.
        XCTAssertTrue(script.contains("if (!(key in product))"))
        // Document-start timing: the meta does not exist yet — the observer does the rewrite.
        XCTAssertTrue(script.contains("new MutationObserver"))
        XCTAssertTrue(script.contains("observer.disconnect()"))
        XCTAssertTrue(script.contains("__slopdeskRecommendationTips"))
        XCTAssertTrue(script.contains("meta.setAttribute(\"data-settings\", JSON.stringify(settings))"))
    }

    func testRecommendationTipsScriptShipsTheBundledCatalogueByDefault() {
        XCTAssertTrue(
            CodeSidebarPageDressing.recommendationTipsScript()
                .contains("languageExtensionTips"),
        )
    }
}
