import Foundation
import SlopDeskClient
import SlopDeskTransport
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// W11 — the removal of the dedicated `PaneKind.claudeCode` (a Claude session is now just a `.terminal`
/// pane, auto-detected). Pins the load-bearing no-data-loss / no-trap contract:
///
///  1. `PaneKind` has exactly `{ terminal, desktop }` — the `.claudeCode` case is gone
///     (this file would not COMPILE if anything still referenced it).
///  2. A persisted spec carrying the LEGACY `"claudeCode"` raw value loads as `.terminal` (forward/
///     back-tolerant) — never trapping now the case is removed.
///  3. The frozen v9 → v10 migration rewrites a legacy claude pane to `.terminal` with NO data loss.
///  4. A plain `.terminal` pane does NOT stand up the read-only inspector until a `claude` is detected.
///
/// **Two files carry a persisted kind, and only one of them is read by a Swift decoder.** The
/// workspace file's kinds go through ``WorkspaceFile/decode(_:)`` into `slopdesk_workspace::persist`,
/// so §2's cases below exercise `persist::decode_pane_kind` — not `PaneKind.init(from:)`, which they
/// cannot reach at all now that ``PaneSpec`` is no longer `Codable`. `device-prefs.json` is the one
/// that still meets Foundation, through the ``SessionTemplate`` library's `TemplatePane`, and §2f is
/// its case. The two decoders fold the same five names because they read the same
/// `PaneKind::RETIRED_RAW_VALUES` — one through the crate directly, one through
/// `slopdesk_ws_pane_kind_from_raw`.
@MainActor
final class ClaudeKindRemovalTests: XCTestCase {
    // MARK: - 1. The case is gone (a closed enum without claudeCode)

    func testPaneKindHasNoClaudeCodeCase() {
        // CaseIterable would include `.claudeCode` if it still existed; the live set is exactly these.
        XCTAssertEqual(
            Set(PaneKind.allCasesForTest),
            Set([.terminal, .desktop]),
            "PaneKind is { terminal, desktop } — claudeCode is retired",
        )
        // The legacy raw value is no longer a valid synthesized case.
        XCTAssertNil(PaneKind(rawValue: "claudeCode"), "the synthesized rawValue init does not know claudeCode")
    }

    // MARK: - The file the specs live in

    /// One spec, loaded the way a launch loads it: wrapped in the workspace file its session's side
    /// table lives in, read back through ``WorkspaceFile``. It used to be a bare
    /// `JSONDecoder().decode(PaneSpec.self, …)`; `PaneSpec` is not `Codable` any more, because the
    /// file has one decoder and it is `rust/slopdesk-workspace`'s. The retired-kind bridge these
    /// tests pin is `persist::decode_pane_kind`'s, and it folds the same five raw values.
    ///
    /// The decode is its OWN statement, and must stay one: `XCTUnwrap` records a failure for an
    /// error thrown inside its autoclosure before it rethrows, so folding the two lines together
    /// makes ``testUnknownPaneKindStillThrows`` fail while its assertion passes.
    private func loadSpec(_ spec: String) throws -> PaneSpec {
        let pane = UUID()
        let paneJSON = "{\"raw\":\"\(pane.uuidString)\"}"
        let id = { "{\"raw\":\"\(UUID().uuidString)\"}" }
        let file = Data("""
        {"schemaVersion":\(TreeWorkspace.currentSchemaVersion),"sessions":[
          {"id":\(id()),"name":"Local","activeTabIndex":0,
           "tabs":[{"id":\(id()),"title":"","root":{"leaf":\(paneJSON)}}],
           "specs":[{"pane":\(paneJSON),"spec":\(spec)}]}
        ]}
        """.utf8)
        let loaded = try WorkspaceFile.decode(file)
        return try XCTUnwrap(loaded.spec(for: PaneID(raw: pane)))
    }

    // MARK: - 2. Legacy `"claudeCode"` raw value loads as `.terminal` (no trap)

