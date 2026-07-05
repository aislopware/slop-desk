# CLI Reference

## Summary

Reference for the `slopdesk` command-line tool. Bare `slopdesk` (or `slopdesk -e <cmd>`) launches the GUI, like `xterm`/`alacritty`/`ghostty`. UI-driving subcommands (`window`, `tab`, `pane`, `view`, `edit`, `jump`, …) require a running SlopDesk app.

Usage: `slopdesk <subcommand> [flags] [args]`

For scenario examples see "Using the CLI in your Shell".

## Behaviors

- Bare `slopdesk` launches the GUI (like bare `xterm`/`alacritty`/`ghostty`); `slopdesk -e <cmd>` launches it running `<cmd>` (same launch path).
- UI-inspect/drive subcommands (`window`, `tab`, `pane`, `view`, `edit`, `jump`, etc.) require a running app connected via the runtime control socket.
- Global flags: `--format json`/`--json` (JSON output for scripting); `--no-headers` (strip table headers, for piping); `--socket <path>` (override auto-detected socket; multi-instance/testing); `--config-file <path>` (override config file location); `--timeout <ms>` (default 3000; IPC response wait); `-y`/`--yes` (skip destructive confirmations, e.g. `close`, `unset`).
- `slopdesk open [path]` — new window, optional directory, command, title.
- `slopdesk view <target>` opens a file or HTTP(S) URL read-only; `slopdesk edit <target>` opens it editable. Both accept placement: `--new-tab` (default), `--new-window`, or `--left`/`--right`/`--top`/`--bottom` to split the focused pane.
- `slopdesk config get/set/unset/edit/show/path/validate/reload` manages the config file; `--reload` pushes changes to the running app; `--transient` applies to the running app only, no persist.
- `slopdesk font list` filters: `--monospace`, `--family <name>` (substring), `--system`/`--user`. `slopdesk font apply "<name>"` writes `font-family` to config. `slopdesk font import ./Font.ttf --apply` copies into `~/.config/slopdesk/fonts/` and optionally applies.
- `slopdesk theme list` filters `--color <dark|light|all>` (default `all`). `slopdesk theme import <path-or-url>` accepts SlopDesk `.toml`, iTerm2 `.itermcolors`, kitty/alacritty/ghostty color files; flags `--activate`, `--overwrite`. To switch active theme without importing: `slopdesk config set theme <name>`.
- `slopdesk keybind list` lists all keybindings; `--action <substring>` filters by action.
- Plurals `slopdesk windows`/`tabs`/`panes` are shortcuts for `... list`.
- `slopdesk pane send-keys --pane <n> -- "text" key:Enter` sends literal text then named keys to a pane. `slopdesk pane capture --pane <n> --lines <n>` captures the last N lines.
- `slopdesk tab badge --kind <kind>` sets a tab status badge. Kinds: `running`, `completed`, `finished`, `unread`, `error`, `awaiting-input`.
- `slopdesk watch <cmd>` wraps a command so the tab shows a spinner during execution and a success/error badge on exit (via OSC 9;4), then posts a "Notify on Watch Finish" notification. `-q`/`--quiet` suppresses the notification.
- `slopdesk watch:<agent> <id>` blocks until the named code-agent session (`claude`/`codex`/`opencode`) reaches idle. Exit codes: 0 = idle or session closed, 4 = session ID never seen, 9 = timeout.
- `slopdesk jump [query]` sends `cd <path>` to the focused pane (frecency-ranked). No query toggles between `$HOME` and last jump source. `--no-cd` just prints the resolved path.
- `slopdesk learn [path]` records a directory visit in the frecency DB; no path uses the focused pane's cwd. `slopdesk ignore <path>` removes a directory or command from the frecency DB.
- `slopdesk import <source>` imports config from ghostty/kitty/alacritty, merges zoxide frecency, or imports a theme. Bare path/URL auto-detected: font files → font import, theme files → theme import. Flags: `--overwrite`, `--keep`, `--activate`.
- `slopdesk export <target>` exports config to ghostty/kitty/alacritty format; `-o <path>` writes to file instead of stdout.
- `slopdesk features list` / `slopdesk features <name>` renders demos for colors, emoji, OSC sequences, images, and more.
- `slopdesk completions <shell>` prints a completion script. Shells: `bash`, `zsh`, `fish`, `elvish`, `powershell`. Settings → Shell → Install CLI installs these automatically.
- `slopdesk version` prints version, build hash, and a brief feature/protocol summary.
- `slopdesk state:<agent> key=value …` reports a code-agent's lifecycle state; `slopdesk ipc <command>` sends a raw control message. Both invoked by bundled agent hooks/shell integration, not typically by hand.

