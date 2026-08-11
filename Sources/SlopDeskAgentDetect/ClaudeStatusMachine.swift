import Foundation

/// A PURE, deterministic per-pane Claude-status state machine (docs/41 §4.3, docs/42 W7).
///
/// **Clock is injected.** Every `reduce` takes an absolute `now: TimeInterval`; the
/// machine NEVER calls `Date()`/`Date.now` (it imports Foundation only for `TimeInterval`,
/// a plain `Double`). This keeps tests deterministic and honours the repo's no-wall-clock
/// convention. The only time-driven transition is `done → idle` after `doneToIdleTimeout`,
/// fired on a `tick` (or any signal) whose `now` reaches the deadline.
///
/// **Signal precedence (defense-in-depth, docs/41 §4.2).**
/// 1. `processPresent(false)` / `sessionEnd` → `.none` (termination wins, clears all state).
/// 2. Authoritative HOOK events set the status directly (UserPrompt/PreTool → working;
///    Notification(permission|waiting) → needsPermission; Stop → done; SessionStart → idle).
/// 3. `processPresent(true)` / OSC `Claude:` title → presence FLOOR `.idle` (only lifts
///    `.none`; never downgrades a richer hook status). The title's spinner/`✳` PREFIXES
///    (Claude Code's own busy/rest telltale) additionally corroborate working/idle — see
///    `applyTitle` for the conservative rules (never past a hook block, rest only demotes
///    a live working).
/// 4. `manifestVerdict` (the no-hooks fallback) is CONSERVATIVE: a `.none` verdict is
///    ignored; `.working`/`.needsPermission` apply ONLY when an authoritative hook block
///    is not already in effect.
///
/// **Two tiers, and what decides which one is in force (2026-08-11).** Precedence alone says
/// which signal wins a collision; it does not say whether a weak signal should be in the argument
/// at all. Once a pane is HOOK-COVERED — ``hasAuthoritativeFeed``, set by the first parsed hook of a
/// session and dropped only when the session ends — the agent is TELLING us its state on every
/// edge, and the screen engine is a heuristic reading of pixels the agent draws for a human. So
/// the screen stops being a peer:
///
/// - **Tier 1 (authoritative)** — hooks, the ctl `report` verb, presence ABSENCE, and a CANCEL
///   keystroke. These change the status, immediately, always.
/// - **Tier 2 (inferred)** — the screen engine, the OSC title, the presence floor. Under coverage
///   the screen may only CORROBORATE; it cannot move the status.
///
/// …with one escape hatch, because hooks are best-effort (the relay can die, a record can be lost,
/// the host can restart mid-session): ``screenDissentSince`` times how long the screen has
/// contradicted the authoritative status WITHOUT INTERRUPTION. Past the window the pane drops
/// coverage and the screen applies. Asymmetric on purpose — ``screenDissentToRaise`` is short
/// (a human waiting on an unannounced dialog is the expensive failure) and
/// ``screenDissentToRelease`` is long (a premature release flaps the mark AND mints a false
/// finished turn, which is the failure that was actually reported). Any hook restores coverage and
/// resets the clock instantly.
///
/// This is where SlopDesk diverges from herdr on purpose: herdr has no hook feed, so its screen
/// engine IS its authority and every heuristic has to be load-bearing. Ours is a backstop.
///
/// **Post-exit lockout.** Precedence alone is not enough for teardown, because the terminating
/// signal ARRIVES EARLY: `sessionEnd` is posted while claude is still the PTY foreground, so for
/// a second or so every rung-3/4 signal still describes a live agent and lifts the floor straight
/// back off `.none`. A `sessionEnd` therefore arms ``postExitFloorLockout``, during which no weak
/// signal may lift `.none`; only an authoritative hook clears it. Presence ABSENCE arms nothing —
/// it is the end already observed, not an announcement of one.
///
/// `mutating func reduce(_:at:)` returns the new `ClaudeStatus`. Idempotent on duplicate
/// signals; out-of-order / unknown signals never trap (validate-then-drop).
public struct ClaudeStatusMachine: Sendable, Equatable {
    /// Seconds a `.done` status lingers before decaying to `.idle` (docs/41 §4.3 done→idle).
    public let doneToIdleTimeout: TimeInterval

    /// Current rolled-up status.
    public private(set) var status: ClaudeStatus

    /// A short human label (≤ `maxLabel` chars) — last assistant message / permission prompt
    /// text — for the pane chrome chip. `nil` when there is nothing to show.
    public private(set) var label: String?

    /// Absolute time the status entered `.done` (the done→idle decay anchor). `nil` otherwise.
    private var doneSince: TimeInterval?

    /// Where the current `.needsPermission` block came from (`.none` when not blocked). A
    /// conservative manifest `.working`/`.idle` verdict may clear a MANIFEST-sourced block but
    /// stays SUPPRESSED under an authoritative HOOK block — distinguishing the source fixes the
    /// stuck-blocked bug where `applyManifest(.needsPermission)` set the same flag that gated the
    /// manifest branches, so a manifest-set block could never be cleared by a later manifest
    /// verdict (review #5). Set on `enterBlocked`; cleared on any authoritative working/idle/
    /// done/terminal transition (`enter`/`terminate`).
    private var blockSource: BlockSource

    /// Absolute time the machine entered the current `.needsPermission` (nil when not blocked).
    /// Gates the SCREEN engine's hook-block override: a screen verdict may clear a hook block
    /// only once the block is at least ``hookBlockScreenOverrideGrace`` old — younger blocks win,
    /// covering the stale-snapshot race right after a hook fires, before the dialog paints.
    private var blockedSince: TimeInterval?

