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

## Final gate (all green)

- **`make check`** (lint + build + test + golden) → **PASS**. Full XCTest suite **2707 tests, 0 failures**
  (from a 2322 baseline — ~385 new). `make lint` (SwiftFormat + SwiftLint `--strict`, the CI gate) clean.
- **`golden-check.sh`** → **PASS, byte-identical**; all 13 frozen wire keys intact. Wire types 26/27 added
  additively + golden-pinned.
- **`scripts/check-ios.sh`** → **BUILD SUCCEEDED** (both `ClientApp-iOS` + `AislopdeskClientUI` schemes).
- **`aislopdesk-loopback-validate --frames 120`** (real-VT encode→FEC→reassemble→decode) → **exit 0**
  across clean / 2% / 10% loss, FEC tiers, interleave, RS m=2/3, LTR.
- **22 atomic green commits** on `feat/coding-workspace-redesign` (HEAD `0436798`). Unpushed, unmerged.
- **5 adversarial review rounds** (C1×2, C2, C3, C4+C5) — every confirmed finding fixed + re-gated.

Each layer was committed only after building + testing green; the wire/golden corpus was never broken.
Push / merge / `git diff main...HEAD` whenever you're ready; the dead canvas cleanup + the deferred items
above are the natural follow-ups after your `check-macos.sh` pass.

## Addendum — Terminal "Blocks" (Warp-style, added post-handoff, now merged in)

A follow-on requested in conversation; spiked → built → reviewed → fast-forward-merged into this branch
(4 commits on top: `bb70903` spike, `082b178` WB1, `1795730` WB2, `25796eb` review-fix). Now **27 commits vs main**.

- **Host segments the PTY stream into per-command blocks from the OSC 133 marks it already sniffs**
  (`CommandBlockSegmenter` + `CommandBlockTracker`, bounded ring). New wire types **28 `commandBlock`** /
  **15 `requestBlockOutput`** / **29 `blockOutput`** (additive, golden-pinned `blocksWireMessages`, 13 frozen
  keys intact). Gated `AISLOPDESK_BLOCKS` (default-ON; off ⇒ byte-pipeline byte-identical, proven).
- **Client UI**: Command Navigator (⌃⌘O), sticky command header, chrome status chip, jump prev/next
  (⌃⌘[ / ⌃⌘]), "Copy Command Output" in the right-click menu. **No inline row-aligned gutter** — libghostty 1.3.1
  exposes no prompt-mark positions (verified in `ghostty.h` + `PageList.zig`), so jump uses `scroll_to_bottom`
  re-anchor + `jump_to_prompt`; the navigator/header/chip are the row-alignment-free surfaces.
- Review caught + fixed: viewport-relative jump math, CSI-leak into commandText (colorized shells), copy
  timeout race, copy-while-running. Full suite **2799**, `make check` + `check-ios` + loopback all green.
- **Needs eyes-on** (`check-macos`): the navigator/header/chip render + live jump/copy over a real libghostty
  surface. Needs a shell with **OSC 133 shell-integration** (`ShellIntegration.swift`) for blocks to appear.

## Addendum — three more follow-on features (same overnight session, "tiếp tục ý tưởng hay khác")

Each was orchestrated as an **implement → 5-dimension adversarial review → verify → fix** workflow and committed
only after I re-ran `make check` myself (lint + build + full suite + golden). **All four are client-only: no
wire/host/FFI/golden/schema change; golden byte-identical every time.** Branch now **33 commits vs main, unpushed.**

