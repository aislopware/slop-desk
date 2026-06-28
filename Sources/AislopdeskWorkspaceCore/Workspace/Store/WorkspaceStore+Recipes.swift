import Foundation

// MARK: - Recipe glue value types (the save-flow / open-flow vocabulary the store + the app share)

/// What a ⌘S save captures, ORTHOGONAL to ``RecipeScope`` (which picks tab vs window vs commands-only). The
/// save sheet (WI-10) offers Layout Only / Include Commands (Include Scrollback is greyed honestly until the
/// scrollback-serialisation seam lands — see the plan's pinned deferrals).
public enum RecipeSaveContent: String, Sendable, Equatable, CaseIterable {
    /// Capture the layout only — every pane's `commands` stays empty.
    case layoutOnly
    /// Also capture each pane's recent OSC-133 commands for replay-on-open.
    case includeCommands
    /// Reserved: also capture scrollback (deferred — treated as ``layoutOnly`` here until the seam exists).
    case includeScrollback
}

/// Where an opened recipe came from — selects which Command-Replay default applies (saved recipes follow
/// ``SettingsKey/replayModeSaved``, external files follow ``SettingsKey/replayModeFiles``).
public enum RecipeSource: Sendable, Equatable {
    /// An internally-saved recipe from the library (`~/.config/aislopdesk/recipes/`).
    case savedLibrary
    /// An externally-opened `.ottyrecipe` file (Finder drop / File ▸ Open Recipe…).
    case file
}

/// The state behind the command-replay TRUST prompt: an unfamiliar recipe whose commands must be shown
/// before anything runs. Carries everything ``WorkspaceStore/confirmTrust(alwaysTrust:)`` needs to proceed
/// (Always-Trust persists by ``hash``; Run-Once proceeds without persisting; Cancel drops it).
public struct RecipeTrustPrompt: Sendable, Equatable {
    /// The parsed recipe to restore once trusted.
    public var recipe: Recipe
    /// The exact on-disk bytes (the trust checksum input — ``hash`` is `sha256Hex(bytes)`).
    public var bytes: [UInt8]
    /// The SHA-256 checksum of ``bytes`` (the trust-store key).
    public var hash: String
    /// The commands shown to the user (every pane's commands, in tree order) — the trust sheet's list.
    public var commands: [String]
    /// Whether the recipe came from the library or a file (selects the replay-mode default on confirm).
    public var source: RecipeSource
    /// The folder containing the `.ottyrecipe` (resolves `{{recipe_location}}` cwds on restore); `""` for a
    /// library/in-memory recipe.
    public var recipeLocation: String

    public init(
        recipe: Recipe, bytes: [UInt8], hash: String, commands: [String],
        source: RecipeSource, recipeLocation: String,
    ) {
        self.recipe = recipe
        self.bytes = bytes
        self.hash = hash
        self.commands = commands
        self.source = source
        self.recipeLocation = recipeLocation
    }
}

/// The bundled runtime state for the recipe glue — held as ONE ``WorkspaceStore`` stored property (the
/// ``BlockBookmarkSeam`` idiom) so the store's class body stays under the lint type-body ceiling. The app
/// observes its `pending*` fields (via `@Observable` on the owning store) to present the save / trust / open
/// surfaces; ``environment`` is injectable so a headless test points the file engine at a temp dir.
public struct RecipeRuntimeState: Sendable {
    /// The environment the recipe file engine resolves its folders from (`~/.config/aislopdesk/recipes/` +
    /// `~/Library/Application Support/Aislopdesk/trusted_recipes.json`). Injectable for tests.
    public var environment: [String: String] = ProcessInfo.processInfo.environment
    /// Set by ⌘S / File ▸ Recipe ▸ Save Recipe… — the app presents the save sheet off it.
    public var pendingSaveRecipe = false
    /// Set by File ▸ Recipe ▸ Open Recipe… — the app presents the open picker / `.fileImporter` off it.
    public var pendingOpenRecipe = false
    /// Set when opening an UNFAMILIAR recipe whose commands need the trust prompt (Always-Trust / Run-Once /
    /// Cancel); `nil` while no prompt is pending.
    public var pendingTrustPrompt: RecipeTrustPrompt?
    /// The commands a just-restored recipe queued for replay, per restored pane (WI-9 consumes + clears it);
    /// `nil` when the opened recipe carried no commands (Layout-Only).
    public var pendingRecipeReplay: RecipeReplayRequest?
    /// The LIVE per-pane replay state machines WI-9 drives against the PTY (one ``RecipeReplayMachine`` per
    /// restored pane with commands). A pane is present only while its replay is mid-flight — ``beginRecipeReplay(launchGrace:)``
    /// installs it, and ``recipeReplayCommandCompleted(for:)`` / ``continueRecipeReplay(for:)`` remove it once
    /// the machine finishes. The UI reads ``WorkspaceStore/recipeReplayState(for:)`` off it for the replay HUD.
    public var replayMachines: [PaneID: RecipeReplayMachine] = [:]
    /// Per-pane count of typed-ahead command completions to ABSORB before the shell-handoff resume edge fires.
    /// An Auto / Ask-Once burst types every SAFE command up to AND INCLUDING the interactive one (the machine's
    /// drain), so the local shell returns to a prompt once per typed-ahead command; only the INTERACTIVE
    /// command's return-to-prompt should resume the queue. This counter skips the earlier completions so the
    /// post-handoff command is never injected into the inner (ssh / docker / …) session. Keyed by pane.
    public var replayHandoffAbsorb: [PaneID: Int] = [:]
    /// Per-pane count of restored-cwd `cd`s typed-ahead into a pane BEFORE its replay burst (the parallel
    /// ``WorkspaceStore/mountRestorePlan(_:name:launchGrace:)`` `deferInheritedCwd` stream). Each such `cd` runs
    /// at the SAME local prompt and emits its own OSC-133;D, so the handoff-absorb counter must skip those
    /// completions too — otherwise the absorb hits zero one edge early and the post-handoff command injects into
    /// the inner (ssh / docker / …) session. ``beginRecipeReplay(launchGrace:)`` consumes + clears this when it
    /// arms each pane's machine. Keyed by pane.
    public var replayPreInjectedCwds: [PaneID: Int] = [:]