    func testLegacyClaudeCodeRawValueDecodesToTerminal() throws {
        // A persisted PaneSpec with the retired discriminator — the exact bytes an old binary wrote.
        let spec = try loadSpec(#"{ "kind": "claudeCode", "title": "my agent" }"#)
        XCTAssertEqual(spec.kind, .terminal, "a legacy claudeCode spec decodes to a plain terminal (no trap)")
        XCTAssertEqual(spec.title, "my agent", "the title survives the tolerant decode")
    }

    /// A genuinely unknown kind (NOT a tolerated legacy value) still throws — the loader's reset path
    /// handles that; only the intentionally-retired values are repaired.
    func testUnknownPaneKindStillThrows() {
        XCTAssertThrowsError(
            try loadSpec(#"{ "kind": "wormhole", "title": "x" }"#), "an unknown kind is still corruption",
        ) { error in
            XCTAssertEqual(error as? WorkspaceFile.FileError, .malformed)
        }
    }

    // MARK: - 2b. Legacy `"web"` raw value decodes to `.terminal` (the removed local web pane, no trap)

    /// The removed `PaneKind.web` (the local WKWebView browser pane, since pruned) rides the SAME decode
    /// bridge as `"claudeCode"`: an OLD persisted workspace carrying a `"web"` leaf decodes to a plain
    /// `.terminal` instead of trapping. Its now-unknown `webURL` key is simply decode-ignored (the keyed
    /// container skips keys it does not model). Revert-to-confirm-fail: drop `"web"` from
    /// `PaneKind::RETIRED_RAW_VALUES` and `persist::decode_pane_kind` refuses the file, so the whole
    /// load becomes `.malformed` and this test fails.
    func testLegacyWebRawValueDecodesToTerminal() throws {
        // The exact bytes an old binary wrote for a persisted web pane (kind + title + address).
        let spec = try loadSpec(#"{ "kind": "web", "title": "Web", "webURL": "https://example.com/" }"#)
        XCTAssertEqual(spec.kind, .terminal, "a legacy web spec decodes to a plain terminal (no trap)")
        XCTAssertEqual(spec.title, "Web", "the title survives the tolerant decode")
        // The raw value is no longer a valid synthesized case either.
        XCTAssertNil(PaneKind(rawValue: "web"), "the synthesized rawValue init does not know web")
    }

    // MARK: - 2c. Legacy `"chooser"` raw value decodes to `.terminal` (the retired in-pane kind chooser)

    /// The removed `PaneKind.chooser` (the transient in-pane kind picker — retired by the Stage re-scope:
    /// every new-pane gesture mints a terminal directly) rides the SAME decode bridge as `"web"` /
    /// `"claudeCode"`: a persisted `.chooser` was always mid-gesture ephemera, and folding it to
    /// `.terminal` is exactly what picking the default kind would have done. Revert-to-confirm-fail:
    /// drop `"chooser"` from `PaneKind::RETIRED_RAW_VALUES` and the load becomes `.malformed`.
    func testLegacyChooserRawValueDecodesToTerminal() throws {
        let spec = try loadSpec(#"{ "kind": "chooser", "title": "New Pane" }"#)
        XCTAssertEqual(spec.kind, .terminal, "a legacy chooser spec decodes to a plain terminal (no trap)")
        XCTAssertNil(PaneKind(rawValue: "chooser"), "the synthesized rawValue init does not know chooser")
    }

    // MARK: - 2d. Legacy `"remoteGUI"` raw value decodes to `.terminal` (the removed remote-window pane)

    /// The removed `PaneKind.remoteGUI` (per-window streaming — retired by the dedicated-desktop-window
    /// re-scope, docs/DECISIONS.md 2026-07-22) rides the SAME decode bridge: a persisted remote-window
    /// leaf folds to a plain `.terminal` (the stream identity is deliberately dropped — no-backcompat
    /// rule), its now-unknown `video` endpoint decode-tolerated. Revert-to-confirm-fail: drop
    /// `"remoteGUI"` from `PaneKind::RETIRED_RAW_VALUES` and the load becomes `.malformed`.
    func testLegacyRemoteGUIRawValueDecodesToTerminal() throws {
        let spec = try loadSpec(
            #"{ "kind": "remoteGUI", "title": "Docs", "video": { "windowID": 42, "title": "Docs", "appName": "Safari" } }"#,
        )
        XCTAssertEqual(spec.kind, .terminal, "a legacy remote-window spec decodes to a plain terminal (no trap)")
        XCTAssertEqual(spec.title, "Docs", "the title survives the tolerant decode")
        XCTAssertNil(PaneKind(rawValue: "remoteGUI"), "the synthesized rawValue init does not know remoteGUI")
    }

    // MARK: - 2e. Legacy `"systemDialog"` raw value decodes to `.terminal` (the removed system-dialog pane)

    /// The removed `PaneKind.systemDialog` (the auto-spawned system-dialog pane — retired by the
    /// no-video-in-the-workspace re-scope, docs/DECISIONS.md 2026-07-23) rides the SAME decode bridge:
    /// a `.systemDialog` leaf was ephemeral and never persisted, so this is belt-and-braces — but a
    /// file that somehow carries one folds to a plain `.terminal` instead of trapping.
    func testLegacySystemDialogRawValueDecodesToTerminal() throws {
        let spec = try loadSpec(
            #"{ "kind": "systemDialog", "title": "sudo", "video": { "windowID": 7, "title": "sudo", "appName": "SecurityAgent" } }"#,
        )
        XCTAssertEqual(spec.kind, .terminal, "a legacy system-dialog spec decodes to a plain terminal (no trap)")
        XCTAssertNil(PaneKind(rawValue: "systemDialog"), "the synthesized rawValue init does not know systemDialog")
    }

    // MARK: - 2f. The OTHER file: a retired kind inside `device-prefs.json`'s template library

    /// `PaneKind.init(from:)` — the Swift face over `slopdesk_ws_pane_kind_from_raw` — on the only
    /// path that still reaches it. The five cases above go through `WorkspaceFile`, which is Rust's
    /// decoder end to end; this one goes through `JSONDecoder`, because a captured
    /// ``SessionTemplate``'s `TemplatePane` carries a kind and the device-local preferences file is
    /// still Foundation's.
    ///
    /// **The assertion that matters is the third one, not the first.** `DevicePreferences` decodes as
    /// one synthesized whole, so a `PaneKind` that THROWS unwinds past the template library, past the
    /// latched video modes and past the per-host connection targets, and `load()`'s `try?` answers a
    /// fresh default. The visible failure is not "a pane came back wrong" — it is a user's entire
    /// device-local state silently reset because one leaf of one template named a kind that was
    /// retired after it was captured, with nothing logged. Pinning the surviving neighbours is what
    /// makes that the thing under test.
    ///
    /// Written by REWRITING a file this build saved, rather than by hand: the shape of
    /// `device-prefs.json` is synthesized from a field list that moves, and a literal would start
    /// failing for the unrelated reason that a field was added — decoding to a fresh default and
    /// passing an assertion about `.terminal` while proving nothing.
    func testARetiredKindInACapturedTemplateDoesNotResetEveryDevicePreference() throws {
        let template = SessionTemplate(
            name: "Legacy", symbol: "sparkles",
            layout: .pane(TemplatePane(kind: .terminal, title: "agent", command: "claude")),
        )
        let target = ConnectionTarget(host: "10.0.0.7", port: 4242)
        let store = DevicePreferencesStore(fileURL: temporaryPreferencesURL())
        try store.save(DevicePreferences(
            launchPresets: [], sessionTemplates: [template],
            videoModesByTarget: ["display:0": VideoPaneModes(immersive: true)],
            connectionByHostKey: [DevicePreferences.hostKey(for: target): target],
        ))

        // The bytes an OLD binary wrote for the same template, back when the kind still existed. The
        // built-in libraries are empty above so this raw value is the only `"terminal"` in the file.
        //
        // The read is its OWN statement for the reason ``loadSpec`` states: an error thrown inside an
        // `XCTUnwrap` autoclosure is recorded as this test's failure before it is rethrown.
        let written = try Data(contentsOf: store.fileURL)
        let saved = try XCTUnwrap(String(data: written, encoding: .utf8))
        let aged = saved.replacingOccurrences(of: "\"terminal\"", with: "\"claudeCode\"")
        XCTAssertNotEqual(aged, saved, "the rewrite found no kind to age — the fixture stopped testing anything")
        try Data(aged.utf8).write(to: store.fileURL)

        let loaded = store.load()
        XCTAssertEqual(loaded.sessionTemplates.count, 1, "the template library survived the retired kind")
        XCTAssertEqual(
            loaded.sessionTemplates.first?.layout,
            .pane(TemplatePane(kind: .terminal, title: "agent", command: "claude")),
            "a legacy claudeCode leaf folds to a plain terminal, cwd/command intact",
        )
        XCTAssertEqual(
            loaded.videoModesByTarget["display:0"]?.immersive, true,
            "the latched video modes are what a THROWN PaneKind would have taken down with it",
        )
        XCTAssertEqual(loaded.connectionByHostKey.count, 1, "and the per-host connection targets with them")
    }

    /// The other half of the face: a discriminator this build has never had still THROWS, so the
    /// caller's reset path keeps something to catch. Here that reset is the whole file, which is
    /// exactly right — a kind nobody ever wrote is corruption, not age.
    func testAnUnknownKindInATemplateStillResetsThePreferences() throws {
        let store = DevicePreferencesStore(fileURL: temporaryPreferencesURL())
        try store.save(DevicePreferences(
            launchPresets: [],
            sessionTemplates: [SessionTemplate(name: "Bad", layout: .pane(TemplatePane(title: "x")))],
        ))
        let written = try Data(contentsOf: store.fileURL)
        let saved = try XCTUnwrap(String(data: written, encoding: .utf8))
        let broken = saved.replacingOccurrences(of: "\"terminal\"", with: "\"wormhole\"")
        XCTAssertNotEqual(broken, saved, "the rewrite found no kind to corrupt — the fixture tests nothing")
        try Data(broken.utf8).write(to: store.fileURL)

        XCTAssertEqual(
            store.load().sessionTemplates, SessionTemplate.builtIns,
            "an unknown kind is corruption — the whole value resets to the shipped default",
        )
    }

    /// A throwaway `device-prefs.json` so a test never touches the real one.
    private func temporaryPreferencesURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-panekind-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("device-prefs.json", isDirectory: false)
    }

    // MARK: - 3. Legacy claude pane handling

    // L0 / D2: testMigrationRewritesLegacyClaudeCodePaneToTerminal was DELETED — it exercised the deleted
    // v9 migration (`WorkspaceV9` + `WorkspaceMigrationV9toV10`). The load-bearing fact it protected — that
    // a legacy `"claudeCode"` raw kind decodes to `.terminal` rather than trapping — is still pinned by the
    // direct PaneSpec decode test below (testLegacyClaudeCodeRawDecodesToTerminal).

    /// The retired `"claudeCode"` raw value still decodes to `.terminal` directly on `PaneSpec` (the
    /// forward-tolerant decode that survives a stale persisted file), independent of any schema migration.
    func testLegacyClaudeCodeRawDecodesToTerminal() throws {
        let spec = try loadSpec(#"{ "kind": "claudeCode", "title": "agent" }"#)
        XCTAssertEqual(spec.kind, .terminal, "the retired claudeCode kind decodes to terminal")
        XCTAssertEqual(spec.title, "agent", "title preserved")
    }

    // MARK: - 4. A plain terminal does NOT open the inspector until claude is detected

    func testPlainTerminalDoesNotOpenInspector() async {
        var madeInspector = false
        let session = LivePaneSession.make(
            paneID: PaneID(), spec: PaneSpec(kind: .terminal, title: "term"),
            makeClient: { _ in
                SlopDeskClient(makeTransport: {
                    MuxClientTransport(registry: ConnectionRegistry())
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
    static var allCasesForTest: [PaneKind] { [.terminal, .desktop] }
}
