# 01 — Overall Architecture

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Architecture update (re-scope):** the project is now **hybrid** — the terminal goes over the **PTY text-path** (like SSH/mosh, rendered with libghostty); only **GUI windows** go over video. This doc describes the **GUI video-path**; the new overall architecture + key insight (the terminal path avoids input-injection) is in **[12-coding-profile.md](12-coding-profile.md)** (read that first).

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
│ ┌───────────────┐    CGEvent / AX    ┌──────────┐   │  Transport   │  │
│ │ Window/Input  │ ◀───────────────── │ Control  │◀──│ (Network.fw) │  │
│ │  Controller   │                    │ Receiver │   └──────────────┘  │
│ └───────────────┘                    └──────────┘           │         │
└─────────────────────────────────────────────────────────────│─────────┘
                                                              │ LAN (UDP/QUIC)
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
| **Encoder** | HW encode H.264/HEVC low-latency | `VTCompressionSession` |
| **Packetizer + Transport** | Fragment NALUs → UDP datagrams, send | `NWConnection`, `NWListener` |
| **Control Receiver** | Receive input events over the reliable channel | `NWConnection` (TCP/QUIC stream) |
| **Window/Input Controller** | Raise the window + inject mouse/keyboard | `AXUIElement`, `CGEvent`, `CGEventPostToPid` |

### Client (macOS / iOS / iPadOS) — **maximize code sharing**
| Module | Responsibility | Key APIs |
|--------|-------------|-----------|
| **Discovery** | Find hosts on the LAN | `NWBrowser` (Bonjour) |
| **Transport + Reassembler** | Receive datagrams, reassemble frames | `NWConnection` |
| **Decoder** | HW decode → `CVPixelBuffer` | `VTDecompressionSession` |
| **Renderer** | Low-latency display | `CAMetalLayer` or `AVSampleBufferDisplayLayer` |
| **Input Capture** | Capture mouse/keyboard/touch → send to host | NSEvent / UIKit gestures |

## 3. Package structure (Swift Package Manager)

```
PaneCast/
├── Package.swift
├── Sources/
│   ├── PaneCastCore/          # SHARED — platform-independent
│   │   ├── Protocol/          # packet format, message types, codec enum
│   │   ├── Transport/         # NWConnection wrappers, Bonjour, packetizer/reassembler
│   │   └── Codec/             # VideoToolbox encode + decode wrappers
│   ├── PaneCastHost/          # macOS only — capture, input inject, window control
│   ├── PaneCastClientKit/     # shared client logic (decode pipeline, input mapping)
│   └── PaneCastRender/        # Metal renderer (macOS + iOS)
├── Apps/
│   ├── HostApp-macOS/         # AppKit/SwiftUI host UI + window picker
│   ├── ClientApp-macOS/       # viewer UI
│   └── ClientApp-iOS/         # viewer UI (touch)
└── docs/
```

**Principle:** `PaneCastCore` builds for both macOS and iOS (decode + transport run in both places). `PaneCastHost` is macOS-only (capture + input only exist on the host). Rendering uses Metal, shared by both.

## 4. Data flow for one frame (happy path)

1. A window on the host changes pixels → ScreenCaptureKit emits a `CMSampleBuffer` (status `.complete`).
2. Take the `CVPixelBuffer` + PTS → push into `VTCompressionSession`.
3. The encoder returns NALUs (AVCC). If it's a keyframe → include parameter sets (SPS/PPS or VPS/SPS/PPS).
4. The packetizer splits the frame into datagrams ≤1200 bytes, attaching a header (frameID, fragIndex, fragCount, flags, streamSeq).
5. Send over `NWConnection` UDP (`serviceClass = .interactiveVideo`).
6. The client receives and reassembles fragments by frameID; if a fragment is missing → **drop the frame + request a keyframe** over the control channel.
7. Assemble NALUs → `CMSampleBuffer` (AVCC) → `VTDecompressionSession`.
8. The decoder returns a `CVPixelBuffer` (NV12, IOSurface-backed).
9. Renderer: zero-copy `CVMetalTextureCache` → YCbCr→RGB shader → present.

## 5. Latency Budget

> ⚠️ **Applies to the GUI video-path only.** Terminal-path latency = network RTT (~1–5ms LAN-direct), no vsync/encode. The GUI path target is relaxed to **40–80ms** (coding); **120fps/ProMotion dropped**. The table below is the old numbers (30–50ms/60fps) — kept as reference. See [12 §latency](12-coding-profile.md), [00](00-overview.md).

Target: **glass-to-glass ~30–50ms** on wired LAN, 60fps (frame = 16.6ms).

| Stage | Estimate | Notes |
|-----------|----------|---------|
| Capture (SCKit, waiting for a frame) | ~8–16ms | at most 1 frame interval |
| HW encode (Apple Silicon, low-latency) | ~1–5ms | re-measure in Phase 0 |
| Packetize + send | <1ms | |
| LAN (wired) | ~0.2–2ms | Wi-Fi can be 2–10ms + jitter |
| Reassemble | <1ms | |
| HW decode | ~2–8ms | |
| Render + present | ~8–16ms | reduce with `displaySyncEnabled=false` (macOS), ProMotion 120Hz |
| **Total (wired LAN, 60fps)** | **~30–50ms** | |

**Most important latency levers:**
- Disable B-frames (`AllowFrameReordering = false`) on both encode and decode (drop `enableTemporalProcessing`).
- `RealTime = true` on both `VTCompressionSession` and `VTDecompressionSession`.
- `serviceClass = .interactiveVideo` on `NWParameters`.
- No large jitter buffer: on error → drop the frame + request a keyframe, do NOT retransmit.
- Render: `CAMetalLayer.displaySyncEnabled = false` (macOS), `maximumDrawableCount = 2`.

## 6. Tech stack summary

| Layer | Technology | Min OS |
|------|-----------|--------|
| Capture | ScreenCaptureKit | macOS 13 (target 14+) |
| Encode/Decode | VideoToolbox (HEVC preferred, H.264 fallback) | — |
| Discovery | Bonjour via `NWListener`/`NWBrowser` | — |
| Transport | `NWConnection` UDP (LAN) or QUIC datagram (Wi-Fi) | UDP: iOS 12 / QUIC: iOS 16 |
| Control channel | TCP `noDelay` or QUIC reliable stream | — |
| Render | Metal (`CAMetalLayer` + `CVMetalTextureCache`) | macOS + iOS |
| Input inject | CGEvent + Accessibility | macOS 14+ |

> **Default codec:** **HEVC Main 10 (10-bit), 4:2:0, low-latency rate control**. H.264 as fallback. On **Apple Silicon**, low-latency rate control supports **HEVC as well** (not just H.264). AV1 = decode-only on Apple (no HW encode) → not used for encoding. The real quality ceiling for text is **4:2:0 chroma** (Apple HW has no 4:4:4) → mitigate with 10-bit + high capture resolution. Full analysis in [09-codec-choice.md](09-codec-choice.md).