    public init() {}
}

/// The replay queue a just-restored recipe hands to the WI-9 replay-execution wiring: the resolved
/// ``RecipeReplayMode`` plus the commands to replay PER restored pane (only panes with ≥ 1 command). WI-9
/// drives a ``RecipeReplayMachine`` per pane against the live PTY (verbatim, with the shell-handoff pause).
public struct RecipeReplayRequest: Sendable, Equatable {
    /// The replay mode (Auto / Ask-Once / Manually / Skip) resolved from the recipe source.
    public var mode: RecipeReplayMode
    /// The commands to replay, keyed by the restored pane id (the SAME ids the mounted tree carries).
    public var commandsByPane: [PaneID: [String]]

    public init(mode: RecipeReplayMode, commandsByPane: [PaneID: [String]]) {
        self.mode = mode
        self.commandsByPane = commandsByPane
    }
}

/// What the in-pane replay HUD shows for a pane with an in-flight replay that NEEDS the user — the live
/// affordance whose single button drives ``WorkspaceStore/continueRecipeReplay(for:)`` keyed by the banner's
/// own pane (a multi-pane recipe shows one banner per pane, each advancing its OWN machine). A pure
/// projection of the per-pane ``RecipeReplayMachine`` so the banner is a thin renderer and the
/// show / label / preview decision is unit-tested headlessly (no NSWindow). ``WorkspaceStore/recipeReplayPrompt(for:)``
/// returns `nil` whenever no banner should show (no replay, or an Auto / Skip run mid-drain that needs no
/// user action). This is THE surface that makes Ask-Once / Manually reachable: without a control reading it,
/// those two modes (Ask-Once is the DEFAULT for opened `.ottyrecipe` files) queue their commands and never run.
public struct RecipeReplayPrompt: Equatable, Sendable {
    /// Which kind of confirmation the banner is asking for (so the UI + tests branch without string-matching).
    public enum Kind: Equatable, Sendable {
        /// Ask-Once, before the first run — one confirm runs the WHOLE remaining queue.
        case awaitingAskOnce
        /// Manually — one confirm runs exactly the NEXT command.
        case awaitingManual
        /// Auto / Ask-Once paused right after an interactive (`ssh`/…) command — continue past the handoff.
        case pausedHandoff
        /// An explicit (store / user) pause — continue resumes the queue.
        case pausedManual
    }

    /// The confirmation kind (drives the banner copy + the test branch).
    public var kind: Kind
    /// The single live button's label ("Run" / "Run Next" / "Continue").
    public var actionLabel: String
    /// The headline copy shown beside the button.
    public var message: String
    /// The not-yet-run commands (the Ask-Once preview / the held post-handoff commands), in order.
    public var commands: [String]

    public init(kind: Kind, actionLabel: String, message: String, commands: [String]) {
        self.kind = kind
        self.actionLabel = actionLabel
        self.message = message
        self.commands = commands
    }
}

// MARK: - WorkspaceStore × Recipes (E16 WI-8 — save / open / library / trust)

