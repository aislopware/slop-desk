// WorkspaceControlBackendTreeTests — pins the REAL `WorkspaceControlBackend` (not the dispatcher's FAKE
// backend) on the surfaces the FAKE cannot catch: the tree → window/tab/pane mapping,
// the SHELL-QUOTED `jump` cd bytes, the view/edit shim's new-leaf placement + quoted launch bytes,
// scrollback capture, the named-key send-keys table, and the font system/user scope classifier.
//
// Revert-to-confirm-fail: every quoting assertion fails on the pre-fix backend (which emitted
// `cd /Users/x/My Project` / `less /tmp/my file.txt` raw, word-splitting on the space), and the scope
// assertions fail on the pre-fix `isSystem: true`-for-everything `listFonts`. None is tautological.
//
// Hang-safe (CLAUDE.md rule #6): a tree-model store over a recording in-memory fake and a temp-file
// `FolderFrecencyStore` — no socket, no GUI, no SCStream/VT/Metal/NSWindow.

import SlopDeskWorkspaceModel
import XCTest
@testable import SlopDeskClientCore
@testable import SlopDeskWorkspaceCore

@MainActor
final class WorkspaceControlBackendTreeTests: XCTestCase {
    /// The backend holds `folders` WEAKLY (the app owns it); the test must retain it for the method's
    /// duration or `jump`/`learn` degrade to nil mid-test.
    private var retained: [AnyObject] = []