    /// Seconds a HOOK-sourced block outranks a contradicting screen verdict. The scan cadence is
    /// 300 ms and a dialog paints within a frame, so 1 s comfortably covers the race while the
    /// Esc-cancel liberation (a visible idle prompt box after the dialog closes) stays sub-second
    /// after the grace.
    static let hookBlockScreenOverrideGrace: TimeInterval = 1.0

    /// Absolute time the POST-EXIT floor lockout lapses, or `nil` when no session has announced its
    /// end. Armed by a `sessionEnd` hook (only that path — see ``terminate(at:armLockout:)``).
    private var exitLockoutUntil: TimeInterval?

    /// TRUE between a `preCompact` hook and the next thing that happens — the COMPACTION MARKER.
    ///
    /// Claude Code ends a `/compact` the way it ends any turn: with a `Stop`. That put the pane at
    /// `.done`, which fired the finished-turn notification, the sound and the unread badge for a
    /// housekeeping command the user ran themselves and watched complete (user-reported
    /// 2026-08-10). `.done` means "your work is finished"; a compaction finishing is the agent
    /// simply available again, which is `.idle`.
    ///
    /// A one-shot ARMED by `preCompact` and DISARMED by any subsequent turn activity (a tool
    /// starting or finishing, a new prompt, a block being raised, a session boundary). That
    /// disarming is what keeps the AUTOMATIC mid-turn compaction honest: it fires `preCompact`,
    /// then the turn RESUMES — more tools, more work — and the `Stop` at the end of that is a
    /// genuine finish, so by then the marker is long gone. Only a compaction that is the last thing
    /// to happen before the turn ends spends it.
    private var compactionPending: Bool

    /// TRUE while the CURRENT status is one the human must not be told about — today, exactly the
    /// `.idle` a spent compaction marker produced.
    ///
    /// Dropping the compaction's `Stop` from `.done` to `.idle` is only half the fix: `.working →
    /// .idle` is the hook-less COMPLETION edge every non-Claude agent finishes on, so the client
    /// would announce the compaction anyway. This flag rides out to the client on the wire `kind`
    /// byte (``AgentStatusKind/quiet``) so the transition arrives labelled as bookkeeping.
    ///
    /// Set only on that one branch and cleared by EVERY other status transition (``enter``,
    /// ``enterBlocked``, ``terminate``), so it can never outlive the status it qualifies.
    public private(set) var isQuiet: Bool

    /// Seconds a hook-announced session end vetoes every WEAK liveness signal.
    ///
    /// `SessionEnd` fires while the `claude` process is still alive: the PTY foreground was measured
    /// coming back to the shell 1.0–1.5 s later across six captured `/exit` runs. Across that gap
    /// the ~1 Hz foreground poll, the 300 ms screen scan and the still-painted OSC title all keep
    /// reporting a live agent, and any one of them lifting the presence floor resurrects the pane
    /// milliseconds after it went dark. 3 s clears the widest measured overlap with margin.
    ///
    /// Deliberately NOT a mute: an authoritative hook — a genuinely new session — clears it at once
    /// (see ``clearExitLockout()``), so `claude` relaunched immediately is never held dark; and the
    /// window is short enough that a hook-free pane's presence-only detection resumes on its next
    /// poll or two. The absence path arms nothing: `processPresent(false)` is already ground truth.
    public static let postExitFloorLockout: TimeInterval = 3.0

    /// The OUTSTANDING human-blocking tool calls, in arrival order — the BLOCK LEDGER.
    ///
    /// A hook block used to be one flag, so "the pane is blocked" and "this specific call is
    /// waiting on a human" were the same fact, and ANY `PostToolUse` cleared it. Claude Code emits
    /// tool calls in BATCHES: an assistant turn carrying `[AskUserQuestion, Bash]` fires both
    /// `PreToolUse` hooks, and the `Bash` result then landed while the question was still on screen
    /// and un-answered — clearing the block, marking the turn finished, and handing the pane back to
    /// a human who was still being asked something. Same for a permission dialog raised on one call
    /// of a batch while a sibling call runs to completion.
    ///
    /// Keyed by `tool_use_id`, a resolution names the call it resolves and nothing else. Entries
    /// with NO id (a free-standing `agent_needs_input` / a ctl `report blocked`) name no call, so
    /// they keep the old any-tool-clears-it rule — there is no better handle, and the alternative is
    /// a hand nothing can lower.
    private var blockLedger: [BlockEntry]

    /// One outstanding human-blocking call.
    struct BlockEntry: Sendable, Equatable {
        /// The blocking call's `tool_use_id`, or `nil` for a notification that names no call.
        var toolUseID: String?
        var kind: BlockKind
    }

    /// What KIND of thing is waiting on the human — the two differ in what may resolve them.
    enum BlockKind: Sendable, Equatable {
        /// A permission dialog (`PermissionRequest` / `permission_prompt`). Strictly MODAL: nothing
        /// else can START while it is up, so any `PreToolUse` proves it is gone — which is what
        /// covers a DENIED permission, the one resolution Claude Code announces with no hook of
        /// its own.
        case permission
        /// Claude asking the human a question (`AskUserQuestion`, `elicitation_dialog`). Resolved
        /// ONLY by its own `PostToolUse`, a turn boundary, or a cancel key — a sibling call in the
        /// same batch finishing says nothing about whether the human has answered.
        case ask
    }

    /// The provenance of an active `.needsPermission` block — what gates whether a conservative
    /// manifest verdict is allowed to clear it (review #5).
    private enum BlockSource: Equatable {
        /// Not blocked.
        case none
        /// An authoritative HOOK Notification(permission|waiting) — a manifest verdict must NOT clear it.
        case hook
        /// The no-hooks manifest fallback's strongest cue (a known approval UI) — a later manifest
        /// `.working`/`.idle` MAY clear it (the manifest is the only authority in play).
        case manifest
    }

