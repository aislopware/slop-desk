import Foundation
import XCTest
@testable import SlopDeskWorkspaceCore

/// The store-side session-template surface: opening a template adds a new ACTIVE session whose active tab
/// has the right leaf count + axis shape and materializes every pane through the `FakePaneSession` factory;
/// capturing the active session appends a template that survives a persistence round-trip. The per-pane
/// launch bytes are asserted against the PURE ``SessionTemplateEngine`` (not the 1400 ms timer).
@MainActor
final class SessionTemplateStoreTests: XCTestCase {
    private func treeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: TreeWorkspace.defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            persistence: nil,
        )
    }

    // MARK: Defaults seeded

    func testDefaultWorkspaceSeedsBuiltInSessionTemplates() {
        XCTAssertEqual(
            treeStore().sessionTemplates.map(\.name),
            ["Editor + Terminal", "Editor · Server · Git", "Claude + Terminal"],
        )
    }

    // MARK: Open from template

    func testNewSessionFromTemplateAddsActiveSessionWithRightShape() {
        let store = treeStore()
        let sessionsBefore = store.tree.sessions.count
        let template = SessionTemplate(name: "ET", layout: .split(axis: .horizontal, children: [
            .pane(TemplatePane(title: "Editor")), .pane(TemplatePane(title: "Terminal")),
        ]))
        let ids = store.newSessionFromTemplate(template)

        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(store.tree.sessions.count, sessionsBefore + 1)
        // The new session is ACTIVE, named for the slot that was free when it was created.
        let active = store.tree.activeSession
        XCTAssertEqual(active?.name, "Session \(sessionsBefore + 1)")
        // Its active tab has 2 leaves under a horizontal split.
        let root = active?.activeTab?.root
        XCTAssertEqual(root?.leafCount, 2)
        if case let .split(_, axis, _) = root {
            XCTAssertEqual(axis, .horizontal)
        } else { XCTFail("expected a horizontal split root") }
        // Both panes materialized in the registry (adopted).
        for id in ids {
            XCTAssertNotNil(store.handle(for: id))
            XCTAssertEqual((store.handle(for: id) as? FakePaneSession)?.events.first, .adopt(id))
        }
    }

    func testNestedTemplateLeafCountAndShape() {
        let store = treeStore()
        let ids = store.newSessionFromTemplate(SessionTemplate.builtIns[1]) // Editor · Server · Git (3)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.root.leafCount, 3)
        XCTAssertEqual(store.tree.activeSession?.activeTab?.root.depth, 3) // outer + nested vertical split
    }

    /// The planned per-pane launch bytes match the PURE engine for each pane (asserted via
    /// ``SessionTemplateEngine``, NOT the 1400 ms deferred timer) — so an opened template behaves like a
    /// launch preset. We re-expand the template the same way the store does and compare to `launchBytes`.
    func testPlannedLaunchBytesMatchEngine() {
        let store = treeStore()
        let template = SessionTemplate.builtIns[2] // Claude + Terminal — pane 0 runs "claude", pane 1 plain
        // Re-derive the launch list (deterministic per-pane templates) and assert each pane's bytes.
        let (_, launches) = SessionTemplateEngine.makeSession(from: template, name: "X")
        let claude = launches.first { $0.1.title == "Claude" }
        let term = launches.first { $0.1.title == "Terminal" }
        XCTAssertEqual(
            SessionTemplateEngine.launchBytes(cwd: claude?.1.cwd, command: claude?.1.command),
            Array("claude\n".utf8),
        )
        // The plain Terminal pane has no cwd/command → no bytes planned (a true no-op).
        XCTAssertNil(SessionTemplateEngine.launchBytes(cwd: term?.1.cwd, command: term?.1.command))
        // And opening it really creates the panes.
        XCTAssertEqual(store.newSessionFromTemplate(template).count, 2)
    }

    /// The deferred store→PTY wiring itself: with a `0`ms launch grace, `newSessionFromTemplate` must
    /// actually deliver each pane's launch bytes to THAT pane's session (the Claude pane gets `claude\n`,
    /// the plain Terminal pane gets nothing). Drops/wrong-pane/wrong-bytes mutations in the send loop
    /// (WorkspaceStore+Templates.swift:30-38) are caught here — `testPlannedLaunchBytesMatchEngine` only
    /// asserts the PURE engine, never the timer-deferred `sendBytes`.
    func testNewSessionFromTemplateSendsPerPaneLaunchBytes() async {
        let store = treeStore()
        // "Claude + Terminal" — pane "Claude" runs `claude`, pane "Terminal" is plain.
        let ids = store.newSessionFromTemplate(SessionTemplate.builtIns[2], launchGrace: .zero)
        XCTAssertEqual(ids.count, 2)

        // Let the deferred (0 ms-grace) send tasks run on the main actor.
        for _ in 0..<200 {
            let delivered = ids.compactMap { (store.handle(for: $0) as? FakePaneSession)?.sentBytes.count }
            if delivered.contains(where: { $0 > 0 }) { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let sentByPane = ids.map { id -> (PaneKind, [[UInt8]]) in
            let fake = store.handle(for: id) as? FakePaneSession
            return (fake?.kind ?? .terminal, fake?.sentBytes ?? [])
        }
        // Exactly one pane received bytes, and they are `claude\n`.
        let withBytes = sentByPane.filter { !$0.1.isEmpty }
        XCTAssertEqual(withBytes.count, 1, "only the Claude pane gets launch bytes; the plain Terminal gets none")
        XCTAssertEqual(withBytes.first?.1, [Array("claude\n".utf8)])
    }

    // MARK: Capture

    func testSaveCurrentSessionAsTemplateAppendsAndCapturesLayout() {
        let store = treeStore()
        // Make the active session a 2-pane split so the captured layout is non-trivial.
        store.splitActivePaneDefault(axis: .horizontal)
        let templatesBefore = store.sessionTemplates.count

        store.saveCurrentSessionAsTemplate(name: "My Layout", symbol: "star")
        XCTAssertEqual(store.sessionTemplates.count, templatesBefore + 1)
        let captured = store.sessionTemplates.last
        XCTAssertEqual(captured?.name, "My Layout")
        XCTAssertEqual(captured?.symbol, "star")
        XCTAssertEqual(captured?.isBuiltIn, false)
        // The captured layout mirrors the active session's split shape (2 panes, one split).
        XCTAssertEqual(captured?.layout.paneCount, 2)
        if case .split = captured?.layout {} else { XCTFail("expected a split layout captured") }
    }

    /// The documented no-op: with NO active session, `saveCurrentSessionAsTemplate` must NOT append (the
    /// `guard let session = tree.activeSession else { return }` at WorkspaceStore+Templates.swift:48).
    /// `replaceTree` (no re-normalize) lets the test reach the empty-sessions state the public open/close
    /// paths re-seed away from.
    func testSaveCurrentSessionWithNoActiveSessionIsNoOp() {
        let store = treeStore()
        let templatesBefore = store.sessionTemplates.count
        store.replaceTree(TreeWorkspace(sessions: [], activeSessionID: nil))
        XCTAssertNil(store.tree.activeSession, "precondition: no active session")

        store.saveCurrentSessionAsTemplate(name: "Should Not Append", symbol: "x")
        XCTAssertEqual(store.sessionTemplates.count, templatesBefore, "no template appended without an active session")
        XCTAssertFalse(store.sessionTemplates.contains { $0.name == "Should Not Append" })
    }

    func testSaveWithBlankNameUsesDefaultLayoutName() {
        let store = treeStore()
        let expected = store.defaultLayoutTemplateName
        store.saveCurrentSessionAsTemplate(name: "   ", symbol: "x")
        XCTAssertEqual(store.sessionTemplates.last?.name, expected)
    }

    /// A captured template survives a real persistence round-trip (reload via a fresh store on the same
    /// file).
    func testCapturedTemplateSurvivesPersistenceRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slopdesk-store-tmpl-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("workspace.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = WorkspacePersistence(fileURL: url)

        let store = WorkspaceStore(
            restoringTree: TreeWorkspace.defaultWorkspace(),
            liveModel: .tree,
            makeSession: { FakePaneSession($0) },
            persistence: persistence,
        )
        store.splitActivePaneDefault(axis: .vertical)
        store.saveCurrentSessionAsTemplate(name: "Persisted", symbol: "star")
        store.saveImmediately()

        let reloaded = persistence.loadTree()
        XCTAssertTrue(
            reloaded.sessionTemplates.contains { $0.name == "Persisted" && $0.layout.paneCount == 2 },
            "captured template round-trips through persistence",
        )
    }

    // MARK: CRUD

    func testUpsertAndRemove() {
        let store = treeStore()
        let id = UUID()
        store.upsertSessionTemplate(SessionTemplate(id: id, name: "Mine", layout: .pane(TemplatePane(title: "X"))))
        XCTAssertEqual(store.sessionTemplates.first { $0.id == id }?.name, "Mine")
        // Replace, not duplicate.
        store.upsertSessionTemplate(SessionTemplate(id: id, name: "Renamed", layout: .pane(TemplatePane(title: "X"))))
        XCTAssertEqual(store.sessionTemplates.count(where: { $0.id == id }), 1)
        XCTAssertEqual(store.sessionTemplates.first { $0.id == id }?.name, "Renamed")
        store.removeSessionTemplate(id)
        XCTAssertFalse(store.sessionTemplates.contains { $0.id == id })
    }
}
