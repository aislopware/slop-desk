import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// The rest of the hand-edited-file sweep — the sites `SplitNodeDecodeRepairTests` does not reach,
/// one level up the persisted file from the split tree.
///
/// Same blast radius: a value the reader refuses in one session used to unwind the whole
/// `TreeWorkspace` decode, so `WorkspacePersistence.loadTree()` replaced the user's arrangement with
/// the default workspace and filed the old one away as a `.corrupt` sidecar. Every test here
/// therefore asserts the SURVIVAL of the panes, tabs and sessions the file still describes — the
/// field's own repaired value is the small half of the property.
///
/// These asserted against Swift's `Session`/`PaneSpec` `Codable` until 2026-08-20, when the file's
/// only decoder became `rust/slopdesk-workspace`'s. They now assert through ``WorkspaceFile``, which
/// is the same rules with one implementation behind them: `decode_spec` is what folds a non-boolean
/// `userRenamed` to false, `decode_video` is what repairs a window id to `0`, and `tolerant_array` is
/// what reads an unreadable side table as an empty one.
final class SessionDecodeRepairTests: XCTestCase {
    // MARK: - Fixtures (written in the shape that is actually on disk)

    /// Every id in this model is a single-field struct, so it persists as `{"raw":"<uuid>"}`.
    private func idJSON(_ uuid: UUID) -> String { "{\"raw\":\"\(uuid.uuidString)\"}" }

    private func tabJSON(pane: UUID) -> String {
        "{\"id\":\(idJSON(UUID())),\"title\":\"\",\"root\":{\"leaf\":\(idJSON(pane))}}"
    }

    private func terminalSpecJSON(title: String = "one", extra: String = "") -> String {
        "{\"kind\":\"terminal\",\"title\":\"\(title)\"\(extra)}"
    }

    /// A one-tab session whose single pane's spec is written out verbatim, so a test can put exactly
    /// one malformed value into an otherwise perfectly good file. `specs` is spelled as the raw JSON
    /// it holds so a test can hand it something that is not an array at all.
    private func sessionJSON(
        name: String,
        pane: UUID,
        spec: String? = nil,
        specs: String? = nil,
        activeTabIndex: String = "0",
        extra: String = "",
    ) -> String {
        let entries = specs ?? "[{\"pane\":\(idJSON(pane)),\"spec\":\(spec ?? terminalSpecJSON())}]"
        return "{\"id\":\(idJSON(UUID())),\"name\":\"\(name)\",\"tabs\":[\(tabJSON(pane: pane))],"
            + "\"activeTabIndex\":\(activeTabIndex),\"specs\":\(entries)\(extra)}"
    }

    /// The sessions a file's `sessions` key holds, wrapped in the file the door reads.
    private func fileJSON(_ sessions: String...) -> Data {
        Data("""
        {"schemaVersion":\(TreeWorkspace.currentSchemaVersion),"sessions":[\(sessions.joined(separator: ","))]}
        """.utf8)
    }

    /// The decode is its OWN statement, and must stay one: `XCTUnwrap` records a failure for an
    /// error thrown inside its autoclosure before it rethrows, so folding these two lines together
    /// makes every test that ASSERTS a refusal fail while its assertion passes.
    private func decodeSession(_ json: String) throws -> Session {
        let tree = try WorkspaceFile.decode(fileJSON(json))
        return try XCTUnwrap(tree.sessions.first)
    }

    /// Two sessions in one file. A repair that is not really a repair shows up here as the SECOND
    /// session disappearing along with the first.
    private func decodeSessions(_ first: String, _ second: String) throws -> [Session] {
        try WorkspaceFile.decode(fileJSON(first, second)).sessions
    }

    /// The intact session every test pairs its broken one with: whatever the repair costs, it must
    /// not reach this.
    private func healthySessionJSON(pane: UUID) -> String {
        sessionJSON(name: "right", pane: pane, spec: terminalSpecJSON(title: "two"))
    }

    // MARK: - PaneSpec.userRenamed

    /// `"userRenamed": "yes"` is not `true`, and it is not a fault either — `decode_spec`
    /// pattern-matches for `Some(Json::Bool(true))` and every other shape folds to false. The deleted
    /// Swift threw past its own `?? false` and took both sessions with it.
    func testANonBooleanUserRenamedFoldsToFalseAndKeepsBothSessions() throws {
        let first = UUID(), second = UUID()
        let broken = sessionJSON(
            name: "left", pane: first, spec: terminalSpecJSON(extra: ",\"userRenamed\":\"yes\""),
        )
        let sessions = try decodeSessions(broken, healthySessionJSON(pane: second))
        XCTAssertEqual(sessions.count, 2, "one unreadable flag must not cost the other session")
        XCTAssertEqual(sessions.first?.specs[PaneID(raw: first)]?.userRenamed, false)
        XCTAssertEqual(
            sessions.first?.specs[PaneID(raw: first)]?.title,
            "one",
            "the fields either side of the bad one are untouched",
        )
        XCTAssertEqual(sessions.last?.specs[PaneID(raw: second)]?.title, "two")
    }