    /// TRUE once an AUTHORITATIVE event has been folded for the live session — the agent in this
    /// pane is announcing its own edges, so the screen engine drops to corroboration (see the type's
    /// doc-comment).
    ///
    /// "Authoritative" is deliberately not "Claude hook". Two feeds reach ``apply(_:at:)`` and both
    /// earn coverage: the Claude Code hook socket, and the ctl `report` verb — which ANY agent or
    /// orchestrator in a pane can call (`slopdesk ctl report blocked "…"`). So a codex / gemini /
    /// bespoke wrapper that reports its own state gets exactly the tier-1 treatment Claude gets,
    /// screen demotion and watchdog included, with no per-agent code. That is the whole point of
    /// keying this on the FEED rather than on the agent's name.
    ///
    /// Deliberately NOT a recency window: a pane blocked on a question for ten minutes emits no
    /// traffic at all, and that silence is the block working exactly as intended, not evidence the
    /// feed has died. Only a session ENDING (`SessionEnd`, or presence absence) drops it — plus the
    /// dissent watchdog, which is the "the feed died anyway" path.
    private var authoritativeCovered: Bool

    /// The session id that OWNS this pane, or `nil` while the pane is unclaimed.
    ///
    /// ⚠️ The hook relay routes by `SLOPDESK_PANE_ID`, an ENVIRONMENT VARIABLE — so every
    /// descendant of the pane's shell inherits it. A `claude -p …` run from a script, a Makefile,
    /// or the pane agent's own Bash tool is a SEPARATE claude with its own session id, posting the
    /// full hook set to the pane that spawned it. Ungated, its `SessionStart` cleared the pane
    /// agent's block, its `Stop` minted a finished turn for a turn that never finished, and its
    /// `SessionEnd` blanked the pane and armed the post-exit lockout — all while the pane's real
    /// agent was still waiting on a human.
    ///
    /// So: first id-carrying event claims the pane; events naming a DIFFERENT session are dropped
    /// whole (validate-then-drop — they do not even corroborate presence, since they prove only
    /// that some claude exists somewhere in the process tree). Events carrying NO session id
    /// (tool calls, notifications, every ctl `report`) always apply and never claim, so an
    /// unattributed feed behaves exactly as it did before this existed.
    ///
    /// Released by the owner's own `SessionEnd`, by presence absence, and by the dissent watchdog
    /// — that last one is what recovers a pane whose agent died WITHOUT a `SessionEnd` (a crash, a
    /// `kill -9`) and was restarted inside one presence poll: the screen contradicts the dead
    /// session's last word, the watchdog revokes coverage, and the next hook claims a free pane.
    ///
    /// Deliberately NOT released on a timer. A nested run can hold the terminal for minutes while
    /// the owner says nothing — its `PostToolUse` cannot arrive until the nested claude exits — so
    /// any silence window short enough to be useful is also short enough to hand the pane to the
    /// very process this exists to ignore.
    private var ownerSessionID: String?

    /// When the screen engine STARTED contradicting the authoritative status without interruption,
    /// or `nil` when it currently agrees. Reset by agreement, by a change in WHAT the screen claims
    /// (``screenDissent``), and by every status transition — so only a steady, unchanging
    /// disagreement accumulates.
    private var screenDissentSince: TimeInterval?

    /// The screen VERDICT currently being dissented with — a different claim is a different
    /// argument and restarts the clock.
    ///
    /// The whole detection is kept, not just its ``AgentScreenState``, because the watchdog is
    /// resolved on a CLOCK rather than on the next fold (see ``resolveScreenDissentIfDue(at:)``):
    /// when the window elapses there may be no incoming detection to apply, so this is the one
    /// that gets applied. `visibleIdle` is load-bearing there — a plain idle cannot lower a hook
    /// block.
    private var screenDissent: AgentScreenDetection?

    /// How long the screen must claim BLOCKED, uninterrupted, before it may raise a block over a
    /// hook feed that never announced one. Short: the cost of being slow here is a human sitting in
    /// front of an unannounced dialog. Long enough that the ~300 ms scan must agree ~10 times
    /// running, so no single stale or torn read can reach it.
    public static let screenDissentToRaise: TimeInterval = 3.0

    /// How long the screen must contradict the authoritative status in the OTHER direction —
    /// wanting the pane out of a block, or off `working` — before it wins. Deliberately long:
    /// releasing early is the failure that was actually reported (the mark flaps AND `needsPermission
    /// → idle` mints a finished turn across every client), and every LEGITIMATE release announces
    /// itself on tier 1 already — an answered question fires `PostToolUse`, an approved permission
    /// fires `PreToolUse`, a finished turn fires `Stop`, and an Esc-cancel — the one resolution with
    /// no hook at all — arrives as ``ClaudeSignal/userInput`` in the same millisecond the key is
    /// pressed. Nothing correct is waiting on this window; it exists for the case where the hook
    /// feed itself has stopped being true.
    public static let screenDissentToRelease: TimeInterval = 10.0

    /// Cap for `label` — keeps the chip bounded regardless of a hostile/huge hook body.
    public static let maxLabel = 120

    public init(doneToIdleTimeout: TimeInterval = 8) {
        // Ordered max guards a negative / NaN injected timeout (validate-then-clamp; ordered
        // min/max per the repo's NaN-faithful convention, never a bare `<` ternary).
        self.doneToIdleTimeout = Double.maximum(0, doneToIdleTimeout)
        status = .none
        label = nil
        doneSince = nil
        blockSource = .none
        blockedSince = nil
        exitLockoutUntil = nil
        compactionPending = false
        isQuiet = false
        blockLedger = []
        authoritativeCovered = false
        ownerSessionID = nil
        screenDissentSince = nil
        screenDissent = nil
    }

