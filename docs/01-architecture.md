# 01 — Overall Architecture

> **STATUS: REFERENCE — GUI video-path design depth.** Shipped and co-equal with terminal panes; the old "Phase 4 / secondary" framing is retired. Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> A pane is either a **terminal** (host PTY → TCP → libghostty) or a **GUI window** (ScreenCaptureKit → HEVC → UDP) — co-equal transports. This doc is **GUI video-path design depth**; overall split → [12-coding-profile.md](12-coding-profile.md).

## 1. The big picture

```
┌──────────────────────────── HOST (macOS) ─────────────────────────────┐
│                                                                       │
│ ┌───────────────┐   CVPixelBuffer    ┌──────────────┐   NALU+PTS      │
│ │ ScreenCapture │ ─────────────────▶ │ VideoToolbox │ ──────────┐     │
│ │  Kit (1 win)  │                    │  HW Encoder  │           │     │
│ └───────────────┘                    └──────────────┘           ▼     │
│          ▲                                          ┌──────────────┐  │
│          │ raise + frame                            │ Packetizer / │  │
│ ┌───────────────┐    CGEvent / AX    ┌──────────┐   │  FEC / Tx    │  │
│ │ Window/Input  │ ◀───────────────── │ Control  │◀──│ (UdpSocket)  │  │
│ │  Controller   │                    │ Receiver │   └──────────────┘  │
│ └───────────────┘                    └──────────┘           │         │
└─────────────────────────────────────────────────────────────│─────────┘
                                                              │ UDP (plain; trusted private net)
                       Bonjour discovery ◀────────────────────┤
                                                              │
┌──────────────────── CLIENT (macOS / iOS / iPadOS) ──────────▼─────────┐
│ ┌───────────────┐     NALU     ┌──────────────┐  CVPixelBuffer        │
│ │ Transport /   │ ───────────▶ │ VideoToolbox │ ─────────────┐        │
│ │ Reassembler   │              │  HW Decoder  │              ▼        │
│ └───────────────┘              └──────────────┘    ┌──────────────┐   │
│          ▲                                         │ Metal /      │   │
│ ┌───────────────┐   input events (reliable)        │ AVSampleBuf  │   │
│ │ Input Capture │ ─────────────────────────────────│ DisplayLayer │   │
│ │ (mouse/touch) │                                  └──────────────┘   │
│ └───────────────┘                                                     │
└───────────────────────────────────────────────────────────────────────┘
```

> The whole HOST box is `rust/slopdesk-videohostd` — one Rust daemon ([61](61-videohost-deletion.md)),
> calling ScreenCaptureKit, VideoToolbox, CGEvent and AX through the `slopdesk-apple-*` crates
> ([57](57-apple-frameworks-in-rust.md)). The framework names above say WHAT is called, not in what
> language. The CLIENT box is the Swift that is left.

## 2. Components & responsibilities

### Host (macOS)
| Module | Responsibility | Key APIs |
|--------|-------------|-----------|
| **Window Enumerator** | Enumerate windows, let the user pick | `SCShareableContent`, `SCWindow` |
| **Capturer** | Capture one window → `CVPixelBuffer` | `SCStream` + `SCContentFilter(desktopIndependentWindow:)` |
| **Encoder** | HW encode HEVC (H.264 fallback), low-latency | `VTCompressionSession` |
| **Packetizer + FEC + Transport** | Fragment NALUs → UDP datagrams + Reed–Solomon GF(2⁸) parity (NEON), send | `std::net::UdpSocket` — the `NWListener`/`NWConnection` pair went with the Swift host ([61](61-videohost-deletion.md)); a peer-address map stands where the connection registry stood |
| **Control Receiver** | Input events + keyframe/LTR requests | the mux's `Control` channel over the SAME two UDP sockets ([20](20-wire-protocol.md) §9.1) — the daemon binds no TCP at all; the separate reliable channel went with the Swift host |
| **Window/Input Controller** | Raise the window + inject mouse/keyboard | `AXUIElement`, `CGEvent`, `CGEventPostToPid` |

