// WorkspaceControlBackendTreeTests — pins the REAL `WorkspaceControlBackend` (not the dispatcher's FAKE
// backend) on the E20 ES-E20-1 / -3 surfaces the FAKE cannot catch: the tree → window/tab/pane mapping,
// the SHELL-QUOTED `jump` cd bytes (M7), the view/edit shim's new-leaf placement + quoted launch bytes,
// scrollback capture, the named-key send-keys table, and the font system/user scope classifier (M4).
//
// Revert-to-confirm-fail: every quoting assertion fails on the pre-fix backend (which emitted
// `cd /Users/x/My Project` / `less /tmp/my file.txt` raw, word-splitting on the space), and the scope
// assertions fail on the pre-fix `isSystem: true`-for-everything `listFonts`. None is tautological.
//
// Hang-safe (CLAUDE.md rule #6): a tree-model store over a recording in-memory fake, an isolated
// `PreferencesStore` + a temp-file `FolderFrecencyStore` — no socket, no GUI, no SCStream/VT/Metal/NSWindow.

import XCTest
@testable import AislopdeskClientUI
@testable import AislopdeskWorkspaceCore

/// A `PaneSessionHandle` that RECORDS the bytes/text routed to it (so the backend's verbatim+quoted cd /
/// shim / send-keys output is observable) and serves a seeded scrollback (so `pane capture` is observable).
@MainActor
final class RecordingPaneSession: @MainActor PaneSessionHandle, @MainActor Identifiable, PaneSessionIDAdopting {
    private(set) var id: PaneID
    let kind: PaneKind
    private(set) var isVideoActive = false
    private(set) var sentText: [String] = []
    private(set) var sentBytes: [[UInt8]] = []
    var scrollback: [String] = []

    init(_ spec: PaneSpec) {
        id = PaneID()
        kind = spec.kind
    }

    func adopt(id: PaneID) { self.id = id }
    func setVideoActive(_ active: Bool) { if kind.isVideo { isVideoActive = active } }
    func pause() {}
    func resume() {}
    func teardown() {}
    func sendText(_ text: String) { sentText.append(text) }
    func sendBytes(_ bytes: [UInt8]) { sentBytes.append(bytes) }
    func captureScrollback(lines count: Int) -> [String] {
        guard count > 0 else { return [] }
        return Array(scrollback.suffix(count))
    }
}

@MainActor
final class WorkspaceControlBackendTreeTests: XCTestCase {
    /// The backend holds `preferences` + `folders` WEAKLY (the app owns them); the test must retain them for
    /// the method's duration or `jump`/`learn` degrade to nil mid-test.
    private var retained: [AnyObject] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(liveModel: .tree, makeSession: { RecordingPaneSession($0) })
    }

    private func makeBackend(
        _ store: WorkspaceStore,
        shimGrace: Duration = .milliseconds(1500),
        _ name: String = #function,
    ) -> WorkspaceControlBackend {
        let suite = "WorkspaceControlBackendTreeTests." + name
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let prefs = PreferencesStore(defaults: defaults, sidecarURL: nil, applyOnInit: false)
        let folders = FolderFrecencyStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("frecency-\(UUID().uuidString).json"),
        )
        retained.append(prefs)
        retained.append(folders)
        return WorkspaceControlBackend(store: store, preferences: prefs, folders: folders, shimLaunchGrace: shimGrace)
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

    // MARK: - (a) tree → window / tab / pane mapping (ES-E20-1)

    func testTreeMapsToWindowsTabsPanes() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)
        store.tree = WorkspaceTreeOps.updatingSpec(focused, in: store.tree) { spec in
            spec.lastKnownCwd = "/work/proj"
            spec.lastKnownTitle = "vim"
        }
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
        XCTAssertEqual(pane.cwd, "/work/proj", "cwd maps from PaneSpec.lastKnownCwd")
        XCTAssertEqual(pane.title, "vim", "title maps from PaneSpec.lastKnownTitle")
        XCTAssertEqual(pane.kind, PaneKind.terminal.rawValue, "kind maps from PaneSpec.kind")
    }

    // MARK: - (b) jump emits a SHELL-QUOTED `cd -- '…'` (M7)

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

    // MARK: - (d) pane capture — last-N scrollback

    func testCapturePaneReturnsLastNLines() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)
        try recording(store, focused).scrollback = ["l1", "l2", "l3", "l4"]

        XCTAssertEqual(backend.capturePane(paneId: nil, lines: 2), ["l3", "l4"], "the last N lines")
        XCTAssertEqual(backend.capturePane(paneId: nil, lines: 10), ["l1", "l2", "l3", "l4"], "N over count = all")
    }

    // MARK: - (e) send-keys — verbatim text + named-key table

    func testSendKeysVerbatimTextThenNamedKeys() throws {
        let store = makeStore()
        let backend = makeBackend(store)
        let focused = try focusedLeaf(store)

        XCTAssertTrue(backend.sendKeys(paneId: nil, text: "echo hi", keys: ["enter", "tab", "esc", "up"]))
        let handle = try recording(store, focused)
        XCTAssertEqual(handle.sentText, ["echo hi"], "literal text is sent verbatim")
        XCTAssertEqual(
            handle.sentBytes,
            [[0x0D], [0x09], [0x1B], [0x1B, 0x5B, 0x41]],
            "named keys map to their keycode bytes (enter/tab/esc/up)",
        )
    }

    // MARK: - (f) font scope classifier (M4)

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
                // swiftlint:disable:next optional_data_string_conversion
                return String(decoding: bytes, as: UTF8.self)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("shim launch bytes never arrived")
        return ""
    }
}
