# 50 — Agent detection: how the hook feed and the TTY parse combine

The contract for how SlopDesk decides what a coding agent in a pane is doing. Read this before
touching `ClaudeStatusMachine`, `ClaudePaneDetector`, `PaneScreenScanner`, `AgentDetectionHold`, or
the bundled manifests. `docs/41` §4 has the original research; this file supersedes its
reconciliation rules.

Written 2026-08-11, after a user-reported flap (Tab-switching an `AskUserQuestion` walked the pane's
mark blocked ↔ idle, once per press) turned out to be a whole class of problem rather than one bug.

**This is `rust/slopdesk-agent` (stage 31, 2026-08-13; the fusion followed 2026-08-17).** Every rule
below — `kind`, `job`, `process`, `status`, `signal`, `screen`, `hold`, `input`, `machine`,
`detector` — is a zero-dependency library with an injected clock, LINKED by
`rust/slopdesk-hostsession` and reached from the client's `SlopDeskAgentDetect` in-process over the
FFI boundary (`docs/55`). `detector` is the layer above `machine`: not "what is the status now" but what the host
OWES the client after that fold — the type-26 basename edge, the type-27 dedupe anchor, the
stickiness clock and its two absence suppressors, the block-class carry, the type-36 intent latch and
the type-21 title ownership. It is the only thing anywhere that constructs a machine, and
`ClaudePaneDetector` is the handle over it plus the `WireMessage` shapes, which is the one part that
has to stay Swift. The Swift that remains is that, the case lists a SwiftUI `switch` needs, and the
marshalling; `docs/55` §6 draws that line and `rust/slopdesk-invariants` gates it. The split
against `slopdesk-screend` (docs/52) is that **screend owns everything reading the BYTES and the
agent crate owns everything reading the CLOCK**.

---

## 0. The one-paragraph version

Every pane has ONE state machine. Signals arrive from six places and are sorted into **two tiers**:
the agent describing ITSELF (tier 1) and us inferring from what it drew (tier 2). While a tier-1
feed is live, tier 2 may corroborate but not overrule — with a stopwatch as the escape hatch, so a
dead feed cannot pin a pane forever. Which tier is in force is keyed on the FEED, never on the
agent's name, so an agent with no hooks at all gets the same treatment the moment it reports its
own state.

---

## 1. Why two tiers, and not just precedence

The machine has always had a precedence list. Precedence answers *"who wins a collision"*. It does
not answer *"should this signal be in the argument at all"*, and that turned out to be the question
that mattered.

The screen engine is a heuristic reading of pixels an agent drew **for a human**. It is a genuinely
good one — a herdr port, differentially verified against the pin (§9 for where we now beat
it) — but herdr has no
hook feed, so for herdr every heuristic must be load-bearing. Ours does not have to be. When Claude
Code says `PreToolUse(AskUserQuestion)`, that is not evidence about the pane's state; it IS the
pane's state. Letting a rule-ladder verdict outrank it is a category error, and it cost exactly
what category errors cost:

- one torn mid-repaint read released a live hook block (`live_prompt_box` matches a modal dialog
  whose footer has been erased but not yet rewritten — see the 2026-08-11 DECISIONS entry);
- `needsPermission → idle` is the hook-less COMPLETION edge, so each release minted a finished turn
  — banner, sound, unread badge — for every attached client, once per Tab press.

So: tiers.

---

## 2. The signals, sorted

### Tier 1 — the agent describing itself (AUTHORITATIVE)

| Signal | Source | Reaches the detector as |
| --- | --- | --- |
| Claude Code hooks | `AgentHookListener` AF_UNIX socket, raw body | `slopdesk_agent_detector_hook` |
| ctl `report` verb | `slopdesk ctl report working\|blocked\|done\|idle` | `slopdesk_agent_detector_report` |
| presence ABSENCE | ~1 Hz foreground poll | `slopdesk_agent_detector_sample` |
| a CANCEL keystroke | client → PTY, raw bytes | `slopdesk_agent_detector_user_input` |

Nothing on that list becomes a Swift value first. Each door takes the input in the shape hostd
already holds it — a hook body as the bytes off the socket, a keystroke as the chunk headed for the
PTY — and `rust/slopdesk-agent`'s `detector` reads it and folds it in the same call. A Swift signal
type in between would be a decode whose only consumer is the next call across the same boundary.

The first two set **authoritative coverage** (`slopdesk_agent_detector_has_authoritative_feed`). ⚠️ Note
what is NOT in that column: the agent's NAME. `ctl report` is available to any process in any pane,
so a codex / gemini / opencode / bespoke-orchestrator wrapper that reports its own state gets
tier-1 treatment identically, with zero per-agent code in the machine. That is the intended way to
make a hook-less agent first-class.

