# SlopDesk — design docs

> Design docs for SlopDesk, a low-latency remote-coding tool for Apple platforms (macOS host;
> macOS + iOS/iPadOS clients). Client = infinite canvas of panes; each pane is a terminal
> (host PTY → TCP → libghostty) or a live GUI window (ScreenCaptureKit → VideoToolbox HEVC →
> UDP) — both first-class. Performance core is Rust (`rust/slopdesk-core`, behind a C ABI:
> wire codecs, FEC, realtime controllers, terminal protocol); shell is Swift/SwiftUI (capture,
> HW codec, Metal, input, UI). Older docs use the codename "PaneCast" and frame the terminal as
> the only path — since levelled (see [00-overview.md](00-overview.md)).
>
> Read first: [00-overview.md](00-overview.md) (architecture + every binding decision)
> · Decision log: [DECISIONS.md](DECISIONS.md)
> · Rust core: [`rust/README.md`](../rust/README.md) (codecs / FEC / controllers / terminal protocol behind the C ABI)

## Scope (settled)

| Item | Decision |
|------|----------|
| **Host** | macOS 26+ (Apple Silicon), **non-sandboxed** (spawns shells + CGEvent) |
| **Client** | macOS + iOS/iPadOS, native Swift/SwiftUI |
| **Use case** | Everyday coding (shell + Claude Code), not game streaming |
| **Network** | Plain TCP (terminal) + UDP (video), no app-layer crypto/auth. Assumes a trusted private network, typically a WireGuard mesh (e.g. NetBird/Tailscale) supplying encryption + node auth; the security boundary is the network. [13](13-network-transport.md) |
| **Data paths** | Two first-class pane transports plus a companion: **(1) Terminal:** host PTY → TCP → libghostty client. **(2) GUI window:** ScreenCaptureKit + VideoToolbox HEVC, RS-FEC + ABR + LTR, per-window UDP, 60 fps default. **(3) Inspector:** read-only Claude Code transcript tail |
| **Control** | Terminal: input bytes → PTY stdin (no injection). GUI window: activate-then-control + CGEvent |

Non-functional profile (coding, not gaming): terminal text is pixel-perfect by construction
(PTY → libghostty, never a codec); GUI path targets feels-local responsiveness at 60 fps
default (30 fps reads as stale on scroll/motion). Idle-skips when the screen is static rather
than burning a fixed frame budget — high fps on motion, ~0 bandwidth when static.

## Document index

> **Status:** `CURRENT` = current architecture · `REFERENCE` = GUI video path design depth
> · `SUPERSEDED` = kept as history.

### Read first
| File | Contents |
|------|----------|
| [00-overview.md](00-overview.md) | **Architecture overview** — 3 data paths + every decision, each linking to its detailed doc |
| [DECISIONS.md](DECISIONS.md) | **Decision log** — one line per decision + status + link |

### CURRENT — current architecture
| # | File | Contents |
|---|------|----------|
| 12 | [12-coding-profile.md](12-coding-profile.md) | Hybrid architecture + terminal-path design (host PTY, libghostty) + GUI video + roadmap |
| 13 | [13-network-transport.md](13-network-transport.md) | **Network model & transport assumptions** — trusted private network (WireGuard mesh, e.g. NetBird/Tailscale); plain TCP+UDP, no app-layer crypto; userspace-WG interface = `.other`; app-layer adaptive rate |
| 14 | [14-claude-code-integration.md](14-claude-code-integration.md) | Claude Code integration (TERM / fullscreen / auth, external input box A+B1) |
| 15 | [15-prior-art-happy-happier.md](15-prior-art-happy-happier.md) | Prior art: Happy/Happier (how they hook Claude Code) + lessons + pitfalls |
| 16 | [16-readonly-inspector.md](16-readonly-inspector.md) | **Read-only inspector** (differentiator): transcript tail → tool cards / subagent tree / todos |
| 17 | [17-native-feel-synthesis.md](17-native-feel-synthesis.md) | **Best-solution synthesis** from prior art (Mosh/ET/Parsec/Moonlight/Xpra…): native-feel techniques + gap analysis |
| 18 | [18-risk-resolutions.md](18-risk-resolutions.md) | **Risk resolutions** — verified solutions for 9 risks/spikes (threading, mapping, encoders, reconnect, security) |

### REFERENCE — GUI video path (design depth)
| # | File | Contents |
|---|------|----------|
| 01 | [01-architecture.md](01-architecture.md) | Video pipeline architecture + latency budget |
| 02 | [02-host-capture-encode.md](02-host-capture-encode.md) | Window capture (ScreenCaptureKit) + encode (VideoToolbox) |
| 03 | [03-transport-protocol.md](03-transport-protocol.md) | Video transport (UDP), packet format, loss handling (network model per [13]) |
| 04 | [04-client-decode-render.md](04-client-decode-render.md) | Decode (VideoToolbox) + render (Metal / AVSampleBufferDisplayLayer) |
| 05 | [05-input-window-control.md](05-input-window-control.md) | GUI input injection, window raise, Accessibility |
| 06 | [06-permissions-distribution.md](06-permissions-distribution.md) | TCC permissions, sandbox, signing & notarization |
| 09 | [09-codec-choice.md](09-codec-choice.md) | Codec choice (HEVC 4:2:0/8-bit vs AV1/VVC/ProRes), chroma, bitrate |
| 10 | [10-latency-optimization.md](10-latency-optimization.md) | Latency techniques (Parsec/Moonlight/Sunshine): LTR, pacing, client-side cursor |
| 11 | [11-absolute-latency.md](11-absolute-latency.md) | Deep latency-floor research + API corrections + spike checklist |