    // MARK: - Published tier state

    /// TRUE while the pane's agent is announcing its own edges (a Claude hook feed, or any agent
    /// calling the ctl `report` verb) — the screen engine is then corroboration, not authority.
    /// Published for the ctl/diagnostic surfaces so "why did this pane not react" is answerable
    /// without re-deriving the rule.
    public var hasAuthoritativeFeed: Bool { authoritativeCovered }

    /// How many human-blocking calls are outstanding (the block ledger's depth). `0` whenever the
    /// pane is not hook-blocked.
    public var outstandingBlockCount: Int { blockLedger.count }

    /// The wire `kind` byte of the block the pane is ACTUALLY sitting on, or `0` when it is not
    /// hook-blocked (a screen-raised block carries no call identity, so it states no class).
    ///
    /// The MOST RECENT entry, because blocks stack modally: `[AskUserQuestion, PermissionRequest]`
    /// puts the approval dialog on top, and when that one resolves the question underneath is what
    /// the human is now looking at. Tracking the last byte SEEN instead reported the resolved
    /// block's class for as long as the surviving one stood.
    public var standingBlockKind: UInt8 {
        guard status == .needsPermission, let kind = blockLedger.last?.kind else { return 0 }
        return kind == .permission
            ? AgentStatusKind.permission.rawValue
            : AgentStatusKind.waitingForInput.rawValue
    }

    /// Fold one signal at absolute time `now`, returning the new status.
    @discardableResult
    public mutating func reduce(_ signal: ClaudeSignal, at now: TimeInterval) -> ClaudeStatus {
        switch signal {
        case let .processPresent(present):
            if present {
                liftPresenceFloor(at: now)
            } else {
                // Ground truth, not an announcement: the agent is demonstrably off the PTY
                // foreground. Nothing to defend against, so this path arms no lockout.
                terminate(armLockout: false, at: now)
            }

        case let .hook(event):
            apply(event, at: now)

        case let .manifestVerdict(verdict):
            applyManifest(verdict, at: now)

        case let .screen(detection):
            applyScreen(detection, at: now)

        case let .oscTitle(title):
            applyTitle(title, at: now)

        case .tick:
            break // pure time advance; decay handled below

        case .userInput:
            // A CANCEL key into a blocked pane = the modal is being DISMISSED. Demote to idle: an
            // Esc-cancel fires NO Stop hook, so idle is the truth nothing else would report. Every
            // other status is untouched — a keystroke never conjures presence, never demotes a live
            // turn, and never cuts the done decay. (Only a cancel reaches here: a dialog resolved
            // any other way re-promotes through its own hook, and demoting on plain navigation keys
            // manufactured a blocked→idle→blocked flap that re-rang the cue — see `ClaudeSignal`.)
            if status == .needsPermission {
                enter(.idle, label: nil)
                // ⚠️ QUIET. Dismissing a dialog is not a finished turn — but `needsPermission →
                // idle` is precisely the hook-less COMPLETION edge, so this transition used to mint
                // an unread badge, a banner and a sound for a pane the human had just pressed Esc
                // in, one they were by definition looking at. Nothing to announce: they did it.
                isQuiet = true
            }
        }

        // Both time-driven paths run on EVERY signal, ticks included — neither may wait for a
        // fold that the publish gate upstream may never deliver.
        resolveScreenDissentIfDue(at: now)
        decayIfDue(now: now)
        return status
    }

    // MARK: - Hook events (authoritative)

