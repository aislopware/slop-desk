//! The per-pane FUSION: ONE [`ClaudeStatusMachine`] fed by every detection input the host has.
//!
//! [`machine`](crate::machine) answers "given this signal, what is the status now". This module
//! answers the question one layer up — **what does the host owe the client after that fold** — and
//! it is a different question with its own state: two dedupe anchors, a stickiness clock, a block
//! class the machine does not carry across folds, a session intent latched off prompts and titles,
//! and the ownership record that lets an exiting agent hand its pane title back.
//!
//! ## Why one detector and not one per input
//! Splitting detection across two independent machines — a foreground-watch reducer at ~1 Hz and a
//! hook-socket handler — has BOTH emit type-27 with no reconciliation, so they fight (a hook
//! `Working` and a poll `Idle` clobber each other down the one control stream), and with nobody
//! driving [`tick`](PaneDetector::tick) the `Done → Idle` decay never fires: a finished turn stays
//! blue forever. Fusing every input into one machine gives ONE type-27 dedupe anchor and ONE
//! type-26 edge anchor.
//!
//! ## The inputs, all folded through the one machine
//! - [`sample`](PaneDetector::sample) — the ~1 Hz foreground poll (presence floor + the type-26
//!   basename edge).
//! - [`hook`](PaneDetector::hook) — one parsed hook record. The JSON never reaches this crate; see
//!   the manifest for why.
//! - [`report`](PaneDetector::report) — the ctl `report` verb, an agent declaring its own state.
//! - [`tick`](PaneDetector::tick) — the clock that drives the decay.
//! - [`screen`](PaneDetector::screen) — the screen engine's published verdict.
//! - [`title`](PaneDetector::title) — a sniffed OSC 0/2 title.
//! - [`user_input`](PaneDetector::user_input) — the Esc-cancel unblock edge.
//! - [`reestablish_on_reattach`](PaneDetector::reestablish_on_reattach) — current truth, as fresh
//!   messages, for a returning client.
//!
//! PURE and TOTAL: every input (empty, huge, hostile) is tolerated — validate-then-drop, never a
//! trap. The clock is injected, exactly as the machine's is.

use crate::input::contains_cancel_keystroke;
use crate::kind::AgentKind;
use crate::machine::ClaudeStatusMachine;
use crate::process::{canonical_name, is_claude_running, is_likely_wrapper};
use crate::screen::AgentScreenDetection;
use crate::signal::{ClaudeHookEvent, ClaudeSignal, NotificationKind};
use crate::status::{AgentStatusKind, ClaudeStatus};

/// The WIRE shape of one type-27 emission — the three fields the machine resolves, captured so a
/// dedupe anchor compares what actually goes out rather than the richer [`ClaudeStatus`].
///
/// Two panes at the same status can still owe different frames (a different label, a different
/// notification kind), and two at different statuses can owe the same one. Only the triple answers
/// "would this frame be a repeat", which is the question every emitter is asking.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StatusTriple {
    /// The status urgency byte.
    pub state: u8,
    /// The notification kind, or `0` for a transition that carries none.
    pub kind: u8,
    /// The display label, or empty.
    pub label: String,
}

/// One decision: the (possibly empty) control messages one fold owes the client.
///
/// Ordered as the caller sends them — the presence floor first, then the richer status, then the
/// intent, mirroring the machine's precedence, and the title retirement last, being a display
/// consequence of the status having dropped.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Emission {
    /// The type-26 foreground basename, or `None` — no basename edge.
    pub foreground: Option<String>,
    /// The type-27 status triple, or `None` — the triple did not change.
    pub status: Option<StatusTriple>,
    /// The type-36 session intent, or `None` — the intent did not change. Empty means cleared.
    pub intent: Option<String>,
    /// TRUE when this fold retires the pane title (a type-21 whose body is the empty string).
    ///
    /// Only ever empty: the sniffer drops empty OSC 0/2 bodies, so an empty type-21 on the wire is
    /// unambiguously this deliberate clear and nothing else.
    pub title_retired: bool,
}

impl Emission {
    /// Bit `0` foreground · `1` status · `2` intent · `3` title retirement.
    ///
    /// The FFI reads this instead of four presence doors: a fold answers which slots it filled, and
    /// only the filled ones are then pulled across.
    pub const FOREGROUND: u32 = 1;
    /// See [`FOREGROUND`](Self::FOREGROUND).
    pub const STATUS: u32 = 1 << 1;
    /// See [`FOREGROUND`](Self::FOREGROUND).
    pub const INTENT: u32 = 1 << 2;
    /// See [`FOREGROUND`](Self::FOREGROUND).
    pub const TITLE: u32 = 1 << 3;

    /// TRUE when this fold owes nothing at all.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.slots() == 0
    }

    /// Which slots are filled, as the bitmask the FFI answers with.
    #[must_use]
    pub const fn slots(&self) -> u32 {
        let mut bits = 0;
        if self.foreground.is_some() {
            bits |= Self::FOREGROUND;
        }
        if self.status.is_some() {
            bits |= Self::STATUS;
        }
        if self.intent.is_some() {
            bits |= Self::INTENT;
        }
        if self.title_retired {
            bits |= Self::TITLE;
        }
        bits
    }
}

/// The single per-pane detector: the one machine, and the bookkeeping that turns its verdicts into
/// the host's control stream. See the module docs.
#[derive(Debug)]
pub struct PaneDetector {
    /// The ONE per-pane state machine — every signal folds through this single instance.
    machine: ClaudeStatusMachine,

    /// The last foreground basename a type-26 was emitted for (`None` before the first sample).
    last_emitted_name: Option<String>,