/// The recipe store glue: the seven live surfaces (⌘S, File ▸ Recipe, palette, the save sheet, the trust
/// sheet, the open picker, replay) all meet here. SAVE snapshots the live tree (``RecipeBuilder/snapshot``)
/// → emits TOML (``RecipeTOMLCodec/emit(_:)``) → writes the file (``RecipeLibrary/write(_:to:slug:)``) and
/// records it trusted (self-saved). OPEN reads bytes → parses → consults the trust store → either restores
/// the layout (``RecipeBuilder/restorePlan(_:home:currentFolder:recipeLocation:)`` → tree mount +
/// ``reconcileTree()``) and queues the commands for replay, or sets ``pendingTrustPrompt`` so the commands
/// are shown first.
///
/// **Wire posture:** 100% client-side — nothing here touches the wire / golden corpus.
public extension WorkspaceStore {
    // MARK: - Recent commands (the Include-Commands / commands-scope source)

    /// The recent OSC-133 commands captured in pane `id`'s ``TerminalBlockModel``, OLDEST-FIRST (the replay
    /// order), with blank entries dropped. Empty for a non-terminal pane / an empty shell.
    func recentCommands(for id: PaneID) -> [String] {
        guard let provider = handle(for: id) as? TerminalModelProviding,
              let model = provider.terminalModel else { return [] }
        return model.blocks.blocks
            .map { $0.commandText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The active pane's recent commands (oldest-first) — the commands-scope replay source.
    func recentCommandsForReplay() -> [String] {
        guard let id = activePaneID else { return [] }
        return recentCommands(for: id)
    }

    /// Recent commands for EVERY leaf in the active session, keyed by pane id (Include-Commands across a tab /
    /// window snapshot). Panes with no commands are omitted, so a Layout-Only emit stays clean.
    func recentCommandsForActiveSession() -> [PaneID: [String]] {
        guard let session = tree.activeSession else { return [:] }
        var map: [PaneID: [String]] = [:]
        for id in session.allPaneIDs() {
            let commands = recentCommands(for: id)
            if !commands.isEmpty { map[id] = commands }
        }
        return map
    }

    // MARK: - Save

    /// Requests the ⌘S save sheet (the command-layer entry point); the app presents it off
    /// `recipes.pendingSaveRecipe`.
    func requestSaveRecipe() { recipes.pendingSaveRecipe = true }
    /// The app consumed the save-sheet request (presented / dismissed it).
    func clearSaveRecipeRequest() { recipes.pendingSaveRecipe = false }

    /// Snapshot the live tree into a `.ottyrecipe` and write it to the recipes library, returning the written
    /// URL (or `nil` on failure / an empty commands-scope save).
    ///
    /// - `scope`: `.tab` (the focused tab), `.window` (every tab), or `.commands` (the focused pane's recent
    ///   commands only).
    /// - `content`: `.includeCommands` also captures recent commands; `.layoutOnly` leaves them empty.
    ///   `.commands` scope IMPLIES include-commands and REQUIRES ≥ 1 command (else `nil` — a commands recipe
    ///   with nothing to replay is meaningless).
    /// - `portable`: portabilize each pane's cwd against `$HOME` / the active cwd.
    /// - `directory`: override the destination (the save sheet's "save as…"); default is the library folder.
    /// - `commands`: the save sheet's CURATED commands-scope list (the ticked + inline-edited recent commands).
    ///   When supplied for `.commands` scope it REPLACES the focused pane's auto-captured commands (blank /
    ///   whitespace entries dropped); `nil` (the default) keeps the WI-8 auto-capture from the block model.
    ///
    /// The written file's bytes are recorded TRUSTED (self-saved) so re-opening it never prompts.
    @discardableResult
    func saveRecipe(
        scope: RecipeScope,
        content: RecipeSaveContent,
        name: String,
        portable: Bool = false,
        directory: URL? = nil,
        commands: [String]? = nil,
    ) -> URL? {
        guard let session = tree.activeSession else { return nil }
        let includeCommands = content == .includeCommands || scope == .commands
        var commandsByPane = includeCommands ? recentCommandsForActiveSession() : [:]

        // E16 WI-10: the save sheet's commands-scope sub-list lets the user tick + inline-edit which recent
        // commands to capture; a curated list REPLACES the focused pane's auto-captured commands (blank entries
        // dropped). `nil` (no curation / a tab/window save) keeps the auto-capture untouched.
        if scope == .commands, let curated = commands, let focused = session.activeTab?.activePane {
            commandsByPane[focused] = curated
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        // Commands-scope gate (the plan's "≥ 1 command"): nothing to replay ⇒ don't write a hollow recipe.
        if scope == .commands {
            let focused = session.activeTab?.activePane
            let focusedCommands = focused.flatMap { commandsByPane[$0] } ?? []
            if focusedCommands.isEmpty { return nil }
        }

        let recipe = RecipeBuilder.snapshot(
            session: session, scope: scope, name: name,
            recentCommands: commandsByPane, portable: portable,
            home: recipeHome, currentFolder: activePaneCwd ?? "",
        )

        guard let dir = directory ?? RecipeLibrary.recipesDirectoryURL(environment: recipes.environment) else {
            return nil
        }
        let slug = RecipeLibrary.uniqueSlug(
            RecipeLibrary.slugify(name), existing: RecipeLibrary.existingSlugs(in: dir),
        )
        guard let result = try? RecipeLibrary.write(recipe, to: dir, slug: slug) else { return nil }
        persistTrust(hash: RecipeTrustStore.sha256Hex(result.bytes), name: name, origin: .selfSaved)
        return result.url
    }

    // MARK: - Open

    /// Requests the File ▸ Open Recipe… picker; the app presents it off `recipes.pendingOpenRecipe`.
    func requestOpenRecipe() { recipes.pendingOpenRecipe = true }
    /// The app consumed the open-picker request.
    func clearOpenRecipeRequest() { recipes.pendingOpenRecipe = false }

    /// The saved `.ottyrecipe` files in the library folder (`~/.config/aislopdesk/recipes/`) — the Open-Recipe
    /// picker's in-app list, parsed + sorted by filename. A malformed file keeps its slot with a `nil`
    /// ``RecipeLibrary/RecipeFile/recipe`` so the picker can grey it honestly; an absent folder yields `[]`.
    func savedRecipeFiles() -> [RecipeLibrary.RecipeFile] {
        guard let dir = RecipeLibrary.recipesDirectoryURL(environment: recipes.environment) else { return [] }
        return RecipeLibrary.scan(directory: dir)
    }

    /// Open a `.ottyrecipe` from a library file (resolving its on-disk location for `{{recipe_location}}`).
    /// `launchGrace` defers the restored panes' cwd `cd` + the command replay (the production default lets a
    /// freshly-mounted shell's prompt come up first); a test injects `.zero` for a synchronous read.
    func openRecipe(at url: URL, source: RecipeSource = .file, launchGrace: Duration = .milliseconds(1400)) {
        guard let file = RecipeLibrary.read(url: url) else { return }
        openRecipe(
            bytes: file.bytes, source: source,
            recipeLocation: url.deletingLastPathComponent().path, launchGrace: launchGrace,
        )
    }

    /// Open a recipe from raw bytes: parse (validate-then-drop), then — if it carries commands — consult the
    /// trust store. A trusted (or self-saved) recipe restores immediately; an unfamiliar one sets
    /// ``pendingTrustPrompt`` so the commands are shown first. A Layout-Only recipe (no commands) restores
    /// straight away (nothing to trust). A malformed file is silently dropped. `launchGrace` flows through to
    /// the restore (cwd `cd`) + replay; tests pass `.zero`.
    func openRecipe(
        bytes: [UInt8], source: RecipeSource = .file, recipeLocation: String = "",
        launchGrace: Duration = .milliseconds(1400),
    ) {
        // Non-UTF-8 / malformed bytes are dropped (validate-then-drop on an untrusted file).
        guard let text = String(bytes: bytes, encoding: .utf8),
              let recipe = RecipeTOMLCodec.parse(text) else { return }
        let commands = recipe.allReplayCommands

        // No commands ⇒ no replay-safety question; restore the layout directly.
        guard !commands.isEmpty else {
            applyTrustedRecipe(recipe, source: source, recipeLocation: recipeLocation, launchGrace: launchGrace)
            return
        }

        let hash = RecipeTrustStore.sha256Hex(bytes)
        switch trustStore().decision(forHash: hash, settingsMode: replayMode(for: source)) {
        case .trusted:
            applyTrustedRecipe(recipe, source: source, recipeLocation: recipeLocation, launchGrace: launchGrace)
        case .prompt:
            recipes.pendingTrustPrompt = RecipeTrustPrompt(
                recipe: recipe, bytes: bytes, hash: hash, commands: commands,
                source: source, recipeLocation: recipeLocation,
            )
        }
    }

    // MARK: - Trust prompt resolution

    /// Resolve a pending trust prompt by proceeding with the restore. `alwaysTrust` persists the recipe's
    /// hash (so future opens skip the prompt); a Run-Once proceeds WITHOUT persisting. A no-op when no prompt
    /// is pending. `launchGrace` flows through to the restore (cwd `cd`) + replay; tests pass `.zero`.
    func confirmTrust(alwaysTrust: Bool, launchGrace: Duration = .milliseconds(1400)) {
        guard let prompt = recipes.pendingTrustPrompt else { return }
        if alwaysTrust {
            persistTrust(hash: prompt.hash, name: prompt.recipe.name, origin: .alwaysTrust)
        }
        recipes.pendingTrustPrompt = nil
        applyTrustedRecipe(
            prompt.recipe, source: prompt.source, recipeLocation: prompt.recipeLocation, launchGrace: launchGrace,
        )
    }

    /// Dismiss the trust prompt without running anything (Cancel).
    func cancelTrust() { recipes.pendingTrustPrompt = nil }

    /// The app consumed the replay queue (drove the ``RecipeReplayMachine``s) — clears the pending replay.
    func clearRecipeReplay() { recipes.pendingRecipeReplay = nil }

    // MARK: - Replay execution (WI-9 — drive the machine against the live PTY)

    /// Begin replaying a just-restored recipe's queued commands: consume ``RecipeRuntimeState/pendingRecipeReplay``
    /// and install one ``RecipeReplayMachine`` per restored pane, injecting each machine's opening burst into
    /// that pane's live PTY.
    ///
    /// INJECTION is VERBATIM through the existing terminal input seam — each command is encoded with
    /// ``BlockReRunEncoder`` (literal UTF-8 + exactly one `\n`, NEVER ``SendKeysParser``, so a captured
    /// command that literally contains `<Enter>` / a quoted path can't be turned into control bytes — the
    /// injection-safety invariant ``reRunCommandInActivePane(_:)`` shares) and handed to
    /// ``TerminalViewModel/sendInput(_:)`` (wire type 3 — no host / wire change). The pane's working directory
    /// is established at RESTORE time via the safe-literal `cd` builder (``SessionTemplateEngine/launchBytes(cwd:command:)``,
    /// `command: nil`), so replay never re-tokenizes a path.
    ///
    /// `launchGrace` defers the opening burst (the default 1400 ms lets a freshly-restored remote shell's
    /// prompt come up first — the SAME grace ``newSessionFromTemplate(_:)`` uses); a `.zero` grace injects
    /// synchronously (tests). The machine STATE is advanced synchronously regardless, so the handoff-absorb
    /// counter is armed before any completion edge can arrive.
    func beginRecipeReplay(launchGrace: Duration = .milliseconds(1400)) {
        // Snapshot + clear the restored-cwd `cd` pre-injects (set by `mountRestorePlan` for THIS restore) so each
        // pane's machine folds its own `cd` completion(s) into the handoff-absorb count, and no entry survives
        // the restore (a Layout-Only / Skip restore that queues no replay still clears them here).
        let preInjected = recipes.replayPreInjectedCwds
        recipes.replayPreInjectedCwds = [:]
        guard let request = recipes.pendingRecipeReplay else { return }
        recipes.pendingRecipeReplay = nil
        for (pane, commands) in request.commandsByPane {
            var machine = RecipeReplayMachine(mode: request.mode, commands: commands)
            let burst = machine.start()
            recordReplayProgress(machine, burst: burst, for: pane, extraAbsorb: preInjected[pane] ?? 0)
            deliverReplayBurst(burst, into: pane, launchGrace: launchGrace)
        }
    }

    /// The shell-handoff resume edge — call on each OSC-133;D command-completion (the local-prompt-return
    /// signal) for pane `id`. A typed-ahead non-interactive command's completion is ABSORBED (the burst types
    /// several commands ahead — only the INTERACTIVE command's return resumes); once the absorb counter
    /// reaches zero the machine's ``RecipeReplayMachine/noteReturnedToPrompt()`` resumes the queue and the next
    /// burst is injected. A no-op for a pane with no live replay. Returns the commands this edge injected
    /// (for tests / a HUD).
    @discardableResult
    func recipeReplayCommandCompleted(for id: PaneID) -> [String] {
        guard var machine = recipes.replayMachines[id] else { return [] }
        if let absorb = recipes.replayHandoffAbsorb[id], absorb > 0 {
            recipes.replayHandoffAbsorb[id] = absorb - 1
            return []
        }
        let resumed = machine.noteReturnedToPrompt()
        recordReplayProgress(machine, burst: resumed, for: id)
        injectRecipeCommands(resumed, into: id)
        return resumed
    }

    /// The manual-continue edge for pane `id` — the user's Enter in Manually mode, the single Enter in
    /// Ask-Once, or a manual "continue" out of a handoff pause. Drives ``RecipeReplayMachine/confirm()`` and
    /// injects whatever it returns (one command in Manually, the rest of the queue in Ask-Once / a resume).
    /// A no-op for a pane with no live replay. Returns the commands injected.
    @discardableResult
    func continueRecipeReplay(for id: PaneID) -> [String] {
        guard var machine = recipes.replayMachines[id] else { return [] }
        let injected = machine.confirm()
        recordReplayProgress(machine, burst: injected, for: id)
        injectRecipeCommands(injected, into: id)
        return injected
    }

    /// The manual-continue edge for the ACTIVE pane (a ⌘-driven "continue replay" / the HUD button). Resolves
    /// the active pane id and routes to ``continueRecipeReplay(for:)``; a no-op when nothing is replaying there.
    func continueRecipeReplayInActivePane() {
        guard let id = activePaneID else { return }
        continueRecipeReplay(for: id)
    }

    /// The live replay state for pane `id` (`nil` when no replay is in flight) — the UI reads it to show the
    /// "replaying / paused after `ssh prod` / awaiting Enter" HUD and to gate the Continue control.
    func recipeReplayState(for id: PaneID) -> RecipeReplayMachine.State? {
        recipes.replayMachines[id]?.state
    }

    /// Whether pane `id` currently has a replay in flight (the HUD / Continue-control visibility gate).
    func isReplayingRecipe(for id: PaneID) -> Bool {
        recipes.replayMachines[id] != nil
    }

    /// The live replay-HUD content for pane `id`, or `nil` when no banner should show. The in-pane
    /// ``RecipeReplayHUD`` renders this and wires its button to ``continueRecipeReplay(for:)`` keyed by THAT
    /// banner's own pane (a banner is mounted per pane with a pending prompt, so a multi-pane recipe advances
    /// the correct machine per banner, never the active pane's). Surfaces a banner for the two modes that
    /// block on the user (Ask-Once before its single run, Manually before each command) and for a shell-handoff
    /// pause (so the user can continue past an `ssh`/… even when the prompt-return edge never arrives). Auto
    /// while draining and Skip surface NOTHING (no user action is owed); a finished / idle machine surfaces
    /// nothing either. Pure projection of the machine — no I/O, no view, so the show/label decision is tested
    /// headlessly. 100% client-side — no wire / golden touch.
    func recipeReplayPrompt(for id: PaneID) -> RecipeReplayPrompt? {
        guard let machine = recipes.replayMachines[id] else { return nil }
        let pending = machine.pendingCommands
        switch machine.state {
        case .awaitingConfirmation:
            switch machine.mode {
            case .manually:
                return RecipeReplayPrompt(
                    kind: .awaitingManual, actionLabel: "Run Next",
                    message: "Manual replay — \(Self.replayCountPhrase(pending.count)) left.",
                    commands: pending,
                )
            default:
                return RecipeReplayPrompt(
                    kind: .awaitingAskOnce, actionLabel: "Run",
                    message: "\(Self.replayCountPhrase(pending.count)) from this recipe ready to run.",
                    commands: pending,
                )
            }
        case let .paused(.interactiveCommand(command)):
            return RecipeReplayPrompt(
                kind: .pausedHandoff, actionLabel: "Continue",
                message: "Paused after “\(command)”. Continue when the prompt returns.",
                commands: pending,
            )
        case .paused(.manual):
            return RecipeReplayPrompt(
                kind: .pausedManual, actionLabel: "Continue",
                message: "Replay paused.", commands: pending,
            )
        case .idle,
             .running,
             .finished:
            return nil
        }
    }

    /// "1 command" / "N commands" — the replay HUD's count phrase (English plural).
    private static func replayCountPhrase(_ count: Int) -> String {
        "\(count) command\(count == 1 ? "" : "s")"
    }

    // MARK: - Replay execution helpers

    /// Store the machine's post-transition state + (re)arm the handoff-absorb counter. A FINISHED machine is
    /// removed (with its absorb entry); a machine PAUSED on an interactive command arms the counter to the
    /// number of typed-ahead NON-interactive commands in `burst` (everything except the trailing interactive
    /// command), so their completions are skipped before the interactive command's return-to-prompt resumes.
    /// `extraAbsorb` folds in completions typed-ahead OUTSIDE the burst (the restored-cwd `cd` injected via the
    /// parallel `mountRestorePlan` stream) that also land at the local prompt before the interactive command's
    /// return; it is only ever non-zero on the INITIAL arm (the `cd` is typed once, before the first burst).
    private func recordReplayProgress(
        _ machine: RecipeReplayMachine, burst: [String], for id: PaneID, extraAbsorb: Int = 0,
    ) {
        if machine.isFinished {
            recipes.replayMachines[id] = nil
            recipes.replayHandoffAbsorb[id] = nil
            return
        }
        recipes.replayMachines[id] = machine
        if case .paused(.interactiveCommand) = machine.state {
            recipes.replayHandoffAbsorb[id] = max(0, burst.count - 1) + extraAbsorb
        } else {
            recipes.replayHandoffAbsorb[id] = nil
        }
    }

    /// Inject a burst of recipe commands into pane `id`'s live PTY, deferred by `launchGrace`. A `.zero` grace
    /// injects synchronously (the resume edges already have a live prompt; tests want a deterministic read); a
    /// positive grace defers via a main-actor Task (the freshly-restored remote prompt must come up first),
    /// mirroring ``newSessionFromTemplate(_:)``'s deferred per-pane launch.
    private func deliverReplayBurst(_ commands: [String], into id: PaneID, launchGrace: Duration) {
        guard !commands.isEmpty else { return }
        if launchGrace == .zero {
            injectRecipeCommands(commands, into: id)
        } else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: launchGrace)
                self?.injectRecipeCommands(commands, into: id)
            }
        }
    }

