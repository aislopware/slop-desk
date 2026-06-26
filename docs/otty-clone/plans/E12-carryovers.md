# E12 carry-over directives (REQUIRED — fold into the E12 plan)

E12 (Composer + Prompt Queue) inherits **no behavioral fixes from earlier epics** — E9 (the
immediately-prior epic) closed all of its review findings before this point, so there is nothing to
re-fix here. This file exists only to carry forward the **binding scope reductions** as hard
exclusions, since E12's composer/prompt-queue lives in otty's "agents" doc section where the
agent-support reduction applies. Treat each reduction below as a **hard exclusion**.

## SCOPE REDUCTIONS (binding — do NOT build these)

- **Agents = Claude Code only initially (the one that bites E12).** The composer and prompt queue
  send prompts to whatever agent is running in the **active pane** — they are agent-AGNOSTIC plumbing
  (type → `⌘↩` send / `⌥⌘↩` enqueue → OSC-133 idle dispatch). Do **NOT** add any agent-PICKER,
  per-agent backend selection, or codex/opencode-specific composer affordance even if otty's
  `agents__composer.md` / `agents__prompt-queue.md` screenshots show one. Claude Code is the only
  first-class agent; the composer targets the active pane's session, full stop. (Reading/queuing is
  not agent-driving — keep the OSC-133 `.commandFinished` idle-dispatch seam; just don't surface a
  multi-agent chooser.)
- **No horizontal tab bar.** Not relevant to the composer, but standing: never introduce a
  horizontal/top tab-bar layout anywhere E12 touches. aislopdesk is vertical-tabs-only (encoded in
  `docs/DECISIONS.md`).
- **No SSH-host filter.** Standing exclusion (primary impact E11); do not add an SSH-host filter/pill
  in any surface E12 touches.

## NOT for E12 (routed elsewhere — do not action here)

- **Agent integration UI (Claude Code) — supervision/status/approval surfaces.** Anything that drives
  or supervises the agent (status chips, run/approve controls, session lifecycle) is **E13**, not the
  composer. E12 ships only the composer + prompt-queue input mechanics. (And per the standing
  directive, E13 must never add an approval gate.)
