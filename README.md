# Aislopdesk

Aislopdesk drives a remote Mac from another Apple device. A macOS **host** exposes its
shells and windows; macOS and iOS/iPadOS **clients** present them as a tiling workspace of
panes — sessions grouped by host, tabs per session, and recursive splits per tab, with
optional floating scratch panes on top. A pane is either a terminal or a live GUI window,
and you mix both in the same workspace. The usual setup is several shells and **Claude Code**
agents running on a workstation, supervised from a laptop or iPad with no perceptible lag.

Two things make that work:

- The latency-sensitive code — every wire codec, FEC, frame reassembly, and the realtime
  controllers — is native Swift, the single source of truth, with no second implementation
  and no FFI boundary. The Swift/SwiftUI apps are the platform shell around it (capture,
  hardware codec, Metal, input, PTY, UI).
- There is no app-layer encryption or auth. Aislopdesk expects to run on a trusted private
  network, normally a WireGuard mesh such as [NetBird](https://netbird.io) or Tailscale,
  which already provides end-to-end encryption, node identity, and per-port ACLs. The
  security boundary is the network, not the app.

Build floor is macOS 26 / iOS 26 (`Package.swift` pins `.v26`). The terminal renderer is
**libghostty**.

## The workspace

The client is a coding-IDE shell: a sessions sidebar grouped by host, a tab bar per session,
and a recursive split tree per tab (panes split vertically or horizontally and tile
n-ary). Any pane can pop out as a movable, resizable **floating scratch pane** that persists
across reloads. Each pane connects to the host over the transport that fits its content:

**Terminal panes** stream raw VT bytes from a host PTY over TCP and render them with
libghostty — a full terminal, so vim, tmux, and the Claude Code TUI all work as if local.
Text is pixel-perfect because it never goes through a video codec. Each session uses two TCP
connections (data and control) so an output burst can't delay a resize ack, and a replay
buffer gives byte-exact lossless reconnect after a drop.

**GUI window panes** mirror a single host window — VS Code, Xcode, a browser — over UDP.
ScreenCaptureKit captures the window, VideoToolbox encodes HEVC at up to 60 fps, and the
client decodes to Metal. The path carries Reed–Solomon FEC, adaptive bitrate and congestion
control, long-term-reference loss recovery, and a client-side cursor drawn at display
refresh so pointer latency is just the round trip. Input is injected back into the host
window with CGEvent.

Alongside the panes, a **read-only Claude Code inspector** tails the JSONL transcript and
hooks on a second TCP connection and surfaces tool calls, subagents, and todos. It only
observes the transcript; it never drives the agent.

Because the point is supervising several agents at once, the workspace is built around a
**"which agent needs me?" loop**. The host detects a `claude` running in any terminal pane
and tracks its state (idle / working / blocked / done); the client renders that as a
concentric attention ring (red when an agent is blocked on a permission prompt, green when
done) that shows even on a background pane, plus tab glow, an OS notification on the edge, and
**jump-to-unread** (⌘⇧U) to focus the oldest pane needing attention. The app never adds its
own approval gate — it surfaces the agent's own blocked state and lets you type the answer;
the security boundary stays the network. The same status is exposed headlessly through
`aislopdesk-ctl`: a push events stream and per-pane state so an orchestrator can supervise
without polling. Other workspace conveniences: **sync-input** (⌘⇧I) fans keystrokes to every
pane in a tab, and a keyboard **copy-mode** (⌘⇧C) navigates and copies scrollback with
tmux/zellij-style keys. The UI is a modern dark IDE — pane focus ring, elevation, semantic
status accents, and a glass command palette — over the libghostty surfaces.

The three transports share nothing — separate sockets, message sets, and version constants.
The host rejects any version other than `1` rather than negotiating.

## Architecture

Native Swift is the single source of truth for everything on the wire: the terminal and
video codecs, FEC and frame reassembly, the realtime controllers (congestion and ABR, the
fps governor, LTR, the decode gate and sequencer, the jitter pacer, the delay-gradient
trendline, recovery admission), coordinate mapping, and the terminal/PTY protocol including
its SSH-style channel mux and per-channel flow control. There is no second implementation to
keep in sync and no FFI boundary; the wire is frozen by a golden corpus
(`golden/golden_vectors.json`) so a refactor can't silently shift a byte.

The only non-Swift code is `Sources/CAislopdeskSIMD`: ONE aarch64 NEON kernel, the GF(2⁸)
region multiply used by FEC, guarded `#if defined(__aarch64__)` with a scalar fallback
otherwise. SwiftPM compiles it from source every build — no cbindgen, no marshalling, no
prebuilt staticlib, no build ordering. Frame hashing is pure scalar Swift (xxHash64 is
64-bit-multiply-heavy and Apple Silicon has no native 64-bit lane multiply, so the scalar
path beats a synthesized-NEON fold). Both the NEON kernel and the scalar hash are pinned
bit-for-bit against their scalar references by differential tests.

## Module map (SwiftPM)

| Target | Kind | Role |
|--------|------|------|
| `AislopdeskProtocol`     | lib  | Terminal wire format (framing, seq, hello/ack). No platform deps. |
| `AislopdeskTransport`    | lib  | TCP channels, replay buffer, reconnect handshake. |
| `AislopdeskHost`         | lib  | macOS host: PTY spawn/relay, session manager, agent-detect gates. |
| `AislopdeskClient`       | lib  | Shared client: connection/reconnect, input, gap-free output stream. |
| `AislopdeskTerminal`     | lib  | `TerminalSurface` seam (libghostty-backed in the GUI apps). |
| `AislopdeskTTY`          | lib  | Local raw-mode termios + winsize for the CLI. |
| `AislopdeskInspector`    | lib  | JSONL transcript tailer, typed events, read-only views. |
| `AislopdeskClaudeCode`   | lib  | Claude Code integration: terminal-mode sniffer, input dedup/state. |
| `AislopdeskAgentDetect`  | lib  | Headless per-pane Claude status machine + no-hooks manifest matcher. |
| `AislopdeskClientUI`     | lib  | SwiftUI client views/view-models + iOS input host. |
| `AislopdeskVideoProtocol`| lib  | Video wire format: packetizer, FEC, cursor/geometry/input codec. |
| `AislopdeskVideoHost`    | lib  | macOS capture + encode + input injection + UDP host session. |
| `AislopdeskVideoClient`  | lib  | macOS/iOS decode + Metal render + pacing + client session. |
| `AislopdeskCtlCore`      | lib  | Pure `aislopdesk-ctl` core: arg parsing + NDJSON request/response. |
| `CAislopdeskSIMD`        | C    | The only non-Swift code: the aarch64 NEON GF(2⁸) region-multiply kernel (scalar fallback). |
| `CAislopdeskVirtualDisplay` | C | Private `CGVirtualDisplay*` headers for the host's 2× HiDPI virtual display. |
| `aislopdesk-hostd`       | exec | Headless host daemon (terminal panes). |
| `aislopdesk-client`      | exec | Interactive remote terminal client. |
| `aislopdesk-ctl`         | exec | Agent-control CLI over the host's Unix-domain NDJSON socket. |
| `aislopdesk-videohostd`  | exec | GUI-window host daemon (needs a GUI session + TCC). |
| `aislopdesk-loopback-validate` | exec | Headless video-pipeline validator (real HW encode→decode, FEC, ABR). |
| `aislopdesk-corevectors` | exec | Emits the golden corpus the golden-corpus check diffs against. |
| `aislopdesk-bench`       | exec | Micro-benchmark for the hot paths (frame hash, GF region multiply, RS FEC). |
| `aislopdesk-framewatch`, `aislopdesk-capture-probe`, `aislopdesk-fake-client` | exec | Diagnostics: ScreenCaptureKit cadence, window capture, host-side fake client. |

There is no FFI boundary: the codecs, FEC, controllers, and terminal protocol are native
Swift, linked directly. The package is 14 Swift libraries, 10 executables, 12 test targets,
and 2 C targets (`CAislopdeskSIMD`, the NEON kernel, plus `CAislopdeskVirtualDisplay`, a
virtual-display header shim) — both compiled from source by SwiftPM.

## Build & run

The libraries, CLIs, and tests are headless: no GUI, no libghostty, no signing. A clean
checkout builds with no prerequisite — there is no Rust toolchain, no staticlib to
pre-build, and no build ordering. The only C is the in-tree `CAislopdeskSIMD` target, which
SwiftPM compiles from source.

```sh
swift build               # 14 libs + 10 executables (+ 2 C targets, built from source)
swift test                # full suite (~2300 tests), headless
scripts/check-ios.sh      # iOS-simulator typecheck of the #if os(iOS) sources (needs Xcode)
```

### Host daemons

A terminal host:

```sh
swift build -c release
.build/release/aislopdesk-hostd --port 7420                 # plain login shell
.build/release/aislopdesk-hostd --port 7420 --inspector     # + read-only inspector on port+1
```

| Flag | Meaning |
|------|---------|
| `--port`, `-p` | TCP port to bind (default `7420`; `0` → OS-chosen, logged to stderr). |
| `--shell`, `-s` | Login shell to spawn (default: the user's). |
| `--inspector`  | Stand up the read-only structured inspector server on `port + 1`. |
| `--transcript PATH` | Inject the Claude Code JSONL transcript path the inspector tails (implies `--inspector`). |

Every channel spawns a plain login shell; the curated `--claude` launch mode is retired. A
Claude session is now just a `.terminal` pane that runs `claude`, auto-detected by the
host's process-watch and hook listener and offered client-side as a launch preset. Terminal
sessions survive client disconnects: a returning client resumes byte-exact from the replay
buffer, and long-offline sessions are reaped on an idle timeout. The host defaults to the
libghostty `TERM`, probes terminfo at spawn, and falls back to `xterm-256color` when the
ghostty entry is missing.

A GUI-window host (needs Screen Recording + Accessibility, and a real GUI session — not
SSH):

```sh
.build/release/aislopdesk-videohostd --list             # enumerate windows
.build/release/aislopdesk-videohostd --window-id <N>     # serve one window (60 fps default)
```

`--fps N` overrides the capture/encode rate (default 60; 30 is lighter but visibly less
smooth on scroll and motion).

### Interactive terminal client

```sh
.build/release/aislopdesk-client --host <host> --port 7420
```

Every keystroke, including `Ctrl-C`, is forwarded raw to the remote shell. The only local
escape is `Ctrl-]`, a clean disconnect. The local terminal is always restored on exit,
including on signals. For scripting, `--no-raw` pipe mode waits for the remote session to
exit:

```sh
printf 'echo hello\nexit\n' | .build/release/aislopdesk-client --host <host> --port 7420 --no-raw
```

### GUI client apps (libghostty renderer + video)

libghostty renders on macOS and iOS (verified on the iOS 26.5 Simulator). It is gated behind
`#if canImport(CGhostty)` and lives outside `Package.swift`, so headless builds never see it.
The xcframework is gitignored and must be built once:

```sh
# 1. Universal xcframework (macos-arm64 + ios-arm64 + ios-arm64-simulator)
XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh

# 2a. macOS app
bash scripts/enable-macos-renderer.sh
xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj -scheme ClientApp-macOS \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build

# 2b. iOS app (project.yml is committed renderer-enabled)
xcodegen generate --spec Apps/ClientApp-iOS/project.yml
xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj -scheme ClientApp-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

In the app, add a terminal pane by entering the host and terminal port, or a GUI-window pane
through the Remote-window sheet (host, ports, window id). Full recipe and caveats are in the
[`build-libghostty.sh`](ThirdParty/ghostty/build-libghostty.sh) header and
[`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Status

| Layer | State |
|-------|-------|
| Native-Swift core (codecs, FEC, controllers, terminal protocol) | The single source of truth; wire frozen by the golden corpus, plus per-subsystem fuzz and HW loopback. |
| Terminal panes end to end (protocol, transport, host PTY, client, reconnect) | Done; tested headlessly and on hardware. |
| GUI-window panes (capture → encode → FEC/ABR → decode → render, input injection) | Running on hardware via the video host daemon and the client Remote-window panel. |
| Inspector (JSONL tailer, event model, second channel) | Done; fixture-tested. |
| Claude Code integration (env, sniffer, dedup) | Done; byte-sequence tested. |
| Client UI (SwiftUI + iOS input) | macOS tested; iOS compiles, on-device interaction unverified. |
| libghostty renderer (macOS + iOS) | Builds, links, renders (iOS Simulator verified). |

Per-layer detail, test counts, and the hardware-verification checklist are in
[`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Documentation

- [`docs/README.md`](docs/README.md) — index of the design docs.
- [`docs/00-overview.md`](docs/00-overview.md) — architecture and every binding decision (read first).
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — the decision log.
- [`docs/20-wire-protocol.md`](docs/20-wire-protocol.md) — the terminal-path wire protocol.

## License

[MIT](LICENSE)
