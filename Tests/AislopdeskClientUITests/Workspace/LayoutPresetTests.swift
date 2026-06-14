import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins named layout presets: snapshot the current canvas under a name, switch contexts (tears down +
/// rebuilds every session via reconcile), overwrite/delete, ephemeral-pane stripping, and the
/// Codable round-trip.
@MainActor
final class LayoutPresetTests: XCTestCase {
    private func makeStore(restoring: Workspace? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: restoring, makeSession: { FakePaneSession($0) }, liveVideoCap: 5)
    }

    private func twoPaneWorkspace() -> (Workspace, PaneID, PaneID) {
        let a = PaneID(), b = PaneID()
        let items = [
            CanvasItem(
                id: a,
                spec: PaneSpec(kind: .terminal, title: "A"),
                frame: CGRect(x: 0, y: 0, width: 480, height: 320),
                z: 0,
            ),
            CanvasItem(
                id: b,
                spec: PaneSpec(kind: .claudeCode, title: "B"),
                frame: CGRect(x: 600, y: 0, width: 480, height: 320),
                z: 1,
            ),
        ]
        return (Workspace(canvas: Canvas(items: items), focusedPane: a), a, b)
    }

    func testSaveSnapshotsCanvasGroupsAndFocus() throws {
        let (ws, a, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        let gid = store.addGroup(name: "G")
        store.assignPane(a, toGroup: gid)

        store.saveLayoutPreset(name: "work")

        XCTAssertEqual(store.layoutPresetNames, ["work"])
        let preset = try XCTUnwrap(store.workspace.layoutPresets.first)
        XCTAssertEqual(preset.canvas.items.count, 2)
        XCTAssertEqual(preset.groups.count, 1)
        XCTAssertEqual(preset.focusedPane, a)
    }

    func testEmptyNameIsNoop() {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.saveLayoutPreset(name: "   ")
        XCTAssertTrue(store.layoutPresetNames.isEmpty)
    }

    func testResaveOverwritesByName() {
        let (ws, _, b) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.saveLayoutPreset(name: "work")
        store.closePane(b) // now one pane
        store.saveLayoutPreset(name: "work")
        XCTAssertEqual(store.layoutPresetNames, ["work"], "same name overwrites, not appends")
        XCTAssertEqual(store.workspace.layoutPresets.first?.canvas.items.count, 1)
    }

    func testSwitchReplacesCanvasWithFreshIdsAndRebuildsSessions() async throws {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.saveLayoutPreset(name: "two")
        let savedIDs = try Set(XCTUnwrap(store.workspace.layoutPresets.first?.canvas.items.map(\.id)))

        // Mutate the live canvas, then switch back to the saved "two".
        store.addPane(kind: .terminal) // now 3 panes
        XCTAssertEqual(store.workspace.canvas.items.count, 3)
        store.switchToLayoutPreset(name: "two")
        await store.quiesce()

        XCTAssertEqual(store.workspace.canvas.items.count, 2, "the saved 2-pane layout came back")
        // Ids are RE-MINTED (so a switch can't collide with a still-tearing-down session of the same id).
        let liveIDs = Set(store.workspace.canvas.allIDs())
        XCTAssertTrue(liveIDs.isDisjoint(with: savedIDs), "switch re-mints pane ids")
        // The registry invariant holds: a session per live pane.
        XCTAssertEqual(Set(store.allSessions.map(\.id)), liveIDs)
        // Titles/kinds preserved through the switch.
        let kinds = store.workspace.canvas.allIDs().compactMap { store.workspace.canvas.spec(for: $0)?.kind }
        XCTAssertEqual(Set(kinds), Set([.terminal, .claudeCode]))
    }

    func testSwitchPreservesConnectionAndPresets() {
        let (ws0, _, _) = twoPaneWorkspace()
        var ws = ws0
        ws.connection = ConnectionTarget(host: "studio", port: 7420)
        let store = makeStore(restoring: ws)
        store.saveLayoutPreset(name: "a")
        store.saveLayoutPreset(name: "b")
        store.switchToLayoutPreset(name: "a")
        XCTAssertEqual(store.workspace.connection?.host, "studio", "a layout switch keeps the host")
        XCTAssertEqual(Set(store.layoutPresetNames), Set(["a", "b"]), "presets survive a switch")
    }

    func testEphemeralPanesAreStrippedFromSnapshot() throws {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.addSystemDialogPane(windowID: 9, owner: "SecurityAgent", title: "sudo", isSecure: true)
        store.saveLayoutPreset(name: "work")
        let kinds = try XCTUnwrap(store.workspace.layoutPresets.first?.canvas.items.map(\.spec.kind))
        XCTAssertFalse(kinds.contains(.systemDialog), "an auto-managed dialog pane must not be saved")
    }

    func testDeleteAndUnknownSwitchAreSafe() {
        let (ws, _, _) = twoPaneWorkspace()
        let store = makeStore(restoring: ws)
        store.saveLayoutPreset(name: "work")
        store.switchToLayoutPreset(name: "nope") // unknown — no-op, no trap
        XCTAssertEqual(store.workspace.canvas.items.count, 2)
        store.deleteLayoutPreset(name: "work")
        XCTAssertTrue(store.layoutPresetNames.isEmpty)
        store.deleteLayoutPreset(name: "work") // already gone — no-op
    }

    func testPresetsSurviveCodableRoundTrip() throws {
        let (ws0, a, _) = twoPaneWorkspace()
        var ws = ws0
        ws.layoutPresets = [LayoutPreset(name: "x", canvas: ws.canvas, groups: [], focusedPane: a)]
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.layoutPresets.count, 1)
        XCTAssertEqual(decoded.layoutPresets.first?.name, "x")
        XCTAssertEqual(decoded.layoutPresets.first?.focusedPane, a)
    }

    func testSaveRequestNudge() {
        let store = makeStore()
        XCTAssertFalse(store.pendingSaveLayout)
        store.requestSaveLayout()
        XCTAssertTrue(store.pendingSaveLayout)
        store.clearSaveLayoutRequest()
        XCTAssertFalse(store.pendingSaveLayout)
    }
}
