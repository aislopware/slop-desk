# Aislopdesk

**Aislopdesk** is a terminal-first, low-latency remote-coding tool for Apple platforms — a
macOS **host** paired with macOS / iOS **clients**. The everyday use case is running a
shell and **Claude Code** on a remote machine and driving it from another device with
native, feels-local responsiveness. Aislopdesk is **native Swift end to end** and runs over a
[NetBird](https://netbird.io) (WireGuard) mesh, assuming direct peer-to-peer connectivity.
Because WireGuard already provides end-to-end encryption and NetBird ACLs gate membership,
Aislopdesk adds **no app-layer encryption or auth** — the security boundary is the mesh. The
client terminal renderer is **libghostty exclusively** — there is **no SwiftTerm fallback**
and no second rendering path (a deliberate "build the best thing, keep no plan B" commitment).

## Architecture — three data paths

```
┌──────────── HOST (macOS, non-sandboxed) ────────────┐
│  ① TERMINAL PATH (primary)                          │
│     openpty + posix_spawn → shell / claude (PTY)    │
│        │ raw VT byte stream                         │
│  ③ INSPECTOR (read-only companion)                  │
│     tail JSONL transcript + hooks → typed events    │
│  ② GUI VIDEO PATH (Phase 4)                         │
│     ScreenCaptureKit → VideoToolbox HEVC 4:2:0      │
└──────│───────────────│──────────────────│───────────┘
       │ TCP           │ NWConnection #2   │ UDP   (all over NetBird WireGuard P2P)
┌──────▼───────────────▼──────────────────▼───────────┐
│  CLIENT (macOS / iOS / iPadOS)                       │
│  ① libghostty surface (full TUI render) + keys       │
│  ③ SwiftUI read-only views (tool cards / subagents / │
│     todos / CoT-placeholder)                         │
│  ② VTDecompression → Metal (GUI window video)        │
└──────────────────────────────────────────────────────┘
```

- **① Terminal path (primary).** Host opens a PTY (`openpty` + `posix_spawn` with
  `POSIX_SPAWN_SETSID`), streams raw VT bytes over **plain TCP** (with `TCP_NODELAY`) to the
  client, which renders them with **libghostty**. A dual data/control channel plus an
  Eternal-Terminal-style replay buffer give byte-exact lossless reconnect. This is the
  de-risked core and the everyday path.
- **③ Read-only inspector (differentiator).** A companion view that tails the Claude Code
  JSONL transcript + hooks to surface tool calls, subagents, and todos over a second
  NWConnection. Read-only by construction — it observes the transcript and never drives the
  agent, so it never pays the cost of doing so.
- **② GUI video path (Phase 4, secondary).** ScreenCaptureKit + VideoToolbox HEVC over UDP
  for the occasional GUI window (VS Code, Xcode). Built and reviewed, not part of the
  everyday terminal flow; see the status table.

## Module map (SwiftPM)

| Target | Kind | Role |
|--------|------|------|
| `AislopdeskProtocol`     | lib  | Wire format: framing, `MessageType`, `Int64` seq, hello/ack. Pure Swift, **zero platform dep** (no `Network`/`Darwin`) → builds macOS + iOS. |
| `AislopdeskTransport`    | lib  | `NWConnection` + `TCP_NODELAY`, dual data/control channels, ET-style `ReplayBuffer` (4 MiB offline gate / 64 MiB cap), reconnect handshake. |
| `AislopdeskHost`         | lib  | macOS host: PTY (`openpty` + `posix_spawn` createSession), session manager, no-buffer PTY↔transport relay, `TIOCSWINSZ` resize, Claude Code launch env (`--claude`/`--xterm256`) + stat-only auth resolve, idle-TTL session reaper, host-side OSC/BEL title/bell sniffer. |
| `AislopdeskClient`       | lib  | Shared client: connection manager, reconnect (capped backoff), input encoding, gap-free/dup-free output stream, iOS pause/resume seam. |
| `AislopdeskTerminal`     | lib  | `TerminalSurface` protocol + `HeadlessTerminalSurface`. The libghostty-backed `GhosttySurface` lives in the GUI app target and conforms to the same seam. |
| `AislopdeskTTY`          | lib  | Local raw-mode termios save/restore + `TIOCGWINSZ`/`TIOCSWINSZ` for the interactive CLI (split out so it is unit-testable). |
| `AislopdeskInspector`    | lib  | Read-only structured inspector: tolerant JSONL transcript tailer + hooks, typed `InspectorEvent` model (tool cards / subagent tree / todos / thinking-placeholder), second-channel transport + SwiftUI views. |
| `AislopdeskClaudeCode`   | lib  | Cross-platform Claude Code integration logic: terminal-mode sniffer (DECSET/DECRST 1049 + OSC 133, split-robust), input dedup ring, input-box A/B1 state machine. |
| `AislopdeskClientUI`     | lib  | Cross-platform SwiftUI client: views + `@Observable` view-models binding Client/Inspector/ClaudeCode/Terminal; iOS UIKit native-feel table-stakes (key-repeat, floating cursor, accessory bar, IME routing) + the `TerminalInputHost` `UIResponder` that assembles them (compiles for iOS, on-device interaction unverified). |
| `AislopdeskVideoProtocol`| lib  | PATH 2 pure wire format: UDP packetizer/reassembler + loss detect, FEC (XOR parity), cursor side-channel, window geometry, coordinate mapping, input-event codec. Zero platform dep → macOS + iOS. |
| `AislopdeskVideoHost`    | lib  | PATH 2 macOS-only capture + encode + input injection + UDP transport + host session orchestrator (ScreenCaptureKit / VideoToolbox 2-session / CGEvent / `NWVideoDatagramTransport`). Compiled + reviewed; pure logic tested, GUI pipeline not run. |
| `AislopdeskVideoClient`  | lib  | PATH 2 macOS + iOS decode + Metal render + client-side cursor + UDP transport + display-link pacing + client session orchestrator (VTDecompression / Metal / CVDisplayLink·CADisplayLink). Compiled + reviewed; pure logic tested, GUI pipeline not run. |
| `aislopdesk-hostd`       | exec | Headless host daemon (PTY + transport; `--claude`/`--xterm256` launch modes). |
| `aislopdesk-client`      | exec | Interactive remote terminal client. |
| `aislopdesk-videohostd`  | exec | PATH 2 GUI-video host daemon — enumerate `SCWindow`, serve one via `AislopdeskVideoHostSession` (`--list`/`--window-id`/`--window-title`). macOS + GUI/TCC only. |

12 libraries + 3 executables + 10 test targets = **25 SwiftPM targets**, ~24k Swift LOC.

## Quickstart

Everything below the GUI is **headless** — no GUI, no libghostty, no signing required for
the core libraries, CLIs, and tests. These commands are real and work today over TCP
(loopback or NetBird).

### Build & test

```sh
swift build          # builds every target incl. all three executables
swift test           # 423 tests, 0 failures (~23s), warning-clean
```

### iOS typecheck

`swift build` on macOS compiles the **macOS slice only** — it never type-checks the
`#if os(iOS)` sources (the UIKit input host + the four native-feel table-stakes in
`Sources/AislopdeskClientUI/iOS/`), so they can rot silently. Build them with an explicit
iOS-Simulator (unsigned) build:

```sh
scripts/check-ios.sh   # iOS-triple build of ClientApp-iOS (+ AislopdeskClientUI); fails non-zero on error
```

This requires Xcode and runs `xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj
-scheme ClientApp-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
build`. Run it whenever you touch `#if os(iOS)` code.

### Run the host daemon (`aislopdesk-hostd`)

```sh
swift build -c release
.build/release/aislopdesk-hostd --port 7420                     # plain login shell (TERM=xterm-ghostty)
.build/release/aislopdesk-hostd --port 7420 --claude            # launch Claude Code under the curated env
.build/release/aislopdesk-hostd --port 7420 --claude --xterm256 # Claude Code, TERM=xterm-256color fallback
```

`aislopdesk-hostd` binds `0.0.0.0` (the port you pass, or an OS-chosen one), spawns a login shell
per new session, logs to stderr, and runs until `SIGINT`. The session **survives a client
disconnect** — the daemon never kills the shell on channel failure; a returning client
resumes byte-exact from the replay buffer. A long-offline client is eventually torn down by
the idle-TTL reaper, and half-open handshakes are reaped on timeout.

| Flag | Meaning |
|------|---------|
| `--port`, `-p` | TCP port to bind (omit → OS-chosen, logged to stderr). |
| `--shell`      | Login shell to spawn (default: the user's). |
| `--claude`     | Launch `claude` under the curated `ClaudeCodeProfile` env (`TERM=xterm-ghostty`, `COLORTERM`, `CLAUDE_CODE_NO_FLICKER`, …) instead of a plain shell. |
| `--xterm256`   | With `--claude`, advertise `TERM=xterm-256color` (the multi-line-paste #54700 fallback) instead of `xterm-ghostty`. No-op without `--claude`. |

**TERM auto-fallback (terminfo bootstrap, audit #17).** The host's default is
`TERM=xterm-ghostty` (best features for the libghostty client), but that terminfo entry is
not present on a fresh remote host — so before each PTY spawn the host probes whether it can
resolve `xterm-ghostty` (searches `$TERMINFO` / `~/.terminfo` / `$TERMINFO_DIRS` / the system
terminfo dirs, then `infocmp xterm-ghostty`). If it cannot, the host automatically advertises
`TERM=xterm-256color` instead — universally present and correct enough for `vim`/`htop`/`less`/
`tmux`/`top` — and logs the fallback to stderr. This mirrors Ghostty's documented #54700
fallback; the heavier kitty-`ssh`-kitten model (pushing + `tic`-installing the compiled
ghostty terminfo on the remote) is intentionally deferred. An explicit `--xterm256` always
wins over auto-detection.

### Run the interactive client (`aislopdesk-client`)

```sh
.build/release/aislopdesk-client --host <host> --port 7420
```

| Flag | Meaning |
|------|---------|
| `--host`, `-h` | Host running `aislopdesk-hostd`. |
| `--port`, `-p` | TCP port `aislopdesk-hostd` listens on. |
| `--no-raw`     | Do not put the local terminal in raw mode (use for pipes / scripting). |

In interactive mode (stdin is a TTY, `--no-raw` not set) the local terminal is put into raw
mode and every keystroke — **including `Ctrl-C`** — is forwarded as a raw byte to the remote
shell (the remote line discipline raises `SIGINT` there, not locally). Because `Ctrl-C` is
passed through, the only **local** escape is:

> **`Ctrl-]`** — cleanly disconnect, restore the terminal, exit `0`.

The terminal is always restored on exit (normal exit, `Ctrl-]`, and
`SIGINT`/`SIGTERM`/`SIGQUIT`/`SIGHUP`), so a wedged session never leaves it in raw mode.

### Non-interactive / pipe form

```sh
printf 'echo hello\nexit\n' | .build/release/aislopdesk-client --host <host> --port 7420 --no-raw
```

`--no-raw` pipe mode waits for the remote session to exit before returning, so a piped
script is never truncated.

## GUI renderer + PATH 2 (libghostty + video) — how to run on hardware

The libghostty renderer **compiles, LINKS, and RENDERS at runtime** on this macOS-26.5 host for
**both macOS AND iOS** (0 undefined symbols) — the former Zig↔SDK blocker is gone, and the iOS
renderer is **verified rendering on the iOS 26.5 Simulator** (driven via maestro: glyphs, ANSI
colors, nerd-font/powerline icons, live `ls`/Starship output, cursor — updating per feed). Key insight: an xcframework slice
is a **static archive (no final link step)**, so Zig 0.15.2 cross-compiles iOS objects against
the installed **iOS 26.5 SDK** fine — **no iOS ≤18 SDK needed**. (macOS needs an `xcrun`
PATH-shim to point the native build-runner at the CLT's `MacOSX15.sdk`; iOS passes through to
26.5.) The renderer stays gated `#if canImport(CGhostty)` and is in NO `Package.swift` target,
so the headless `swift build`/`swift test` never see it; the 64 MB+ xcframework is gitignored.
The **iOS** app ships with the renderer **enabled** in its committed `project.yml` — so you must
build `libghostty.xcframework` first (step 1) or the iOS `xcodebuild` fails to link. The **macOS**
app stays renderer-free by default (enable on demand, step 2a). Rendering on the iOS Simulator
also requires `ThirdParty/ghostty/patches/0001-aislopdesk-sync-updateframe-in-draw.patch` (auto-applied
by `build-libghostty.sh`): it makes `Surface.draw()` run `updateFrame` synchronously, because the
renderer thread's libxev `wakeup` async isn't pumped on the Simulator (so the normal cell-rebuild
never re-runs → blank glyphs without the patch).

```sh
# 1. Build the universal xcframework (macos-arm64 + ios-arm64 + ios-arm64-simulator).
#    Needs the Metal Toolchain once: xcodebuild -downloadComponent MetalToolchain
XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh   # (omit env → macOS-only)

# 2a. macOS GUI terminal: wire the renderer, build + run the app, then restore the placeholder spec.
bash scripts/enable-macos-renderer.sh
xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj -scheme ClientApp-macOS \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
git checkout -- Apps/ClientApp-macOS/project.yml && xcodegen generate --spec Apps/ClientApp-macOS/project.yml

# 2b. iOS GUI terminal (Simulator). project.yml is committed renderer-ENABLED (+ pins ARCHS=arm64),
#     so just (re)generate the .xcodeproj and build — no enable step, no restore:
xcodegen generate --spec Apps/ClientApp-iOS/project.yml   # or: bash scripts/enable-ios-renderer.sh (idempotent)
xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj -scheme ClientApp-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
# Install + run on the booted simulator:
xcrun simctl install booted .work/ios-dd/Build/Products/Debug-iphonesimulator/Aislopdesk.app  # (set -derivedDataPath .work/ios-dd)
# (To DISABLE the renderer for a lightweight iOS build, revert the renderer wiring in project.yml.)
```

The GUI terminal is **interactive** — keystrokes (`GhosttySurface.onWrite`) and grid resizes
flow back to the host PTY through `TerminalViewModel` → `AislopdeskClient.sendInput`/`sendResize`.

**PATH 2 (GUI video, secondary).** Host: `swift build -c release` then
`.build/release/aislopdesk-videohostd --list` to find a window, then `--window-id <N>` (grant
**Screen Recording** + **Accessibility**/Post-Event TCC; run from a real GUI session, not SSH).
Client: in the app, open the **Remote window** sheet (toolbar) and enter the host + media/cursor
ports + window id the daemon printed. The live decode pipeline (`AislopdeskVideoClientSession`) comes
up only with a real capturing host + device.

Full recipe + caveats: [`ThirdParty/ghostty/build-libghostty.sh`](ThirdParty/ghostty/build-libghostty.sh)
header and [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Status

| Layer | State |
|-------|-------|
| `AislopdeskProtocol` / `AislopdeskTransport` (incl. byte-exact reconnect) | ✅ done, unit + integration tested headlessly |
| `AislopdeskHost` PTY + session survival | ✅ done, tested headlessly |
| `AislopdeskClient` + interactive `aislopdesk-client` (full PATH 1 e2e) | ✅ done, real loopback + subprocess e2e |
| `AislopdeskInspector` (JSONL tailer + event model + 2nd channel) | ✅ done, fixture-tested |
| `AislopdeskClaudeCode` integration logic (env / sniffer / dedup) | ✅ done, byte-sequence tested |
| `AislopdeskClientUI` (SwiftUI + iOS table-stakes logic) | ✅ macOS-tested; iOS responder host `TerminalInputHost` ⚠️ compiles (`scripts/check-ios.sh`) + reviewed, on-device interaction unverified |
| `AislopdeskVideoProtocol` (PATH 2 pure codec/FEC/mapping) | ✅ done, unit tested |
| `AislopdeskVideoHost` / `AislopdeskVideoClient` (capture/encode/decode/render + orchestrators) | ⚠️ compiled + reviewed; pure logic tested. **Both ends now wired**: `aislopdesk-videohostd` host daemon + the client Remote-window panel + the LIVE `VideoWindowView(title:connection:)` factory. GUI pipeline still **not run** (SCKit/VideoToolbox hang without a window-server + TCC) — needs a real capturing host + device. |
| `GhosttyTerminalView` / libghostty renderer | ✅ **compiles + LINKS on macOS AND iOS** (0 undefined; `enable-{macos,ios}-renderer.sh`). Gated `#if canImport(CGhostty)`; the OUT path (keystrokes/resize → host) is wired. Remaining: a runtime GUI smoke-test + on-device run. |

For the full per-layer status with test counts, commit hashes, the verify-on-hardware
checklist, and known caveats, see [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Documentation

- [`docs/00-overview.md`](docs/00-overview.md) — architecture overview + every binding decision (read first).
- [`docs/19-implementation-plan.md`](docs/19-implementation-plan.md) — the full build log + phase→workflow table + status (source of truth).
- [`docs/20-wire-protocol.md`](docs/20-wire-protocol.md) — the PATH 1 terminal wire protocol.
- [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md) — honest end-of-autonomous-build status + how to verify on hardware.

## License

[MIT](LICENSE)