    private mutating func apply(_ event: ClaudeHookEvent, at now: TimeInterval) {
        // Whose pane is this? A nested `claude -p` inherits `SLOPDESK_PANE_ID` and posts the whole
        // hook set here; ignoring it is the difference between the pane showing its agent's block
        // and the pane going blank. See ``ownerSessionID``.
        guard claimOrVerifyOwner(of: event) else { return }
        // This is the agent describing ITSELF — a Claude hook, or any agent's ctl `report`. From
        // here the pane is authoritatively covered and the screen engine is a backstop. Set BEFORE
        // the switch so no branch can forget; `sessionEnd` clears it again through `terminate`.
        authoritativeCovered = true
        // The compaction marker is spent or dropped by the FIRST hook after it — `preCompact` arms
        // it below, every other event disarms it here (before the switch, so no branch can forget),
        // and `.stop` reads the armed copy taken on this line. See ``compactionPending``.
        let compactionEnded = compactionPending
        if case .preCompact = event {} else { compactionPending = false }
        switch event {
        case .preCompact:
            // No status of its own: a compaction runs INSIDE whatever the pane is already doing.
            // It only arms the marker (and corroborates presence like any other hook).
            compactionPending = true
            liftPresenceFloor(at: now)

        case .sessionStart:
            // Session opened → present & at rest. Clears any stale block/label.
            enter(.idle, label: nil)

        case .userPromptSubmit:
            enter(.working, label: nil)

        case let .preToolUse(_, _, toolUseID):
            // A tool STARTING resolves its own permission prompt (approved → it runs) and proves
            // every other permission dialog is gone, because a permission dialog is modal. It says
            // nothing about a sibling QUESTION in the same batch — that keeps its ledger entry, and
            // the pane stays blocked until the human actually answers.
            resolveLedger(call: toolUseID)
            if blockLedger.isEmpty {
                // The raw tool name is not useful chip text (the meaningful label is the Stop
                // message), so working transitions CLEAR the label.
                enter(.working, label: nil)
            }

        case let .postToolUse(_, _, toolUseID):
            // A tool result is mid-turn → keep working (don't fall back to idle/done here) — but
            // only once nothing is still waiting on the human.
            resolveLedger(call: toolUseID)
            if blockLedger.isEmpty { enter(.working, label: nil) }

        case let .notification(kind, label, toolUseID, _):
            switch kind {
            case .permission,
                 .waitingForInput:
                // An authoritative HOOK block — a conservative manifest verdict must NOT clear it.
                let entry = BlockEntry(
                    toolUseID: toolUseID,
                    kind: kind == .permission ? .permission : .ask,
                )
                enterBlocked(label: label, source: .hook, entry: entry, at: now)
            case .other:
                // Informational (auth_success / elicitation_complete) — no status change,
                // but it does corroborate presence (lift the floor off `.none`). Corroboration
                // is WEAK evidence, so it obeys the post-exit lockout like any other floor lift.
                liftPresenceFloor(at: now)
            }

        case let .stop(_, label):
            // A turn that ended on a COMPACTION is not a finished task — the agent is just
            // available again. `.idle` carries no notification, no sound and no unread badge, which
            // is the whole point: `/compact` used to announce "Claude is done" for housekeeping the
            // user ran themselves (user-reported 2026-08-10). The label goes with it — the last
            // assistant message belongs to the turn BEFORE the compaction, and captioning an idle
            // row with it would restate stale news.
            if compactionEnded {
                enter(.idle, label: nil)
                // …and MARK it: `.working → .idle` is the hook-less completion edge, so without this
                // the client re-announces the very finish this branch just suppressed (see ``isQuiet``).
                isQuiet = true
            } else {
                enter(.done, label: label, at: now)
            }

        case .subagentStop:
            // A subagent stopping does not change the parent pane's coarse status.
            break

        case .interrupted:
            // The human stopped the turn. There is no `Stop` for this, so without it the pane's
            // last authoritative word stayed `working` — spinner up, forever, until the watchdog
            // eventually corrected it into a FALSE "turn finished" ten seconds later. Quiet for the
            // same reason an Esc-cancelled dialog is: they did it, and they were watching.
            enter(.idle, label: nil)
            isQuiet = true

        case .sessionEnd:
            // The one signal that ARRIVES EARLY: claude posts it and then keeps running for
            // another second while it tears down. Arm the veto so nothing weak walks the pane
            // back out of `.none` across that gap.
            terminate(armLockout: true, at: now)
        }
        // ⚠️ A hook does NOT blindly reset the stopwatch. The clock measures how long the screen
        // has contradicted the AUTHORITATIVE STATUS, and a hook that leaves that contradiction
        // standing has not answered it. Blindly clearing here meant a turn still emitting hooks
        // held the watchdog at zero forever — which is exactly the situation a stale `.ask` ledger
        // entry creates, so the one case that needed the escape hatch was the one that disabled it.
        reconcileScreenDissent()
    }

    /// Drops the stopwatch iff the screen's remembered claim is no longer a contradiction.
    private mutating func reconcileScreenDissent() {
        guard let dissent = screenDissent else { return }
        if screenAgrees(with: dissent) { clearScreenDissent() }
    }

    /// The session id an event names, or `nil` when it names none. Tool calls and notifications
    /// carry no session in the adapter, and no ctl `report` ever does.
    private static func sessionID(of event: ClaudeHookEvent) -> String? {
        switch event {
        case let .sessionStart(id),
             let .userPromptSubmit(id),
             let .sessionEnd(id),
             let .interrupted(id),
             let .preCompact(id):
            id
        case let .preToolUse(id, _, _),
             let .postToolUse(id, _, _):
            id
        case let .stop(id, _):
            id
        case let .notification(_, _, _, id):
            id
        case .subagentStop:
            nil
        }
    }

    /// TRUE when `event` belongs to this pane: it names no session, it names the owner, or the
    /// pane is unclaimed. Pure — ask before folding when a CALLER has side effects of its own to
    /// suppress (``ClaudePaneDetector`` stamps a liveness anchor and re-titles the session from a
    /// prompt; neither should happen for a nested run's traffic).
    public func accepts(_ event: ClaudeHookEvent) -> Bool {
        guard let id = Self.sessionID(of: event), !id.isEmpty else { return true }
        guard let owner = ownerSessionID else { return true }
        if owner == id { return true }
        // The one handover: a new session starting on a pane whose turn is over — see
        // ``claimOrVerifyOwner(of:)``. This predicate must answer exactly what the fold will do, or
        // a caller gating on it drops an event the machine would have taken.
        if case .sessionStart = event, turnIsOver { return true }
        return false
    }

    /// ``accepts(_:)``, plus the claim: an id-carrying event on an unclaimed pane takes ownership,
    /// and a foreign `SessionStart` on a pane whose turn is OVER takes it over.
    ///
    /// ⚠️ The handover is what recovers a pane whose agent died without a `SessionEnd` (a crash,
    /// a `kill -9`). Presence would eventually free it, but ``ClaudePaneDetector`` suppresses a
    /// terminating absence for 30 s — 600 s behind a wrapper basename — so a human who simply
    /// re-runs `claude` in the same pane lands inside that window, and every hook of the new
    /// session names a session the pane has never heard of and is dropped WHOLE: no status, no
    /// finished turn, no title.
    ///
    /// It is gated on the pane being at rest because that is what a nested `claude -p` can never
    /// be: it is spawned BY a tool call, so the parent is `working` or blocked at that instant, by
    /// construction. A crash-restart is the opposite — nothing of the old session is in flight.
    /// (Mid-turn is left to the dissent watchdog, which frees ownership on its own; being briefly
    /// stale is recoverable, whereas following a nested run's `SessionEnd` blanks the pane.)
    private mutating func claimOrVerifyOwner(of event: ClaudeHookEvent) -> Bool {
        guard let id = Self.sessionID(of: event), !id.isEmpty else { return accepts(event) }
        if ownerSessionID == nil {
            ownerSessionID = id
            return true
        }
        if ownerSessionID == id { return true }
        guard case .sessionStart = event, turnIsOver else { return false }
        ownerSessionID = id
        return true
    }

