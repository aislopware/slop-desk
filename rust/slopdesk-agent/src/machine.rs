//! The per-pane status state machine: a PURE, deterministic fold over every detection signal.
//!
//! A 1:1 port of `ClaudeStatusMachine.swift` (docs/41 §4.3, docs/42 W7). Every design note below is
//! the Swift one, kept because it is the record of what each rule cost to learn.

use crate::screen::{AgentScreenDetection, AgentScreenState};
use crate::signal::{ClaudeHookEvent, ClaudeSignal, NotificationKind};
use crate::status::{AgentStatusKind, ClaudeStatus};

/// What KIND of thing is waiting on the human — the two differ in what may resolve them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BlockKind {
    /// A permission dialog. Strictly MODAL: nothing else can START while it is up, so any
    /// `PreToolUse` proves it is gone — which is what covers a DENIED permission, the one
    /// resolution Claude Code announces with no hook of its own.
    Permission,
    /// The agent asking the human a question (`AskUserQuestion`, `elicitation_dialog`). Resolved
    /// ONLY by its own `PostToolUse`, a turn boundary, or a cancel key — a sibling call in the same
    /// batch finishing says nothing about whether the human has answered.
    Ask,
}

/// One outstanding human-blocking call.
#[derive(Debug, Clone, PartialEq, Eq)]
struct BlockEntry {
    /// The blocking call's `tool_use_id`, or `None` for a notification that names no call.
    tool_use_id: Option<String>,
    kind: BlockKind,
}

/// The provenance of an active block — what gates whether a conservative manifest verdict is
/// allowed to clear it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum BlockSource {
    /// Not blocked.
    #[default]
    None,
    /// An authoritative HOOK notification — a manifest verdict must NOT clear it.
    Hook,
    /// The no-hooks fallback's strongest cue (a known approval UI) — a later manifest working/idle
    /// MAY clear it, because the manifest is the only authority in play.
    Manifest,
}

/// A PURE, deterministic per-pane agent-status state machine.
///
/// **The clock is injected.** Every [`reduce`](Self::reduce) takes an absolute `now`; the machine
/// never reads a clock of its own. The only time-driven transitions are the done→idle decay and the
/// screen-dissent watchdog, and both are re-checked on every fold.
///
/// # Signal precedence (defense in depth, docs/41 §4.2)
/// 1. Process absence / `SessionEnd` → [`ClaudeStatus::None`]; termination wins and clears
///    everything.
/// 2. Authoritative HOOK events set the status directly.
/// 3. Process presence and a claude-naming OSC title lift a presence FLOOR of
///    [`ClaudeStatus::Idle`] — never downgrading a richer hook status. The title's spinner and
///    at-rest prefixes additionally corroborate working/idle.
/// 4. A coarse manifest verdict is CONSERVATIVE: [`ClaudeStatus::None`] is ignored, and the rest
///    apply only when an authoritative hook block is not already in effect.
///
/// # Two tiers, and what decides which is in force (2026-08-11)
/// Precedence alone says which signal wins a collision; it does not say whether a weak signal
/// should be in the argument at all. Once a pane is HOOK-COVERED — [`has_authoritative_feed`], set
/// by the first hook of a session and dropped only when the session ends — the agent is TELLING us
/// its state on every edge, and the screen engine is a heuristic reading of pixels the agent draws
/// for a human. So the screen stops being a peer:
///
/// - **Tier 1 (authoritative)** — hooks, the ctl `report` verb, presence ABSENCE, and a CANCEL
///   keystroke. These change the status, immediately, always.
/// - **Tier 2 (inferred)** — the screen engine, the OSC title, the presence floor. Under coverage
///   the screen may only CORROBORATE; it cannot move the status.
///
/// …with one escape hatch, because hooks are best-effort (the relay can die, a record can be lost,
/// the host can restart mid-session): the dissent stopwatch times how long the screen has
/// contradicted the authoritative status WITHOUT INTERRUPTION. Past the window the pane drops
/// coverage and the screen applies. Asymmetric on purpose — [`SCREEN_DISSENT_TO_RAISE`] is short (a
/// human waiting on an unannounced dialog is the expensive failure) and
/// [`SCREEN_DISSENT_TO_RELEASE`] is long (a premature release flaps the mark AND mints a false
/// finished turn, which is the failure that was actually reported). Any hook restores coverage and
/// resets the clock instantly.
///
/// This is where we diverge from herdr on purpose: herdr has no hook feed, so its screen
/// engine IS its authority and every heuristic has to be load-bearing. Ours is a backstop.
///
/// # Post-exit lockout
/// Precedence alone is not enough for teardown, because the terminating signal ARRIVES EARLY:
/// `SessionEnd` is posted while the agent is still the PTY foreground, so for a second or so every
/// weak signal still describes a live agent and lifts the floor straight back off
/// [`ClaudeStatus::None`]. A `SessionEnd` therefore arms [`POST_EXIT_FLOOR_LOCKOUT`], during which
/// no weak signal may lift the floor; only an authoritative hook clears it. Presence ABSENCE arms
/// nothing — it is the end already observed, not an announcement of one.
///
/// [`has_authoritative_feed`]: Self::has_authoritative_feed
/// [`SCREEN_DISSENT_TO_RAISE`]: Self::SCREEN_DISSENT_TO_RAISE
/// [`SCREEN_DISSENT_TO_RELEASE`]: Self::SCREEN_DISSENT_TO_RELEASE
/// [`POST_EXIT_FLOOR_LOCKOUT`]: Self::POST_EXIT_FLOOR_LOCKOUT
#[derive(Debug, Clone, PartialEq)]
pub struct ClaudeStatusMachine {
    /// Seconds a done status lingers before decaying to idle.
    done_to_idle_timeout: f64,
    status: ClaudeStatus,
    label: Option<String>,
    /// TRUE while the CURRENT status is one the human must not be told about.
    is_quiet: bool,
    /// Absolute time the status entered done — the decay anchor.
    done_since: Option<f64>,
    block_source: BlockSource,
    /// Absolute time the machine entered the current block. Gates the screen engine's hook-block
    /// override: a screen verdict may clear a hook block only once the block is at least
    /// [`HOOK_BLOCK_SCREEN_OVERRIDE_GRACE`](Self::HOOK_BLOCK_SCREEN_OVERRIDE_GRACE) old — younger
    /// blocks win, covering the stale-snapshot race right after a hook fires, before the dialog
    /// paints.
    blocked_since: Option<f64>,
    /// Absolute time the post-exit floor lockout lapses, or `None` when no session has announced
    /// its end.
    exit_lockout_until: Option<f64>,
    /// TRUE between a `PreCompact` hook and the next thing that happens — the COMPACTION MARKER.
    ///
    /// Claude Code ends a `/compact` the way it ends any turn: with a `Stop`. That put the pane at
    /// done, which fired the finished-turn notification, the sound and the unread badge for a
    /// housekeeping command the user ran themselves and watched complete (user-reported
    /// 2026-08-10). Done means "your work is finished"; a compaction finishing is the agent simply
    /// available again, which is idle.
    ///
    /// A one-shot ARMED by `PreCompact` and DISARMED by any subsequent turn activity. That
    /// disarming is what keeps the AUTOMATIC mid-turn compaction honest: it fires `PreCompact`, the
    /// turn RESUMES, and the `Stop` at the end of that is a genuine finish, so by then the marker
    /// is long gone. Only a compaction that is the last thing to happen before the turn ends spends
    /// it.
    compaction_pending: bool,
    /// The OUTSTANDING human-blocking tool calls, in arrival order — the BLOCK LEDGER.
    ///
    /// A hook block used to be one flag, so "the pane is blocked" and "this specific call is
    /// waiting on a human" were the same fact, and ANY `PostToolUse` cleared it. Claude Code emits
    /// tool calls in BATCHES: an assistant turn carrying `[AskUserQuestion, Bash]` fires both
    /// `PreToolUse` hooks, and the `Bash` result then landed while the question was still on screen
    /// and un-answered — clearing the block, marking the turn finished, and handing the pane back
    /// to a human who was still being asked something.
    ///
    /// Keyed by `tool_use_id`, a resolution names the call it resolves and nothing else. Entries
    /// with NO id name no call, so they keep the old any-tool-clears-it rule — there is no better
    /// handle, and the alternative is a hand nothing can lower.
    block_ledger: Vec<BlockEntry>,
    /// TRUE once an AUTHORITATIVE event has been folded for the live session.
    ///
    /// "Authoritative" is deliberately not "Claude hook". Two feeds reach the fold and both earn
    /// coverage: the Claude Code hook socket, and the ctl `report` verb — which ANY agent or
    /// orchestrator in a pane can call. So a codex / gemini / bespoke wrapper that reports its own
    /// state gets exactly the tier-1 treatment Claude gets, screen demotion and watchdog included,
    /// with no per-agent code. That is the whole point of keying this on the FEED rather than on
    /// the agent's name.
    ///
    /// Deliberately NOT a recency window: a pane blocked on a question for ten minutes emits no
    /// traffic at all, and that silence is the block working exactly as intended, not evidence the
    /// feed has died. Only a session ENDING drops it — plus the dissent watchdog, which is the "the
    /// feed died anyway" path.
    authoritative_covered: bool,
    /// The session id that OWNS this pane, or `None` while the pane is unclaimed.
    ///
    /// ⚠️ The hook relay routes by `SLOPDESK_PANE_ID`, an ENVIRONMENT VARIABLE — so every
    /// descendant of the pane's shell inherits it. A `claude -p …` run from a script, a Makefile,
    /// or the pane agent's own Bash tool is a SEPARATE agent with its own session id, posting the
    /// full hook set to the pane that spawned it. Ungated, its `SessionStart` cleared the pane
    /// agent's block, its `Stop` minted a finished turn for a turn that never finished, and its
    /// `SessionEnd` blanked the pane and armed the post-exit lockout — all while the pane's real
    /// agent was still waiting on a human.
    ///
    /// So: the first id-carrying event claims the pane; events naming a DIFFERENT session are
    /// dropped whole. Events carrying NO session id always apply and never claim, so an
    /// unattributed feed behaves exactly as it did before this existed.
    ///
    /// Deliberately NOT released on a timer. A nested run can hold the terminal for minutes while
    /// the owner says nothing — its `PostToolUse` cannot arrive until the nested agent exits — so
    /// any silence window short enough to be useful is also short enough to hand the pane to the
    /// very process this exists to ignore.
    owner_session_id: Option<String>,
    /// When the screen engine STARTED contradicting the authoritative status without interruption,
    /// or `None` when it currently agrees.
    screen_dissent_since: Option<f64>,
    /// The screen VERDICT currently being dissented with — a different claim is a different
    /// argument and restarts the clock.
    ///
    /// The whole detection is kept, not just its state, because the watchdog is resolved on a CLOCK
    /// rather than on the next fold: when the window elapses there may be no incoming detection to
    /// apply, so this is the one that gets applied. `visible_idle` is load-bearing there — a plain
    /// idle cannot lower a hook block.
    screen_dissent: Option<AgentScreenDetection>,
}

