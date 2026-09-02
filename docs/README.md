# SlopDesk — design docs

Low-latency remote coding for Apple platforms (macOS host; macOS + iOS/iPadOS clients). Workspace of panes: **terminal** (PTY → TCP → `slopdesk-vterm`, our engine over `libghostty-vt`) or **GUI window** (ScreenCaptureKit → HEVC → UDP). **Rust is the default** (CLAUDE.md): the wire, the video path, hostd and the six sidecars are Rust, linked in-process through `CSlopDeskFFI` where a Swift caller needs them. Swift is the AppKit/UIKit shell and nothing else.

**Start here:** [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md)

## Settled scope

| | |
|--|--|
| Host | macOS 26+, non-sandboxed (shell + CGEvent) |
| Client | macOS (AppKit) + iOS/iPadOS (UIKit) — no SwiftUI anywhere; see `56`, `62` |
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
| 45 | [45-multi-client-state-sync.md](45-multi-client-state-sync.md) | Multi-client workspace document + PTY fan-out |
| 46 | [46-gates-env-paths.md](46-gates-env-paths.md) | Gate matrix, `SLOPDESK_*` env, three paths (detail split out of `CLAUDE.md`) |
| 47 | [47-simulator-panel.md](47-simulator-panel.md) | Simulators panel — the fourth path |
| 48 | [48-android-panel.md](48-android-panel.md) | Android panel (`slopdesk-androidd`) |
| 49 | [49-release-pipeline.md](49-release-pipeline.md) | Release, signing, Homebrew |
| 50 | [50-agent-detection-architecture.md](50-agent-detection-architecture.md) | Agent detection: hook feed + TTY parse |
| 51 | [51-process-supervision.md](51-process-supervision.md) | `slopdesk-superd` — what outlives a hostd restart |
| 52 | [52-screen-engine.md](52-screen-engine.md) | `slopdesk-screend` |
| 53 | [53-file-drop-service.md](53-file-drop-service.md) | `slopdesk-dropd` |
| 54 | [54-inspector.md](54-inspector.md) | `slopdesk-inspectord` |
| 55 | [55-ffi-boundary.md](55-ffi-boundary.md) | How Rust reaches an in-process Swift caller |
| 56 | [56-client-ui-split.md](56-client-ui-split.md) | The client UI splits in two (its iOS half was later reversed by `62`) |
| 57 | [57-apple-frameworks-in-rust.md](57-apple-frameworks-in-rust.md) | The `slopdesk-apple-*` family |
| 58 | [58-configuration.md](58-configuration.md) | One config file, no settings GUI |
| 59 | [59-hostd-projection.md](59-hostd-projection.md) | Dissolving `MuxChannelSession` and `HostServer` |
| 60 | [60-hostd-in-rust.md](60-hostd-in-rust.md) | hostd becomes a Rust process |
| 61 | [61-videohost-deletion.md](61-videohost-deletion.md) | Deleting `Sources/SlopDeskVideoHost` |
| 62 | [62-phone-uikit.md](62-phone-uikit.md) | The phone client becomes UIKit |
| 63 | [63-client-transport-in-rust.md](63-client-transport-in-rust.md) | The client transport becomes Rust |
| 64 | [64-command-surface-in-rust.md](64-command-surface-in-rust.md) | The binding table becomes Rust |
| 65 | [65-workspace-store-projection.md](65-workspace-store-projection.md) | `WorkspaceStore` becomes a projection |
| 66 | [66-inspector-store-projection.md](66-inspector-store-projection.md) | The inspector's client store becomes a projection |
| 67 | [67-swift-floor-closeout.md](67-swift-floor-closeout.md) | The closeout sweep, and the Swift floor as a list |
| 68 | [68-terminal-surface-in-rust.md](68-terminal-surface-in-rust.md) | The terminal surface becomes ours |
| 69 | [69-dependency-currency.md](69-dependency-currency.md) | Every pin at upstream latest, audited 2026-09-02 |
| 70 | [70-codebase-audit-2026-09.md](70-codebase-audit-2026-09.md) | The whole-tree audit of 2026-09-02: fixed, rejected, ratcheted |
| 72 | [72-terminal-and-remote-desktop-audit-2026-09.md](72-terminal-and-remote-desktop-audit-2026-09.md) | The terminal-vs-ghostty and remote-desktop-vs-Parsec pass of 2026-09-02 |

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
| 40 | [40-rust-to-swift-migration.md](40-rust-to-swift-migration.md) | A Rust→Swift reabsorption that was carried out and then **reversed** — Rust is the default again. History of a round trip, not guidance. |
| 41–42 | [41](41-redesign-research.md), [42](42-implementation-plan.md) | Workspace redesign (canvas → split tree) |
| ui-shell | [ui-shell/README.md](ui-shell/README.md) | Client shell specs, coverage, historical epics |

## Reading paths
- **Architecture** → [00](00-overview.md) + [DECISIONS.md](DECISIONS.md)
- **Terminal** → [12](12-coding-profile.md) → [13](13-network-transport.md) → [14](14-claude-code-integration.md) → [16](16-readonly-inspector.md) → [20](20-wire-protocol.md) → [68](68-terminal-surface-in-rust.md) (the surface itself)
- **GUI video** → [01](01-architecture.md) + [02](02-host-capture-encode.md) + [04](04-client-decode-render.md) + [05](05-input-window-control.md) + [09](09-codec-choice.md)
- **Latency** → [10](10-latency-optimization.md) + [11](11-absolute-latency.md) + [17](17-native-feel-synthesis.md)
- **Workspace UI** → [22](22-workspace-architecture.md) + [56](56-client-ui-split.md) (Mac/AppKit) + [62](62-phone-uikit.md) (phone/UIKit); [ui-shell/README.md](ui-shell/README.md) is the historical epic log
- **The Swift floor** → [67](67-swift-floor-closeout.md) — what stays Swift, and the six reasons that let it

## Glossary

| Term | |
|------|--|
| PTY | Pseudo-terminal; host shell master fd |
| `libghostty-vt` | Ghostty's VT state machine, taken as a C library from the org mirror — the parse layer under `slopdesk-vterm`. The grid, the blocks and the renderer (`slopdesk-termrender`) are ours; see `68`. |
| JSONL transcript | Claude Code per-line JSON log (inspector source) |
| `TCP_NODELAY` | Disables Nagle; mandatory on terminal sockets |
| ET replay buffer | Seq-numbered ring for lossless reconnect |
| Client-side cursor | Cursor stripped from video, drawn on client → pointer = RTT |
| LTR | Long-term reference frame (loss recovery without full IDR) |
| TCC / AX | macOS permissions / Accessibility API |
