# 01 — Overall Architecture

> **STATUS: REFERENCE — GUI video-path design depth.** Shipped and co-equal with terminal panes; the old "Phase 4 / secondary" framing is retired. Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> The client is one unified infinite canvas of panes. A pane is either a **terminal pane** (host PTY → TCP → libghostty, pixel-perfect text) or a **GUI-window pane** (ScreenCaptureKit → VideoToolbox HEVC → UDP video) — two co-equal, both-shipped pane transports. This doc covers the **GUI video-path**; for the overall split — and why the terminal transport avoids input-injection — read **[12-coding-profile.md](12-coding-profile.md)** first.

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
│ │ Window/Input  │ ◀───────────────── │ Control  │◀──│ (Network.fw) │  │
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

## 2. Components & responsibilities

### Host (macOS)
| Module | Responsibility | Key APIs |
|--------|-------------|-----------|
| **Window Enumerator** | Enumerate windows, let the user pick | `SCShareableContent`, `SCWindow` |
| **Capturer** | Capture one window → `CVPixelBuffer` | `SCStream` + `SCContentFilter(desktopIndependentWindow:)` |
| **Encoder** | HW encode HEVC (H.264 fallback), low-latency | `VTCompressionSession` |
| **Packetizer + FEC + Transport** | Fragment NALUs → UDP datagrams + Reed–Solomon GF(2⁸) parity (NEON), send | `NWConnection`, `NWListener` |
| **Control Receiver** | Input events + keyframe/LTR requests over the reliable channel | `NWConnection` (TCP, `TCP_NODELAY`) |
| **Window/Input Controller** | Raise the window + inject mouse/keyboard | `AXUIElement`, `CGEvent`, `CGEventPostToPid` |

### Client (macOS / iOS / iPadOS) — **maximize code sharing**
| Module | Responsibility | Key APIs |
|--------|-------------|-----------|
| **Discovery** | Find hosts on the LAN (same-LAN only) | `NWBrowser` (Bonjour) |
| **Transport + Reassembler + FEC** | Receive datagrams, reassemble frames, recover from parity | `NWConnection` |
| **Decoder** | HW decode → `CVPixelBuffer` | `VTDecompressionSession` |
| **Renderer** | Low-latency display | `CAMetalLayer` or `AVSampleBufferDisplayLayer` |
| **Input Capture** | Capture mouse/keyboard/touch → send to host | NSEvent / UIKit gestures |

> The wire codec, packetization, **FEC** (Reed–Solomon over GF(2⁸), NEON-accelerated — `m=1` byte-identical to the original XOR parity, `m≥2` recovers multi-packet loss; with adaptive tiering), frame reassembly, and the realtime controllers — **ABR/congestion, FPS governor, LTR, decode gate/sequencer, jitter-depth pacer, delay-gradient trendline, coordinate mapping** — live in the Rust core (`slopdesk-core`, safe Rust, zero runtime deps) behind a C-ABI (`slopdesk-ffi`, header `slopdesk_ffi.h`). The Swift modules **SlopDeskVideoHost** (capture/encode) and **SlopDeskVideoClient** (decode/render/input) call it through the **CSlopDeskFFI** C target.

## 3. Package structure

```
slopdesk/
├── Package.swift
├── rust/
│   ├── slopdesk-core/   # safe Rust (no `unsafe`, 0 runtime deps): the
│   │                      #   performance core — wire codecs, FEC + reassembly,
│   │                      #   ABR/congestion, FPS governor, LTR, decode gate/
│   │                      #   sequencer, jitter pacer, coordinate mapping
│   └── slopdesk-ffi/    # C-ABI boundary (the only crate allowed `unsafe`)
│                          #   → libslopdesk_ffi.a + slopdesk_ffi.h
├── Sources/
│   ├── CSlopDeskFFI/           # C target; links libslopdesk_ffi.a
│   ├── SlopDeskVideoProtocol/  # Swift surface over the core's video codec
│   ├── SlopDeskVideoHost/      # macOS — capture, HW encode, send
│   └── SlopDeskVideoClient/    # client — receive, HW decode, Metal render
└── docs/
```

**Principle:** the codecs / FEC / controllers are platform-independent Rust — the same core a future **Android client** consumes over the same C-ABI/JNI (the ALVR split: Rust owns reassembly/FEC/jitter/ABR/recovery; the platform shell owns capture, the socket, and the HW codec). The Swift shell owns ScreenCaptureKit capture, VideoToolbox, Metal rendering (shared macOS + iOS), and input.

## 4. Data flow for one frame (happy path)

1. A window on the host changes pixels → ScreenCaptureKit emits a `CMSampleBuffer` (status `.complete`).
2. Take the `CVPixelBuffer` + PTS → push into `VTCompressionSession`.
3. The encoder returns NALUs (AVCC). Keyframes include parameter sets (SPS/PPS or VPS/SPS/PPS).
4. The Rust core packetizes the frame into datagrams ≤ MTU (header: frameID, fragIndex, fragCount, flags, streamSeq) + emits Reed–Solomon GF(2⁸) parity (NEON; `m=1`≡XOR, `m≥2` multi-loss) per the adaptive FEC tier.
5. Send over `NWConnection` UDP (`serviceClass = .interactiveVideo`).
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
| Transport | `NWConnection` plain UDP | video datagrams |
| Control channel | TCP (`TCP_NODELAY`) | keyframe/LTR requests, input |
| Render | Metal (`CAMetalLayer` + `CVMetalTextureCache`) | macOS + iOS |
| Input inject | CGEvent + Accessibility | macOS 26 |

> **Platform floor:** Package.swift targets `.v26` — macOS 26 / iOS 26, no fallback below that.

> **Network model:** plain UDP (video) + plain TCP (control), no app-layer crypto. Assumes a **trusted private network** — typically a WireGuard mesh (e.g. NetBird/Tailscale) providing encryption + node auth + per-port ACLs; the security boundary is the network, not the app. Practical notes when running over a userspace-WG mesh: Bonjour/mDNS does not traverse it (connect by IP/hostname); DSCP/`serviceClass` is zeroed through the tunnel → rely on the app-layer ABR; clamp the UDP payload to the runtime MTU; don't pin `requiredInterfaceType` (a userspace-WG link shows up as `.other`).

> **Default codec:** **HEVC Main (8-bit), 4:2:0, low-latency rate control**; H.264 fallback. On Apple Silicon, low-latency rate control supports HEVC (not just H.264). AV1 = decode-only on Apple (no HW encode) → not used for encoding. The quality ceiling for text is **4:2:0 chroma** (Apple HW has no 4:4:4) → mitigate with high capture resolution. Full analysis in [09-codec-choice.md](09-codec-choice.md).
