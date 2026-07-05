# Shell Integration

## Summary

SlopDesk injects small shell hooks that emit OSC 133 (FTCS) prompt marks. These power command outlines, working-directory tracking, and exit-status indicators. The feature is enabled by default and is recommended to keep on. Supported shells are **zsh**, **bash**, and **fish**, auto-detected from `$SHELL`. Other shells work as plain terminals but receive none of the integration features.

## Behaviors

### OSC sequences emitted

| Sequence | When | Why |
|----------|------|-----|
| `OSC 133 ; A` | Right before drawing the prompt | Marks prompt boundaries |
| `OSC 133 ; B` | After the prompt, before input | Distinguishes prompt from typed input |
| `OSC 133 ; C` | When the command starts running | Output begins here |
| `OSC 133 ; D ; <exit>` | When the command finishes | Records exit status |
| `OSC 7 ; file://<host><cwd>` | At every prompt | Tracks pane cwd |

### Features driven by OSC 133 C / D (command status)

- **Outline & command navigation** — per-pane command list and jump-to-prompt capability
- **Exit-status gutter dots** — green/red status marker beside each command
- **Tab badges** — _When Command Finishes_ and _When Command Fails_ dots on tabs
- **Command notifications & sounds** — _Notify on Command Finish_, _Notify on Error Exit_, _Beep on Error Exit_
- **On-device autocomplete learning** — only commands exiting `0` are learned
- **Re-run processes on session restore** — restoring running commands needs the command-start mark

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

- SlopDesk still saves the setting but pops a warning that it won't do anything until shell integration is re-enabled.
- Every affected Settings toggle in the UI is individually flagged when integration is off.

### How integration loads per shell

**zsh:** SlopDesk points `ZDOTDIR` at its bundled `zsh/` directory for the launched session. That `.zshenv` immediately restores the user's real `ZDOTDIR`, runs their own `.zshenv`, then loads SlopDesk's payload on the first prompt (so its marks win over plugin managers). `~/.zshrc` and other dotfiles are **not** edited.

**fish:** SlopDesk prepends its bundled directory to `XDG_DATA_DIRS`, so fish auto-loads the `vendor_conf.d` entry, which then removes that dir again so child processes do not inherit it. `config.fish` is **not** edited.

**bash:** bash has no clean per-spawn auto-load, so SlopDesk adds a small, clearly-marked block to `~/.bashrc` (and a `~/.bash_profile` shim) that sources the bundled payload only when launched by SlopDesk. The block is inert in other terminals and is removed when the toggle is turned off.

**tmux exception:** A tmux server captures its environment once at start, so the `ZDOTDIR` / `XDG_DATA_DIRS` injection cannot reach panes spawned later. When tmux is installed, SlopDesk additionally adds the same guarded managed block to the user's zsh/fish rc so tmux panes still get the integration. Turning the toggle off removes every block.

### Integration scripts are readable and code-signed

Scripts ship as resources installed to a well-known path:
```
~/.slopdesk/shell-integration/
├── slopdesk-integration.zsh
├── slopdesk-integration.bash
├── slopdesk-integration.fish
├── zsh/.zshenv
└── fish/vendor_conf.d/slopdesk-shell-integration.fish
```
Nothing is synthesized at runtime or written to a hidden temp file.

### Opting out — everywhere

Open **Settings → Shell → Shell Integration** and turn off **Provide Shell Integration**. A confirmation dialog (_Turn off shell integration?_) appears. On confirm, SlopDesk removes the bash block and any tmux managed blocks from shell startup files and stops the per-session `ZDOTDIR` / `XDG_DATA_DIRS` injection for zsh and fish. Toggling back on reinstalls everything.

### Opting out — per-shell

Leave integration on globally but skip it for one shell by exporting before SlopDesk's payload loads:
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

No keybindings are defined on this page. (Jump-to-prompt and outline navigation keybindings are documented in the [Outline](/user-interface/outline) section.)

## Config keys

