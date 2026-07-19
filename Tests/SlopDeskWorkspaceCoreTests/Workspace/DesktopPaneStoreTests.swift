// DesktopPaneStoreTests — pins the full-desktop pivot's store surface (docs/DECISIONS.md
// 2026-07-14): `.desktop` panes are ordinary tree leaves minted by `newDesktopTab` (⌥⌘N), the
// per-window ingress is `openRemoteWindow` (reveal-not-duplicate), and the Stage domain is GONE —
// a persisted Stage-era file loads with its orphaned stage specs pruned, never a trap.

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

    // MARK: - openRemoteWindow (Open Quickly / palette — the per-window secondary path)

    /// A fresh window opens as a `.remoteGUI` tab pre-bound to the picked id.
    func testOpenRemoteWindowMintsWindowTab() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari"))
        let spec = try XCTUnwrap(store.tree.spec(for: id))
        XCTAssertEqual(spec.kind, .remoteGUI)
        XCTAssertEqual(spec.video?.windowID, 42)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, id, "selected + focused")
    }

    /// An already-streaming window is REVEALED (tab switch + focus), never duplicated — the
    /// one-home rule every per-window ingress shares.
    func testOpenRemoteWindowRevealsExistingPane() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari"))
        store.newTab(kind: .terminal, launchGrace: .zero) // move focus away
        XCTAssertNotEqual(store.tree.activeSession?.activeTab?.activePane, first)

        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let second = store.openRemoteWindow(windowID: 42, title: "Docs", appName: "Safari")

        XCTAssertEqual(second, first, "the same window resolves to its existing pane")
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore, "no new tab was minted")
        XCTAssertEqual(store.tree.activeSession?.activeTab?.activePane, first, "the pane was revealed")
    }

    /// `streamedWindowPane` is the ONE already-open derivation: it resolves the pane + its 1-based
    /// tab ordinal, and misses cleanly for an unknown id.
    func testStreamedWindowPaneResolvesTabOrdinal() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.openRemoteWindow(windowID: 9, title: "T", appName: "A"))
        let ref = try XCTUnwrap(store.streamedWindowPane(for: 9))
        XCTAssertEqual(ref.paneID, id)
        XCTAssertEqual(ref.tabOrdinal, 2, "the window tab landed after the seed terminal tab")
        XCTAssertNil(store.streamedWindowPane(for: 777))
    }

    /// A `.remoteGUI` pane keeps streaming after being detached into its own satellite window — the
    /// window is still "already open" and must be found, not just tiled panes.
    func testStreamedWindowPaneFindsDetachedPane() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.openRemoteWindow(windowID: 9, title: "T", appName: "A"))
        store.detachPaneToWindow(id)
        XCTAssertTrue(store.tree.isDetached(id), "precondition: the window pane left the tree")

        let ref = try XCTUnwrap(store.streamedWindowPane(for: 9))

        XCTAssertEqual(ref.paneID, id)
        XCTAssertTrue(ref.isDetached, "the ref must flag it as a satellite, not a tab")
    }

    /// Reopening a window that's currently detached must NOT mint a second `.remoteGUI` tab (a second
    /// live video stream) — it resolves to the SAME pane id and, when a satellite reveal seam is wired,
    /// calls it instead of touching the tree.
    func testOpenRemoteWindowRevealsDetachedPaneInsteadOfDuplicating() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.openRemoteWindow(windowID: 9, title: "T", appName: "A"))
        store.detachPaneToWindow(first)
        var revealed: [PaneID] = []
        store.revealSatelliteWindow = { paneID in revealed.append(paneID)
            return true
        }
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0

        let second = store.openRemoteWindow(windowID: 9, title: "T", appName: "A")

        XCTAssertEqual(second, first, "resolves to the SAME pane — no duplicate stream")
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore, "no new tab was minted")
        XCTAssertFalse(store.tree.contains(first), "the pane stays detached, not folded back into a tab")
        XCTAssertEqual(revealed, [first], "the reveal seam was called with the detached pane")
    }

    /// Without the reveal seam wired (headless / test default) reopening a detached window still
    /// resolves to the existing pane and mints no duplicate — degrade to silent no-reveal, never a
    /// second live stream.
    func testOpenRemoteWindowNoDuplicateEvenWithoutRevealSeam() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.openRemoteWindow(windowID: 9, title: "T", appName: "A"))
        store.detachPaneToWindow(first)
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0

        let second = store.openRemoteWindow(windowID: 9, title: "T", appName: "A")

        XCTAssertEqual(second, first)
        XCTAssertEqual(store.tree.activeSession?.tabs.count, tabsBefore, "still no new tab — no duplicate stream")
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
            kind: .remoteGUI, title: "W",
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
