import Foundation
import XCTest
@testable import SlopDeskWorkspaceModel

/// The rest of the `decodeIfPresent(…) ?? default` sweep — the sites `SplitNodeDecodeRepairTests`
/// did not reach, one level up the persisted file from the split tree.
///
/// Same trap, same blast radius: a key that is PRESENT with a value its type refuses does not answer
/// `nil`, it THROWS, so the `??` default written beside it never runs. Nothing catches that throw
/// until `WorkspacePersistence.load()`, which replaces the user's whole arrangement with the default
/// workspace and files the old one away as a `.corrupt` sidecar. Every test here therefore asserts
/// the SURVIVAL of the panes, tabs and sessions the file still describes — the field's own repaired
/// value is the small half of the property.
///
/// Which language had it right, per site:
///
/// - `PaneSpec.userRenamed` — **RUST**. `persist::decode_spec` asks
///   `matches!(value.get("userRenamed"), Some(Json::Bool(true)))`, so anything that is not the
///   literal `true` is false and nothing here is ever a fault.
/// - `VideoEndpoint` — **RUST**. `persist::decode_video` repairs `windowID` to `0`, `appName` to
///   `""` and `displayID` to `None`, and faults only on `title`. Swift's SYNTHESIZED decode faulted
///   on all four.
/// - `Session.activeTabIndex`, `Session.specs`, `Session.detached` — **NO RUST COUNTERPART**.
///   `persist.rs` decodes specs and nodes; it has never seen a session. The Swift here is the only
///   implementation of these three answers, and is what `persist.rs` will have to agree with when it
///   grows to the session/file level.
final class SessionDecodeRepairTests: XCTestCase {
    private let decoder = JSONDecoder()

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

    private func decodeSession(_ json: String) throws -> Session {
        try decoder.decode(Session.self, from: Data(json.utf8))
    }

    /// Two sessions in one array — the shape a workspace file's `sessions` key holds. A repair that
    /// is not really a repair shows up here as the SECOND session disappearing along with the first.
    private func decodeSessions(_ first: String, _ second: String) throws -> [Session] {
        try decoder.decode([Session].self, from: Data("[\(first),\(second)]".utf8))
    }

    /// The intact session every test pairs its broken one with: whatever the repair costs, it must
    /// not reach this.
    private func healthySessionJSON(pane: UUID) -> String {
        sessionJSON(name: "right", pane: pane, spec: terminalSpecJSON(title: "two"))
    }

    // MARK: - PaneSpec.userRenamed (Rust had it right)

    /// `"userRenamed": "yes"` is not `true`, and under Rust it is not a fault either — `decode_spec`
    /// pattern-matches for `Some(Json::Bool(true))` and every other shape folds to false. Swift threw
    /// past its own `?? false` and took both sessions with it.
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

    // MARK: - VideoEndpoint (Rust had it right)

    /// A window id that is not a number, and no `appName` at all. `decode_video` answers `0` and
    /// `""`; Swift's synthesized decode required both keys at their exact types, so either one threw
    /// out of the endpoint, the spec, the session and the file.
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
    /// spec when it is missing. Swift refuses it too.
    func testAVideoEndpointWithNoTitleIsStillAFault() {
        let pane = UUID()
        let json = sessionJSON(
            name: "left", pane: pane, spec: terminalSpecJSON(extra: ",\"video\":{\"windowID\":7}"),
        )
        XCTAssertThrowsError(
            try decodeSession(json), "an endpoint that names no target is corruption, not a repair",
        )
    }

    // MARK: - Session.activeTabIndex (no Rust counterpart)

    /// Swift is the only implementation here, and the answer is decided by the field's own
    /// normalizer: `normalizingActive()` already clamps an out-of-range index to `0` and `activeTab`
    /// already falls through to `tabs.first`. A wrong-TYPED index carries strictly less information
    /// than an out-of-range one, so treating it as the harsher fault was backwards.
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

    // MARK: - Session.specs (no Rust counterpart) — tolerant container

    /// `specs` is a SIDE table, not the pane list: the tabs' trees are. So an unreadable `specs`
    /// value costs titles, kinds and video targets for that ONE session — `normalizingSpecs()`
    /// re-seeds every leaf a default `PaneSpec` — while the arrangement itself survives intact. The
    /// throw it replaces cost every session in the file.
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
        XCTAssertEqual(sessions.first?.specs.isEmpty, true)
        XCTAssertEqual(sessions.last?.specs[PaneID(raw: second)]?.title, "two")
    }

    /// The strict half. A spec ROW inside the array still decodes strictly, because a `try?` per
    /// element would silently re-seed that one pane as a default terminal — a `.desktop` pane coming
    /// back as a blank terminal out of a load that reported success. Visible refusal beats a pane
    /// quietly turning into a different pane.
    func testAMalformedSpecEntryIsStillAFault() {
        let pane = UUID()
        let json = sessionJSON(name: "left", pane: pane, specs: "[{\"pane\":\(idJSON(pane))}]")
        XCTAssertThrowsError(
            try decodeSession(json), "a spec entry with no spec is corruption, not a repair",
        )
    }

    // MARK: - Session.detached (no Rust counterpart) — tolerant container

    /// `detached` is the ONLY record of a pane living outside every tab tree, so this is the repair
    /// with the sharpest edge: an entry lost here is a pane deleted (`normalizingSpecs()` prunes its
    /// now-orphan spec). It is still right, for the same reason `children` was — a value the type
    /// refuses named no panes to begin with, and there is nothing under a `{}` to recover — and the
    /// alternative was losing every session in the file including this one's tabs.
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

    /// A readable `detached` list still decodes, and every entry in it still decodes STRICTLY: a
    /// malformed record is a fault rather than one detached pane silently deleted out of a load that
    /// reported success. That strictness is what makes the tolerant container above safe.
    func testAReadableDetachedListSurvivesAndAMalformedEntryIsAFault() throws {
        let pane = UUID(), floating = UUID()
        let good = sessionJSON(
            name: "left", pane: pane, extra: ",\"detached\":[{\"pane\":\(idJSON(floating))}]",
        )
        let session = try decodeSession(good)
        XCTAssertEqual(session.detached.map(\.pane.raw), [floating])
        let bad = sessionJSON(
            name: "left", pane: pane, extra: ",\"detached\":[{\"originTab\":\(idJSON(UUID()))}]",
        )
        XCTAssertThrowsError(
            try decodeSession(bad),
            "a detached record with no pane id names nothing that can be brought back",
        )
    }
}