impl Default for ClaudeStatusMachine {
    fn default() -> Self {
        Self::new(Self::DEFAULT_DONE_TO_IDLE_TIMEOUT)
    }
}

impl ClaudeStatusMachine {
    /// The default done→idle decay: long enough to be seen, short enough not to lie about a pane
    /// that has been resting for a while.
    pub const DEFAULT_DONE_TO_IDLE_TIMEOUT: f64 = 8.0;

    /// Seconds a HOOK-sourced block outranks a contradicting screen verdict.
    ///
    /// The scan cadence is 300 ms and a dialog paints within a frame, so 1 s comfortably covers the
    /// race while the Esc-cancel liberation (a visible idle prompt box after the dialog closes)
    /// stays sub-second after the grace.
    pub const HOOK_BLOCK_SCREEN_OVERRIDE_GRACE: f64 = 1.0;

    /// Seconds a hook-announced session end vetoes every WEAK liveness signal.
    ///
    /// `SessionEnd` fires while the agent process is still alive: the PTY foreground was measured
    /// coming back to the shell 1.0–1.5 s later across six captured `/exit` runs. Across that gap
    /// the ~1 Hz foreground poll, the 300 ms screen scan and the still-painted OSC title all keep
    /// reporting a live agent, and any one of them lifting the presence floor resurrects the pane
    /// milliseconds after it went dark. 3 s clears the widest measured overlap with margin.
    ///
    /// Deliberately NOT a mute: an authoritative hook — a genuinely new session — clears it at
    /// once, so an agent relaunched immediately is never held dark; and the window is short enough
    /// that a hook-free pane's presence-only detection resumes on its next poll or two. The absence
    /// path arms nothing: process absence is already ground truth.
    pub const POST_EXIT_FLOOR_LOCKOUT: f64 = 3.0;

    /// How long the screen must claim BLOCKED, uninterrupted, before it may raise a block over a
    /// hook feed that never announced one.
    ///
    /// Short: the cost of being slow here is a human sitting in front of an unannounced dialog.
    /// Long enough that the ~300 ms scan must agree ~10 times running, so no single stale or torn
    /// read can reach it.
    pub const SCREEN_DISSENT_TO_RAISE: f64 = 3.0;

    /// How long the screen must contradict the authoritative status in the OTHER direction —
    /// wanting the pane out of a block, or off working — before it wins.
    ///
    /// Deliberately long: releasing early is the failure that was actually reported (the mark flaps
    /// AND blocked→idle mints a finished turn across every client), and every LEGITIMATE release
    /// announces itself on tier 1 already — an answered question fires `PostToolUse`, an approved
    /// permission fires `PreToolUse`, a finished turn fires `Stop`, and an Esc-cancel — the one
    /// resolution with no hook at all — arrives as
    /// [`ClaudeSignal::UserInput`](crate::signal::ClaudeSignal::UserInput) in the same millisecond
    /// the key is pressed. Nothing correct is waiting on this window; it exists for the case where
    /// the hook feed itself has stopped being true.
    pub const SCREEN_DISSENT_TO_RELEASE: f64 = 10.0;

    /// Cap for the label, in scalars — keeps the chip bounded regardless of a hostile or huge hook
    /// body.
    pub const MAX_LABEL: usize = 120;

    /// A fresh machine whose done status decays after `done_to_idle_timeout` seconds.
    ///
    /// The timeout is clamped through an ordered max, so a negative or NaN injected value cannot
    /// produce a decay that never fires or fires instantly at an unexamined moment.
    #[must_use]
    pub const fn new(done_to_idle_timeout: f64) -> Self {
        Self {
            done_to_idle_timeout: f64::max(0.0, done_to_idle_timeout),
            status: ClaudeStatus::None,
            label: None,
            is_quiet: false,
            done_since: None,
            block_source: BlockSource::None,
            blocked_since: None,
            exit_lockout_until: None,
            compaction_pending: false,
            block_ledger: Vec::new(),
            authoritative_covered: false,
            owner_session_id: None,
            screen_dissent_since: None,
            screen_dissent: None,
        }
    }

    // MARK: Published state

    /// The current rolled-up status.
    #[must_use]
    pub const fn status(&self) -> ClaudeStatus {
        self.status
    }

    /// The short human label — the last assistant message, or a permission prompt's text — for the
    /// pane chrome chip.
    #[must_use]
    pub fn label(&self) -> Option<&str> {
        self.label.as_deref()
    }

    /// The label, but absent when it is empty (the clamp can yield `""`).
    #[must_use]
    pub fn display_label(&self) -> Option<&str> {
        self.label.as_deref().filter(|label| !label.is_empty())
    }

    /// TRUE while the CURRENT status change is bookkeeping rather than news — deliver it to the
    /// dots and the chrome, but raise no attention.
    #[must_use]
    pub const fn is_quiet(&self) -> bool {
        self.is_quiet
    }

    /// The decay window this machine was built with, after clamping.
    #[must_use]
    pub const fn done_to_idle_timeout(&self) -> f64 {
        self.done_to_idle_timeout
    }

    /// TRUE while the pane's agent is announcing its own edges — the screen engine is then
    /// corroboration, not authority.
    ///
    /// Published for the ctl and diagnostic surfaces, so "why did this pane not react" is
    /// answerable without re-deriving the rule.
    #[must_use]
    pub const fn has_authoritative_feed(&self) -> bool {
        self.authoritative_covered
    }

    /// How many human-blocking calls are outstanding — the block ledger's depth. Zero whenever the
    /// pane is not hook-blocked.
    #[must_use]
    pub const fn outstanding_block_count(&self) -> usize {
        self.block_ledger.len()
    }

    /// The wire `kind` byte of the block the pane is ACTUALLY sitting on, or `0` when it is not
    /// hook-blocked (a screen-raised block carries no call identity, so it states no class).
    ///
    /// The MOST RECENT entry, because blocks stack modally: `[AskUserQuestion, PermissionRequest]`
    /// puts the approval dialog on top, and when that one resolves the question underneath is what
    /// the human is now looking at. Tracking the last byte SEEN instead reported the resolved
    /// block's class for as long as the surviving one stood.
    #[must_use]
    pub fn standing_block_kind(&self) -> u8 {
        if self.status != ClaudeStatus::NeedsPermission {
            return AgentStatusKind::None.wire_byte();
        }
        match self.block_ledger.last().map(|entry| entry.kind) {
            Some(BlockKind::Permission) => AgentStatusKind::Permission.wire_byte(),
            Some(BlockKind::Ask) => AgentStatusKind::WaitingForInput.wire_byte(),
            None => AgentStatusKind::None.wire_byte(),
        }
    }

    // MARK: The fold

    /// Folds one signal at absolute time `now`, returning the new status.
    ///
    /// Idempotent on duplicate signals; out-of-order and unknown signals never fail
    /// (validate-then-drop).
    pub fn reduce(&mut self, signal: ClaudeSignal, now: f64) -> ClaudeStatus {
        match signal {
            ClaudeSignal::ProcessPresent(present) => {
                if present {
                    self.lift_presence_floor(now);
                } else {
                    // Ground truth, not an announcement: the agent is demonstrably off the PTY
                    // foreground. Nothing to defend against, so this path arms no lockout.
                    self.terminate(false, now);
                }
            },
            ClaudeSignal::Hook(event) => self.apply(event, now),
            ClaudeSignal::ManifestVerdict(verdict) => self.apply_manifest(verdict, now),
            ClaudeSignal::Screen(detection) => self.apply_screen(detection, now),
            ClaudeSignal::OscTitle(title) => self.apply_title(&title, now),
            // A pure time advance; the decay below handles it.
            ClaudeSignal::Tick => {},
            ClaudeSignal::UserInput => {
                // A CANCEL key into a blocked pane = the modal is being DISMISSED. Demote to idle:
                // an Esc-cancel fires NO Stop hook, so idle is the truth nothing else would report.
                // Every other status is untouched — a keystroke never conjures presence, never
                // demotes a live turn, and never cuts the done decay.
                if self.status == ClaudeStatus::NeedsPermission {
                    self.enter(ClaudeStatus::Idle, None, None);
                    // ⚠️ QUIET. Dismissing a dialog is not a finished turn — but blocked → idle is
                    // precisely the hook-less COMPLETION edge, so this transition used to mint an
                    // unread badge, a banner and a sound for a pane the human had just pressed Esc
                    // in, one they were by definition looking at. Nothing to announce: they did it.
                    self.is_quiet = true;
                }
            },
        }

        // Both time-driven paths run on EVERY signal, ticks included — neither may wait for a fold
        // that the publish gate upstream may never deliver.
        self.resolve_screen_dissent_if_due(now);
        self.decay_if_due(now);
        self.status
    }

