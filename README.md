# SlopDesk

Remote coding for Apple platforms. A macOS **host** exposes shells and windows; macOS and iOS
**clients** show them as a tiling workspace of panes, terminal or live GUI window, mixed freely.
The usual setup is several shells and Claude Code agents on a workstation, supervised from a laptop
or an iPad.

Build floor: macOS 26 / iOS 26, Apple silicon.

## Architecture

**Rust owns the wire and the machine.** Codecs, FEC, realtime controllers, the terminal/PTY
protocol, the workspace document, the settings catalogue, agent detection, and every system call
from capture to input injection (`rust/slopdesk-wire`, `rust/slopdesk-video`,
`rust/slopdesk-workspace` and ~50 more crates). The wire format is frozen by
`golden/golden_vectors.json`. Rust reaches the apps two ways: six sidecar daemons over sockets, and
`CSlopDeskFFI` linked in-process ([`docs/55-ffi-boundary.md`](docs/55-ffi-boundary.md)).

**Swift is the view layer.** AppKit in `Sources/SlopDeskMacUI`, UIKit in
`Sources/SlopDeskPhoneUI`, over a shared `Sources/SlopDeskClientCore` that draws nothing. The iOS
app differs in layout only; every feature is on both halves.

**No app-layer crypto or auth.** Run it on a trusted private network, a WireGuard mesh such as
NetBird or Tailscale. The security boundary is the network.

### Three transports

Separate sockets, separate message sets, version `1` only.

| Path | Transport | What moves |
|------|-----------|------------|
| Terminal | TCP, data + control | Host PTY bytes into `rust/slopdesk-vterm`, drawn by `rust/slopdesk-termrender`. Dual channel plus a replay buffer, so a reconnect is lossless |
| GUI window | UDP | ScreenCaptureKit into HEVC into Metal, with Reed-Solomon FEC, adaptive bitrate and a client-side cursor |
| Inspector | TCP | Read-only Claude Code JSONL and hooks: tool calls, subagents, todos |

The terminal engine is `libghostty-vt` as the parse layer; the grid and the renderer above it are
this repo's own ([`docs/68-terminal-surface-in-rust.md`](docs/68-terminal-surface-in-rust.md)).

## What it does

- **Workspace** of session, tab, and n-ary split panes. A pane is a terminal or a GUI window, and
  the transport follows the content.
- **Agent attention.** Idle, working, blocked and done drive pane rings, tab glow, notifications
  and jump-to-unread. Detection is a hook feed plus a TTY parse
  ([`docs/50-agent-detection-architecture.md`](docs/50-agent-detection-architecture.md)).
- **Read-only inspector**, a companion view for what reads badly in scrollback: subagent
  transcripts, tool I/O, todos, workflow.
- **Sessions outlive the host.** `slopdesk-superd` holds every PTY master, so restarting the host
  never kills the agents under it.
- **Multi-client.** Several clients share one workspace document with PTY fan-out
  ([`docs/45-multi-client-state-sync.md`](docs/45-multi-client-state-sync.md)).
- Sync-input across panes, copy-mode, per-pane read-only lock, file drop, and `slopdesk-ctl` for
  headless supervision.
- Side panels for iOS simulators and Android emulators
  ([`docs/47-simulator-panel.md`](docs/47-simulator-panel.md),
  [`docs/48-android-panel.md`](docs/48-android-panel.md)).

## More

Install, build and run: [`BUILDING.md`](BUILDING.md). Architecture in full:
[`docs/00-overview.md`](docs/00-overview.md), indexed in [`docs/README.md`](docs/README.md), with
the decision log in [`docs/DECISIONS.md`](docs/DECISIONS.md).

## License

[MIT](LICENSE)
