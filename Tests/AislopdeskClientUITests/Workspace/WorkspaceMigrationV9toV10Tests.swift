import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// W3 (docs/42 §Migration): the first non-trivial schema step, v9 → v10.
///
/// The v9 persisted shape is the live ``Workspace`` (a single infinite ``Canvas`` of free-floating panes
/// + named ``PaneGroup``s). v10 is the tree-rooted ``TreeWorkspace`` (`Session → Tab → Pane`). This suite
/// proves the migration is **faithful + additive**:
///
/// 1. **Frozen mirror is faithful** — a value the LIVE `Workspace` Codable produces decodes cleanly through
///    the frozen ``WorkspaceV9`` shadow with panes / groups / specs / bookmarks / presets / snippets intact
///    (so the migration is decoupled from a future live-type edit without drifting from today's bytes).
/// 2. **PaneID + PaneSpec preserved 1:1** across the transform — every leaf id survives and carries its
///    exact `PaneSpec`.
/// 3. **Groups → tabs** — each ``PaneGroup`` becomes one ``Tab``; ungrouped panes become a leading
///    "Main" tab; everything is wrapped in ONE default ``Session``.
/// 4. **Deterministic split arrangement** — a tab's panes are arranged into a valid ``SplitNode``, ordered
///    by frame `minX` then `minY`, so round-trips are byte-stable.
/// 5. **Invariant held** — the migrated ``TreeWorkspace`` satisfies `Set(specs.keys) == Set(leafIDs)`.
/// 6. **Round-trip stability** — `migrate → encode → decode == migrated`.
/// 7. **Degenerate inputs** — no panes / one pane / one group never trap.
final class WorkspaceMigrationV9toV10Tests: XCTestCase {
    // MARK: - Shared codecs

    private func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    private let decoder = JSONDecoder()

