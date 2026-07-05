# E20 carry-overs — CLI parity + watch + first-launch (the FINAL epic)

> Each carry-over is an **additional acceptance criterion**; each scope reduction a **hard exclusion**. E20 is the **last epic** in the UI-shell ladder — after it the UI shell is feature-complete.

## §0 — What E20 is, and the standard it is held to

**Goal (BACKLOG):** extend the `slopdesk` CLI to full command-surface parity and add the first-launch flow. Acceptance: **ES-E20-1…4** (USER-STORIES).

Two halves:
1. **CLI parity** (headless, the bulk) — map the designed subcommand surface onto slopdesk's existing control plane. Overwhelmingly **pure parse/dispatch + reuse of existing engines** → **heavily headless-testable** (revert-to-confirm-fail on parser/dispatcher/frecency/exit-codes). No screenshot governs CLI text output beyond `spec/reference__cli.md` behaviors.
2. **First-launch flow** (GUI) — a guided setup surface. **Visual standard = the 6 screenshots in `spec/getting-started__first-launch.md`** (`first-launch.png`, `launch-option.png`, `first-launch-default-terminal.png`, `theme-list.png`, `change-theme.png`, `first-launch-agents.png`). Mostly **wiring already-built settings** (E7 On-Launch, E15 theme, E13 Claude-hooks) into a first-run path.

**DESIGN PHASE FIRST JOB = a current-state audit** of `Sources/SlopDeskCtlCore/CtlCore.swift` + `Sources/slopdesk-ctl` + `Sources/SlopDeskHost/AgentControlListener.swift`, then map designed subcommands onto what exists. EXTEND the existing JSON-RPC control protocol; do **not** rebuild a parallel CLI. A large pile of net-new files signals you are rebuilding an existing engine — audit first.

**Absorbs E16's deferred CLI** `slopdesk open <recipe>` (GUI open-recipe shipped in E16 `fc18e5b`; only the CLI subcommand was deferred).

## §1 — Reuse map (grep-grounded at HEAD `443883a`; VERIFY each before building)

| CLI subcommand / feature | slopdesk reuse seam (EXISTING) | notes |
|---|---|---|
| `ipc`, `state:<agent>`, control transport | `SlopDeskCtlCore/CtlCore.swift` (JSON-RPC line protocol: `parseGlobal`, `encodeRequestLine`/`decodeResponseLine`, `listPanes/read/write/run/wait/spawn/kill/subscribe/report/resize/subscribeAll` param builders) + `slopdesk-ctl` executable + host `AgentControlListener.swift`/`AgentControlState.swift` | **The spine.** `SLOPDESK_AGENT_CONTROL=1`, AF_UNIX NDJSON. EXTEND with new methods; the NDJSON control protocol is **NOT** the golden-frozen binary wire (golden freezes terminal/video/inspector binary paths) → adding control methods does **not** touch golden. |
| `pane send-keys -- "text" key:Enter` | existing `writeParams(text:)` (verbatim) + named-key path | **Literal text = VERBATIM UTF-8; named keys = keycode path. NEVER route literal text through SendKeysParser** (CLAUDE.md / [[slopdesk-coding-workspace-redesign-2026-06-20]]). Already exists — pin it, don't rewrite. |
| `jump [query]` / `learn [path]` / `ignore <path>` | `Folders/FolderFrecencyStore.swift` + `FolderFrecency.swift` (E11) | Frecency engine EXISTS. `jump` resolves a path client-side then sends `cd <resolved>\n` VERBATIM via the mux; no-query toggles `$HOME`↔last-jump; `--no-cd` prints only. `learn` no-arg + `jump` default need the **cached OSC-7 host cwd per pane** (cwd lives on host — cache last OSC-7 value client-side; spec "Cannot map 1:1"). |
| `open [recipe]` (E16 deferral) | `Domain/Recipe/Recipe.swift` + `RecipeTOMLCodec.swift` + `PortablePaths.swift`; GUI open-recipe wired in E16 | CLI subcommand = parse `.slopdeskrecipe` (validate-then-drop) → drive the SAME store op the GUI uses. Recipe-by-name resolves `savedLibrary`. |
| `watch <cmd>` | `Protocol/ProgressState.swift` (wire type 32, E14) + host `AutoProgressMatcher.swift` + `WorkspaceStore+Progress.swift` + `App/DockProgressController.swift` | OSC 9;4 path EXISTS end-to-end. `watch` = thin wrapper running `<cmd>`, emits OSC 9;4 (spinner→success/error badge on exit), then posts a "Notify on Watch Finish" notification; `-q`/`--quiet` suppresses it. NOTE `slopdesk-framewatch` is the VIDEO framewatch — NOT this; do not conflate. |
| `watch:claude <id>` | `SlopDeskAgentDetect` (`ClaudeManifestMatcher`/ClaudePaneDetector) + host `AgentControlListener` | Block until the claude session reaches idle. **Exit codes: 0 = idle/closed, 4 = id never seen, 9 = timeout.** **CLAUDE ONLY** — see §4. |
| `tab badge --kind <kind>` | E6 `TabBadgeResolver` / `WorkspaceStore` badge state | Kinds `running/completed/finished/unread/error/awaiting-input` map onto existing ClaudeStatus/agent lifecycle. |
| `pane capture --lines N` | `ReplayBuffer` read / inspector (read-only 2nd TCP path) | Capture last N lines of pane output. |
| `config get/set/unset/edit/show/path/validate/reload`, `--transient` | `EnvConfig` + `PreferencesStore` + `ConfigStore`/`EnvBridge` ([[slopdesk-gui-pane-keybind-settings-plan-2026-06-24]]) | `--transient` = write `EnvConfig` without persisting to `PreferencesStore`. `reload` = broadcast a config-change notification. |
| `theme list/import`, `font list/apply/import`, `keybind list` | `ThemeStore`/`ThemeLibrary` (E15), libghostty font config (E15), `WorkspaceBindingRegistry` | E15 already imports iTerm2/Kitty/Alacritty/Ghostty themes → reuse for `theme import`. `keybind list` = registry dump (+`--action` filter). |
| On-Launch (first-launch step 1) | E7 On-Launch (`07516ec`/`26a8f74`; `Restore Last Session` ↔ `DetachedSessionStore`, `SLOPDESK_DETACH_ENABLED`) | EXISTS — surface it in first-launch; do not rebuild. |
| Install Claude hooks (first-launch step 5) | E13 `HostAgentActionPerformer` + MetadataVerb `installAgentHooks=11`/`uninstall=12`/`status=13` (`cf805a3`) | EXISTS — reuse the install card. **Claude only.** |
| Theme (first-launch step 4) | E15 theme grid + Command-Palette theme flow (E2 palette) | EXISTS. |
| `version` | `Bundle.main.infoDictionary` version + build hash | Trivial. |