## Keybindings

No keybindings — pure CLI reference. See the Keybindings Reference (`/reference/keybindings`) for the default key map, and `slopdesk keybind list` at runtime.

| Action | Keys |
|--------|------|
| (none on this page) | — |

## Config keys

No config keys directly — see the Configuration Reference. Config is managed via `slopdesk config` subcommands. CLI-adjacent config:

| Key | Default | Effect |
|-----|---------|--------|
| `theme` | (built-in default) | Active color theme name; set via `slopdesk config set theme <name>` |
| `font-family` | (system mono) | Active font family; set via `slopdesk font apply` or `slopdesk config set font-family` |
| `font-size` | (built-in default) | Font size in points; can be set `--transient` (running app only) |

(Full config key list: Configuration Reference at `/reference/configuration`.)

## Visual spec

### otty-icon.png — App icon

**256×256 px PNG, RGBA.**

Rounded-rectangle app-icon shape; very light gray/off-white outer background (~#F0F0F0, standard macOS icon shadow well). The face is a large near-perfect circle, dark charcoal (~#3A3A3A–#404040), centered, filling most of the canvas with ~16 px padding.

Inside the circle, two glyphs in light off-white/cream (~#E8E6E0), sans-serif weight matching a rounded monospace aesthetic:
- Left glyph: `>_` — a shell-prompt ligature. `>` slightly angled (caret-like), `_` a horizontal underscore baseline. Positioned left-of-center, vertically centered slightly above the circle midpoint.
- Right glyph: `*` — a 6-point asterisk/star, right-of-center at roughly the same height as `>_`, medium-bold stroke matching the prompt glyph.
- A short horizontal dash below the `>_` at lower-left, suggesting a cursor underline / shell caret extension.

Reading: "terminal + agent" — `>_` = terminal prompt, `*` = wildcard/agent. No text labels, no gradients (flat dark circle fill). Subtle Apple-standard drop shadow on the outer rounded-rect.

Typography: glyphs hand-drawn/custom, ~28–32 pt equivalent at icon size, stroke width ~8–10 px at 256 px.

## Screenshots

- `otty-icon.png` — App icon (256×256), this design's reference icon asset. The CLI reference page has no UI screenshots; it is a pure text/code reference.

## Implementation notes

### What each command is backed by

- **`slopdesk open [path]`** → the GUI launch path (no subcommand / `-e`) maps directly to launching the macOS client app.
- **`slopdesk view` / `slopdesk edit`** → open a read-only or editable pane. In slopdesk the pane is always a remote terminal (PTY) or remote file stream; a local file viewer pane would need host-side `cat`/`$EDITOR` forwarding.
- **`slopdesk config get/set/unset/show/reload`** → slopdesk's `EnvConfig` + `PreferencesStore` over the control socket (the LIVE running-app store). `--transient` = writing `EnvConfig` without touching `PreferencesStore`.
- **`slopdesk config reload`** → broadcasts a config-change notification via `ConfigStore` / `EnvBridge`.
- **`slopdesk config path/edit/validate`** → **Deliberate design split (M2).** These do not act on one `config.toml` uniformly: the launch-time bridge (`KeybindConfigLoader`) reads ONLY `keybind = <chord>:<action>` lines; every other key (font-size, theme, …) is silently ignored there and lives in the running-app `PreferencesStore` reached by get/set/show/reload. So `path`/`edit`/`validate` target the **keybind config file**, and `validate` checks it against the REAL grammar the app honours (`CLIConfig.validate` runs `KeybindGrammar.parseLine` per line) — a non-`keybind` key like `font-size = 14` is flagged as having no effect, not "valid". The `config` CLI help spells this split out explicitly so it is never silent.
- **`slopdesk font list/apply/import`** → font management local to the macOS client (libghostty font config).
- **`slopdesk theme list/import`** → `ThemeStore` on the client. Theme files (SlopDesk `.toml`, iTerm2 `.itermcolors`, ghostty format) need an import pipeline feeding `ThemeStore`.
- **`slopdesk keybind list`** → enumerates `WorkspaceBindingRegistry`. Implementable as a CLI dump.
- **`slopdesk panes --json` / `slopdesk tab new` / `slopdesk pane split`** → the `WorkspaceStore` / `PaneKind` / `reconcile()` API. IPC socket is analogous to the AF_UNIX NDJSON socket (`SLOPDESK_AGENT_CONTROL=1` / `slopdesk-ctl`). **Highest-value item** — `slopdesk pane send-keys` is exactly `slopdesk-ctl send-keys`.
- **`slopdesk pane capture --lines N`** → `ReplayBuffer` read or PTY scrollback capture via the inspector (read-only 2nd TCP path).
- **`slopdesk tab badge --kind <kind>`** → tab badge state in `WorkspaceStore`. Kinds (`running`, `completed`, `finished`, `unread`, `error`, `awaiting-input`) map directly to `ClaudeStatus` / agent lifecycle states already tracked.
- **`slopdesk watch <cmd>`** → wraps a command with OSC 9;4 progress reporting. SlopDesk already supports OSC 9;4 (`Progress State`); the wrapper is a thin script/binary that invokes the command and emits OSC 9;4 on exit.
- **`slopdesk watch:<agent> <id>`** → `ClaudePaneDetector` / `AgentControlListener` polling loop. Exit codes (0/4/9) are a clean contract.
- **`slopdesk jump [query]` / `slopdesk learn` / `slopdesk ignore`** → frecency DB local to the client. `jump` sends `cd <path>` to the focused pane via `send-keys` (through the host PTY): resolve path client-side, send `cd <resolved>\n` via the terminal mux. `learn` without args reads the focused pane's cwd — tracked via OSC 7 from the host, received and recorded by the client.
- **`slopdesk import <source>` / `slopdesk export <target>`** → config import/export. Ghostty config import is highest-value since slopdesk uses libghostty and the format is well-defined.
- **`slopdesk features [name]`** → demo/test sequences; a library of OSC/VT sample outputs sent to the focused pane.
- **`slopdesk completions <shell>`** → standard shell completion generation.
- **`slopdesk version`** → trivial; `Bundle.main.infoDictionary` version + build hash.
- **`slopdesk state:<agent> key=value`** → `AgentControlListener` / the AF_UNIX NDJSON control socket. Partially implemented (`SLOPDESK_AGENT_CONTROL=1`).
- **`slopdesk ipc <command>`** → raw NDJSON message to the `slopdesk-ctl` socket.

### Open questions / constraints

- **`slopdesk jump` — cwd resolution from focused pane**: the cwd lives on the macOS host, not the client; the client only knows it via OSC 7 emissions from the host shell. `jump` without args must request the current cwd from the host (control channel or cached OSC 7), not read it locally. Resolution: cache the last OSC 7 cwd per pane on the client; use it for `learn` and `jump` defaulting.
- **`slopdesk learn` (no args) — focused pane cwd**: same issue as `jump`; use cached OSC 7 host cwd.
- **`slopdesk view <url>` / `slopdesk edit <file>`**: native local-file/URL pane content assumes local files, but the "pane" IS the remote PTY — no local file renderer. To view a file the host must run `cat`/`less`/`$EDITOR`; URL viewing needs a browser or `w3m`/`curl` on the host. Can be shimmed by sending `less <path>\n` or `open <url>\n` to a new split pane on the host — not a native renderer.
- **`slopdesk config set font-size 14 --transient`**: "running app only, no persist" is fully client-side implementable. But libghostty font reflow needs re-creating the terminal surface or calling `updateConfig` — check whether `TerminalConfigBuilder` supports live font-size changes without reflow.
- **`slopdesk theme import <iTerm2.itermcolors>`**: needs an iTerm2 color-file (plist) parser. ghostty/kitty parsers are higher priority (ghostty format already used); iTerm2 implementable but lower priority.
- **`slopdesk tab badge --kind awaiting-input`**: requires detecting when the agent process is blocked on user input — needs `ClaudePaneDetector` heuristics or an explicit OSC 9;4 state from the agent hook. Detection is non-trivial; the badge display itself is easy.
- **Remote SSH badge / multi-host context**: local apps trivially detect `ssh` in the process tree and badge the tab. In slopdesk the host IS always remote — every pane is already "SSH", so the concept inverts: a badge would only be meaningful for panes SSH-ing to a third host (nested SSH). Requires host-side process-tree inspection.
- **OS Picture-in-Picture / window management**: macOS PiP for a remote-rendered terminal pane would require presenting the pane as a standalone AVPlayerLayer or similar — not straightforwardly available through libghostty's `TerminalSurface` seam.
- **`slopdesk completions` — Settings → Shell → Install CLI auto-install**: requires the client to know the user's shell config directory and write completion files there. Implementable but needs a one-time setup flow in Settings.
