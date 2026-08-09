// SlateTerminalFaceTests — pins the peek card's FACE resolution (user-reported 2026-08-09: every
// `eza` / prompt icon in the card drew as a missing-glyph box).
//
// The bug was not the primary family — the card was right to wear the pane's own `JetBrains Mono`.
// It was the absence of a CASCADE behind it: plain JetBrains Mono carries the powerline subset but
// not the wider Nerd Font private-use area, and no system face claims those code points, so macOS's
// automatic fallback lands on `.LastResort` (the box). Measured on the machine that has the fonts:
// U+F07C and U+E702 draw as `.LastResort` without the cascade and as `Symbols Nerd Font Mono` with
// it. These tests pin the ORDER that produces that, with the installed set injected — this machine
// has no Nerd Font at all, and a test that asked the real font server would pass or fail by which
// laptop ran it.

import XCTest
@testable import SlopDeskClientUI

final class SlateTerminalFaceTests: XCTestCase {
    /// A machine with the pane's configured family AND the symbol faces.
    private let installed: Set<String> = [
        "JetBrains Mono", "JetBrainsMono Nerd Font", "Symbols Nerd Font Mono", "Symbols Nerd Font",
        "SF Mono", "Menlo",
    ]

    /// The regression: the pane's family LEADS (the card wears what the terminal wears) and the
    /// symbol faces come BEHIND it rather than replacing it.
    func testTheConfiguredFamilyLeadsAndTheSymbolFacesFollow() {
        let chain = Slate.Typeface.terminalFaceChain(
            family: "JetBrains Mono", fallbacks: "", installed: installed,
        )
        XCTAssertEqual(chain.primary, "JetBrains Mono")
        XCTAssertEqual(chain.cascade.first, "Symbols Nerd Font Mono")
        XCTAssertTrue(chain.cascade.contains("Symbols Nerd Font"))
    }

    /// The pane's OWN fallback list is the user's stated preference — it outranks the house's.
    func testThePanesDeclaredFallbacksComeFirstInTheCascade() {
        let chain = Slate.Typeface.terminalFaceChain(
            family: "JetBrains Mono", fallbacks: " Menlo , SF Mono ", installed: installed,
        )
        XCTAssertEqual(Array(chain.cascade.prefix(2)), ["Menlo", "SF Mono"])
    }

    /// A family named twice (or naming the primary again) must appear once — a cascade entry that
    /// repeats the primary is a wasted lookup per glyph.
    func testTheChainNeverRepeatsAFamily() {
        let chain = Slate.Typeface.terminalFaceChain(
            family: "JetBrains Mono",
            fallbacks: "JetBrains Mono, Symbols Nerd Font Mono, Menlo, Menlo",
            installed: installed,
        )
        XCTAssertFalse(chain.cascade.contains("JetBrains Mono"))
        XCTAssertEqual(chain.cascade, Array(NSOrderedSet(array: chain.cascade)) as? [String])
    }

    /// An UNINSTALLED family must never reach the descriptor: `Font.custom` / a family attribute
    /// that names a missing face falls over to the PROPORTIONAL system face in silence, and a
    /// preview of terminal output in a proportional face is not a preview of terminal output.
    func testAnUninstalledFamilyIsDroppedRatherThanHandedOver() {
        let chain = Slate.Typeface.terminalFaceChain(
            family: "Comic Sans Nerd Font", fallbacks: "Also Not Installed", installed: installed,
        )
        XCTAssertEqual(chain.primary, "JetBrainsMono Nerd Font") // the first installed house face
        XCTAssertFalse(chain.cascade.contains("Also Not Installed"))
    }

    /// No family at all (an unset preference) still resolves to a face, and still gets the cascade.
    func testNoConfiguredFamilyStillResolvesAndStillCascades() {
        let chain = Slate.Typeface.terminalFaceChain(family: nil, fallbacks: "", installed: installed)
        XCTAssertEqual(chain.primary, "JetBrainsMono Nerd Font")
        XCTAssertFalse(chain.cascade.isEmpty)
    }

    /// A machine with NOTHING installed: no primary, no cascade — the caller then takes the system
    /// monospace, which is the one face that is always there.
    func testABareMachineResolvesNothingRatherThanGuessing() {
        let chain = Slate.Typeface.terminalFaceChain(
            family: "JetBrains Mono", fallbacks: "Menlo", installed: [],
        )
        XCTAssertNil(chain.primary)
        XCTAssertTrue(chain.cascade.isEmpty)
    }
}