### SUPERSEDED
| # | File | Note |
|---|------|------|
| 07 | [07-roadmap.md](07-roadmap.md) | Old video-first roadmap — superseded by [12 §Roadmap] / [00] |
| 08 | [08-risks-open-questions.md](08-risks-open-questions.md) | Risks/open questions (mostly GUI path; many resolved — see [DECISIONS.md]) |

### Reference — protocol & workspace
| # | File | Contents |
|---|------|----------|
| 20 | [20-wire-protocol.md](20-wire-protocol.md) | Terminal-path wire protocol |
| 22 | [22-workspace-architecture.md](22-workspace-architecture.md) | Workspace / multi-pane architecture |
| 30 | [30-infinite-canvas.md](30-infinite-canvas.md) | Infinite-canvas pane workspace |

### Historical session logs (19, 21, 23–29, 31–39)
> Dated build / handoff / round logs — kept as history, not current architecture.

| # | File | Note |
|---|------|------|
| 19 | [19-implementation-plan.md](19-implementation-plan.md) | Build log + phase status |
| 21 | [21-HANDOFF.md](21-HANDOFF.md) | End-of-build status + hardware-verification checklist |
| 23 | [23-workspace-ui-handoff.md](23-workspace-ui-handoff.md) | Workspace UI handoff |
| 24 | [24-hardening-handoff.md](24-hardening-handoff.md) | Hardening round |
| 25–29 | [25](25-overnight-handoff.md) · [26](26-RESEARCH-OPTIMIZATIONS.md) · [27](27-NIGHT-HANDOFF.md) · [28](28-NIGHT-HANDOFF.md) · [29](29-NIGHT-HANDOFF.md) | Overnight handoffs + research-driven optimizations |
| 31 | [31-TERMINAL-SMOOTHNESS-HANDOFF.md](31-TERMINAL-SMOOTHNESS-HANDOFF.md) | Terminal smoothness round |
| 32 | [32-BORDERLESS-CANVAS-UIUX.md](32-BORDERLESS-CANVAS-UIUX.md) | Borderless canvas UI/UX |
| 33 | [33-UIUX-FEATURES-ROUND.md](33-UIUX-FEATURES-ROUND.md) | UI/UX features round |
| 34 | [34-FEATURES-ROUND-2026-06-13.md](34-FEATURES-ROUND-2026-06-13.md) | Features round |
| 35 | [35-NON-OVERLAP-LAYOUT.md](35-NON-OVERLAP-LAYOUT.md) | Non-overlap layout |
| 36 | [36-UIUX-DX-ROUND-2026-06-13.md](36-UIUX-DX-ROUND-2026-06-13.md) | UI/UX + DX round |
| 37 | [37-BUGHUNT-DX-ROUND-2026-06-13.md](37-BUGHUNT-DX-ROUND-2026-06-13.md) | Bug-hunt + DX round |
| 38 | [38-FEATURES-DX-ROUND-2026-06-13.md](38-FEATURES-DX-ROUND-2026-06-13.md) | Features + DX round |
| 39 | [39-MEDLOW-HUNT-ROUND-2026-06-13.md](39-MEDLOW-HUNT-ROUND-2026-06-13.md) | Med/Low bug-hunt round |

## Reading paths by role
- **Understand the architecture** → [00](00-overview.md) (+ [DECISIONS.md](DECISIONS.md))
- **Terminal panes** → [00](00-overview.md) → [17](17-native-feel-synthesis.md) → [18](18-risk-resolutions.md) → [12](12-coding-profile.md) → [13](13-network-transport.md) → [14](14-claude-code-integration.md) → [16](16-readonly-inspector.md)
- **GUI-window panes** → [01](01-architecture.md) + [02](02-host-capture-encode.md) + [04](04-client-decode-render.md) + [05](05-input-window-control.md) + [09](09-codec-choice.md)
- **Latency work (GUI path)** → [10](10-latency-optimization.md) + [11](11-absolute-latency.md)
- **Workspace / canvas** → [22](22-workspace-architecture.md) + [30](30-infinite-canvas.md)

## Glossary

| Term | Meaning |
|------|---------|
| **PTY** | Pseudo-terminal master/slave fd pair; host runs the shell in a PTY and relays the master fd |
| **TUI** | Full-screen terminal app (vim, Claude Code interactive) |
| **libghostty** | Ghostty's terminal engine (C ABI) — the client renderer |
| **alt-screen** | Alternate screen buffer (DECSET 1049) — a TUI taking the whole screen |
| **JSONL transcript** | Claude Code's per-line JSON log — the inspector's data source |
| **A+B1** | External input box: A = shell input box, B1 = overlay → PTY (structured view = read-only inspector) |
| **`TCP_NODELAY`** | Disables Nagle — mandatory on the terminal path, else keystrokes batch +200 ms |
| **ET replay buffer** | Eternal Terminal-style seq-numbered ring for lossless reconnect (replaces tmux) |
| **Client-side cursor** | Strip cursor from video, send position on a side channel, draw on client → pointer latency = RTT |
| **NV12** | `420YpCbCr8BiPlanarVideoRange` — zero-copy capture → VideoToolbox pixel format |
| **LTR** | Long-Term Reference frame — loss recovery without a forced IDR |
| **Glass-to-glass** | Latency from pixel change on host to display on client |
| **TCC / AX** | macOS permission system / Accessibility API |
