import Foundation
import SlopDeskProtocol
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientUI

/// ``CodeFontSync`` — the client-side maths that folds the LIVE terminal prefs into the verb-20
/// spec. The metrics probe is always injected here: the machine's font library must never decide
/// a test's outcome.
final class CodeFontSyncTests: XCTestCase {
    private func prefs(
        family: String = "JetBrains Mono", size: Double = 14,
        lineHeight: LineHeightMode = .default,
    ) -> TerminalPreferences {
        TerminalPreferences(fontFamily: family, fontSize: size, lineHeight: lineHeight)
    }

    func testUnresolvedFamilyFallsBackToTheEmbeddedRatio() {
        // "JetBrains Mono" resolves on neither machine — the terminal renders the EMBEDDED face
        // (ratio 1.32), so the editor must too.
        let spec = CodeFontSync.spec(terminal: prefs(), resolveRatio: { _, _ in nil })
        XCTAssertEqual(spec.family, "JetBrains Mono")
        XCTAssertEqual(spec.size, 14)
        XCTAssertEqual(spec.lineHeight, 1.32)
    }

    func testLooseModeScalesTheRatioTwentyPercent() {
        // The shipping macbook-pro prefs: JBM / 14 / loose → 1.32 × 1.2 = 1.584 → rounded 1.58.
        let spec = CodeFontSync.spec(
            terminal: prefs(lineHeight: .loose), resolveRatio: { _, _ in nil },
        )
        XCTAssertEqual(spec.lineHeight, 1.58)
    }

    func testCompactModeKeepsTheBaseRatio() {
        let spec = CodeFontSync.spec(
            terminal: prefs(lineHeight: .compact), resolveRatio: { _, _ in nil },
        )
        XCTAssertEqual(spec.lineHeight, 1.32)
    }

    func testCustomModeUsesTheMultiplierAgainstTheResolvedBase() {
        // An INSTALLED family: the injected probe answers its metrics ratio; custom 1.5 = +50%.
        let spec = CodeFontSync.spec(
            terminal: prefs(family: "Menlo", size: 12, lineHeight: .custom(1.5)),
            resolveRatio: { family, size in
                XCTAssertEqual(family, "Menlo")
                XCTAssertEqual(size, 12)
                return 1.2
            },
        )
        XCTAssertEqual(spec.family, "Menlo")
        XCTAssertEqual(spec.size, 12)
        // 1.2 × 1.5 = 1.8 exactly (plain multiply, two-decimal round is a no-op here).
        XCTAssertEqual(spec.lineHeight, 1.8)
    }

    func testRatioRoundsToTwoDecimals() {
        // Metrics division jitter (e.g. 1.31640625) must not churn the synced file per round.
        let spec = CodeFontSync.spec(
            terminal: prefs(), resolveRatio: { _, _ in 1.31640625 },
        )
        XCTAssertEqual(spec.lineHeight, 1.32)
    }

    #if canImport(AppKit)
    func testInstalledFontRatioResolvesARealFaceAndRefusesAFakeOne() throws {
        // Menlo ships with macOS — the real CoreText walk must answer a sane monospace ratio.
        let menlo = try XCTUnwrap(CodeFontSync.installedFontRatio(family: "Menlo", size: 13))
        XCTAssertGreaterThan(menlo, 1.0)
        XCTAssertLessThan(menlo, 2.0)
        XCTAssertNil(CodeFontSync.installedFontRatio(family: "No Such Face 9000", size: 13))
        XCTAssertNil(CodeFontSync.installedFontRatio(family: "Menlo", size: 0))
    }
    #endif
}