### Client (macOS / iOS / iPadOS) — **maximize code sharing**
| Module | Responsibility | Key APIs |
|--------|-------------|-----------|
| **Discovery** | Find hosts on the LAN (same-LAN only) | `NWBrowser` (Bonjour) |
| **Transport + Reassembler + FEC** | Receive datagrams, reassemble frames, recover from parity | `NWConnection` |
| **Decoder** | HW decode → `CVPixelBuffer` | `VTDecompressionSession` |
| **Renderer** | Low-latency display | `CAMetalLayer` or `AVSampleBufferDisplayLayer` |
| **Input Capture** | Capture mouse/keyboard/touch → send to host | NSEvent / UIKit gestures |

> Wire codec, packetization, **FEC** (Reed–Solomon over GF(2⁸), NEON in `rust/slopdesk-gfsimd` — `m=1` ≡ XOR, `m≥2` multi-loss; adaptive tiering), frame reassembly, and realtime controllers (ABR/congestion, FPS governor, LTR, decode gate/sequencer, pacer, trendline, coordinate mapping) are Rust (`rust/slopdesk-video`), reached from `SlopDeskVideoClient` / `SlopDeskVideoProtocol` through `CSlopDeskFFI`. The two halves are no longer symmetric: the HOST half — capture, HW encode, send, injection — is the Rust daemon `rust/slopdesk-videohostd`, which links `slopdesk-video` directly and reaches every Apple framework through the `slopdesk-apple-*` crates ([57](57-apple-frameworks-in-rust.md), [61](61-videohost-deletion.md)); only **SlopDeskVideoClient** is still Swift, and it owns decode/render/input.

## 3. Package structure

```
slopdesk/
├── Package.swift
├── Sources/
│   ├── CSlopDeskFFI/           # the static archive `just ffi` builds, + its header
│   ├── SlopDeskVideoProtocol/  # thin Swift face over the Rust codec/controllers
│   └── SlopDeskVideoClient/    # client — receive, HW decode, Metal render
├── rust/
│   ├── slopdesk-videohostd/    # the GUI HOST — capture, HW encode, send, injection (docs/61)
│   ├── slopdesk-video/         # wire codec, FEC, reassembly, controllers (forbid unsafe)
│   ├── slopdesk-apple-*/       # one Apple framework area per crate, through objc2 (docs/57)
│   └── slopdesk-gfsimd/        # aarch64 NEON GF(2⁸) region multiply + scalar twin
└── docs/
```

**Principle:** codecs / FEC / controllers are Rust (golden-pinned), and so is every effect on the host's system — ScreenCaptureKit, VideoToolbox and event injection are `slopdesk-apple-*`'s, driven by `slopdesk-videohostd`. What is left in Swift is the CLIENT: Metal render (macOS + iOS) and input capture.

## 4. Data flow for one frame (happy path)

1. A window on the host changes pixels → ScreenCaptureKit emits a `CMSampleBuffer` (status `.complete`).
2. Take the `CVPixelBuffer` + PTS → push into `VTCompressionSession`.
3. The encoder returns NALUs (AVCC). Keyframes include parameter sets (SPS/PPS or VPS/SPS/PPS).
4. Packetize the frame into datagrams ≤ MTU (header: frameID, fragIndex, fragCount, flags, streamSeq) + emit Reed–Solomon GF(2⁸) parity (NEON; `m=1`≡XOR, `m≥2` multi-loss) per the adaptive FEC tier.
5. Send over UDP. Steps 1–5 are the HOST's and they are all `rust/slopdesk-videohostd` now ([61](61-videohost-deletion.md)), so this leg is a plain socket, not `NWConnection` — `serviceClass = .interactiveVideo` survives only on the CLIENT's Swift side, and a WireGuard tunnel zeroes it there anyway (§5).
6. The client reassembles fragments by frameID; missing fragments are recovered from FEC parity where possible, otherwise the frame is dropped and recovery is driven by LTR / a keyframe request over the control channel.
7. Assemble NALUs → `CMSampleBuffer` (AVCC) → `VTDecompressionSession`.
8. The decoder returns a `CVPixelBuffer` (NV12, IOSurface-backed).
9. Renderer: zero-copy `CVMetalTextureCache` → YCbCr→RGB shader → present.

