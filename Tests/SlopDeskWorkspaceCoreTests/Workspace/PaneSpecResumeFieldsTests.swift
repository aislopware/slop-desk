import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// Stage-1 additive persistence fields on ``PaneSpec`` (schema v11):
/// `resumeSessionID`, `resumeLastReceivedSeq`, `lastKnownCwd`, `lastKnownTitle`.
///
/// Contract (five cases):
/// (a) A ``PaneSpec`` carrying all four fields round-trips `==`.
/// (b) A v10-era JSON (the four keys absent) decodes with all four `nil` — never traps.
/// (c) A v10 ``TreeWorkspace`` JSON loads via `migrateToTree(_:from:10)` to a valid v11 tree
///     whose specs have nil resume fields and the specs == leafIDs invariant holds.
/// (d) `loadTree()` promotes `lastKnownTitle` into `title` for panes whose title is still
///     the default `"Terminal"`.
/// (e) `loadTree()` does NOT override a user-renamed title (title ≠ `"Terminal"`).
///
/// ### Revert-to-confirm-fail reasoning
/// Each test is written so it would FAIL against the unmodified code:
/// (a) The unmodified `PaneSpec` has no resume fields → the encoder would not emit them and
///     the decoder would not populate them; `XCTAssertEqual` on a populated vs. empty spec fails.
/// (b) The unmodified `PaneSpec.init(from:)` would throw on unknown keys OR simply not populate
///     them; nil assertions trivially pass on the old code, but the decode itself would require
///     the struct to accept unknown keys — the REAL failure mode is (a) above, where a round-trip
///     produces unequal values.
/// (c) The unmodified `migrateToTree(_:from:)` had no `case 10` (returned nil) → `XCTUnwrap` fails.
/// (d)+(e) The unmodified `loadTree()` had no title-promotion transform → the spec title stays
///     `"Terminal"` even when `lastKnownTitle` is set, so (d) fails; (e) passes trivially but
///     for the wrong reason.
final class PaneSpecResumeFieldsTests: XCTestCase {
    // MARK: - Shared codecs

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private let decoder = JSONDecoder()

    // MARK: - (a) PaneSpec round-trips all four fields

    func testPaneSpecRoundTripsAllFourResumeFields() throws {
        let resumeID = UUID()
        let spec = PaneSpec(
            kind: .terminal,
            title: "zsh",
            video: nil,
            resumeSessionID: resumeID,
            resumeLastReceivedSeq: 42000,
            lastKnownCwd: "/home/user/project",
            lastKnownTitle: "zsh — project",
        )

        let data = try makeEncoder().encode(spec)
        let restored = try decoder.decode(PaneSpec.self, from: data)

        XCTAssertEqual(restored, spec, "PaneSpec round-trips all four resume fields")
        XCTAssertEqual(restored.resumeSessionID, resumeID)
        XCTAssertEqual(restored.resumeLastReceivedSeq, 42000)
        XCTAssertEqual(restored.lastKnownCwd, "/home/user/project")
        XCTAssertEqual(restored.lastKnownTitle, "zsh — project")
    }

