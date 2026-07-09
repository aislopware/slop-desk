# 00 — Architecture Overview (read this first)

> **Read-first** document — the entire current architecture + every settled decision, each point linking to its detailed doc. Decision log: [DECISIONS.md](DECISIONS.md). Old codename "PaneCast" (screen-sharing era); now a remote-coding tool whose client is a unified canvas of terminal and GUI-window panes.

## 1. What it is

> **Philosophy: commit to one good choice per problem.** One renderer (libghostty), one structured view (the read-only inspector), one native-Swift core that owns the wire. Where there is a real choice the design picks it and proves it, rather than shipping fallbacks.

A remote-coding app for Apple platforms (macOS host, macOS + iOS/iPadOS client), native Swift/SwiftUI; build floor macOS 26 / iOS 26, developed on Apple Silicon. Use-case: daily coding — running a shell and Claude Code on a remote machine and driving it from another device. Not game-streaming.

The client is a coding workspace: **Session → Tab → n-ary split panes**. A pane is either a **terminal** (host PTY → TCP → libghostty) or a **GUI window** (ScreenCaptureKit → HEVC → UDP). Both are first-class; transport is chosen per pane. (Docs 01–11 = GUI video design depth; free-floating canvas design is historical — [30](30-infinite-canvas.md).)

## 2. Architecture: two pane transports + a companion

The canvas holds panes; each streams over the transport its content needs (terminal text over TCP, GUI video over UDP), with the inspector alongside as a read-only companion. Three independent transports, sharing no sockets, message set, or version.

```
┌───────────── HOST (macOS, non-sandboxed) ─────────────┐
│  TERMINAL pane                                        │
│      openpty + posix_spawn → shell / claude (PTY)     │
│        │ raw VT byte stream                           │
│  GUI-WINDOW pane                                      │
│      ScreenCaptureKit → VideoToolbox HEVC 4:2:0       │
│  INSPECTOR (read-only companion)                      │
│      tail JSONL transcript + hooks → typed events     │
└───────│──────────────│─────────────────│──────────────┘
        │ TCP          │ UDP             │ NWConn #2   (over a trusted private mesh, e.g. WireGuard)
┌───────▼──────────────▼─────────────────▼──────────────┐
│  CLIENT (macOS / iOS / iPadOS) — session/tab/split workspace │
│  libghostty surface (full TUI render) ← sends keys    │
│  VTDecompression → Metal (GUI window video) ← input   │
│  SwiftUI read-only views (tool cards / subagent /     │
│      todos / workflow / CoT-placeholder)              │
└───────────────────────────────────────────────────────┘
```

- **Terminal panes** — full TUI fidelity, pixel-perfect text. Host PTY ([12], [02]) → plain TCP (on a trusted private network) → libghostty client renderer ([12 §renderer]).
- **GUI-window panes** — a single host window (VS Code, Xcode, a browser…). ScreenCaptureKit → VideoToolbox HEVC over plain UDP, with RS-FEC, ABR/congestion control, a client-side cursor, and LTR recovery; 60 fps with idle-skip. ([01], [02], [04], [09])
- **Read-only inspector** (the differentiator) — a companion for content awkward to read in scrollback (subagent transcripts, tool I/O, todos, workflow). Data = tailing the Claude Code JSONL transcript + hooks → events over a second NWConnection. Read-only, so it avoids every cost of driving the agent. ([16])

### Core / shell split
**Native Swift** owns the wire: codecs, FEC + reassembly, realtime controllers, coordinate mapping, terminal/PTY protocol (channel mux + flow control). Frozen by `golden/golden_vectors.json`. Only non-Swift code: `Sources/CSlopDeskSIMD` (one GF(2⁸) NEON kernel + scalar fallback). Platform shell is Swift/SwiftUI — ScreenCaptureKit, VideoToolbox, Metal, input, PTY, UI.

## 3. Major decisions (summary — details in [DECISIONS.md](DECISIONS.md))