    // The @objc XCTestCase override must keep the throwing signature (a non-throwing
    // override of a throwing @objc method does not compile).
    // swiftlint:disable:next unneeded_throws_rethrows
    override func tearDown() async throws {
        retained.removeAll()
    }

    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(makeSession: { seed in RecordingPaneSession(seed.spec) })
        store.attachLoopbackWorkspaceDocument()
        return store
    }

    private func makeBackend(
        _ store: WorkspaceStore,
        shimGrace: Duration = .milliseconds(1500),
    ) -> WorkspaceControlBackend {
        let folders = FolderFrecencyStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("frecency-\(UUID().uuidString).json"),
        )
        retained.append(folders)
        return WorkspaceControlBackend(store: store, folders: folders, shimLaunchGrace: shimGrace)
    }

    private func recording(_ store: WorkspaceStore, _ id: PaneID) throws -> RecordingPaneSession {
        try XCTUnwrap(store.handle(for: id) as? RecordingPaneSession)
    }

    /// The id of the live (materialized) focused leaf in `.tree` mode — the active tab's active pane. (NOT
    /// `store.focusedPane`, which is the unmaterialized canvas leaf in tree mode — the very mismatch the
    /// backend's tree-aware focus resolution corrects.)
    private func focusedLeaf(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
    }

    // MARK: - (a) tree → window / tab / pane mapping

    func testTreeMapsToWindowsTabsPanes() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)
        store.setLastKnownCwd("/work/proj", for: focused)
        store.noteTitlePushed("vim", for: focused)
        store.reconcileTree()

        let windows = backend.listWindows()
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(try XCTUnwrap(windows.first).isFocused, "the only session is the focused window")

        let tabs = backend.listTabs(windowId: nil)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertTrue(try XCTUnwrap(tabs.first).isFocused, "the only tab is focused")

        let panes = backend.listPanes(tabId: nil)
        let pane = try XCTUnwrap(panes.first { $0.id == focused.raw.uuidString })
        XCTAssertTrue(pane.isFocused, "the focused pane is flagged")
        XCTAssertEqual(pane.cwd, "/work/proj", "cwd maps from the pane's `pane/cwd`")
        XCTAssertEqual(pane.title, "vim", "title maps from the pane's live shell title")
        XCTAssertEqual(pane.kind, PaneKind.terminal.rawValue, "kind maps from PaneSpec.kind")
    }

    // MARK: - (b) jump emits a SHELL-QUOTED `cd -- '…'`

    /// `focusedCwd()` feeds `slopdesk jump` (no query) and `slopdesk learn` (no path). A nil there is
    /// silent: both verbs simply return nothing, with no error to explain why. So it is pinned through
    /// the one verb whose OUTPUT names it — `learn` with no path records the focused pane's cwd.
    func testFocusedCwdIsNotNilAfterTheMove() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)

        XCTAssertNil(backend.learn(path: nil), "precondition: no cwd is known yet")

        store.setLastKnownCwd("/work/proj", for: focused)
        XCTAssertEqual(
            backend.learn(path: nil), "/work/proj",
            "the focused pane's cwd resolves through the mirror — the frecency verbs still have an input",
        )
    }

    func testJumpQuotesPathWithSpace() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)
        _ = backend.learn(path: "/Users/x/My Project")

        let outcome = try XCTUnwrap(backend.jump(query: "My Project", changeDirectory: true))
        XCTAssertEqual(outcome.path, "/Users/x/My Project")
        XCTAssertTrue(outcome.didChangeDirectory)

        let handle = try recording(store, focused)
        // Pre-fix this was `cd /Users/x/My Project` (cds to `/Users/x/My`); the quoted form is the fix.
        XCTAssertEqual(handle.sentText, ["cd -- '/Users/x/My Project'"], "the path is single-quoted, not raw")
        XCTAssertEqual(handle.sentBytes, [[0x0D]], "Enter == carriage return follows the cd")
    }

    func testJumpEscapesEmbeddedSingleQuote() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)
        _ = backend.learn(path: "/Users/x/a'b")

        _ = backend.jump(query: "a'b", changeDirectory: true)
        let handle = try recording(store, focused)
        // The POSIX `'\''` idiom: a'b → 'a'\''b'.
        XCTAssertEqual(handle.sentText, ["cd -- '/Users/x/a'\\''b'"], "embedded single-quote is escaped")
    }

    func testJumpNoCdDoesNotEmitBytes() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)
        _ = backend.learn(path: "/Users/x/My Project")

        let outcome = try XCTUnwrap(backend.jump(query: "My Project", changeDirectory: false))
        XCTAssertFalse(outcome.didChangeDirectory)
        let handle = try recording(store, focused)
        XCTAssertTrue(handle.sentText.isEmpty, "--no-cd resolves the path but sends nothing")
    }

    // MARK: - (c) view / edit shim — new leaf + quoted launch bytes

    func testViewShimAddsLeafAndQuotesLessCommand() async throws {
        let store = makeStore()
        let backend = makeBackend(store, shimGrace: .milliseconds(5))
        let before = leafIDs(store)

        XCTAssertTrue(backend.open(target: "/tmp/my file.txt", mode: .view, placement: .newTab))
        let after = leafIDs(store)
        XCTAssertEqual(after.count, before.count + 1, "the placement op spawned exactly one new leaf")
        let newLeaf = try XCTUnwrap(after.subtracting(before).first)

        let command = try await awaitShimCommand(store, newLeaf)
        XCTAssertTrue(
            command.contains("less -- '/tmp/my file.txt'"),
            "view shim quotes the path for `less` (got: \(command))",
        )
    }

    func testEditShimQuotesEditorCommand() async throws {
        let store = makeStore()
        let backend = makeBackend(store, shimGrace: .milliseconds(5))
        let before = leafIDs(store)

        XCTAssertTrue(backend.open(target: "/tmp/my file.txt", mode: .edit, placement: .newTab))
        let newLeaf = try XCTUnwrap(leafIDs(store).subtracting(before).first)

        let command = try await awaitShimCommand(store, newLeaf)
        XCTAssertTrue(
            command.contains("${EDITOR:-vi} -- '/tmp/my file.txt'"),
            "edit shim quotes the path for $EDITOR (got: \(command))",
        )
    }

    /// `--new-window` does not mint a NEW SESSION (the session switcher is gone, and a new session would
    /// strand the user) — it degrades to a NEW TAB in the CURRENT session. The session count
    /// must stay 1 and the active session gains one tab; the shim command still lands on the new leaf.
    /// REVERT-TO-FAIL: a `store.newSession(...)` arm would make `sessions.count` 2 (a new orphan session).
    func testNewWindowPlacementOpensTabInCurrentSession() async throws {
        let store = makeStore()
        let backend = makeBackend(store, shimGrace: .milliseconds(5))
        let sessionsBefore = store.tree.sessions.count
        let tabsBefore = store.tree.activeSession?.tabs.count ?? 0
        let leavesBefore = leafIDs(store)

        XCTAssertTrue(backend.open(target: "/tmp/notes.txt", mode: .view, placement: .newWindow))

        XCTAssertEqual(
            store.tree.sessions.count, sessionsBefore,
            "--new-window must NOT create a new session (the multi-session UI is gone)",
        )
        XCTAssertEqual(
            store.tree.activeSession?.tabs.count, tabsBefore + 1,
            "--new-window opens a new TAB in the current session",
        )
        let newLeaf = try XCTUnwrap(leafIDs(store).subtracting(leavesBefore).first)
        let command = try await awaitShimCommand(store, newLeaf)
        XCTAssertTrue(
            command.contains("less -- '/tmp/notes.txt'"),
            "the shim command still lands on the new-tab leaf (got: \(command))",
        )
    }

    // MARK: - (d) pane capture — last-N scrollback

    func testCapturePaneReturnsLastNLines() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)
        try recording(store, focused).scrollback = ["l1", "l2", "l3", "l4"]

        XCTAssertEqual(backend.capturePane(paneId: nil, lines: 2), ["l3", "l4"], "the last N lines")
        XCTAssertEqual(backend.capturePane(paneId: nil, lines: 10), ["l1", "l2", "l3", "l4"], "N over count = all")
    }

    // MARK: - (e) send-keys — verbatim text + the one named-key vocabulary

    func testSendKeysVerbatimTextThenNamedKeys() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)

        XCTAssertEqual(backend.sendKeys(paneId: nil, text: "echo hi", keys: ["enter", "tab", "esc", "up"]), .sent)
        let handle = try recording(store, focused)
        XCTAssertEqual(handle.sentText, ["echo hi"], "literal text is sent verbatim")
        XCTAssertEqual(
            handle.sentBytes,
            [[0x0D, 0x09, 0x1B, 0x1B, 0x5B, 0x41]],
            "named keys map to their keycode bytes (enter/tab/esc/up), resolved before anything is written",
        )
    }

    /// The names the deleted nine-entry table did not know. Each reported SUCCESS and sent nothing;
    /// the vocabulary behind the door has always had them, so they are keystrokes now.
    func testSendKeysReachesTheKeysTheOldTableDropped() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)

        XCTAssertEqual(backend.sendKeys(paneId: nil, text: "", keys: ["f5", "pgup", "home", "delete"]), .sent)
        let handle = try recording(store, focused)
        XCTAssertEqual(
            handle.sentBytes,
            [[0x1B, 0x5B, 0x31, 0x35, 0x7E] + [0x1B, 0x5B, 0x35, 0x7E] + [0x1B, 0x5B, 0x48] + [0x1B, 0x5B, 0x33, 0x7E]],
            "F5, PgUp, Home and Delete are CSI sequences, not silence",
        )
    }

    /// A name that is not a key rejects the WHOLE request, and nothing reaches the pane — the same
    /// validate-then-drop the host's `write` verb has always applied to the same vocabulary.
    func testSendKeysRefusesAnUnknownKeyAndWritesNothing() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)

        XCTAssertEqual(
            backend.sendKeys(paneId: nil, text: "echo hi", keys: ["enter", "frobnicate"]),
            .unknownKey("frobnicate"),
        )
        let handle = try recording(store, focused)
        XCTAssertEqual(handle.sentText, [], "not even the literal text goes out on a refused request")
        XCTAssertEqual(handle.sentBytes, [])
    }

    // MARK: - (f) font scope classifier

    #if canImport(AppKit)
    func testIsUserFontClassifierByDirectory() {
        let userDir = "/Users/x/Library/Fonts"
        XCTAssertTrue(
            WorkspaceControlBackend.isUserFont(
                url: URL(fileURLWithPath: userDir + "/My.ttf"),
                userFontsDirectory: userDir,
            ),
            "a face under ~/Library/Fonts is a user font",
        )
        XCTAssertFalse(
            WorkspaceControlBackend.isUserFont(
                url: URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc"), userFontsDirectory: userDir,
            ),
            "a face under /System/Library/Fonts is NOT a user font",
        )
        XCTAssertFalse(
            WorkspaceControlBackend.isUserFont(url: nil, userFontsDirectory: userDir),
            "an unresolved URL degrades to system",
        )
    }

    /// The live `font list` honors `--system`/`--user`: Menlo (a built-in macOS face) is reported `system`,
    /// is present under `--system`, and is ABSENT under `--user`. Pre-fix `listFonts` hard-coded
    /// `isSystem: true` AND ignored `scope`, so Menlo would have wrongly appeared in the `--user` results.
    func testFontScopeFilterClassifiesMenloAsSystem() throws {
        let store = makeStore()
        let backend = makeBackend(store)

        let menloAll = backend.listFonts(monospaceOnly: false, family: "Menlo", scope: nil)
        guard let menlo = menloAll.first(where: { $0.family == "Menlo" }) else {
            throw XCTSkip("Menlo not installed on this host")
        }
        XCTAssertTrue(menlo.isSystem, "Menlo classifies as a system font")

        let system = backend.listFonts(monospaceOnly: false, family: "Menlo", scope: .system)
        XCTAssertTrue(system.contains { $0.family == "Menlo" }, "--system includes Menlo")
        let user = backend.listFonts(monospaceOnly: false, family: "Menlo", scope: .user)
        XCTAssertFalse(user.contains { $0.family == "Menlo" }, "--user excludes the system Menlo")
    }
    #endif

    // MARK: - Helpers

    private func leafIDs(_ store: WorkspaceStore) -> Set<PaneID> {
        var ids: Set<PaneID> = []
        for session in store.tree.sessions {
            for tab in session.tabs {
                for id in tab.allPaneIDs() { ids.insert(id) }
            }
        }
        return ids
    }

    /// Poll until the deferred shim launch bytes land on `leaf`, then decode them to a string. Fails if no
    /// bytes arrive within the budget (the shim grace is injected at 5 ms, so this resolves promptly).
    private func awaitShimCommand(_ store: WorkspaceStore, _ leaf: PaneID) async throws -> String {
        for _ in 0..<100 {
            if let handle = store.handle(for: leaf) as? RecordingPaneSession, let bytes = handle.sentBytes.first {
                return String(decoding: bytes, as: UTF8.self)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("shim launch bytes never arrived")
        return ""
    }
}