    // MARK: - Fixtures (LIVE v9 values — the migration source)

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
        windowID: UInt32,
        frame: CGRect,
        z: Int,
        groupID: PaneGroupID? = nil,
    ) -> CanvasItem {
        CanvasItem(
            id: id,
            spec: PaneSpec(
                kind: .remoteGUI,
                title: title,
                video: VideoEndpoint(windowID: windowID, title: title, appName: "Safari"),
            ),
            frame: frame, z: z, groupID: groupID,
        )
    }

    /// A representative, realistic live v9 workspace: two groups + an ungrouped pane, a video pane carrying
    /// a `VideoEndpoint`, a `.claudeCode` pane, a focused + maximized pane, a panned camera, snippets,
    /// presets, and bookmarks. The single source the suite migrates and round-trips.
    private func makeRichV9() -> (Workspace, [PaneID]) {
        let groupA = PaneGroup(name: "Servers")
        let groupB = PaneGroup(name: "Agents")
        let pBuild = PaneID(), pLog = PaneID(), pClaude = PaneID(), pVideo = PaneID(), pLoose = PaneID()

        let canvas = Canvas(
            items: [
                // groupA: two panes, deliberately out of minX order so the migration's sort is exercised.
                terminalItem(
                    pLog,
                    title: "log",
                    frame: CGRect(x: 700, y: 0, width: 640, height: 420),
                    z: 1,
                    groupID: groupA.id,
                ),
                terminalItem(
                    pBuild,
                    title: "build",
                    frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                    z: 0,
                    groupID: groupA.id,
                ),
                // groupB: a claude terminal + a video pane.
                CanvasItem(
                    id: pClaude,
                    spec: PaneSpec(kind: .claudeCode, title: "claude"),
                    frame: CGRect(x: 0, y: 500, width: 640, height: 420),
                    z: 2,
                    groupID: groupB.id,
                ),
                videoItem(
                    pVideo,
                    title: "Safari",
                    windowID: 99,
                    frame: CGRect(x: 700, y: 500, width: 800, height: 600),
                    z: 3,
                    groupID: groupB.id,
                ),
                // ungrouped.
                terminalItem(pLoose, title: "scratch", frame: CGRect(x: -200, y: 200, width: 640, height: 420), z: 4),
            ],
            camera: CanvasCamera(origin: CGPoint(x: -50, y: 30)),
        )
        let preset = LayoutPreset(
            name: "monitoring",
            canvas: Canvas(items: [terminalItem(
                PaneID(),
                title: "top",
                frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                z: 0,
            )]),
            groups: [],
            focusedPane: nil,
            triggerAppName: "Grafana",
        )
        let ws = Workspace(
            schemaVersion: Workspace.currentSchemaVersion,
            canvas: canvas,
            focusedPane: pClaude,
            maximizedPane: pVideo,
            groups: [groupA, groupB],
            connection: ConnectionTarget(host: "10.0.0.7", port: 7420, mediaPort: 9000, cursorPort: 9001),
            bookmarks: [1: CanvasBookmark(pane: pBuild, cameraOrigin: .zero, name: "build")],
            layoutPresets: [preset],
            snippets: [Snippet(name: "ssh", body: "ssh {{host}}<Enter>")],
        )
        return (ws, [pBuild, pLog, pClaude, pVideo, pLoose])
    }

    // MARK: - 1. Frozen WorkspaceV9 faithfully decodes the LIVE v9 JSON

    func testFrozenV9DecodesLiveWorkspaceJSON() throws {
        let (live, paneIDs) = makeRichV9()
        let data = try makeEncoder().encode(live)
        // Prove the SAME bytes the live `Workspace` Codable produces decode through the frozen mirror.
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)

        XCTAssertEqual(v9.schemaVersion, Workspace.currentSchemaVersion)
        XCTAssertEqual(v9.canvas.items.count, 5)
        XCTAssertEqual(Set(v9.canvas.items.map(\.id)), Set(paneIDs), "every PaneID survives the frozen decode")
        XCTAssertEqual(v9.groups.map(\.name), ["Servers", "Agents"])
        XCTAssertEqual(v9.focusedPane, live.focusedPane)
        XCTAssertEqual(v9.maximizedPane, live.maximizedPane)
        XCTAssertEqual(v9.connection?.host, "10.0.0.7")
        XCTAssertEqual(v9.snippets.map(\.name), ["ssh"])
        XCTAssertEqual(v9.layoutPresets.map(\.name), ["monitoring"])
        // Specs (the join target) survive verbatim.
        let v9Spec = v9.canvas.items.first { $0.id == paneIDs[3] }?.spec
        XCTAssertEqual(v9Spec?.kind, .remoteGUI)
        XCTAssertEqual(v9Spec?.video?.windowID, 99)
        XCTAssertEqual(v9Spec?.video?.appName, "Safari")
    }

    // MARK: - 2. PaneID + PaneSpec preserved 1:1 through the migration

    func testMigrationPreservesEveryPaneIDAndSpec() throws {
        let (live, paneIDs) = makeRichV9()
        let data = try makeEncoder().encode(live)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)

        // Every PaneID survives.
        XCTAssertEqual(Set(v10.allPaneIDs()), Set(paneIDs), "no PaneID lost or invented")
        // Every spec survives byte-for-byte.
        for item in v9.canvas.items {
            XCTAssertEqual(v10.spec(for: item.id), item.spec, "spec for \(item.id.raw) preserved verbatim")
        }
        XCTAssertTrue(v10.isInvariantHeld(), "specs == leafIDs after migration")
    }

    // MARK: - 3. Groups → tabs (+ one default Session, ungrouped → Main)

    func testGroupsMapToTabsWithLeadingMainForUngrouped() throws {
        let (live, _) = makeRichV9()
        let data = try makeEncoder().encode(live)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)

        XCTAssertEqual(v10.sessions.count, 1, "everything wraps in ONE default session")
        let session = try XCTUnwrap(v10.sessions.first)
        // Leading "Main" (the one ungrouped pane) + one tab per group, group order preserved.
        XCTAssertEqual(session.tabs.map(\.title), ["Main", "Servers", "Agents"])
        // The "Main" tab holds exactly the ungrouped pane.
        XCTAssertEqual(session.tabs[0].allPaneIDs().count, 1)
        // "Servers" holds its two panes; "Agents" its two.
        XCTAssertEqual(session.tabs[1].allPaneIDs().count, 2)
        XCTAssertEqual(session.tabs[2].allPaneIDs().count, 2)
    }

    // MARK: - 4. Deterministic split arrangement (minX then minY)

    func testTabSplitOrdersPanesByFrameMinXThenMinY() throws {
        let (live, _) = makeRichV9()
        let data = try makeEncoder().encode(live)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)
        let session = try XCTUnwrap(v10.sessions.first)
        // "Servers" tab: build (x=0) must precede log (x=700) regardless of array order in the canvas.
        let serversTab = try XCTUnwrap(session.tabs.first { $0.title == "Servers" })
        let order = serversTab.root.allPaneIDs()
        let buildID = try XCTUnwrap(v9.canvas.items.first { $0.spec.title == "build" }?.id)
        let logID = try XCTUnwrap(v9.canvas.items.first { $0.spec.title == "log" }?.id)
        XCTAssertEqual(order, [buildID, logID], "panes ordered by frame.minX then minY")
        // A 2-pane tab is a flat horizontal split (≥2 children → valid SplitNode).
        if case let .split(_, axis, children) = serversTab.root {
            XCTAssertEqual(axis, .horizontal)
            XCTAssertEqual(children.count, 2)
        } else {
            XCTFail("a 2-pane tab must be a .split, got \(serversTab.root)")
        }
    }

    // MARK: - 5. Active state carried (focus → activePane, maximize → zoom)

    func testFocusAndMaximizeCarriedIntoOwningTab() throws {
        let (live, _) = makeRichV9()
        let data = try makeEncoder().encode(live)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)
        // focusedPane (pClaude) lives in the "Agents" tab → that tab's activePane.
        let agents = try XCTUnwrap(v10.sessions.first?.tabs.first { $0.title == "Agents" })
        XCTAssertEqual(agents.activePane, live.focusedPane)
        // maximizedPane (pVideo) also in "Agents" → that tab's zoomedPane.
        XCTAssertEqual(agents.zoomedPane, live.maximizedPane)
    }

    // MARK: - 6. Carried client state + connection-derived session name

    func testSnippetsPresetsAndConnectionCarried() throws {
        let (live, _) = makeRichV9()
        let data = try makeEncoder().encode(live)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)
        XCTAssertEqual(v10.snippets.map(\.name), ["ssh"], "snippets carried verbatim")
        XCTAssertEqual(v10.layoutPresets.map(\.name), ["monitoring"], "presets carried verbatim")
        let session = try XCTUnwrap(v10.sessions.first)
        XCTAssertEqual(session.name, "10.0.0.7", "session named from the v9 connection host")
        XCTAssertEqual(session.connection?.host, "10.0.0.7", "v9 connection carried onto the session")
    }

    // MARK: - 7. Round-trip stability (migrate → encode → decode == migrated, normalized)

    func testMigratedWorkspaceRoundTripsStably() throws {
        let (live, _) = makeRichV9()
        let data = try makeEncoder().encode(live)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9).normalized()
        let encoded = try makeEncoder().encode(v10)
        let restored = try decoder.decode(TreeWorkspace.self, from: encoded)
        XCTAssertEqual(restored, v10, "migrated TreeWorkspace is an exact round-trip")
        XCTAssertTrue(restored.isInvariantHeld())
        // Byte stability: re-encoding the decoded value is identical (no hash-order churn).
        let reEncoded = try makeEncoder().encode(restored)
        XCTAssertEqual(reEncoded, encoded, "byte-stable round-trip")
    }

    // MARK: - 8. Degenerate v9 inputs never trap

    func testEmptyV9MigratesToDefaultWorkspace() throws {
        // A v9 with no panes (the user closed the last pane) is a valid persisted state.
        let empty = Workspace(canvas: Canvas(items: []), focusedPane: nil)
        let data = try makeEncoder().encode(empty)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)
        XCTAssertGreaterThanOrEqual(v10.sessions.count, 1, "never an empty workspace")
        XCTAssertTrue(v10.isInvariantHeld())
        XCTAssertFalse(v10.allPaneIDs().isEmpty, "a default leaf is seeded for an empty v9")
    }

    func testSinglePaneV9MigratesToSingleLeaf() throws {
        let p = PaneID()
        let single = Workspace(
            canvas: Canvas(items: [terminalItem(
                p,
                title: "solo",
                frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                z: 0,
            )]),
            focusedPane: p,
        )
        let data = try makeEncoder().encode(single)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)
        XCTAssertEqual(v10.allPaneIDs(), [p])
        XCTAssertEqual(v10.spec(for: p)?.title, "solo")
        let tab = try XCTUnwrap(v10.sessions.first?.tabs.first)
        if case let .leaf(id) = tab.root {
            XCTAssertEqual(id, p, "one pane → a single .leaf, not a 1-child split")
        } else {
            XCTFail("a single-pane tab must be a .leaf, got \(tab.root)")
        }
        XCTAssertTrue(v10.isInvariantHeld())
    }

    func testSingleGroupV9MigratesWithoutMainTab() throws {
        // All panes grouped → no leading "Main" tab (it would be empty); just the group's tab.
        let g = PaneGroup(name: "OnlyGroup")
        let p1 = PaneID(), p2 = PaneID()
        let ws = Workspace(
            canvas: Canvas(items: [
                terminalItem(p1, title: "a", frame: CGRect(x: 0, y: 0, width: 640, height: 420), z: 0, groupID: g.id),
                terminalItem(p2, title: "b", frame: CGRect(x: 700, y: 0, width: 640, height: 420), z: 1, groupID: g.id),
            ]),
            focusedPane: p1,
            groups: [g],
        )
        let data = try makeEncoder().encode(ws)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)
        let session = try XCTUnwrap(v10.sessions.first)
        XCTAssertEqual(session.tabs.map(\.title), ["OnlyGroup"], "no empty Main tab when nothing is ungrouped")
        XCTAssertEqual(Set(session.allPaneIDs()), Set([p1, p2]))
        XCTAssertTrue(v10.isInvariantHeld())
    }

    func testDanglingGroupIDPaneSurvivesAsUngrouped() throws {
        // A pane whose groupID names a group NOT in v9.groups (hand-edited / partially-deleted file) must
        // NOT be lost. The LIVE load path (`Workspace.normalizingGroups()`) resets such a dangling groupID
        // to nil so the pane survives as ungrouped; the migration must mirror that, routing the pane into
        // the leading "Main" tab rather than dropping its spec into an orphan that `.normalized()` deletes.
        let realGroup = PaneGroup(name: "Real")
        let pGrouped = PaneID() // a legitimately grouped pane
        let pDangling = PaneID() // groupID names a missing group
        let ghostGroupID = PaneGroupID() // referenced but absent from `groups`
        let ws = Workspace(
            canvas: Canvas(items: [
                terminalItem(
                    pGrouped,
                    title: "in-real-group",
                    frame: CGRect(x: 0, y: 0, width: 640, height: 420),
                    z: 0,
                    groupID: realGroup.id,
                ),
                terminalItem(
                    pDangling,
                    title: "orphaned-membership",
                    frame: CGRect(x: 700, y: 0, width: 640, height: 420),
                    z: 1,
                    groupID: ghostGroupID,
                ),
            ]),
            focusedPane: pGrouped,
            groups: [realGroup], // ghostGroupID is deliberately absent
        )
        let data = try makeEncoder().encode(ws)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)

        // The dangling-membership pane survives, with its spec intact.
        XCTAssertTrue(v10.allPaneIDs().contains(pDangling), "a pane whose groupID names a missing group is NOT lost")
        XCTAssertEqual(v10.spec(for: pDangling)?.title, "orphaned-membership", "its spec is preserved verbatim")
        // It lands in the leading "Main" tab (treated as ungrouped), not a phantom group tab.
        let session = try XCTUnwrap(v10.sessions.first)
        XCTAssertEqual(session.tabs.map(\.title), ["Main", "Real"], "ghost group yields no tab; dangling pane → Main")
        let mainTab = try XCTUnwrap(session.tabs.first { $0.title == "Main" })
        XCTAssertEqual(mainTab.allPaneIDs(), [pDangling], "the dangling-membership pane is in the Main tab")
        XCTAssertTrue(v10.isInvariantHeld(), "specs == leafIDs after migration (no orphan dropped)")
    }

    func testEmptyGroupYieldsNoTab() throws {
        // A group with no members must NOT yield an empty tab (a live tab must have ≥ 1 pane).
        let live = PaneGroup(name: "Live")
        let dead = PaneGroup(name: "Empty")
        let p = PaneID()
        let ws = Workspace(
            canvas: Canvas(items: [terminalItem(
                p,
                title: "x",
                frame: .init(x: 0, y: 0, width: 640, height: 420),
                z: 0,
                groupID: live.id,
            )]),
            focusedPane: p,
            groups: [live, dead],
        )
        let data = try makeEncoder().encode(ws)
        let v9 = try decoder.decode(WorkspaceV9.self, from: data)
        let v10 = WorkspaceMigrationV9toV10.migrate(v9)
        let session = try XCTUnwrap(v10.sessions.first)
        XCTAssertEqual(session.tabs.map(\.title), ["Live"], "an empty group produces no tab")
        XCTAssertTrue(v10.isInvariantHeld())
    }
}
