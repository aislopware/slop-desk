# E12 carry-over directives (REQUIRED — fold into the E12 plan)

E12 (Composer + Prompt Queue) inherits **no behavioral fixes** — E9 (prior epic) closed all its
review findings. This file carries forward the **binding scope reductions** as hard exclusions, since
E12's composer/prompt-queue is under the "agents" surface where the agent-support reduction applies.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **Agents = Claude Code only initially (the one that bites E12).** Composer and prompt queue send
  prompts to whatever agent runs in the **active pane** — agent-AGNOSTIC plumbing (type → `⌘↩` send /
  `⌥⌘↩` enqueue → OSC-133 idle dispatch). Do **NOT** add an agent-PICKER, per-agent backend selection,
  or codex/opencode-specific composer affordance even if `agents__composer.md` /
  `agents__prompt-queue.md` show one. Composer targets the active pane's session, full stop.
  Reading/queuing is not agent-driving — keep the OSC-133 `.commandFinished` idle-dispatch seam; just
  don't surface a multi-agent chooser.
- **No horizontal tab bar.** slopdesk is vertical-tabs-only (encoded in `docs/DECISIONS.md`); never
  introduce a horizontal/top tab-bar layout anywhere E12 touches.
- **No SSH-host filter.** Standing exclusion (primary impact E11); do not add one in any surface E12
  touches.

## NOT for E12 (routed elsewhere — do not action here)

- **Agent integration UI (Claude Code) — supervision/status/approval surfaces.** Anything that drives
  or supervises the agent (status chips, run/approve controls, session lifecycle) is **E13**. E12
  ships only composer + prompt-queue input mechanics. Per standing directive, E13 must never add an
  approval gate.
