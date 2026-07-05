# $TERM and Identification

## Summary

How SlopDesk tells programs its terminal type: the `$TERM` value, fixed identification env vars, and escape-sequence replies TUIs probe to unlock features. Principle — conservative accuracy: default to `xterm-256color` (a universally-installed terminfo entry) and advertise extended capabilities (truecolor, Kitty keyboard, etc.) via separate mechanisms rather than by impersonating another terminal.

**TL;DR: do NOT change `$TERM` unless you understand what it is.**

## Behaviors

- Every launched shell gets a `TERM` env var, which selects the terminfo entry and thus the capabilities programs assume are available.
- Default `term = auto` resolves to `xterm-256color` — conservative, present on every Unix terminfo install, covering all a line editor needs (cursor motion, line erase, 256-color).
- Truecolor is advertised separately via `COLORTERM=truecolor`, so staying on `xterm-256color` loses no 24-bit color.
- If `term` is set to any non-`auto` value, SlopDesk verifies a matching terminfo entry exists before applying it; if not, it logs a warning and falls back to `xterm-256color` (a broken TERM mangles line editing over SSH or in `less`).
- **Do NOT** set `term = xterm-kitty`, `xterm-ghostty`, or another terminal's name to inherit its features: `TERM` selects a capability database, not behaviour — claiming to be a terminal you can't fully emulate makes programs emit sequences SlopDesk doesn't handle.
- A fixed set of identification env vars is exported into every child (see table below).
- `TERM_PROGRAM=slopdesk` is the recommended stable SlopDesk-detection probe — survives tmux and any `TERM` value, no escape-reply parsing.
- `CW_TERM=slopdesk` stops Amazon Q / Fig / CodeWhisperer from `exec`-ing `cwterm` mid-`.zshrc` (which would suppress shell-integration marks).
- Device Attributes (DA1/DA2) queries are answered synchronously over the PTY:
  - DA1 (`CSI c` / `CSI 0 c`) → `CSI ? 6 c` ("VT102-class terminal").
  - DA2 (`CSI > c`) → `CSI > 0 ; <version> ; 1 c` (model ID 0, build version, ROM slot 1).
  - DA3 (tertiary) is not implemented — no reply, the correct behavior for an unsupported query.
