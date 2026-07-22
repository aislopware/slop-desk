// DesktopPaneStoreTests — pins the full-desktop store surface: `.desktop` panes are minted by
// `newDesktopTab` (⌥⌘N), and the retired Stage domain stays decode-tolerated — a persisted
// Stage-era file loads with its orphaned stage specs pruned, never a trap.

import XCTest
@testable import SlopDeskWorkspaceCore

@MainActor
final class DesktopPaneStoreTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { FakePaneSession($0) })
    }

    // MARK: - newDesktopTab (⌥⌘N)

    /// ⌥⌘N mints a `.desktop` tab: a fresh tab whose lone leaf carries the desktop spec — endpoint
    /// displayID 0 (the host's main display), kind `.desktop` — selected and focused like ⌘T.
    func testNewDesktopTabMintsSelectedDesktopPane() throws {
        let store = makeStore()
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0

        let id = store.newDesktopTab()

        let session = try XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(session.tabs.count, tabsBefore + 1, "a desktop pane opens as a NEW tab")
        XCTAssertEqual(session.activeTab?.activePane, id, "the new tab is selected + its pane focused")
        let spec = try XCTUnwrap(session.specs[id])
        XCTAssertEqual(spec.kind, .desktop)
        XCTAssertEqual(spec.video?.displayID, 0, "displayID 0 = the host's main display")
        XCTAssertTrue(store.tree.isInvariantHeld())
        XCTAssertNotNil(store.handle(for: id), "reconcile materialized the desktop pane's session")
    }

    /// A second ⌥⌘N mints a SECOND desktop pane — no reveal-dedupe (one per display is a
    /// legitimate ask, unlike per-window panes where a window has one home).
    func testNewDesktopTabAlwaysMints() {
        let store = makeStore()
        let first = store.newDesktopTab()
        let second = store.newDesktopTab()
        XCTAssertNotEqual(first, second, "desktop tabs never dedupe")
    }

    /// An explicit display id rides the endpoint (the multi-display path).
    func testNewDesktopTabCarriesExplicitDisplayID() {
        let store = makeStore()
        let id = store.newDesktopTab(displayID: 7)
        XCTAssertEqual(store.tree.spec(for: id)?.video?.displayID, 7)
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
            kind: .systemDialog, title: "W",
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
