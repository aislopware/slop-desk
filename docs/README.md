# SlopDesk — design docs

Low-latency remote coding for Apple platforms (macOS host; macOS + iOS/iPadOS clients). Workspace of panes: **terminal** (PTY → TCP → libghostty) or **GUI window** (ScreenCaptureKit → HEVC → UDP). Wire core is native Swift; only non-Swift code is the NEON kernel in `Sources/CSlopDeskSIMD`.

**Start here:** [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md)

## Settled scope

| | |
|--|--|
| Host | macOS 26+, non-sandboxed (shell + CGEvent) |
| Client | macOS + iOS/iPadOS, Swift/SwiftUI |
| Use case | Everyday coding (shell + Claude Code), not game streaming |
| Network | Plain TCP + UDP on a trusted private mesh (WireGuard); no app-layer crypto |
| Paths | Terminal · GUI window · read-only inspector |

## Index

### Read first
| File | |
|------|--|
| [00-overview.md](00-overview.md) | Architecture + every binding decision |
| [DECISIONS.md](DECISIONS.md) | Decision log |

### Current architecture
| # | File | |
|---|------|--|
| 12 | [12-coding-profile.md](12-coding-profile.md) | Hybrid architecture (terminal + GUI) |
| 13 | [13-network-transport.md](13-network-transport.md) | Network model (WireGuard mesh, plain TCP/UDP) |
| 14 | [14-claude-code-integration.md](14-claude-code-integration.md) | Claude Code (TERM, auth, input box) |
| 15 | [15-prior-art-happy-happier.md](15-prior-art-happy-happier.md) | Prior art: Happy/Happier |
| 16 | [16-readonly-inspector.md](16-readonly-inspector.md) | Read-only inspector |
| 17 | [17-native-feel-synthesis.md](17-native-feel-synthesis.md) | Native-feel techniques (Mosh/ET/Parsec…) |
| 18 | [18-risk-resolutions.md](18-risk-resolutions.md) | Risk resolutions + measurements |
| 20 | [20-wire-protocol.md](20-wire-protocol.md) | Terminal wire protocol |
| 22 | [22-workspace-architecture.md](22-workspace-architecture.md) | Workspace (Session → Tab → split tree) |

### GUI video path (design depth)
| # | File | |
|---|------|--|
| 01–06 | [01](01-architecture.md) … [06](06-permissions-distribution.md) | Pipeline, capture, transport, decode, input, permissions |
| 09–11 | [09](09-codec-choice.md) … [11](11-absolute-latency.md) | Codec, latency techniques, floor research |

### Superseded / historical
| # | File | Note |
|---|------|------|
| 07–08 | [07](07-roadmap.md), [08](08-risks-open-questions.md) | Old roadmap / risk log |
| 30, 35 | [30](30-infinite-canvas.md), [35](35-NON-OVERLAP-LAYOUT.md) | Free-floating canvas era (superseded by split tree) |
| 19, 21, 23–29, 31–39, 43–44 | handoffs & rounds | Session logs, not current architecture |
| 40 | [40-rust-to-swift-migration.md](40-rust-to-swift-migration.md) | Migration plan (done; Rust tree removed) |
| 41–42 | [41](41-redesign-research.md), [42](42-implementation-plan.md) | Workspace redesign (canvas → split tree) |
| ui-shell | [ui-shell/README.md](ui-shell/README.md) | Client shell specs, coverage, historical epics |

## Reading paths
- **Architecture** → [00](00-overview.md) + [DECISIONS.md](DECISIONS.md)
- **Terminal** → [12](12-coding-profile.md) → [13](13-network-transport.md) → [14](14-claude-code-integration.md) → [16](16-readonly-inspector.md) → [20](20-wire-protocol.md)
- **GUI video** → [01](01-architecture.md) + [02](02-host-capture-encode.md) + [04](04-client-decode-render.md) + [05](05-input-window-control.md) + [09](09-codec-choice.md)
- **Latency** → [10](10-latency-optimization.md) + [11](11-absolute-latency.md) + [17](17-native-feel-synthesis.md)
- **Workspace UI** → [22](22-workspace-architecture.md) + [ui-shell/README.md](ui-shell/README.md)

## Glossary

| Term | |
|------|--|
| PTY | Pseudo-terminal; host shell master fd |
| libghostty | Ghostty terminal engine — client renderer |
| JSONL transcript | Claude Code per-line JSON log (inspector source) |
| `TCP_NODELAY` | Disables Nagle; mandatory on terminal sockets |
| ET replay buffer | Seq-numbered ring for lossless reconnect |
| Client-side cursor | Cursor stripped from video, drawn on client → pointer = RTT |
| LTR | Long-term reference frame (loss recovery without full IDR) |
| TCC / AX | macOS permissions / Accessibility API |
