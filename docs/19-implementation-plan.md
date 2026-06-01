# 19 — Implementation plan & build log (autonomous build)

> **STATUS: CURRENT — orchestration anchor.** Spec/de-risk done ([18 §0]: Phase 0 PASS trên 2 máy thật). Đây là bản đồ **build → workflow** + trạng thái, cập nhật sau mỗi workflow. Triết lý: **codebase đẹp nhất, kiến trúc tốt nhất, không fallback** (libghostty-only, no SwiftTerm).

## Tên sản phẩm & module

Product/codename: **Rwork** (remote workspace — khớp repo `rworkspace`). Module prefix `Rwork`.

```
rworkspace/
├── Package.swift                 # SPM: libs + CLI execs + tests (HEADLESS-buildable & testable)
├── Sources/
│   ├── RworkProtocol/            # wire format: framing, MessageType, seq(int64), Hello/Ack — pure Swift, 0 platform dep
│   ├── RworkTransport/           # NWConnection + TCP_NODELAY, dual data/control channel,
│   │                             #   BackedWriter/BackedReader (ET replay 64MB/4MB gate), reconnect handshake
│   ├── RworkHost/                # macOS: PTY (openpty + posix_spawn createSession), session mgr,
│   │                             #   no-buffer PTY↔transport relay (QoS user-interactive), TIOCSWINSZ
│   ├── RworkClient/              # shared client: connection mgr, reconnect, input encoding
│   └── RworkTerminal/            # TerminalSurface protocol + HeadlessSurface (libghostty impl = GUI app target)
│   ├── rwork-hostd/              # exec: headless host daemon (PTY + transport)  ← buildable tonight
│   └── rwork-client/             # exec: headless CLI test client                ← buildable tonight
├── Tests/{RworkProtocol,RworkTransport,RworkHost,RworkClient}Tests/
├── Apps/                         # Xcode projects (GUI; depend on SPM + libghostty XCFramework) — scaffold
│   ├── HostApp-macOS/  ClientApp-macOS/  ClientApp-iOS/
├── ThirdParty/ghostty/           # build script + External.zig patch → libghostty.xcframework
└── docs/
```

**Why headless-first:** the whole PATH 1 byte pipeline (host PTY ↔ TCP/`TCP_NODELAY` ↔ client, with replay-buffer reconnect) is the de-risked core and is fully buildable + unit/integration-testable with **no GUI, no libghostty**. The renderer (libghostty surface in a Metal view) is intrinsically part of the GUI app target and sits behind `TerminalSurface`; its XCFramework build is the only fragile step (needs Zig) and must never block the core.

## Phase → workflow map

| WF | Layer | Deliverable | Verify | Status |
|----|-------|-------------|--------|--------|
| **WF-1** | Foundation | git init, Package.swift (all targets), `RworkProtocol` fully impl + tests, `docs/20-wire-protocol.md` | `swift build` + `swift test` green | ✅ |
| **WF-2** | Transport | `RworkTransport`: `TCP_NODELAY` conn, dual data/control, BackedWriter/Reader replay, reconnect handshake | loopback unit tests (framing, replay-after-drop, reconnect resume) | ✅ |
| **WF-3** | Host PTY | `RworkHost`: openpty+posix_spawn, relay, resize, session mgr; `rwork-hostd` | spawn `cat`/`echo` in PTY, byte round-trip test | ✅ |
| **WF-4** | E2E byte pipeline | `RworkClient` + `rwork-client`; host↔client loopback over TCP | e2e: client sends `echo hi`, receives `hi`; kill+reconnect resumes | ⛔ WF-3 |
| **WF-5** | libghostty seam | `TerminalSurface`, `GhosttySurface` (GUI), Zig install + ghostty fork + External.zig patch + XCFramework script | `swift build` still green w/o framework; build script runs (best-effort) | ⛔ WF-1 (parallel w/ WF-2..4 ok) |
| **WF-6** | Inspector | `RworkInspector`: tail JSONL transcript + hooks, NWConnection #2, tool-card/subagent/todo model + SwiftUI views | unit tests on JSONL parse + event model | ⛔ WF-1 (independent of terminal) |
| **WF-7** | Claude Code integ | host env (TERM=xterm-ghostty, NO_FLICKER, setup-token reuse), input box A+B1 model | unit tests on env + dedup ring | ⛔ WF-3 |
| **WF-8** | iOS client | UIKit table-stakes (key-repeat/IME/floating-cursor/accessory), reuse Client+Terminal | builds for iOS target | ⛔ WF-4, WF-5 |
| **WF-9** | GUI video path | capture/encode/decode/render/cursor/input (Phase 4) | harness-validated pieces → integrated | ⛔ WF-4 |