    /// The one raw value that IS true stays true — pinned so the fold cannot quietly become
    /// "userRenamed is always false", which no test asserting only survival would catch.
    func testATrueUserRenamedIsStillRead() throws {
        let pane = UUID()
        let session = try decodeSession(sessionJSON(
            name: "left", pane: pane, spec: terminalSpecJSON(extra: ",\"userRenamed\":true"),
        ))
        XCTAssertEqual(session.specs[PaneID(raw: pane)]?.userRenamed, true)
    }

    // MARK: - VideoEndpoint

    /// A window id that is not a number, and no `appName` at all. `decode_video` answers `0` and
    /// `""`; the deleted Swift required both keys at their exact types, so either one threw out of
    /// the endpoint, the spec, the session and the file.
    func testAnUnreadableWindowIDAndAMissingAppNameRepairRatherThanThrow() throws {
        let first = UUID(), second = UUID()
        let video = "{\"windowID\":\"not-a-number\",\"title\":\"Display 1\"}"
        let broken = sessionJSON(
            name: "left", pane: first, spec: terminalSpecJSON(extra: ",\"video\":\(video)"),
        )
        let sessions = try decodeSessions(broken, healthySessionJSON(pane: second))
        XCTAssertEqual(sessions.count, 2, "a bad window id costs a window id, not the file")
        let endpoint = try XCTUnwrap(sessions.first?.specs[PaneID(raw: first)]?.video)
        XCTAssertEqual(endpoint.windowID, 0, "0 already MEANS 'not a window-shaped target'")
        XCTAssertEqual(endpoint.appName, "", "the empty name is the manual/display binding")
        XCTAssertEqual(endpoint.title, "Display 1", "the readable half of the endpoint survives")
        XCTAssertEqual(sessions.last?.specs[PaneID(raw: second)]?.title, "two")
    }

    /// A display id that is not a number reads as absent, so the endpoint falls back to the window
    /// shape rather than failing — `decode_video`'s `.and_then(Json::integer).and_then(…ok)` chain
    /// answering `None`.
    func testAnUnreadableDisplayIDFallsBackToTheWindowShape() throws {
        let pane = UUID()
        let video = "{\"windowID\":7,\"title\":\"Screen\",\"appName\":\"Xcode\",\"displayID\":\"main\"}"
        let session = try decodeSession(sessionJSON(
            name: "left", pane: pane, spec: terminalSpecJSON(extra: ",\"video\":\(video)"),
        ))
        let endpoint = try XCTUnwrap(session.specs[PaneID(raw: pane)]?.video)
        XCTAssertNil(endpoint.displayID)
        XCTAssertEqual(endpoint.modesKey, "app:Xcode", "it keys as the window-shaped target it now is")
    }

    /// And the line the tolerance must not cross, on the same struct. `decode_video` writes
    /// `text(value, "title")?` — a fault — because the title is the only thing a window-shaped
    /// endpoint says about itself that a repair cannot invent, and `decode_spec` refuses the whole
    /// spec when it is missing.
    func testAVideoEndpointWithNoTitleIsStillAFault() {
        let pane = UUID()
        let json = sessionJSON(
            name: "left", pane: pane, spec: terminalSpecJSON(extra: ",\"video\":{\"windowID\":7}"),
        )
        XCTAssertThrowsError(
            try decodeSession(json), "an endpoint that names no target is corruption, not a repair",
        ) { error in
            XCTAssertEqual(error as? WorkspaceFile.FileError, .malformed)
        }
    }

    // MARK: - Session.activeTabIndex

