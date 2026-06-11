# Aislopdesk — design docs

> Technical design docs for **Aislopdesk**, a terminal-first remote-coding tool for Apple
> platforms (macOS host, macOS + iOS/iPadOS clients, native Swift). Some docs use the legacy
> codename "PaneCast" from the early screen-sharing idea.
>
> 👉 **Read first: [00-overview.md](00-overview.md)** (architecture + every binding decision)
> · **Decision log: [DECISIONS.md](DECISIONS.md)**

## Scope (settled)

| Item | Decision |
|------|----------|
| **Host** | macOS 14+ (Apple Silicon), **non-sandboxed** (spawns shells + CGEvent) |
| **Client** | macOS + iOS/iPadOS, native Swift |
| **Use case** | **Everyday coding** (shell + Claude Code) — NOT game streaming |
| **Network** | **NetBird mesh (WireGuard), assumes direct P2P** (~5–20 ms). Relay = degraded (warn only). Encryption + auth live in the VPN layer → no app-layer crypto. [13](13-netbird-transport.md) |
| **Data paths** | **(1) Terminal (primary):** host PTY → TCP → libghostty client. **(2) GUI video (Phase 4):** ScreenCaptureKit + VideoToolbox, per-window. **(3) Inspector:** read-only Claude Code transcript tail |
| **Control** | Terminal: input bytes → PTY stdin (no input injection). GUI window: activate-then-control + CGEvent (Phase 4) |

Non-functional profile (coding, not gaming): terminal text is pixel-perfect by construction
(PTY → libghostty, never through a codec); input responsiveness matters but ~40–80 ms
motion-to-photon is acceptable; fps is not a goal (mostly-static screens).

## Document index

> **Status:** `CURRENT` = current architecture · `REFERENCE` = GUI video path only (Phase 4)
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
| 13 | [13-netbird-transport.md](13-netbird-transport.md) | NetBird (WireGuard mesh) networking: no app-layer crypto, utun=`.other`, direct vs relayed |
| 14 | [14-claude-code-integration.md](14-claude-code-integration.md) | Claude Code integration (TERM / fullscreen / auth, external input box A+B1) |
| 16 | [16-readonly-inspector.md](16-readonly-inspector.md) | **Read-only inspector** (differentiator): transcript tail → tool cards / subagent tree / todos |
| 17 | [17-native-feel-synthesis.md](17-native-feel-synthesis.md) | **Best-solution synthesis** from prior art (Mosh/ET/Parsec/Moonlight/Xpra…): native-feel techniques + gap analysis |
| 18 | [18-risk-resolutions.md](18-risk-resolutions.md) | **Risk resolutions** — verified solutions for 9 risks/spikes (threading, mapping, encoders, reconnect, security) |
| 15 | [15-prior-art-happy-happier.md](15-prior-art-happy-happier.md) | Prior art: Happy/Happier (how they hook Claude Code) + lessons + pitfalls |

### REFERENCE — GUI video path (Phase 4)
| # | File | Contents |
|---|------|----------|
| 01 | [01-architecture.md](01-architecture.md) | Video pipeline architecture + latency budget |
| 02 | [02-host-capture-encode.md](02-host-capture-encode.md) | Window capture (ScreenCaptureKit) + encode (VideoToolbox) |
| 04 | [04-client-decode-render.md](04-client-decode-render.md) | Decode (VideoToolbox) + render (Metal / AVSampleBufferDisplayLayer) |
| 05 | [05-input-window-control.md](05-input-window-control.md) | GUI input injection, window raise, Accessibility |
| 09 | [09-codec-choice.md](09-codec-choice.md) | Codec choice (HEVC 4:2:0/8-bit vs AV1/VVC/ProRes), chroma, bitrate |
| 10 | [10-latency-optimization.md](10-latency-optimization.md) | Latency techniques (Parsec/Moonlight/Sunshine): LTR, pacing, client-side cursor |
| 11 | [11-absolute-latency.md](11-absolute-latency.md) | Deep latency-floor research + API corrections + Phase-0 spike checklist |
| 03 | [03-transport-protocol.md](03-transport-protocol.md) | Video transport (UDP), packet format, loss handling (NetBird overrides — [13]) |
| 06 | [06-permissions-distribution.md](06-permissions-distribution.md) | TCC permissions, sandbox, signing & notarization |

