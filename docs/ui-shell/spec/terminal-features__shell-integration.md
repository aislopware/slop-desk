# Shell Integration

## Summary

SlopDesk injects small shell hooks that emit OSC 133 (FTCS) prompt marks, powering command outlines, working-directory tracking, and exit-status indicators. Enabled by default; recommended to keep on. Shells **zsh**, **bash**, **fish** are auto-detected from `$SHELL`; others work as plain terminals with no integration.

## Behaviors

### OSC sequences emitted

| Sequence | When | Why |
|----------|------|-----|
| `OSC 133 ; A` | Right before drawing the prompt | Marks prompt boundaries |
| `OSC 133 ; B` | After the prompt, before input | Distinguishes prompt from typed input |
| `OSC 133 ; C` | When the command starts running | Output begins here |
| `OSC 133 ; D ; <exit>` | When the command finishes | Records exit status |
| `OSC 7 ; file://<host><cwd>` | At every prompt | Tracks pane cwd |
| `CSI 5 SP q` (DECSCUSR 5) | Right before drawing the prompt | Bar caret while the shell is idle at its prompt (ghostty/kitty "cursor" feature) |
| `CSI 0 SP q` (DECSCUSR 0) | When the command starts running | Restores the configured default caret (block) while a command runs |

### Features driven by OSC 133 C / D (command status)

- **Outline & command navigation** — per-pane command list and jump-to-prompt
- **Exit-status gutter dots** — green/red status marker beside each command
- **Tab badges** — _When Command Finishes_ and _When Command Fails_ dots on tabs
- **Command notifications & sounds** — _Notify on Command Finish_, _Notify on Error Exit_, _Beep on Error Exit_
- **On-device autocomplete learning** — only commands exiting `0` are learned
- **Re-run processes on session restore** — needs the command-start mark

### Features driven by OSC 7 (working directory)