    /// The last triple a type-27 was emitted for (`None` before the first emit) — the dedupe
    /// anchor.
    last_emitted_status: Option<StatusTriple>,

    /// Injected time of the LAST authoritative fold — a ctl self-report or a parsed hook — or
    /// `None`. See [`REPORT_GRACE_WINDOW`](PaneDetector::REPORT_GRACE_WINDOW).
    last_authoritative_at: Option<f64>,

    /// TRUE while the machine's current (non-`None`) status was established authoritatively.
    hook_authority: bool,

    /// The wire `kind` byte for the LAST hook notification class, carried so a type-27 emitted by a
    /// later tick/presence fold still reports the live block class.
    last_notification_kind: u8,

    /// The hook session the current [`session_intent`](Self::session_intent) belongs to.
    intent_session_id: Option<String>,

    /// The pane's AGENT-SESSION INTENT (wire type 36).
    session_intent: Option<String>,

    /// The last type-36 intent emitted (`None` before the first) — the dedupe anchor.
    last_emitted_intent: Option<String>,

    /// TRUE while the pane's OSC title is one the DETECTED agent wrote.
    agent_owns_title: bool,
}

impl Default for PaneDetector {
    fn default() -> Self {
        Self::new(ClaudeStatusMachine::DEFAULT_DONE_TO_IDLE_TIMEOUT)
    }
}

impl PaneDetector {
    /// Seconds an authoritative fold (report/hook) stays STICKY against a foreground-presence
    /// absence.
    ///
    /// An order of magnitude above the ~1 Hz foreground poll, so several polls cannot wipe it: an
    /// agent that keeps working re-reports (or its hooks fire) well within this, and one that has
    /// genuinely finished decays normally once the window lapses.
    pub const REPORT_GRACE_WINDOW: f64 = 30.0;

    /// Seconds a hook-established status stays preserved by a WRAPPER-basename foreground past the
    /// last authoritative fold.
    ///
    /// An order of magnitude above [`REPORT_GRACE_WINDOW`](Self::REPORT_GRACE_WINDOW): a
    /// wrapper-launched claude sitting quietly between turns refreshes the anchor with its next
    /// hook well inside this, while one that died WITHOUT a session end cannot pin its stale
    /// verdict onto an unrelated later `node`/`npx`/`bun` reusing the same pane forever.
    pub const WRAPPER_SUPPRESSION_WINDOW: f64 = 600.0;

    /// Scalar cap on the derived intent line — a sidebar title, not a transcript.
    pub const MAX_INTENT_CHARS: usize = 120;

    /// A fresh detector whose done status decays after `done_to_idle_timeout` seconds.
    #[must_use]
    pub const fn new(done_to_idle_timeout: f64) -> Self {
        Self {
            machine: ClaudeStatusMachine::new(done_to_idle_timeout),
            last_emitted_name: None,
            last_emitted_status: None,
            last_authoritative_at: None,
            hook_authority: false,
            last_notification_kind: 0,
            intent_session_id: None,
            session_intent: None,
            last_emitted_intent: None,
            agent_owns_title: false,
        }
    }

    // MARK: Readable state

    /// The current rolled-up status.
    #[must_use]
    pub const fn status(&self) -> ClaudeStatus {
        self.machine.status()
    }

    /// TRUE while the CURRENT status change is bookkeeping rather than news.
    #[must_use]
    pub const fn is_quiet(&self) -> bool {
        self.machine.is_quiet()
    }

    /// TRUE while this pane's agent announces its own edges through the hook feed.
    #[must_use]
    pub const fn has_authoritative_feed(&self) -> bool {
        self.machine.has_authoritative_feed()
    }

    /// TRUE while the pane's status is hook/report-established, which makes the agent's own
    /// terminal notification (OSC 9 / 777 / 99) redundant: the type-27 edge already raised the
    /// client's banner, so forwarding the blind copy would double-bang every prompt.
    #[must_use]
    pub const fn suppresses_child_notifications(&self) -> bool {
        self.hook_authority
    }

    /// The machine's short human label, `None` when empty.
    #[must_use]
    pub fn status_label(&self) -> Option<&str> {
        self.machine.display_label()
    }

    /// The triple the type-27 stream currently stands at — the CURRENT VALUE behind the edge,
    /// `None` before the first emission.
    #[must_use]
    pub const fn last_emitted_status(&self) -> Option<&StatusTriple> {
        self.last_emitted_status.as_ref()
    }

    /// The agent's current session intent (type 36's value), `None` when none is established.
    #[must_use]
    pub fn session_intent(&self) -> Option<&str> {
        self.session_intent.as_deref()
    }

    /// The canonical name of whatever held the terminal at the last [`Detector::sample`], `None`
    /// before the first one.
    ///
    /// The LATCH rather than a fresh reading, and the difference is what makes it worth exposing:
    /// resolving the name costs a `tcgetpgrp` and a `proc_pidpath`, and a caller that wants it for
    /// every pane at once — the workspace document's capture does, on every reconciler tick — would
    /// otherwise pay a syscall pair per pane for an answer this poll already took.
    ///
    /// An empty sample stays empty here: "nothing is in the foreground" is a fact about the pane,
    /// the state between one child exiting and the next starting, and collapsing it into `None`
    /// would make it indistinguishable from "never sampled".
    #[must_use]
    pub fn foreground_name(&self) -> Option<&str> {
        self.last_emitted_name.as_deref()
    }

    // MARK: Inputs — all fold through the ONE machine

