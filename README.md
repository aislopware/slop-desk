# Rwork

**Rwork** is a terminal-first, low-latency remote-coding tool for Apple platforms —
a macOS host paired with macOS/iOS clients. The everyday use case is running a shell
and **Claude Code** on a remote machine and driving it from another device with
native, feels-local responsiveness.

Rwork is **native Swift end to end** and runs over a [NetBird](https://netbird.io)
(WireGuard) mesh, assuming direct peer-to-peer connectivity. Because WireGuard already
provides end-to-end encryption and NetBird ACLs gate membership, Rwork adds **no app-layer
encryption or auth** — the security boundary is the mesh.

## Architecture in one breath

- **Terminal path (primary):** host opens a PTY (`openpty` + `posix_spawn`), streams raw VT
  bytes over **plain TCP** (with `TCP_NODELAY`) to the client, which renders them with
  **libghostty**. A dual data/control channel plus an Eternal-Terminal-style replay buffer
  give lossless reconnect.
- **Read-only inspector (differentiator):** a companion view that tails the Claude Code
  JSONL transcript + hooks to surface tool calls, subagents, and todos. Read-only, so it
  never pays the cost of driving the agent.
- **GUI video path (Phase 4, secondary):** ScreenCaptureKit + VideoToolbox HEVC for the
  occasional GUI window. Not part of this foundation.

## Renderer policy: libghostty only, no fallback

The client terminal renderer is **libghostty exclusively** — there is **no SwiftTerm
fallback** and no second rendering path. This is a deliberate "build the best thing, keep
no plan B" commitment. The libghostty surface lives in the GUI app target behind the
`TerminalSurface` seam; the headless core builds and is fully testable without it.

## Repository layout

This repo is a Swift package (headless-first core) plus design docs. The canonical module
map and build sequencing live in
[`docs/19-implementation-plan.md`](docs/19-implementation-plan.md). For the full architecture
and every binding decision, start at [`docs/00-overview.md`](docs/00-overview.md).

The wire protocol implemented here is documented in
[`docs/20-wire-protocol.md`](docs/20-wire-protocol.md).

## Build & test

```sh
swift build
swift test
```

Both run headless — no GUI, no libghostty, no signing required for the core libraries,
CLIs, and tests.

## Running the client (`rwork-client`)

`rwork-client` is the interactive terminal client. Point it at a running `rwork-hostd`:

```sh
rwork-client --host <host> --port <port> [--no-raw]
```

| Flag | Meaning |
|------|---------|
| `--host`, `-h` | Host running `rwork-hostd`. |
| `--port`, `-p` | TCP port `rwork-hostd` listens on. |
| `--no-raw` | Do not put the local terminal in raw mode (use for pipes / scripting). |

In interactive mode (stdin is a TTY and `--no-raw` is not set) the local terminal is put
into raw mode and every keystroke — **including `Ctrl-C`** — is forwarded to the remote
shell as a raw byte (the remote line discipline raises `SIGINT` there, not locally).

Because `Ctrl-C` is passed through, the only **local** escape is the disconnect key:

> **`Ctrl-]`** — cleanly disconnects, restores the terminal, and exits `0`.

The terminal is always restored on exit (normal exit, disconnect key, and
`SIGINT`/`SIGTERM`/`SIGQUIT`/`SIGHUP`), so a wedged session never leaves the terminal in
raw mode. (This is the same disconnect key as the `--help` text; keep the two in sync.)

## License

[MIT](LICENSE)