    /// TRUE when nothing of the current session is in flight — the states a pane rests in between
    /// turns. (`.done` is a finished turn still inside its decay window; it is over all the same.)
    private var turnIsOver: Bool {
        status == .idle || status == .done || status == .none
    }

    // MARK: - OSC title (Claude Code's own busy/rest telltale)

    /// Claude Code writes its state into the terminal title: a Braille-spinner glyph prefix while
    /// a turn runs, a `✳ ` prefix at rest. That is the agent's own emission (not a heuristic
    /// screen scrape), so it corroborates liveness where hooks have gaps — conservatively:
    /// - the SPINNER promotes to `.working` only while claude is already detected (a title never
    ///   conjures presence) and never clears an authoritative HOOK block;
    /// - the REST prefix demotes ONLY a live `.working` → `.idle` (the missed-Stop stuck working state);
    ///   `.done` keeps its decay window and a block keeps waiting;
    /// - any other claude-naming title stays the presence floor it always was.
    private mutating func applyTitle(_ title: String, at now: TimeInterval) {
        if Self.titleShowsSpinner(title) {
            // ⚠️ Never out of `.done` while a hook feed is live. The title arrives on the PTY read
            // loop and the `Stop` on its own AF_UNIX queue, so a turn's trailing spinner repaint
            // routinely lands AFTER the `Stop` that ended it — promoting there erased the finished
            // state and its label, and the `✳` a moment later took `.working → .idle`, minting a
            // SECOND completion for the one turn. Under coverage the promotion buys nothing anyway:
            // `UserPromptSubmit`/`PreToolUse` announce a real turn starting.
            let stale = authoritativeCovered && status == .done
            if status != .none, blockSource != .hook, !stale { enter(.working, label: nil) }
            return
        }
        if Self.titleShowsRest(title) {
            if status == .working { enter(.idle, label: nil) }
            return
        }
        if Self.titleNamesClaude(title) { liftPresenceFloor(at: now) }
    }

    /// True when the title carries Claude Code's WORKING telltale — a leading Braille-pattern
    /// spinner glyph (U+2800–U+28FF).
    static func titleShowsSpinner(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(first.value)
    }

    /// True when the title carries Claude Code's AT-REST telltale — the leading `✳` (U+2733).
    static func titleShowsRest(_ title: String) -> Bool {
        title.unicodeScalars.first?.value == 0x2733
    }

    /// True when `title` is one Claude Code wrote ABOUT ITSELF: its busy or at-rest telltale, or a
    /// title naming the program. Exactly the three shapes this machine already believes as agent
    /// evidence — published so the host can decide the title belongs to the agent (and is the
    /// agent's to hand back when it exits) without re-deriving the vocabulary.
    public static func titleIsAgentWritten(_ title: String) -> Bool {
        titleShowsSpinner(title) || titleShowsRest(title) || titleNamesClaude(title)
    }

    // MARK: - Manifest verdict (conservative fallback)

    private mutating func applyManifest(_ verdict: ClaudeStatus, at now: TimeInterval) {
        // A coarse fallback verdict is the weakest evidence there is — it must never walk a pane
        // back out of an announced session end.
        if floorLocked(at: now) { return }
        switch verdict {
        case .none:
            // Unsure → never downgrade; presence is the floor.
            break
        case .needsPermission:
            // Only the manifest's strongest, conservative signal (a known approval UI). Tagged as a
            // MANIFEST block (NOT hook) so a later manifest verdict can clear it (review #5: the old
            // shared `hookBlocked` flag made a manifest-set block permanent).
            enterBlocked(label: label, source: .manifest, entry: nil, at: now)
        case .working:
            // A coarse "working" guess must NOT clear an authoritative HOOK block, but MAY clear a
            // manifest-sourced one (the manifest is the only authority then).
            if blockSource != .hook { enter(.working, label: nil) }
        case .idle:
            if blockSource != .hook, status == .none { enter(.idle, label: nil) }
        case .done:
            // Anchor the done→idle decay clock exactly like the hook `.stop` path — a
            // manifest-sourced done with a nil anchor would never decay (`decayIfDue` requires
            // `doneSince`), latching the pane `.done` until some other signal overrides it.
            if blockSource != .hook { enter(.done, label: label, at: now) }
        }
    }

    // MARK: - Screen-rule verdict (the herdr manifest engine)

    /// The screen engine is continuous ground truth over the live grid. Reconciliation with the
    /// hook edges (docs/DECISIONS round 4):
    /// - `blocked` raises a MANIFEST block (an existing hook block keeps its provenance);
    /// - `working` / a VISIBLE `idle` may clear even a HOOK block once it is ≥ the override
    ///   grace old (the dialog demonstrably left the screen — the Esc-cancel liberation);
    /// - a PLAIN idle (the no-rule fallback) is the weakest evidence: it clears manifest state
    ///   but never a hook block, and never cuts the `.done` decay (screen has no done concept);
    /// - `unknown` / `skipStateUpdate` change nothing (freeze — transcript viewer, model picker).
    /// The working→idle hold has already run UPSTREAM (the scan layer publishes post-hold).
    private mutating func applyScreen(_ detection: AgentScreenDetection, at now: TimeInterval) {
        guard !detection.skipStateUpdate else { return }
        // The scan runs every 300 ms off a grid claude has not finished vacating — inside the
        // post-exit lockout its verdicts describe an agent that already said goodbye.
        if floorLocked(at: now) { return }
        guard detection.state != .unknown else {
            clearScreenDissent()
            return
        }

        guard authoritativeCovered else {
            // No authoritative feed for this pane — the screen IS the authority (herdr's world).
            applyScreenVerdict(detection, correcting: false, at: now)
            return
        }
        // Tier 2 under coverage: corroborate, and otherwise keep a stopwatch on the disagreement.
        if screenAgrees(with: detection) {
            clearScreenDissent()
            return
        }
        // A different claim is a different argument: it re-anchors the clock.
        if screenDissent?.state != detection.state { armScreenDissent(detection, at: now) }
        screenDissent = detection // same claim, freshest evidence (visibleIdle can firm up)
        resolveScreenDissentIfDue(at: now)
    }