    /// Fold one foreground-process sample at `now`.
    ///
    /// Emits type-26 on a basename EDGE (a display hint, never a status source) and drives the
    /// presence FLOOR; a non-agent or empty name forces termination. Presence only ever lifts
    /// `None` — it never overrides a richer hook status.
    ///
    /// **Stickiness.** A recent authoritative fold must not be wiped by a presence ABSENCE: the
    /// common supervised agent (a custom orchestrator, a node-wrapped CLI, any non-`claude`
    /// basename) sets its state authoritatively and the poll's `present == false` would otherwise
    /// terminate it on the next tick. Two suppressors:
    /// 1. within [`REPORT_GRACE_WINDOW`](Self::REPORT_GRACE_WINDOW) of the last authoritative fold,
    ///    ANY absence is dropped;
    /// 2. while a hook-established status is live, an absence whose basename is a known WRAPPER is
    ///    dropped for the longer [`WRAPPER_SUPPRESSION_WINDOW`](Self::WRAPPER_SUPPRESSION_WINDOW) —
    ///    a wrapper-launched claude quiet between turns has no hook traffic to re-stamp the short
    ///    window, and must not flap to `None` while the wrapper still holds the PTY foreground.
    ///
    /// Both are TIME-BOUND off the same anchor, because hooks are best-effort. A wrapper never
    /// LIFTS the floor; absence cannot lift `None`.
    pub fn sample(&mut self, raw_name: &str, now: f64) -> Emission {
        let base = canonical_name(raw_name);
        let mut emission = Emission::default();
        if self.last_emitted_name.as_deref() != Some(base) {
            self.last_emitted_name = Some(base.to_owned());
            emission.foreground = Some(base.to_owned());
        }
        // Presence = ANY known agent, not just claude: the alias table means a codex/gemini/opencode
        // pane lights the same machinery its screen verdicts drive. The exact-basename discipline
        // holds — `AgentKind::identify` matches whole canonical names, never substrings.
        let present = is_claude_running(base) || AgentKind::identify(base).is_some();
        if self.absence_suppressed(present, base, now) {
            // Skip the terminating absence fold; keep the authoritative status intact. (There is no
            // presence floor to lift — absence cannot lift `None`.)
        } else {
            self.machine.reduce(ClaudeSignal::ProcessPresent(present), now);
            // Absence terminates → not blocked anymore → forget the stale notification kind AND the
            // authoritative provenance, so a later wrapper foreground preserves nothing. The session
            // intent dies with the session too: a claude killed without a session end must not pin
            // its task line onto whatever runs in the pane next.
            if !present {
                self.last_notification_kind = 0;
                self.hook_authority = false;
                self.last_authoritative_at = None;
                self.intent_session_id = None;
                self.session_intent = None;
            }
        }
        emission.status = self.status_if_changed();
        emission.intent = self.intent_if_changed();
        emission.title_retired = self.retire_title_if_agent_gone();
        emission
    }

    /// The two absence suppressors, in the order they are tried. See [`sample`](Self::sample).
    ///
    /// Ordered comparisons throughout (`f64::min` then a plain test), never a bare `<` select: an
    /// injected NaN `now` must fall through to "not suppressed" rather than pick an arm by
    /// accident.
    fn absence_suppressed(&self, present: bool, base: &str, now: f64) -> bool {
        if present {
            return false;
        }
        let Some(authoritative_at) = self.last_authoritative_at else {
            return false;
        };
        let elapsed = now - authoritative_at;
        if f64::min(elapsed, Self::REPORT_GRACE_WINDOW) < Self::REPORT_GRACE_WINDOW && elapsed >= 0.0 {
            return true;
        }
        self.hook_authority
            && is_likely_wrapper(base)
            && f64::min(elapsed, Self::WRAPPER_SUPPRESSION_WINDOW) < Self::WRAPPER_SUPPRESSION_WINDOW
            && elapsed >= 0.0
    }

    /// Fold one PARSED hook record at `now`.
    ///
    /// `kind_byte` is the type-27 qualifier the reader resolved for this event, and `prompt` is the
    /// raw text a `UserPromptSubmit` carried (`None` for everything else). The status fold never
    /// reads the prompt — a turn beginning is a turn beginning — but the session intent does.
    ///
    /// Never emits type-26: the foreground process did not change.
    pub fn hook(
        &mut self,
        event: ClaudeHookEvent,
        kind_byte: u8,
        prompt: Option<&str>,
        now: f64,
    ) -> Emission {
        let mut emission = Emission::default();
        // ⚠️ WHOSE hook is this? The relay routes by `SLOPDESK_PANE_ID`, which every descendant of
        // the pane's shell inherits — so a `claude -p …` run from a script, or from the pane agent's
        // own Bash tool, posts its whole hook set HERE. The reader already ATTRIBUTED the record
        // from the envelope's session id; drop it whole if it names a different live session: not
        // the status, not the liveness anchor, and not the session TITLE, which a nested prompt
        // would otherwise rewrite.
        if !self.machine.accepts(&event) {
            return emission;
        }
        match event {
            ClaudeHookEvent::UserPromptSubmit { ref session_id } => {
                let session_id = session_id.clone();
                self.fold_intent(session_id, prompt.unwrap_or_default());
            },
            ClaudeHookEvent::SessionEnd { .. } => {
                self.intent_session_id = None;
                self.session_intent = None;
            },
            _ => {},
        }
        // A REAL hook is the same precedence-2 authoritative signal as a ctl report, so it stamps
        // the SAME stickiness anchor — otherwise the ~1 Hz poll terminates a hook-set status within
        // a second whenever claude runs under a wrapper whose basename never classifies as `claude`.
        // Stamped on every parsed record, so pre/post-tool traffic keeps a long turn's window fresh.
        //
        // EXCEPT a session end. The anchor's whole job is protecting a LIVE state from a poll that
        // cannot see the agent; a session that just ended has no live state to protect, and the
        // absence the poll is about to report is the session end's own corroboration. Stamping here
        // inverted the mechanism — the one signal announcing the end became what kept the dead state
        // alive, for the full window. Clear the anchor instead, so the next absence terminates on
        // contact.
        if matches!(event, ClaudeHookEvent::SessionEnd { .. }) {
            self.last_authoritative_at = None;
        } else {
            self.last_authoritative_at = Some(now);
        }
        self.machine.reduce(ClaudeSignal::Hook(event), now);
        // A session end terminates → the authority is gone with it.
        self.hook_authority = self.machine.status() != ClaudeStatus::None;
        self.last_notification_kind = block_kind(
            self.last_notification_kind,
            self.machine.standing_block_kind(),
            kind_byte,
            self.machine.status() == ClaudeStatus::NeedsPermission,
        );
        emission.status = self.status_if_changed();
        emission.intent = self.intent_if_changed();
        emission.title_retired = self.retire_title_if_agent_gone();
        emission
    }

