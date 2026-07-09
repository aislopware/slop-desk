# SlopDesk

Remote coding for Apple platforms: a macOS **host** exposes shells and windows; macOS/iOS **clients** show them as a tiling workspace of panes (terminal or live GUI window, mixed freely). Typical use: several shells and Claude Code agents on a workstation, supervised from a laptop or iPad.

Build floor: macOS 26 / iOS 26. Terminal renderer: **libghostty**.

## Design

- **Native Swift** owns the wire (codecs, FEC, reassembly, realtime controllers, terminal/PTY protocol). Wire format is frozen by a golden corpus. The only C is one NEON kernel in `Sources/CSlopDeskSIMD` (GF(2⁸) for FEC).
- **No app-layer crypto/auth.** Run on a trusted private network (WireGuard mesh — NetBird, Tailscale, …). The security boundary is the network.

Three independent transports (separate sockets, message sets, version `1` only):

| Path | Transport | Role |
|------|-----------|------|
| Terminal | TCP (data + control) | Host PTY → libghostty; dual channel + replay buffer for lossless reconnect |
| GUI window | UDP | ScreenCaptureKit → HEVC → Metal; RS-FEC, ABR, client-side cursor |
| Inspector | TCP | Read-only Claude Code JSONL/hooks (tool calls, subagents, todos) |

Agent attention (idle/working/blocked/done) drives rings, tab glow, notifications, and jump-to-unread (⌘⇧U). Also: sync-input (⌘⇧I), copy-mode (⌘⇧C), `slopdesk-ctl` for headless supervision.

## Build & run

Headless core needs no GUI, libghostty, or signing:

```sh
swift build
swift test
scripts/check-ios.sh   # iOS slice (#if os(iOS)); needs Xcode
```

**Host (terminal):**

```sh
swift build -c release
.build/release/slopdesk-hostd --port 7420
.build/release/slopdesk-hostd --port 7420 --inspector   # inspector on port+1
```

| Flag | Meaning |
|------|---------|
| `--port`, `-p` | TCP port (default `7420`; `0` = OS-chosen) |
| `--shell`, `-s` | Login shell (default: user's) |
| `--inspector` | Read-only inspector on `port + 1` |
| `--transcript PATH` | Claude Code JSONL path (implies `--inspector`) |

Sessions survive disconnect; clients resume from the replay buffer. Claude is a normal shell running `claude` (auto-detected).

**Host (GUI window)** — needs Screen Recording + Accessibility, real GUI session:

```sh
.build/release/slopdesk-videohostd --list
.build/release/slopdesk-videohostd --window-id <N>   # default 60 fps; `--fps N` to override
```

**CLI client:**

```sh
.build/release/slopdesk-client --host <host> --port 7420
# local escape: Ctrl-]  |  scripting: --no-raw
```

**GUI apps** (libghostty outside SwiftPM; build xcframework once):

```sh
XCFRAMEWORK_TARGET=universal bash ThirdParty/ghostty/build-libghostty.sh

bash scripts/enable-macos-renderer.sh
xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj \
  -scheme ClientApp-macOS -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

xcodegen generate --spec Apps/ClientApp-iOS/project.yml
xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj \
  -scheme ClientApp-iOS -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Details: [`build-libghostty.sh`](ThirdParty/ghostty/build-libghostty.sh), [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Docs

- [`docs/README.md`](docs/README.md) — index
- [`docs/00-overview.md`](docs/00-overview.md) — architecture
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — decision log
- [`docs/20-wire-protocol.md`](docs/20-wire-protocol.md) — terminal wire protocol

## License

[MIT](LICENSE)