    // MARK: Hook events (authoritative)

    fn apply(&mut self, event: ClaudeHookEvent, now: f64) {
        // Whose pane is this? A nested `claude -p` inherits `SLOPDESK_PANE_ID` and posts the whole
        // hook set here; ignoring it is the difference between the pane showing its agent's block
        // and the pane going blank.
        if !self.claim_or_verify_owner(&event) {
            return;
        }
        // This is the agent describing ITSELF — a hook, or any agent's ctl `report`. From here the
        // pane is authoritatively covered and the screen engine is a backstop. Set BEFORE the match
        // so no branch can forget; `SessionEnd` clears it again through `terminate`.
        self.authoritative_covered = true;
        // The compaction marker is spent or dropped by the FIRST hook after it — `PreCompact` arms
        // it below, every other event disarms it here (before the match, so no branch can forget),
        // and `Stop` reads the armed copy taken on this line.
        let compaction_ended = self.compaction_pending;
        if !matches!(event, ClaudeHookEvent::PreCompact { .. }) {
            self.compaction_pending = false;
        }
        match event {
            // No status of its own: a compaction runs INSIDE whatever the pane is already doing. It
            // only arms the marker, and corroborates presence like any other hook.
            ClaudeHookEvent::PreCompact { .. } => {
                self.compaction_pending = true;
                self.lift_presence_floor(now);
            }
            // Session opened → present and at rest. Clears any stale block or label.
            ClaudeHookEvent::SessionStart { .. } => self.enter(ClaudeStatus::Idle, None, None),
            ClaudeHookEvent::UserPromptSubmit { .. } => {
                self.enter(ClaudeStatus::Working, None, None);
            }
            // A tool STARTING resolves its own permission prompt (approved → it runs). It says
            // nothing about a sibling QUESTION in the same batch — that keeps its ledger entry, and
            // the pane stays blocked until the human actually answers.
            ClaudeHookEvent::PreToolUse { tool_use_id, .. }
            // A tool result is mid-turn → keep working (never fall back to idle or done here) — but
            // only once nothing is still waiting on the human.
            | ClaudeHookEvent::PostToolUse { tool_use_id, .. } => {
                self.resolve_ledger(tool_use_id.as_deref());
                if self.block_ledger.is_empty() {
                    // The raw tool name is not useful chip text (the meaningful label is the Stop
                    // message), so working transitions CLEAR the label.
                    self.enter(ClaudeStatus::Working, None, None);
                }
            }
            ClaudeHookEvent::Notification { kind, label, tool_use_id, .. } => match kind {
                NotificationKind::Permission | NotificationKind::WaitingForInput => {
                    // An authoritative HOOK block — a conservative manifest verdict must NOT clear
                    // it.
                    let entry = BlockEntry {
                        tool_use_id,
                        kind: if matches!(kind, NotificationKind::Permission) {
                            BlockKind::Permission
                        } else {
                            BlockKind::Ask
                        },
                    };
                    self.enter_blocked(label, BlockSource::Hook, Some(entry), now);
                }
                // Informational — no status change, but it does corroborate presence.
                // Corroboration is WEAK evidence, so it obeys the post-exit lockout like any other
                // floor lift.
                NotificationKind::Other => self.lift_presence_floor(now),
            },
            ClaudeHookEvent::Stop { label, .. } => {
                // A turn that ended on a COMPACTION is not a finished task — the agent is just
                // available again. Idle carries no notification, no sound and no unread badge,
                // which is the whole point: `/compact` used to announce "Claude is done" for
                // housekeeping the user ran themselves (user-reported 2026-08-10). The label goes
                // with it — the last assistant message belongs to the turn BEFORE the compaction,
                // and captioning an idle row with it would restate stale news.
                if compaction_ended {
                    self.enter(ClaudeStatus::Idle, None, None);
                    // …and MARK it: working → idle is the hook-less completion edge, so without
                    // this the client re-announces the very finish this branch just suppressed.
                    self.is_quiet = true;
                } else {
                    self.enter(ClaudeStatus::Done, label, Some(now));
                }
            }
            // A subagent stopping does not change the parent pane's coarse status.
            ClaudeHookEvent::SubagentStop { .. } => {}
            // The human stopped the turn. There is no `Stop` for this, so without it the pane's
            // last authoritative word stayed working — spinner up, forever, until the watchdog
            // eventually corrected it into a FALSE "turn finished" ten seconds later. Quiet for the
            // same reason an Esc-cancelled dialog is: they did it, and they were watching.
            ClaudeHookEvent::Interrupted { .. } => {
                self.enter(ClaudeStatus::Idle, None, None);
                self.is_quiet = true;
            }
            // The one signal that ARRIVES EARLY: the agent posts it and then keeps running for
            // another second while it tears down. Arm the veto so nothing weak walks the pane back
            // out of the terminal status across that gap.
            ClaudeHookEvent::SessionEnd { .. } => self.terminate(true, now),
        }
        // ⚠️ A hook does NOT blindly reset the stopwatch. The clock measures how long the screen has
        // contradicted the AUTHORITATIVE STATUS, and a hook that leaves that contradiction standing
        // has not answered it. Blindly clearing here meant a turn still emitting hooks held the
        // watchdog at zero forever — which is exactly the situation a stale ask-ledger entry
        // creates, so the one case that needed the escape hatch was the one that disabled it.
        self.reconcile_screen_dissent();
    }

    /// Drops the stopwatch iff the screen's remembered claim is no longer a contradiction.
    fn reconcile_screen_dissent(&mut self) {
        let Some(dissent) = self.screen_dissent.clone() else {
            return;
        };
        if self.screen_agrees(&dissent) {
            self.clear_screen_dissent();
        }
    }

    /// TRUE when `event` belongs to this pane: it names no session, it names the owner, or the pane
    /// is unclaimed.
    ///
    /// Pure — ask before folding when a CALLER has side effects of its own to suppress (the host's
    /// pane detector stamps a liveness anchor and re-titles the session from a prompt; neither
    /// should happen for a nested run's traffic).
    #[must_use]
    pub fn accepts(&self, event: &ClaudeHookEvent) -> bool {
        let Some(id) = event.session_id().filter(|id| !id.is_empty()) else {
            return true;
        };
        let Some(owner) = self.owner_session_id.as_deref() else {
            return true;
        };
        if owner == id {
            return true;
        }
        // The one handover: a new session starting on a pane whose turn is over. This predicate
        // must answer exactly what the fold will do, or a caller gating on it drops an event the
        // machine would have taken.
        matches!(event, ClaudeHookEvent::SessionStart { .. }) && self.turn_is_over()
    }

    /// [`accepts`](Self::accepts), plus the claim: an id-carrying event on an unclaimed pane takes
    /// ownership, and a foreign `SessionStart` on a pane whose turn is OVER takes it over.
    ///
    /// ⚠️ The handover is what recovers a pane whose agent died without a `SessionEnd` (a crash, a
    /// `kill -9`). Presence would eventually free it, but the host suppresses a terminating absence
    /// for 30 s — 600 s behind a wrapper basename — so a human who simply re-runs the agent in the
    /// same pane lands inside that window, and every hook of the new session names a session the
    /// pane has never heard of and is dropped WHOLE: no status, no finished turn, no title.
    ///
    /// It is gated on the pane being at rest because that is what a nested `claude -p` can never
    /// be: it is spawned BY a tool call, so the parent is working or blocked at that instant, by
    /// construction. A crash-restart is the opposite — nothing of the old session is in flight.
    /// (Mid-turn is left to the dissent watchdog, which frees ownership on its own; being briefly
    /// stale is recoverable, whereas following a nested run's `SessionEnd` blanks the pane.)
    fn claim_or_verify_owner(&mut self, event: &ClaudeHookEvent) -> bool {
        let Some(id) = event.session_id().filter(|id| !id.is_empty()) else {
            return self.accepts(event);
        };
        let Some(owner) = self.owner_session_id.as_deref() else {
            self.owner_session_id = Some(id.to_owned());
            return true;
        };
        if owner == id {
            return true;
        }
        if !matches!(event, ClaudeHookEvent::SessionStart { .. }) || !self.turn_is_over() {
            return false;
        }
        self.owner_session_id = Some(id.to_owned());
        true
    }

    /// TRUE when nothing of the current session is in flight — the states a pane rests in between
    /// turns. (Done is a finished turn still inside its decay window; it is over all the same.)
    const fn turn_is_over(&self) -> bool {
        matches!(
            self.status,
            ClaudeStatus::Idle | ClaudeStatus::Done | ClaudeStatus::None
        )
    }

    // MARK: OSC title (the agent's own busy/rest telltale)

