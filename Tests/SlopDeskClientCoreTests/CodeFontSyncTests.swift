import SlopDeskProtocol
import SlopDeskVideoProtocol
import XCTest
@testable import SlopDeskClientCore

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

    /// The real metrics walk. No platform gate: it is CoreText on BOTH halves now, and Menlo ships
    /// with macOS AND iOS — the probe used to answer `nil` off AppKit, which pinned the phone's code
    /// panel at the embedded 1.32 forever no matter which face the terminal was actually rendering.
    func testInstalledFontRatioResolvesARealFaceAndRefusesAFakeOne() throws {
        let menlo = try XCTUnwrap(CodeFontSync.installedFontRatio(family: "Menlo", size: 13))
        XCTAssertGreaterThan(menlo, 1.0)
        XCTAssertLessThan(menlo, 2.0)
        XCTAssertNil(CodeFontSync.installedFontRatio(family: "No Such Face 9000", size: 13))
        XCTAssertNil(CodeFontSync.installedFontRatio(family: "Menlo", size: 0))
    }

    /// The ratio is the FACE's, not the size's: metrics scale linearly with the em, so the same
    /// family answers the same ratio at every size. A probe that leaked the point size into the
    /// answer would make the editor's line height drift every time the user zoomed the terminal.
    func testInstalledFontRatioIsSizeInvariant() throws {
        let small = try XCTUnwrap(CodeFontSync.installedFontRatio(family: "Menlo", size: 9))
        let large = try XCTUnwrap(CodeFontSync.installedFontRatio(family: "Menlo", size: 36))
        XCTAssertEqual(small, large, accuracy: 0.01)
    }

    /// A name CoreText cannot resolve must come back `nil` rather than as the SUBSTITUTE face's
    /// metrics — `CTFontCreateWithName` never fails, it hands back a system fallback, and shipping
    /// that ratio would be a silently wrong line height instead of the honest embedded fallback.
    func testAnUnresolvableNameIsNotTheSubstituteFacesRatio() {
        let substitute = CodeFontSync.installedFontRatio(family: "Definitely Not A Font 9001", size: 13)
        XCTAssertNil(substitute)
        // ...and the spec then carries the embedded face's ratio, which is what libghostty-vt renders.
        let spec = CodeFontSync.spec(terminal: prefs(family: "Definitely Not A Font 9001"))
        XCTAssertEqual(spec.lineHeight, CodeFontSync.embeddedMonoRatio)
    }

    /// The PostScript spelling resolves too — a config file usually carries "Menlo-Regular" where the
    /// picker offers the family "Menlo", and both are things a user can end up with in the field.
    func testThePostScriptSpellingResolvesAsWellAsTheFamily() throws {
        let byFamily = try XCTUnwrap(CodeFontSync.installedFontRatio(family: "Menlo", size: 13))
        let byPostScript = try XCTUnwrap(CodeFontSync.installedFontRatio(family: "Menlo-Regular", size: 13))
        XCTAssertEqual(byFamily, byPostScript, accuracy: 0.0001)
    }

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