| Key | Default | Effect |
|-----|---------|--------|
| `shell-integration` | `enabled` | Master toggle. Mirrors **Settings → Shell → Shell Integration → Provide Shell Integration**. When `disabled`, removes all injected blocks and stops per-session env injection; prompt marks, command status, CWD tracking, `edit`/`view`/`jump` wrappers, custom aliases, and SSH integration go dark. |
| `SLOPDESK_DISABLE_INTEGRATION` (env var) | unset | Set to `1` in a shell rc (before SlopDesk's payload) to skip integration for that shell instance only, without changing the global setting. |

## Visual spec

This page contains no screenshots. All UI interaction is described textually:

- **Settings → Shell → Shell Integration** — a top-level settings pane containing a **Provide Shell Integration** toggle (boolean, default ON).
- When a dependent setting (e.g. _Notify on Command Finish_) is turned on while the master toggle is off, SlopDesk shows an inline warning within Settings indicating the setting will have no effect until integration is re-enabled.
- When the toggle is turned off, a confirmation dialog titled _Turn off shell integration?_ is presented before changes take effect.
- The **Outline** gutter (a sidebar/panel in the terminal view) only renders when OSC 133 marks arrive; it is the primary visual proof that integration is active.
- **Tab badges** appear as small colored dots on terminal tabs: one variant for "command finished" and one for "command failed" (green/red implied by the exit-status gutter dot language used for the gutter).
- **Exit-status gutter dots** are green (exit 0) or red (non-zero exit), rendered beside each command output block in the terminal gutter.

## Screenshots

No screenshots exist for this page.

## Implementation notes

### Feasible directly

- **OSC 133 A/B/C/D parsing** — libghostty already parses OSC 133 (FTCS) sequences (it's a ghostty feature); slopdesk consumes the parsed mark events from the ghostty surface via the `TerminalSurface` seam to drive these features.
- **OSC 7 CWD tracking** — ghostty parses OSC 7; the cwd can be read from the terminal surface and surfaced as pane metadata. On the macOS client this is used to inherit cwd for new tabs/splits, since the client owns the PTY via the host daemon.
- **Exit-status gutter dots** — rendered in the client UI overlay layer beside command output blocks; driven by the OSC 133 D exit code passed from the host via the terminal mux wire.
- **Tab/pane badges** (command finished, command failed) — slopdesk pane tabs already have a badge layer; wire the OSC 133 D event to set badge state.
- **Autocomplete prompt boundary** — OSC 133 B gives the input start offset; the client-side autocomplete engine can use this for inline ghost text positioning.
- **`SLOPDESK_DISABLE_INTEGRATION` env var and `slopdesk open --no-integration`** — read at session launch via the existing `SLOPDESK_*` env-flag pattern.

### Architecture caveats

- **Shell integration script injection (zsh ZDOTDIR / fish XDG_DATA_DIRS)** — the host daemon (`slopdesk-hostd`) spawns the PTY and controls the launch environment, so it can inject `ZDOTDIR` / `XDG_DATA_DIRS` at PTY-fork time. The integration scripts themselves live on the **host** machine (not the client), so they must be bundled with the host daemon, not the client app. This is a clean architecture fit.
- **bash `~/.bashrc` managed block** — the host daemon must write/remove the block on the host filesystem. This is feasible but requires the host daemon to have write access to `~/.bashrc`. The block must be guarded so it is inert in other terminals.
- **tmux managed block** — same as bash: the host daemon detects `tmux` in `$PATH` on the host and adds the guarded block to the host user's rc files. Feasible.
- **SSH wrapper** — the SSH wrapper runs on the **host** side and re-establishes integration on a further remote machine. This is complex in slopdesk's architecture because the remote machine is already the host; a nested SSH from the host to another machine would need the wrapper to forward slopdesk's own integration environment. **Flag as out-of-scope for v1** — ship without SSH integration forwarding.
- **`edit` / `view` / `jump` / `learn` wrappers** — these are host-side shell functions that call back into the slopdesk client over IPC. The IPC channel exists (`slopdesk-ctl` / AF_UNIX NDJSON). Wire is feasible; function names and behavior need their own spec page.

### Known gaps

- **Bundle scripts** — slopdesk's host daemon is a CLI binary, not a macOS `.app` bundle, so the integration scripts cannot live inside an app bundle's `Contents/Resources/` tree. Instead they are embedded in the host binary as resources or installed to the well-known path documented above (`~/.slopdesk/shell-integration/`) at first launch. The user-auditability story is weakened unless the installed path is documented prominently.
- **iOS client** — iOS has no PTY spawn capability; the PTY always lives on the host. The iOS client consumes terminal output over the wire. OSC 133 marks are parsed by the host's libghostty surface and forwarded as metadata over the wire protocol to the iOS client. The client then renders gutter dots and badges exactly as on macOS. No behavioral difference is expected, but the integration scripts themselves are host-only (not an iOS concern).
- **Settings confirmation dialog ("Turn off shell integration?")** — slopdesk's settings UI is in the macOS client app but the actual effect (removing bashrc blocks) must happen on the host. The client must send a control message to the host daemon to perform the uninstall. This adds an async round-trip that a purely local terminal would not need. Handle with a loading/spinner state in the settings toggle.
- **On-device autocomplete learning** — the host knows the exit code (OSC 133 D) and can maintain a host-side command history database; the client can query it. Alternatively the client can maintain a per-host learned history received over the wire. Flag as a separate design decision.
- **Frequent Folders database (`slopdesk-ctl jump`)** — this is a host-side database of visited CWDs (from OSC 7). Map to a host-side store queried via `slopdesk-ctl jump` or similar. The Open Quickly "Folders" tab on the client must fetch from the host over IPC.
