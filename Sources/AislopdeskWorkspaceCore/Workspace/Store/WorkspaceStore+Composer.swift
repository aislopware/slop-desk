import Foundation

// MARK: - ComposerProviding (the store↔live-session seam the composer ops resolve through)

/// The capability seam the E12 active-pane Composer / Prompt-Queue ops resolve through — the exact mirror
/// of ``TerminalModelProviding`` for the WB2/WB3 block ops: an `as?`-castable handle exposing the pane's
/// durable ``ComposerModel``. The production conformer is ``LivePaneSession`` (returns its `composer`); a
/// non-terminal session (`.remoteGUI` / `.systemDialog`) has none, so `composerModel` is `nil` and every
/// composer op degrades to a graceful no-op. Resolving through this seam (rather than an `as? LivePaneSession`
/// cast) keeps the routing exercisable by a recording test double that carries a real ``ComposerModel``.
@MainActor
protocol ComposerProviding: AnyObject {
    /// The pane's Composer + Prompt Queue view-model, or `nil` for a non-terminal session.
    var composerModel: ComposerModel? { get }
    /// Whether this pane currently hosts an agent (`claudeStatus != .none`) — drives the float-panel
    /// title ("Aislopdesk Composer — Claude Code" vs "Aislopdesk Composer"). Defaults to `false` so a
    /// non-agent session / a test double need not implement it.
    var composerAgentActive: Bool { get }
}

@MainActor
extension ComposerProviding {
    /// Default: no agent (a plain terminal / a test double that carries no `claudeStatus`).
    var composerAgentActive: Bool { false }
}

extension LivePaneSession: ComposerProviding {
    /// The per-pane Composer view-model (`nil` for a `.remoteGUI` / `.systemDialog` pane — no terminal,
    /// no composer).
    var composerModel: ComposerModel? { composer }

    /// Whether this pane hosts an agent — `claudeStatus` has lifted off `.none` (host-detected, wire
    /// type 27). The float-panel title appends " — Claude Code" only then (no agent-name guessing).
    var composerAgentActive: Bool { claudeStatus != .none }
}

// MARK: - LiveAgentSessionProviding (the store↔live-session seam the Resume jump map resolves through)

/// The capability seam the E13 History-viewer **Resume** (ES-E13-6) builds its "is this session still
/// running" map through — the mirror of ``ComposerProviding`` for the agent session id: an `as?`-castable
/// handle exposing the Claude session id the pane is CURRENTLY running, or `nil` when it hosts no live agent.
/// The production conformer is ``LivePaneSession`` (its inspector-reported session id, gated on a live
/// `claudeStatus`). Resolving through this seam — rather than an `as? LivePaneSession` cast — keeps the map
/// building exercisable by a recording test double that carries a settable session id.
@MainActor
protocol LiveAgentSessionProviding: AnyObject {
    /// The Claude session id this pane is CURRENTLY running, or `nil` when no live agent hosts it. E13 WI-6.
    var liveAgentSessionID: String? { get }
}

// MARK: - ResolvedComposer (the window-level pin / float mount target the client UI promotes)

/// A composer the client UI must mount OUTSIDE its origin pane's subtree (E12 WI-6): the pinned
/// window-level mount or the floating panel / sheet. Bundles the durable ``ComposerModel`` with the
/// resolved agent flag (for the float title) so the resolver reads both in one pass over the live
/// sessions. A plain value type (holding the `@MainActor` ``ComposerModel`` reference) — it is built and
/// read entirely on the main actor (the `@MainActor` store resolver / a SwiftUI body), so it needs no
/// isolation annotation of its own; storing the reference never touches the model's isolated members.
public struct ResolvedComposer {
    /// The durable per-pane composer to mount at the window level / in the float panel.
    public let composer: ComposerModel
    /// Whether the origin pane hosts an agent — drives the float-panel title suffix.
    public let agentActive: Bool

    public init(composer: ComposerModel, agentActive: Bool) {
        self.composer = composer
        self.agentActive = agentActive
    }
}