- DA2 version encoding: `major × 10000 + minor × 100 + patch` (any `-rc`/`-beta` suffix dropped first). E.g. `1.0.2` → `10002`. Matches xterm/Alacritty so their version-gating logic works unchanged.
- XTVERSION: `CSI > q` → `DCS > | slopdesk(<version>) ST`, sent as `ESC P > | slopdesk(<version>) ESC \`. `<version>` is the plain build string (e.g. `slopdesk(1.0.2)`). Terminated with ESC \ (7-bit ST) to survive 8-bit-clean PTYs. Programs recognizing the `slopdesk(` prefix can enable SlopDesk features without guessing from `TERM`.
- Device Status Report (DSR) queries answered immediately:
  - `CSI 5 n` → `CSI 0 n` (ready/OK).
  - `CSI 6 n` → `CSI <row> ; <col> R` (1-based cursor position).
- SlopDesk ships precompiled terminfo entries alongside the host daemon (e.g. `~/.slopdesk/terminfo/`) and prepends this dir to `TERMINFO_DIRS` for every shell, so `xterm-ghostty`, `alacritty`, etc. resolve even if those terminals aren't installed.
- The bundled terminfo path is searched first (wins over an outdated system copy); `/usr/share/terminfo` is appended so nothing else is hidden.
- Over SSH, the SSH wrapper extracts the current terminfo via `infocmp`, pipes it to the remote host, and compiles it there with `tic` into `~/.terminfo`. Cached per `user@host` (first connection only) — this is why `TERM` keeps working on a fresh remote box with no manual terminfo install.

## Keybindings

No keybindings are defined on this page.

| Action | Keys |
|--------|------|
| _(none)_ | _(none)_ |

## Config keys

### `term` config key

| Key | Default | Effect |
|-----|---------|--------|
| `term` | `auto` | `$TERM` exported to every child shell. `auto` → `xterm-256color`. Any other terminfo name is validated before applying, falling back to `xterm-256color` with a warning if not found. Do NOT set to another terminal's name (e.g. `xterm-kitty`, `xterm-ghostty`) to inherit features — programs then emit sequences SlopDesk doesn't handle. |

### Environment variables exported to every child process

| Variable | Value | Purpose |
|----------|-------|---------|
| `TERM` | `xterm-256color` (default, controlled by `term` config key) | terminfo capability database |
| `COLORTERM` | `truecolor` | Advertises 24-bit color. nvim, modern shells, and `ls` light up on this. |
| `TERM_PROGRAM` | `slopdesk` | Canonical "which terminal am I in?" probe. Stable across `TERM` values, survives tmux. |
| `TERM_PROGRAM_VERSION` | build version (e.g. `1.0.2`) | Paired with `TERM_PROGRAM` for version-gating. |
| `CW_TERM` | `slopdesk` | Stops Amazon Q / Fig / CodeWhisperer from `exec`-ing `cwterm` mid-`.zshrc` (suppresses shell-integration marks). |

### Device Attributes reply table

| Query | SlopDesk's Reply | Meaning |
|-------|-------------|---------|
| DA1 — `CSI c` / `CSI 0 c` | `CSI ? 6 c` | "VT102-class terminal." Compact and conservative. |
| DA2 — `CSI > c` | `CSI > 0 ; <version> ; 1 c` | Model ID 0 (generic), build version, ROM slot 1. |
| DA3 (tertiary attributes) | _(no reply)_ | Correct for unsupported query. |

### Device Status Report reply table

| Query | Reply | Meaning |
|-------|-------|---------|
| `CSI 5 n` | `CSI 0 n` | Terminal ready / OK. |
| `CSI 6 n` (cursor position) | `CSI <row> ; <col> R` | 1-based cursor position. |

## Visual spec

No screenshots — pure reference page (prose, tables, code blocks). No UI elements or visual states.

## Screenshots

_(none — this page has no screenshots)_

## Implementation notes

### Feasible directly

- **`$TERM` / `COLORTERM` / `TERM_PROGRAM`**: the libghostty-backed pane already sets `TERM` and `COLORTERM` via the PTY env when launching shells on the macOS host. Add `TERM_PROGRAM=slopdesk` and `TERM_PROGRAM_VERSION=<build>` — a simple PTY env injection at session creation.
- **`CW_TERM`**: same pattern — set `CW_TERM=slopdesk` in the PTY env.
- **`term = auto` config key**: expose an equivalent setting (e.g. `SLOPDESK_TERM` env var or a prefs key) defaulting to `xterm-256color`. Validation (check terminfo exists, warn and fall back) is host-side at PTY fork time.
- **DA1/DA2 replies**: handled by libghostty's VT emulator (slopdesk uses libghostty behind `TerminalSurface`), so DA1/DA2/DA3 already work. DA2 version should reflect the slopdesk build — check whether libghostty exposes a hook to override the DA2 version field or whether it must be intercepted at the PTY stream level.
- **XTVERSION (`CSI > q`)**: libghostty replies with its own build identity (e.g. `ghostty(...)`) unless overridden — verify libghostty's default reply and decide to pass through, rewrite to `slopdesk(...)`, or leave it. Rewriting needs PTY-level escape interception (non-trivial).
- **DSR (`CSI 5 n`, `CSI 6 n`)**: handled by libghostty's emulator; no slopdesk-specific work.

### Known gaps

- **Bundled terminfo path**: the PTY runs on the macOS host, not in an app bundle with bundled terminfo. SlopDesk can inject `TERMINFO_DIRS` to prepend a bundled dir (e.g. `~/.slopdesk/terminfo/`, installed with the host daemon), but this requires shipping the terminfo entries with the daemon. macOS system terminfo is generally complete, so the gap is small — **low priority**.
- **SSH wrapper terminfo forwarding (`infocmp` → remote `tic`)**: SlopDesk reaches a remote macOS host via WireGuard/TCP with the PTY on the remote host directly (not an SSH tunnel). A terminfo-forwarding wrapper applies only when a user SSHes *from inside* a slopdesk pane to a further third machine; there, `TERM_PROGRAM=slopdesk` and `TERM=xterm-256color` forward naturally, but the `tic` step needs a custom SSH wrapper injected into the host PATH. **Optional, low priority** — default `xterm-256color` works everywhere without forwarding.
- **`XTVERSION` reply rewriting**: for programs to recognize slopdesk by the `slopdesk(` prefix, intercept and rewrite the `CSI > q` reply at the PTY stream level. Architecturally non-trivial given the libghostty seam — **deferred**; low impact since most programs fall back to `TERM_PROGRAM` capability negotiation.

### Implementation priority order

1. Set `TERM_PROGRAM=slopdesk`, `TERM_PROGRAM_VERSION=<build>`, `CW_TERM=slopdesk`, `COLORTERM=truecolor` in PTY env at fork — **trivial, high value**.
2. Expose a `term` preference key (default `auto` → `xterm-256color`) with validation — **straightforward**.
3. Verify DA2 version field from libghostty — **investigate only**.
4. SSH wrapper / terminfo forwarding — **deferred**.
5. XTVERSION rewriting — **deferred**.