Legend: ⏳ running · ✅ done · ⛔ blocked · 🔁 needs-fix

## Sequencing tonight
PATH 1 core is the priority: **WF-1 → WF-2 → WF-3 → WF-4** (sequential; each depends on prior). WF-5 (libghostty) and WF-6 (inspector) are independent of the byte pipeline and can run alongside. WF-7/8/9 follow. Each green layer → atomic git commit. No push (no remote). GUI apps need libghostty + signing → scaffold only.

## Toolchain notes
- Swift 6.3.2 · Xcode 26.5 · arm64 · macOS 26.5. git + gh present.
- `brew install zig pandoc` done → **zig 0.16.0** at `/opt/homebrew/bin/zig`, pandoc 3.9.0.2.
- ⚠️ **WF-5 must pin Zig precisely:** zig 0.16.0 is too new for the ghostty fork (Zig breaks between minors; `daiimus/ghostty:ios-external-backend` was cut from an older SHA needing ~0.13/0.14). WF-5: read the fork's `build.zig.zon` / `.zigversion` / `minimum_zig_version`, fetch that EXACT toolchain into a local dir (ziglang.org/download or mach nominated), and use it via a build-local PATH — do NOT rely on brew's 0.16.0.

## Build log
- (append one line per workflow completion: WF-id · result · commit · notes)
- **WF-1** · ✅ green · SPM foundation (5 libs + 2 execs + 4 test targets, swift-tools 6.0, macOS 14 / iOS 17), `RworkProtocol` fully implemented (framing + dual-channel `WireMessage` + streaming `FrameDecoder`, big-endian, Int64 seq), `docs/20-wire-protocol.md`. `swift build` + `swift test` green (32 tests, 0 failures), warning-free. Skeleton seams for Transport/Host/Client/Terminal + `HeadlessTerminalSurface` real impl. Renderer = libghostty-only behind `TerminalSurface`, no fallback.
- **WF-1 review** · ✅ green · addressed concurrency + decode-coverage review: `ClientConnection` mutable state now `NSLock`-guarded (real `@unchecked Sendable`, no data race); `RworkConnection`/`ReconnectManager` dropped gratuitous `@unchecked` for automatic `Sendable` (so WF-2/WF-4 mutable state will trip the compiler, not be pre-suppressed); added decode error-path tests (`.truncated` on short exit/resize bodies, `.malformedBody` on invalid-UTF-8 `title`, `maxFramePayloadLength` boundary accepted, 256 KiB large-payload round-trip). No wire-format change → `docs/20` unchanged.
- **WF-2** · ✅ green · `RworkTransport` real impl: `TransportParameters.makeTCP()` (single canonical `NWParameters` — `TCP_NODELAY`+keepalive, no app crypto, no interface pin); `NWMessageChannel` actor (NWConnection ⇄ `FrameDecoder`, drains all frames per chunk, async over continuations); pure value-type `ReplayBuffer` (Int64 seq, never-drop invariant, 4 MiB offline gate / 64 MiB cap, `shouldPauseDrain`); `HostTransport`/`HostSessionTransport`/`ClientTransport` actors with server-decides-RETURNING_CLIENT handshake + 1-byte+sessionID channel-association preamble (`docs/20` §8); atomic `resume()` replays the tail in strictly ascending seq before live output resumes. `swift build`+`swift test` green (63 tests, 0 failures, warning-clean; reconnect-resume + framing-fragmentation over real loopback NWConnections, stable across repeated runs). No `@unchecked Sendable` over unguarded mutable state. Wire format unchanged; appended `docs/20` §8 (channel association & handshake).
- **WF-3** · ✅ green · `RworkHost` real impl: `PTYProcess` = `openpty()` (sane cooked termios + `IUTF8` + initial winsize) → `posix_spawn` with `POSIX_SPAWN_SETSID` (createSession), file-actions dup2 slave→0/1/2 + addclose master in child; **controlling tty acquired implicitly** — a fresh session leader's first non-`O_NOCTTY` tty open (the dup2'd slave) becomes its controlling terminal on macOS 26, so **no `TIOCSCTTY` needed** (verified empirically: `tty`→`/dev/ttys*`, `stty size`→openpty winsize, `TIOCSWINSZ`+`SIGWINCH` reflow); `setBlocking(true)` clears `O_NONBLOCK` on master pre-spawn (Happy #301); dedicated `waitpid` reaper thread surfaces exit code as `WireMessage.exit`. `PTYReadLoop` = no-buffer blocking read loop at `QOS_CLASS_USER_INTERACTIVE` → straight to `HostSessionTransport.sendOutput` (only buffer is the transport `ReplayBuffer`); backpressure gate parks the loop (zero master syscalls via `NSCondition`) on `drainPauses==true` so the kernel PTY buffer backpressures the shell, resumes on false. `HostSession` binds PTY↔transport (input→master, resize→`TIOCSWINSZ`, ack, exit); **session survives client disconnect** — `HostTransport` rebinds fresh channels onto the same `HostSessionTransport`+`ReplayBuffer` and replays in place (not re-yielded on `sessions_`), the daemon never kills the shell on channel failure. `HostServer` owns `HostTransport`, spawns a curated-env login shell per NEW session (keep-alive policy default; `TERM=xterm-256color` placeholder // TODO(WF-7)). `rwork-hostd` parses `--port`/`--shell`, binds 0.0.0.0/OS-chosen, logs to stderr, runs to SIGINT (smoke-verified: binds + clean shutdown). `swift build`+`swift test` green (74 tests total, +13 host: PTY round-trip/echo/controlling-tty/resize/exit-code/O_NONBLOCK + backpressure gate + transport drain transitions; 0 failures, warning-clean, stable over 5 full runs). No `@unchecked Sendable` over unguarded mutable state (every one guards an `NSLock`/`NSCondition`). WF-2 public APIs unchanged.
- **WF-3 review** · ✅ green · addressed host PTY/relay/session review: **(fd hygiene)** master fd was leaked on every spawn — added `PTYProcess.closeMaster()` (idempotent) + `deinit` safety net, called from `HostSession.shutdown()` *after* stopping the read loop (so no `read()` races the close); regression test spawns+shuts 40 sessions and asserts ~0 open-fd delta (was +40). **(output ordering — the load-bearing fix)** the relay bridged each PTY chunk onto the transport actor via a fresh detached `Task` per chunk, which does NOT preserve order (independent tasks hop onto the actor in scheduler order, not creation order) → scrambled seq assignment corrupting both the live stream and the replayed tail; replaced with a single ordered FIFO `AsyncStream<Data>` whose one consumer awaits `sendOutput` sequentially (actor-arrival order == read order). New `RelayOrderingTests` drives the real relay with a 20k-line burst and asserts a perfect contiguous run — **empirically confirmed it FAILS on the old per-chunk-Task bridge and PASSES on the FIFO** (test is regression-meaningful, not vacuous). `resume()`'s ascending-seq replay is now correct as written (no change there). **(missed-exit on reconnect)** `sendExit` now records the exit code and is gated behind `isResuming`; `resume()` re-sends it after the tail flush so a client offline when the shell exits still gets the terminal marker (no "zombie session"); offline `sendExit` records-not-throws. **(spawn-failure leak)** added `HostTransport.dropSession(_:)` + `HostSessionTransport.close()` (cancels forwarders, closes channels, finishes inbound streams); `HostServer` calls it on `pty.spawn()` failure so the already-bound+published session is torn down instead of orphaned with live channels. **(test coverage)** strengthened `testControllingTTY` to exercise `/dev/tty` (`tty </dev/tty; stty size </dev/tty`) — empirically proven regression-meaningful for `POSIX_SPAWN_SETSID` (WITH setsid → `/dev/tty`+`40 132`; WITHOUT → `Device not configured`), where the old fd-0 form passed even with setsid broken; added a WIFSIGNALED test (self-`SIGTERM` → 143). `swift build`+`swift test` green (81 tests, +7; 0 failures, warning-clean, stable over 3 full runs). WF-1/WF-2 public APIs unchanged; only additive new public methods (`closeMaster`, `HostSessionTransport.close`, `HostTransport.dropSession`). No wire-format change → `docs/20` unchanged.