The last two are authoritative but do not confer coverage: absence is the end already observed, and
a keystroke is one edge, not a feed.

### Tier 2 — inference (CORROBORATION)

| Signal | Source | Reaches the machine as |
| --- | --- | --- |
| screen rule ladder | `PaneScreenScanner` → screend's `detect` verb | `.screen(AgentScreenDetection)` |
| OSC 0/2 title | `HostOutputSniffer` | `.oscTitle(String)` |
| presence PRESENT | ~1 Hz foreground poll | `.processPresent(true)` |
| coarse manifest verdict | the legacy ctl seam | `.manifestVerdict(ClaudeStatus)` |

The OSC title is the interesting middle case: it is the agent's own emission (Claude Code writes a
Braille spinner while working and `✳` at rest), so it is trusted further than the rule ladder — it
demotes a stuck `working` even under coverage — but it never conjures presence and never clears a
block. It is the missed-`Stop` safety net.

---

## 3. Coverage

`authoritativeCovered` is TRUE from the first tier-1 feed event of a session until the session ends
(`SessionEnd`, or presence absence). Three properties are load-bearing:

- **It is not a recency window.** A pane blocked on a question for ten minutes emits no traffic at
  all. That silence is the block working as intended, not evidence the feed died. Timing out on
  silence would have re-introduced the exact bug at a ten-minute period instead of a 300 ms one.
- **It belongs to a SESSION, not a pane.** A new `claude` in the same pane earns its own coverage on
  its own first hook.
- **Any tier-1 event restores it instantly**, including after the watchdog has revoked it.

## 4. The dissent watchdog — the escape hatch

Hooks are best-effort. The relay can die, the host can restart mid-session, a record can be lost. So
the screen keeps a stopwatch: `screenDissentSince` measures how long it has contradicted the
authoritative status **without interruption**. One agreeing read resets it to zero — which is what
makes a repaint (blocked, blocked, torn, blocked, …) unable to accumulate at all.

Two windows, asymmetric on purpose:

| Direction | Constant | Value | Why |
| --- | --- | --- | --- |
| screen wants to RAISE a block | `screenDissentToRaise` | 3 s | A human in front of an unannounced dialog is the expensive failure. ~10 consecutive agreeing scans. |
| screen wants to RELEASE a block, or contradict `working` | `screenDissentToRelease` | 10 s | Releasing early flaps the mark AND mints a false finished turn. Nothing correct waits on this window — see below. |

Past its window the pane **drops coverage**, the screen applies, and the resulting transition is
marked `isQuiet` — it is the detector correcting itself, never something to announce. Dropping
coverage also frees `ownerSessionID` (§5b).

Two things about HOW it runs are load-bearing, and both were wrong once:

- **It runs on the clock, not on the next fold.** `AgentDetectionHold.shouldPublish` only publishes a
  CHANGED verdict, and its one heartbeat requires `visibleBlocker` on both sides — so a steady
  dissent is folded EXACTLY ONCE and a fold-driven window can never elapse. The stopwatch is
  anchored on the first dissenting fold and re-checked from `reduce`, on every tick and every
  signal. Before that, the escape hatch was unreachable in the live pipeline while its unit test
  passed, because the test drove `reduce(.screen(…))` directly.
- **The verdict is tried FIRST, and coverage is revoked only if it lands.** A matured dissent whose
  verdict cannot apply — a PLAIN idle against a hook block — used to revoke coverage and ownership
  and then change nothing, leaving the pane both stale AND unclaimed, so the next nested `claude -p`
  could take it.

⚠️ **A hook does not reset the stopwatch.** `apply()` used to clear the dissent on every hook, which
meant the watchdog could never mature while a turn was still emitting hooks — exactly when a stale
ledger entry pins a pane blocked. Only an AGREEING screen read clears it; a hook re-checks whether
its own move has resolved the disagreement (`reconcileScreenDissent`).

**Nothing correct waits on the release window.** Every legitimate way out of a block announces
itself on tier 1, immediately:

| Resolution | Tier-1 signal | Latency |
| --- | --- | --- |
| question answered | `PostToolUse` of that call | instant |
| permission approved | `PreToolUse` of the gated call | instant |
| permission denied | `PermissionDenied` of that call | instant |
| a call FAILED / was interrupted | `PostToolUseFailure` of that call | instant |
| MCP elicitation answered | `ElicitationResult` of that id | instant |
| turn finished | `Stop` / `StopFailure` | instant |
| dialog Esc-cancelled | `.userInput` (no hook exists for it) | instant |
| agent exited | presence absence / `SessionEnd` | ≤ 1 poll |