1. **Blocks++** (`87c7223`) — the Warp block superpowers on top of the Blocks feature above:
   - **Re-run command** (`⌃⌘R` last-command + per-row button): `BlockReRunEncoder` re-injects the captured
     `commandText` as **verbatim literal UTF-8 + one `\n`** through the existing input path — never via
     `SendKeysParser`, so a command literally containing `<Enter>`/`<cr>` re-runs unchanged (correctness + injection safety).
   - **Status filter + jump-to-failed** (`⌃⌘⇧[` / `⌃⌘⇧]`): navigator segmented control (all/failed/bookmarked) +
     a per-pane cursor jumping over FAILED blocks only.
   - **Bookmark/star**: persisted via `PreferencesStore` keyed by a **per-session `bookmarkScopeKey`** (NOT the
     relaunch-stable `PaneID` — block indices restart at 0/session; review caught a real "stars graft onto unrelated
     commands after relaunch" bug here).
   - Review: 14 raw → 7 confirmed → all fixed (incl. a tautological routing test replaced by 10 mutation-proven
     dispatch tests via a `TerminalModelProviding` seam + recording double).
2. **Session templates / project profiles** (`08b3bb6`) — open a named workspace with a predefined split layout +
   per-pane cwd/startup command; capture the current layout as a reusable template.
   - Recursive `TemplateNode` (`PaneSpec` deliberately has no cwd/command → those ride the keystroke path); pure
     `SessionTemplateEngine` (makeSession / captureTemplate round-trip / `launchBytes` reusing the cd-as-literal-UTF-8
     safe path); `TreeWorkspace.sessionTemplates` via `decodeIfPresent` (old v10 files decode `[]` + reseed — **no
     migration**); 3 built-ins incl. **Claude + Terminal** (ties into the Claude auto-detect work).
   - Surfaced as a dynamic **Command Palette** section (no chord pressure). `newSessionFromTemplate` mirrors
     `applyLaunchPreset`; the 1400 ms launch-send is testable via an injectable `launchGrace` seam (proves the Claude
     pane gets `claude\n`, the plain pane nothing). Review: 10 → 4 confirmed → all fixed.
3. **Keyboard-driven pane management** (`e319049`) — the split-tree primitives already existed; this adds the
   user-facing layer so panes are fully keyboard-drivable:
   - **Move/swap** in direction (`⌥⌘⇧←→↑↓`), **resize** active split (`⌃⌘←→↑↓`, right/down grow · left/up shrink),
     **balance** splits (`⌃⌘=`). New pure ops (`movePaneInDirection`, `enclosingSplit(of:axis:)` query,
     `resizeActivePane`, `rebalanced`) carry the tests; the 9 chords are pinned by `TreeCommandRoutingTests`.
   - Review: 11 → 4 confirmed → all fixed (resize now mutates the *located* tab not the active one; two real
     test-rigor holes closed).
4. **Background-pane command-completion awareness** (`0f743e3`) — finishes the half-built "notify on finish"
   (the `TODO(B3)` focus gate) and adds an in-app badge, consuming the existing `.commandStatus(.idle)` wire (OSC 133
   exit + duration — zero new wire):
   - **Focus-gated notification**: a long command now notifies **only when its pane is backgrounded** (no spam while
     you watch it); the notify decision moved into the store so the gate applies, and the notification now embeds the
     paneID so a **click reveals the pane** (was OSC-9-only before).
   - **In-app ✓/✗ badge** on the tab + session sidebar (mirrors `AgentStatusDot`): set on a background completion
     (failures always; successes only when long, to avoid `ls`/`cd` noise), cleared on focus / app-active.
   - Pure `BackgroundCompletionPolicy` + store handler carry the tests; the `UNUserNotificationCenter` delivery +
     SwiftUI badge are thin shims. Review: 12 findings → **0 confirmed**. `check-ios` BUILD SUCCEEDED (app/scenePhase touched).

### Needs YOUR eyes-on for these four (still impossible headless)
- **Blocks++**: re-run button + `⌃⌘R`; the all/failed/bookmarked filter + `⌃⌘⇧[`/`⌃⌘⇧]` jump-to-failed; star toggle +
  persistence across a relaunch (stars should NOT reappear on unrelated commands).
- **Templates**: the Command Palette "Session Templates" section opens a multi-pane session that auto-`cd`s/runs the
  per-pane command; "Save Layout as Template…" round-trips.
- **Pane management**: move/resize/balance chords on a real multi-pane tab (divider actually nudges; balance evens out).
- **Completion awareness**: run a long command in a background pane → ✓/✗ badge appears on its tab/sidebar (clears on
  focus) + a "command finished" notification fires (and **only** when that pane is NOT focused); clicking it reveals
  the pane. Needs `SettingsKey.longCommandNotificationsEnabled` on + notification permission granted + OSC 133 shell-integration.
