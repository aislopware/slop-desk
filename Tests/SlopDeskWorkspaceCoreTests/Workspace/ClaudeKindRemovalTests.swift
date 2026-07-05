import SlopDeskClient
import SlopDeskTransport
import XCTest
@testable import SlopDeskWorkspaceCore

/// W11 — the removal of the dedicated `PaneKind.claudeCode` (a Claude session is now just a `.terminal`
/// pane, auto-detected). Pins the load-bearing no-data-loss / no-trap contract:
///
///  1. `PaneKind` has exactly `{ terminal, remoteGUI, systemDialog }` — the `.claudeCode` case is gone
///     (this file would not COMPILE if anything still referenced it).
///  2. A persisted spec carrying the LEGACY `"claudeCode"` raw value decodes to `.terminal` (forward/
///     back-tolerant) — never trapping now the case is removed.
///  3. The frozen v9 → v10 migration rewrites a legacy claude pane to `.terminal` with NO data loss.
///  4. A plain `.terminal` pane does NOT stand up the read-only inspector until a `claude` is detected.
@MainActor
final class ClaudeKindRemovalTests: XCTestCase {
    // MARK: - 1. The case is gone (a closed enum without claudeCode)

    func testPaneKindHasNoClaudeCodeCase() {
        // CaseIterable would include `.claudeCode` if it still existed; the live set is exactly these.
        XCTAssertEqual(
            Set(PaneKind.allCasesForTest),
            Set([.terminal, .remoteGUI, .systemDialog]),
            "PaneKind is { terminal, remoteGUI, systemDialog } — claudeCode is retired",
        )
        // The legacy raw value is no longer a valid synthesized case.
        XCTAssertNil(PaneKind(rawValue: "claudeCode"), "the synthesized rawValue init does not know claudeCode")
    }

    // MARK: - 2. Legacy `"claudeCode"` raw value decodes to `.terminal` (no trap)

    func testLegacyClaudeCodeRawValueDecodesToTerminal() throws {
        // A persisted PaneSpec with the retired discriminator — the exact bytes an old binary wrote.
        let json = Data(#"{ "kind": "claudeCode", "title": "my agent" }"#.utf8)
        let spec = try JSONDecoder().decode(PaneSpec.self, from: json)
        XCTAssertEqual(spec.kind, .terminal, "a legacy claudeCode spec decodes to a plain terminal (no trap)")
        XCTAssertEqual(spec.title, "my agent", "the title survives the tolerant decode")
    }

    /// A genuinely unknown kind (NOT a tolerated legacy value) still throws — the loader's reset path
    /// handles that; only the intentionally-retired values are repaired.
    func testUnknownPaneKindStillThrows() {
        let json = Data(#"{ "kind": "wormhole", "title": "x" }"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PaneSpec.self, from: json), "an unknown kind is still corruption")
    }

    // MARK: - 2b. Legacy `"web"` raw value decodes to `.terminal` (the removed local web pane, no trap)

    /// The removed `PaneKind.web` (the local WKWebView browser pane, since pruned) rides the SAME decode
    /// bridge as `"claudeCode"`: an OLD persisted workspace carrying a `"web"` leaf decodes to a plain
    /// `.terminal` instead of trapping. Its now-unknown `webURL` key is simply decode-ignored (the keyed
    /// container skips keys it does not model). Revert-to-confirm-fail: without the bridge in
    /// `PaneKind.init(from:)` the decode throws and this test fails.
    func testLegacyWebRawValueDecodesToTerminal() throws {
        // The exact bytes an old binary wrote for a persisted web pane (kind + title + address).
        let json = Data(#"{ "kind": "web", "title": "Web", "webURL": "https://example.com/" }"#.utf8)
        let spec = try JSONDecoder().decode(PaneSpec.self, from: json)
        XCTAssertEqual(spec.kind, .terminal, "a legacy web spec decodes to a plain terminal (no trap)")
        XCTAssertEqual(spec.title, "Web", "the title survives the tolerant decode")
        // The raw value is no longer a valid synthesized case either.
        XCTAssertNil(PaneKind(rawValue: "web"), "the synthesized rawValue init does not know web")
    }

    // MARK: - 3. Legacy claude pane handling

    // L0 / D2: testMigrationRewritesLegacyClaudeCodePaneToTerminal was DELETED — it exercised the deleted
    // v9 migration (`WorkspaceV9` + `WorkspaceMigrationV9toV10`). The load-bearing fact it protected — that
    // a legacy `"claudeCode"` raw kind decodes to `.terminal` rather than trapping — is still pinned by the
    // direct PaneSpec decode test below (testLegacyClaudeCodeRawDecodesToTerminal).

    /// The retired `"claudeCode"` raw value still decodes to `.terminal` directly on `PaneSpec` (the
    /// forward-tolerant decode that survives a stale persisted file), independent of any schema migration.
    func testLegacyClaudeCodeRawDecodesToTerminal() throws {
        let json = Data(#"{ "kind": "claudeCode", "title": "agent" }"#.utf8)
        let spec = try JSONDecoder().decode(PaneSpec.self, from: json)
        XCTAssertEqual(spec.kind, .terminal, "the retired claudeCode kind decodes to terminal")
        XCTAssertEqual(spec.title, "agent", "title preserved")
    }

    // MARK: - 4. A plain terminal does NOT open the inspector until claude is detected

    func testPlainTerminalDoesNotOpenInspector() async {
        var madeInspector = false
        let session = LivePaneSession.make(
            PaneSpec(kind: .terminal, title: "term"),
            makeClient: {
                SlopDeskClient(makeTransport: {
                    MuxClientTransport(
                        acquire: { _, _, _, _ in throw SlopDeskTransportError.notConnected("inert") },
                        release: { _, _, _ in },
                    )
                })
            },
            makeInspector: { _ in
                madeInspector = true
                return nil
            },
        )
        XCTAssertEqual(session.claudeStatus, .none, "no claude detected on a fresh terminal")
        await session.subscribeInspector()
        XCTAssertFalse(madeInspector, "a plain terminal must NOT stand up the inspector (W11 dynamic gate)")
    }
}

// MARK: - Test-only PaneKind enumeration

extension PaneKind {
    /// The live case set, for the removal assertion. (PaneKind is not `CaseIterable` in production — this
    /// is a test-local witness; it MUST list every case, so a future case addition surfaces here.)
    static var allCasesForTest: [PaneKind] { [.terminal, .remoteGUI, .systemDialog] }
}
