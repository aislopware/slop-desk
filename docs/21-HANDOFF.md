# 21 — Handoff (honest end-of-autonomous-build status)

> **STATUS: CURRENT.** This is the truthful wake-up picture after the autonomous build of
> **Rwork** (WF-1 … WF-9, consolidated in WF-10). It states what is COMPLETE + tested
> headlessly vs. what is COMPILED + reviewed but **not run** (and why), the one external
> blocker, the verify-on-hardware checklist, the priority-ordered next steps, and the honest
> caveats. Source of truth for the per-workflow narrative is
> [`19-implementation-plan.md`](19-implementation-plan.md); the wire contract is
> [`20-wire-protocol.md`](20-wire-protocol.md); the architecture + decisions are
> [`00-overview.md`](00-overview.md) / [`DECISIONS.md`](DECISIONS.md).

## Headline

- **278 tests pass, 0 failures**, warning-clean, stable across **3/3** full `swift test`
  runs (~17.8s each) on Swift 6.3.2 / Xcode 26.5 / arm64 / macOS 26.5.
- **22 SwiftPM targets** (12 libraries + 2 executables + 8 test targets), ~17.6k Swift LOC.
- **PATH 1 (terminal) is a working end-to-end system** today over TCP (loopback or NetBird):
  `rwork-hostd` + `rwork-client` echo + byte-exact reconnect, proven with real components
  and real shipped binaries.
- **One external blocker:** the libghostty xcframework cannot compile on this macOS-26.5 host
  (Zig ↔ SDK pincer). Everything else is either tested headlessly or compiled+reviewed and
  gated only on hardware/TCC/a device.

## Per-layer status

### COMPLETE + tested headlessly (unit / integration)

| Layer | Target(s) | Tests | Commit |
|-------|-----------|-------|--------|
| Wire protocol — framing, dual-channel `WireMessage`, streaming `FrameDecoder`, BE/Int64 seq, decode error paths | `RworkProtocol` | 32 (cumulative) | `c4a8ce9`, review `2e7eddb` |
| Transport — `TCP_NODELAY` dual channel, pure `ReplayBuffer` (never-drop, 4 MiB gate / 64 MiB cap), server-decides handshake, association preamble, atomic resume+replay | `RworkTransport` | 63 (cumulative) | `4f77686`, review `66bd20a` |
| **Reconnect hardening** — fixed the resume-rebind race: dead-channel send is `ECANCELED`→`notConnected`→**retain-not-throw** (bytes re-sent from replay buffer), gate on new-channel readiness, client clean-FIN→reconnect. Verified `HandshakeReconnectTests` **100/100** consecutive. | `RworkTransport` | 96 (cumulative) | `4288535` |
| Host PTY — `openpty`+`posix_spawn(SETSID)` (controlling-tty implicit, no `TIOCSCTTY`), no-buffer relay (ordered FIFO, QoS user-interactive), `TIOCSWINSZ`, exit reaper, fd hygiene, **session survives client disconnect**, **host-side OSC/BEL title/bell sniffer** (`HostTitleBellSniffer`, non-destructive observer on the output relay — **now the producer of wire types 21/22**) | `RworkHost` | 74 → 81 (cumulative) | `4f837bb`, review `1dae0e3` |
| E2E byte pipeline + interactive CLI — `RworkClient` (gap-free/dup-free output, capped-backoff reconnect, iOS pause/resume), `RworkTTY` raw-mode save/restore, `rwork-client` (raw relay, `Ctrl-]` disconnect, `--no-raw` pipe). **Crown-jewel e2e uses REAL components:** in-process echo over loopback; **byte-exact reconnect resume** (force-drop → reconnect → reconstructed stream == `1..2000` once each, in order); subprocess e2e launches the actual shipped `rwork-hostd` + `rwork-client`. | `RworkClient`, `RworkTTY`, `rwork-hostd`, `rwork-client` | 93 (cumulative) | `d268f9b`, review `2d50f49` |
| Read-only inspector — tolerant JSONL parse (unknown/malformed never crash), typed event taxonomy, tool-card pairing (out-of-order/missing/error + dedup), append-follow tailer (`LineAccumulator` holds partial line / resets on truncation), subagent tree, 2nd-channel (`NWConnection #2`) JSON transport, SwiftUI views (logic-free) | `RworkInspector` | 128 (cumulative; +32) | `7d08b5a`, review `569ff45` |
| Claude Code integration **logic** — curated launch env (forced/inherited disjoint sets), **stat-only** auth resolver (cannot read the credential file by construction), terminal-mode sniffer (split-robust at every chunk size), input dedup ring (hold-and-confirm), input-box A/B1 model | `RworkClaudeCode`, `RworkHost` (env/auth seam) | 181 (cumulative; +53) | `465fb19`, review `c1fda4d` |
| Client-UI logic — `TerminalViewModel`/`ConnectionViewModel`/`InputBarModel` state transitions, **events multicast fix** (`EventBroadcaster` tee — three concurrent consumers no longer steal events), iOS table-stakes pure logic (key-repeat cadence via injected scheduler, floating-cursor delta→arrow, accessory-bar decision, IME routing). `ConnectionViewModel` driven against a **real in-process HostServer + RworkClient over loopback**. KeyRepeater race fixed + **TSan-clean**. | `RworkClientUI` | 228 → 231 (cumulative; +41 / +3) | `bbff449`, review `517eb45` |
| Video protocol — packetize/reassemble (single/multi-fragment, reorder, dup), **fragment-loss → drop + recovery signalled**, **FEC real single-loss recovery** (XOR parity, byte-exact across differently-sized fragments), cursor codec (<64 B), coordinate mapping (multi-monitor Cocoa-flip + Retina), window-geometry + input-event codecs, NALU defensive parse | `RworkVideoProtocol` | 275 (cumulative; +44) | `1db2f5b`, review `51a8cab` |

