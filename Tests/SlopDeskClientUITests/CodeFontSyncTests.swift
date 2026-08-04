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

    // MARK: Push gate

    private static let spec = MetadataCodec.CodeFontSpec(family: "JetBrains Mono", size: 13, lineHeight: 1.32)

    private func endpoint(_ state: MetadataCodec.ServiceState) -> MetadataCodec.ServiceEndpoint {
        MetadataCodec.ServiceEndpoint(state: state, port: state == .ready ? 1234 : 0)
    }

    /// The seed has to land BEFORE the booting workbench reads its settings, so a `.starting`
    /// round pushes — waiting for `.ready` would be a reload late.
    func testPushRidesTheStartingAndReadyRounds() {
        for state in [MetadataCodec.ServiceState.starting, .ready] {
            XCTAssertTrue(
                CodeFontSync.shouldPush(endpoint: endpoint(state), spec: Self.spec, lastSent: nil),
                "\(state) pushes",
            )
        }
    }

    /// A host with no code-server binary never boots a workbench, and the panel keeps polling it
    /// every ~3.6 s — patching a settings file nothing will read, forever, is pure churn.
    func testUnavailableHostIsNeverPushedTo() {
        XCTAssertFalse(
            CodeFontSync.shouldPush(endpoint: endpoint(.unavailable), spec: Self.spec, lastSent: nil),
        )
    }

    func testNoEndpointHasNowhereToPush() {
        XCTAssertFalse(CodeFontSync.shouldPush(endpoint: nil, spec: Self.spec, lastSent: nil))
    }

    /// The host no-ops a write that changes nothing, but the ROUND TRIP still queues behind real
    /// metadata work — so an unchanged spec is dropped client-side.
    func testAnUnchangedSpecIsNotResent() {
        XCTAssertFalse(
            CodeFontSync.shouldPush(endpoint: endpoint(.ready), spec: Self.spec, lastSent: Self.spec),
        )
        var moved = Self.spec
        moved.size += 1
        XCTAssertTrue(
            CodeFontSync.shouldPush(endpoint: endpoint(.ready), spec: moved, lastSent: Self.spec),
            "a real font change still goes out",
        )
    }
}
