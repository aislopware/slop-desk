import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// ``TreeWorkspace``'s ADDITIVE-tolerant decode of the new `sessionTemplates` key + the re-seed-when-empty
/// logic (mirroring the `launchPresets` field exactly — NO schema bump, NO migration). A v10 file written
/// BEFORE this feature has no `sessionTemplates` key — the decode must NOT trap and must yield an empty
/// list, which `seedingBuiltInSessionTemplatesIfEmpty()` then re-seeds. A file that DOES carry the field
/// round-trips it verbatim; a curated (≥ 1) list is left untouched. The persistence path round-trips the
/// field byte-stably.
final class TreeWorkspaceSessionTemplateDecodeTests: XCTestCase {
    /// A minimal valid v10 workspace JSON, optionally including a `sessionTemplates` array — built by hand
    /// so the test exercises the REAL `init(from:)`, not an encode-of-our-own-model derivation.
    private func workspaceJSON(sessionTemplates: String?) -> Data {
        let session = try? JSONEncoder().encode(
            Session.singlePane(name: "Local", spec: PaneSpec(kind: .terminal, title: "Local")),
        )
        let sessionJSON = session.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var fields = """
        "schemaVersion": \(TreeWorkspace.currentSchemaVersion),
        "sessions": [\(sessionJSON)]
        """
        if let sessionTemplates {
            fields += ",\n\"sessionTemplates\": \(sessionTemplates)"
        }
        return Data("{\(fields)}".utf8)
    }

    // MARK: Additive decode — absent field

    func testDecodeWithoutSessionTemplatesKeyYieldsEmptyAndDoesNotTrap() throws {
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(sessionTemplates: nil))
        XCTAssertTrue(ws.sessionTemplates.isEmpty, "absent key ⇒ empty list (decodeIfPresent), never a trap")
    }

    func testEmptySessionTemplatesReseedsBuiltIns() throws {
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(sessionTemplates: nil))
        let seeded = ws.seedingBuiltInSessionTemplatesIfEmpty()
        XCTAssertEqual(seeded.sessionTemplates, SessionTemplate.builtIns)
    }

    /// Re-seeding is idempotent — applying it twice does not duplicate the built-ins (stable UUIDs).
    func testReseedIsIdempotent() throws {
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(sessionTemplates: nil))
        let once = ws.seedingBuiltInSessionTemplatesIfEmpty()
        let twice = once.seedingBuiltInSessionTemplatesIfEmpty()
        XCTAssertEqual(twice.sessionTemplates, SessionTemplate.builtIns)
        XCTAssertEqual(twice.sessionTemplates.count, 3, "no duplicate built-ins on a second seed")
    }

    // MARK: Present field — verbatim, no spurious re-seed

    func testDecodeWithCustomTemplatesRoundTripsAndIsNotReseeded() throws {
        let mine = SessionTemplate(name: "Mine", layout: .pane(TemplatePane(title: "Solo")))
        let listJSON = try XCTUnwrap(String(data: JSONEncoder().encode([mine]), encoding: .utf8))
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(sessionTemplates: listJSON))
        XCTAssertEqual(ws.sessionTemplates, [mine])
        XCTAssertEqual(ws.seedingBuiltInSessionTemplatesIfEmpty().sessionTemplates, [mine], "no re-seed")
    }

    func testCuratedListAfterDeletionIsNotResurrected() throws {
        let kept = SessionTemplate.builtIns[0]
        let listJSON = try XCTUnwrap(String(data: JSONEncoder().encode([kept]), encoding: .utf8))
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(sessionTemplates: listJSON))
        XCTAssertEqual(
            ws.seedingBuiltInSessionTemplatesIfEmpty().sessionTemplates.map(\.name),
            [kept.name],
            "deleted built-ins are not resurrected",
        )
    }

    // MARK: normalized() chains the seed

    func testNormalizedSeedsSessionTemplates() throws {
        let ws = try JSONDecoder().decode(TreeWorkspace.self, from: workspaceJSON(sessionTemplates: nil))
        XCTAssertEqual(ws.normalized().sessionTemplates, SessionTemplate.builtIns)
    }

    // MARK: loadTree count bound (DoS-hardening)

    /// A hand-edited / hostile v10 file with a `sessionTemplates` array beyond ``WorkspacePersistence/maxItems``
    /// must be REJECTED by `loadTree()` (reset aside → default), exactly as the `allPaneIDs`/
    /// `layoutPresets`/`launchPresets` collections are — so a single huge persisted array can't make the
    /// store allocate unboundedly on launch.
    func testLoadTreeRejectsOversizedSessionTemplates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-tmpl-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = WorkspacePersistence(fileURL: url)

        // One template repeated (maxItems + 1) times — a valid v10 file whose ONLY problem is the count.
        let one = SessionTemplate(name: "T", layout: .pane(TemplatePane(title: "X")))
        let oversized = [SessionTemplate](repeating: one, count: WorkspacePersistence.maxItems + 1)
        let listJSON = try XCTUnwrap(String(data: JSONEncoder().encode(oversized), encoding: .utf8))
        try workspaceJSON(sessionTemplates: listJSON).write(to: url)

        let loaded = persistence.loadTree()
        // Reset to default (built-in templates), NOT the oversized array.
        XCTAssertEqual(loaded.sessionTemplates, SessionTemplate.builtIns)
        XCTAssertLessThanOrEqual(loaded.sessionTemplates.count, WorkspacePersistence.maxItems)
    }

    // MARK: Persistence round-trip (byte-stable)

    func testPersistenceRoundTripsSessionTemplates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-tmpl-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("workspace.json")
        let persistence = WorkspacePersistence(fileURL: url)
        defer { try? FileManager.default.removeItem(at: dir) }

        var tree = TreeWorkspace.defaultWorkspace().normalized()
        let mine = SessionTemplate(name: "Captured", symbol: "star", layout: .split(
            axis: .horizontal, children: [.pane(TemplatePane(title: "L")), .pane(TemplatePane(title: "R"))],
        ))
        tree.sessionTemplates.append(mine)

        try persistence.save(tree)
        let loaded = persistence.loadTree()
        XCTAssertTrue(loaded.sessionTemplates.contains(mine), "captured template survives save→load")
        // Byte-stable: a second save of the loaded tree produces identical bytes.
        let firstBytes = try Data(contentsOf: url)
        try persistence.save(loaded)
        let secondBytes = try Data(contentsOf: url)
        XCTAssertEqual(firstBytes, secondBytes, "sessionTemplates persist byte-stably (sorted keys)")
    }
}