## §2 — Genuine gaps to BUILD (priority order)

1. **`slopdesk` CLI subcommand surface** mapping the full designed CLI onto `SlopDeskCtlCore` — `open/view/edit`, `config …`, `font/theme/keybind list`, `tab/pane/window` (+plural shortcuts), `tab badge --kind`, `pane capture`, `jump/learn/ignore`, `version`, `completions`, plus global flags `--json`/`--format json`, `--no-headers`, `--socket`, `--config-file`, `--timeout`, `-y/--yes`. **`--json` must produce structured output (ES-E20-1).** Bare `slopdesk` / `slopdesk -e <cmd>` launches the GUI (xterm-like). Pure parser/dispatcher → headless-test exhaustively.
2. **`watch <cmd>`** wrapper (OSC 9;4 spinner→badge + notification, `-q`) — **ES-E20-2**.
3. **`watch:claude <id>`** blocking with **exit 0/4/9** — ES-E20-2.
4. **Install-CLI flow** (Settings → Shell): symlink `/usr/local/bin/slopdesk` (admin-once via the existing privilege path — NOT app-crypto), **Omit-prefix** shell-function injection (`edit`/`view`/`watch`/`jump`/`learn` as bare functions in app-launched shells), **Allow-Overwrite** toggle.
5. **`completions <shell>`** — bash/zsh/fish/elvish/powershell.
6. **First-launch flow chrome** — a guided first-run surface composing existing settings (On-Launch picker, Set-as-Default-Terminal [LOCAL handler], Install CLI, Theme, Install Claude hooks) per the 6 screenshots. **GUI-verifiable → ES-E20-4.**
7. **`slopdesk open <recipe>`** — the E16 CLI deferral (§1).

## §3 — Constraints (hard)