    /// Fold an AGENT SELF-REPORT at `now` — the ctl `report` verb.
    ///
    /// An agent inside a pane declares its own state; this is authoritative (precedence 2, the same
    /// rung as a real hook), beating the foreground heuristic floor. The ctl state token maps to a
    /// synthetic hook event and folds through the SAME machine, so the existing precedence and
    /// dedupe apply unchanged:
    /// - `working` → a turn is in progress,
    /// - `blocked` → needs a human,
    /// - `done` → the turn finished,
    /// - `idle` → present and at rest, which clears any stale block.
    ///
    /// Validate-then-drop: an unknown token changes nothing, including the stickiness anchor.
    pub fn report(&mut self, state: &str, message: Option<&str>, now: f64) -> Emission {
        let mut emission = Emission::default();
        let label = message.map(str::to_owned);
        let event = match state {
            "working" => ClaudeHookEvent::UserPromptSubmit { session_id: None },
            "blocked" => {
                ClaudeHookEvent::Notification {
                    kind: NotificationKind::Permission,
                    label,
                    tool_use_id: None,
                    session_id: None,
                }
            },
            "done" => {
                ClaudeHookEvent::Stop {
                    session_id: None,
                    label,
                }
            },
            "idle" => ClaudeHookEvent::SessionStart { session_id: None },
            _ => return emission,
        };
        // Only a VALID (folded) state stamps the floor — an unknown one already returned above.
        self.last_authoritative_at = Some(now);
        self.machine.reduce(ClaudeSignal::Hook(event), now);
        self.hook_authority = self.machine.status() != ClaudeStatus::None;
        self.last_notification_kind = u8::from(self.machine.status() == ClaudeStatus::NeedsPermission);
        emission.status = self.status_if_changed();
        emission.title_retired = self.retire_title_if_agent_gone();
        emission
    }

    /// A bare clock tick at `now` — what drives the `Done → Idle` decay.
    pub fn tick(&mut self, now: f64) -> Emission {
        self.machine.reduce(ClaudeSignal::Tick, now);
        self.after_weak_fold()
    }

    /// Fold one SCREEN-RULE verdict at `now` — the manifest engine's published detection, with the
    /// startup grace, idle-scan skip and working→idle hold already applied by the scan task.
    ///
    /// The machine reconciles it against the hook edges: a visible idle or live spinner may clear
    /// even a hook block once it is past the paint grace, because the screen is ground truth, while
    /// a plain fallback idle never clears one. NOT authoritative — it stamps no stickiness anchor.
    pub fn screen(&mut self, detection: AgentScreenDetection, now: f64) -> Emission {
        self.machine.reduce(ClaudeSignal::Screen(detection), now);
        let mut emission = self.clear_kind_off_block();
        // Like a title: never OPEN the type-27 stream while still `None`. An unknown-state verdict
        // on an undetected pane must not announce a churn frame.
        if self.machine.status() == ClaudeStatus::None && self.last_emitted_status.is_none() {
            return emission;
        }
        emission.status = self.status_if_changed();
        emission.title_retired = self.retire_title_if_agent_gone();
        emission
    }

    /// Fold one sniffed OSC 0/2 title at `now`.
    ///
    /// Claude Code writes its own busy/rest telltale into the title (a Braille spinner means
    /// working, `✳ ` means at rest), so the title corroborates where hooks have gaps — most
    /// importantly, a missed stop's stuck `Working` demotes to `Idle` on the rest title. The
    /// machine applies the conservative precedence: a title never clears a hook block, never
    /// conjures presence, never touches `Done`. NOT authoritative — it stamps no stickiness
    /// anchor.
    ///
    /// The title's TEXT is also claude's OWN session title: behind the telltale glyph rides a
    /// model-generated topic summary (and a `/rename`d session's custom name) — the canonical "what
    /// is this session about". A real topic SUPERSEDES the prompt-derived intent; the static
    /// startup `Claude Code` names the program, not the work. Folded only while an agent is
    /// DETECTED, so a plain shell's title cannot conjure an agent intent.
    pub fn title(&mut self, title: &str, now: f64) -> Emission {
        self.machine.reduce(ClaudeSignal::OscTitle(title.to_owned()), now);
        let mut emission = self.clear_kind_off_block();
        if self.machine.status() != ClaudeStatus::None {
            if let Some(topic) = topic_line(title) {
                self.session_intent = Some(topic);
            }
            // Ownership: a title the DETECTED agent wrote is the agent's to give back when it goes.
            // A shell's own title (`nvim — README.md`, a long `make`) is not — it stays put.
            if ClaudeStatusMachine::title_is_agent_written(title) {
                self.agent_owns_title = true;
            }
        }
        // EVERY shell titles its tab — a title folded on an undetected pane must not OPEN the
        // type-27 stream with a churn frame announcing the client's own default.
        if self.machine.status() == ClaudeStatus::None && self.last_emitted_status.is_none() {
            return emission;
        }
        emission.status = self.status_if_changed();
        emission.intent = self.intent_if_changed();
        emission.title_retired = self.retire_title_if_agent_gone();
        emission
    }