// MARK: - WorkspaceStore × Composer + Prompt Queue (E12)

/// The E12 active-pane Composer (`⌘⇧E`) / Prompt-Queue (`⌘⇧M`) ops, split into their own extension (like
/// ``WorkspaceStore`` × Blocks) so the already-large store body stays under the lint type-body ceiling.
/// They mirror ``WorkspaceStore/requestCopyModeInActivePane()``: resolve the active pane's DURABLE composer
/// (in whichever live model is active) + its terminal model, then drive the composer verb and fire the
/// per-pane view-focus callback. A no-op for a non-terminal active pane (`.remoteGUI`) or an empty shell.
public extension WorkspaceStore {
    /// The active pane's durable ``ComposerModel`` in WHICHEVER live model is active (mirrors
    /// ``activeTerminalModel``): the tree's active pane on the IDE shell, the canvas focus on the
    /// retained-but-dead path. `nil` for a non-terminal active pane (`.remoteGUI`) or an empty shell.
    internal var activeComposerModel: ComposerModel? {
        guard let activeID = activePaneID,
              let provider = handle(for: activeID) as? ComposerProviding else { return nil }
        return provider.composerModel
    }

    /// `⌘⇧E` — TOGGLES the Composer over the active pane: flips the durable ``ComposerModel/isVisible`` (the
    /// bar mounts at the pane bottom via the leaf view, E12 WI-5) and fires the pane's
    /// ``TerminalViewModel/onRequestComposer`` so the view can move keyboard focus into the field. A no-op
    /// for a non-terminal active pane or an empty shell.
    func requestComposerInActivePane() {
        activeComposerModel?.toggle()
        activeTerminalModel?.onRequestComposer?()
    }

    /// `⌘⇧M` — OPENS the Composer in Prompt-Queue input mode over the active pane: shows the durable
    /// ``ComposerModel`` (OPEN, not toggle — a second ⌘⇧M leaves the queue open) and fires the pane's
    /// ``TerminalViewModel/onRequestPromptQueue`` so the leaf view switches to the queue-input affordance
    /// (placeholder + `↩`-adds-a-line, E12 WI-5) and takes focus. A no-op off-terminal / empty shell.
    func requestPromptQueueInActivePane() {
        activeComposerModel?.open()
        activeTerminalModel?.onRequestPromptQueue?()
    }

    // MARK: - E13 WI-5: Send to Chat (capture the active pane's quote)

    /// Captures the active pane's Send-to-Chat quote (ES-E13-5, `⌘⌃↩`) SYNCHRONOUSLY: the libghostty SELECTION
    /// when one exists (the primary path — select text, then ⌘⌃↩). Returns `nil` — so the caller does NOT
    /// open the dialog on this synchronous pass — when the active pane is not a terminal or has no selection.
    /// PURE-ish read (resolves through ``activeTerminalModel``); never mutates the tree.
    ///
    /// The spec's no-selection fallback ("the last command's OUTPUT — the OSC-133 `D` block's output body from
    /// shell integration") is NOT available synchronously: it needs a wire round-trip (type 15 → 29,
    /// ``TerminalViewModel/copyBlockOutput(index:onResult:)``, live-host-only). So this synchronous capture is
    /// SELECTION-ONLY; the caller falls through to the async companion ``captureSendToChatLastOutput(onResult:)``
    /// when this returns `nil`. (Quoting the command LINE would mislead — it sends the command you typed, not
    /// its output — so only the real OUTPUT body is ever quoted, never the line.)
    func captureSendToChatContext() -> SendToChatContext? {
        guard let activeID = activePaneID, let spec = tree.spec(for: activeID) else { return nil }
        let title = PanePresentation.displayTitle(handle(for: activeID), spec: spec)
        let selection = activeTerminalModel?.currentSelectionText()
        // `lastOutput: nil` — the output-body fallback is async (see `captureSendToChatLastOutput`); this
        // synchronous capture only ever quotes a live selection.
        return SendToChatModel.capture(title: title, selection: selection, lastOutput: nil)
    }