    /// Claude Code writes its state into the terminal title: a Braille-spinner glyph prefix while a
    /// turn runs, a `✳ ` prefix at rest. That is the agent's own emission — not a heuristic screen
    /// scrape — so it corroborates liveness where hooks have gaps, conservatively:
    /// - the SPINNER promotes to working only while the agent is already detected (a title never
    ///   conjures presence) and never clears an authoritative HOOK block;
    /// - the REST prefix demotes ONLY a live working → idle (the missed-`Stop` stuck-working
    ///   state); done keeps its decay window and a block keeps waiting;
    /// - any other agent-naming title stays the presence floor it always was.
    fn apply_title(&mut self, title: &str, now: f64) {
        if Self::title_shows_spinner(title) {
            // ⚠️ Never out of done while a hook feed is live. The title arrives on the PTY read loop
            // and the `Stop` on its own queue, so a turn's trailing spinner repaint routinely lands
            // AFTER the `Stop` that ended it — promoting there erased the finished state and its
            // label, and the `✳` a moment later took working → idle, minting a SECOND completion
            // for the one turn. Under coverage the promotion buys nothing anyway:
            // `UserPromptSubmit` / `PreToolUse` announce a real turn starting.
            let stale = self.authoritative_covered && self.status == ClaudeStatus::Done;
            if self.status != ClaudeStatus::None && self.block_source != BlockSource::Hook && !stale {
                self.enter(ClaudeStatus::Working, None, None);
            }
            return;
        }
        if Self::title_shows_rest(title) {
            if self.status == ClaudeStatus::Working {
                self.enter(ClaudeStatus::Idle, None, None);
            }
            return;
        }
        if Self::title_names_claude(title) {
            self.lift_presence_floor(now);
        }
    }

    /// True when the title carries the WORKING telltale — a leading Braille-pattern spinner glyph
    /// (U+2800–U+28FF).
    #[must_use]
    pub fn title_shows_spinner(title: &str) -> bool {
        title
            .chars()
            .next()
            .is_some_and(|first| (0x2800..=0x28FF).contains(&u32::from(first)))
    }

    /// True when the title carries the AT-REST telltale — the leading `✳` (U+2733).
    #[must_use]
    pub fn title_shows_rest(title: &str) -> bool {
        title
            .chars()
            .next()
            .is_some_and(|first| u32::from(first) == 0x2733)
    }

    /// True when an OSC 2 title names the agent (`Claude: my-project`, `✳ Claude Code`).
    #[must_use]
    pub fn title_names_claude(title: &str) -> bool {
        title.to_lowercase().contains("claude")
    }

    /// True when `title` is one the agent wrote ABOUT ITSELF: its busy or at-rest telltale, or a
    /// title naming the program.
    ///
    /// Exactly the three shapes this machine already believes as agent evidence — published so the
    /// host can decide the title belongs to the agent (and is the agent's to hand back when it
    /// exits) without re-deriving the vocabulary.
    #[must_use]
    pub fn title_is_agent_written(title: &str) -> bool {
        Self::title_shows_spinner(title) || Self::title_shows_rest(title) || Self::title_names_claude(title)
    }

    // MARK: Manifest verdict (the conservative fallback)

    fn apply_manifest(&mut self, verdict: ClaudeStatus, now: f64) {
        // A coarse fallback verdict is the weakest evidence there is — it must never walk a pane
        // back out of an announced session end.
        if self.floor_locked(now) {
            return;
        }
        match verdict {
            // Unsure → never downgrade; presence is the floor.
            ClaudeStatus::None => {},
            // Only the manifest's strongest, conservative signal (a known approval UI). Tagged as a
            // MANIFEST block, NOT a hook one, so a later manifest verdict can clear it: the old
            // shared flag made a manifest-set block permanent.
            ClaudeStatus::NeedsPermission => {
                let carried = self.label.clone();
                self.enter_blocked(carried, BlockSource::Manifest, None, now);
            },
            // A coarse "working" guess must NOT clear an authoritative HOOK block, but MAY clear a
            // manifest-sourced one — the manifest is the only authority then.
            ClaudeStatus::Working => {
                if self.block_source != BlockSource::Hook {
                    self.enter(ClaudeStatus::Working, None, None);
                }
            },
            ClaudeStatus::Idle => {
                if self.block_source != BlockSource::Hook && self.status == ClaudeStatus::None {
                    self.enter(ClaudeStatus::Idle, None, None);
                }
            },
            // Anchor the decay clock exactly like the hook `Stop` path — a manifest-sourced done
            // with no anchor would never decay, latching the pane done until something else
            // overrode it.
            ClaudeStatus::Done => {
                if self.block_source != BlockSource::Hook {
                    let carried = self.label.clone();
                    self.enter(ClaudeStatus::Done, carried, Some(now));
                }
            },
        }
    }

    // MARK: Screen-rule verdict (the manifest engine)

    /// The screen engine is continuous ground truth over the live grid. Reconciliation with the
    /// hook edges (docs/DECISIONS round 4):
    /// - blocked raises a MANIFEST block (an existing hook block keeps its provenance);
    /// - working, or a VISIBLE idle, may clear even a HOOK block once it is at least the override
    ///   grace old — the dialog demonstrably left the screen, the Esc-cancel liberation;
    /// - a PLAIN idle (the no-rule fallback) is the weakest evidence: it clears manifest state but
    ///   never a hook block, and never cuts the done decay (the screen has no done concept);
    /// - unknown and `skip_state_update` change nothing — the transcript viewer and model picker
    ///   freeze.
    ///
    /// The working→idle hold has already run UPSTREAM: the scan layer publishes post-hold.
    fn apply_screen(&mut self, detection: AgentScreenDetection, now: f64) {
        if detection.skip_state_update {
            return;
        }
        // The scan runs every 300 ms off a grid the agent has not finished vacating — inside the
        // post-exit lockout its verdicts describe an agent that already said goodbye.
        if self.floor_locked(now) {
            return;
        }
        if detection.state == AgentScreenState::Unknown {
            self.clear_screen_dissent();
            return;
        }

        if !self.authoritative_covered {
            // No authoritative feed for this pane — the screen IS the authority (herdr's world).
            self.apply_screen_verdict(&detection, false, now);
            return;
        }
        // Tier 2 under coverage: corroborate, and otherwise keep a stopwatch on the disagreement.
        if self.screen_agrees(&detection) {
            self.clear_screen_dissent();
            return;
        }
        // A different claim is a different argument: it re-anchors the clock.
        if self.screen_dissent.as_ref().map(|dissent| dissent.state) != Some(detection.state) {
            self.screen_dissent_since = Some(now);
        }
        // Same claim, freshest evidence — `visible_idle` can firm up.
        self.screen_dissent = Some(detection);
        self.resolve_screen_dissent_if_due(now);
    }

    /// The watchdog proper, run on the CLOCK rather than on the next fold.
    ///
    /// ⚠️ It cannot be driven by incoming detections.
    /// [`AgentDetectionHold::should_publish`](crate::hold::AgentDetectionHold::should_publish) only
    /// publishes a CHANGED verdict, and its one heartbeat requires a visible blocker on both sides
    /// — so a steady idle or working dissent is folded EXACTLY ONCE and a fold-driven window can
    /// never elapse. Anchoring on the first dissenting fold and re-checking from
    /// [`reduce`](Self::reduce) — every tick, every signal — is what makes the escape hatch
    /// reachable at all; before this it was unreachable in the live pipeline while passing its unit
    /// test, which drove the screen signal directly.
    fn resolve_screen_dissent_if_due(&mut self, now: f64) {
        if !self.authoritative_covered {
            return;
        }
        let (Some(detection), Some(since)) = (self.screen_dissent.clone(), self.screen_dissent_since) else {
            return;
        };
        let window = if detection.state == AgentScreenState::Blocked {
            Self::SCREEN_DISSENT_TO_RAISE
        } else {
            Self::SCREEN_DISSENT_TO_RELEASE
        };
        // A positive comparison, so a NaN elapsed simply never matures.
        if now - since >= window {
            // ⚠️ Try the verdict FIRST. A matured dissent whose verdict cannot apply — a PLAIN idle
            // against a hook block, say — used to revoke coverage and ownership anyway and then
            // change nothing, leaving the pane stale AND unclaimed, so the next `claude -p` could
            // take it. Authority is handed over only when the screen actually says something that
            // lands.
            if !self.apply_screen_verdict(&detection, true, now) {
                return;
            }
            // Uninterrupted contradiction past the window, and the screen had a usable verdict: the
            // hook feed has stopped describing this pane (relay dead, host restarted mid-session, a
            // record lost). Hand authority back — the move itself is already marked a CORRECTION.
            self.authoritative_covered = false;
            // …and free the pane. If the feed died because the AGENT did (a crash posts no
            // `SessionEnd`), the replacement's session id differs and would otherwise be ignored
            // forever — this is the only path that recovers that pane.
            self.owner_session_id = None;
            self.clear_screen_dissent();
        }
    }

    /// The screen engine's verdict applied as authority — no hook coverage, or the watchdog just
    /// took it back. `correcting` marks the move as bookkeeping rather than something that
    /// happened.
    ///
    /// Returns TRUE when the verdict actually LANDED: the watchdog reads this to decide whether
    /// handing authority over is justified, because a verdict that cannot apply must not cost the
    /// pane its coverage and its session-ownership gate for nothing.
    fn apply_screen_verdict(&mut self, detection: &AgentScreenDetection, correcting: bool, now: f64) -> bool {
        match detection.state {
            AgentScreenState::Unknown => false,
            AgentScreenState::Blocked => {
                // Agreement — keep the richer provenance.
                if self.status == ClaudeStatus::NeedsPermission {
                    return false;
                }
                self.enter_blocked(None, BlockSource::Manifest, None, now);
                true
            },
            AgentScreenState::Working => {
                if self.block_source == BlockSource::Hook && !self.hook_block_overridable(now) {
                    return false;
                }
                if self.status == ClaudeStatus::Working {
                    return false;
                }
                self.enter(ClaudeStatus::Working, None, None);
                true
            },
            AgentScreenState::Idle => {
                // The done decay outlives a merely-idle screen.
                if self.status == ClaudeStatus::Done {
                    return false;
                }
                if self.block_source == BlockSource::Hook {
                    if !detection.visible_idle || !self.hook_block_overridable(now) {
                        return false;
                    }
                    self.enter(ClaudeStatus::Idle, None, None);
                    // A hook said blocked and the screen disagreed for long enough to win. That is
                    // the detector correcting ITSELF — never a turn the human should be told
                    // finished.
                    self.is_quiet = true;
                    return true;
                }
                if self.status == ClaudeStatus::Idle {
                    return false;
                }
                let was_blocked = correcting && self.status == ClaudeStatus::NeedsPermission;
                self.enter(ClaudeStatus::Idle, None, None);
                if was_blocked {
                    self.is_quiet = true;
                }
                true
            },
        }
    }

