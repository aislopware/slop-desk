import CoreGraphics
import XCTest
@testable import AislopdeskClientUI

/// Pins the client-side invariants of the "show system popups in their own pane" feature (the user's
/// case: a SecurityAgent login/password dialog gets its own pane): an ephemeral ``PaneKind/systemDialog``
/// pane spawns on the canvas, carries its host windowID, and is NEVER persisted (a relaunch must not
/// restore a stale dialog windowID). Uses the spec-only ``FakePaneSession`` seam — no client/host.
@MainActor
final class SystemDialogPaneTests: XCTestCase {
    private func makeStore(persistence: WorkspacePersistence? = nil) -> WorkspaceStore {
        WorkspaceStore(restoring: nil, makeSession: { FakePaneSession($0) }, liveVideoCap: 2, persistence: persistence)
    }

    private func kinds(_ store: WorkspaceStore) -> [PaneKind] {
        store.workspace.canvas.allIDs().compactMap { store.workspace.canvas.spec(for: $0)?.kind }
    }

    // Spawning a dialog pane adds a `.systemDialog` leaf bound to the host windowID, focused.
    func testAddSystemDialogPaneCreatesBoundFocusedLeaf() {
        let store = makeStore()
        let before = store.workspace.canvas.allIDs().count
        let id = store.addSystemDialogPane(windowID: 1966, owner: "SecurityAgent", title: "", isSecure: true)
        XCTAssertEqual(store.workspace.canvas.allIDs().count, before + 1)
        let spec = store.workspace.canvas.spec(for: id)
        XCTAssertEqual(spec?.kind, .systemDialog)
        XCTAssertEqual(spec?.video?.windowID, 1966, "the pane streams the dialog's host windowID")
        XCTAssertEqual(spec?.title, "SecurityAgent", "owner is the label when the title is empty")
        XCTAssertEqual(store.workspace.focusedPane, id, "a surfacing prompt takes focus")
    }

    // The dialog title is folded into the label when present.
    func testTitleFoldedIntoLabel() {
        let store = makeStore()
        let id = store.addSystemDialogPane(windowID: 7, owner: "SecurityAgent", title: "Unlock", isSecure: true)
        XCTAssertEqual(store.workspace.canvas.spec(for: id)?.title, "SecurityAgent — Unlock")
    }

    // closePane removes the ephemeral pane (the monitor's dismiss path).
    func testClosingDialogPaneRemovesIt() {
        let store = makeStore()
        let id = store.addSystemDialogPane(windowID: 1966, owner: "SecurityAgent", title: "", isSecure: true)
        XCTAssertTrue(store.workspace.canvas.contains(id))
        store.closePane(id)
        XCTAssertFalse(store.workspace.canvas.contains(id))
        XCTAssertFalse(kinds(store).contains(.systemDialog))
    }

    // THE key invariant: a `.systemDialog` pane is NOT written to disk — a relaunch restores only the
    // real (terminal/remoteGUI) panes, never a stale dialog windowID.
    func testSystemDialogPaneIsNotPersisted() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aislopdesk-sysdialog-test-\(ProcessInfo.processInfo.globallyUniqueString)")
            .appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        let persistence = WorkspacePersistence(fileURL: tmp)

        let store = makeStore(persistence: persistence)
        let terminalCount = kinds(store).count(where: { $0 == .terminal })
        XCTAssertGreaterThan(terminalCount, 0, "the default workspace has a terminal pane")
        store.addSystemDialogPane(windowID: 1966, owner: "SecurityAgent", title: "", isSecure: true)
        XCTAssertTrue(kinds(store).contains(.systemDialog), "the dialog pane is live on the canvas")

        store.saveImmediately()
        let reloaded = persistence.load()
        let reloadedKinds = reloaded.canvas.allIDs().compactMap { reloaded.canvas.spec(for: $0)?.kind }
        XCTAssertFalse(reloadedKinds.contains(.systemDialog), "the ephemeral dialog pane must NOT persist")
        XCTAssertEqual(
            reloadedKinds.count(where: { $0 == .terminal }),
            terminalCount,
            "the real terminal pane(s) still persist unchanged",
        )
    }

    // A dialog pane is a VIDEO kind (counts against the cap / renders the remote-GUI view) but also flagged
    // ephemeral (skips revalidation + persistence). Pins the helper the store/session branch on.
    func testKindClassification() {
        XCTAssertTrue(PaneKind.systemDialog.isVideo)
        XCTAssertTrue(PaneKind.systemDialog.isEphemeral)
        XCTAssertTrue(PaneKind.remoteGUI.isVideo)
        XCTAssertFalse(PaneKind.remoteGUI.isEphemeral)
        XCTAssertFalse(PaneKind.terminal.isVideo)
    }
}
