import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Persistence is the contract that the workspace *is* its on-disk JSON (docs/30 §4): a
/// ``TreeWorkspace`` value encodes to a stable, reviewable shape and decodes back to an EQUAL value
/// with no live object in sight. Pins the LIVE `loadTree()` path and its safety branches (C2):
///
/// - a current-version file round-trips with NO migration hop and writes no `.corrupt` sidecar;
/// - garbage / a future `schemaVersion` / the retired canvas shape all reset to the default workspace,
///   copying the unreadable file aside first;
/// - a file whose leaf count exceeds ``WorkspaceFile/maxPanes`` is bounded-reset.
///
/// (The app has no released persisted format, so there is no backward-compat migration to test — an
/// older, incompatible on-disk shape simply fails to decode and falls back to the default.)
final class WorkspacePersistenceTests: XCTestCase {
    // MARK: - 9. loadTree() — the LIVE load path's safety branches (C2)

    /// A real v11 ``TreeWorkspace`` file decodes + round-trips through `loadTree()` with NO migration
    /// (the steady-state path), no `.corrupt` sidecar written.
    func testLoadTreeRoundTripsCurrentVersionFileWithoutMigration() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let session = Session.singlePane(name: "Local", spec: PaneSpec(kind: .terminal, title: "build"))
        // Add a second TERMINAL tab + a DESKTOP tab so the round-trip exercises the mixed-kind tree
        // (terminal / desktop panes are ordinary leaves).
        let (withWindow, windowPane) = TreeIntent.newTab(
            in: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            spec: PaneSpec(
                kind: .desktop, title: "agent",
                video: VideoEndpoint(windowID: 0, title: "agent", displayID: 0),
            ),
        )
        let (grown, _) = TreeIntent.newTab(
            in: withWindow,
            spec: PaneSpec(kind: .terminal, title: "logs"),
        )
        try persistence.save(grown)

