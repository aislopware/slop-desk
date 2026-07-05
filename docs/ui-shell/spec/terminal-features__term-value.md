# $TERM and Identification

## Summary

This page documents how SlopDesk communicates terminal type to the programs running inside it — through the `$TERM` value, a fixed set of identification environment variables, and escape-sequence replies that TUIs probe to unlock features. The guiding principle is conservative accuracy: SlopDesk defaults to `xterm-256color` (universally available terminfo entry) and advertises extended capabilities (truecolor, Kitty keyboard protocol, etc.) through separate mechanisms rather than by claiming to be another terminal. The page opens with a TL;DR warning: **do NOT change `$TERM` unless you understand what it is.**

## Behaviors

- Every shell SlopDesk launches receives a `TERM` environment variable that controls which terminfo entry programs load and therefore which capabilities they believe are available.
- The default `term = auto` resolves to `xterm-256color` — a deliberately conservative choice present on every Unix terminfo install, covering everything line editors need (cursor motion, line erase, 256-color).
- Truecolor is advertised separately through `COLORTERM=truecolor`, so users do not lose 24-bit color by staying on `xterm-256color`.
- If `term` is set to any value other than `auto`, SlopDesk checks that a matching terminfo entry actually exists before applying it. If the entry does not exist, SlopDesk logs a warning and falls back to `xterm-256color` to prevent a broken TERM that mangles line editing over SSH or in `less`.
- **Warning enforced by docs**: Do NOT set `term = xterm-kitty`, `term = xterm-ghostty`, or another terminal's name hoping to inherit its features. `TERM` selects a capability database, not a behaviour — claiming to be a terminal you can't fully emulate makes programs emit sequences SlopDesk doesn't handle.
- SlopDesk exports a fixed set of identification environment variables into every child process (see Config keys / env vars table below).
- `TERM_PROGRAM=slopdesk` is the recommended stable way for scripts and prompts to detect SlopDesk — it survives tmux and different `TERM` values, and doesn't require parsing escape replies.
- `CW_TERM=slopdesk` prevents Amazon Q / Fig / CodeWhisperer from `exec`-ing `cwterm` mid-`.zshrc`, which would suppress shell-integration marks.
- Device Attributes (DA1/DA2) queries are answered synchronously over the PTY.
  - DA1 (`CSI c` / `CSI 0 c`) → `CSI ? 6 c` ("I'm a VT102-class terminal.")
  - DA2 (`CSI > c`) → `CSI > 0 ; <version> ; 1 c` (model ID 0, build version, ROM slot 1).
  - DA3 (tertiary attributes) is not implemented — SlopDesk sends no reply, which is the correct behavior for an unsupported query.
