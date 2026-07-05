# CLI Reference

## Summary

Complete reference for the `slopdesk` command-line tool. Running `slopdesk` with no subcommand (or starting with `-e`) launches the GUI, so `slopdesk` and `slopdesk -e <cmd>` behave like `xterm` / `alacritty` / `ghostty`. Many subcommands that inspect or drive the UI (`window`, `tab`, `pane`, `view`, `edit`, `jump`, …) require a running SlopDesk app.

Usage syntax:
```
slopdesk <subcommand> [flags] [args]
```

For scenario-oriented examples see "Using the CLI in your Shell".

## Behaviors

- `slopdesk` with no subcommand launches the GUI (equivalent to bare `xterm`/`alacritty`/`ghostty`).
- `slopdesk -e <cmd>` launches the GUI running `<cmd>` (same GUI-launch path as no subcommand).
- Subcommands that inspect or drive the UI (`window`, `tab`, `pane`, `view`, `edit`, `jump`, etc.) require a running SlopDesk app connected via the runtime control socket.
- `--format json` / `--json` switches all list/inspect output to JSON for scripting.
- `--no-headers` strips table header rows from text output (useful for piping).
- `--socket <path>` overrides auto-detected socket; useful for multi-instance or testing.
- `--config-file <path>` overrides the auto-detected config file location.
- `--timeout <ms>` (default 3000 ms) controls how long CLI waits for IPC response from the running app.
- `-y` / `--yes` skips destructive-action confirmation prompts (e.g. `close`, `unset`).
- `slopdesk open [path]` opens a new window, optionally in a directory, with an optional command and title.
- `slopdesk view <target>` opens a file or HTTP(S) URL as a read-only pane; `slopdesk edit <target>` opens it in edit mode.
- Both `view` and `edit` accept placement flags: `--new-tab` (default), `--new-window`, or `--left`/`--right`/`--top`/`--bottom` to split the focused pane.
- `slopdesk config get/set/unset/edit/show/path/validate/reload` manages the config file; `--reload` also pushes changes to the running app; `--transient` applies to the running app only without persisting.
- `slopdesk font list` accepts `--monospace`, `--family <name>` (substring), `--system`/`--user` filters.
- `slopdesk font apply "<name>"` writes `font-family` to the config file.
- `slopdesk font import ./Font.ttf --apply` copies the font into `~/.config/slopdesk/fonts/` and optionally applies it.
- `slopdesk theme list` filters with `--color <dark|light|all>` (default: `all`).
- `slopdesk theme import <path-or-url>` accepts SlopDesk `.toml`, iTerm2 `.itermcolors`, kitty/alacritty/ghostty color files; flags `--activate` and `--overwrite`.
- To switch the active theme without importing, use `slopdesk config set theme <name>`.
- `slopdesk keybind list` lists all keybindings; `--action <substring>` filters by action name.
- Plural forms `slopdesk windows`, `slopdesk tabs`, `slopdesk panes` are shortcuts for `... list`.
- `slopdesk pane send-keys --pane <n> -- "text" key:Enter` sends literal text followed by named keys to a pane.
- `slopdesk pane capture --pane <n> --lines <n>` captures the last N lines of pane output.
- `slopdesk tab badge --kind <kind>` sets a tab status badge. Badge kinds: `running`, `completed`, `finished`, `unread`, `error`, `awaiting-input`.
- `slopdesk watch <cmd>` wraps a command so the tab shows a spinner during execution and a success/error badge on exit (via OSC 9;4), then posts a "Notify on Watch Finish" system notification.
- `-q`/`--quiet` on `slopdesk watch` suppresses the system notification.
- `slopdesk watch:<agent> <id>` blocks until the named code-agent session (`claude`/`codex`/`opencode`) reaches idle state. Exit codes: 0 = idle or session closed, 4 = session ID never seen, 9 = timeout.
- `slopdesk jump [query]` sends `cd <path>` to the focused pane (frecency-ranked). No query toggles between `$HOME` and last jump source. `--no-cd` just prints the resolved path.
- `slopdesk learn [path]` records a directory visit in the frecency database; no path uses the focused pane's cwd. `slopdesk ignore <path>` removes a directory or command from the frecency database.
- `slopdesk import <source>` imports config from ghostty/kitty/alacritty, merges zoxide frecency, or imports a theme. A bare path/URL is auto-detected: font files → font import, theme files → theme import. Flags: `--overwrite`, `--keep`, `--activate`.
- `slopdesk export <target>` exports config to ghostty/kitty/alacritty format; `-o <path>` writes to file instead of stdout.
- `slopdesk features list` / `slopdesk features <name>` renders demos for colors, emoji, OSC sequences, images, and more.
- `slopdesk completions <shell>` prints a completion script. Supported shells: `bash`, `zsh`, `fish`, `elvish`, `powershell`. Settings → Shell → Install CLI installs these automatically.
- `slopdesk version` prints version, build hash, and a brief feature/protocol summary.
- `slopdesk state:<agent> key=value …` reports a code-agent's lifecycle state (invoked by bundled agent hooks/shell integration, not typically by hand).
- `slopdesk ipc <command>` sends a raw control message (invoked by bundled agent hooks/shell integration, not typically by hand).

