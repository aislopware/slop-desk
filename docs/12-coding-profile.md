# 12 — Coding profile (hybrid architecture)

> **CURRENT.** Two co-equal pane transports for daily coding — not game streaming. Decisions: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md). Wire: [20-wire-protocol.md](20-wire-protocol.md). Research corpus (history): [research/hybrid-research-corpus.json](research/hybrid-research-corpus.json).

## Two paths

| | **Terminal** | **GUI window** |
|--|--------------|----------------|
| Content | shell, vim, tmux, Claude Code TUI | VS Code, Xcode, browser, other GUI apps |
| Host | PTY (`openpty` + `posix_spawn`) → VT bytes | ScreenCaptureKit per-window → VideoToolbox HEVC |
| Client | **libghostty** (pixel-perfect) | VT decode → Metal (4:2:0, soft text OK) |
| Input | bytes → PTY stdin | CGEvent / Accessibility inject |
| Transport | TCP (data + control) | UDP + RS-FEC + ABR |
| Idle bandwidth | ~0 | ~0 (`SCFrameStatus.idle` skip) |

**Why terminal first (history, both shipped now):** terminal input is just bytes — no CGEvent, no TCC Accessibility, no activate-then-control. That risk layer (R1/R2 in [08](08-risks-open-questions.md)) lives only on GUI panes. Prior art (VS Code Remote, JetBrains Gateway, Blink) streams text for code, pixels only where no semantic path exists.

**Wire core:** native Swift codecs + controllers; golden corpus `golden/golden_vectors.json`; only C is `Sources/CSlopDeskSIMD` (GF NEON). Shell = ScreenCaptureKit / VideoToolbox / Metal / PTY / UI. Floor: macOS 26 / iOS 26.

Workspace chrome is a **Session → Tab → n-ary split tree** (not free-floating canvas — see [22](22-workspace-architecture.md); canvas design kept as [30](30-infinite-canvas.md) history).

---

## Terminal path

| Decision | Choice |
|----------|--------|
| PTY | `openpty()` + `posix_spawn(createSession)` + `login_tty` (not forkpty-from-Swift) |
| I/O | `DispatchIO(.stream)`, highWater 128 KB; close in cleanup handler |
| Resize | `ioctl(TIOCSWINSZ)` → SIGWINCH |
| Env | `TERM=xterm-ghostty` (fallback `xterm-256color`), `LANG=…UTF-8`, `COLORTERM=truecolor`, `IUTF8` |
| Sandbox | Host **non-sandboxed** (Developer ID); client can be MAS |
| Transport | Plain TCP, dual data/control, `TCP_NODELAY`; **no** app-layer TLS ([13](13-network-transport.md)) |
| Framing | Length-prefixed binary; SSH-style channel mux — [20](20-wire-protocol.md) |
| Renderer | libghostty full surface + self-owned external-backend patch (ref daiimus External.zig) |
| Keys | Always `ghostty_surface_key` (kitty/DECCKM); no hard-coded VT100 bypass |
| Scrollback | Client-side (libghostty); server is a stateless relay + ET replay buffer |
| Reconnect | ET-style seq ring (64 MiB cap, 4 MiB offline gate pauses PTY drain); persistent PTY in hostd |
| Prediction | **No** full Mosh predictor (opaque surface + alt-screen TUIs); optional glitch caret only ([17](17-native-feel-synthesis.md)) |

**libghostty notes:** feed network bytes via `ghostty_surface_feed_data`; outbound via write-callback. Full surface, not vt+own-renderer. Patch rebased on pinned Ghostty SHA; build XCFramework with Zig. Alt-screen works; use action callbacks (COMMAND_FINISHED, PWD, …) — no client-side OSC parse of the full stream.

Claude Code details: [14](14-claude-code-integration.md). Inspector: [16](16-readonly-inspector.md).

---

## GUI video path

Text-critical work stays on the terminal path, so video does **not** chase 4:4:4 or sub-16 ms floors.

| Decision | Choice |
|----------|--------|
| Capture | Per-window ScreenCaptureKit; NV12; skip `.idle` |
| Encode | HEVC Main 8-bit 4:2:0; no B-frames; CQ / low-latency RC on Apple Silicon |
| fps | ~30 default with idle-skip (60 available); capture can run faster than encode |
| Loss | RS FEC (`m=1` ≡ XOR) + LTR + optional NACK; ABR via `LiveCongestionController` |
| Cursor | Stripped from capture; side-channel UDP; client composite → pointer ≈ RTT |
| Input | Activate-then-control + CGEvent (this path only) — [05](05-input-window-control.md) |
| Latency goal | Feels-local coding, not game-stream floor — [10](10-latency-optimization.md), [11](11-absolute-latency.md) demoted |

Deep design: [01](01-architecture.md)–[04](04-client-decode-render.md), [09](09-codec-choice.md).

---

## What not to re-open

- App-layer crypto / pairing — security boundary is the WireGuard mesh ([13](13-network-transport.md))
- Full Mosh shadow-framebuffer predictor on PATH 1
- 4:4:4 / ProMotion / beam-racing for coding
- SDK-driven Claude pane (B2) — TUI + read-only inspector instead
- Building an orchestration product (herdr client only)

## Further reading

- Native-feel synthesis → [17](17-native-feel-synthesis.md)
- Risk measurements → [18](18-risk-resolutions.md)
- Network model → [13](13-network-transport.md)
- Workspace → [22](22-workspace-architecture.md)