- Version encoding for DA2: `major × 10000 + minor × 100 + patch` (any `-rc`/`-beta` suffix is dropped first). Example: version `1.0.2` encodes as `10002`. Matches xterm and Alacritty encoding so version-gating logic written for them works unchanged.
- XTVERSION: SlopDesk responds to `CSI > q` with `DCS > | slopdesk(<version>) ST`, transmitted as `ESC P > | slopdesk(<version>) ESC \`. The `<version>` is the plain build version string (e.g. `slopdesk(1.0.2)`). Reply is terminated with ESC \ (7-bit ST) so it survives 8-bit-clean PTYs. Programs that recognize the `slopdesk(` prefix can enable SlopDesk-supported features without guessing from `TERM`.
- Device Status Report (DSR) queries are answered immediately:
  - `CSI 5 n` → `CSI 0 n` (terminal ready/OK)
  - `CSI 6 n` → `CSI <row> ; <col> R` (1-based cursor position)
- SlopDesk ships precompiled terminfo entries alongside the host daemon (e.g. `~/.slopdesk/terminfo/`) and prepends this directory to the front of `TERMINFO_DIRS` for every shell. This lets `xterm-ghostty`, `alacritty`, and similar entries resolve even if those terminals are not installed on the system.
- The bundled terminfo path is searched first (wins over an outdated system copy), and `/usr/share/terminfo` is appended so nothing else is hidden.
- Over SSH, the SSH wrapper extracts the current terminfo with `infocmp`, pipes it to the remote host, and compiles it there with `tic` into `~/.terminfo`. Results are cached per `user@host` so this only happens on the first connection — this is why `TERM` keeps working on a fresh remote box that has never heard of it, with no manual terminfo install required.

## Keybindings

No keybindings are defined on this page.

| Action | Keys |
|--------|------|
| _(none)_ | _(none)_ |

## Config keys

### `term` config key

| Key | Default | Effect |
|-----|---------|--------|
| `term` | `auto` | Controls the `$TERM` value exported to every child shell. `auto` resolves to `xterm-256color`. Can be set to any other terminfo name; SlopDesk validates the entry exists before applying it, falling back to `xterm-256color` with a warning if not found. Do NOT set to another terminal's name (e.g. `xterm-kitty`, `xterm-ghostty`) to try to inherit features — this causes programs to emit sequences SlopDesk doesn't handle. |

### Environment variables exported to every child process

| Variable | Value | Purpose |
|----------|-------|---------|
| `TERM` | `xterm-256color` (default, controlled by `term` config key) | terminfo capability database |
| `COLORTERM` | `truecolor` | Advertises 24-bit color support. nvim, modern shells, and `ls` light up on this. |
| `TERM_PROGRAM` | `slopdesk` | The canonical "which terminal am I in?" probe. Stable across `TERM` value choices, survives tmux. |
| `TERM_PROGRAM_VERSION` | build version (e.g. `1.0.2`) | Paired with `TERM_PROGRAM` for version-gating capability. |
| `CW_TERM` | `slopdesk` | Stops Amazon Q / Fig / CodeWhisperer from `exec`-ing `cwterm` mid-`.zshrc` (which would suppress shell-integration marks). |

### Device Attributes reply table

| Query | SlopDesk's Reply | Meaning |
|-------|-------------|---------|
| DA1 — `CSI c` / `CSI 0 c` | `CSI ? 6 c` | "I'm a VT102-class terminal." Compact and conservative. |
| DA2 — `CSI > c` | `CSI > 0 ; <version> ; 1 c` | Model ID 0 (generic), build version, ROM slot 1. |
| DA3 (tertiary attributes) | _(no reply)_ | Correct behavior for unsupported query. |

### Device Status Report reply table

| Query | Reply | Meaning |
|-------|-------|---------|
| `CSI 5 n` | `CSI 0 n` | Terminal is ready / OK. |
| `CSI 6 n` (cursor position) | `CSI <row> ; <col> R` | 1-based cursor position. |

## Visual spec

This page contains no screenshots. It is a pure reference/documentation page with prose, tables, and code blocks. No UI elements or visual states are depicted.

## Screenshots

_(none — this page has no screenshots)_

## Implementation notes

### Feasible directly

- **`$TERM` / `COLORTERM` / `TERM_PROGRAM`**: SlopDesk's libghostty-backed terminal pane already sets `TERM` and `COLORTERM` via the PTY environment when launching shells on the macOS host. The `TERM_PROGRAM` and `TERM_PROGRAM_VERSION` variables should be set to `slopdesk` and the current build version respectively — this is a simple PTY env injection at session creation.
- **`CW_TERM`**: Same injection pattern — set `CW_TERM=slopdesk` in the PTY env to suppress Amazon Q / CodeWhisperer mid-shell `exec` behavior.
- **`term = auto` config key**: SlopDesk should expose an equivalent setting (e.g. `SLOPDESK_TERM` env var or a preferences key) that defaults to `xterm-256color`. Validation (check terminfo exists before applying, warn and fall back) is a host-side behavior at PTY fork time.
- **DA1/DA2 replies**: These are answered by libghostty's VT emulator layer. Since slopdesk uses libghostty behind `TerminalSurface`, the DA1/DA2/DA3 replies are already handled by the underlying ghostty emulator. The version number in DA2 should ideally reflect the slopdesk build version — check whether libghostty exposes a hook to override the DA2 version field or whether it must be intercepted at the PTY stream level.
- **XTVERSION (`CSI > q`)**: libghostty replies with its own default build identity (e.g. `ghostty(...)`) unless the embedding app overrides it — slopdesk should verify what reply libghostty emits by default and decide whether to pass it through, rewrite it to `slopdesk(...)`, or leave it. Rewriting would require PTY-level escape sequence interception, which is non-trivial.
- **DSR (`CSI 5 n`, `CSI 6 n`)**: Handled by libghostty's emulator; no slopdesk-specific work needed.

### Known gaps

- **Bundled terminfo path**: SlopDesk hosts the PTY on the macOS host machine, not inside an app bundle with bundled terminfo. SlopDesk can inject `TERMINFO_DIRS` to prepend a bundled terminfo directory (e.g. `~/.slopdesk/terminfo/`, installed alongside the host daemon), but this requires shipping the relevant terminfo entries with the host daemon. On macOS the system terminfo is generally complete, so the practical gap is small. Flag as **low priority**.
- **SSH wrapper terminfo forwarding (`infocmp` → remote `tic`)**: SlopDesk's connection model is a remote macOS host reached via WireGuard/TCP, with the PTY running on the remote host directly (not through an SSH tunnel managed by the client). A terminfo-forwarding wrapper would apply only when users SSH *from inside* an slopdesk pane to a further third machine. In that case, `TERM_PROGRAM=slopdesk` and `TERM=xterm-256color` will be forwarded naturally by SSH; the `tic` compilation step would require a custom SSH wrapper injected into the PATH on the host. This is **optional and low priority** — the default `xterm-256color` TERM works everywhere without any terminfo forwarding.
- **`XTVERSION` reply rewriting**: If slopdesk wants programs to recognize it by name (via the `slopdesk(` prefix in XTVERSION), it needs to intercept and rewrite the `CSI > q` reply at the PTY stream level. This is architecturally non-trivial given the libghostty seam and should be **deferred** — the practical impact is low since most programs fall back to capability negotiation via `TERM_PROGRAM`.

### Implementation priority order

1. Set `TERM_PROGRAM=slopdesk`, `TERM_PROGRAM_VERSION=<build>`, `CW_TERM=slopdesk`, `COLORTERM=truecolor` in PTY env at fork — **trivial, high value**.
2. Expose a `term` preference key (default `auto` → `xterm-256color`) with validation — **straightforward**.
3. Verify DA2 version field from libghostty — **investigate only**.
4. SSH wrapper / terminfo forwarding — **deferred**.
5. XTVERSION rewriting — **deferred**.
