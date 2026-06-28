import XCTest
@testable import AislopdeskWorkspaceCore

/// E16 / WI-8 — the recipe STORE GLUE: save snapshots the live tree to a parseable `.ottyrecipe` whose
/// restore reproduces the tree; a commands-scope save gates on ≥ 1 command; the trust store skips the prompt
/// for a self-saved recipe but raises `recipes.pendingTrustPrompt` for an unfamiliar one; and the
/// `.saveRecipe` / `.openRecipe` actions route to the store's request entry points.
///
/// Headless: a `.tree`-live store backed by ``RecordingTerminalPaneSession`` (a REAL ``TerminalViewModel``
/// per `.terminal` pane, so recent OSC-133 commands can be seeded — no socket, no renderer, no NSWindow). All
/// file IO is pointed at a fresh temp dir via `recipes.environment` (no app container touched).
@MainActor
final class WorkspaceStoreRecipesTests: XCTestCase {
    // MARK: - Fixtures

    /// A fresh temp `HOME` per test (XCTest makes one instance per test method), so each test's recipe folder
    /// + trust store are isolated under a unique directory.
    private lazy var tempHome: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("aislopdesk-recipes-\(UUID().uuidString)", isDirectory: true)

    override func setUp() {
        super.setUp()
        // Pin the two Command-Replay modes so the end-to-end replay assertions are deterministic regardless of
        // a prior test's `Defaults` writes: saved recipes Auto (commands run immediately), files Ask-Once.
        UserDefaults.standard.set(RecipeReplayMode.auto.rawValue, forKey: SettingsKey.replayModeSavedKey)
        UserDefaults.standard.set(RecipeReplayMode.askOnce.rawValue, forKey: SettingsKey.replayModeFilesKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.replayModeSavedKey)
        UserDefaults.standard.removeObject(forKey: SettingsKey.replayModeFilesKey)
        try? FileManager.default.removeItem(at: tempHome)
        super.tearDown()
    }

    /// The strings injected into pane `id`'s recording terminal session, in call order (each replay command /
    /// cwd `cd` is one send of literal UTF-8).
    private func injected(_ store: WorkspaceStore, _ id: PaneID) throws -> [String] {
        let session = try XCTUnwrap(store.handle(for: id) as? RecordingTerminalPaneSession)
        return session.sentInput.compactMap { String(data: $0, encoding: .utf8) }
    }

