# SlopDesk

Remote coding for Apple platforms: a macOS **host** exposes shells and windows; macOS/iOS **clients** show them as a tiling workspace of panes (terminal or live GUI window, mixed freely). Typical use: several shells and Claude Code agents on a workstation, supervised from a laptop or iPad.

Build floor: macOS 26 / iOS 26. Terminal engine: **libghostty-vt** through `rust/slopdesk-vterm`; the renderer above it is this repo's own ([`docs/68-terminal-surface-in-rust.md`](docs/68-terminal-surface-in-rust.md)).

## Design

- **Rust owns the wire** (codecs, FEC, reassembly, realtime controllers, terminal/PTY protocol), reached two ways: six sidecar daemons over sockets, and `CSlopDeskFFI` linked in-process as an `.xcframework`. Swift keeps SwiftUI/AppKit. Wire format is frozen by a golden corpus.
- **No app-layer crypto/auth.** Run on a trusted private network (WireGuard mesh — NetBird, Tailscale, …). The security boundary is the network.

Three independent transports (separate sockets, message sets, version `1` only):

| Path | Transport | Role |
|------|-----------|------|
| Terminal | TCP (data + control) | Host PTY → libghostty-vt → this repo's renderer; dual channel + replay buffer for lossless reconnect |
| GUI window | UDP | ScreenCaptureKit → HEVC → Metal; RS-FEC, ABR, client-side cursor |
| Inspector | TCP | Read-only Claude Code JSONL/hooks (tool calls, subagents, todos) |

Agent attention (idle/working/blocked/done) drives rings, tab glow, notifications, and jump-to-unread (⌘⇧U). Also: sync-input (⌘⇧I), copy-mode (⌘⇧C), `slopdesk-ctl` for headless supervision.

## Install

Apple silicon, macOS 26 or newer. Signed and notarized; two packages, installed independently:

```sh
brew install --cask aislopware/tap/slopdesk  # SlopDesk.app + SlopDeskHost.app
brew services start slopdesk                 # slopdesk-superd — required, see below
```

The cask depends on the formula, so that first command also installs the CLI (`slopdesk`,
`slopdesk-hostd`, `slopdesk-ctl`) and the sidecar daemons. `brew install aislopware/tap/slopdesk`
alone gets you those without the apps.

`brew services start slopdesk` is not optional. `slopdesk-superd` holds every pane's PTY master —
that is what lets you restart the host without killing the agents under it — and neither the host
app nor `slopdesk-hostd` forks a shell itself, so without the service running there are no panes.

The app bundles carry no copy of the CLI. Signed artifacts also live on the
[releases page](https://github.com/aislopware/slop-desk/releases); how they are built and signed is
[`docs/49-release-pipeline.md`](docs/49-release-pipeline.md).

## Build & run

Every gate, build and test in this repo is a `just` recipe — `just --list` names all 127 of them.
`just` is the one thing to install before anything else can run; `just install-tools` brings the
rest (and `just` itself, so a machine that got it from cargo ends up on the pinned copy).

```sh
brew install just
just install-tools
```

Headless core needs no GUI, no Metal, and no signing:

```sh
swift build
swift test
just check-ios   # iOS slice (#if os(iOS)); needs Xcode
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
.build/release/slopdesk-videohostd --window-id <N>   # window panes default 30 fps (desktop panes 60); `--fps N` to override
```

**CLI client:**

```sh
.build/release/slopdesk-client --host <host> --port 7420
# local escape: Ctrl-]  |  scripting: --no-raw
```

**GUI apps** (the terminal engine's sources are pinned in `ThirdParty/tools/tools.lock`, so provision once):

```sh
just provision

xcodebuild -project Apps/ClientApp-macOS/ClientApp-macOS.xcodeproj \
  -scheme ClientApp-macOS -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

xcodegen generate --spec Apps/ClientApp-iOS/project.yml
xcodebuild -project Apps/ClientApp-iOS/ClientApp-iOS.xcodeproj \
  -scheme ClientApp-iOS -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Details: [`docs/68-terminal-surface-in-rust.md`](docs/68-terminal-surface-in-rust.md), [`docs/21-HANDOFF.md`](docs/21-HANDOFF.md).

## Docs

- [`docs/README.md`](docs/README.md) — index
- [`docs/00-overview.md`](docs/00-overview.md) — architecture
- [`docs/DECISIONS.md`](docs/DECISIONS.md) — decision log
- [`docs/20-wire-protocol.md`](docs/20-wire-protocol.md) — terminal wire protocol

## License

[MIT](LICENSE)