    /// Whether the screen's verdict is consistent with the authoritative status.
    ///
    /// Coarse on purpose — the two vocabularies do not line up exactly (the screen has no done, and
    /// the terminal status means the tier-1 signals have not placed an agent yet), and only a
    /// CONTRADICTION should start a clock.
    fn screen_agrees(&self, detection: &AgentScreenDetection) -> bool {
        match detection.state {
            AgentScreenState::Unknown => true,
            AgentScreenState::Blocked => self.status == ClaudeStatus::NeedsPermission,
            AgentScreenState::Working => self.status == ClaudeStatus::Working,
            // Done is a finished turn resting at its prompt — the screen sees exactly that and is
            // agreeing, not arguing. The terminal status is nobody's claim to contradict.
            AgentScreenState::Idle => {
                matches!(
                    self.status,
                    ClaudeStatus::Idle | ClaudeStatus::Done | ClaudeStatus::None
                )
            },
        }
    }

    fn clear_screen_dissent(&mut self) {
        self.screen_dissent_since = None;
        self.screen_dissent = None;
    }

    /// True once the current block is old enough for the screen to have painted its dialog — a
    /// contradicting screen verdict is then believed.
    fn hook_block_overridable(&self, now: f64) -> bool {
        let Some(since) = self.blocked_since else {
            return true;
        };
        now - since >= Self::HOOK_BLOCK_SCREEN_OVERRIDE_GRACE
    }

    // MARK: State entry helpers

    /// The presence floor — lift the terminal status to idle, never downgrading a richer one.
    /// Vetoed while the post-exit lockout stands: presence is exactly the signal that lags an
    /// announced session end.
    fn lift_presence_floor(&mut self, now: f64) {
        if self.floor_locked(now) {
            return;
        }
        if self.status == ClaudeStatus::None {
            self.enter(ClaudeStatus::Idle, None, None);
        }
    }

    /// TRUE while a hook-announced session end still vetoes weak liveness evidence. An ordered
    /// minimum, never a bare `<` ternary, so a NaN `now` does not silently unlock the floor.
    fn floor_locked(&self, now: f64) -> bool {
        let Some(until) = self.exit_lockout_until else {
            return false;
        };
        f64::min(now, until) < until
    }

    /// Drops the veto — an AUTHORITATIVE signal (a real hook naming a live session) is proof the
    /// pane has an agent again, and outranks the exit it may still be racing.
    const fn clear_exit_lockout(&mut self) {
        self.exit_lockout_until = None;
    }

    fn enter_blocked(
        &mut self,
        label: Option<String>,
        source: BlockSource,
        entry: Option<BlockEntry>,
        now: f64,
    ) {
        self.clear_exit_lockout();
        self.clear_screen_dissent();
        self.is_quiet = false;
        // A re-assertion of a standing block keeps the ORIGINAL entry time — the override grace
        // measures how long the dialog has been up, not how recently a hook repeated itself.
        if self.status != ClaudeStatus::NeedsPermission {
            self.blocked_since = Some(now);
        }
        // A screen or manifest block carries no call identity, so it never touches the ledger: the
        // provenance flag alone governs it. Only hook blocks are itemised.
        if let Some(entry) = entry
            && !self.block_ledger.contains(&entry)
        {
            self.block_ledger.push(entry);
        }
        self.block_source = source;
        self.done_since = None;
        self.status = ClaudeStatus::NeedsPermission;
        if let Some(label) = label {
            self.label = Some(Self::clamp_label(&label));
        }
    }

    // MARK: The block ledger

    /// Resolves the ledger for one tool call — STARTING (its permission was granted, so it runs) or
    /// FINISHED, which are the same fact for a block: that call is no longer waiting on a human.
    /// Takes its own entry, plus the id-less ones — those name no call, so this is the only handle
    /// they will ever have.
    ///
    /// ⚠️ A STARTING call used to drop every permission entry regardless of id, on the reasoning
    /// that a permission dialog is modal so anything starting proves none is up. That reasoning is
    /// false for a BATCH: `[Read(a), Bash(gated)]` raises the dialog on `Bash` and then `Read`'s
    /// own `PreToolUse` fires while the human is still looking at it — the same failure the
    /// ledger was built to fix, left open in this one direction. The denial it stood in for is
    /// announced properly now, so a permission entry resolves by identity like every other
    /// kind, and a hand nothing answers still comes down on Esc, on `Stop`, and on the
    /// sustained-dissent watchdog.
    fn resolve_ledger(&mut self, id: Option<&str>) {
        self.block_ledger
            .retain(|entry| entry.tool_use_id.is_some() && entry.tool_use_id.as_deref() != id);
    }

    /// Enters a non-blocked status. A non-`None` `now` marks the done-decay anchor.
    fn enter(&mut self, next: ClaudeStatus, new_label: Option<String>, now: Option<f64>) {
        self.clear_exit_lockout();
        self.clear_screen_dissent();
        // Cleared HERE — the one funnel for every non-blocked transition — and re-set by the single
        // caller that means it, so a quiet mark can never survive into a status it did not qualify.
        self.is_quiet = false;
        self.block_source = BlockSource::None;
        self.blocked_since = None;
        // Leaving the blocked state at all retires every outstanding call: a turn boundary (a
        // `Stop`, a new prompt, a `SessionStart`) means nothing from the old turn is still being
        // asked.
        self.block_ledger.clear();
        self.status = next;
        self.label = new_label.map(|label| Self::clamp_label(&label));
        self.done_since = if next == ClaudeStatus::Done { now } else { None };
    }

    /// Drops to the terminal status.
    ///
    /// `arm_lockout` distinguishes the two ways a session dies: a hook `SessionEnd` ANNOUNCES the
    /// end while the process still runs (arm the veto), whereas process absence IS the end already
    /// observed (nothing to defend).
    fn terminate(&mut self, arm_lockout: bool, now: f64) {
        self.status = ClaudeStatus::None;
        self.label = None;
        self.done_since = None;
        self.block_source = BlockSource::None;
        self.blocked_since = None;
        // A session boundary retires the marker with everything else — a compaction cannot straddle
        // two sessions, and a stale one would swallow the next session's first genuine finish.
        self.compaction_pending = false;
        self.is_quiet = false;
        self.block_ledger.clear();
        // Coverage belongs to a SESSION. The next session earns its own on its first hook — and
        // until then this pane is back to screen-and-presence detection, which is the correct
        // reading of "we have not heard from an agent here".
        self.authoritative_covered = false;
        self.owner_session_id = None;
        self.clear_screen_dissent();
        if arm_lockout {
            self.exit_lockout_until = Some(now + Self::POST_EXIT_FLOOR_LOCKOUT);
        }
    }

    // MARK: Time-based decay (the injected clock)

    fn decay_if_due(&mut self, now: f64) {
        if self.status != ClaudeStatus::Done {
            return;
        }
        let Some(since) = self.done_since else { return };
        if now - since >= self.done_to_idle_timeout {
            self.enter(ClaudeStatus::Idle, None, None);
        }
    }

    // MARK: Helpers