## 5. The block ledger

A hook block is a SET of outstanding calls keyed by `tool_use_id`, not a flag
(`ClaudeStatusMachine.BlockEntry`). Claude Code emits tool calls in BATCHES, so "a tool finished"
and "the human answered" stopped being the same fact: an assistant turn carrying
`[AskUserQuestion, Bash]` fires both `PreToolUse` hooks, and the `Bash` result then cleared the
block while the question was still on screen and un-answered.

| Entry kind | Opened by | Resolved by |
| --- | --- | --- |
| `.ask` | `PreToolUse(AskUserQuestion)`, `agent_needs_input`, `elicitation_dialog` | its OWN `PostToolUse` **or `PostToolUseFailure`**; a turn boundary; a cancel key |
| `.permission` | `PermissionRequest`, `permission_prompt` | its own `PreToolUse`/`PostToolUse`/**`PermissionDenied`**; a turn boundary; a cancel key |
| id-less | any of the above with no `tool_use_id` | any tool traffic — it names no call, so there is no better handle and the alternative is a hand nothing can lower |

Turn boundaries (`Stop`, `UserPromptSubmit`, `SessionStart`, `SessionEnd`) and presence absence
empty the ledger entirely.

⚠️ A `.permission` entry used to be dropped by ANY `PreToolUse`, on the reasoning that a permission
dialog is modal so anything starting proves it is gone. That is false for a BATCH: `[Read(a),
Bash(gated)]` raises the prompt on `Bash` and then `Read`'s own `PreToolUse` fires while the human is
still looking at it — the same failure the ledger was built to fix, left open in one direction. The
denial it stood in for is announced properly now (`PermissionDenied`), so **every** kind resolves by
identity, and a hand nothing answers still comes down on Esc, on `Stop`, and on the watchdog.

⚠️ **A body that sends no `tool_use_id` arrives with none.** Minting one is tempting and wrong: it
would be a DIFFERENT string on the pre and the post hook, so the ledger entry it opened could never
be resolved and the call would block the pane forever. `rust/slopdesk-hookevent` leaves it `None`
and a nil id degrades to the id-less rule (resolved by the next `Stop`, an Esc, or the watchdog).

A SCREEN-raised block carries no call identity and never touches the ledger; its `BlockSource`
provenance flag governs it exactly as before.

⚠️ **A call can end WITHOUT a `PostToolUse`.** Claude Code emits `PostToolUseFailure` on the catch
path INSTEAD of `PostToolUse` (verified in 2.1.227: the failure emitter is invoked from the tool
loop's `catch`), carrying the same `tool_use_id`. Since an `.ask` entry is deliberately immune to
any other call's `PreToolUse`, that was the difference between a failed `AskUserQuestion`
resolving and a hand staying raised over a vanished dialog for the rest of the turn. Both it and
`PermissionDenied` are now installed and parsed, and both map to the same "this call is over"
resolution. `slopdesk-agenthooks`' `install::INSTALLED_EVENTS` is the list of what we register; a hook we do not
register cannot be a signal, and a hook we register but do not parse is a silent drop.

⚠️ **`is_installed` means ALL of `INSTALLED_EVENTS`, not any.** A settings file written by an older
build carries the events THAT build knew; answering "installed" for it leaves every event added since
permanently unregistered, and the Settings row that would offer the fix reads as already done.
Under-reporting is the safe direction — the merge is idempotent, so re-installing over a complete
install is a no-op, while the reverse is a degraded pane forever.

`Elicitation` / `ElicitationResult` (an MCP server asking the human for structured input) join the
ledger the same way, keyed on `elicitation_id` — a different id namespace doing the same job. That
block was previously reachable only by text-classifying a `Notification` message as
`elicitation_dialog`, which is inference where an announcement exists. When the payload names no
`elicitation_id`, the key falls back to `elicitation:<mcp_server_name>`
(`AgentHookHandler.elicitationKey`): an id-less entry is swept by any unrelated call, so a nil key
would hand the pane back as working with the MCP prompt still on screen.

⚠️ **An INTERRUPT is not a failed call, it is a finished turn.** `PostToolUseFailure` carries
`is_interrupt`, and Claude Code emits **no `Stop`** when the human presses Esc. Mapped as an ordinary
failure it pinned the pane `working` with the spinner up until the watchdog corrected it — ten
seconds later, into a "turn finished" announcement for a turn the user had cancelled. It maps to
`.interrupted` → idle, QUIETLY.

**Audited against the CLI, not against memory** (2.1.227 emits 31 distinct `hook_event_name`s). The
ones deliberately NOT installed carry no pane status: `ConfigChange`, `CwdChanged`,
`DirectoryAdded`, `FileChanged`, `InstructionsLoaded`, `MessageDisplay`, `Setup`, `WorktreeCreate`,
`WorktreeRemove`, `PostToolBatch`, `PostCompact` (the `PreCompact` marker already covers it),
`SubagentStart`, `TaskCreated`, `TaskCompleted`, `TeammateIdle`, `UserPromptExpansion`. Re-run that
diff before concluding a signal is missing.

## 5b. Session ownership — whose hooks are these?

The relay routes by `SLOPDESK_PANE_ID`, an **environment variable**, so every descendant of the
pane's shell inherits it. A `claude -p …` from a script, a Makefile, or the pane agent's own Bash
tool is a separate claude with its own session id posting the **full hook set** to the pane that
spawned it. Ungated, its `SessionStart` cleared the pane agent's block, its `Stop` minted a
finished turn, its `SessionEnd` blanked the pane and armed the post-exit lockout, and its prompt
re-titled the session — all while the real agent sat waiting on a human.

So a pane belongs to ONE session (`ClaudeStatusMachine.ownerSessionID`):

- the first id-carrying event **claims** it;
- an event naming a **different** session is dropped whole — not the status, not the presence
  floor, not the liveness anchor, not the type-36 title (`ClaudePaneDetector` asks
  `machine.accepts(_:)` before any of its own side effects);
- an event carrying **no** session id always applies and never claims, so ctl `report` and every
  unattributed feed behave exactly as before.

`session_id` rides the hook ENVELOPE, not the tool, so the cases that model a call carry none.
`rust/slopdesk-hookevent` reads it off the envelope and stamps it into every empty slot, so a
reading arrives already attributed — the fold never sees an unattributed hook.

**Why this is safe for `/clear` and `/resume`** — the everyday way a pane changes session. Verified
against the shipped CLI (2.1.227): `clearConversation` **awaits** the `SessionEnd` hook
(`reason: "clear"`) before doing anything else, and `/resume` does the same with `reason: "resume"`.
The old session hands the pane back before the new one speaks. That is the entire difference
between a replacement and a nested run: a replacement says goodbye, because it had the pane.

**Released by** the owner's `SessionEnd`, presence absence, the dissent watchdog, and a
`SessionStart` from another session **while the pane's turn is over** (`status` idle / done / none).

That last one is what recovers a crash. An agent killed without a `SessionEnd` and re-run in the same
pane lands inside `ClaudePaneDetector`'s absence-suppression window — 30 s, or 600 s behind a wrapper
basename — so no `processPresent(false)` ever frees the pane, and every hook of the new session is
dropped whole. It is gated on the pane being AT REST because that is the one thing a nested run can
never be: a nested `claude -p` is spawned BY a tool call, so the owner is `working` or blocked at
that instant, by construction. A crash-restart is the opposite. Mid-turn crashes are left to the
watchdog: being briefly stale is recoverable, whereas following a nested run's `SessionEnd` blanks
the pane.

⚠️ **Deliberately not released on a timer.** A nested run can hold the terminal for minutes while
the owner says nothing — the owner's `PostToolUse` for the spawning Bash call cannot arrive until
the nested claude exits — so any silence window short enough to be useful is also short enough to
hand the pane to the very process this exists to ignore. The gate is the pane's own state, which
needs no window guessed.

## 6. Quiet transitions

`ClaudeStatus` has no way to say "this changed, but nobody did it". The wire `kind` byte does:
`AgentStatusKind.quiet` (4). A quiet transition moves every dot, rollup and document field and
raises NO attention — not the coalesced edge, not the hook-less completion edge. Vetoed on BOTH
sides: `WorkspaceStore.setAgentStatus(quiet:)` on the client, and
`MuxChannelSession.notifyAgentStatusChanged(_:quiet:)` on the host, which is what the multi-client
unread latch actually reads.

Today exactly three things are quiet:

1. the `Stop` that ends a `/compact` (2026-08-10);
2. an Esc-cancelled dialog — the human dismissed it, they were by definition looking at it;
3. a watchdog correction;
4. an INTERRUPTED turn (`PostToolUseFailure` with `is_interrupt`) — the same Esc, announced by the
   agent rather than seen in the keystrokes.

All four land on `working|needsPermission → idle`, the hook-less completion shape. Without the
qualifier each one announces a turn that never finished.

## 7. Below the machine: the scan layer

Two guards run in `PaneScreenScanner` / `AgentDetectionHold` BEFORE a verdict is ever published, so
the machine only ever sees settled readings:

- **The synchronized-frame hold** — never read a grid the program has not finished painting.
  screend's `syncwatch` is a byte-at-a-time DECSET/DECRST 2026 parser and reports `frameOpen` +
  `frameGeneration` with every verdict; while a synchronized update is open the scanner publishes
  nothing and rechecks at 100 ms, bounded by `syncFrameHoldCap` (1 s). The cap is per FRAME, keyed
  on `frameGeneration` — a busy TUI opens a new frame every few milliseconds, so a cap anchored on
  "a frame was open last scan too" would let one second of ordinary repainting retire the guard
  permanently. ESC inside a CSI aborts and re-enters escape (the VT500 anywhere-transition);
  swallowing it lost the whole sequence that followed a re-sync. The PARSER is screend's and the
  DEADLINE is hostd's, which is the split throughout: screend owns everything that reads the bytes,
  hostd owns everything that reads the clock.
- **`AgentDetectionHold.shouldHoldBlockedToIdle`** — leaving a block takes three confirming reads.
  Ours, not herdr's, and deliberately stricter than its `working → idle` sibling: a VISIBLE idle
  does not bypass it, because the visible idle is the false verdict.

These are defence in depth. With the tiers in place a torn read no longer reaches a decision at
all — but a hook-free pane has no tier 1, and for that pane these guards ARE the protection.

## 8. Invariants

- ONE machine per pane. Two machines emitting type-27 down one control stream fight, and neither
  drives the `done → idle` decay. `ClaudePaneDetector` is the single fusion point.
- The machine never reads a wall clock. Every `reduce` takes an injected `now`.
- Tier 2 never changes the status under coverage — only the watchdog can, and only by first
  revoking coverage.
- The tier is keyed on the FEED, never on `AgentKind`.
- The bundled manifests are a herdr port diffed by `slopdesk-herdr differential`
  (`rust/slopdesk-devtools`) — but parity is no longer the goal. `DIVERGED_RULES` in that crate
  names the RULES we have deliberately made
  BETTER than upstream (today `claude`'s `live_prompt_box` and `legacy_no_prompt_blocker`), and
  divergence is scoped to the rule: every other rule of a diverged agent stays under test, because
  "we improved one rule" must not retire the guard on the twenty we did not touch. A mismatch is
  excused only when a diverged rule is what explains it. Adding an id needs a written reason in the
  script and a test that pins what the divergence buys.

## 9. Cross-region gates (⚠️ diverges from herdr)

A nested gate may carry its own `region`, overriding the rule's for that gate only:

```toml
not = [
  { region = "after_last_horizontal_rule", any = [{ contains = ["esc to cancel"] }] },
]
```

herdr has no syntax for this: there, every gate reads the rule's region. That is what made
`live_prompt_box`'s five footer needles **dead code** — a modal dialog's footer sits below the last
horizontal rule, outside `prompt_box_body` by construction, so the veto never saw the thing it was
written to stop, while the dialog's focused option `❯ 1. …` satisfied the rule's `^\s*❯` caret. The
result was the strongest idle verdict the engine can produce, for a pane blocked on a human.

`live_prompt_box` now carries TWO vetoes, because they fail in different places:

| Veto | Reads | Covers |
| --- | --- | --- |
| cross-region footer | `after_last_horizontal_rule` | a WHOLE dialog — strict complement of `live_blocked_form`, so exactly one of the two can fire |
| option list | its own region: `❯ 1. …` **plus** a sibling `  2. …` | a TORN dialog, where the repaint has erased the footer from every region |

Requiring the sibling option is what keeps a human who types `1. foo` at a real prompt from being
vetoed — and even then the cost is only `visible_idle`, since the `✳` title rule still reports the
pane idle. Pinned by `rust/slopdesk-screend/tests/cross_region_gate.rs`. Validation is symmetric: a bogus `region` in a
nested gate rejects the whole manifest, exactly as it does on a rule — and a gate region is an
**engine-3** key, so a manifest that uses one must declare `min_engine_version >= 3`. An engine that
predates it ignores the key silently, and silently ignoring a VETO is how a rule fires on the screen
it was written to skip. A rule's own `region` is NOT copied onto its root gate: it is inherited, so
copying it re-resolves the region text on every evaluation and makes every rule look like it uses
this feature.