| Area | Decision | Doc |
|----------|-----------|-----|
| Use-case | Daily coding (Claude Code), not game-streaming | [12] |
| Network | **Trusted private network** (WireGuard mesh, e.g. NetBird/Tailscale); security boundary = the network, not the app | [13] |
| Encryption | **None at the app layer** — the mesh provides E2E encryption + node auth + per-port ACLs | [13] |
| Terminal transport | **Plain TCP** (reliable; only buffering needed) | [13], [12] |
| Video transport | Plain UDP (QUIC dropped — WireGuard already encrypts) | [03] |
| Terminal renderer | **libghostty** full surface + **self-owned external-backend patch** (ref daiimus External.zig) | [12] |
| Host PTY | `openpty` + `posix_spawn(createSession)` (forkpty unsafe from Swift) | [12] |
| Claude Code TERM | **`xterm-ghostty`** (kitty kbd + DEC2026; accept the paste risk #54700 + a fallback toggle) | [14] |
| Claude Code fullscreen | `CLAUDE_CODE_NO_FLICKER=1` for the remote PTY | [14] |
| Auth | **Subscription OAuth + `setup-token`** (or reuse `~/.claude/.credentials.json`); NO custom PKCE | [14] |
| External input box | **A** (shell input box + block) **+ B1** (Claude Code keeps its TUI + overlay compose-box→PTY); structured view = read-only inspector [16] | [14] |
| Inspector | **Read-only**, data = JSONL transcript + hooks; **CoT = placeholder-only** | [16] |
| Codec (GUI path) | **HEVC Main 8-bit 4:2:0** + constant-quality (Apple Silicon); 10-bit optional. 4:4:4 dropped; AV1/VVC have no HW encode | [09] |
| FEC (GUI path) | **Reed–Solomon over GF(2⁸)** (NEON-accelerated), `m=1` byte-identical to the old XOR, `m≥2` multi-loss recovery | [03], [17] |
| Native-feel TUI | **`TCP_NODELAY`** (Nagle +200ms) + dual channel + ET replay-buffer reconnect; **NO full Mosh predictor** (opaque ghostty → duplicate parser; optional glitch-caret only) | [17] |
| Native-feel GUI | **Client-side cursor** (strip + UDP side-channel + composite at refresh → pointer=RTT) + deadline presentation pacer + adaptive playout | [17] |
| FPS / latency | Terminal panes = network RTT (~1–5ms LAN-direct, no vsync). GUI panes run **60 fps with idle-skip** (30 fps reads as stale on scroll/motion) and target feels-local glass-to-glass; the 120fps/ProMotion/beam-racing floor-chasing from [11] stays out of scope as over-engineering for coding | [11], [12] |
| Distribution | Host **non-sandboxed** (spawns shell + CGEvent) → Developer-ID + notarize, **outside MAS**; client viewer can be MAS | [06], [12] |
| Orchestration (herdr/agent-teams) | **Be a client**, don't build an orchestration product | [14], [15] |

## 4. How it was built
De-risk-first: architecture spikes measured before production ([18](18-risk-resolutions.md): decode 1.1ms, multi-window encode, low-latency RC, cursor-strip). Terminal path, inspector, reconnect, iOS client, GUI video, and Session→Tab→split workspace all shipped. Build logs: docs 19, 21–39 (history).

> The project's hardest risk (macOS input injection — [05]/[08] R1/R2) lives entirely on the
> GUI-window path; terminal panes sidestep it (input = bytes → PTY stdin).

## 5. Further reading
- ⭐ **Best-solution synthesis (lowest latency + real-machine feel, TUI & GUI)** → [17](17-native-feel-synthesis.md) — OSS/commercial research, gap-analysis, techniques
- ⭐ **Risk resolutions (how each risk was resolved + measurements)** → [18](18-risk-resolutions.md)
- Terminal panes → [12](12-coding-profile.md) + [13](13-network-transport.md) + [14](14-claude-code-integration.md) + [16](16-readonly-inspector.md)
- Prior art (mobile/desktop apps for Claude Code) → [15](15-prior-art-happy-happier.md)
- GUI-window panes → [01](01-architecture.md) + [02](02-host-capture-encode.md) + [04](04-client-decode-render.md) + [05](05-input-window-control.md) + [09](09-codec-choice.md)
- Workspace → [22](22-workspace-architecture.md) (canvas era: [30](30-infinite-canvas.md), historical)
- Latency reference (GUI path) → [10](10-latency-optimization.md) + [11](11-absolute-latency.md)