    func testPaneSpecWithNilResumeFieldsRoundTrips() throws {
        // A never-connected pane has all four nil — its JSON must be unchanged from the pre-v11 shape.
        let spec = PaneSpec(kind: .terminal, title: "Terminal")
        let data = try makeEncoder().encode(spec)
        let restored = try decoder.decode(PaneSpec.self, from: data)
        XCTAssertEqual(restored, spec)
        XCTAssertNil(restored.resumeSessionID)
        XCTAssertNil(restored.resumeLastReceivedSeq)
        XCTAssertNil(restored.lastKnownCwd)
        XCTAssertNil(restored.lastKnownTitle)

        // The emitted JSON must NOT contain the resume keys for a nil-resume spec (encodeIfPresent).
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("resumeSessionID"), "nil resumeSessionID must not be emitted")
        XCTAssertFalse(json.contains("resumeLastReceivedSeq"), "nil seq must not be emitted")
        XCTAssertFalse(json.contains("lastKnownCwd"), "nil cwd must not be emitted")
        XCTAssertFalse(json.contains("lastKnownTitle"), "nil title must not be emitted")
    }

    // MARK: - (b) A v10-era PaneSpec JSON (four keys absent) decodes with all four nil

    func testV10EraPaneSpecJSONDecodesWithAllFourNil() throws {
        // Hand-built v10-era JSON: only the fields that existed before schema v11.
        let json = """
        { "kind": "terminal", "title": "Terminal" }
        """
        let spec = try decoder.decode(PaneSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.kind, .terminal)
        XCTAssertEqual(spec.title, "Terminal")
        XCTAssertNil(spec.resumeSessionID, "absent resumeSessionID decodes as nil (decodeIfPresent)")
        XCTAssertNil(spec.resumeLastReceivedSeq, "absent seq decodes as nil (decodeIfPresent)")
        XCTAssertNil(spec.lastKnownCwd, "absent lastKnownCwd decodes as nil (decodeIfPresent)")
        XCTAssertNil(spec.lastKnownTitle, "absent lastKnownTitle decodes as nil (decodeIfPresent)")
    }

    func testV10EraVideoSpecDecodesWithAllFourNil() throws {
        // A v10-era .remoteGUI spec carrying only the pre-v11 fields.
        let json = """
        { "kind": "remoteGUI", "title": "Safari",
          "video": { "windowID": 99, "title": "Safari", "appName": "Safari" } }
        """
        let spec = try decoder.decode(PaneSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.kind, .remoteGUI)
        XCTAssertEqual(spec.video?.windowID, 99)
        XCTAssertNil(spec.resumeSessionID)
        XCTAssertNil(spec.lastKnownTitle)
    }

    // MARK: - (c) A v10 TreeWorkspace JSON loads via migrateToTree with nil resume fields

    /// A hand-built v10 ``TreeWorkspace`` JSON (no resume fields in the specs) migrates via the
    /// `case 10` identity step in ``WorkspaceSchemaMigration/migrateToTree(_:from:)``. The loaded
    /// tree must have nil resume fields on every spec and the specs == leafIDs invariant must hold.
    func testV10TreeWorkspaceLoadsMigratingToV11WithNilResumeFields() throws {
        let paneID = PaneID()
        let sessionID = SessionID()

        // Build a v10-shaped TreeWorkspace JSON by hand, explicitly setting schemaVersion = 10.
        // Session is encoded via the real Session.encode(to:), then patched into a wrapper.
        let session = Session(
            id: sessionID,
            name: "Local",
            tabs: [Tab(root: .leaf(paneID), activePane: paneID)],
            activeTabIndex: 0,
            specs: [paneID: PaneSpec(kind: .terminal, title: "Terminal")],
        )
        let sessionData = try makeEncoder().encode(session)
        let sessionJSON = try XCTUnwrap(String(data: sessionData, encoding: .utf8))

        // v10 wrapper: schemaVersion = 10, no resume fields in the spec (none exist in the JSON above).
        let v10JSON = """
        {
          "schemaVersion": 10,
          "sessions": [\(sessionJSON)],
          "activeSessionID": { "raw": "\(sessionID.raw.uuidString)" }
        }
        """
        let v10Data = Data(v10JSON.utf8)

        // The peeked version must be 10.
        XCTAssertEqual(WorkspacePersistence.peekSchemaVersion(in: v10Data), 10)

        // migrateToTree(from: 10) must return a valid tree (not nil).
        let migrated = try XCTUnwrap(
            WorkspaceSchemaMigration.migrateToTree(v10Data, from: 10),
            "a v10 TreeWorkspace JSON must migrate (identity re-decode) to a valid TreeWorkspace",
        )

        // The invariant must hold.
        XCTAssertTrue(migrated.isInvariantHeld(), "specs == leafIDs invariant holds after v10 identity migration")

        // The spec for the single pane must have nil resume fields.
        let spec = try XCTUnwrap(migrated.spec(for: paneID))
        XCTAssertEqual(spec.kind, .terminal)
        XCTAssertNil(spec.resumeSessionID, "a v10 file's spec has nil resumeSessionID after migration")
        XCTAssertNil(spec.resumeLastReceivedSeq, "a v10 file's spec has nil resumeLastReceivedSeq after migration")
        XCTAssertNil(spec.lastKnownCwd, "a v10 file's spec has nil lastKnownCwd after migration")
        XCTAssertNil(spec.lastKnownTitle, "a v10 file's spec has nil lastKnownTitle after migration")
    }

    /// Garbage bytes passed to `migrateToTree(from: 10)` must return nil (never trap).
    func testGarbageBytesForV10MigrateToNil() {
        XCTAssertNil(
            WorkspaceSchemaMigration.migrateToTree(Data("garbage }{".utf8), from: 10),
            "non-JSON bytes for from=10 must return nil, not trap",
        )
    }

    // MARK: - (d) loadTree() promotes lastKnownTitle → title when title == "Terminal"

    func testLoadTreePromotesLastKnownTitleIntoDefaultTitle() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)

        let paneID = PaneID()
        let session = Session(
            name: "Local",
            tabs: [Tab(root: .leaf(paneID), activePane: paneID)],
            activeTabIndex: 0,
            specs: [paneID: PaneSpec(
                kind: .terminal,
                title: "Terminal", // the default title → eligible for promotion
                lastKnownTitle: "vim — main.swift",
            )],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        try persistence.save(tree)

        let loaded = persistence.loadTree()
        let loadedSpec = try XCTUnwrap(loaded.spec(for: paneID))
        XCTAssertEqual(
            loadedSpec.title,
            "vim — main.swift",
            "lastKnownTitle is promoted into title when the user has not renamed the pane",
        )
        XCTAssertEqual(
            loadedSpec.lastKnownTitle,
            "vim — main.swift",
            "lastKnownTitle is preserved verbatim after promotion",
        )
    }

    /// Multiple panes in one session — only those still named `"Terminal"` get promoted.
    func testLoadTreePromotesOnlyDefaultTitledPanes() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)

        let pDefault = PaneID()
        let pRenamed = PaneID()

        // Build a 2-leaf horizontal split using WeightedChild (the SplitNode API).
        let splitRoot = SplitNode.split(
            id: SplitNodeID(),
            axis: .horizontal,
            children: [
                WeightedChild(weight: .flex(1), node: .leaf(pDefault)),
                WeightedChild(weight: .flex(1), node: .leaf(pRenamed)),
            ],
        )
        let session = Session(
            name: "Local",
            tabs: [Tab(root: splitRoot, activePane: pDefault)],
            activeTabIndex: 0,
            specs: [
                pDefault: PaneSpec(kind: .terminal, title: "Terminal", lastKnownTitle: "make build"),
                pRenamed: PaneSpec(kind: .terminal, title: "Editor", lastKnownTitle: "vim"),
            ],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        try persistence.save(tree)

        let loaded = persistence.loadTree()
        let defaultSpec = try XCTUnwrap(loaded.spec(for: pDefault))
        let renamedSpec = try XCTUnwrap(loaded.spec(for: pRenamed))

        XCTAssertEqual(defaultSpec.title, "make build", "default-titled pane is promoted to lastKnownTitle")
        XCTAssertEqual(renamedSpec.title, "Editor", "user-renamed pane is NOT overridden by lastKnownTitle")
    }

    // MARK: - (e) loadTree() does NOT override a user-renamed title

    func testLoadTreeDoesNotOverrideUserRenamedTitle() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)

        let paneID = PaneID()
        let session = Session(
            name: "Local",
            tabs: [Tab(root: .leaf(paneID), activePane: paneID)],
            activeTabIndex: 0,
            specs: [paneID: PaneSpec(
                kind: .terminal,
                title: "My Custom Title", // user-renamed — must NOT be overridden
                lastKnownTitle: "zsh",
            )],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        try persistence.save(tree)

        let loaded = persistence.loadTree()
        let loadedSpec = try XCTUnwrap(loaded.spec(for: paneID))
        XCTAssertEqual(
            loadedSpec.title,
            "My Custom Title",
            "a user-renamed title (≠ \"Terminal\") must not be overridden by lastKnownTitle",
        )
    }

    /// A pane with `lastKnownTitle == nil` and `title == "Terminal"` is left untouched (nothing to promote).
    func testLoadTreeDoesNotPromoteWhenLastKnownTitleIsNil() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)

        let paneID = PaneID()
        let session = Session(
            name: "Local",
            tabs: [Tab(root: .leaf(paneID), activePane: paneID)],
            activeTabIndex: 0,
            specs: [paneID: PaneSpec(kind: .terminal, title: "Terminal")], // no lastKnownTitle
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        try persistence.save(tree)

        let loaded = persistence.loadTree()
        let loadedSpec = try XCTUnwrap(loaded.spec(for: paneID))
        XCTAssertEqual(loadedSpec.title, "Terminal", "nil lastKnownTitle leaves default title unchanged")
    }

    // MARK: - promotingLastKnownTitles — pure value transform (no disk I/O)

    func testPromotingLastKnownTitlesIsPure() {
        let pDefault = PaneID()
        let pRenamed = PaneID()
        let pNilTitle = PaneID()

        let splitRoot = SplitNode.split(
            id: SplitNodeID(),
            axis: .horizontal,
            children: [
                WeightedChild(weight: .flex(1), node: .leaf(pDefault)),
                WeightedChild(weight: .flex(1), node: .leaf(pRenamed)),
                WeightedChild(weight: .flex(1), node: .leaf(pNilTitle)),
            ],
        )
        let session = Session(
            name: "S",
            tabs: [Tab(root: splitRoot, activePane: pDefault)],
            activeTabIndex: 0,
            specs: [
                pDefault: PaneSpec(kind: .terminal, title: "Terminal", lastKnownTitle: "ssh prod"),
                pRenamed: PaneSpec(kind: .terminal, title: "Prod Shell", lastKnownTitle: "ssh prod"),
                pNilTitle: PaneSpec(kind: .terminal, title: "Terminal"), // no lastKnownTitle
            ],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let promoted = WorkspacePersistence.promotingLastKnownTitles(in: tree)

        XCTAssertEqual(promoted.spec(for: pDefault)?.title, "ssh prod")
        XCTAssertEqual(promoted.spec(for: pRenamed)?.title, "Prod Shell", "user-renamed title unchanged")
        XCTAssertEqual(promoted.spec(for: pNilTitle)?.title, "Terminal", "nil lastKnownTitle unchanged")
        XCTAssertTrue(promoted.isInvariantHeld())
    }

    /// A pane the user deliberately renamed TO `"Terminal"` (``PaneSpec/userRenamed`` = true) must survive
    /// the load-time promotion — the old `title == "Terminal"` gate alone would clobber that chosen label
    /// with the promoted `lastKnownTitle`. Gating on `!userRenamed` (B2) preserves the user's intent. FAILS
    /// on the pre-fix transform (it promoted any `title == "Terminal"` pane).
    func testPromotingLastKnownTitlesRespectsUserRenamedToTerminal() {
        let pane = PaneID()
        let spec = PaneSpec(
            kind: .terminal, title: "Terminal", lastKnownTitle: "ssh prod", userRenamed: true,
        )
        let session = Session(
            name: "S", tabs: [Tab(root: .leaf(pane), activePane: pane)], activeTabIndex: 0, specs: [pane: spec],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let promoted = WorkspacePersistence.promotingLastKnownTitles(in: tree)
        XCTAssertEqual(
            promoted.spec(for: pane)?.title, "Terminal",
            "an explicit rename to \"Terminal\" is not clobbered by the promoted lastKnownTitle",
        )
    }

    // MARK: - sanitizingTransientPluginCwds — pure value transform (no disk I/O)

    func testSanitizingTransientPluginCwdsDropsPoisonKeepsReal() {
        let pPoison = PaneID()
        let pReal = PaneID()
        let pNil = PaneID()

        let session = Session(
            name: "S",
            tabs: [Tab(root: .split(
                id: SplitNodeID(),
                axis: .horizontal,
                children: [
                    WeightedChild(weight: .flex(1), node: .leaf(pPoison)),
                    WeightedChild(weight: .flex(1), node: .leaf(pReal)),
                    WeightedChild(weight: .flex(1), node: .leaf(pNil)),
                ],
            ), activePane: pPoison)],
            activeTabIndex: 0,
            specs: [
                // A PRE-fix session's poisoned cwd (zinit's `user---repo` turbo-`cd` capture).
                pPoison: PaneSpec(
                    kind: .terminal, title: "Terminal",
                    lastKnownCwd: "/Users/me/.local/share/zinit/plugins/zsh-users---zsh-autosuggestions",
                ),
                pReal: PaneSpec(kind: .terminal, title: "Terminal", lastKnownCwd: "/Users/me/project"),
                pNil: PaneSpec(kind: .terminal, title: "Terminal"),
            ],
        )
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        let cleaned = WorkspacePersistence.sanitizingTransientPluginCwds(in: tree)

        XCTAssertNil(cleaned.spec(for: pPoison)?.lastKnownCwd, "a persisted plugin-cache-dir is dropped on load")
        XCTAssertEqual(cleaned.spec(for: pReal)?.lastKnownCwd, "/Users/me/project", "a real cwd is kept")
        XCTAssertNil(cleaned.spec(for: pNil)?.lastKnownCwd, "a nil cwd stays nil")
        XCTAssertTrue(cleaned.isInvariantHeld())
    }

    // MARK: - Helpers

    private func tempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneSpecResumeFieldsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("workspace.json")
    }
}
