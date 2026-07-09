# UI-shell docs

Design material for the client **workspace shell** (sessions, tabs, splits, palette, settings, Claude integration surfaces). Wire/protocol is out of scope here — see parent [docs/README.md](../README.md).

**Out of scope by product decision:** cloud sync; non-Claude agents (Codex/OpenCode); large “don’t auto-build” items in [COVERAGE.md](COVERAGE.md) §E (autocomplete, full file/folder editor, quick-terminal, …).

## Start here

| File | Role |
|------|------|
| [COVERAGE.md](COVERAGE.md) | **What’s implemented** vs intentional non-builds (read this first) |
| [current-state/](current-state/) | Maps of live code seams (workspace, keybindings, settings, agents…) |
| [spec/](spec/) | Feature design pages (target behavior + screenshots) |
| [USER-STORIES.md](USER-STORIES.md) | Acceptance checklist by epic |

## Historical (shipped epics — do not re-run as open work)

Epics **E1–E21** were planned, implemented, and largely closed. Treat these as session logs, not a todo list:

| File | Role |
|------|------|
| [BACKLOG.md](BACKLOG.md) | Epic ordering + goals (pre-implementation plan) |
| [GAP-ANALYSIS.md](GAP-ANALYSIS.md) | Spec vs code matrix at planning time |
| [plans/](plans/) | Per-epic work items + carryovers |

If a gap still exists, confirm against **current code** + [COVERAGE.md](COVERAGE.md); do not trust stale “missing” rows in GAP-ANALYSIS alone.

## Screenshots

Reference UI under [screenshots/](screenshots/) (otty-era and parity references).