## 5. Latency Budget

> ⚠️ **GUI video-path only.** The terminal pane transport's latency = network RTT (~1–5ms LAN-direct), no vsync/encode. The GUI path target is **40–80ms** (coding use); 120fps/ProMotion dropped. The table below is the original **30–50ms / 60fps** estimate, kept as reference. See [12 §latency](12-coding-profile.md), [00](00-overview.md).

Reference target: **glass-to-glass ~30–50ms** on wired LAN, 60fps (frame = 16.6ms).

| Stage | Estimate | Notes |
|-----------|----------|---------|
| Capture (SCKit, waiting for a frame) | ~8–16ms | at most 1 frame interval |
| HW encode (Apple Silicon, low-latency) | ~1–5ms | |
| Packetize + FEC + send | <1ms | |
| LAN (wired) | ~0.2–2ms | Wi-Fi can be 2–10ms + jitter |
| Reassemble | <1ms | |
| HW decode | ~2–8ms | |
| Render + present | ~8–16ms | reduce with `displaySyncEnabled=false` (macOS), ProMotion 120Hz |
| **Total (wired LAN, 60fps)** | **~30–50ms** | |

**Most important latency levers:**
- Disable B-frames (`AllowFrameReordering = false`) on encode + decode.
- `RealTime = true` on both `VTCompressionSession` and `VTDecompressionSession`.
- `serviceClass = .interactiveVideo` on `NWParameters` (zeroed through a WireGuard tunnel → the app-layer ABR carries the load).
- Bounded jitter buffer: recover lost fragments from FEC parity, else drop + recover via LTR / keyframe request — no per-packet retransmit.
- Adaptive bitrate / congestion control (`LiveCongestionController` + `LiveBitratePolicy`) tracks the link.
- Render: `CAMetalLayer.displaySyncEnabled = false` (macOS), `maximumDrawableCount = 2`.

## 6. Tech stack summary

| Layer | Technology | Notes |
|------|-----------|--------|
| Capture | ScreenCaptureKit | macOS 26 floor (SCK since 12.3) |
| Encode/Decode | VideoToolbox (HEVC, H.264 fallback) | — |
| Discovery | Bonjour via `NWListener`/`NWBrowser` | same-LAN only |
| Transport | plain UDP — a socket on the HOST, `NWConnection` on the CLIENT | video datagrams; the two ends stopped being the same language when [61](61-videohost-deletion.md) moved the host to `rust/slopdesk-videohostd` |
| Control channel | the mux's `Control` channel on the video UDP sockets | keyframe/LTR requests, input. On THIS path only — the terminal pane's transport is still TCP (`TCP_NODELAY`), see [00](00-overview.md) |
| Render | Metal (`CAMetalLayer` + `CVMetalTextureCache`) | macOS + iOS |
| Input inject | CGEvent + Accessibility | macOS 26 |

> **Platform floor:** Package.swift targets `.v26` — macOS 26 / iOS 26, no fallback below that.

> **Network model:** plain UDP, no app-layer crypto — on THIS path both the video and its control
> channel ride the same two UDP sockets (the TCP control channel went with the Swift host,
> [61](61-videohost-deletion.md)); the terminal pane's transport is the TCP one. Assumes a **trusted private network** — typically a WireGuard mesh (e.g. NetBird/Tailscale) providing encryption + node auth + per-port ACLs; the security boundary is the network, not the app. Practical notes when running over a userspace-WG mesh: Bonjour/mDNS does not traverse it (connect by IP/hostname); DSCP/`serviceClass` is zeroed through the tunnel → rely on the app-layer ABR; clamp the UDP payload to the runtime MTU; don't pin `requiredInterfaceType` (a userspace-WG link shows up as `.other`).

> **Default codec:** **HEVC Main (8-bit), 4:2:0, low-latency rate control**; H.264 fallback. On Apple Silicon, low-latency rate control supports HEVC (not just H.264). AV1 = decode-only on Apple (no HW encode) → not used for encoding. The quality ceiling for text is **4:2:0 chroma** (Apple HW has no 4:4:4) → mitigate with high capture resolution. Full analysis in [09-codec-choice.md](09-codec-choice.md).
