# 00 — Architecture Overview (read this first)

> **Read-first** document — gathers the entire current architecture + every settled decision, each point linking to the detailed doc. Decisions as a log: [DECISIONS.md](DECISIONS.md). Old codename "PaneCast" (from the screen-sharing era) — now a **remote-coding tool**, terminal-first.

## 1. What it is

> **Philosophy: build the BEST thing, no fallbacks** — libghostty-only (no SwiftTerm), no B2 SDK pane, cap fps at ~24–30 (GUI). Commit to one good choice; don't keep a plan B alive.

A **remote control/coding** app on Apple platforms (macOS host, macOS + iOS/iPadOS client), native Swift. **Use-case: daily coding** — running a shell + **Claude Code** remotely. NOT game-streaming. (Docs 01–11 were written under the old screen-sharing/video assumption → they are now **reference for the GUI video-path** or **superseded** — see [README](README.md).)

## 2. Architecture: 3 data paths

```
┌───────────── HOST (macOS, non-sandboxed) ─────────────┐
│  (1) TERMINAL PATH (primary)                          │
│      openpty + posix_spawn → shell / claude (PTY)     │
│        │ raw VT byte stream                           │
│  (3) INSPECTOR (read-only companion)                  │
│      tail JSONL transcript + hooks → typed events     │
│  (2) GUI VIDEO PATH (Phase 4)                         │
│      ScreenCaptureKit → VideoToolbox HEVC 4:2:0       │
└───────│──────────────│─────────────────│──────────────┘
        │ TCP          │ NWConn #2       │ UDP        (all via NetBird WireGuard P2P)
┌───────▼──────────────▼─────────────────▼──────────────┐
│  CLIENT (macOS / iOS / iPadOS)                        │
│  (1) libghostty surface (full TUI render) ← sends keys│
│  (3) SwiftUI read-only views (tool cards / subagent / │
│      todos / workflow / CoT-placeholder)              │
│  (2) VTDecompression → Metal (GUI window video)       │
└───────────────────────────────────────────────────────┘
```

- **(1) Terminal path (PRIMARY)** — full TUI fidelity. Host PTY ([12], [02]) → **plain TCP** over NetBird → **libghostty** client renderer ([12 §renderer]). This is the core.
- **(3) Read-only inspector (DIFFERENTIATOR)** — a companion for viewing things that are hard to read in scrollback (subagent content, tool I/O, todos, workflow). Data = **tailing the Claude Code JSONL transcript** + hooks → events over a **second NWConnection**. Read-only, so it avoids all the costs of driving the agent. ([16])
- **(2) GUI video path (Phase 4, secondary)** — only for GUI windows (VS Code/Xcode...). ScreenCaptureKit + VideoToolbox HEVC. ([01], [02], [04], [09])

## 3. Major decisions (summary — details in [DECISIONS.md](DECISIONS.md))

| Area | Decision | Doc |
|----------|-----------|-----|
| Use-case | Daily coding (Claude Code), not game-streaming | [12] |
| Network | **NetBird (WireGuard mesh), assume direct P2P**; relay = degraded (not engineered for) | [13] |
| Encryption | **None** at the app layer — WireGuard E2E + NetBird ACLs handle it | [13] |
| Terminal transport | **Plain TCP** (reliable; only buffering needed) | [13], [12] |
| Video transport | Plain UDP (QUIC dropped — WireGuard already encrypts) | [03] |
| Terminal renderer | **libghostty** full surface + **self-owned external-backend patch** (ref daiimus External.zig). **NO SwiftTerm** (best-only) | [12] |
| Host PTY | `openpty` + `posix_spawn(createSession)` (forkpty unsafe from Swift) | [12] |
| Claude Code TERM | **`xterm-ghostty`** (kitty kbd + DEC2026; accept the paste risk #54700 + a fallback toggle) | [14] |
| Claude Code fullscreen | `CLAUDE_CODE_NO_FLICKER=1` for the remote PTY | [14] |
| Auth | **Subscription OAuth + `setup-token`** (or reuse `~/.claude/.credentials.json`); NO custom PKCE | [14] |
| External input box | **A** (shell input box + block) **+ B1** (Claude Code keeps its TUI + overlay compose-box→PTY). **NO B2 SDK pane** (structured view = read-only inspector [16]) | [14] |
| Inspector | **Read-only**, data = JSONL transcript + hooks; **CoT = placeholder-only** | [16] |
| Codec (GUI path) | **HEVC Main 8-bit 4:2:0** + constant-quality (Apple Silicon); 10-bit optional. 4:4:4 dropped; AV1/VVC have no HW encode | [09] |
| Native-feel TUI | **`TCP_NODELAY`** (Nagle +200ms) + dual channel + ET replay-buffer reconnect; **NO full Mosh predictor** (opaque ghostty → duplicate parser; optional glitch-caret only) | [17] |
| Native-feel GUI | **Client-side cursor** (strip + UDP side-channel + composite at refresh → pointer=RTT) + **lossy-first→lossless-upgrade** (sharp text) + CADisplayLink pacing | [17] |
| Latency | Terminal path = network RTT (~1–5ms LAN-direct, no vsync). GUI path target **40–80ms** (coding); 120fps/floor-<16ms **dropped** | [11], [12] |
| Distribution | Host **non-sandboxed** (spawns shell + CGEvent) → Developer-ID + notarize, **outside MAS**; client viewer can be MAS | [06], [12] |
| Orchestration (herdr/agent-teams) | **Be a client**, don't build an orchestration product | [14], [15] |

## 4. Roadmap (details in [12 §Roadmap])
**P0** ⭐ **De-risk gate** — run every architecture-defining spike BEFORE building (don't park risk into later phases). *Mostly measured already on an M1 Max/macOS 26.5* ([18 §0]): F decode 1.1ms, G ~8–10 windows, low-latency-RC 7.5ms; remaining: D cursor-strip + echo (not gating). → **P1** Terminal MVP (host PTY → TCP → libghostty) + inspector P1 (tool cards/timeline/todos) → **P2** persistence/reconnect/clipboard + subagent tree → **P3** iOS client → **P4** GUI video path → **P5** polish.

> Most of the project's risk (macOS input injection — [05]/[08] R1/R2) **applies only to the GUI video-path (P4)**; the terminal path avoids it entirely (input = bytes → PTY stdin).

## 5. Further reading
- ⭐ **Best-solution synthesis (lowest latency + real-machine feel, TUI & GUI)** → [17](17-native-feel-synthesis.md) — OSS/commercial research, gap-analysis, open spikes
- ⭐ **Risk resolutions (how each risk is resolved + spike plan)** → [18](18-risk-resolutions.md) — 0 blockers; PATH 1 build-ready, PATH 2 gated on 3 light spikes
- Implementing the terminal path (P1) → [12](12-coding-profile.md) + [13](13-netbird-transport.md) + [14](14-claude-code-integration.md) + [16](16-readonly-inspector.md)
- Prior art (mobile/desktop apps for Claude Code) → [15](15-prior-art-happy-happier.md)
- GUI video path (P4) → [01](01-architecture.md) + [02](02-host-capture-encode.md) + [04](04-client-decode-render.md) + [05](05-input-window-control.md) + [09](09-codec-choice.md)
- Latency reference (GUI path) → [10](10-latency-optimization.md) + [11](11-absolute-latency.md)