    /// E13 WI-5 (ES-E13-5) — the ASYNC no-selection fallback: with NO live selection the spec quotes "the last
    /// command's OUTPUT" (the OSC-133 `D` block's output body from shell integration). That body needs a wire
    /// round-trip (type 15 → 29, ``TerminalViewModel/copyBlockOutput(index:onResult:)``, live-host-only), so it
    /// is fetched here and handed back through `onResult`. Resolves `onResult(nil)` when the active pane is not
    /// a terminal, its NEWEST block holds no output (`outputLen == 0` — the same "has output" gate the
    /// block-output copy affordance uses), or the host reply comes back empty/unavailable (evicted /
    /// disconnected) — the caller then surfaces a toast rather than presenting an empty dialog. The SELECTION
    /// path is resolved first + synchronously by ``captureSendToChatContext()``; this is ONLY the no-selection
    /// branch, so the caller invokes it after that returned `nil`. A pure read of the tree (the wire request is
    /// the model's own); never mutates the tree.
    func captureSendToChatLastOutput(onResult: @escaping (SendToChatContext?) -> Void) {
        guard let activeID = activePaneID, let spec = tree.spec(for: activeID),
              let model = activeTerminalModel, let latest = model.blocks.latest,
              latest.outputLen > 0
        else {
            onResult(nil)
            return
        }
        let title = PanePresentation.displayTitle(handle(for: activeID), spec: spec)
        model.copyBlockOutput(index: latest.index) { output in
            // `output` is the VT-stripped plain text (nil when evicted / no live connection); `capture`
            // returns nil for a blank/absent body, so an unavailable fetch stays an honest no-op.
            onResult(SendToChatModel.capture(title: title, selection: nil, lastOutput: output))
        }
    }

    // MARK: - E13 WI-5: Send to Chat (route a composed message to a CHOSEN agent pane)

    /// The live Claude-only agent panes the E13 "Send to Chat" dialog (`⌘⌃↩`, ES-E13-5) can route to: every
    /// pane whose ``ComposerProviding/composerAgentActive`` is set (`claudeStatus != .none`), in canonical
    /// traversal order, named by its display title. **Claude-only** (BINDING directive 1) — the agent badge
    /// is fixed to "Claude Code" in ``SendToChatSession``; `AgentKind.codex` is never surfaced. The view
    /// builds the picker from this list and resolves the last-used default via
    /// ``SendToChatModel/defaultSession(in:lastUsed:)``. A pure read — never mutates the tree / registry.
    func agentChatSessions() -> [SendToChatSession] {
        tree.allPaneIDs().compactMap { id in
            guard let provider = handle(for: id) as? ComposerProviding,
                  provider.composerAgentActive, provider.composerModel != nil,
                  let spec = tree.spec(for: id) else { return nil }
            return SendToChatSession(id: id, name: PanePresentation.displayTitle(handle(for: id), spec: spec))
        }
    }

    /// E13 WI-5 (ES-E13-5): routes the composed `message` to the agent pane `target`'s durable
    /// ``ComposerModel`` — the SINGLE per-pane ordered-OUT sink (VERBATIM literal UTF-8 via
    /// ``SendToChatModel/payload(for:)``: a multi-line message rides as one inert DEC bracketed-paste block +
    /// CR, NEVER ``SendKeysParser``) — and AUTO-SWITCHES focus to that pane (the spec's final-frame tab
    /// switch). Resolves the target through the ``ComposerProviding`` seam (so it is exercisable by a
    /// recording double), making a non-terminal / unknown / no-composer target a graceful no-op. Focuses in
    /// WHICHEVER live model is active (the tree shell vs the retained canvas). Returns `true` when a live
    /// agent composer accepted the message (so the caller can dismiss the dialog), `false` on a no-op.
    @discardableResult
    func sendChatMessage(_ message: String, to target: PaneID) -> Bool {
        guard let provider = handle(for: target) as? ComposerProviding,
              let composer = provider.composerModel, let send = composer.send else { return false }
        send(SendToChatModel.payload(for: message))
        switch liveModel {
        case .tree: focusPaneTree(target)
        case .canvas: focus(target)
        }
        return true
    }