    /// Fold one client→PTY input chunk at `now` — the Esc-cancel unblock edge.
    ///
    /// Scoped hard: the bytes are read ONLY while the machine sits at `NeedsPermission`, and only a
    /// genuine CANCEL key demotes the block. Esc-cancel fires no stop hook and the ✳ rest title
    /// already shows while the dialog is up, so this is the only host-visible unblock signal there
    /// is.
    ///
    /// ⚠️ It used to fire on ANY keystroke, on the reasoning that typing at a modal is HANDLING it.
    /// That was both unnecessary and harmful. Unnecessary because every other way of resolving a
    /// dialog announces itself with a hook that re-promotes the pane on its own. Harmful because
    /// NAVIGATING a dialog is keystrokes too: arrowing between an `AskUserQuestion`'s options
    /// demoted the block, the still-visible dialog re-raised it a scan later, and the fresh entry
    /// rang the awaiting-input cue — once per keypress.
    pub fn user_input(&mut self, bytes: &[u8], now: f64) -> Emission {
        let mut emission = Emission::default();
        if self.machine.status() != ClaudeStatus::NeedsPermission || !contains_cancel_keystroke(bytes) {
            return emission;
        }
        self.machine.reduce(ClaudeSignal::UserInput, now);
        if self.machine.status() != ClaudeStatus::NeedsPermission {
            self.last_notification_kind = 0;
        }
        emission.status = self.status_if_changed();
        emission
    }

    /// The detector's CURRENT truth as fresh messages, for a returning client.
    ///
    /// Both streams are edge-triggered against the anchors, so after a rebind wiped the control-out
    /// queue nothing would ever re-tell the new client about a foreground command or working agent
    /// that SPANS the reattach — and a status change folded WHILE DETACHED (its emission wiped with
    /// control-out, its anchor already advanced) is otherwise lost forever. The status is
    /// recomputed from the MACHINE, not replayed from the anchor, and the anchor is re-pointed
    /// at it so the next unchanged fold still dedupes. Quiet before any fold: a detection-off
    /// session keeps its no-stream contract.
    pub fn reestablish_on_reattach(&mut self) -> Emission {
        let mut emission = Emission {
            foreground: self.last_emitted_name.clone(),
            ..Emission::default()
        };
        if self.last_emitted_status.is_some() {
            let triple = self.current_triple();
            self.last_emitted_status = Some(triple.clone());
            emission.status = Some(triple);
        }
        // The intent stream re-asserts the same way: current truth, anchor re-pointed, and quiet for
        // a pane whose intent stream never spoke (no spurious empty clear frame).
        if self.last_emitted_intent.is_some() {
            let current = self.session_intent.clone().unwrap_or_default();
            self.last_emitted_intent = Some(current.clone());
            emission.intent = Some(current);
        }
        emission
    }

    // MARK: The shared tail of a weak fold

    /// What a tick owes: the block class is dropped the moment the machine leaves the blocked
    /// state, then the two edge-triggered streams are asked.
    fn after_weak_fold(&mut self) -> Emission {
        let mut emission = self.clear_kind_off_block();
        emission.status = self.status_if_changed();
        emission.title_retired = self.retire_title_if_agent_gone();
        emission
    }

    /// Drops the standing block class once the machine is no longer blocked, and answers an empty
    /// emission for the caller to fill.
    fn clear_kind_off_block(&mut self) -> Emission {
        if self.machine.status() != ClaudeStatus::NeedsPermission {
            self.last_notification_kind = 0;
        }
        Emission::default()
    }

    // MARK: Session intent (the type-36 latch)

    /// Folds one `UserPromptSubmit` into the intent.
    ///
    /// A prompt from a NEW session re-derives from scratch; within a session every TITLEABLE prompt
    /// re-titles, because the row answers "what is the agent doing NOW" rather than "what was it
    /// hired for" — a multi-turn session's title follows the work. A non-titleable prompt (a
    /// slash-command, harness XML, blank) leaves the standing intent untouched: a `/compact` must
    /// not wipe the task line.
    fn fold_intent(&mut self, session_id: Option<String>, prompt: &str) {
        if session_id != self.intent_session_id {
            self.intent_session_id = session_id;
            self.session_intent = None;
        }
        if let Some(line) = intent_line(prompt) {
            self.session_intent = Some(line);
        }
    }

    // MARK: Title retirement (the type-21 agent-gone edge)

    /// TRUE on the edge where the agent that owned the pane's title has gone.
    ///
    /// A ONE-SHOT edge: the ownership flag is consumed here, so a pane already handed back keeps
    /// whatever the shell (or a later agent) titles it next.
    fn retire_title_if_agent_gone(&mut self) -> bool {
        if !self.agent_owns_title || self.machine.status() != ClaudeStatus::None {
            return false;
        }
        self.agent_owns_title = false;
        true
    }

