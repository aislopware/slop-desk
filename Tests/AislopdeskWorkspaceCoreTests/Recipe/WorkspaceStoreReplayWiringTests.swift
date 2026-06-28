import Foundation
import XCTest
@testable import AislopdeskWorkspaceCore

/// E16 / WI-9 — the recipe REPLAY-EXECUTION wiring: ``WorkspaceStore`` drives one ``RecipeReplayMachine`` per
/// restored pane against the live PTY, injecting each captured command VERBATIM (``BlockReRunEncoder`` →
/// ``TerminalViewModel/sendInput(_:)``, never ``SendKeysParser``), advancing on the OSC-133;D / prompt-return
/// edge, and PAUSING after a shell-handoff command (`ssh`/…) until the inner session returns to a local prompt.
///
/// Headless: a `.tree`-live store backed by ``RecordingTerminalPaneSession`` (a REAL ``TerminalViewModel`` per
/// `.terminal` pane whose `sendInput` is recorded — no socket, no renderer, no NSWindow). The replay QUEUE
/// (``RecipeRuntimeState/pendingRecipeReplay``, produced by WI-8's open/restore) is seeded directly so each
/// mode + the handoff pause are pinned in isolation from the open flow.
@MainActor
final class WorkspaceStoreReplayWiringTests: XCTestCase {
    // MARK: - Fixtures

