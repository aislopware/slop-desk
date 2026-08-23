// CodeSidebarPageDressingTests — what is left to test once the dressing itself crossed.
//
// The string builders and everything they say are `rust/slopdesk-codepanel`'s, and are pinned by
// its own tests; duplicating them here would be the cross-language mirror the repo forbids. What
// remains is this side's: that every door actually resolves against the LINKED artifact, that the
// two-call `(out, cap)` retry survives a script far larger than its first guess, and that the
// bundle resources the sheet's `slopdesk-font:` URLs promise are really there.

import SlopDeskFontFaces
import XCTest
@testable import SlopDeskClientCore

final class CodeSidebarPageDressingTests: XCTestCase {
    // MARK: The crossing

    func testEveryDoorResolvesAgainstTheLinkedArtifact() throws {
        // A door the artifact lacks answers nothing, and the face turns that into nil — which is a
        // script silently NOT installed. Empty is the failure this asserts against, not a value.
        XCTAssertEqual(CodeSidebarPageDressing.styleElementID, "slopdesk-dressing")
        XCTAssertEqual(CodeSidebarPageDressing.clipboardHandlerName, "slopdeskClipboard")
        XCTAssertTrue(CodeSidebarPageDressing.focusTruthSyncCall.hasPrefix("window.__slopdeskSyncFocusTruth &&"))
        let scripts = [
            CodeSidebarPageDressing.focusTruthScript(),
            CodeSidebarPageDressing.webviewCanvasScript(),
            CodeSidebarPageDressing.clipboardBridgeScript(),
            CodeSidebarPageDressing.recommendationTipsScript(),
        ]
        for candidate in scripts {
            let script = try XCTUnwrap(candidate)
            XCTAssertTrue(script.hasPrefix("(function ()"), "each script arrives whole, not truncated")
            XCTAssertTrue(script.hasSuffix("})();"))
        }
    }

    func testTheDressingScriptSurvivesTheBufferRetry() throws {
        // The sheet is the one answer that outgrows any sensible first guess — several KB of CSS
        // plus a base64 SVG — so it is what proves the door reports its size and the second call
        // takes the whole thing rather than a prefix.
        let script = try XCTUnwrap(CodeSidebarPageDressing.dressingScript(
            nerdFontURL: CodeSidebarFontScheme.url(for: .nerdSymbols),
            monoUprightURL: CodeSidebarFontScheme.url(for: .monoUpright),
            monoItalicURL: CodeSidebarFontScheme.url(for: .monoItalic),
        ))
        XCTAssertGreaterThan(script.count, 4096, "a truncated sheet would still look like a script")
        XCTAssertTrue(script.hasSuffix("})();"))
        XCTAssertTrue(script.contains(CodeSidebarPageDressing.styleElementID))
        for face in [CodeSidebarFontScheme.Face.nerdSymbols, .monoUpright, .monoItalic] {
            XCTAssertTrue(
                script.contains(CodeSidebarFontScheme.url(for: face)),
                "the sheet must name every face the caller lent",
            )
        }
    }

    func testAFaceTheBundleLacksIsOmittedRatherThanNamed() throws {
        let bare = try XCTUnwrap(CodeSidebarPageDressing.dressingScript(nerdFontURL: nil))
        XCTAssertFalse(
            bare.contains(CodeSidebarFontScheme.url(for: .nerdSymbols)),
            "no bundle resource, no face — never a src the scheme handler would 404",
        )
        XCTAssertTrue(bare.contains(CodeSidebarPageDressing.styleElementID), "the sheet still installs")
    }

    // MARK: The bundle the sheet promises

    func testBundledFontsResolveForTheInjection() throws {
        // The @font-face payloads read the bundled TTFs (the nerd symbols the terminal chrome
        // registers, and the two JetBrains Mono variable faces — the terminal's own family). The
        // resources must resolve: a rename breaks the injection silently otherwise.
        let nerd = try Data(contentsOf: XCTUnwrap(NerdSymbolFont.bundledFontURL))
        XCTAssertGreaterThan(nerd.count, 100_000)
        let upright = try Data(contentsOf: XCTUnwrap(JetBrainsMonoFont.bundledUprightURL))
        XCTAssertGreaterThan(upright.count, 100_000)
        let italic = try Data(contentsOf: XCTUnwrap(JetBrainsMonoFont.bundledItalicURL))
        XCTAssertGreaterThan(italic.count, 100_000)
    }
}