    /// Encode each command VERBATIM (``BlockReRunEncoder`` — literal UTF-8 + one `\n`, never ``SendKeysParser``)
    /// and inject it into pane `id`'s live ``TerminalViewModel`` via ``TerminalViewModel/sendInput(_:)`` (the
    /// SAME outbound seam ``reRunCommandInActivePane(_:)`` uses — wire type 3, no host / wire change). A no-op
    /// for a non-terminal / absent pane or an empty / whitespace-only command (the encoder returns `nil`).
    private func injectRecipeCommands(_ commands: [String], into id: PaneID) {
        guard !commands.isEmpty,
              let model = (handle(for: id) as? TerminalModelProviding)?.terminalModel else { return }
        for command in commands {
            guard let bytes = BlockReRunEncoder.bytes(for: command) else { continue }
            model.sendInput(bytes)
        }
    }

    // MARK: - Restore (mount the tree + queue the commands)

    /// Restore `recipe` into the live tree and queue its commands for replay, then START the replay (WI-9
    /// drives the injection). `tab`/`window` mount the reconstructed split trees as new tab(s)/session and
    /// restore each pane's working directory; `commands` mounts nothing and queues into the CURRENT active
    /// pane. `launchGrace` defers the cwd `cd` + the replay burst (tests pass `.zero`).
    private func applyTrustedRecipe(
        _ recipe: Recipe, source: RecipeSource, recipeLocation: String,
        launchGrace: Duration = .milliseconds(1400),
    ) {
        let plan = RecipeBuilder.restorePlan(
            recipe, home: recipeHome, currentFolder: activePaneCwd ?? "", recipeLocation: recipeLocation,
        )
        let mode = replayMode(for: source)
        switch plan.scope {
        case .commands:
            queueReplay(plan, target: activePaneID, mode: mode)
        case .tab,
             .window:
            mountRestorePlan(plan, name: recipe.name, launchGrace: launchGrace)
            queueReplay(plan, target: nil, mode: mode)
        }
        // E16 WI-9: actually START the replay the restore just queued — the whole point of ES-E16-2. Without
        // this the commands sit in `pendingRecipeReplay` and are silently dropped (no production caller ever
        // consumed the queue). A no-op for a Layout-Only recipe (nothing queued) or Skip mode. The cwd `cd`
        // was scheduled first (above) under the SAME grace, so a freshly-restored pane is in its captured
        // directory before its commands replay. 100% client-side — no wire / golden touch.
        beginRecipeReplay(launchGrace: launchGrace)
    }