    /// Drain the deferred (0 ms-grace) send Task(s) by yielding the main actor until pane `id` has recorded at
    /// least `count` sends or the budget runs out (mirrors `CwdInheritanceStoreTests.waitForBytes`).
    private func waitForInjected(_ store: WorkspaceStore, _ id: PaneID, atLeast count: Int) async throws {
        for _ in 0..<200 {
            if try injected(store, id).count >= count { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A `.tree`-live store with its recipe folders pointed at the per-test temp `HOME`.
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
        store.recipes.environment = ["HOME": tempHome.path]
        return store
    }

    private func activePane(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
    }

    /// Seed a captured command block into pane `id`'s live terminal model (the Include-Commands source).
    private func seedCommand(_ text: String, into id: PaneID, in store: WorkspaceStore, index: UInt32 = 0) throws {
        let session = try XCTUnwrap(store.handle(for: id) as? RecordingTerminalPaneSession)
        let model = try XCTUnwrap(session.terminalModel)
        model.blocks.upsert(
            index: index, commandText: text, exitCode: 0, durationMS: 1, complete: true, outputLen: 0,
        )
    }

    /// A structural fingerprint of a split tree IGNORING pane ids (axis + child arity, recursively) — so a
    /// restored tree (fresh ids) can be compared to the original by SHAPE.
    private func shape(_ node: SplitNode) -> String {
        switch node {
        case .leaf:
            return "L"
        case let .split(_, axis, children):
            let mark = axis == .horizontal ? "H" : "V"
            return "(\(mark):" + children.map { shape($0.node) }.joined(separator: ",") + ")"
        }
    }

    // MARK: - Save → parseable file that restores the tree

    /// `saveRecipe(.window, .layoutOnly)` writes a real `.ottyrecipe` whose bytes parse back into a recipe
    /// whose `restorePlan` reproduces the SHAPE of the saved tab (split axis + pane count preserved).
    /// REVERT-TO-CONFIRM-FAIL: with `saveRecipe` returning `nil` / writing nothing, no file exists to read.
    func testSaveWindowLayoutOnlyWritesParseableFileThatReproducesTree() throws {
        let store = makeStore()
        // Build a 2-pane tab (a horizontal split) so the round-trip carries a non-trivial topology.
        store.splitActivePane(axis: .horizontal, kind: .terminal)
        let originalRoot = try XCTUnwrap(store.tree.activeSession?.activeTab?.root)
        XCTAssertEqual(shape(originalRoot), "(H:L,L)", "the seeded tab is a 2-leaf horizontal split")

        let url = try XCTUnwrap(
            store.saveRecipe(scope: .window, content: .layoutOnly, name: "My Layout"),
            "a window/layout-only save writes a file and returns its URL",
        )
        XCTAssertEqual(url.pathExtension, "ottyrecipe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the recipe file is on disk")

        // Read the file back (the EXACT on-disk bytes) and parse it — proving it is well-formed.
        let file = try XCTUnwrap(RecipeLibrary.read(url: url))
        let recipe = try XCTUnwrap(file.recipe, "the written file parses back into a Recipe")
        XCTAssertEqual(recipe.scope, .window)
        XCTAssertEqual(recipe.window.tabs.count, 1, "one tab captured")
        XCTAssertEqual(recipe.window.tabs.first?.panes.count, 2, "both panes captured")
        // Layout-Only ⇒ no commands leaked into the file.
        XCTAssertTrue(recipe.allReplayCommands.isEmpty, "Layout-Only captures no commands")

        // The restore plan reproduces the saved tab's SHAPE (axis + arity), with fresh ids.
        let plan = RecipeBuilder.restorePlan(recipe)
        let restoredRoot = try XCTUnwrap(plan.tabs.first?.tree)
        XCTAssertEqual(shape(restoredRoot), shape(originalRoot), "restore reproduces the split-tree shape")
    }

    /// Opening a self-saved `.window` recipe actually MOUNTS the restored tree (a new session appended).
    func testSaveThenOpenWindowRecipeMountsARestoredSession() throws {
        let store = makeStore()
        store.splitActivePane(axis: .vertical, kind: .terminal)
        let sessionsBefore = store.tree.sessions.count

        let url = try XCTUnwrap(store.saveRecipe(scope: .window, content: .layoutOnly, name: "Two Up"))
        store.openRecipe(at: url, source: .savedLibrary)

        XCTAssertEqual(store.tree.sessions.count, sessionsBefore + 1, "open restores a NEW session")
        let restored = try XCTUnwrap(store.tree.activeSession)
        XCTAssertEqual(shape(restored.tabs[0].root), "(V:L,L)", "the restored tab is the saved 2-leaf split")
        XCTAssertNil(store.recipes.pendingTrustPrompt, "a Layout-Only recipe never prompts")
    }

    /// ES-E16-2 "restores working directories": opening a recipe whose pane captured a cwd `cd`s the restored
    /// pane into that directory (the safe-literal `cd` route `newTab` uses). Layout-Only ⇒ no replay, so the
    /// ONLY injection is the cwd `cd`.
    /// REVERT-TO-CONFIRM-FAIL: without `mountRestorePlan` deferring the inherited `cd`, the restored pane only
    /// carries `lastKnownCwd` as a metadata hint and the shell stays at $HOME (nothing injected).
    func testRestoredRecipePaneRestoresWorkingDirectory() async throws {
        let store = makeStore()
        let active = try activePane(store)
        store.setLastKnownCwd("/Users/me/proj", for: active)

        let url = try XCTUnwrap(store.saveRecipe(scope: .window, content: .layoutOnly, name: "Dir"))
        let before = Set(store.tree.allPaneIDs())
        store.openRecipe(at: url, source: .savedLibrary, launchGrace: .zero)

        let restoredPane = try XCTUnwrap(
            Set(store.tree.allPaneIDs()).subtracting(before).first, "open mints a fresh restored pane",
        )
        XCTAssertEqual(
            store.tree.spec(for: restoredPane)?.lastKnownCwd, "/Users/me/proj",
            "the restored pane carries the recipe's captured cwd",
        )
        try await waitForInjected(store, restoredPane, atLeast: 1)
        XCTAssertEqual(
            try injected(store, restoredPane), ["cd '/Users/me/proj'\n"],
            "the restored pane is `cd`-ed into the recipe's captured working directory",
        )
    }

    /// E16 handoff hazard: a `.window`/`.tab` recipe restore types each pane's captured cwd `cd` AHEAD of the
    /// replay burst (the parallel `deferInheritedCwd` stream), and that `cd` ALSO runs at the LOCAL prompt and
    /// emits its OWN OSC-133;D → `recipeReplayCommandCompleted`. The handoff-absorb counter must skip that extra
    /// completion, else it hits zero one edge EARLY and the post-`ssh` command injects into the inner session.
    /// With commands `[echo a, ssh host, echo b]` + a restored cwd the local-prompt completions are cd → echo a
    /// before `ssh host` exits — `echo b` must stay HELD until the THIRD completion (the ssh-exit edge).
    /// REVERT-TO-CONFIRM-FAIL: without folding the cwd `cd` into the absorb count, the absorb arms to 1 (not 2)
    /// and `echo b` injects on the SECOND completion (the `echo a` edge) — straight into the still-open `ssh`.
    func testRestoredCwdCdIsAbsorbedSoPostHandoffCommandWaitsForSshExit() async throws {
        let store = makeStore()
        let active = try activePane(store)
        store.setLastKnownCwd("/Users/me/proj", for: active)
        try seedCommand("echo a", into: active, in: store, index: 0)
        try seedCommand("ssh host", into: active, in: store, index: 1)
        try seedCommand("echo b", into: active, in: store, index: 2)

        // Saved-recipe default is Auto (pinned in setUp): the burst types ahead through the ssh handoff.
        let url = try XCTUnwrap(store.saveRecipe(scope: .window, content: .includeCommands, name: "Deploy"))
        let before = Set(store.tree.allPaneIDs())
        store.openRecipe(at: url, source: .savedLibrary, launchGrace: .zero)

        let restored = try XCTUnwrap(
            Set(store.tree.allPaneIDs()).subtracting(before).first, "open mints a fresh restored pane",
        )

        // Auto types ahead up to AND INCLUDING `ssh host`, then pauses on the handoff; `echo b` is held back.
        guard case .paused(.interactiveCommand("ssh host"))? = store.recipeReplayState(for: restored) else {
            XCTFail("the restored pane's queue pauses on the ssh handoff")
            return
        }
        // The absorb folds in BOTH the restored cwd `cd` AND the typed-ahead `echo a` (two local-prompt returns
        // before the ssh-exit edge). Pre-fix this armed to 1 (the burst's `echo a` only) and leaked `echo b`.
        XCTAssertEqual(
            store.recipes.replayHandoffAbsorb[restored], 2,
            "the restored cwd `cd` completion is folded into the handoff-absorb count alongside `echo a`",
        )
        XCTAssertFalse(try injected(store, restored).contains("echo b\n"), "echo b is held while paused on ssh")

        // 1st completion = the restored cwd `cd`'s OSC-133;D — ABSORBED (it ran at the local prompt, pre-ssh).
        store.recipeReplayCommandCompleted(for: restored)
        XCTAssertTrue(store.isReplayingRecipe(for: restored), "the cwd `cd` completion is absorbed — still paused")
        XCTAssertFalse(try injected(store, restored).contains("echo b\n"), "echo b still held after the `cd`")

        // 2nd completion = the typed-ahead `echo a`'s D — ALSO absorbed (it too ran at the local prompt).
        store.recipeReplayCommandCompleted(for: restored)
        XCTAssertTrue(store.isReplayingRecipe(for: restored), "echo a completion is absorbed — still behind ssh")
        XCTAssertFalse(
            try injected(store, restored).contains("echo b\n"),
            "echo b must NOT inject until ssh exits — folding the cwd `cd` into the absorb count holds it",
        )

        // 3rd completion = ssh exited → the local prompt returns → the queue resumes and injects the held one.
        store.recipeReplayCommandCompleted(for: restored)
        XCTAssertTrue(try injected(store, restored).contains("echo b\n"), "echo b injects only after ssh exits")
        XCTAssertFalse(store.isReplayingRecipe(for: restored), "replay finished after the post-handoff command")

        // The full typed-ahead stream eventually lands (the cwd `cd` is deferred via a Task even at .zero grace,
        // so its byte ordering vs the synchronous burst is a test artifact — assert membership, not order).
        try await waitForInjected(store, restored, atLeast: 4)
        XCTAssertEqual(
            try Set(injected(store, restored)),
            ["cd '/Users/me/proj'\n", "echo a\n", "ssh host\n", "echo b\n"],
            "the restored cwd `cd`, the typed-ahead burst, and the resumed echo b all land",
        )
    }

    // MARK: - Commands-scope gate (≥ 1 command)

    /// `saveRecipe(.commands)` REQUIRES at least one recent command: with none captured it returns `nil` and
    /// writes nothing; after a command lands it writes a parseable commands recipe.
    /// REVERT-TO-CONFIRM-FAIL: drop the `scope == .commands` empty-gate and the empty save would write a
    /// hollow file (the first assertion's `nil` flips).
    func testSaveCommandsScopeRequiresAtLeastOneCommand() throws {
        let store = makeStore()
        let active = try activePane(store)

        // No command captured yet ⇒ the commands-scope save is refused.
        XCTAssertNil(
            store.saveRecipe(scope: .commands, content: .includeCommands, name: "No Cmds"),
            "a commands recipe with nothing to replay is not written",
        )

        // Seed a command, then the save succeeds and the file carries it.
        try seedCommand("npm run build", into: active, in: store)
        let url = try XCTUnwrap(
            store.saveRecipe(scope: .commands, content: .includeCommands, name: "Build"),
            "with ≥ 1 command the commands recipe writes",
        )
        let recipe = try XCTUnwrap(RecipeLibrary.read(url: url)?.recipe)
        XCTAssertEqual(recipe.scope, .commands)
        XCTAssertEqual(recipe.allReplayCommands, ["npm run build"], "the captured command round-trips")
    }

    // MARK: - Trust: self-saved skips the prompt; foreign raises it

    /// Opening a recipe THIS store just saved (recorded trusted, origin self-saved) does NOT prompt — it
    /// restores AND (the WI-8 → WI-9 wiring) actually replays its commands into the live pane through the REAL
    /// open path. The Auto (saved-recipe default) burst injects `ls -la` verbatim and the queue is consumed.
    /// REVERT-TO-CONFIRM-FAIL: without `applyTrustedRecipe` starting replay the command sits in
    /// `pendingRecipeReplay` and the pane receives nothing.
    func testOpeningSelfSavedRecipeReplaysCommandsIntoThePane() throws {
        let store = makeStore()
        let active = try activePane(store)
        try seedCommand("ls -la", into: active, in: store)

        let url = try XCTUnwrap(store.saveRecipe(scope: .commands, content: .includeCommands, name: "List"))
        store.openRecipe(at: url, source: .savedLibrary, launchGrace: .zero)

        XCTAssertNil(store.recipes.pendingTrustPrompt, "a self-saved recipe bypasses the trust prompt")
        XCTAssertNil(store.recipes.pendingRecipeReplay, "the replay queue is consumed once replay starts")
        XCTAssertEqual(
            try injected(store, active), ["ls -la\n"],
            "the self-saved Auto recipe's command is replayed verbatim (+ one newline) into the active pane",
        )
    }

    /// Opening an UNFAMILIAR `.ottyrecipe` whose commands the store has never trusted raises the trust prompt
    /// (commands shown) and runs NOTHING until the user resolves it.
    /// REVERT-TO-CONFIRM-FAIL: route the trusted branch unconditionally and `pendingTrustPrompt` stays nil.
    func testOpeningForeignRecipeWithCommandsSetsPendingTrustPrompt() throws {
        let store = makeStore()
        let active = try activePane(store)
        let foreign = Recipe(
            name: "deploy-prod",
            scope: .commands,
            window: RecipeWindow(tabs: [RecipeTab(panes: [RecipePane(commands: ["ssh prod", "deploy"])])]),
        )
        let bytes = Array(RecipeTOMLCodec.emit(foreign).utf8)

        store.openRecipe(bytes: bytes, source: .file)

        let prompt = try XCTUnwrap(store.recipes.pendingTrustPrompt, "an unfamiliar recipe with commands prompts")
        XCTAssertEqual(prompt.commands, ["ssh prod", "deploy"], "the prompt shows the commands first")
        XCTAssertNil(store.recipes.pendingRecipeReplay, "nothing is queued until the user trusts it")
        XCTAssertFalse(store.isReplayingRecipe(for: active), "and nothing replays until the user trusts it")

        // Run-Once proceeds without persisting; the prompt clears and the commands replay starts (Ask-Once for
        // files — the machine installs and awaits the user's Enter, so the queue is consumed but no command has
        // been injected yet).
        store.confirmTrust(alwaysTrust: false, launchGrace: .zero)
        XCTAssertNil(store.recipes.pendingTrustPrompt, "confirming clears the prompt")
        XCTAssertNil(store.recipes.pendingRecipeReplay, "the replay queue is consumed once replay starts")
        XCTAssertTrue(store.isReplayingRecipe(for: active), "after trusting, replay is in flight")
        XCTAssertEqual(try injected(store, active), [], "Ask-Once injects nothing until the user's Enter")
    }

    /// A foreign recipe the user Cancels is dropped — nothing runs, nothing is queued.
    func testCancelTrustDropsTheRecipe() {
        let store = makeStore()
        let foreign = Recipe(
            name: "x", scope: .commands,
            window: RecipeWindow(tabs: [RecipeTab(panes: [RecipePane(commands: ["rm -rf /"])])]),
        )
        store.openRecipe(bytes: Array(RecipeTOMLCodec.emit(foreign).utf8), source: .file)
        XCTAssertNotNil(store.recipes.pendingTrustPrompt)
        store.cancelTrust()
        XCTAssertNil(store.recipes.pendingTrustPrompt, "cancel clears the prompt")
        XCTAssertNil(store.recipes.pendingRecipeReplay, "cancel runs nothing")
    }

    // MARK: - Action routing + chord

    /// `.saveRecipe` / `.openRecipe` route to the store's request entry points (the app then presents the
    /// matching sheet off these flags).
    func testRecipeActionsRouteToTheirRequestEntryPoints() {
        let store = makeStore()
        XCTAssertFalse(store.recipes.pendingSaveRecipe)
        WorkspaceBindingRegistry.route(.saveRecipe, to: store)
        XCTAssertTrue(store.recipes.pendingSaveRecipe, ".saveRecipe → requestSaveRecipe()")

        XCTAssertFalse(store.recipes.pendingOpenRecipe)
        WorkspaceBindingRegistry.route(.openRecipe, to: store)
        XCTAssertTrue(store.recipes.pendingOpenRecipe, ".openRecipe → requestOpenRecipe()")
    }

    /// ⌘S resolves to `.saveRecipe` through the live dispatcher table (the NSEvent dispatcher's source), and
    /// the recipe verbs carry NO display binding row (the menu is shortcut-less).
    /// REVERT-TO-CONFIRM-FAIL: without the alias-chord entry, ⌘S resolves to nil.
    func testSaveRecipeChordResolvesAndIsDisplayRowLess() {
        XCTAssertEqual(
            WorkspaceBindingRegistry.resolvedChordTable[KeyChord(character: "s", [.command])],
            .saveRecipe,
            "⌘S fires Save Recipe via the dispatcher (aliasChords)",
        )
        XCTAssertNil(
            WorkspaceBindingRegistry.binding(for: .saveRecipe),
            "Save Recipe has no display binding row (the menu is shortcut-less)",
        )
        XCTAssertNil(WorkspaceBindingRegistry.binding(for: .openRecipe), "Open Recipe is menu/palette only")
    }

    // MARK: - WI-10: curated commands-scope save + the open-picker library list

    /// The save sheet's commands-scope sub-list (tick + inline-edit) hands `saveRecipe` a CURATED list that
    /// REPLACES the auto-captured commands, with blank entries dropped.
    /// REVERT-TO-CONFIRM-FAIL: without the `commands:` override, the file carries the auto-captured commands.
    func testSaveCommandsScopeUsesCuratedCommandsOverride() throws {
        let store = makeStore()
        let active = try activePane(store)
        try seedCommand("npm run build", into: active, in: store, index: 0)
        try seedCommand("npm test", into: active, in: store, index: 1)

        let url = try XCTUnwrap(store.saveRecipe(
            scope: .commands, content: .includeCommands, name: "Curated",
            commands: ["npm run build --prod", "   "],
        ))
        let recipe = try XCTUnwrap(RecipeLibrary.read(url: url)?.recipe)
        XCTAssertEqual(
            recipe.allReplayCommands, ["npm run build --prod"],
            "the curated + inline-edited command replaces the auto-captured list; the blank entry is dropped",
        )
    }

    /// A commands-scope save with NOTHING ticked (an empty curated list) is refused — no hollow recipe.
    func testSaveCommandsScopeWithEmptyCuratedListIsRefused() throws {
        let store = makeStore()
        let active = try activePane(store)
        try seedCommand("rm -rf /", into: active, in: store)
        XCTAssertNil(
            store.saveRecipe(scope: .commands, content: .includeCommands, name: "Empty", commands: []),
            "an empty curated commands list writes nothing",
        )
    }

    /// `savedRecipeFiles()` lists the written library recipes (the Open-Recipe picker's in-app source).
    func testSavedRecipeFilesListsWrittenRecipes() throws {
        let store = makeStore()
        XCTAssertTrue(store.savedRecipeFiles().isEmpty, "no recipes saved yet → an empty library list")
        _ = try XCTUnwrap(store.saveRecipe(scope: .window, content: .layoutOnly, name: "Layout A"))
        let files = store.savedRecipeFiles()
        XCTAssertEqual(files.count, 1, "the saved recipe shows in the library list")
        XCTAssertEqual(files.first?.recipe?.name, "Layout A", "parsed back with its name")
    }
}