    /// E13 WI-5 (ES-E13-5) — the "New session" picker option (no live agent target chosen): spawn a fresh
    /// terminal tab (the new chat's pane, focused), LAUNCH Claude in it, then hand it the composed `message`.
    /// Returns the new pane's id (focused), or `nil` if the spawn did not materialize a pane.
    /// `onDeliveryFailed` fires (main actor) if the pane never became ready to accept input within
    /// ``sendChatReadyTimeout`` — e.g. a slow/unreachable host — so the caller can surface a user-visible
    /// error instead of the message silently vanishing.
    @discardableResult
    func sendChatToNewSession(_ message: String, onDeliveryFailed: (@MainActor () -> Void)? = nil) -> PaneID? {
        sendChatToNewSession(message, launchGrace: .milliseconds(1400), onDeliveryFailed: onDeliveryFailed)
    }

    /// The bound on how long ``sendChatToNewSession(_:launchGrace:onDeliveryFailed:)`` waits for the freshly
    /// spawned tab to become ``PaneSessionHandle/isReadyForInput`` before giving up and calling
    /// `onDeliveryFailed`.
    static let sendChatReadyTimeout: Duration = .seconds(10)

    /// The `launchGrace`-parameterized core of ``sendChatToNewSession(_:onDeliveryFailed:)`` — a test injects
    /// a `0` ms grace to observe the launch + delivery without a 1.4 s wall-clock wait. Production callers
    /// use the public overload.
    ///
    /// A fresh terminal tab is a bare login SHELL — there is no live Claude here (that is exactly why the
    /// picker offered "New session"). Injecting the composed prompt straight in (the prior bug) makes the
    /// SHELL try to RUN the quoted-markdown block (command-not-found / stray redirects), not start a chat. So
    /// LAUNCH Claude first — `claude\n` as VERBATIM literal UTF-8, NEVER ``SendKeysParser`` (the standing
    /// inject-safety invariant the fork/resume path also obeys) — then deliver the prompt via
    /// ``SendToChatModel/payload(for:)`` once Claude's TUI input is up (a multi-line message rides as one inert
    /// DEC bracketed-paste block + CR).
    ///
    /// Readiness-gated, NOT a fixed sleep for the launch: a fixed wall-clock wait either fires too early on a
    /// slow/WAN connect (``PaneSessionHandle/sendBytes(_:)`` silently drops while disconnected — the `claude\n`
    /// launch vanishes and the message types into a bare shell) or wastes time on a fast one. So Phase 1 polls
    /// ``PaneSessionHandle/isReadyForInput`` (bounded by ``sendChatReadyTimeout``) before typing `claude\n`,
    /// and calls `onDeliveryFailed` instead of guessing if the pane never comes up. There is no wire signal for
    /// "Claude's TUI is up", so Phase 2 (before the prompt) stays a bounded grace — but it now runs only after
    /// the launch is KNOWN delivered, not guessed. Both phases run in ONE task so the launch lands STRICTLY
    /// after the new tab's own deferred cwd `cd` (which fires at `launchGrace`) — otherwise `claude` could
    /// start before the `cd` and the directory change would type into Claude's prompt instead of the shell.
    @discardableResult
    func sendChatToNewSession(
        _ message: String,
        launchGrace: Duration,
        readyTimeout: Duration = WorkspaceStore.sendChatReadyTimeout,
        onDeliveryFailed: (@MainActor () -> Void)? = nil,
    ) -> PaneID? {
        newTab(kind: .terminal, launchGrace: launchGrace)
        guard let spawned = tree.activeSession?.activeTab?.activePane else { return nil }
        let launch = Array("claude\n".utf8) // VERBATIM — start Claude in the fresh shell (no SendKeysParser)
        let payload = Array(SendToChatModel.payload(for: message))
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Phase 0: let the new-tab's own deferred cwd `cd` get enqueued first (same grace), so `cd`
            // can never land AFTER `claude` starts and type into its prompt instead of the shell.
            try? await Task.sleep(for: launchGrace)
            // Phase 1: wait for the pane to actually be able to accept input — NOT a guess. Bails out
            // (loudly) rather than silently dropping `claude\n` into a still-disconnected pane.
            guard await waitUntilReady(spawned, timeout: readyTimeout) else {
                onDeliveryFailed?()
                return
            }
            handle(for: spawned)?.sendBytes(launch)
            // Phase 2: Claude's TUI needs a moment to come up before it can accept the composed prompt —
            // no wire signal exists for this, so it stays a bounded grace (but the launch above is now
            // KNOWN delivered, unlike the old fixed-sleep-only version).
            try? await Task.sleep(for: launchGrace)
            handle(for: spawned)?.sendBytes(payload)
        }
        return spawned
    }

    /// Polls ``PaneSessionHandle/isReadyForInput`` for pane `id` until it is `true` or `timeout` elapses.
    /// Checks BEFORE the first sleep so an already-ready pane (every test fake, or a fast local connect)
    /// returns immediately with no added latency.
    @MainActor
    private func waitUntilReady(_ id: PaneID, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if handle(for: id)?.isReadyForInput == true { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - E13 WI-6: Resume (the History viewer's jump-vs-spawn map + the spawn-into-a-fresh-tab path)

    /// E13 WI-6 (ES-E13-6): the live Claude agent panes keyed by the session id each is CURRENTLY running —
    /// the map the History viewer's Resume routes through (``AgentResumeRouter/target(sessionID:liveSessionIDs:)``):
    /// a Resume JUMPS to the pane already running that exact session instead of spawning a duplicate. Only panes
    /// hosting a LIVE agent (a non-`.none` `claudeStatus`) with a known session id are included; the id is the
    /// bare Claude session id the inspector channel reported, which ``AgentResumeRouter`` matches CANONICALLY
    /// against the host's `AgentSessionInfo.id` (an absolute `<id>.jsonl` path). Claude-only (BINDING directive
    /// 1). Resolves through the ``LiveAgentSessionProviding`` seam (exercisable by a recording double); a pure
    /// read — never mutates the tree / registry.
    func liveAgentSessionIDs() -> [String: PaneID] {
        var map: [String: PaneID] = [:]
        for id in tree.allPaneIDs() {
            guard let provider = handle(for: id) as? LiveAgentSessionProviding,
                  let sessionID = provider.liveAgentSessionID else { continue }
            map[sessionID] = id
        }
        return map
    }

    /// E13 WI-6 (ES-E13-6) — the History viewer's Resume "spawn" branch: open a fresh terminal tab (the
    /// resumed session's pane, focused) and run the VERBATIM resume command
    /// (``AgentResumeRouter/ResumeTarget/spawn(command:)`` — `claude --resume <id>\n`) in it once the remote
    /// shell prompt is up. Returns the new pane's id (focused), or `nil` if the spawn made no pane.
    @discardableResult
    func resumeAgentInNewTab(command: String) -> PaneID? {
        resumeAgentInNewTab(command: command, launchGrace: .milliseconds(1400))
    }

    /// The `launchGrace`-parameterized core of ``resumeAgentInNewTab(command:)`` — a test injects a `0` ms
    /// grace to observe the inject without a 1.4 s wall-clock wait. Production callers use the public overload.
    ///
    /// The resume command must NOT land in the FOCUSED pane (the History viewer is opened from the inspector of
    /// a pane that is frequently a LIVE Claude agent — injecting there would deliver `claude --resume <id>` as a
    /// chat prompt INTO the running agent, the exact bug this fixes). So a fresh terminal tab is spawned and the
    /// command is delivered there as literal UTF-8 bytes, NEVER ``SendKeysParser`` (the standing inject-safety
    /// invariant the fork / Send-to-Chat paths also obey) — so a stray quote / newline in a session id can never
    /// become a control sequence. The two graces sequence the resume command STRICTLY after the new tab's own
    /// deferred cwd `cd` (which fires at `launchGrace`), so the `cd` can never type into the `claude --resume`
    /// line (the same ordering ``sendChatToNewSession(_:launchGrace:)`` uses).
    @discardableResult
    func resumeAgentInNewTab(command: String, launchGrace: Duration) -> PaneID? {
        newTab(kind: .terminal, launchGrace: launchGrace)
        guard let spawned = tree.activeSession?.activeTab?.activePane else { return nil }
        let bytes = Array(command.utf8) // VERBATIM — `claude --resume <id>` into the fresh shell (no SendKeysParser)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: launchGrace)
            try? await Task.sleep(for: launchGrace)
            self?.handle(for: spawned)?.sendBytes(bytes)
        }
        return spawned
    }

    // MARK: - Pin / float resolution (E12 WI-6 — the window-level / float mount the client UI promotes)

    /// The composer currently PINNED, in WHICHEVER live pane owns it — `nil` when none is pinned. The
    /// client UI mounts this at the WINDOW level (above the split / tab switcher) so a pinned composer
    /// rides along across tab switches (a pinned composer stays visible regardless of which tab is active),
    /// instead of inside the origin pane's subtree. Resolves across ALL live sessions (not just the active
    /// one) — that is exactly what lets the pinned bar survive switching to a different tab. Reading it in a
    /// SwiftUI body registers observation on each composer's ``ComposerModel/isPinned`` so the mount tracks
    /// the toggle. First match wins (one composer is pinned at a time in practice).
    var pinnedComposer: ResolvedComposer? { resolveComposer { $0.isPinned } }

    /// The composer currently FLOATING — `nil` when none is floating. The client UI presents this in a
    /// non-activating `NSPanel` (macOS) / bottom sheet (iOS), keeping the SAME ``ComposerModel`` so `⌘↩`
    /// still injects into the origin pane's PTY. Resolves across ALL live sessions (the float detaches from
    /// its origin pane). Reading it in a SwiftUI body registers observation on each composer's
    /// ``ComposerModel/isFloating`` so the presentation opens / closes with the toggle.
    var floatingComposer: ResolvedComposer? { resolveComposer { $0.isFloating } }

    /// Scan the live sessions for the FIRST whose composer matches `predicate`, bundling it with its
    /// resolved agent flag. A pure read — never mutates the tree / registry. The `as? ComposerProviding`
    /// cast skips non-terminal sessions (`.remoteGUI` has no composer). Reading `allSessions` +
    /// `composer.isPinned` / `.isFloating` here is what makes the result reactive in a SwiftUI body.
    private func resolveComposer(_ predicate: (ComposerModel) -> Bool) -> ResolvedComposer? {
        for session in allSessions {
            guard let provider = session as? ComposerProviding,
                  let composer = provider.composerModel, predicate(composer) else { continue }
            return ResolvedComposer(composer: composer, agentActive: provider.composerAgentActive)
        }
        return nil
    }

    /// Enforce a SINGLE window-level pin: a pinned composer is a window-level singleton ("rides along
    /// regardless of which tab is active"), so pinning `pinnedID`'s composer must clear EVERY OTHER pane's
    /// pin. Without this, pinning pane A then pane B left both pinned — and ``pinnedComposer`` (first-match)
    /// surfaces only one, so the other (and its unpin toggle) became unreachable. Wired into every composer's
    /// ``ComposerModel/onPinnedExclusive`` at materialization (so it fires on a runtime toggle) AND re-run
    /// after a persisted-pin restore (so a legacy multi-pin relaunch collapses to one, last-restored winning).
    /// Clearing a sibling routes through ``ComposerModel/setPinned(_:)`` → its ``ComposerModel/onPinnedChange``
    /// → un-persists it, keeping the persisted pin set a singleton too; a pin-OFF edge fires no
    /// `onPinnedExclusive`, so the sweep cannot recurse.
    func enforceSingleComposerPin(keeping pinnedID: PaneID) {
        for session in allSessions where session.id != pinnedID {
            guard let composer = (session as? ComposerProviding)?.composerModel, composer.isPinned else { continue }
            composer.setPinned(false)
        }
    }
}