    /// Mount a `tab` / `window` restore plan into the live tree: a `window` recipe appends a fresh ``Session``
    /// (selected); a `tab` recipe appends its tab(s) to the active session (or a fresh session when none).
    /// Then ``reconcileTree()`` materializes the new leaves. The plan's leaf ids are reused verbatim, so the
    /// queued replay (keyed by those ids) targets the mounted panes. Finally each restored TERMINAL pane is
    /// `cd`-ed into its captured working directory (ES-E16-2), via the SAME deferred safe-literal `cd` route
    /// `newTab` / `splitActivePane` use; `launchGrace` defers it past the freshly-mounted shell's prompt.
    private func mountRestorePlan(_ plan: RecipeRestorePlan, name: String, launchGrace: Duration) {
        guard !plan.tabs.isEmpty else { return }
        let restored = sessionFromRestoreTabs(plan.tabs, name: recipeSessionName(name))
        guard !restored.tabs.isEmpty else { return }

        if plan.scope == .window {
            tree.sessions.append(restored)
            tree.activeSessionID = restored.id
        } else if let index = tree.activeSessionIndex {
            // `.tab`: graft the restored tab(s) onto the active session and select the first new one.
            let firstNewIndex = tree.sessions[index].tabs.count
            tree.sessions[index].tabs.append(contentsOf: restored.tabs)
            for (id, spec) in restored.specs { tree.sessions[index].specs[id] = spec }
            tree.sessions[index].activeTabIndex = firstNewIndex
        } else {
            tree.sessions.append(restored)
            tree.activeSessionID = restored.id
        }
        reconcileTree()
        // ES-E16-2 "restores working directories": a recipe captures each pane's cwd in `lastKnownCwd`, but a
        // freshly-mounted PTY starts at $HOME — type the safe-literal `cd` into each restored terminal pane so
        // it lands in its captured directory. Independent of replay mode (a Skip / Layout-Only restore still
        // restores cwd); `deferInheritedCwd` no-ops a non-terminal pane or an empty cwd. A `cd` that DID type
        // (returns `true`) runs at the local prompt and emits its own OSC-133;D — record it so the replay
        // machine's handoff-absorb skips that completion too (else the post-`ssh` command injects into the inner
        // session; see `replayPreInjectedCwds`). `beginRecipeReplay` consumes + clears these.
        for (paneID, spec) in restored.specs {
            let typedCd = deferInheritedCwd(
                spec.lastKnownCwd, into: paneID, kind: spec.kind, launchGrace: launchGrace,
            )
            guard typedCd else { continue }
            recipes.replayPreInjectedCwds[paneID, default: 0] += 1
        }
    }

