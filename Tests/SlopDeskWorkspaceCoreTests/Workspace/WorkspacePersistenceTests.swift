import CoreGraphics
import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

/// Persistence is the contract that the workspace *is* its on-disk JSON (docs/30 §4): a `Workspace`
/// value (now holding ONE flat ``Canvas`` plus named ``PaneGroup``s — no tabs) encodes to a stable,
/// reviewable shape and decodes back to an EQUAL value with no live object in sight. Pins:
///
/// 1. **Exact-inverse round-trip** — `Workspace → JSON → Workspace` is `==`, for a multi-pane canvas
///    with mixed kinds, populated endpoints, named groups, a maximized pane, a panned camera, and
///    explicit z/frames.
/// 2. **Byte-stability** — re-encoding a decoded value yields identical bytes (a saved canvas reloads
///    pixel-identical: positions, sizes, camera, z, group membership all survive).
/// 3. **Canvas decode invariants** — a zero-item canvas THROWS (corruption → store fallback), and a
///    sub-minimum / degenerate frame is sanitized to ``Canvas/minItemSize`` on decode.
/// 4. **Schema fallback + the migration seam** — corrupt JSON / an unknown `schemaVersion` fall back to
///    ``Workspace/defaultWorkspace()``; a current (v3) payload is restored verbatim.
/// 5. **Real `load()`** — end-to-end on disk: verbatim restore, unreadable → default + `.corrupt`
///    sidecar, duplicate-id re-mint, dangling focusedPane / orphaned group repair.
///
/// (The app has no released persisted format, so there is no backward-compat migration to test — an
/// older, incompatible on-disk shape simply fails to decode and falls back to the default.)
final class WorkspacePersistenceTests: XCTestCase {
    // MARK: - Shared codecs

    private func makeEncoder(sortedKeys: Bool = false) -> JSONEncoder {
        let enc = JSONEncoder()
        if sortedKeys { enc.outputFormatting = [.sortedKeys] }
        return enc
    }

    private let decoder = JSONDecoder()

    // MARK: - Fixtures

    private func terminalItem(
        _ id: PaneID,
        title: String,
        frame: CGRect,
        z: Int,
        groupID: PaneGroupID? = nil,
    ) -> CanvasItem {
        CanvasItem(id: id, spec: PaneSpec(kind: .terminal, title: title), frame: frame, z: z, groupID: groupID)
    }

    private func videoItem(
        _ id: PaneID,
        title: String,
        frame: CGRect,
        z: Int,
        groupID: PaneGroupID? = nil,
    ) -> CanvasItem {
        CanvasItem(
            id: id,
            spec: PaneSpec(
                kind: .desktop,
                title: title,
                video: VideoEndpoint(windowID: 0, title: title, displayID: 0),
            ),
            frame: frame, z: z, groupID: groupID,
        )
    }

    // MARK: - 1. Round-trip equality

    func testDefaultWorkspaceRoundTripsEqual() throws {
        let original = Workspace.defaultWorkspace()
        let data = try makeEncoder().encode(original)
        let restored = try decoder.decode(Workspace.self, from: data)
        XCTAssertEqual(restored, original, "defaultWorkspace must be an exact round-trip")
        XCTAssertEqual(restored.canvas.itemCount, 1)
        XCTAssertEqual(restored.canvas.items.first?.spec.title, "Terminal")
        XCTAssertEqual(restored.focusedPane, restored.canvas.items.first?.id)
        XCTAssertTrue(restored.groups.isEmpty)
    }