- **Claude Code ONLY** (binding). `watch:<agent>` ships **`watch:claude` only** — never surface/scaffold `watch:codex`/`watch:opencode`. Agent-hooks install = Claude only. Never expose `AgentKind.codex`/opencode in CLI help, completions, or first-launch.
- **send-keys / jump / cd / recipe-command injection = VERBATIM UTF-8** for literal text; named keys (`key:Enter`) via keycode path. **NEVER SendKeysParser** for literal text. Recipe command/cwd inject via the E16 `SessionTemplateEngine.launchBytes` path.
- **No app-layer crypto/auth/tokens.** Install-CLI's admin prompt is a system privilege escalation via the existing privilege path (E14 privilege parity), not app crypto. `.slopdeskrecipe`/config/socket input is **untrusted → validate-then-drop**, never force-unwrap, validate counts/lengths before allocating.
- **golden expected ZERO-diff** (`touchesWire:false`). The NDJSON control protocol is **separate from** the golden-frozen binary wire. If any binary wire IS touched (unlikely), hand-edit golden surgically so the **13 frozen keys survive**, and update `docs/20`+`DECISIONS.md`.
- **Hang-safety:** the CLI core is pure/headless — test parser/dispatcher/frecency/exit-codes directly. **NEVER instantiate SCStream/VTCompression/VTDecompression/Metal/a real NSWindow/WKWebView in a test.** First-launch GUI views are compiled-only (Phase-3 HW-verify).
- **iOS:** the `/usr/local/bin` CLI + OS-integration are **macOS-only** (`#if os(macOS)`); iOS keeps the cross-platform first-launch parts (On-Launch, theme, agent-install) that already exist. First-launch settings touch shared `SlopDeskClientUI`/`SlopDeskWorkspaceCore` → **`touchesIOS:true`, run `scripts/check-ios.sh`**.
- **Menu hygiene:** `WorkspaceCommands.swift` carries no `.keyboardShortcut` (check-menu-shortcutless gate).
- **Commit straight to main, NO branch, NO push.** No backcompat/migrations.

## §4 — Exclusions (BINDING / MVP — do NOT build)

- **Non-Claude agents** — `watch:codex`/`watch:opencode`, Codex/OpenCode hook install (`~/.codex/`, `~/.config/opencode/plugins/`). Out of scope (Claude-only binding). Do not scaffold dead branches.
- **"Set as Default Terminal for Common Apps" rewriting REMOTE editor configs** — most editors hardcode Terminal.app; rewriting their config only makes sense for a **LOCAL** editor on the client Mac. A remote-host editor needs a host-side agent and **cannot map 1:1**. MVP: offer it for local editors only; **honestly-disable/defer the remote case with a documented note — do NOT ship a dead button** (E21 "no dead UI", DECISIONS:123).
- **`view`/`edit` as a NATIVE local file renderer** — an slopdesk pane IS a remote PTY; there is no local file renderer. Shim `view`/`edit` by sending `less <path>`/`$EDITOR <path>`/`open <url>` (VERBATIM) to a new split pane on the host — NOT a native renderer. Document the shim.
- **`import`/`export` ghostty/kitty/alacritty CONFIG (non-theme)** and **feature-showcase demo subcommands** — lower priority; design phase MAY defer with a documented note if the WI count is large (theme import already shipped in E15). Do not let them block ES-E20-1…4.
- **SSH-host badge / nested-SSH detection** — out (every slopdesk pane is already remote; a "remote" badge is inverted here — always on). Aligns with the binding **SSH-filter** scope reduction.

## §5 — Definition of done

- **ES-E20-1** `open/view/edit/config/font/theme/keybind/tab/pane/window` drive the running app; `--json` produces structured output (both platforms where applicable).
- **ES-E20-2** `watch <cmd>` spinner + success/error badge on exit; `watch:claude` exit 0/4/9.
- **ES-E20-3** `tab badge --kind`, `pane capture`, `jump/learn/ignore`, `version`, `completions <shell>` per the CLI reference.
- **ES-E20-4** first-run user can set On-Launch, install the CLI, and install Claude Code hooks from a first-launch flow (GUI-verifiable).
- Gate green: `swift build` + `make lint` + `swift test` + `scripts/check-ios.sh` BUILD SUCCEEDED + `scripts/golden-check.sh` PASS (zero-diff, 13 frozen intact).
- Phase-3 HW-fidelity targets: the 6 first-launch screenshots (first-launch window, On-Launch dropdown, OS-integration buttons, theme picker palette + grid, agents behavior list), real `/usr/local/bin/slopdesk` install + admin prompt, real `watch` OSC-9;4 spinner/badge in a live terminal.

## §6 — Design notes

E20 is the **largest CLI surface** of this UI-shell effort — expect many WIs (one per subcommand cluster). CLI parse/dispatch is **pure** → test exhaustively headlessly (each subcommand: parse → dispatch → exit code, revert-to-confirm-fail). **Audit `SlopDeskCtlCore` + `slopdesk-ctl` + `AgentControlListener` FIRST and EXTEND them** — a parallel CLI stack is the rebuild anti-pattern. First-launch is mostly composition of existing settings; the genuinely-new chrome is the guided sheet + the OS-integration/install-CLI buttons. After E20 ships, the UI-shell ladder is **complete** → the autonomous loop advances to the post-epic **audit + dependency-upgrade** directive ([[slopdesk-post-epic-audit-upgrade-directive-2026-06-28]]).
