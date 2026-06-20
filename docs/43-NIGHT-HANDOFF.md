# 43 — Coding-Workspace Redesign: Night Handoff (2026-06-20)

Autonomous overnight build on branch **`feat/coding-workspace-redesign`**, driven by ultracode
workflows (orchestrator + per-work-item implementer agents + per-phase adversarial review). Every
layer was committed green; the wire/golden corpus was never broken. **Nothing is pushed.**

## What you asked for → what landed

| Your ask | Status |
|---|---|
| SwiftUI sidebar/topbar don't suit a coding app → research Muxy, build coding chrome | ✅ IDE shell: hidden titlebar + sessions sidebar + tab bar + split panes (C2) |
| Infinite canvas inconvenient → tabs + vertical/horizontal panes + tmux/muxy/herdr **session/workspace** model (sidebar = sessions, session → tabs, tab → panes) | ✅ `Session → Tab → Pane` n-ary split tree; canvas retired as the live UI (C1+C2) |
| Remove the dedicated "Claude Code pane" → auto-detect `claude` in any terminal pane (muxy/herdr/warp via hooks) | ✅ Process-watch + opt-in hooks; status dots in the sidebar; pane kind removed (C3) |
| Full GUI settings (terminal + GUI config) | ✅ 10-panel Settings + live terminal config + video sidecar (C4) |
| Terminal features parity with ghostty/muxy/warp | ✅ ⌘F find, right-click menu, launch presets, OSC 8 links, jump-to-prompt (C5) |

Research dossier: `docs/41-redesign-research.md`. Binding plan: `docs/42-implementation-plan.md`.
Decisions: `docs/DECISIONS.md` (redesign entries appended).

## The new model (headless, fully unit-tested)

- `Session → Tab → Pane`, each Tab owns an **n-ary recursive `SplitNode`** (`.leaf(PaneID)` /
  `.split(axis,[WeightedChild])`); zoom is out-of-tree render state (panes stay mounted at
  `opacity 0` — no libghostty surface rebuild). `Domain/Tree/`.
- The whole transport/liveness layer is **reused unchanged**: the Store's `reconcile()` registry
  pattern now also drives the tree via a shared `reconcileRegistry` helper; `PaneLeafView` renders
  each leaf — mux/wire/golden untouched.
- **Persistence v9→v10 migration** wraps the old flat canvas into one default Session/Tab,
  preserving every PaneID/PaneSpec (groups→tabs); dangling-group + unknown-kind degrade safely
  (no data loss, validate-then-repair).
- The infinite-canvas code (`CanvasView`/`FloatingPaneHandle`/canvas Store path) is **kept
  compiling as dead code** behind the runtime `liveModel` switch — a later cleanup commit deletes
  it **after you visually verify** the new shell.

## Verified headless (what I could prove without a GUI)

- `swift build` clean; **full suite green** (≈2687 tests, grew from a 2322 baseline — ~365 new).
- `make lint` (SwiftFormat + SwiftLint `--strict`, the CI gate) clean on every commit.
- `golden-check.sh` PASS — all 13 frozen wire keys intact; wire types **26/27** (Claude status)
  added additively and golden-pinned; no existing encoding shifted.
- `scripts/check-ios.sh` → **BUILD SUCCEEDED** (also fixed a pre-existing iOS rot in
  `VideoWindowView` that had nothing to do with this branch).
- `loopback-validate --smoke` green after every wire/host change.
- 5 adversarial review rounds (C1×2, C2, C3, C4+C5) — every confirmed finding fixed + re-gated;
  notably caught real bugs: migration data-loss on dangling groupID, solver `.fixed` overlap, and
  the detection pipeline's dual-emitter/no-decay architecture gap (rewired to a single source of truth).

## ⚠️ Needs YOUR eyes-on (GUI/host — impossible headless)

Run on the real MacBook (unlocked Aqua + Screen-Recording TCC):

1. **`scripts/check-macos.sh`** — the new IDE shell renders: sidebar sessions, tab bar, split panes,
   divider drag, hidden-titlebar/traffic-light layout. (Watch: titlebar vs sidebar overlap.)
2. **Settings** (⌘,): the 10 panels render; changing terminal font/theme **reloads the live terminal**;
   video/FEC changes write `video-prefs.json` and apply **on reconnect**; rebinding a shortcut takes effect.
3. **Claude auto-detect**: run `claude` in a terminal pane on the host → the sidebar/tab **status dot**
   lights (🟡 working / 🔴 needs-permission / 🔵 done → 🟢 idle decay). Optionally
   `aislopdesk-hostd integration install claude` for the richer hook path (`AISLOPDESK_AGENT_HOOKS=1`).
4. **Terminal features**: ⌘F find bar, right-click menu (copy/paste/clear/split), OSC 8 link click,
   jump-to-prompt, launch presets (Claude Code / htop / Git log).
5. **iOS**: compiles; the **compact per-tab carousel is deferred** (decision #8) — iOS currently
   renders the responsive NavigationSplitView shell.

## Deferred (tracked, intentional)

- Delete the dead canvas code (`Canvas*`/`FloatingPaneHandle`) — after you confirm the new shell.
- iOS compact carousel-per-tab.
- Manifest no-hooks fallback is wired+tested but not live-fed on the host (process-watch + hooks cover it).
- Sticky command header + host-side OSC 8 sniffer (libghostty already owns link rendering).
- Per-pane inline rename field (⌘⇧R renames the active **tab** today).

## Flags added

- `AISLOPDESK_AGENT_DETECT` (default-ON, process-watch) · `AISLOPDESK_AGENT_HOOKS` (default-OFF, opt-in socket).
- `AISLOPDESK_LEGACY_CANVAS` — reserved intent (the `liveModel` switch); the app defaults to the tree shell.
- Settings persist to `UserDefaults` (`settings.<model>.v1`) + `video-prefs.json` sidecar in App Support.

## Final gate

<!-- FINAL_GATE -->