    /// A `.tree`-live store whose `.terminal` panes carry a recording ``TerminalViewModel``.
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            restoringTree: .defaultWorkspace(),
            liveModel: .tree,
            makeSession: { RecordingTerminalPaneSession($0) },
            liveVideoCap: 2,
        )
    }

    private func activePane(_ store: WorkspaceStore) throws -> PaneID {
        try XCTUnwrap(store.tree.activeSession?.activeTab?.activePane)
    }

    private func recordingSession(_ store: WorkspaceStore, _ id: PaneID) throws -> RecordingTerminalPaneSession {
        try XCTUnwrap(store.handle(for: id) as? RecordingTerminalPaneSession)
    }

    /// The bytes injected into a pane, decoded back to strings in call order (every recipe command is one
    /// `sendInput` of literal UTF-8 + one `\n`).
    private func sentStrings(_ session: RecordingTerminalPaneSession) -> [String] {
        session.sentInput.compactMap { String(data: $0, encoding: .utf8) }
    }

    /// Seed the replay queue (the WI-8 → WI-9 boundary) for one pane, then begin synchronously (`.zero` grace).
    private func seedReplay(_ store: WorkspaceStore, _ mode: RecipeReplayMode, _ commands: [String], into id: PaneID) {
        store.recipes.pendingRecipeReplay = RecipeReplayRequest(mode: mode, commandsByPane: [id: commands])
    }

    // MARK: - Auto: the whole queue injects in order

    /// Auto replay injects the captured commands into the live pane in order, each as verbatim UTF-8 + one
    /// newline, and the queue is consumed.
    /// REVERT-TO-CONFIRM-FAIL: a `beginRecipeReplay` that drops the burst injection records nothing.
    func testAutoInjectsTheWholeSequenceInOrder() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        seedReplay(store, .auto, ["echo a", "echo b", "echo c"], into: active)
        store.beginRecipeReplay(launchGrace: .zero)

        XCTAssertEqual(sentStrings(session), ["echo a\n", "echo b\n", "echo c\n"], "Auto injects all in order")
        XCTAssertNil(store.recipes.pendingRecipeReplay, "begin consumes the queue")
        XCTAssertFalse(store.isReplayingRecipe(for: active), "an all-safe Auto queue finishes immediately")
    }

    // MARK: - Manually: one command per continue

    /// Manually replay injects NOTHING on begin and feeds exactly one command per ``continueRecipeReplay(for:)``
    /// (the user's Enter), finishing after the last.
    func testManuallyFeedsOneCommandPerContinue() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        seedReplay(store, .manually, ["echo a", "echo b"], into: active)
        store.beginRecipeReplay(launchGrace: .zero)
        XCTAssertEqual(sentStrings(session), [], "Manually injects nothing until the user continues")
        XCTAssertTrue(store.isReplayingRecipe(for: active), "the machine waits for the first continue")

        store.continueRecipeReplay(for: active)
        XCTAssertEqual(sentStrings(session), ["echo a\n"], "one command per continue")
        XCTAssertTrue(store.isReplayingRecipe(for: active))

        store.continueRecipeReplay(for: active)
        XCTAssertEqual(sentStrings(session), ["echo a\n", "echo b\n"])
        XCTAssertFalse(store.isReplayingRecipe(for: active), "the machine finishes after the last command")
    }

    // MARK: - Ask-Once / Manually: the live HUD prompt + the ACTIVE-pane continue (the "Run" button path)

    /// Ask-Once injects NOTHING on begin (it awaits one confirm), surfaces a live ``RecipeReplayPrompt`` the
    /// in-pane HUD renders, and runs the WHOLE queue on a single ``continueRecipeReplayInActivePane()`` — the
    /// exact path the HUD's "Run" button drives.
    /// REVERT-TO-CONFIRM-FAIL: before the HUD seam, nothing called the active-pane continue for an
    /// `awaitingConfirmation` machine, so Ask-Once (the DEFAULT for opened `.ottyrecipe` files) queued its
    /// commands and never ran — `recipeReplayPrompt` was nil-surfaced by no view and stayed unread.
    func testAskOnceSurfacesPromptThenRunsAllViaActivePaneContinue() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        seedReplay(store, .askOnce, ["echo a", "echo b"], into: active)
        store.beginRecipeReplay(launchGrace: .zero)

        XCTAssertEqual(sentStrings(session), [], "Ask-Once injects nothing until one confirm")
        let prompt = try XCTUnwrap(store.recipeReplayPrompt(for: active), "the HUD must surface an Ask-Once prompt")
        XCTAssertEqual(prompt.kind, .awaitingAskOnce)
        XCTAssertEqual(prompt.commands, ["echo a", "echo b"], "the queued commands preview in the HUD")

        // The HUD's "Run" button drives the ACTIVE-pane continue (the active pane IS the seeded pane).
        store.continueRecipeReplayInActivePane()
        XCTAssertEqual(sentStrings(session), ["echo a\n", "echo b\n"], "one confirm runs the whole Ask-Once queue")
        XCTAssertFalse(store.isReplayingRecipe(for: active))
        XCTAssertNil(store.recipeReplayPrompt(for: active), "the HUD hides once the queue finishes")
    }

    /// Manually surfaces a per-command prompt and feeds exactly one command per active-pane continue (the HUD's
    /// "Run Next"), the queue holding a live prompt until the last command.
    func testManuallySurfacesPerCommandPromptViaActivePaneContinue() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        seedReplay(store, .manually, ["echo a", "echo b"], into: active)
        store.beginRecipeReplay(launchGrace: .zero)
        XCTAssertEqual(try XCTUnwrap(store.recipeReplayPrompt(for: active)).kind, .awaitingManual)

        store.continueRecipeReplayInActivePane()
        XCTAssertEqual(sentStrings(session), ["echo a\n"], "Manually feeds one command per continue")
        XCTAssertEqual(try XCTUnwrap(store.recipeReplayPrompt(for: active)).kind, .awaitingManual)

        store.continueRecipeReplayInActivePane()
        XCTAssertEqual(sentStrings(session), ["echo a\n", "echo b\n"])
        XCTAssertNil(store.recipeReplayPrompt(for: active), "no HUD after the last command")
    }

    /// An all-safe Auto run and a Skip run surface NO HUD (they owe the user no action), so the banner never
    /// shows for the modes that drive themselves.
    func testAutoAllSafeAndSkipSurfaceNoHUD() throws {
        let store = makeStore()
        let active = try activePane(store)
        seedReplay(store, .auto, ["echo a", "echo b"], into: active)
        store.beginRecipeReplay(launchGrace: .zero)
        XCTAssertNil(store.recipeReplayPrompt(for: active), "an all-safe Auto run needs no HUD")

        let skipStore = makeStore()
        let skipActive = try activePane(skipStore)
        seedReplay(skipStore, .skip, ["echo x"], into: skipActive)
        skipStore.beginRecipeReplay(launchGrace: .zero)
        XCTAssertNil(skipStore.recipeReplayPrompt(for: skipActive), "Skip needs no HUD")
    }

    /// A shell-handoff pause surfaces a "Continue" HUD whose button resumes the queue via the active-pane
    /// continue — so the user is never STUCK behind an `ssh` whose inner session never returns a local prompt.
    func testHandoffPauseSurfacesContinueHUDAndResumesViaActivePaneContinue() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        seedReplay(store, .auto, ["echo a", "ssh host", "echo b"], into: active)
        store.beginRecipeReplay(launchGrace: .zero)

        let prompt = try XCTUnwrap(store.recipeReplayPrompt(for: active), "a handoff pause surfaces a Continue HUD")
        XCTAssertEqual(prompt.kind, .pausedHandoff)
        XCTAssertEqual(prompt.commands, ["echo b"], "the held post-handoff command previews in the HUD")

        // The user clicks Continue instead of waiting for the prompt-return edge.
        store.continueRecipeReplayInActivePane()
        XCTAssertEqual(sentStrings(session), ["echo a\n", "ssh host\n", "echo b\n"], "Continue resumes the queue")
        XCTAssertFalse(store.isReplayingRecipe(for: active), "replay finished after the manual continue")
        XCTAssertNil(store.recipeReplayPrompt(for: active))
    }

    // MARK: - Shell-handoff pause: an `ssh` command holds the queue

    /// After an interactive command (`ssh`) Auto PAUSES: the typed-ahead `echo a` completion is absorbed and the
    /// post-handoff `echo b` is NOT injected until the local prompt returns (the second completion edge).
    /// REVERT-TO-CONFIRM-FAIL: without the WI-5 pause wiring (or the absorb counter), `echo b` injects on the
    /// FIRST completion — straight into the inner ssh session.
    func testInteractiveCommandPausesUntilPromptReturns() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        seedReplay(store, .auto, ["echo a", "ssh host", "echo b"], into: active)
        store.beginRecipeReplay(launchGrace: .zero)

        // Auto types ahead up to AND INCLUDING the interactive command, then pauses — `echo b` is held back.
        XCTAssertEqual(sentStrings(session), ["echo a\n", "ssh host\n"], "the post-ssh command is held back")
        guard case .paused(.interactiveCommand("ssh host"))? = store.recipeReplayState(for: active) else {
            XCTFail("the queue is paused on the ssh handoff")
            return
        }

        // The typed-ahead `echo a` completion is ABSORBED — the held command must NOT inject yet.
        store.recipeReplayCommandCompleted(for: active)
        XCTAssertEqual(sentStrings(session), ["echo a\n", "ssh host\n"], "echo b stays held during the handoff")

        // ssh exits → the local prompt returns → the queue resumes and injects the held command.
        store.recipeReplayCommandCompleted(for: active)
        XCTAssertEqual(sentStrings(session), ["echo a\n", "ssh host\n", "echo b\n"], "the prompt-return resumes")
        XCTAssertFalse(store.isReplayingRecipe(for: active), "replay finished after the post-handoff command")
    }

    // MARK: - Verbatim injection (never SendKeysParser)

    /// Recipe commands inject VERBATIM: a captured command that LITERALLY contains the `SendKeysParser` tokens
    /// `<Enter>` / `<cr>` (and a quoted path) is sent as literal text + exactly one trailing newline — never
    /// tokenized into raw control bytes (the injection hazard the verbatim seam forbids).
    /// REVERT-TO-CONFIRM-FAIL: routing replay through `SendKeysParser`/`launchBytes` turns `<Enter>`→0x0A,
    /// `<cr>`→0x0D and the string no longer round-trips.
    func testInjectedBytesAreVerbatimNeverSendKeysParser() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        let command = #"echo "<Enter>" && cd '/tmp/<cr>x'"#
        seedReplay(store, .auto, [command], into: active)
        store.beginRecipeReplay(launchGrace: .zero)

        XCTAssertEqual(
            sentStrings(session), [command + "\n"],
            "recipe commands inject VERBATIM (no SendKeysParser tokenizing) + exactly one newline",
        )
    }

    // MARK: - Multi-pane: each banner's continue drives its OWN pane (routed by paneID, not the active pane)

    /// A multi-pane Include-Commands recipe in Manually / Ask-Once mounts a ``RecipeReplayHUD`` over EVERY pane
    /// with a pending prompt — clicking the banner for a NON-active pane must advance THAT pane's machine, not
    /// the active pane's. Two panes each get a live Manually machine; pane A is made active, then the per-pane
    /// continue for pane B (the edge the fixed HUD button drives) injects into B while A stays untouched.
    /// REVERT-TO-CONFIRM-FAIL: route this continue through the active pane (the old
    /// ``continueRecipeReplayInActivePane()`` the HUD used) and B is never advanced — A's machine moves instead,
    /// stranding B's commands permanently un-replayed.
    func testPerPaneContinueDrivesItsOwnPaneNotTheActivePane() throws {
        let store = makeStore()
        let paneA = try activePane(store)
        // Split off a second real terminal pane; the split focuses the NEW pane, so capture it as the active id.
        store.splitActivePane(axis: .horizontal, kind: .terminal, leading: false, launchGrace: .zero)
        let paneB = try activePane(store)
        XCTAssertNotEqual(paneA, paneB, "the split produced a distinct second pane")
        let sessionA = try recordingSession(store, paneA)
        let sessionB = try recordingSession(store, paneB)

        // Seed a Manually replay in BOTH panes at once (the multi-pane Include-Commands shape), then begin: each
        // pane gets its own live machine awaiting the user, and neither injects until its banner is clicked.
        store.recipes.pendingRecipeReplay = RecipeReplayRequest(
            mode: .manually, commandsByPane: [paneA: ["echo a1", "echo a2"], paneB: ["echo b1", "echo b2"]],
        )
        store.beginRecipeReplay(launchGrace: .zero)
        XCTAssertNotNil(store.recipeReplayPrompt(for: paneA), "pane A's banner is up")
        XCTAssertNotNil(store.recipeReplayPrompt(for: paneB), "pane B's banner is up")

        // Make pane A the active pane — pane B's banner is now over a NON-active pane.
        store.focusPaneTree(paneA)
        XCTAssertEqual(store.activePaneID, paneA, "pane A is the active pane")

        // Click pane B's banner — its button calls the per-pane continue keyed by B's id.
        store.continueRecipeReplay(for: paneB)

        XCTAssertEqual(sentStrings(sessionB), ["echo b1\n"], "pane B's machine advanced — its OWN command injected")
        XCTAssertEqual(sentStrings(sessionA), [], "the active pane A's machine did NOT advance")
    }

    // MARK: - Skip: nothing runs

    /// Skip mode opens the layout but injects NOTHING — a foreign recipe's commands never touch the shell.
    func testSkipInjectsNothing() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        seedReplay(store, .skip, ["rm -rf important"], into: active)
        store.beginRecipeReplay(launchGrace: .zero)

        XCTAssertEqual(sentStrings(session), [], "Skip never injects")
        XCTAssertFalse(store.isReplayingRecipe(for: active), "nothing to drive — no live machine")
        XCTAssertNil(store.recipes.pendingRecipeReplay, "the queue is still consumed")
    }

    // MARK: - No replay → the edges are inert

    /// The replay edges are no-ops for a pane with no in-flight replay (a stray OSC-133;D / continue can't
    /// inject anything).
    func testReplayEdgesAreNoOpWithoutAnActiveReplay() throws {
        let store = makeStore()
        let active = try activePane(store)
        let session = try recordingSession(store, active)

        XCTAssertEqual(store.recipeReplayCommandCompleted(for: active), [], "a stray completion injects nothing")
        XCTAssertEqual(store.continueRecipeReplay(for: active), [], "a stray continue injects nothing")
        XCTAssertEqual(sentStrings(session), [])
        XCTAssertNil(store.recipeReplayState(for: active))
    }
}
