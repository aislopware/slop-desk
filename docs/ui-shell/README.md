# UI-shell docs

Design material for the client **workspace shell** (sessions, tabs, splits, palette, settings, Claude integration surfaces). Wire/protocol is out of scope here — see parent [docs/README.md](../README.md).

**Out of scope by product decision:** cloud sync; non-Claude agents (Codex/OpenCode); large “don’t auto-build” items in [COVERAGE.md](COVERAGE.md) §E (autocomplete, full file/folder editor, quick-terminal, …).

## Start here

| File | Role |
|------|------|
| [COVERAGE.md](COVERAGE.md) | **What’s implemented**, what was removed after shipping, and what is intentionally not built (read this first) |
| [USER-STORIES.md](USER-STORIES.md) | Every acceptance story by epic, each tagged with its state |
| [current-state/](current-state/) | Maps of live code seams (workspace, keybindings, settings, agents…) |
| [spec/](spec/) | Feature design pages — **target** behaviour + screenshots, not a claim about the tree |

## What state a feature is in

Do not read a summary here; there is no summary to maintain. Two files carry the answer, and they
carry it per-row with a `file:line` or a commit beside each one:

- **[COVERAGE.md](COVERAGE.md)** groups by outcome — §A covered, §B removed after shipping, §C
  macOS-only splits, §D intentional exclusions, §E intentionally not built, §F claims that were never
  true.
- **[USER-STORIES.md](USER-STORIES.md)** marks every story **GONE**, **NEVER BUILT**, **MAC ONLY**,
  **PARTLY**, or unmarked for “ships on both platforms”.

Four whole epics — **E9** (Details/Inspector panel), **E12** (Composer + prompt queue), **E16**
(recipes + snippets) and **E21** (remote-window mode) — were built and then **deleted**; several
others lost rows the same way. Both files say so per row, with the ruling in
[`docs/DECISIONS.md`](../DECISIONS.md).

## Historical (planning material — do not re-run as open work)

Epics **E1–E21** were planned and implemented during 2026-06. These are session logs from that
period, frozen at planning time and **not maintained** — a row here is evidence of what was intended,
never of what ships:

| File | Role |
|------|------|
| [BACKLOG.md](BACKLOG.md) | Epic ordering + goals (pre-implementation plan) |
| [GAP-ANALYSIS.md](GAP-ANALYSIS.md) | Spec vs code matrix at planning time |
| [plans/](plans/) | Per-epic work items + carryovers |

If you think a gap still exists, confirm against **current code** plus COVERAGE.md and USER-STORIES.md.
Do not trust a stale “missing” row in GAP-ANALYSIS — and do not trust a “done” row in a plan either;
some of what those plans closed has since been deleted.

## Screenshots

Reference UI under [screenshots/](screenshots/) (otty-era and parity references).
