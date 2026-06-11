# Aislopdesk

**Aislopdesk** is a terminal-first, low-latency remote-coding tool for Apple platforms — a
macOS **host** paired with macOS / iOS **clients**. The everyday use case: run a shell and
**Claude Code** on a remote machine and drive it from another device with feels-local
responsiveness. Native Swift end to end; the client terminal renderer is **libghostty**
exclusively (no fallback renderer).

It runs over a [NetBird](https://netbird.io) (WireGuard) mesh assuming direct P2P
connectivity. WireGuard provides end-to-end encryption and NetBird ACLs gate membership, so
Aislopdesk adds **no app-layer encryption or auth** — the security boundary is the mesh.

## Architecture — three data paths

```
┌─────────────────── HOST (macOS, non-sandboxed) ───────────────────┐
│ (1) Terminal   openpty + posix_spawn -> shell / claude (raw VT)   │
│ (2) GUI video  ScreenCaptureKit -> VideoToolbox HEVC              │
│ (3) Inspector  Claude Code JSONL transcript + hooks -> events     │
└──────┬──────────────────────┬─────────────────────┬───────────────┘
       │ (1) TCP              │ (2) UDP             │ (3) TCP #2
┌──────▼──────────────────────▼─────────────────────▼───────────────┐
│                   CLIENT (macOS / iOS / iPadOS)                   │
│ (1) libghostty surface (full TUI render) + keystrokes             │
│ (2) VTDecompression -> Metal (GUI window video)                   │
│ (3) SwiftUI read-only views (tool cards / subagents / todos)      │
└───────────────────────────────────────────────────────────────────┘
```

All three paths run over the NetBird WireGuard mesh, direct P2P.

1. **Terminal path (primary).** Host opens a PTY and streams raw VT bytes over plain TCP
   (`TCP_NODELAY`) to the client, which renders them with libghostty. A dual data/control
   channel plus an Eternal-Terminal-style replay buffer give byte-exact lossless reconnect.
2. **GUI video path (secondary).** ScreenCaptureKit + VideoToolbox HEVC over UDP for the
   occasional GUI window (VS Code, Xcode), with FEC, adaptive bitrate, and client-side
   cursor.
3. **Read-only inspector (differentiator).** Tails the Claude Code JSONL transcript + hooks
   to surface tool calls, subagents, and todos on a second channel. Read-only by
   construction — it observes the transcript and never drives the agent.

## Module map (SwiftPM)

| Target | Kind | Role |
|--------|------|------|
| `AislopdeskProtocol`     | lib  | Terminal wire format (framing, seq, hello/ack). Zero platform deps. |
| `AislopdeskTransport`    | lib  | TCP channels + replay buffer + reconnect handshake. |
| `AislopdeskHost`         | lib  | macOS host: PTY spawn/relay, session manager, Claude Code launch env. |
| `AislopdeskClient`       | lib  | Shared client: connection/reconnect, input, gap-free output stream. |
| `AislopdeskTerminal`     | lib  | `TerminalSurface` seam (libghostty-backed in the GUI apps). |
| `AislopdeskTTY`          | lib  | Local raw-mode termios + winsize for the CLI. |
| `AislopdeskInspector`    | lib  | JSONL transcript tailer + typed events + views (read-only inspector). |
| `AislopdeskClaudeCode`   | lib  | Claude Code integration: terminal-mode sniffer, input dedup/state. |
| `AislopdeskClientUI`     | lib  | SwiftUI client views/view-models + iOS native-feel input host. |
| `AislopdeskVideoProtocol`| lib  | Video wire format: packetizer, FEC, cursor/geometry/input codec. |
| `AislopdeskVideoHost`    | lib  | macOS capture + encode + input injection + UDP host session. |
| `AislopdeskVideoClient`  | lib  | macOS/iOS decode + Metal render + pacing + client session. |
| `aislopdesk-hostd`       | exec | Headless host daemon (terminal path). |
| `aislopdesk-client`      | exec | Interactive remote terminal client. |
| `aislopdesk-videohostd`  | exec | GUI-video host daemon (window capture; needs GUI session + TCC). |
| `aislopdesk-loopback-validate` | exec | Headless video-pipeline validator (real HW encode→decode, FEC, ABR). |
| `aislopdesk-framewatch`  | exec | ScreenCaptureKit window-cadence diagnostic tool. |

12 libraries + 5 executables + 10 test targets (plus a C virtual-display shim).

## Quickstart

The core libraries, CLIs, and tests are fully headless — no GUI, no libghostty, no signing
required.

```sh
swift build               # builds every target incl. all three executables
swift test                # full suite, headless
scripts/check-ios.sh      # iOS-simulator typecheck of the #if os(iOS) sources (needs Xcode)
```

### Host daemon

```sh
swift build -c release
.build/release/aislopdesk-hostd --port 7420            # plain login shell
.build/release/aislopdesk-hostd --port 7420 --claude   # launch Claude Code
```

| Flag | Meaning |
|------|---------|
| `--port`, `-p` | TCP port to bind (omit → OS-chosen, logged to stderr). |
| `--shell`      | Login shell to spawn (default: the user's). |
| `--claude`     | Launch `claude` under the curated env instead of a plain shell. |
| `--xterm256`   | With `--claude`, advertise `TERM=xterm-256color` instead of `xterm-ghostty`. |

Sessions **survive client disconnects** — a returning client resumes byte-exact from the
replay buffer; long-offline sessions are reaped by an idle TTL. The host defaults to
`TERM=xterm-ghostty` but probes terminfo at spawn and auto-falls back to `xterm-256color`
when the ghostty entry is missing.

### Interactive client

```sh
.build/release/aislopdesk-client --host <host> --port 7420
```

In interactive mode every keystroke — including `Ctrl-C` — is forwarded raw to the remote
shell. The only local escape is **`Ctrl-]`** (clean disconnect). The local terminal is
always restored on exit, including on signals. For scripting, `--no-raw` pipe mode waits
for the remote session to exit:

```sh
printf 'echo hello\nexit\n' | .build/release/aislopdesk-client --host <host> --port 7420 --no-raw
```

## GUI apps (libghostty renderer + video path)

The libghostty renderer builds and renders on macOS **and** iOS (verified on the iOS 26.5
Simulator). It is gated behind `#if canImport(CGhostty)` and lives outside `Package.swift`,
so headless builds never see it; the xcframework is gitignored and must be built once:

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

**GUI video path:** run `.build/release/aislopdesk-videohostd --list` to enumerate windows,
then `--window-id <N>` (grant Screen Recording + Accessibility; run from a real GUI session,
not SSH). In the client app, open the **Remote window** sheet and enter the host, ports, and
window id.

Full recipe + caveats: [`ThirdParty/ghostty/build-libghostty.sh`](ThirdParty/ghostty/build-libghostty.sh)
header and [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Status

| Layer | State |
|-------|-------|
| Terminal path end to end (protocol, transport, host PTY, client, reconnect) | ✅ done, tested headlessly + on real hardware |
| Inspector (JSONL tailer, event model, second channel) | ✅ done, fixture-tested |
| Claude Code integration logic (env / sniffer / dedup) | ✅ done, byte-sequence tested |
| Client UI (SwiftUI + iOS native-feel input) | ✅ macOS-tested; iOS compiles, on-device interaction unverified |
| GUI video path (codec/FEC tested; capture→render pipeline) | ✅ running on real hardware (host daemon + client Remote-window panel) |
| libghostty renderer (macOS + iOS) | ✅ builds, links, renders (iOS Simulator verified) |

Per-layer detail, test counts, and the hardware-verification checklist:
[`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Documentation

- [`docs/README.md`](docs/README.md) — index of all design docs.
- [`docs/00-overview.md`](docs/00-overview.md) — architecture overview + every binding decision (read first).
- [`docs/19-implementation-plan.md`](docs/19-implementation-plan.md) — build log + phase status (source of truth).
- [`docs/20-wire-protocol.md`](docs/20-wire-protocol.md) — the terminal-path wire protocol.
- [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md) — end-of-build status + how to verify on hardware.

## License

[MIT](LICENSE)