All counts are cumulative full-suite totals at that workflow's completion. The final suite is
**278** (the +3 over WF-9's 275 are the small consolidation/stability deltas absorbed by the
existing suites — re-verified 3/3 in WF-10).

### COMPILED + reviewed but NOT RUN (and why)

These targets build cleanly (`swift build`, including the iOS triple) and were code-reviewed,
but are **deliberately never executed in a test** — they require a window-server + TCC session
or a real device/simulator that a headless run does not have.

| Layer | Target | Why not run |
|-------|--------|-------------|
| GUI **capture + HW encode** + input injection | `RworkVideoHost` | `SCStream` capture **and** `VTCompressionSession` HW encode **HANG** without a window-server + Screen-Recording TCC session — measured in [`research/spikes/vtbench/RESULTS.md`](research/spikes/vtbench/RESULTS.md) ("encode HW VideoToolbox **TREO khi chạy qua SSH**"). No test imports ScreenCaptureKit/VideoToolbox/Metal (verified by grep of `Tests/`). |
| GUI **decode + Metal render** + client cursor | `RworkVideoClient` | Decode is MEASURED-safe (~0.9–1.1 ms synchronous), but to honour the same hang-safety rule no `VTDecompressionSession`/Metal device is instantiated in tests. |
| SwiftUI / Metal terminal + video **views** | `RworkClientUI` (`GhosttyTerminalView`, `VideoWindowView`), `RworkVideoClient` (`MetalVideoRenderer`) | Render seams; need a GUI app target + (terminal) the libghostty xcframework. Logic behind them is tested; the views themselves only lay out. |
| iOS UIKit **table-stakes** wrappers | `RworkClientUI` (`KeyRepeater` host, `KeyboardAccessoryBar`, `IMEProxyTextView`, `FloatingCursorController`) | Logic is pure + macOS-unit-tested + iOS-triple-typechecked, but the `UIResponder`/`UIView` glue (presses→repeater, `inputAccessoryView` host, IME consumer, floating-cursor caller) needs a device/simulator — it is iOS-only view glue, not unit-testable on macOS. **Integration PENDING.** |
| libghostty terminal renderer | `GhosttySurface` (under `ThirdParty/ghostty/integration/`) | Needs the xcframework — the one external blocker below. Wired into no `Package.swift` target by design, so the headless core never depends on it. |

## The one external blocker — libghostty xcframework

The renderer binding is done; the **xcframework compile is blocked on this macOS-26.5 host**
by a Zig ↔ SDK pincer (both jaws characterized empirically):

1. Pinned **Zig 0.15.2** (the fork `daiimus/ghostty @ ios-external-backend`,
   SHA `21c717340b62349d67124446c2447bf38796540b`, requires 0.15.2) **cannot link the
   macOS 26.5 SDK** — even a trivial `zig run` errors `undefined symbol:
   __availability_version_check` / `_abort` / `_bzero` (0.15.2 predates the 26.x libSystem
   availability layout; `--sysroot`/`-lc` don't help).
2. **Zig 0.16.0** (the only Zig that links the 26.5 SDK here) is **rejected by the fork's
   `build.zig`** — a hard `requireZig` version gate **and** `std.process.EnvMap` was
   removed/renamed after 0.15.2 so `src/build/Config.zig` no longer compiles.

**Precise path to resolve** (any one):
- Run `ThirdParty/ghostty/build-libghostty.sh` on a host with a **≤ 15.x SDK** (an Xcode 16
  Command Line Tools install, or a CI runner image) that Zig 0.15.2 supports; **or**
- a future Zig that supports **both** the macOS 26.x SDK and the fork's `build.zig` (bump the
  `ZIG_*` pins in the script, re-verify the header symbols); **or**
- bump the **fork pin** to a daiimus/own SHA whose `build.zig` accepts a macOS-26-capable Zig
  (re-confirm the external-IO symbols `ghostty_surface_write_output` etc. after the bump).

The script preflights this exact condition (a libSystem link smoke test) and fails fast with
the actionable message. Full detail: [`../ThirdParty/ghostty/README.md`](../ThirdParty/ghostty/README.md).

