// NerdSymbolFontTests — pins the bundled Symbols Nerd Font machinery: the resource is really in the
// module bundle, registration succeeds process-wide, and the PURE run splitter classifies exactly the
// private-use runs (what `Text.nerdAware` splices into the symbols face). Headless — no view, no window.

import XCTest
@testable import SlopDeskClientUI

final class NerdSymbolFontTests: XCTestCase {
    /// The TTF ships in the module bundle (Package.swift `resources: [.copy("Resources/Fonts")]`) and
    /// registers with Core Text. REVERT-TO-CONFIRM-FAIL: drop the resource declaration (or the file)
    /// and both assertions trip — `nerdAware` would then silently degrade to plain Text forever.
    func testBundledFontRegisters() {
        XCTAssertNotNil(
            Bundle.module.url(
                forResource: "SymbolsNerdFont-Regular", withExtension: "ttf", subdirectory: "Fonts",
            ),
            "the Symbols Nerd Font TTF ships in the SlopDeskClientUI resource bundle",
        )
        XCTAssertTrue(NerdSymbolFont.registered, "the bundled face registers (or already was) with Core Text")
    }

    /// The private-use classification covers the three PUA blocks nerd fonts populate — and nothing else.
    func testPrivateUseClassification() throws {
        XCTAssertTrue(NerdSymbolFont.isPrivateUse("\u{E0A0}")) // powerline branch — BMP PUA
        XCTAssertTrue(NerdSymbolFont.isPrivateUse("\u{F8FF}")) // BMP PUA upper edge (Apple logo slot)
        let plane15 = try XCTUnwrap(Unicode.Scalar(0xF0001)) // plane 15 (material design)
        XCTAssertTrue(NerdSymbolFont.isPrivateUse(plane15))
        XCTAssertFalse(NerdSymbolFont.isPrivateUse("A"))
        XCTAssertFalse(NerdSymbolFont.isPrivateUse("✳")) // the agent asterisk is ordinary Unicode
        XCTAssertFalse(NerdSymbolFont.isPrivateUse("⠙")) // braille spinner frames are ordinary too
    }

    /// Stripping (the titlebar path) removes exactly the private-use glyphs and tidies the whitespace
    /// their removal strands; a symbol-free string passes through untouched.
    func testStrippingSymbols() {
        XCTAssertEqual(NerdSymbolFont.strippingSymbols("\u{E0A0} nerd-branch"), "nerd-branch")
        XCTAssertEqual(NerdSymbolFont.strippingSymbols("\u{E0A0}nerd-branch"), "nerd-branch")
        XCTAssertEqual(NerdSymbolFont.strippingSymbols("repo \u{E0B0} main"), "repo main")
        XCTAssertEqual(NerdSymbolFont.strippingSymbols("plain title"), "plain title")
        XCTAssertEqual(NerdSymbolFont.strippingSymbols("\u{E0A0}"), "", "a bare glyph strips to empty")
    }

    /// The splitter yields MAXIMAL alternating runs in order, and reassembles losslessly.
    func testRunSplitting() {
        let title = "\u{E0A0} main \u{E0B0}\u{E0B1} ok"
        let runs = NerdSymbolFont.runs(of: title)
        XCTAssertEqual(runs.map(\.isSymbol), [true, false, true, false])
        XCTAssertEqual(runs.map(\.text), ["\u{E0A0}", " main ", "\u{E0B0}\u{E0B1}", " ok"])
        XCTAssertEqual(runs.map(\.text).joined(), title, "splitting is lossless")

        XCTAssertEqual(NerdSymbolFont.runs(of: "plain title").count, 1, "no symbol ⇒ one ordinary run")
        XCTAssertTrue(NerdSymbolFont.runs(of: "").isEmpty, "empty in, empty out")
    }
}