    func testMultiPaneCanvasWorkspaceRoundTripsEqual() throws {
        let groupA = PaneGroup(name: "Servers")
        let groupB = PaneGroup(name: "Claude")
        let pA = PaneID(), pB = PaneID(), pC = PaneID()

        let canvas = Canvas(
            items: [
                terminalItem(
                    pA,
                    title: "build",
                    frame: CGRect(x: -120, y: 40, width: 700, height: 460),
                    z: 0,
                    groupID: groupA.id,
                ),
                videoItem(
                    pB,
                    title: "desktop",
                    frame: CGRect(x: 800, y: 300, width: 900, height: 600),
                    z: 1,
                    groupID: groupA.id,
                ),
                CanvasItem(
                    id: pC,
                    spec: PaneSpec(kind: .desktop, title: "agent"),
                    frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                    z: 2,
                    groupID: groupB.id,
                ),
            ],
            camera: CanvasCamera(origin: CGPoint(x: -50, y: 120)),
        )
        let original = Workspace(
            canvas: canvas,
            focusedPane: pB,
            maximizedPane: pB, // exercise the non-nil maximize path
            groups: [groupA, groupB],
            connection: ConnectionTarget(
                host: "10.0.0.9",
                port: 7420,
                mediaPort: 9000,
                cursorPort: 9001,
            ), // exercise the app-global target round-trip
        )
        let data = try makeEncoder().encode(original)
        let restored = try decoder.decode(Workspace.self, from: data)

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.focusedPane, pB)
        XCTAssertEqual(restored.maximizedPane, pB)
        XCTAssertEqual(restored.groups, [groupA, groupB], "named groups + order survive")
        XCTAssertEqual(restored.group(ofPane: pC)?.id, groupB.id, "pane group membership survives")
        XCTAssertEqual(restored.canvas.camera.origin, CGPoint(x: -50, y: 120), "camera pan survives")
        XCTAssertEqual(
            restored.canvas.frame(of: pA),
            CGRect(x: -120, y: 40, width: 700, height: 460),
            "item frame survives",
        )
        XCTAssertEqual(restored.schemaVersion, Workspace.currentSchemaVersion)
        XCTAssertEqual(restored.schemaVersion, 9) // 9: the last bump (the since-removed command macros)
        XCTAssertEqual(
            restored.connection,
            ConnectionTarget(host: "10.0.0.9", port: 7420, mediaPort: 9000, cursorPort: 9001),
            "the app-global connection target round-trips",
        )
    }

    // MARK: - 2. Byte-stability

    func testCanvasIsByteStable() throws {
        let p0 = PaneID(), p1 = PaneID()
        let original = Workspace(
            canvas: Canvas(
                items: [
                    terminalItem(p0, title: "p0", frame: CGRect(x: 12.5, y: -33.25, width: 643, height: 421), z: 5),
                    terminalItem(p1, title: "p1", frame: CGRect(x: 700.75, y: 100, width: 800, height: 500), z: 9),
                ],
                camera: CanvasCamera(origin: CGPoint(x: 17.5, y: -8.25)),
            ),
            focusedPane: p0,
        )

        let encoder = makeEncoder(sortedKeys: true)
        let data1 = try encoder.encode(original)
        let restored = try decoder.decode(Workspace.self, from: data1)
        XCTAssertEqual(restored, original, "canvas must round-trip exactly")

        let data2 = try encoder.encode(restored)
        XCTAssertEqual(data1, data2, "encode is an exact inverse of decode — byte-stable")

        // The exact z + frame survived (no re-mint / reorder / round).
        XCTAssertEqual(restored.canvas.item(p0)?.z, 5)
        XCTAssertEqual(restored.canvas.item(p1)?.z, 9)
        XCTAssertEqual(restored.canvas.frame(of: p1)?.origin.x ?? 0, 700.75, accuracy: 1e-9)
    }

    // MARK: - 3. Canvas decode invariants

    /// A zero-item canvas is now a VALID state (docs/31): the canvas is the single workspace root, not a
    /// tab's canvas, so when the user closes the last pane the canvas legitimately has zero items and must
    /// round-trip (→ the "Add a pane" empty state on reload). (Was a hard decode failure under the old
    /// per-tab ≥1-item invariant.)
    func testZeroItemCanvasDecodesEmpty() throws {
        let json = """
        { "camera": { "origin": { "x": 0, "y": 0 } }, "items": [] }
        """
        let canvas = try decoder.decode(Canvas.self, from: Data(json.utf8))
        XCTAssertTrue(canvas.items.isEmpty)
        XCTAssertEqual(canvas.camera, .zero)
    }

    /// A sub-minimum frame is sanitized to ``Canvas/minItemSize`` on decode (a degenerate frame must
    /// never reach the layout).
    func testSubMinimumFrameIsSanitizedOnDecode() throws {
        let id = PaneID()
        let json = """
        {
          "camera": { "origin": { "x": 0, "y": 0 } },
          "items": [
            { "id": { "raw": "\(id.raw.uuidString)" }, "z": 0,
              "frame": { "origin": {"x": 1, "y": 2}, "size": {"width": 5, "height": 5} },
              "spec": { "kind": "terminal", "title": "tiny" } }
          ]
        }
        """
        let canvas = try decoder.decode(Canvas.self, from: Data(json.utf8))
        XCTAssertEqual(canvas.frame(of: id)?.size, Canvas.minItemSize, "sub-minimum size floored to minItemSize")
        XCTAssertEqual(canvas.frame(of: id)?.origin, CGPoint(x: 1, y: 2), "origin preserved")
    }

    /// A canvas without a `camera` key decodes to the zero camera (forward-compatible).
    func testMissingCameraDecodesToZero() throws {
        let id = PaneID()
        let json = """
        { "items": [ { "id": { "raw": "\(id.raw.uuidString)" }, "z": 0,
          "frame": { "origin": {"x":0,"y":0}, "size": {"width":640,"height":420} },
          "spec": { "kind": "terminal", "title": "t" } } ] }
        """
        let canvas = try decoder.decode(Canvas.self, from: Data(json.utf8))
        XCTAssertEqual(canvas.camera, .zero)
    }

    // MARK: - 4. Schema-mismatch / corrupt JSON → default-workspace fallback

    func testCorruptJSONFallsBackToDefaultWorkspace() {
        let corrupt = Data("{ this is not valid workspace json ".utf8)
        let restored = decodeOrDefault(corrupt)
        assertIsDefaultWorkspaceShape(restored, "undecodable payload → default workspace")
    }

    func testUnknownSchemaVersionFallsBackToDefaultWorkspace() throws {
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        let data = try makeEncoder().encode(future)
        let raw = try decoder.decode(Workspace.self, from: data)
        XCTAssertEqual(raw.schemaVersion, Workspace.currentSchemaVersion + 99)
        let restored = decodeOrDefault(data)
        assertIsDefaultWorkspaceShape(restored, "unknown schemaVersion → default workspace")
    }

    func testCurrentVersionWellFormedPayloadIsRestoredNotReplaced() throws {
        let p0 = PaneID(), p1 = PaneID()
        let original = Workspace.make(panes: [
            (p0, PaneSpec(kind: .terminal, title: "shell")),
            (p1, PaneSpec(kind: .desktop, title: "agent")),
        ])
        let data = try makeEncoder().encode(original)
        let restored = decodeOrDefault(data)
        XCTAssertEqual(restored, original, "a good current-version payload is restored verbatim, not replaced")
        XCTAssertEqual(restored.canvas.itemCount, 2)
    }

    // MARK: - 5. Real load() through the persistence seam (end-to-end on disk)

    func testLoadCurrentVersionPayloadIsRestoredVerbatimViaRealLoad() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let original = Workspace.make(panes: [
            (PaneID(), PaneSpec(kind: .terminal, title: "shell")),
            (PaneID(), PaneSpec(kind: .desktop, title: "agent")),
        ])
        try persistence.save(original)
        XCTAssertEqual(persistence.load(), original, "a current-version payload loads verbatim")
    }

    func testLoadFutureVersionPayloadFallsBackViaRealLoad() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        try persistence.save(future)
        assertIsDefaultWorkspaceShape(persistence.load(), "future schemaVersion on disk → default via real load()")
    }

    /// A corrupt persisted canvas with a DUPLICATE pane id is RE-MINTED in place (the registry is keyed
    /// 1:1 by PaneID) — the user's panes are preserved, not nuked.
    func testLoadDedupesDuplicatePaneIDsPreservingLayout() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let shared = PaneID()
        let canvas = Canvas(items: [
            CanvasItem(
                id: shared,
                spec: PaneSpec(kind: .terminal, title: "A"),
                frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                z: 0,
            ),
            CanvasItem(
                id: shared,
                spec: PaneSpec(kind: .terminal, title: "B"),
                frame: CGRect(x: 700, y: 0, width: 640, height: 420),
                z: 1,
            ),
        ])
        try persistence.save(Workspace(canvas: canvas, focusedPane: shared))

        let loaded = persistence.load()
        XCTAssertEqual(loaded.canvas.itemCount, 2, "the user's panes are PRESERVED, not reset")
        let ids = loaded.canvas.allIDs()
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids re-minted to be globally unique")
        XCTAssertTrue(loaded.canvas.contains(loaded.focusedPane ?? PaneID()), "focus points at a real (re-minted) pane")
    }

    func testLoadCopiesUnrestorableFileAsideBeforeReset() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        var future = Workspace.defaultWorkspace()
        future.schemaVersion = Workspace.currentSchemaVersion + 99
        try persistence.save(future)
        assertIsDefaultWorkspaceShape(persistence.load(), "a future-version file → default")
        let backup = url.appendingPathExtension("corrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the unrestorable file is copied aside")
    }

    func testLoadDoesNotBackUpAGoodFile() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        try persistence.save(Workspace.make(panes: [(PaneID(), PaneSpec(kind: .desktop, title: "x"))]))
        _ = persistence.load()
        let backup = url.appendingPathExtension("corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "a good load writes no backup")
    }

    func testLoadRepairsDanglingFocusedPane() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let realPane = PaneID()
        let ghost = PaneID()
        let canvas = Canvas(items: [CanvasItem(
            id: realPane,
            spec: PaneSpec(kind: .terminal, title: "A"),
            frame: CGRect(x: 0, y: 0, width: 640, height: 420),
            z: 0,
        )])
        try persistence.save(Workspace(canvas: canvas, focusedPane: ghost))
        let loaded = persistence.load()
        XCTAssertEqual(loaded.focusedPane, realPane, "a dangling focusedPane is repaired to the first pane")
    }

    /// A pane tagged with a `groupID` that names no surviving group is reset to ungrouped on load
    /// (a hand-edited / partially-deleted file), without nuking the pane.
    func testLoadRepairsOrphanedGroupMembership() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let pane = PaneID()
        let orphanGroup = PaneGroupID() // referenced by the item but absent from `groups`
        let canvas = Canvas(items: [CanvasItem(
            id: pane,
            spec: PaneSpec(kind: .terminal, title: "A"),
            frame: CGRect(x: 0, y: 0, width: 640, height: 420),
            z: 0,
            groupID: orphanGroup,
        )])
        try persistence.save(Workspace(canvas: canvas, focusedPane: pane, groups: []))
        let loaded = persistence.load()
        XCTAssertEqual(loaded.canvas.itemCount, 1, "the pane is preserved, not reset")
        XCTAssertNil(loaded.canvas.item(pane)?.groupID, "membership in a non-existent group is cleared")
        XCTAssertNil(loaded.group(ofPane: pane), "the pane resolves as ungrouped")
    }

    // MARK: - 7. Group arithmetic round-trips through persistence (replaces tab arithmetic)

    /// The pure group CRUD (``Workspace/addingGroup(name:)`` / ``renamingGroup(_:to:)`` /
    /// ``assigning(pane:toGroup:)``) produces a workspace that persists + restores `==` — the
    /// single-canvas replacement for the old tab-arithmetic round-trip.
    func testGroupArithmeticRoundTripsThroughPersistence() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let p0 = PaneID(), p1 = PaneID()
        let base = Workspace.make(panes: [
            (p0, PaneSpec(kind: .terminal, title: "shell")),
            (p1, PaneSpec(kind: .desktop, title: "agent")),
        ])

        let (withGroup, gid) = base.addingGroup(name: "Work")
        let assigned = withGroup
            .assigning(pane: p0, toGroup: gid)
            .renamingGroup(gid, to: "Servers")

        XCTAssertEqual(assigned.group(gid)?.name, "Servers")
        XCTAssertEqual(assigned.group(ofPane: p0)?.id, gid, "p0 joined the group")
        XCTAssertNil(assigned.group(ofPane: p1), "p1 stays ungrouped")

        try persistence.save(assigned)
        XCTAssertEqual(persistence.load(), assigned, "group membership + name survive a real load()")
    }

    /// ``Workspace/removingGroup(_:)`` deletes the group but leaves its members alive as ungrouped
    /// panes — deleting a group never closes a pane (replaces the old "closing a tab" round-trip).
    func testRemovingGroupKeepsMembersUngrouped() {
        let p0 = PaneID(), p1 = PaneID()
        let base = Workspace.make(panes: [
            (p0, PaneSpec(kind: .terminal, title: "a")),
            (p1, PaneSpec(kind: .terminal, title: "b")),
        ])
        let (withGroup, gid) = base.addingGroup(name: "G")
        let grouped = withGroup
            .assigning(pane: p0, toGroup: gid)
            .assigning(pane: p1, toGroup: gid)

        let pruned = grouped.removingGroup(gid)
        XCTAssertNil(pruned.group(gid), "the group is gone")
        XCTAssertEqual(pruned.canvas.itemCount, 2, "both panes survive")
        XCTAssertNil(pruned.group(ofPane: p0), "p0 is now ungrouped")
        XCTAssertNil(pruned.group(ofPane: p1), "p1 is now ungrouped")
    }

    /// ``Workspace/movingGroup(from:to:)`` reorders the sidebar groups (replaces "move tab").
    func testMovingGroupReordersSidebar() {
        let base = Workspace.make(panes: [(PaneID(), PaneSpec(kind: .terminal, title: "t"))])
        let (a, _) = base.addingGroup(name: "A")
        let (b, _) = a.addingGroup(name: "B")
        let (c, _) = b.addingGroup(name: "C")
        XCTAssertEqual(c.groups.map(\.name), ["A", "B", "C"])

        let moved = c.movingGroup(from: IndexSet(integer: 0), to: 3) // A → end
        XCTAssertEqual(moved.groups.map(\.name), ["B", "C", "A"], "group order changed")
        XCTAssertEqual(moved.canvas, c.canvas, "membership unchanged by a reorder")
    }

    // MARK: - 9. loadTree() — the LIVE load path's safety branches (C2)

    /// A real v11 ``TreeWorkspace`` file decodes + round-trips through `loadTree()` with NO migration
    /// (the steady-state path), no `.corrupt` sidecar written.
    func testLoadTreeRoundTripsCurrentVersionFileWithoutMigration() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        let session = Session.singlePane(name: "Local", spec: PaneSpec(kind: .terminal, title: "build"))
        // Add a second TERMINAL tab + a DESKTOP tab so the round-trip exercises the mixed-kind tree
        // (terminal / desktop panes are ordinary leaves).
        let (withWindow, windowPane) = WorkspaceTreeOps.newTab(
            in: TreeWorkspace(sessions: [session], activeSessionID: session.id),
            spec: PaneSpec(
                kind: .desktop, title: "agent",
                video: VideoEndpoint(windowID: 0, title: "agent", displayID: 0),
            ),
        )
        let (grown, _) = WorkspaceTreeOps.newTab(
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

    /// A file whose leaf count EXCEEDS ``WorkspacePersistence/maxItems`` is bounded-reset (a corrupt file must
    /// not make the store eagerly allocate a session per leaf on launch).
    func testLoadTreeExceedingMaxItemsIsBoundedReset() throws {
        let url = try tempURL()
        let persistence = WorkspacePersistence(fileURL: url)
        // A single session whose one tab carries maxItems + 1 leaves (a deep split), via the tree ops.
        var tree = TreeWorkspace.defaultWorkspace()
        let firstLeaf = try XCTUnwrap(tree.allPaneIDs().first)
        // Split the active pane repeatedly to grow leaves past the ceiling. Each split adds one leaf.
        for _ in 0...(WorkspacePersistence.maxItems) {
            let active = tree.activeSession?.activeTab?.activePane ?? firstLeaf
            let (next, _) = WorkspaceTreeOps.splitPane(
                active, axis: .horizontal,
                newSpec: PaneSpec(kind: .terminal, title: "x"), in: tree,
            )
            tree = next
        }
        XCTAssertGreaterThan(tree.allPaneIDs().count, WorkspacePersistence.maxItems, "the fixture is over the ceiling")
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

    /// The decode-with-fallback mirror of the load path: decode a `Workspace`, gate its version,
    /// default on either failing. There is no migration hop — a shape or a version this build cannot
    /// read resets to the default.
    private func decodeOrDefault(_ data: Data) -> Workspace {
        guard let decoded = try? decoder.decode(Workspace.self, from: data),
              decoded.schemaVersion == Workspace.currentSchemaVersion
        else { return .defaultWorkspace() }
        return decoded
    }

    private func assertIsDefaultWorkspaceShape(
        _ ws: Workspace,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
    ) {
        XCTAssertEqual(ws.schemaVersion, Workspace.currentSchemaVersion, message, file: file, line: line)
        XCTAssertEqual(ws.canvas.itemCount, 1, "default has exactly one pane. \(message)", file: file, line: line)
        XCTAssertTrue(ws.groups.isEmpty, "default has no groups. \(message)", file: file, line: line)
        XCTAssertEqual(ws.maximizedPane, nil, "default is not maximized. \(message)", file: file, line: line)
        guard let item = ws.canvas.items.first else {
            XCTFail("default canvas must have one item. \(message)", file: file, line: line)
            return
        }
        XCTAssertEqual(item.spec.kind, .terminal, "default pane is a terminal. \(message)", file: file, line: line)
        XCTAssertEqual(
            item.spec.title,
            "Terminal",
            "default pane is named Terminal. \(message)",
            file: file,
            line: line,
        )
        XCTAssertEqual(ws.focusedPane, item.id, "the single pane is focused. \(message)", file: file, line: line)
    }
}