### SUPERSEDED
| # | File | Note |
|---|------|------|
| 07 | [07-roadmap.md](07-roadmap.md) | Old video-first roadmap — superseded by [12 §Roadmap] / [00] |
| 08 | [08-risks-open-questions.md](08-risks-open-questions.md) | Risks/open questions (mostly GUI path; many resolved — see [DECISIONS.md]) |

### Implementation logs & handoffs (19–30)
| # | File | Contents |
|---|------|----------|
| 19 | [19-implementation-plan.md](19-implementation-plan.md) | Build log + phase status (source of truth) |
| 20 | [20-wire-protocol.md](20-wire-protocol.md) | Terminal-path wire protocol |
| 21 | [21-HANDOFF.md](21-HANDOFF.md) | End-of-build status + hardware verification checklist |
| 22 | [22-workspace-architecture.md](22-workspace-architecture.md) | Workspace / multi-pane architecture |
| 23 | [23-workspace-ui-handoff.md](23-workspace-ui-handoff.md) | Workspace UI handoff |
| 24 | [24-hardening-handoff.md](24-hardening-handoff.md) | Hardening-round handoff |
| 25–29 | [25](25-overnight-handoff.md) · [26](26-RESEARCH-OPTIMIZATIONS.md) · [27](27-NIGHT-HANDOFF.md) · [28](28-NIGHT-HANDOFF.md) · [29](29-NIGHT-HANDOFF.md) | Overnight work-session handoffs + research-driven optimizations |
| 30 | [30-infinite-canvas.md](30-infinite-canvas.md) | Infinite-canvas pane workspace |

## Reading paths by role
- **Understand the architecture** → [00](00-overview.md) (+ [DECISIONS.md](DECISIONS.md))
- **Terminal path (Phase 1)** → [00](00-overview.md) → [17](17-native-feel-synthesis.md) → [18](18-risk-resolutions.md) → [12](12-coding-profile.md) → [13](13-netbird-transport.md) → [14](14-claude-code-integration.md) → [16](16-readonly-inspector.md)
- **GUI video path (Phase 4)** → [01](01-architecture.md) + [02](02-host-capture-encode.md) + [04](04-client-decode-render.md) + [05](05-input-window-control.md) + [09](09-codec-choice.md)
- **Latency work (GUI path)** → [10](10-latency-optimization.md) + [11](11-absolute-latency.md)

## Glossary

| Term | Meaning |
|------|---------|
| **PTY** | Pseudo-terminal master/slave fd pair; the host runs the shell in a PTY and relays the master fd |
| **TUI** | Full-screen terminal app (vim, Claude Code interactive) |
| **libghostty** | Ghostty's terminal engine (C ABI) — the client renderer |
| **alt-screen** | Alternate screen buffer (DECSET 1049) — a TUI taking the whole screen |
| **JSONL transcript** | Claude Code's per-line JSON log — the inspector's data source |
| **A+B1** | External input box: A = shell input box, B1 = overlay → PTY (no B2 SDK pane; structured view = read-only inspector) |
| **`TCP_NODELAY`** | Disables Nagle — mandatory on the terminal path, else keystrokes batch +200 ms |
| **ET replay buffer** | Eternal Terminal-style seq-numbered ring for lossless reconnect (replaces tmux) |
| **Client-side cursor** | Strip cursor from video, send position on a side channel, draw on client → pointer latency = RTT |
| **NV12** | `420YpCbCr8BiPlanarVideoRange` — zero-copy capture→VideoToolbox pixel format |
| **LTR** | Long-Term Reference frame — loss recovery without a forced IDR |
| **Glass-to-glass** | Latency from pixel change on host to display on client |
| **TCC / AX** | macOS permission system / Accessibility API |