## Keybindings

This page contains no keybindings — it is a pure CLI reference. See the Keybindings Reference page (`/reference/keybindings`) for the default key map, and `slopdesk keybind list` at runtime.

| Action | Keys |
|--------|------|
| (none on this page) | — |

## Config keys

This page contains no config keys directly — it references the Configuration Reference. Config is managed via `slopdesk config` subcommands. Relevant CLI-adjacent config:

| Key | Default | Effect |
|-----|---------|--------|
| `theme` | (built-in default) | Active color theme name; set via `slopdesk config set theme <name>` |
| `font-family` | (system mono) | Active font family; set via `slopdesk font apply` or `slopdesk config set font-family` |
| `font-size` | (built-in default) | Font size in points; can be set `--transient` (running app only) |

(Full config key list is in the Configuration Reference at `/reference/configuration`.)

## Visual spec

### otty-icon.png — App icon

**256×256 px PNG, RGBA.**

Overall: rounded-rectangle app-icon shape with a very light gray/off-white outer background (approximately #F0F0F0, standard macOS icon shadow well). The icon face is a large near-perfect circle, dark charcoal/dark gray (approximately #3A3A3A–#404040), centered and filling most of the canvas with generous padding (~16 px).

Inside the circle, two glyphs rendered in a light off-white/cream color (approximately #E8E6E0), using a sans-serif weight consistent with a rounded monospace aesthetic:
- Left glyph: `>_` — a shell prompt ligature. The `>` is slightly angled (caret-like), the `_` is a horizontal underscore baseline. Together they form the classic terminal-prompt symbol. Positioned left-of-center, vertically centered slightly above the circle midpoint.
- Right glyph: `*` — an asterisk/star with 6 points, positioned right-of-center at roughly the same vertical height as `>_`. Its style matches the prompt glyph weight (medium-bold stroke).
- A short horizontal dash/line appears below the `>_` prompt at lower-left, suggesting a cursor underline or shell caret extension.

The overall reading is: "terminal + agent" — the `>_` = terminal prompt, `*` = wildcard/agent. No text labels. No gradients; the circle is a flat dark fill. Drop shadow on the outer rounded-rect is subtle (Apple-standard icon shadow).

Typography / weight: glyphs appear hand-drawn or custom, approximately 28–32 pt equivalent at icon size, stroke width ~8–10 px at 256 px resolution.

## Screenshots

- `otty-icon.png` — App icon (256×256), this design's reference icon asset. The CLI reference page has no UI screenshots; it is a pure text/code reference.

## Implementation notes

### What each command is backed by

- **`slopdesk open [path]`** → the GUI launch path (no subcommand / `-e`) maps directly to launching the macOS client app.
- **`slopdesk view` / `slopdesk edit`** → opening a read-only or editable pane. In slopdesk the pane content is always a remote terminal (PTY) or remote file stream; a local file viewer pane would need host-side `cat`/`$EDITOR` forwarding.
- **`slopdesk config get/set/unset/show/reload`** → backed by slopdesk's `EnvConfig` + `PreferencesStore` layer over the control socket (the LIVE running-app store). `--transient` (running app only, no persist) is equivalent to writing to `EnvConfig` without touching `PreferencesStore`.
- **`slopdesk config reload`** → broadcasts a config-change notification via `ConfigStore` / `EnvBridge`.
- **`slopdesk config path/edit/validate`** → **Deliberate design split (M2).** These `config` subcommands do not all act on one `config.toml` uniformly: slopdesk's launch-time bridge (`KeybindConfigLoader`) reads ONLY the `keybind = <chord>:<action>` lines of that file; every other key (font-size, theme, …) is silently ignored there and instead lives in the running-app `PreferencesStore` reached by get/set/show/reload above. So `path`/`edit`/`validate` target the **keybind config file**, and `validate` checks it against the REAL grammar the app honours (`CLIConfig.validate` runs `KeybindGrammar.parseLine` on each line) — a non-`keybind` key like `font-size = 14` is flagged as having no effect rather than reported "valid". The `config` CLI help spells this split out explicitly so it is never silent.
- **`slopdesk font list/apply/import`** → font management is local to the macOS client (libghostty font config).
- **`slopdesk theme list/import`** → backed by `ThemeStore` on the client. Theme files (SlopDesk `.toml`, iTerm2 `.itermcolors`, ghostty format) need an import pipeline feeding into `ThemeStore`.
- **`slopdesk keybind list`** → enumerates `WorkspaceBindingRegistry`. Implementable as a CLI dump.
- **`slopdesk panes --json` / `slopdesk tab new` / `slopdesk pane split`** → backed by the `WorkspaceStore` / `PaneKind` / `reconcile()` API. The IPC socket is analogous to the AF_UNIX NDJSON socket (`SLOPDESK_AGENT_CONTROL=1` / `slopdesk-ctl`). **This is the highest-value item** — `slopdesk pane send-keys` is exactly `slopdesk-ctl send-keys`.
- **`slopdesk pane capture --lines N`** → backed by `ReplayBuffer` read or PTY scrollback capture via the inspector (read-only 2nd TCP path).
- **`slopdesk tab badge --kind <kind>`** → backed by tab badge state in `WorkspaceStore`. Badge kinds (`running`, `completed`, `finished`, `unread`, `error`, `awaiting-input`) map directly to `ClaudeStatus` / agent lifecycle states already tracked.
- **`slopdesk watch <cmd>`** → wraps a command with OSC 9;4 progress reporting. SlopDesk already supports OSC 9;4 (`Progress State`). The `watch` wrapper is a thin shell script / binary that invokes the command and emits OSC 9;4 on exit.
- **`slopdesk watch:<agent> <id>`** → backed by `ClaudePaneDetector` / `AgentControlListener` polling loop. Exit codes (0/4/9) are a clean contract to implement.
- **`slopdesk jump [query]` / `slopdesk learn` / `slopdesk ignore`** → the frecency database is local to the client. `jump` sends `cd <path>` to the focused pane via `send-keys` — in slopdesk this goes through the host PTY. Resolve path client-side (frecency DB), send `cd <resolved>\n` via the terminal mux. `learn` without args reads the **focused pane's cwd** — in slopdesk the cwd is tracked via OSC 7 from the host; the client receives it and can record it.
- **`slopdesk import <source>` / `slopdesk export <target>`** → config import/export. Ghostty config import is the highest-value target since slopdesk uses libghostty and ghostty config format is well-defined.
- **`slopdesk features [name]`** → demo/test sequences. Implementable as a library of OSC/VT sample outputs sent to the focused pane.
- **`slopdesk completions <shell>`** → standard shell completion generation.
- **`slopdesk version`** → trivial. Backed by `Bundle.main.infoDictionary` version + build hash.
- **`slopdesk state:<agent> key=value`** → backed by `AgentControlListener` / the AF_UNIX NDJSON control socket. This is already partially implemented (`SLOPDESK_AGENT_CONTROL=1`).
- **`slopdesk ipc <command>`** → raw NDJSON message to the `slopdesk-ctl` socket.

### Open questions / constraints

- **`slopdesk jump` — cwd resolution from focused pane**: In slopdesk the cwd lives on the **macOS host**, not the client. The client only knows the cwd via OSC 7 emissions from the host shell. `jump` without args must request the current cwd from the host (via the control channel or a cached OSC 7 value), not read it locally. Resolution: cache the last OSC 7 cwd per pane on the client; use that for `learn` and `jump` defaulting.
- **`slopdesk learn` (no args) — focused pane cwd**: Same issue as `jump` above. Must use cached OSC 7 host cwd.
- **`slopdesk view <url>` / `slopdesk edit <file>`**: Opening local files/URLs as pane content natively assumes local files. In slopdesk the "pane" IS the remote PTY; there is no local file renderer. To view a file: the host must run `cat`/`less`/`$EDITOR` on it. URL viewing requires opening a browser or running `w3m`/`curl` on the host. A `view` subcommand can be shimmed by sending `less <path>\n` or `open <url>\n` to a new split pane on the host — but it is not a native renderer.
- **`slopdesk config set font-size 14 --transient`**: The "running app only, no persist" pattern is fully implementable client-side. However, libghostty font reflow requires re-creating the terminal surface or calling `updateConfig` — check whether `TerminalConfigBuilder` supports live font-size changes without reflow.
- **`slopdesk theme import <iTerm2.itermcolors>`**: Requires an iTerm2 color file parser. ghostty and kitty color format parsers are higher priority (ghostty format is already used). iTerm2 format is a plist; implementable but lower priority.
- **`slopdesk tab badge --kind awaiting-input`**: The `awaiting-input` badge requires detecting when the agent process is blocked waiting for user input — this needs either `ClaudePaneDetector` heuristics or an explicit OSC 9;4 state from the agent hook. The detection logic is non-trivial; the badge display itself is easy.
- **Remote SSH badge / multi-host context**: Local terminal apps can trivially detect `ssh` in the process tree and badge the tab. In slopdesk the host IS always remote — every pane is already "SSH". The concept of a "remote" badge is inverted: all panes are remote, so the badge would only be meaningful for panes that are themselves SSH-ing to a third host (nested SSH). Requires host-side process tree inspection.
- **OS Picture-in-Picture / window management**: macOS PiP for terminal windows is a feature seen in some other terminal apps. The slopdesk client is also macOS but PiP for a remote-rendered terminal pane would require the pane to be presented as a standalone AVPlayerLayer or similar — not straightforwardly available through libghostty's `TerminalSurface` seam.
- **`slopdesk completions` — Settings → Shell → Install CLI auto-install**: This requires the macOS client to know the user's shell config directory and write completion files there. Implementable but requires a one-time setup flow in Settings.