        let loaded = persistence.loadTree()
        XCTAssertEqual(
            loaded.schemaVersion,
            TreeWorkspace.currentSchemaVersion,
            "a current-version file loads at the current schema version, no migration",
        )
        XCTAssertEqual(Set(loaded.allPaneIDs()), Set(grown.allPaneIDs()), "every leaf survived the round-trip")
        XCTAssertEqual(
            loaded.spec(for: windowPane)?.kind, .desktop,
            "the desktop pane survived the round-trip as an ordinary tree leaf",
        )
        XCTAssertTrue(loaded.isInvariantHeld(), "the loaded tree holds specs == paneIDs")
        let backup = url.appendingPathExtension("corrupt")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: backup.path),
            "a good current-version load writes no .corrupt sidecar",
        )
    }

    /// Garbage / non-JSON bytes → `loadTree()` returns the default AND copies the file aside as `.corrupt`
    /// (it never throws). Pins the validate-then-drop + preserve-aside contract on the live load path.
    func testLoadTreeGarbageResetsToDefaultAndWritesCorruptSidecar() throws {
        let url = try tempURL()
        try Data("{ this is not valid tree json ".utf8).write(to: url, options: [.atomic])
        let persistence = WorkspacePersistence(fileURL: url)

        let loaded = persistence.loadTree()

        assertIsDefaultTreeShape(loaded, "garbage bytes → the default tree")
        let backup = url.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the unrestorable file is preserved aside")
    }

    /// A FUTURE `schemaVersion` (> current) is un-migratable by this build → safe reset to the default (+ sidecar).
    func testLoadTreeFutureVersionSafelyResets() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        var future = TreeWorkspace.defaultWorkspace()
        future.schemaVersion = TreeWorkspace.currentSchemaVersion + 99
        try persistence.save(future)

        let loaded = persistence.loadTree()

        assertIsDefaultTreeShape(loaded, "a future tree schemaVersion → safe default reset")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
            "the future-version file is preserved aside",
        )
    }

    /// A file from the shape BEFORE the device-local facts left the tree resets aside, keeping the user's
    /// presets and templates recoverable.
    ///
    /// The retired keys (`launchPresets`, `sessionTemplates`, `videoModesByTarget`, `Session.connection`)
    /// are outside ``TreeWorkspace`` `CodingKeys`, so the decoder ignores them — meaning without a version
    /// bump the old file decodes "successfully", the store's next autosave rewrites it without them, and
    /// the library the user built is gone with no `.corrupt` copy anywhere. Stale data decode-FAILS to the
    /// default; that is the repo rule, and the version is what makes it true here.
    func testLoadTreeResetsAFileFromTheShapeThatCarriedTheDeviceLocalFacts() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let previousShape: [String: Any] = [
            "schemaVersion": TreeWorkspace.currentSchemaVersion - 1,
            "sessions": [],
            "launchPresets": [["id": UUID().uuidString, "name": "deploy", "command": "make deploy"]],
        ]
        try JSONSerialization.data(withJSONObject: previousShape).write(to: url, options: [.atomic])

        let loaded = persistence.loadTree()

        assertIsDefaultTreeShape(loaded, "the previous tree shape → safe default reset")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
            "the user's presets and templates must still be recoverable from the sidecar",
        )
    }

    /// A file whose leaf count EXCEEDS ``WorkspaceFile/maxPanes`` is bounded-reset (a corrupt file must
    /// not make the store eagerly allocate a session per leaf on launch).
    func testLoadTreeExceedingMaxItemsIsBoundedReset() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        // A single session carrying maxPanes + 1 leaves, spread over tabs of 200: the document's own
        // `childCount` is a u8, so no ONE split can hold them — an over-ceiling file is wide, never a
        // single impossible fan-out.
        var tabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        while specs.count <= WorkspaceFile.maxPanes {
            let leaves = (0..<200).map { _ in PaneID() }
            for leaf in leaves { specs[leaf] = PaneSpec(kind: .terminal, title: "x") }
            let root = SplitNode.split(
                id: SplitNodeID(), axis: .horizontal,
                children: leaves.map { WeightedChild(weight: .flex(1.0), node: .leaf($0)) },
            )
            tabs.append(Tab(root: root, activePane: leaves[0]))
        }
        let session = Session(name: "Local", tabs: tabs, activeTabIndex: 0, specs: specs)
        let tree = TreeWorkspace(sessions: [session], activeSessionID: session.id)
        XCTAssertGreaterThan(tree.allPaneIDs().count, WorkspaceFile.maxPanes, "the fixture is over the ceiling")
        try persistence.save(tree)

        let loaded = persistence.loadTree()
        assertIsDefaultTreeShape(loaded, "an over-ceiling file is bounded-reset to the default")
    }

    /// Asserts `tree` has the default-workspace SHAPE (one "Local" session, one tab, one terminal leaf) —
    /// not value-equality, since `defaultWorkspace()` mints fresh random ids on every call.
    private func assertIsDefaultTreeShape(
        _ tree: TreeWorkspace,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(tree.schemaVersion, TreeWorkspace.currentSchemaVersion, message, file: file, line: line)
        XCTAssertEqual(tree.sessions.count, 1, "default tree has one session. \(message)", file: file, line: line)
        XCTAssertEqual(tree.allPaneIDs().count, 1, "default tree has one leaf. \(message)", file: file, line: line)
        XCTAssertEqual(
            tree.sessions.first?.tabs.count,
            1,
            "default tree has one tab. \(message)",
            file: file,
            line: line,
        )
        guard let leaf = tree.allPaneIDs().first else {
            XCTFail("default tree must have one leaf. \(message)", file: file, line: line)
            return
        }
        XCTAssertEqual(
            tree.spec(for: leaf)?.kind,
            .terminal,
            "default leaf is a terminal. \(message)",
            file: file,
            line: line,
        )
    }

    // MARK: - Helpers

    private func tempURL(file _: StaticString = #filePath, line _: UInt = #line) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("workspace.json")
    }
}