    /// Build a ``Session`` from the restore plan's reconstructed tabs: each leaf becomes a `.terminal`
    /// ``PaneSpec`` carrying the resolved cwd, and the spec side-table covers every leaf (the specs == leafIDs
    /// invariant). The tab's first leaf is its active pane.
    private func sessionFromRestoreTabs(_ tabs: [RecipeRestoreTab], name: String) -> Session {
        var builtTabs: [Tab] = []
        var specs: [PaneID: PaneSpec] = [:]
        for restoreTab in tabs {
            for id in restoreTab.tree.allPaneIDs() {
                let detail = restoreTab.panes[id]
                specs[id] = PaneSpec(
                    kind: .terminal,
                    title: restoreTab.title.isEmpty ? "Terminal" : restoreTab.title,
                    lastKnownCwd: detail?.cwd,
                )
            }
            builtTabs.append(Tab(
                title: restoreTab.title, root: restoreTab.tree, activePane: restoreTab.tree.firstLeafID,
            ))
        }
        return Session(name: name, tabs: builtTabs, activeTabIndex: 0, specs: specs)
    }

    /// Produce the per-pane replay queue from a restore plan. `commands` scope queues `plan.commands` into the
    /// supplied `target` (the current active pane); `tab`/`window` queue each restored pane's own commands.
    /// Sets ``pendingRecipeReplay`` (or clears it when there is nothing to replay).
    private func queueReplay(_ plan: RecipeRestorePlan, target: PaneID?, mode: RecipeReplayMode) {
        var byPane: [PaneID: [String]] = [:]
        switch plan.scope {
        case .commands:
            if let target, !plan.commands.isEmpty { byPane[target] = plan.commands }
        case .tab,
             .window:
            for restoreTab in plan.tabs {
                for (id, pane) in restoreTab.panes where !pane.commands.isEmpty {
                    byPane[id] = pane.commands
                }
            }
        }
        recipes.pendingRecipeReplay = byPane.isEmpty ? nil : RecipeReplayRequest(mode: mode, commandsByPane: byPane)
    }

