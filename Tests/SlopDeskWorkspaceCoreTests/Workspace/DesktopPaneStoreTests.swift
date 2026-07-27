// DesktopPaneStoreTests — pins the dedicated-desktop-window store surface (docs/DECISIONS.md
// 2026-07-22): `openDesktopWindow` (⌥⌘N) mints a `.desktop` pane DIRECTLY into the detached set
// (its own OS window — never a tab), reveal-dedupes per display, and the retired Stage domain
// stays decode-tolerated — a persisted Stage-era file loads with its orphaned specs pruned.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskWorkspaceCore

@MainActor
final class DesktopPaneStoreTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(liveModel: .tree, makeSession: { seed in FakePaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    // MARK: - openDesktopWindow (⌥⌘N)

    /// ⌥⌘N mints the desktop pane DETACHED: no tab appears, the spec carries the display target
    /// (displayID 0 = the host's main display), and reconcile materializes its live session.
    func testOpenDesktopWindowMintsADetachedPane() throws {
        let store = makeStore()
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0

        let id = store.openDesktopWindow()

        let session = try XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session.tabs.count, tabsBefore, "the desktop NEVER opens as a tab")
        XCTAssertTrue(session.isDetached(id), "it is born detached — the dedicated window")
        let spec = try XCTUnwrap(session.specs[id])
        XCTAssertEqual(spec.kind, .desktop)
        XCTAssertEqual(spec.video?.displayID, 0, "displayID 0 = the host's main display")
        XCTAssertTrue(store.tree.isInvariantHeld())
        XCTAssertNotNil(store.handle(for: id), "reconcile materialized the desktop pane's session")
    }

    /// A second ⌥⌘N on the SAME display reveals the existing window instead of minting a second
    /// live stream of the same display.
    func testOpenDesktopWindowRevealDedupesPerDisplay() {
        let store = makeStore()
        var revealed: [PaneID] = []
        store.revealSatelliteWindow = { revealed.append($0)
            return true
        }

        let first = store.openDesktopWindow()
        let again = store.openDesktopWindow()

        XCTAssertEqual(again, first, "same display → the existing pane is returned")
        XCTAssertEqual(revealed, [first], "…and its window revealed, never a duplicate stream")
        XCTAssertEqual(store.tree.activeSession?.detached.count, 1)
    }

    /// A DIFFERENT display mints a sibling window (one desktop window per display).
    func testOpenDesktopWindowMintsPerDisplaySiblings() {
        let store = makeStore()
        let main = store.openDesktopWindow()
        let second = store.openDesktopWindow(displayID: 7)
        XCTAssertNotEqual(second, main)
        XCTAssertEqual(store.tree.spec(for: second)?.video?.displayID, 7)
        XCTAssertEqual(store.tree.activeSession?.detached.count, 2)
    }

    /// The AUTOMATION seam's window-shaped desktop pane (`SLOPDESK_VIDEO_AUTOCONNECT_*` — endpoint
    /// with `displayID` nil) is NOT a display match: ⌥⌘N on display 0 mints a real display stream
    /// instead of revealing the automation pane (strict optional compare in `detachedDesktopPane`).
    func testWindowShapedAutomationPaneDoesNotHijackDisplayDedupe() throws {
        let store = makeStore()
        store.bootstrapFromEnvironment([
            "SLOPDESK_VIDEO_AUTOCONNECT_HOST": "127.0.0.1",
            "SLOPDESK_VIDEO_AUTOCONNECT_MEDIA_PORT": "9000",
            "SLOPDESK_VIDEO_AUTOCONNECT_CURSOR_PORT": "9001",
            "SLOPDESK_VIDEO_AUTOCONNECT_WINDOW_ID": "42",
        ])
        let automation = try XCTUnwrap(
            store.tree.activeSession?.detached.first?.pane,
            "the video autoconnect boots a DETACHED window-targeted desktop pane",
        )
        XCTAssertEqual(store.tree.spec(for: automation)?.kind, .desktop)
        XCTAssertNil(store.tree.spec(for: automation)?.video?.displayID, "window-shaped: no display target")
        XCTAssertEqual(store.tree.spec(for: automation)?.video?.windowID, 42)
        XCTAssertEqual(
            store.tree.activeSession?.tabs.flatMap { $0.allPaneIDs() }.count, 1,
            "one terminal tab — video never in the tree",
        )

        var revealed: [PaneID] = []
        store.revealSatelliteWindow = { revealed.append($0)
            return true
        }
        let main = store.openDesktopWindow(displayID: 0)

        XCTAssertNotEqual(main, automation, "⌥⌘N mints a REAL display-0 stream, not the automation pane")
        XCTAssertTrue(revealed.isEmpty, "no reveal — the window-shaped pane is not a display match")
        XCTAssertEqual(store.tree.spec(for: main)?.video?.displayID, 0)
        XCTAssertEqual(store.openDesktopWindow(displayID: 0), main, "…and the real one still dedupes")
    }

    /// Closing the desktop window is a REAL close: the pane + spec + live handle all go.
    func testCloseDesktopWindowEndsTheSession() {
        let store = makeStore()
        let id = store.openDesktopWindow()
        XCTAssertNotNil(store.handle(for: id))

        store.closePaneTree(id)

        XCTAssertNil(store.tree.spec(for: id), "the spec is gone")
        XCTAssertNil(store.handle(for: id), "reconcile tore the live session down")
        XCTAssertFalse(store.tree.activeSession?.isDetached(id) == true)
        // …and the SAME display can be reopened fresh (the dedupe never sees a closed pane).
        let reopened = store.openDesktopWindow()
        XCTAssertNotEqual(reopened, id)
    }

    // MARK: - Stage-era persistence is decode-tolerated (the Stage domain is gone)

    /// A Session JSON written during the short-lived Stage era carries `stagePanes` /
    /// `activeStagePane` keys and a spec entry for the staged pane. Decoding IGNORES the stage keys
    /// and `normalized()` prunes the orphaned spec (streamed-window tabs were ephemeral viewing
    /// surfaces — dropping them loses no terminal state). Never a trap.
    func testStageEraFileDecodesWithStageSpecsPruned() throws {
        // Build a current-shape session, then graft the Stage-era keys + an orphaned spec entry
        // into its JSON (encoding-shape-agnostic — no hand-written tree JSON to drift).
        var session = Session.singlePane(name: "Local", spec: PaneSpec(kind: .terminal, title: "T"))
        let terminal = try XCTUnwrap(session.allPaneIDs().first)
        let staged = PaneID()
        session.specs[staged] = PaneSpec(
            kind: .desktop, title: "W",
            video: VideoEndpoint(windowID: 5, title: "W", appName: "App"),
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any],
        )
        json["stagePanes"] = [["raw": staged.raw.uuidString]]
        json["activeStagePane"] = ["raw": staged.raw.uuidString]
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Session.self, from: data)
        let ws = TreeWorkspace(sessions: [decoded], activeSessionID: decoded.id).normalized()
        XCTAssertTrue(ws.isInvariantHeld(), "the loaded tree holds specs == leafIDs")
        XCTAssertNil(ws.spec(for: staged), "the orphaned stage spec is pruned")
        XCTAssertNotNil(ws.spec(for: terminal), "the tree leaf survives untouched")
    }

    /// The encoder writes NO stage keys anymore — byte-stability with the pre-Stage shape.
    func testEncodedSessionCarriesNoStageKeys() throws {
        let session = Session.singlePane(name: "Local", spec: PaneSpec(kind: .terminal, title: "T"))
        let data = try JSONEncoder().encode(session)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("stagePanes"))
        XCTAssertFalse(text.contains("activeStagePane"))
    }
}