## How to verify it works for real on hardware

1. **Build libghostty** on a compatible host (≤ 15.x SDK / CI) → produces
   `ThirdParty/ghostty/libghostty.xcframework`.
2. **Two-machine terminal test over NetBird.** Run `rwork-hostd --port 7420` on the host
   machine; run `rwork-client --host <netbird-ip> --port 7420` on the M2 Pro client. Confirm
   interactive shell + `Claude Code`, then kill/restart the client and confirm byte-exact
   resume. (App-level echo over the live NetBird mesh measured ~9 ms typical / ~18 ms p99 in
   the spikes — feels-local.)
3. **Wire `GhosttySurface` into the macOS client app** via
   `RworkClientUI.TerminalRendererFactory.shared` (see `Apps/Shared/AppMain.swift`) so the
   client renders with libghostty instead of the build-status placeholder.
4. **Grant TCC for the GUI video path** on the host: **Screen Recording** (capture),
   **Accessibility** + **Post Event** (input injection). Then exercise `RworkVideoHost`
   capture/encode → `RworkVideoClient` decode/render for a GUI window. (Run capture/encode
   from a real GUI session, **not** SSH — they hang without a window-server session.)
5. **Run the iOS client on a device/simulator** to exercise the UIKit input layer
   (`KeyRepeater` / `KeyboardAccessoryBar` / `IMEProxyTextView` / `FloatingCursorController`)
   that is currently logic-only.

## Recommended next steps (priority-ordered)

1. **Finish the libghostty build** on a ≤ 15.x-SDK host or CI (unblocks the only hard
   dependency).
2. **Wire the renderer into the client app** (`TerminalRendererFactory.shared = GhosttyTerminalView`).
3. **Real 2-machine terminal test over NetBird** (host ↔ M2 Pro client): interactive shell +
   Claude Code + reconnect — this validates the entire PATH 1 on hardware.
4. **GUI video path live test** (PATH 2): grant TCC, run capture/encode/decode/render for one
   GUI window from a real GUI session.
5. **iOS device pass** for the UIKit table-stakes glue.

## Honest known caveats (from the reviews / build log)

- **Video FEC is XOR single-loss parity, not Reed-Solomon.** `XORParityFEC` (groupSize 5 =
  20% parity) recovers exactly **one** lost fragment per group; two losses in a group are
  unrecoverable (surfaced as a dropped frame + recovery signal). `FECScheme` is a protocol so
  production can swap in Reed-Solomon — documented, not done.
- **CoT / thinking is placeholder-only.** The inspector renders `thinking:""` + signature as
  an `isPlaceholder` marker and **never fabricates** chain-of-thought content (load-bearing
  privacy choice, doc 16).
- **Auth is stat-only.** `ClaudeAuthResolver` takes a `(String)->Bool` existence predicate and
  has **no capability** to open/log/transmit `~/.claude/.credentials.json`; the spawned
  `claude` inherits it via `HOME`.
- **iOS UIKit table-stakes are logic-complete but not integrated** — no owning `UIResponder`
  routes presses to `KeyRepeater`, hosts the accessory bar, embeds the IME proxy, or drives
  the floating cursor yet. Follow-up view glue.
- **GUI video path is built to MEASURED spike configs, never executed.** The host capture +
  HW encode + the decoder/Metal renderer are compiled + reviewed only; SCKit/VideoToolbox hang
  headlessly (RESULTS.md). The 2-session encoder (Session A low-latency-RC live 12 Mbps /
  Session B `Quality=1.0` all-intra crisp — there is no `Lossless` HEVC key, it returns
  `-12900`) matches the spikes exactly.
- **`TERM=xterm-ghostty` carries the known multi-line-paste risk (#54700)** — mitigated by a
  first-class `.xterm256` toggle (`xterm-256color`, drops DEC 2026), not removed.
- **macOS-26 multi-NALU watch-item is downgraded, not ignored** — steady state emits 1 NALU
  per `CMSampleBuffer`, but NALUs are still iterated length-prefixed defensively.
- **No app-layer crypto / Mosh predictor — by design.** WireGuard encrypts; the replay buffer
  stores raw bytes (ET's `CryptoHandler` deliberately not ported). The opaque libghostty
  surface rules out a duplicate VT parser, so there is no full client-side predictor (only an
  optional glitch-caret was ever considered) — the measured ~9 ms echo makes it unnecessary.
- **One latent package-graph note (non-blocking):** addressed in WF-8 review by removing the
  inert `import RworkTerminal` from `RworkClient.swift` (the terminal surface is a closure
  seam by design); `swift build`/`swift test` are warning-clean.

## Build & verify

```sh
swift build                              # all 22 targets incl. both executables
swift test                               # 278 tests, 0 failures (~18s), warning-clean
.build/release/rwork-hostd --port 7420   # host (after swift build -c release)
.build/release/rwork-client --host <h> --port 7420   # interactive client; Ctrl-] to disconnect
```