    /// The type-36 value iff the latched intent changed since the last emit (a `None` anchor
    /// collapses to the empty string, so a never-intent pane stays silent); empty means cleared.
    fn intent_if_changed(&mut self) -> Option<String> {
        let current = self.session_intent.clone().unwrap_or_default();
        // BOTH sides collapse to the empty string, the anchor included. That asymmetry with the
        // status anchor (where a never-emitted stream and an emitted-none are genuinely different
        // frames) is the whole reason a pane that never had an intent stays SILENT rather than
        // opening its stream with an empty clear frame nobody asked for.
        if current == self.last_emitted_intent.clone().unwrap_or_default() {
            return None;
        }
        self.last_emitted_intent = Some(current.clone());
        Some(current)
    }

    // MARK: Status dedupe (ONE anchor for the ONE type-27 stream)

    /// The wire `kind` byte for the CURRENT status — the qualifier the state byte has no room for.
    ///
    /// Two disjoint producers, checked in urgency order: a live block reports its standing class,
    /// and a QUIET transition reports [`AgentStatusKind::Quiet`] so the client delivers the status
    /// without announcing it. They cannot collide — the machine clears the quiet mark on every
    /// transition into a block.
    const fn kind_byte(&self) -> u8 {
        if self.machine.is_quiet() {
            return AgentStatusKind::Quiet.wire_byte();
        }
        self.last_notification_kind
    }

    /// The triple the machine stands at right now.
    fn current_triple(&self) -> StatusTriple {
        StatusTriple {
            state: self.machine.status().urgency(),
            kind: self.kind_byte(),
            label: self.machine.display_label().unwrap_or_default().to_owned(),
        }
    }

    /// The type-27 triple iff it changed since the last emit; `None` when unchanged (dedupe).
    fn status_if_changed(&mut self) -> Option<StatusTriple> {
        let triple = self.current_triple();
        if Some(&triple) == self.last_emitted_status.as_ref() {
            return None;
        }
        self.last_emitted_status = Some(triple.clone());
        Some(triple)
    }
}

/// The `kind` byte a fold should leave standing.
///
/// `0` when the pane is not blocked, the EVENT's class when the event is itself a blocking
/// notification (`1` permission / `2` waiting-for-input), and otherwise the class already standing
/// — mid-block traffic describes the turn, not the block. Total over the byte.
///
/// ⚠️ `ledger` outranks `standing` because blocks STACK. With `[AskUserQuestion, Bash(gated)]` the
/// approval dialog is raised second and, once approved, its `PreToolUse` arrives with event byte 0
/// — leaving the standing byte naming a block that is already gone, so every client drew
/// "Permission needed" over an unanswered question for as long as it stood. The machine knows which
/// entries survive; this is that answer.
#[must_use]
pub const fn block_kind(standing: u8, ledger: u8, event: u8, blocked: bool) -> u8 {
    if !blocked {
        return 0;
    }
    if ledger != 0 {
        return ledger;
    }
    if event == 1 || event == 2 {
        return event;
    }
    standing
}

/// Derives the one-line intent from a submitted prompt.
///
/// The first non-blank line, inner whitespace collapsed, clamped to
/// [`MAX_INTENT_CHARS`](PaneDetector::MAX_INTENT_CHARS). `None` when the prompt has no titling
/// value — blank, a slash-command (`/compact`), or a harness-injected XML block — so a later REAL
/// prompt can still name the session. Pure and total: any string is tolerated.
#[must_use]
pub fn intent_line(prompt: &str) -> Option<String> {
    for raw_line in swift_lines(prompt) {
        let line = raw_line.trim_matches(is_horizontal_space);
        if line.is_empty() {
            continue;
        }
        if line.starts_with('/') || line.starts_with('<') {
            return None;
        }
        return Some(clamp(&collapse_whitespace(line)));
    }
    None
}

/// Claude's own session title out of a sniffed OSC title, or `None` when it carries no topic.
///
/// Strips the leading busy/rest telltale (Braille spinner frames, `✳`, the variation selectors that
/// follow it) and whitespace; rejects an empty remainder and the static startup `Claude Code`,
/// which names the program rather than the work. Whitespace-collapsed and clamped like
/// [`intent_line`] — the two feed the same type-36 latch. Pure and total.
#[must_use]
pub fn topic_line(title: &str) -> Option<String> {
    let stripped = title.trim_start_matches(|scalar: char| {
        matches!(
            scalar,
            '\u{2800}'..='\u{28FF}' | '\u{2733}' | '\u{FE0E}' | '\u{FE0F}'
        ) || scalar.is_whitespace()
    });
    let collapsed = collapse_whitespace(stripped);
    if collapsed.is_empty() || collapsed == "Claude Code" {
        return None;
    }
    Some(clamp(&collapsed))
}

/// The lines Swift's `split(separator: "\n", omittingEmptySubsequences: true)` produces.
///
/// Not `str::lines` and not `split('\n')`: Swift splits a `String` by CHARACTER, and `"\r\n"` is
/// one grapheme cluster that is not equal to `"\n"` — so a CRLF prompt is ONE line there, whose
/// carriage return the whitespace collapse then eats. Splitting on every `'\n'` here would cut it
/// into two and keep only the first half, silently truncating every intent a Windows-side producer
/// submits.
fn swift_lines(text: &str) -> impl Iterator<Item = &str> {
    let mut start = 0;
    let mut lines = Vec::new();
    let bytes = text.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if *byte != b'\n' || index.checked_sub(1).and_then(|at| bytes.get(at)) == Some(&b'\r') {
            continue;
        }
        if let Some(piece) = text.get(start..index) {
            lines.push(piece);
        }
        start = index.saturating_add(1);
    }
    if let Some(piece) = text.get(start..) {
        lines.push(piece);
    }
    lines.into_iter().filter(|piece| !piece.is_empty())
}