    /// The watchdog proper, run on the CLOCK rather than on the next fold.
    ///
    /// ⚠️ It cannot be driven by incoming detections. `AgentDetectionHold.shouldPublish` only
    /// publishes a CHANGED verdict, and its one heartbeat (`stableVisibleSignalRefreshDue`)
    /// requires `visibleBlocker` on both sides — so a steady idle/working dissent is folded
    /// EXACTLY ONCE and a fold-driven window can never elapse. Anchoring on the first dissenting
    /// fold and re-checking from ``reduce`` (every tick, every signal) is what makes the escape
    /// hatch reachable at all; before this it was unreachable in the live pipeline while passing
    /// its unit test, which drove `reduce(.screen(…))` directly.
    private mutating func resolveScreenDissentIfDue(at now: TimeInterval) {
        guard authoritativeCovered, let detection = screenDissent, let since = screenDissentSince
        else {
            return
        }
        let window = detection.state == .blocked
            ? Self.screenDissentToRaise
            : Self.screenDissentToRelease
        // Ordered comparison (NaN-faithful) — never a bare `<` ternary.
        guard now - since >= window else { return }
        // ⚠️ Try the verdict FIRST. A matured dissent whose verdict cannot apply — a PLAIN idle
        // against a hook block, say — used to revoke coverage and ownership anyway and then change
        // nothing, leaving the pane stale AND unclaimed, so the next `claude -p` could take it.
        // Authority is handed over only when the screen actually says something that lands.
        guard applyScreenVerdict(detection, correcting: true, at: now) else { return }
        // Uninterrupted contradiction past the window, and the screen had a usable verdict: the
        // hook feed has stopped describing this pane (relay dead, host restarted mid-session, a
        // record lost). Hand authority back — the move itself is already marked a CORRECTION.
        authoritativeCovered = false
        // …and free the pane. If the feed died because the AGENT did (a crash posts no
        // `SessionEnd`), the replacement's session id differs and would otherwise be ignored
        // forever — this is the only path that recovers that pane.
        ownerSessionID = nil
        clearScreenDissent()
    }

    private mutating func armScreenDissent(_ detection: AgentScreenDetection, at now: TimeInterval) {
        screenDissent = detection
        screenDissentSince = now
    }

    /// The screen engine's verdict applied as authority (no hook coverage, or the watchdog just
    /// took it back). `correcting` marks the move as bookkeeping rather than something that
    /// happened — see ``isQuiet``.
    /// Returns TRUE when the verdict actually LANDED — the watchdog reads this to decide whether
    /// handing authority over is justified (a verdict that cannot apply must not cost the pane its
    /// coverage and its session-ownership gate for nothing).
    @discardableResult
    private mutating func applyScreenVerdict(
        _ detection: AgentScreenDetection, correcting: Bool, at now: TimeInterval,
    ) -> Bool {
        switch detection.state {
        case .unknown:
            return false
        case .blocked:
            if status == .needsPermission { return false } // agreement — keep the richer provenance
            enterBlocked(label: nil, source: .manifest, entry: nil, at: now)
            return true
        case .working:
            if blockSource == .hook, !hookBlockOverridable(at: now) { return false }
            if status == .working { return false }
            enter(.working, label: nil)
            return true
        case .idle:
            if status == .done { return false } // the done decay outlives a merely-idle screen
            if blockSource == .hook {
                guard detection.visibleIdle, hookBlockOverridable(at: now) else { return false }
                enter(.idle, label: nil)
                // A hook said blocked and the screen disagreed for long enough to win. That is the
                // detector correcting ITSELF — never a turn the human should be told finished.
                isQuiet = true
                return true
            }
            guard status != .idle else { return false }
            let wasBlocked = correcting && status == .needsPermission
            enter(.idle, label: nil)
            if wasBlocked { isQuiet = true }
            return true
        }
    }

    /// Whether the screen's verdict is consistent with the authoritative status. Coarse on purpose —
    /// the two vocabularies do not line up exactly (the screen has no `done`, and `.none` means the
    /// tier-1 signals have not placed an agent yet), and only a CONTRADICTION should start a clock.
    private func screenAgrees(with detection: AgentScreenDetection) -> Bool {
        switch detection.state {
        case .unknown:
            true
        case .blocked:
            status == .needsPermission
        case .working:
            status == .working
        case .idle:
            // `.done` is a finished turn resting at its prompt — the screen sees exactly that and is
            // agreeing, not arguing. `.none` is nobody's claim to contradict.
            status == .idle || status == .done || status == .none
        }
    }

    private mutating func clearScreenDissent() {
        screenDissentSince = nil
        screenDissent = nil
    }

    /// True once the current block is old enough for the screen to have painted its dialog —
    /// a contradicting screen verdict is then believed. Ordered comparison (NaN-faithful).
    private func hookBlockOverridable(at now: TimeInterval) -> Bool {
        guard let since = blockedSince else { return true }
        let elapsed = now - since
        return elapsed >= Self.hookBlockScreenOverrideGrace
    }

    // MARK: - State entry helpers