    /// The answer is decided by the field's own normalizer: the repair already clamps an out-of-range
    /// index to `0` and `activeTab` already falls through to `tabs.first`. A wrong-TYPED index
    /// carries strictly less information than an out-of-range one, so treating it as the harsher
    /// fault was backwards.
    func testAnUnreadableActiveTabIndexCostsTheSelectionAndNothingElse() throws {
        let first = UUID(), second = UUID()
        let broken = sessionJSON(name: "left", pane: first, activeTabIndex: "\"two\"")
        let sessions = try decodeSessions(broken, healthySessionJSON(pane: second))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.activeTabIndex, 0, "the same 0 the clamp would have produced")
        XCTAssertEqual(
            sessions.first?.allPaneIDs().map(\.raw),
            [first],
            "the tab and its pane are exactly where the file left them",
        )
        XCTAssertEqual(sessions.last?.name, "right")
    }

    // MARK: - Session.specs — a tolerant container around strict elements

    /// `specs` is a SIDE table, not the pane list: the tabs' trees are. So an unreadable `specs`
    /// value costs the titles, kinds and video targets of that ONE session — the repair re-seeds
    /// every leaf a default `PaneSpec` — while the arrangement itself survives intact. The throw it
    /// replaces cost every session in the file.
    func testAnUnreadableSpecsValueKeepsEveryTabAndEverySession() throws {
        let first = UUID(), second = UUID()
        let broken = sessionJSON(name: "left", pane: first, specs: "5")
        let sessions = try decodeSessions(broken, healthySessionJSON(pane: second))
        XCTAssertEqual(sessions.count, 2, "the side table is not the arrangement")
        XCTAssertEqual(
            sessions.first?.allPaneIDs().map(\.raw),
            [first],
            "the pane is still in its tab — only its description was unreadable",
        )
        XCTAssertEqual(
            sessions.first?.specs[PaneID(raw: first)]?.title,
            TreeWorkspaceDefaults.paneTitle,
            "the leaf that lost its description is re-seeded, not dropped",
        )
        XCTAssertEqual(sessions.last?.specs[PaneID(raw: second)]?.title, "two")
    }

    /// The strict half. A spec ROW inside the array is still strict, because tolerating it would
    /// silently re-seed that one pane as a default terminal — a `.desktop` pane coming back as a
    /// blank terminal out of a load that reported success. Visible refusal beats a pane quietly
    /// turning into a different pane.
    func testAMalformedSpecEntryIsStillAFault() {
        let pane = UUID()
        let json = sessionJSON(name: "left", pane: pane, specs: "[{\"pane\":\(idJSON(pane))}]")
        XCTAssertThrowsError(
            try decodeSession(json), "a spec entry with no spec is corruption, not a repair",
        ) { error in
            XCTAssertEqual(error as? WorkspaceFile.FileError, .malformed)
        }
    }

    // MARK: - Session.detached — a tolerant container around strict elements

    /// `detached` is the ONLY record of a pane living outside every tab tree, so this is the repair
    /// with the sharpest edge: an entry lost here is a pane deleted. It is still right, for the same
    /// reason `children` was — a value the reader refuses named no panes to begin with, and there is
    /// nothing under a `{}` to recover — and the alternative was losing every session in the file
    /// including this one's tabs.
    func testAnUnreadableDetachedValueCostsNoTiledPaneAndNoOtherSession() throws {
        let first = UUID(), second = UUID()
        let broken = sessionJSON(name: "left", pane: first, extra: ",\"detached\":{}")
        let sessions = try decodeSessions(broken, healthySessionJSON(pane: second))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.detached.isEmpty, true)
        XCTAssertEqual(
            sessions.first?.allPaneIDs().map(\.raw),
            [first],
            "every TILED pane survives — the unreadable list named none of them",
        )
        XCTAssertEqual(sessions.first?.specs[PaneID(raw: first)]?.title, "one")
        XCTAssertEqual(sessions.last?.specs[PaneID(raw: second)]?.title, "two")
    }

    /// A readable `detached` list still loads, and every entry in it is still strict: a malformed
    /// record is a refusal rather than one detached pane silently deleted out of a load that reported
    /// success. That strictness is what makes the tolerant container above safe.
    ///
    /// The satellite carries its own spec row, because a detached pane with nothing to materialize
    /// from is not a pane the repair keeps — which is the one place the door's answer is sharper than
    /// the deleted decoder's, and deliberately so.
    func testAReadableDetachedListSurvivesAndAMalformedEntryIsAFault() throws {
        let pane = UUID(), floating = UUID()
        let specs = "[{\"pane\":\(idJSON(pane)),\"spec\":\(terminalSpecJSON())},"
            + "{\"pane\":\(idJSON(floating)),\"spec\":\(terminalSpecJSON(title: "satellite"))}]"
        let good = sessionJSON(
            name: "left", pane: pane, specs: specs,
            extra: ",\"detached\":[{\"pane\":\(idJSON(floating))}]",
        )
        let session = try decodeSession(good)
        XCTAssertEqual(session.detached.map(\.pane.raw), [floating])
        XCTAssertEqual(session.specs[PaneID(raw: floating)]?.title, "satellite")

        let bad = sessionJSON(
            name: "left", pane: pane, extra: ",\"detached\":[{\"originTab\":\(idJSON(UUID()))}]",
        )
        XCTAssertThrowsError(
            try decodeSession(bad),
            "a detached record with no pane id names nothing that can be brought back",
        ) { error in
            XCTAssertEqual(error as? WorkspaceFile.FileError, .malformed)
        }
    }
}