/// Swift's `CharacterSet.whitespaces`: CHARACTER TABULATION plus Unicode general category `Zs`.
///
/// Deliberately narrower than [`char::is_whitespace`], which also takes the line separators. The
/// trim above runs on a line that was already cut on newlines, and widening it would make a
/// carriage-return-only line vanish where Swift keeps it — a difference nothing would ever notice
/// until it did.
const fn is_horizontal_space(scalar: char) -> bool {
    matches!(
        scalar,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// Inner whitespace collapsed to single spaces, and the ends trimmed.
fn collapse_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for word in text.split_whitespace() {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(word);
    }
    out
}

/// Clamped to [`MAX_INTENT_CHARS`](PaneDetector::MAX_INTENT_CHARS) scalars — the same clamp the
/// machine applies to a label, so the two type-36 producers cannot disagree on length.
fn clamp(text: &str) -> String {
    if text.chars().count() <= PaneDetector::MAX_INTENT_CHARS {
        return text.to_owned();
    }
    text.chars().take(PaneDetector::MAX_INTENT_CHARS).collect()
}

#[cfg(test)]
mod tests {
    use super::{Emission, PaneDetector, StatusTriple, block_kind, intent_line, topic_line};
    use crate::signal::{ClaudeHookEvent, NotificationKind};
    use crate::status::ClaudeStatus;

    fn detector() -> PaneDetector {
        PaneDetector::default()
    }

    fn prompt(session: &str) -> ClaudeHookEvent {
        ClaudeHookEvent::UserPromptSubmit {
            session_id: Some(session.to_owned()),
        }
    }

    #[test]
    fn a_basename_edge_emits_once_and_then_dedupes() {
        let mut subject = detector();
        let first = subject.sample("/usr/local/bin/claude", 0.0);
        assert_eq!(first.foreground.as_deref(), Some("claude"));
        assert_eq!(subject.status(), ClaudeStatus::Idle, "presence lifts the floor");
        let again = subject.sample("/opt/homebrew/bin/claude", 1.0);
        assert_eq!(again.foreground, None, "the same basename is not an edge");
    }

    #[test]
    fn an_unknown_report_token_changes_nothing_at_all() {
        let mut subject = detector();
        assert!(subject.report("sideways", None, 5.0).is_empty());
        assert_eq!(subject.status(), ClaudeStatus::None);
        // The refused token must not stamp the stickiness anchor either: the very next absence has
        // to fold rather than be suppressed by a fold that never happened. The presence poll is the
        // one input with no `None` guard, so that first sample DOES open the stream — with the
        // none frame, which is the honest answer for a pane holding no agent.
        assert_eq!(subject.sample("zsh", 6.0).status, Some(StatusTriple::default()));
    }

    #[test]
    fn a_report_is_sticky_against_the_presence_poll_for_the_grace_window() {
        let mut subject = detector();
        subject.report("working", None, 100.0);
        assert_eq!(subject.status(), ClaudeStatus::Working);
        subject.sample("node", 101.0);
        assert_eq!(
            subject.status(),
            ClaudeStatus::Working,
            "a wrapper basename one second later cannot wipe an authoritative fold"
        );
        subject.sample("zsh", 100.0 + PaneDetector::REPORT_GRACE_WINDOW + 1.0);
        assert_eq!(
            subject.status(),
            ClaudeStatus::None,
            "…and past the window a plain shell terminates it normally"
        );
    }

    #[test]
    fn a_hook_established_status_survives_a_wrapper_for_the_longer_window() {
        let mut subject = detector();
        subject.hook(prompt("s1"), 0, Some("write the tests"), 0.0);
        assert_eq!(subject.status(), ClaudeStatus::Working);
        assert!(subject.suppresses_child_notifications());
        subject.sample("npx", PaneDetector::REPORT_GRACE_WINDOW + 5.0);
        assert_eq!(subject.status(), ClaudeStatus::Working, "the wrapper holds it");
        subject.sample("npx", PaneDetector::WRAPPER_SUPPRESSION_WINDOW + 5.0);
        assert_eq!(subject.status(), ClaudeStatus::None, "but not forever");
        assert!(!subject.suppresses_child_notifications());
    }

    #[test]
    fn a_nan_clock_never_suppresses_an_absence() {
        let mut subject = detector();
        subject.report("working", None, 0.0);
        subject.sample("zsh", f64::NAN);
        assert_eq!(
            subject.status(),
            ClaudeStatus::None,
            "an unordered elapsed falls through to 'not suppressed'"
        );
    }

    #[test]
    fn a_session_end_clears_the_anchor_rather_than_refreshing_it() {
        let mut subject = detector();
        subject.hook(prompt("s1"), 0, Some("do the thing"), 0.0);
        subject.hook(
            ClaudeHookEvent::SessionEnd {
                session_id: Some("s1".to_owned()),
            },
            0,
            None,
            1.0,
        );
        assert_eq!(subject.status(), ClaudeStatus::None);
        let after = subject.sample("zsh", 2.0);
        assert!(
            after.status.is_none(),
            "already at none — the absence changes nothing to report"
        );
        assert_eq!(subject.session_intent(), None, "the intent died with the session");
    }

    #[test]
    fn a_pane_that_never_had_an_intent_never_opens_its_stream() {
        let mut subject = detector();
        // A session that ends without ever submitting a prompt clears an intent that was never
        // there. Both sides of the comparison collapse to the empty string, so there is nothing to
        // report — an empty type-36 here would tell a client to blank a row it never filled.
        subject.hook(
            ClaudeHookEvent::SessionEnd {
                session_id: Some("s1".to_owned()),
            },
            0,
            None,
            0.0,
        );
        assert_eq!(subject.tick(1.0).intent, None);
        assert_eq!(subject.reestablish_on_reattach().intent, None);
        // …and once it HAS spoken, the clear is owed.
        subject.hook(prompt("s2"), 0, Some("write it"), 2.0);
        let cleared = subject.hook(
            ClaudeHookEvent::SessionEnd {
                session_id: Some("s2".to_owned()),
            },
            0,
            None,
            3.0,
        );
        assert_eq!(cleared.intent.as_deref(), Some(""));
    }

    #[test]
    fn the_intent_follows_the_work_within_a_session_and_resets_across_one() {
        let mut subject = detector();
        let first = subject.hook(prompt("s1"), 0, Some("fix the CI"), 0.0);
        assert_eq!(first.intent.as_deref(), Some("fix the CI"));
        let slash = subject.hook(prompt("s1"), 0, Some("/compact"), 1.0);
        assert_eq!(slash.intent, None, "a slash command leaves the task line alone");
        assert_eq!(subject.session_intent(), Some("fix the CI"));
        let second = subject.hook(prompt("s1"), 0, Some("now ship it"), 2.0);
        assert_eq!(second.intent.as_deref(), Some("now ship it"));
    }

    #[test]
    fn a_block_class_survives_mid_block_traffic_and_dies_with_the_block() {
        let mut subject = detector();
        subject.hook(
            ClaudeHookEvent::Notification {
                kind: NotificationKind::WaitingForInput,
                label: Some("which one?".to_owned()),
                tool_use_id: Some("t1".to_owned()),
                session_id: Some("s1".to_owned()),
            },
            2,
            None,
            0.0,
        );
        assert_eq!(subject.status(), ClaudeStatus::NeedsPermission);
        assert_eq!(subject.last_emitted_status().map(|triple| triple.kind), Some(2));
        subject.tick(1.0);
        assert_eq!(
            subject.last_emitted_status().map(|triple| triple.kind),
            Some(2),
            "a tick during a live block still reports its class"
        );
    }

    #[test]
    fn a_reattach_re_asserts_current_truth_and_stays_quiet_before_any_fold() {
        let mut subject = detector();
        assert!(
            subject.reestablish_on_reattach().is_empty(),
            "a detection-off session keeps its no-stream contract"
        );
        subject.sample("claude", 0.0);
        let again = subject.reestablish_on_reattach();
        assert_eq!(again.foreground.as_deref(), Some("claude"));
        assert_eq!(
            again.status.map(|triple| triple.state),
            Some(ClaudeStatus::Idle.urgency())
        );
    }

    #[test]
    fn an_undetected_pane_is_never_opened_by_a_title_or_a_screen_verdict() {
        let mut subject = detector();
        assert!(subject.title("zsh — README.md", 0.0).is_empty());
        assert!(
            subject
                .screen(
                    crate::screen::AgentScreenDetection::plain(crate::screen::AgentScreenState::Unknown),
                    1.0
                )
                .is_empty()
        );
    }

    #[test]
    fn the_slots_mask_names_exactly_what_is_filled() {
        let emission = Emission {
            foreground: Some("claude".to_owned()),
            status: Some(StatusTriple::default()),
            intent: None,
            title_retired: true,
        };
        assert_eq!(
            emission.slots(),
            Emission::FOREGROUND | Emission::STATUS | Emission::TITLE
        );
        assert!(!emission.is_empty());
        assert!(Emission::default().is_empty());
    }

    #[test]
    fn the_block_kind_prefers_the_ledger_then_the_event_then_what_stands() {
        assert_eq!(block_kind(1, 2, 1, false), 0, "not blocked is not qualified");
        assert_eq!(
            block_kind(1, 2, 0, true),
            2,
            "the ledger outranks the standing byte"
        );
        assert_eq!(
            block_kind(2, 0, 1, true),
            1,
            "a blocking event names its own class"
        );
        assert_eq!(block_kind(2, 0, 0, true), 2, "mid-block traffic leaves it alone");
        assert_eq!(block_kind(2, 0, 99, true), 2, "an unknown byte is not a class");
    }

    #[test]
    fn an_intent_line_is_the_first_real_line_collapsed_and_clamped() {
        assert_eq!(
            intent_line("\n\n  fix   the\tCI  \nsecond line").as_deref(),
            Some("fix the CI")
        );
        assert_eq!(
            intent_line(&"a".repeat(500)).map(|line| line.chars().count()),
            Some(PaneDetector::MAX_INTENT_CHARS)
        );
        assert_eq!(intent_line(""), None);
        assert_eq!(intent_line("   \n  "), None);
        assert_eq!(intent_line("/compact"), None);
        assert_eq!(intent_line("<command-name>/clear</command-name>"), None);
    }

    #[test]
    fn a_crlf_prompt_is_one_line_the_way_it_is_on_the_swift_side() {
        assert_eq!(
            intent_line("ship it\r\nand then rest").as_deref(),
            Some("ship it and then rest"),
            "a carriage return before the newline makes it one grapheme, not a separator"
        );
    }

    #[test]
    fn a_topic_line_strips_the_telltale_and_refuses_the_program_name() {
        assert_eq!(topic_line("✳ Fix the bug").as_deref(), Some("Fix the bug"));
        assert_eq!(topic_line("⠧ tests   running").as_deref(), Some("tests running"));
        assert_eq!(
            topic_line("✳\u{FE0E} renamed session").as_deref(),
            Some("renamed session")
        );
        assert_eq!(topic_line("my custom title").as_deref(), Some("my custom title"));
        assert_eq!(topic_line("✳ Claude Code"), None);
        assert_eq!(topic_line("⠧ "), None);
        assert_eq!(topic_line(""), None);
    }
}