    // MARK: - Helpers

    /// The replay mode for a recipe `source` (the user's two Command-Replay settings).
    private func replayMode(for source: RecipeSource) -> RecipeReplayMode {
        switch source {
        case .savedLibrary: SettingsKey.replayModeSaved
        case .file: SettingsKey.replayModeFiles
        }
    }

    /// The loaded trust store (decode-fail-to-default when the file is missing / corrupt).
    private func trustStore() -> RecipeTrustStore {
        guard let url = RecipeLibrary.trustStoreURL(environment: recipes.environment) else { return .empty }
        return RecipeLibrary.loadTrust(url: url)
    }

    /// Record `hash` trusted (self-saved or Always-Trust) and persist the store. A no-op when the trust-store
    /// URL can't be resolved (no `$HOME`).
    private func persistTrust(hash: String, name: String, origin: RecipeTrustOrigin) {
        guard let url = RecipeLibrary.trustStoreURL(environment: recipes.environment) else { return }
        var store = RecipeLibrary.loadTrust(url: url)
        store.trust(hash: hash, name: name, origin: origin)
        try? RecipeLibrary.saveTrust(store, to: url)
    }

    /// The home directory the save/restore portabilize against (from the recipe environment).
    private var recipeHome: String { recipes.environment["HOME"] ?? "" }

    /// The active pane's last-known cwd (the `{{current_folder}}` base), or `nil`.
    private var activePaneCwd: String? {
        activePaneID.flatMap { tree.spec(for: $0)?.lastKnownCwd }
    }

    /// The name a restored session/tab carries — the recipe's name, or "Recipe" when blank.
    private func recipeSessionName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Recipe" : trimmed
    }
}

// MARK: - Recipe replay-command flattening

extension Recipe {
    /// Every replay command across every tab → pane, in tree order — the trust-sheet list + the replay
    /// source. Empty for a Layout-Only recipe.
    var allReplayCommands: [String] {
        window.tabs.flatMap { $0.panes.flatMap(\.commands) }
    }
}