    /// Bounds the chip text; validate-then-clamp on a hostile or huge body. Empty stays empty.
    ///
    /// The cap counts SCALARS rather than grapheme clusters — the chip is a length bound on a
    /// string that arrived over a socket, not a typographic measurement.
    fn clamp_label(text: &str) -> String {
        let trimmed = text.trim();
        if trimmed.chars().count() <= Self::MAX_LABEL {
            return trimmed.to_owned();
        }
        trimmed.chars().take(Self::MAX_LABEL).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::ClaudeStatusMachine;
    use crate::screen::{AgentScreenDetection, AgentScreenState};
    use crate::signal::{ClaudeHookEvent, ClaudeSignal, NotificationKind};
    use crate::status::{AgentStatusKind, ClaudeStatus};

    fn machine() -> ClaudeStatusMachine {
        ClaudeStatusMachine::default()
    }

    fn hook(event: ClaudeHookEvent) -> ClaudeSignal {
        ClaudeSignal::Hook(event)
    }

    fn session_start(id: &str) -> ClaudeSignal {
        hook(ClaudeHookEvent::SessionStart {
            session_id: Some(id.to_owned()),
        })
    }

    fn prompt(id: &str) -> ClaudeSignal {
        hook(ClaudeHookEvent::UserPromptSubmit {
            session_id: Some(id.to_owned()),
        })
    }

    fn pre_tool(id: &str, call: Option<&str>) -> ClaudeSignal {
        hook(ClaudeHookEvent::PreToolUse {
            session_id: Some(id.to_owned()),
            tool: Some("Bash".to_owned()),
            tool_use_id: call.map(str::to_owned),
        })
    }

    fn post_tool(id: &str, call: Option<&str>) -> ClaudeSignal {
        hook(ClaudeHookEvent::PostToolUse {
            session_id: Some(id.to_owned()),
            tool: Some("Bash".to_owned()),
            tool_use_id: call.map(str::to_owned),
        })
    }

    fn blocked(kind: NotificationKind, call: Option<&str>) -> ClaudeSignal {
        hook(ClaudeHookEvent::Notification {
            kind,
            label: Some("may I".to_owned()),
            tool_use_id: call.map(str::to_owned),
            session_id: None,
        })
    }

    fn stop(id: &str, label: Option<&str>) -> ClaudeSignal {
        hook(ClaudeHookEvent::Stop {
            session_id: Some(id.to_owned()),
            label: label.map(str::to_owned),
        })
    }

    fn screen(state: AgentScreenState) -> ClaudeSignal {
        ClaudeSignal::Screen(AgentScreenDetection::plain(state))
    }

    fn visible_screen(state: AgentScreenState) -> ClaudeSignal {
        ClaudeSignal::Screen(AgentScreenDetection::visible(state))
    }

    // MARK: The hook ladder

    #[test]
    fn a_fresh_machine_has_placed_no_agent_at_all() {
        let subject = machine();
        assert_eq!(subject.status(), ClaudeStatus::None);
        assert_eq!(subject.label(), None);
        assert!(!subject.has_authoritative_feed());
        assert_eq!(subject.outstanding_block_count(), 0);
        assert_eq!(subject.standing_block_kind(), 0);
    }

    #[test]
    fn the_hook_ladder_walks_a_whole_turn() {
        let mut subject = machine();
        assert_eq!(subject.reduce(session_start("s"), 0.0), ClaudeStatus::Idle);
        assert_eq!(subject.reduce(prompt("s"), 1.0), ClaudeStatus::Working);
        assert_eq!(
            subject.reduce(pre_tool("s", Some("c1")), 2.0),
            ClaudeStatus::Working
        );
        assert_eq!(
            subject.reduce(post_tool("s", Some("c1")), 3.0),
            ClaudeStatus::Working
        );
        assert_eq!(
            subject.reduce(stop("s", Some("all done")), 4.0),
            ClaudeStatus::Done
        );
        assert_eq!(subject.display_label(), Some("all done"));
        assert!(subject.has_authoritative_feed());
    }

    #[test]
    fn a_done_turn_decays_to_idle_on_the_injected_clock_and_not_before() {
        let mut subject = machine();
        subject.reduce(stop("s", Some("done")), 100.0);
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 107.9), ClaudeStatus::Done);
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 108.0), ClaudeStatus::Idle);
        assert_eq!(subject.label(), None);
    }

    #[test]
    fn a_negative_or_nan_timeout_is_clamped_rather_than_believed() {
        // Bit-compared, because the point is that NaN never reaches the field at all.
        assert_eq!(
            ClaudeStatusMachine::new(-5.0).done_to_idle_timeout().to_bits(),
            0.0_f64.to_bits()
        );
        assert_eq!(
            ClaudeStatusMachine::new(f64::NAN)
                .done_to_idle_timeout()
                .to_bits(),
            0.0_f64.to_bits()
        );
    }

    #[test]
    fn a_subagent_stopping_changes_nothing_about_the_parent() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        let after = subject.reduce(hook(ClaudeHookEvent::SubagentStop { agent_id: None }), 1.0);
        assert_eq!(after, ClaudeStatus::Working);
    }

    // MARK: The block ledger

    #[test]
    fn a_sibling_tool_finishing_does_not_answer_the_question_on_screen() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("ask")), 1.0);
        assert_eq!(subject.status(), ClaudeStatus::NeedsPermission);
        // The BATCH sibling finishes. The human has still not answered.
        assert_eq!(
            subject.reduce(post_tool("s", Some("bash")), 2.0),
            ClaudeStatus::NeedsPermission
        );
        assert_eq!(subject.outstanding_block_count(), 1);
        // …and its own result does.
        assert_eq!(
            subject.reduce(post_tool("s", Some("ask")), 3.0),
            ClaudeStatus::Working
        );
        assert_eq!(subject.outstanding_block_count(), 0);
    }

    #[test]
    fn a_block_that_names_no_call_comes_down_on_any_tool_at_all() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::Permission, None), 0.0);
        assert_eq!(subject.status(), ClaudeStatus::NeedsPermission);
        assert_eq!(
            subject.reduce(pre_tool("s", Some("other")), 1.0),
            ClaudeStatus::Working
        );
    }

    #[test]
    fn the_standing_block_is_the_most_recent_one_because_blocks_stack_modally() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("ask")), 0.0);
        assert_eq!(
            subject.standing_block_kind(),
            AgentStatusKind::WaitingForInput.wire_byte()
        );
        subject.reduce(blocked(NotificationKind::Permission, Some("perm")), 1.0);
        assert_eq!(
            subject.standing_block_kind(),
            AgentStatusKind::Permission.wire_byte()
        );
        assert_eq!(subject.outstanding_block_count(), 2);
        // The approval on top resolves; the question underneath is what the human now faces.
        subject.reduce(pre_tool("s", Some("perm")), 2.0);
        assert_eq!(subject.status(), ClaudeStatus::NeedsPermission);
        assert_eq!(
            subject.standing_block_kind(),
            AgentStatusKind::WaitingForInput.wire_byte()
        );
    }

    #[test]
    fn a_repeated_notification_is_one_entry_not_two() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::Permission, Some("c")), 0.0);
        subject.reduce(blocked(NotificationKind::Permission, Some("c")), 1.0);
        assert_eq!(subject.outstanding_block_count(), 1);
    }

    #[test]
    fn a_turn_boundary_retires_every_outstanding_call() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("a")), 0.0);
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("b")), 0.1);
        assert_eq!(subject.outstanding_block_count(), 2);
        subject.reduce(stop("s", None), 1.0);
        assert_eq!(subject.outstanding_block_count(), 0);
        assert_eq!(subject.standing_block_kind(), 0);
    }

    // MARK: The cancel key

    #[test]
    fn a_cancel_key_dismisses_a_dialog_quietly_and_touches_nothing_else() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("ask")), 0.0);
        assert_eq!(subject.reduce(ClaudeSignal::UserInput, 1.0), ClaudeStatus::Idle);
        assert!(subject.is_quiet(), "a dismissal the human performed is not news");

        let mut working = machine();
        working.reduce(prompt("s"), 0.0);
        assert_eq!(
            working.reduce(ClaudeSignal::UserInput, 1.0),
            ClaudeStatus::Working
        );
        assert!(!working.is_quiet());

        let mut absent = machine();
        assert_eq!(absent.reduce(ClaudeSignal::UserInput, 1.0), ClaudeStatus::None);
    }

    // MARK: Compaction

    #[test]
    fn a_compaction_ends_on_a_quiet_idle_rather_than_announcing_a_finish() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        subject.reduce(
            hook(ClaudeHookEvent::PreCompact {
                session_id: Some("s".to_owned()),
            }),
            1.0,
        );
        assert_eq!(
            subject.reduce(stop("s", Some("compacted")), 2.0),
            ClaudeStatus::Idle
        );
        assert!(subject.is_quiet());
        assert_eq!(
            subject.label(),
            None,
            "the last message belongs to the turn before"
        );
    }

    #[test]
    fn an_auto_compaction_mid_turn_still_ends_on_a_genuine_done() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        subject.reduce(
            hook(ClaudeHookEvent::PreCompact {
                session_id: Some("s".to_owned()),
            }),
            1.0,
        );
        // The turn RESUMES: a tool runs, which spends the marker.
        subject.reduce(pre_tool("s", Some("c")), 2.0);
        assert_eq!(
            subject.reduce(stop("s", Some("real work")), 3.0),
            ClaudeStatus::Done
        );
        assert!(!subject.is_quiet());
        assert_eq!(subject.display_label(), Some("real work"));
    }

    #[test]
    fn a_session_boundary_retires_a_marker_that_never_got_spent() {
        let mut subject = machine();
        subject.reduce(
            hook(ClaudeHookEvent::PreCompact {
                session_id: Some("s".to_owned()),
            }),
            0.0,
        );
        subject.reduce(
            hook(ClaudeHookEvent::SessionEnd {
                session_id: Some("s".to_owned()),
            }),
            1.0,
        );
        subject.reduce(session_start("t"), 10.0);
        subject.reduce(prompt("t"), 11.0);
        assert_eq!(subject.reduce(stop("t", Some("done")), 12.0), ClaudeStatus::Done);
        assert!(!subject.is_quiet());
    }

    #[test]
    fn an_interrupted_turn_ends_quietly_because_the_human_ended_it() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        let after = subject.reduce(
            hook(ClaudeHookEvent::Interrupted {
                session_id: Some("s".to_owned()),
            }),
            1.0,
        );
        assert_eq!(after, ClaudeStatus::Idle);
        assert!(subject.is_quiet());
    }

    // MARK: Presence, teardown and the post-exit lockout

    #[test]
    fn presence_is_a_floor_and_never_a_downgrade() {
        let mut subject = machine();
        assert_eq!(
            subject.reduce(ClaudeSignal::ProcessPresent(true), 0.0),
            ClaudeStatus::Idle
        );
        subject.reduce(prompt("s"), 1.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::ProcessPresent(true), 2.0),
            ClaudeStatus::Working
        );
    }

    #[test]
    fn absence_is_ground_truth_and_clears_everything() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::Permission, Some("c")), 0.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::ProcessPresent(false), 1.0),
            ClaudeStatus::None
        );
        assert_eq!(subject.label(), None);
        assert_eq!(subject.outstanding_block_count(), 0);
        assert!(!subject.has_authoritative_feed());
        // …and it arms NO lockout, so the next presence poll lights the pane straight back up.
        assert_eq!(
            subject.reduce(ClaudeSignal::ProcessPresent(true), 1.1),
            ClaudeStatus::Idle
        );
    }

    #[test]
    fn an_announced_session_end_vetoes_every_weak_signal_across_the_teardown_gap() {
        let mut subject = machine();
        subject.reduce(session_start("s"), 0.0);
        subject.reduce(
            hook(ClaudeHookEvent::SessionEnd {
                session_id: Some("s".to_owned()),
            }),
            10.0,
        );
        assert_eq!(subject.status(), ClaudeStatus::None);
        // The ~1 Hz poll, the 300 ms scan and the still-painted title all still describe an agent.
        assert_eq!(
            subject.reduce(ClaudeSignal::ProcessPresent(true), 10.5),
            ClaudeStatus::None
        );
        assert_eq!(
            subject.reduce(screen(AgentScreenState::Working), 11.0),
            ClaudeStatus::None
        );
        assert_eq!(
            subject.reduce(ClaudeSignal::OscTitle("Claude: repo".to_owned()), 11.5),
            ClaudeStatus::None
        );
        assert_eq!(
            subject.reduce(ClaudeSignal::ManifestVerdict(ClaudeStatus::Working), 12.0),
            ClaudeStatus::None
        );
        // Past the window, presence works again.
        assert_eq!(
            subject.reduce(ClaudeSignal::ProcessPresent(true), 13.0),
            ClaudeStatus::Idle
        );
    }

    #[test]
    fn a_genuinely_new_session_clears_the_lockout_at_once() {
        let mut subject = machine();
        subject.reduce(session_start("s"), 0.0);
        subject.reduce(
            hook(ClaudeHookEvent::SessionEnd {
                session_id: Some("s".to_owned()),
            }),
            10.0,
        );
        assert_eq!(subject.reduce(session_start("t"), 10.2), ClaudeStatus::Idle);
        assert_eq!(
            subject.reduce(ClaudeSignal::ProcessPresent(true), 10.3),
            ClaudeStatus::Idle
        );
    }

    // MARK: Session ownership

    #[test]
    fn a_nested_run_cannot_blank_the_pane_its_parent_is_blocked_in() {
        let mut subject = machine();
        subject.reduce(session_start("owner"), 0.0);
        subject.reduce(prompt("owner"), 1.0);
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("ask")), 2.0);
        // A `claude -p` inherits the pane id and posts its whole hook set here.
        assert_eq!(
            subject.reduce(session_start("nested"), 3.0),
            ClaudeStatus::NeedsPermission
        );
        assert_eq!(
            subject.reduce(stop("nested", Some("nested done")), 4.0),
            ClaudeStatus::NeedsPermission
        );
        let after = subject.reduce(
            hook(ClaudeHookEvent::SessionEnd {
                session_id: Some("nested".to_owned()),
            }),
            5.0,
        );
        assert_eq!(after, ClaudeStatus::NeedsPermission);
        assert_eq!(subject.display_label(), Some("may I"));
    }

    #[test]
    fn an_event_naming_no_session_always_applies_and_never_claims() {
        let mut subject = machine();
        // A ctl `report blocked` carries no session and takes effect on an unclaimed pane.
        assert_eq!(
            subject.reduce(blocked(NotificationKind::Permission, None), 0.0),
            ClaudeStatus::NeedsPermission
        );
        // …and having claimed nothing, the first id-carrying hook still takes the pane.
        subject.reduce(session_start("s"), 1.0);
        assert!(subject.accepts(&ClaudeHookEvent::Stop {
            session_id: Some("s".to_owned()),
            label: None,
        }));
        assert!(!subject.accepts(&ClaudeHookEvent::Stop {
            session_id: Some("other".to_owned()),
            label: None,
        }));
    }

    #[test]
    fn a_crash_restart_hands_the_pane_over_because_the_turn_was_already_at_rest() {
        let mut subject = machine();
        subject.reduce(session_start("dead"), 0.0);
        subject.reduce(stop("dead", Some("last")), 1.0);
        subject.reduce(ClaudeSignal::Tick, 20.0); // decayed to idle: the turn is over
        assert_eq!(subject.status(), ClaudeStatus::Idle);
        // The human re-runs the agent inside the absence-suppression window.
        assert_eq!(subject.reduce(session_start("fresh"), 21.0), ClaudeStatus::Idle);
        assert_eq!(subject.reduce(prompt("fresh"), 22.0), ClaudeStatus::Working);
    }

    #[test]
    fn accepts_answers_exactly_what_the_fold_will_do() {
        let mut subject = machine();
        subject.reduce(prompt("owner"), 0.0);
        let handover = ClaudeHookEvent::SessionStart {
            session_id: Some("other".to_owned()),
        };
        // Mid-turn: no handover, and `accepts` says so.
        assert!(!subject.accepts(&handover));
        assert_eq!(subject.reduce(hook(handover.clone()), 1.0), ClaudeStatus::Working);
        // At rest: the handover is allowed, and `accepts` says so.
        subject.reduce(stop("owner", None), 2.0);
        subject.reduce(ClaudeSignal::Tick, 30.0);
        assert!(subject.accepts(&handover));
    }

    // MARK: The OSC title

    #[test]
    fn the_titles_own_telltales_are_recognised_and_nothing_else_is() {
        assert!(ClaudeStatusMachine::title_shows_spinner("⠹ Working"));
        assert!(!ClaudeStatusMachine::title_shows_spinner("Working ⠹"));
        assert!(ClaudeStatusMachine::title_shows_rest("✳ Claude Code"));
        assert!(!ClaudeStatusMachine::title_shows_rest("Claude ✳"));
        assert!(ClaudeStatusMachine::title_names_claude("CLAUDE: repo"));
        assert!(!ClaudeStatusMachine::title_names_claude("zsh"));
        assert!(ClaudeStatusMachine::title_is_agent_written("⠹"));
        assert!(!ClaudeStatusMachine::title_is_agent_written("~/src — vim"));
        assert!(!ClaudeStatusMachine::title_shows_spinner(""));
    }

    #[test]
    fn a_spinner_title_never_conjures_presence_out_of_nothing() {
        let mut subject = machine();
        assert_eq!(
            subject.reduce(ClaudeSignal::OscTitle("⠹ x".to_owned()), 0.0),
            ClaudeStatus::None
        );
        subject.reduce(ClaudeSignal::ProcessPresent(true), 1.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::OscTitle("⠹ x".to_owned()), 2.0),
            ClaudeStatus::Working
        );
    }

    #[test]
    fn a_trailing_spinner_repaint_never_erases_the_finish_it_arrived_after() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        subject.reduce(stop("s", Some("finished")), 1.0);
        // The title lands on the PTY loop after the Stop landed on its own queue.
        assert_eq!(
            subject.reduce(ClaudeSignal::OscTitle("⠹ x".to_owned()), 1.1),
            ClaudeStatus::Done
        );
        assert_eq!(subject.display_label(), Some("finished"));
    }

    #[test]
    fn the_at_rest_prefix_demotes_only_a_live_working() {
        let mut subject = machine();
        subject.reduce(ClaudeSignal::ProcessPresent(true), 0.0);
        subject.reduce(ClaudeSignal::OscTitle("⠹".to_owned()), 1.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::OscTitle("✳ Claude".to_owned()), 2.0),
            ClaudeStatus::Idle
        );

        // A done keeps its decay window, and a block keeps waiting.
        let mut done = machine();
        done.reduce(stop("s", Some("x")), 0.0);
        assert_eq!(
            done.reduce(ClaudeSignal::OscTitle("✳".to_owned()), 1.0),
            ClaudeStatus::Done
        );
        let mut held = machine();
        held.reduce(blocked(NotificationKind::Permission, Some("c")), 0.0);
        assert_eq!(
            held.reduce(ClaudeSignal::OscTitle("✳".to_owned()), 1.0),
            ClaudeStatus::NeedsPermission
        );
    }

    #[test]
    fn a_spinner_never_walks_a_pane_out_of_an_authoritative_block() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::Permission, Some("c")), 0.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::OscTitle("⠹ x".to_owned()), 1.0),
            ClaudeStatus::NeedsPermission
        );
    }

    // MARK: The manifest verdict

    #[test]
    fn a_coarse_verdict_never_downgrades_and_never_clears_a_hook_block() {
        let mut subject = machine();
        subject.reduce(ClaudeSignal::ProcessPresent(true), 0.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::ManifestVerdict(ClaudeStatus::None), 1.0),
            ClaudeStatus::Idle
        );
        subject.reduce(blocked(NotificationKind::Permission, Some("c")), 2.0);
        for verdict in [ClaudeStatus::Working, ClaudeStatus::Idle, ClaudeStatus::Done] {
            assert_eq!(
                subject.reduce(ClaudeSignal::ManifestVerdict(verdict), 3.0),
                ClaudeStatus::NeedsPermission,
                "{verdict:?}"
            );
        }
    }

    #[test]
    fn a_manifest_block_can_be_cleared_by_a_later_manifest_verdict() {
        let mut subject = machine();
        subject.reduce(ClaudeSignal::ProcessPresent(true), 0.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::ManifestVerdict(ClaudeStatus::NeedsPermission), 1.0),
            ClaudeStatus::NeedsPermission
        );
        assert_eq!(
            subject.reduce(ClaudeSignal::ManifestVerdict(ClaudeStatus::Working), 2.0),
            ClaudeStatus::Working
        );
    }

    #[test]
    fn a_manifest_done_decays_like_every_other_done() {
        let mut subject = machine();
        subject.reduce(ClaudeSignal::ManifestVerdict(ClaudeStatus::Done), 0.0);
        assert_eq!(subject.status(), ClaudeStatus::Done);
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 8.0), ClaudeStatus::Idle);
    }

    // MARK: The screen engine, uncovered and covered

    #[test]
    fn without_a_hook_feed_the_screen_is_the_authority() {
        let mut subject = machine();
        assert_eq!(
            subject.reduce(screen(AgentScreenState::Working), 0.0),
            ClaudeStatus::Working
        );
        assert_eq!(
            subject.reduce(screen(AgentScreenState::Blocked), 1.0),
            ClaudeStatus::NeedsPermission
        );
        assert_eq!(
            subject.reduce(screen(AgentScreenState::Idle), 2.0),
            ClaudeStatus::Idle
        );
    }

    #[test]
    fn a_frozen_or_unknown_verdict_changes_nothing() {
        let mut subject = machine();
        subject.reduce(screen(AgentScreenState::Working), 0.0);
        let frozen = AgentScreenDetection {
            state: AgentScreenState::Idle,
            skip_state_update: true,
            ..AgentScreenDetection::default()
        };
        assert_eq!(
            subject.reduce(ClaudeSignal::Screen(frozen), 1.0),
            ClaudeStatus::Working
        );
        assert_eq!(
            subject.reduce(screen(AgentScreenState::Unknown), 2.0),
            ClaudeStatus::Working
        );
    }

    #[test]
    fn under_coverage_the_screen_only_corroborates() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        // The screen says idle, repeatedly, and the pane stays working until the window matures.
        for now in [1.0_f64, 2.0, 3.0, 5.0, 9.0] {
            assert_eq!(
                subject.reduce(screen(AgentScreenState::Idle), now),
                ClaudeStatus::Working
            );
        }
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 11.1), ClaudeStatus::Idle);
    }

    #[test]
    fn the_watchdog_matures_on_the_clock_and_not_on_a_second_detection() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        // ONE dissenting fold, then nothing but ticks — the publish gate upstream would send no
        // more, so a fold-driven window would never elapse.
        subject.reduce(screen(AgentScreenState::Idle), 1.0);
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 10.9), ClaudeStatus::Working);
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 11.0), ClaudeStatus::Idle);
        assert!(!subject.has_authoritative_feed(), "authority is handed back");
    }

    #[test]
    fn the_screen_raises_an_unannounced_block_on_the_short_window() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        subject.reduce(screen(AgentScreenState::Blocked), 1.0);
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 3.9), ClaudeStatus::Working);
        assert_eq!(
            subject.reduce(ClaudeSignal::Tick, 4.0),
            ClaudeStatus::NeedsPermission
        );
    }

    #[test]
    fn a_changed_claim_re_anchors_the_stopwatch() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        subject.reduce(screen(AgentScreenState::Idle), 1.0);
        // Nine seconds in, the screen changes its mind to blocked: a different argument.
        assert_eq!(
            subject.reduce(screen(AgentScreenState::Blocked), 10.0),
            ClaudeStatus::Working
        );
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 12.9), ClaudeStatus::Working);
        assert_eq!(
            subject.reduce(ClaudeSignal::Tick, 13.0),
            ClaudeStatus::NeedsPermission
        );
    }

    #[test]
    fn agreement_drops_the_stopwatch_entirely() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        subject.reduce(screen(AgentScreenState::Idle), 1.0);
        subject.reduce(screen(AgentScreenState::Working), 2.0); // agrees → clock cleared
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 30.0), ClaudeStatus::Working);
        assert!(subject.has_authoritative_feed());
    }

    #[test]
    fn a_hook_that_leaves_the_contradiction_standing_does_not_reset_the_clock() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("ask")), 0.0);
        subject.reduce(visible_screen(AgentScreenState::Idle), 1.0);
        // The turn keeps emitting hooks for the batch's SIBLING calls. None of them answers the
        // question the human is looking at, so none of them changes the status — and none of them
        // may hold the watchdog at zero, or the one case that needs the escape hatch (a stale ask
        // entry nothing will ever resolve) would be the one case that disabled it.
        subject.reduce(post_tool("s", Some("sibling-a")), 3.0);
        subject.reduce(post_tool("s", Some("sibling-b")), 6.0);
        subject.reduce(post_tool("s", Some("sibling-c")), 9.0);
        assert_eq!(subject.status(), ClaudeStatus::NeedsPermission);
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 11.0), ClaudeStatus::Idle);
        assert!(subject.is_quiet());
    }

    #[test]
    fn a_matured_verdict_that_cannot_apply_costs_the_pane_nothing() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("ask")), 0.0);
        // A PLAIN idle can never lower a hook block, however long it stands.
        subject.reduce(screen(AgentScreenState::Idle), 1.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::Tick, 30.0),
            ClaudeStatus::NeedsPermission
        );
        assert!(
            subject.has_authoritative_feed(),
            "coverage is not spent on a verdict that cannot land"
        );
    }

    #[test]
    fn a_visible_idle_lowers_a_matured_hook_block_quietly() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::WaitingForInput, Some("ask")), 0.0);
        subject.reduce(visible_screen(AgentScreenState::Idle), 1.0);
        assert_eq!(
            subject.reduce(ClaudeSignal::Tick, 10.9),
            ClaudeStatus::NeedsPermission
        );
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 11.0), ClaudeStatus::Idle);
        assert!(
            subject.is_quiet(),
            "the detector correcting itself is not a finished turn"
        );
        assert!(!subject.has_authoritative_feed());
    }

    #[test]
    fn a_manifest_block_yields_to_the_screen_at_once_because_only_a_hook_block_has_a_grace() {
        let mut subject = machine();
        subject.reduce(ClaudeSignal::ManifestVerdict(ClaudeStatus::NeedsPermission), 1.0);
        // No hook block, so no override grace and no dissent window: the screen simply outranks a
        // guess the screen itself is a better version of.
        assert_eq!(
            subject.reduce(visible_screen(AgentScreenState::Idle), 1.1),
            ClaudeStatus::Idle
        );
    }

    #[test]
    fn a_repeated_hook_does_not_restart_the_dialogs_own_clock() {
        let mut subject = machine();
        subject.reduce(blocked(NotificationKind::Permission, Some("c")), 0.0);
        // The hook repeats itself at 0.9 s; the dialog has still been up since 0, so the override
        // grace measures from the FIRST assertion.
        subject.reduce(blocked(NotificationKind::Permission, Some("c")), 0.9);
        subject.reduce(visible_screen(AgentScreenState::Idle), 1.05);
        assert_eq!(subject.reduce(ClaudeSignal::Tick, 11.05), ClaudeStatus::Idle);
    }

    #[test]
    fn an_idle_screen_never_cuts_the_done_decay_short() {
        let mut subject = machine();
        subject.reduce(stop("s", Some("finished")), 0.0);
        assert_eq!(
            subject.reduce(screen(AgentScreenState::Idle), 1.0),
            ClaudeStatus::Done
        );
        assert_eq!(subject.display_label(), Some("finished"));
    }

    #[test]
    fn a_screen_that_agrees_with_a_done_turn_is_not_arguing() {
        let mut subject = machine();
        subject.reduce(prompt("s"), 0.0);
        subject.reduce(stop("s", None), 1.0);
        // Done and idle are the same picture; the stopwatch must never start.
        for now in [2.0_f64, 3.0, 4.0, 5.0, 6.0, 7.0] {
            subject.reduce(screen(AgentScreenState::Idle), now);
        }
        assert!(subject.has_authoritative_feed());
    }

    #[test]
    fn an_uncovered_unblock_is_a_real_edge_and_is_not_quiet() {
        let mut subject = machine();
        subject.reduce(screen(AgentScreenState::Blocked), 0.0);
        assert_eq!(
            subject.reduce(screen(AgentScreenState::Idle), 2.0),
            ClaudeStatus::Idle
        );
        assert!(!subject.is_quiet());
    }

    // MARK: The label

    #[test]
    fn a_hostile_label_is_clamped_rather_than_carried() {
        let mut subject = machine();
        let huge = "x".repeat(500);
        subject.reduce(stop("s", Some(&huge)), 0.0);
        assert_eq!(
            subject.label().map(str::len),
            Some(ClaudeStatusMachine::MAX_LABEL)
        );

        let mut blank = machine();
        blank.reduce(stop("s", Some("   \n  ")), 0.0);
        assert_eq!(blank.label(), Some(""));
        assert_eq!(blank.display_label(), None, "an empty clamp shows nothing");
    }

    #[test]
    fn a_working_transition_clears_the_label_because_a_tool_name_is_not_chip_text() {
        let mut subject = machine();
        subject.reduce(stop("s", Some("finished")), 0.0);
        subject.reduce(prompt("s"), 1.0);
        assert_eq!(subject.label(), None);
    }

    // MARK: Idempotence and determinism

    #[test]
    fn a_duplicate_signal_folds_to_the_same_place() {
        let mut once = machine();
        let mut twice = machine();
        once.reduce(prompt("s"), 0.0);
        twice.reduce(prompt("s"), 0.0);
        twice.reduce(prompt("s"), 0.0);
        assert_eq!(once, twice);
    }

    #[test]
    fn the_same_signals_in_the_same_order_give_the_same_machine() {
        let script = || {
            let mut subject = machine();
            subject.reduce(ClaudeSignal::ProcessPresent(true), 0.0);
            subject.reduce(session_start("s"), 0.5);
            subject.reduce(prompt("s"), 1.0);
            subject.reduce(blocked(NotificationKind::WaitingForInput, Some("ask")), 2.0);
            subject.reduce(screen(AgentScreenState::Blocked), 2.5);
            subject.reduce(post_tool("s", Some("ask")), 3.0);
            subject.reduce(stop("s", Some("all done")), 4.0);
            subject.reduce(ClaudeSignal::Tick, 20.0);
            subject
        };
        assert_eq!(script(), script());
        assert_eq!(script().status(), ClaudeStatus::Idle);
    }
}