- **Inherit working directory** for new tabs, splits, and windows
- **Auto-record visited folders** — database for Frequent Folders (`slopdesk-ctl jump` and Open Quickly's Folders tab)

### Features driven by OSC 133 B (prompt boundary)

- **Autocomplete** — inline ghost text and candidate panel locate prompt from input mark; without it, falls back to ~1s timer with reduced accuracy

### Injected wrappers (loaded by the integration scripts)

- `edit` / `view` / `jump` / `learn` shell functions (via an _Omit app-name prefix_ option) and custom aliases
- **SSH integration** — `ssh` wrapper that forwards environment, installs terminfo, enables remote file/git access

### Features that work WITHOUT shell integration

- Terminal bell
- App notifications (OSC 9 / 777)
- Code-agent badges (delivered over IPC)

### Turning off a dependent feature when integration is disabled

- SlopDesk still saves the setting but warns it won't do anything until integration is re-enabled.
- Every affected Settings toggle is individually flagged when integration is off.

### How integration loads per shell

**zsh:** SlopDesk points `ZDOTDIR` at its bundled `zsh/` directory for the launched session. That `.zshenv` immediately restores the user's real `ZDOTDIR`, runs their `.zshenv`, then loads SlopDesk's payload on the first prompt (so its marks win over plugin managers). `~/.zshrc` and other dotfiles are **not** edited.

**fish:** SlopDesk prepends its bundled directory to `XDG_DATA_DIRS`, so fish auto-loads the `vendor_conf.d` entry, which then removes that dir so child processes don't inherit it. `config.fish` is **not** edited.

**bash:** No clean per-spawn auto-load, so SlopDesk adds a small, clearly-marked block to `~/.bashrc` (and a `~/.bash_profile` shim) that sources the bundled payload only when launched by SlopDesk. The block is inert in other terminals and is removed when the toggle is turned off.

**tmux exception:** A tmux server captures its environment once at start, so the `ZDOTDIR` / `XDG_DATA_DIRS` injection can't reach later-spawned panes. When tmux is installed, SlopDesk adds the same guarded managed block to the user's zsh/fish rc so tmux panes still get integration. Turning the toggle off removes every block.

### Integration scripts are readable and code-signed

Scripts ship as resources installed to a well-known path; nothing is synthesized at runtime or written to a hidden temp file:
```
~/.slopdesk/shell-integration/
├── slopdesk-integration.zsh
├── slopdesk-integration.bash
├── slopdesk-integration.fish
├── zsh/.zshenv
└── fish/vendor_conf.d/slopdesk-shell-integration.fish
```

### Opting out — everywhere

**Settings → Shell → Shell Integration**, turn off **Provide Shell Integration**. A confirmation dialog (_Turn off shell integration?_) appears. On confirm, SlopDesk removes the bash block and any tmux managed blocks from startup files and stops the per-session `ZDOTDIR` / `XDG_DATA_DIRS` injection for zsh and fish. Toggling back on reinstalls everything.

### Opting out — per-shell

Leave integration on globally but skip one shell by exporting before SlopDesk's payload loads:
```bash
export SLOPDESK_DISABLE_INTEGRATION=1
```

### Opting out — per-window

```bash
slopdesk open --no-integration
```

### Verifying integration is active

```bash
echo "marks: $SLOPDESK_INTEGRATION"
# marks: 1
```
Or observe the Outline gutter — it only renders when marks arrive.

## Keybindings

None on this page. (Jump-to-prompt and outline navigation keybindings are in the [Outline](/user-interface/outline) section.)

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `shell-integration` | `enabled` | Master toggle. Mirrors **Settings → Shell → Shell Integration → Provide Shell Integration**. When `disabled`, removes all injected blocks and stops per-session env injection; prompt marks, command status, CWD tracking, `edit`/`view`/`jump` wrappers, custom aliases, and SSH integration go dark. |
| `SLOPDESK_DISABLE_INTEGRATION` (env var) | unset | Set to `1` in a shell rc (before SlopDesk's payload) to skip integration for that shell instance only, without changing the global setting. |
| `SLOPDESK_SHELL_CURSOR` (env var) | unset (feature ON) | Set to `0`/`false`/`no`/`off` to disable just the prompt cursor-shape feature (bar at prompt, block while a command runs) while keeping the OSC 133 marks. Evaluated in the child shell; forwarded across the curated env allowlist like `SLOPDESK_OSC133`. |

## Visual spec

No screenshots. UI described textually:

- **Settings → Shell → Shell Integration** — top-level settings pane with a **Provide Shell Integration** toggle (boolean, default ON).
- When a dependent setting (e.g. _Notify on Command Finish_) is turned on while the master toggle is off, an inline warning within Settings indicates it has no effect until integration is re-enabled.
- Turning the toggle off presents a confirmation dialog titled _Turn off shell integration?_ before changes take effect.
- The **Outline** gutter (sidebar/panel in the terminal view) renders only when OSC 133 marks arrive; primary visual proof integration is active.
- **Tab badges** — small colored dots on terminal tabs: one variant "command finished", one "command failed" (green/red, matching the gutter dot language).
- **Exit-status gutter dots** — green (exit 0) or red (non-zero exit), beside each command output block in the terminal gutter.

## Screenshots

None for this page.

## Implementation notes

### Feasible directly

- **OSC 133 A/B/C/D parsing** — libghostty already parses OSC 133 (FTCS); slopdesk consumes the parsed mark events from the ghostty surface via the `TerminalSurface` seam.
- **OSC 7 CWD tracking** — ghostty parses OSC 7; cwd is read from the terminal surface as pane metadata. On the macOS client this inherits cwd for new tabs/splits, since the client owns the PTY via the host daemon.
- **Exit-status gutter dots** — rendered in the client UI overlay layer beside command output blocks; driven by the OSC 133 D exit code passed from the host over the terminal mux wire.
- **Tab/pane badges** (command finished, command failed) — pane tabs already have a badge layer; wire the OSC 133 D event to set badge state.
- **Autocomplete prompt boundary** — OSC 133 B gives the input start offset for inline ghost text positioning.
- **`SLOPDESK_DISABLE_INTEGRATION` env var and `slopdesk open --no-integration`** — read at session launch via the existing `SLOPDESK_*` env-flag pattern.

### Architecture caveats

- **Shell integration script injection (zsh ZDOTDIR / fish XDG_DATA_DIRS)** — the host daemon (`slopdesk-hostd`) spawns the PTY and controls the launch environment, so it injects `ZDOTDIR` / `XDG_DATA_DIRS` at PTY-fork time. Scripts live on the **host** (not the client), so they must be bundled with the host daemon. Clean architecture fit.
- **bash `~/.bashrc` managed block** — the host daemon writes/removes the block on the host filesystem; requires write access to `~/.bashrc`. Block must be guarded so it's inert in other terminals.
- **tmux managed block** — same as bash: the host daemon detects `tmux` in `$PATH` on the host and adds the guarded block to the host user's rc files. Feasible.
- **SSH wrapper** — runs on the **host** side and re-establishes integration on a further remote machine. Complex in slopdesk's architecture because the remote machine is already the host; a nested SSH from host to another machine would need the wrapper to forward slopdesk's own integration environment. **Out-of-scope for v1** — ship without SSH integration forwarding.
- **`edit` / `view` / `jump` / `learn` wrappers** — host-side shell functions that call back into the slopdesk client over IPC. The IPC channel exists (`slopdesk-ctl` / AF_UNIX NDJSON). Feasible; function names and behavior need their own spec page.

### Known gaps

- **Bundle scripts** — the host daemon is a CLI binary, not a macOS `.app` bundle, so scripts can't live in `Contents/Resources/`. Instead they're embedded in the host binary as resources or installed to the well-known path (`~/.slopdesk/shell-integration/`) at first launch. Auditability is weakened unless the installed path is documented prominently.
- **iOS client** — iOS has no PTY spawn; the PTY always lives on the host, and the client consumes output over the wire. OSC 133 marks are parsed by the host's libghostty surface and forwarded as metadata over the wire protocol; the client renders gutter dots and badges exactly as on macOS. No behavioral difference; scripts are host-only (not an iOS concern).
- **Settings confirmation dialog ("Turn off shell integration?")** — settings UI is in the macOS client, but the effect (removing bashrc blocks) happens on the host, so the client sends a control message to the host daemon to uninstall. This async round-trip that a local terminal wouldn't need is handled with a loading/spinner state in the settings toggle.
- **On-device autocomplete learning** — the host knows the exit code (OSC 133 D) and can maintain a host-side command-history database the client queries; alternatively the client keeps a per-host learned history received over the wire. Separate design decision.
- **Frequent Folders database (`slopdesk-ctl jump`)** — a host-side database of visited CWDs (from OSC 7), mapped to a host-side store queried via `slopdesk-ctl jump` or similar. The Open Quickly "Folders" tab fetches from the host over IPC.