    /// Presence floor — lift `.none` to `.idle`; never downgrade a richer status. Vetoed while the
    /// post-exit lockout stands: presence is exactly the signal that lags an announced session end.
    private mutating func liftPresenceFloor(at now: TimeInterval) {
        if floorLocked(at: now) { return }
        if status == .none { enter(.idle, label: nil) }
    }

    /// TRUE while a hook-announced session end still vetoes weak liveness evidence. Ordered
    /// comparison (NaN-faithful) — never a bare `<` ternary.
    private func floorLocked(at now: TimeInterval) -> Bool {
        guard let until = exitLockoutUntil else { return false }
        return Double.minimum(now, until) < until
    }

    /// Drops the veto — an AUTHORITATIVE signal (a real hook naming a live session) is proof the
    /// pane has an agent again, and outranks the exit it may still be racing.
    private mutating func clearExitLockout() {
        exitLockoutUntil = nil
    }

    private mutating func enterBlocked(
        label: String?, source: BlockSource, entry: BlockEntry?, at now: TimeInterval,
    ) {
        clearExitLockout()
        clearScreenDissent()
        isQuiet = false
        // A re-assertion of a standing block keeps the ORIGINAL entry time — the override grace
        // measures how long the dialog has been up, not how recently a hook repeated itself.
        if status != .needsPermission { blockedSince = now }
        // A screen/manifest block carries no call identity, so it never touches the ledger: the
        // provenance flag alone governs it, exactly as before. Only hook blocks are itemised.
        if let entry, !blockLedger.contains(entry) { blockLedger.append(entry) }
        blockSource = source
        doneSince = nil
        status = .needsPermission
        if let label { self.label = Self.clampLabel(label) }
    }

    // MARK: - The block ledger

    /// Resolves the ledger for one tool call — STARTING (its permission was granted, so it runs) or
    /// FINISHED, which are the same fact for a block: that call is no longer waiting on a human.
    /// Takes its own entry, plus the id-less ones — those name no call, so this is the only handle
    /// they will ever have.
    ///
    /// ⚠️ A STARTING call used to drop every `.permission` entry regardless of id, on the reasoning
    /// that a permission dialog is modal so anything starting proves none is up. That reasoning is
    /// false for a BATCH: `[Read(a), Bash(gated)]` raises the dialog on `Bash` and then `Read`'s own
    /// `PreToolUse` fires while the human is still looking at it — the same failure the ledger was
    /// built to fix, left open in this one direction. The denial it stood in for is announced
    /// properly now (`PermissionDenied`, `AgentInstaller.installedEvents`), so a permission entry
    /// resolves by identity like every other kind, and a hand nothing answers still comes down on
    /// Esc, on `Stop`, and on the sustained-dissent watchdog.
    private mutating func resolveLedger(call id: String?) {
        blockLedger.removeAll { entry in
            if entry.toolUseID == nil { return true }
            return entry.toolUseID == id
        }
    }

    /// Enter a non-blocked status. `at` non-nil marks the done-decay anchor.
    private mutating func enter(_ next: ClaudeStatus, label newLabel: String?, at now: TimeInterval? = nil) {
        clearExitLockout()
        clearScreenDissent()
        // Cleared HERE (the one funnel for every non-blocked transition) and re-set by the single
        // caller that means it — so a quiet mark can never survive into a status it did not qualify.
        isQuiet = false
        blockSource = .none
        blockedSince = nil
        // Leaving the blocked state at all retires every outstanding call: a turn boundary (Stop,
        // a new prompt, SessionStart) means nothing from the old turn is still being asked.
        blockLedger.removeAll()
        status = next
        label = newLabel.map(Self.clampLabel)
        if next == .done {
            doneSince = now
        } else {
            doneSince = nil
        }
    }

    /// Drop to `.none`. `armLockout` distinguishes the two ways a session dies: a hook `sessionEnd`
    /// ANNOUNCES the end while the process still runs (arm the veto), whereas process absence IS
    /// the end already observed (nothing to defend).
    private mutating func terminate(armLockout: Bool, at now: TimeInterval) {
        status = .none
        label = nil
        doneSince = nil
        blockSource = .none
        blockedSince = nil
        // A session boundary retires the marker with everything else — a compaction cannot straddle
        // two sessions, and a stale one would swallow the next session's first genuine finish.
        compactionPending = false
        isQuiet = false
        blockLedger.removeAll()
        // Coverage belongs to a SESSION. The next session earns its own on its first hook — and
        // until then this pane is back to screen-and-presence detection, which is the correct
        // reading of "we have not heard from an agent here".
        authoritativeCovered = false
        ownerSessionID = nil
        clearScreenDissent()
        if armLockout { exitLockoutUntil = now + Self.postExitFloorLockout }
    }

    // MARK: - Time-based decay (injected clock)

    private mutating func decayIfDue(now: TimeInterval) {
        guard status == .done, let since = doneSince else { return }
        // Ordered comparison; decay once the elapsed time reaches the timeout.
        let elapsed = now - since
        if elapsed >= doneToIdleTimeout {
            enter(.idle, label: nil)
        }
    }

    // MARK: - Helpers

    private static func clampLabel(_ s: String) -> String {
        // Bound the chip text; validate-then-clamp on a hostile/huge body. Empty → nil.
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.count <= maxLabel { return trimmed }
        return String(trimmed.prefix(maxLabel))
    }

    /// True when an OSC 2 title names Claude (e.g. `Claude: my-project`, `✳ Claude Code`).
    static func titleNamesClaude(_ title: String) -> Bool {
        title.range(of: "claude", options: .caseInsensitive) != nil
    }
}

public extension ClaudeStatusMachine {
    /// Convenience: the label, but `nil` when it is empty (the clamp can yield "").
    var displayLabel: String? {
        guard let label, !label.isEmpty else { return nil }
        return label
    }
}
