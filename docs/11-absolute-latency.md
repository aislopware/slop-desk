# 11 — Absolute Latency (deepest multi-layer research)

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **This floor analysis applies ONLY to the GUI video-path** and is largely **over-engineering for the coding profile** ([12](12-coding-profile.md)): motion-to-photon <16ms, 120fps/ProMotion, beam-racing → **DROP**. Terminal path latency = network RTT (~1–5ms LAN), no vsync. **Keep the API corrections** (queueDepth default 8, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, disable AWDL, idle-skip/dirtyRects) — still valid for the GUI path. **NetBird note ([13](13-netbird-transport.md)):** `serviceClass`/DSCP and `requiredInterfaceType=.wiredEthernet` in this doc **do NOT apply** (running over a WireGuard tunnel — DSCP gets zeroed, utun is `.other`).

> Synthesized from a **73-agent** workflow (15 dimensions + 14 gaps + adversarial verify, ~6M tokens). Goal: **absolute floor latency** glass-to-glass for the Apple/LAN/per-window stack. Full raw corpus: [research/latency-research-corpus.json](research/latency-research-corpus.json).

## Floor summary (needs Phase-0 validation)

| Scenario | Theoretical floor | Realistic |
|---|---:|---:|
| 60fps, wired GigE | ~14 ms | ~22–26 ms |
| 120fps, wired (ProMotion both ends) | ~10 ms | ~14–16 ms |
| 60fps, Wi-Fi 6/6E (light load) | — | +2–5 ms vs wired |
| 120fps, Wi-Fi 6E (6GHz) | — | ~17–26 ms |

The two **dominant** stages are **capture (waiting on the compositor vsync at the host)** and **render + scanout (vsync at the client)** — the network all but disappears on wired GigE (one-way <0.1 ms). Every number is **derived**, not yet measured on this native Swift stack → see the Phase-0 checklist at the end.

> ⚠️ **Important CORRECTIONS to the old design** (details in §"Verified API claims"):
> - `minimumFrameInterval`: **macOS 15+ silently defaults to 1/60** (caps at 60fps even on ProMotion) → **must set explicitly**; use `(1/fps)×0.9` (OBS PR#11896), **NOT** `kCMTimeZero` (refuted).
> - `queueDepth`: the actual default is **8** (not 3); **2 is valid** for low latency.
> - HEVC: `AllowOpenGOP` defaults to **true** → **must set `false`**; `MaxFrameDelayCount=0` forces one-in-one-out.
> - 10-bit capture: `'x420'` (`420YpCbCr10BiPlanarVideoRange`) is **NOT** supported by `SCStreamConfiguration`; HDR requires a **macOS 15 preset** or `'xf44'` (4:4:4).
> - **AWDL / peer-to-peer (`includePeerToPeer`) is HARMFUL** for video (40–336 ms spikes) → disable; use AP ch44/149 or the 6GHz band.
> - **VRR / adaptive-sync requires fullscreen** → a single-window (windowed) app gets NO benefit.
> - **Slice / sub-frame pipelining is NOT available** through the public VideoToolbox API (output is frame-granular) → drop from the design.

## Table of contents
- [Latency budget & theoretical floor](#latency-budget--theoretical-floor)
- [Per-stage absolute-minimum configuration](#per-stage-absolute-minimum-configuration)
- [Ranked techniques by latency impact](#ranked-techniques-by-latency-impact)
- [Verified API claims, corrections & Phase-0 validation list](#verified-api-claims-corrections--phase-0-validation-list)

---

## Latency budget & theoretical floor

This section decomposes the glass-to-glass (G2G) budget into discrete stages for the `ScreenCaptureKit -> VideoToolbox HEVC -> Network.framework UDP/QUIC -> VideoToolbox decode -> Metal/CAMetalLayer` stack. The goal is to show exactly where every millisecond goes, which stage dominates, and the absolute realistic floor achievable on Apple Silicon + LAN.

A few foundational principles to internalize before reading the tables:

- **Vsync is an incompressible floor at both ends.** Capture depends on one WindowServer compositor vsync cycle (8.33 ms @120Hz, 16.67 ms @60Hz); display depends on one scanout vsync cycle at the client (half a frame on average, one frame worst-case). These are two costs no API can eliminate — they can only be reduced by raising the refresh rate.
- **On wired LAN, the network all but disappears from the budget.** GigE serialization of one 1500-byte frame is ~12 µs; one-way LAN total < 0.1 ms. The network is NOT the dominant stage on wired — the pipeline is dominated by display timing at both ends.
- **Moonlight's overlay numbers always read LOWER than the true G2G.** Christoff Visser / Greendayle measured Virtual Desktop under-reporting by ~40 ms versus true motion-to-photon; the overlay captures network+decode but misses capture compositor delay, compositor buffering, and display scanout. Every "self-reported" number in the corpus must be read as a lower bound.

---

### Conventions & baseline constants

| Constant | Value | Source |
|---|---|---|
| Vsync period @60Hz | 16.67 ms | By definition (1/60) |
| Vsync period @120Hz | 8.33 ms | By definition (1/120) |
| Average scanout contribution (half frame) | 8.3 ms @60Hz / 4.2 ms @120Hz | blurbusters.com (display-compositor-macos) |
| GigE one-way LAN | < 0.1 ms | basicitnetworking / Cloudflare (~60 µs on 10GbE localhost) |
| Wi-Fi 6/6E one-way (light load) | 0.5–2.5 ms | routerhaus / Cudy (5GHz 5–15ms RTT; 6GHz 3–8ms RTT) |
| mach tick Apple Silicon | 41.67 ns (numer=125, denom=3) | Eclectic Light, confirmed on M1; **claim_to_verify for M2/M3/M4** |

---

### Budget @60fps — WIRED GigE (60Hz display at both ends)

| Stage | Floor | Realistic | Dominant? | Notes & sources |
|---|---:|---:|:---:|---|
| **Capture (SCK compositor vsync)** | 0 | ~16.67 ms | ◆ DOMINANT | One WindowServer compositor cycle; incompressible. CPU cost is only ~1.9% of one core (WWDC22 10156). Set `minimumFrameInterval`, `queueDepth=3`, skip idle frames to avoid backlog. |
| **Encode (VideoToolbox HEVC HW)** | ~3.3 ms | 15–18 ms | ◆ possibly dominant | HEVC ~18 ms/frame @1080p60 on M4 (Lumen README, self-reported); H.264 ~15 ms. Theoretical ceiling ~3.3 ms from ~300fps throughput @1080p — **but that is throughput, NOT single-frame latency** (open question, no official measurement from Apple). Still within the 16.67 ms budget. |
| **Transmit (UDP/QUIC, wired)** | < 0.1 ms | < 0.5 ms | ✗ | Serialization ~12 µs/1500B + NIC + propagation. QUIC-TLS adds AES-128-GCM ~6.5 µs/frame on M1 (negligible). Plain UDP ~0 crypto. |
| **Decode (VideoToolbox HEVC HW)** | ~1 ms | 1–3 ms | ✗ | M2 Mac 2–3 ms, drops to 1.2 ms when the renderer is not the bottleneck (Moonlight #1249). M2 iPad ~1 ms (#1087, "felt" — not measured with Instruments). `flags=0` sync decode, do not set `EnableTemporalProcessing`. |
| **Render + vsync (Metal direct)** | 4.2 ms | 8.3–16.7 ms | ◆ DOMINANT | Average scanout 8.3 ms, worst-case 16.67 ms @60Hz. Metal direct path (CVMetalTextureCache -> CAMetalLayer), do NOT use AVSampleBufferDisplayLayer (adds ≥1 frame of buffering, Moonlight #1885). `maximumDrawableCount=2` (valid on iOS/iPadOS — the "not recommended" claim was refuted), `displaySyncEnabled` + `CAMetalDisplayLink preferredFrameLatency=1`. |
| **TOTAL G2G video** | **~13 ms** | **~22–36 ms** | | Floor = 16.67 (capture) + 3.3 (encode ceiling) + 0.1 (net) + 1 (decode) + but since the capture+render vsync pair dominates, the practical floor ≈ **14 ms**; realistic ≈ **22 ms** |

The realistic 22 ms matches the corpus realworld-floor: "Theoretical glass-to-glass floor at 60fps wired Apple Silicon: ~14–26 ms (capture 1ms + encode 2–4ms + network <0.1ms + decode 1–3ms + display 8.3–16.7ms)".

> **Important note on the capture stage:** The 16.67 ms capture figure assumes the worst case (pixels change right after the compositor just grabbed a frame). The average is half a vsync. The corpus theoretical floor's "1 ms capture" is actually SCK's *callback overhead* after the compositor has already composited — it does NOT include the wait for the compositor vsync. This is the biggest source of confusion: SCK's vsync-to-callback latency on Apple Silicon **has never been published by Apple** (the most important open question of the capture-floor dimension).

---

### Budget @120fps — WIRED GigE (120Hz/ProMotion display at both ends)

| Stage | Floor | Realistic | Dominant? | Notes & sources |
|---|---:|---:|:---:|---|
| **Capture (SCK compositor vsync)** | 0 | ~8.33 ms | ◆ DOMINANT | One cycle @120Hz. **MUST set `minimumFrameInterval` explicitly** — the macOS 15+ default silently changed to 1/60, capping capture at 60fps even on ProMotion (confirmed: macOS 14.5 SDK = default 0, macOS 15.5 SDK = default 1/60). OBS PR#11896 uses `(1/target_fps × 0.9)`, NOT `kCMTimeZero` (the "kCMTimeZero" claim was refuted — that header comment does not exist). |
| **Encode (VideoToolbox HEVC HW)** | ~3.3 ms | 8–18 ms | ◆ DOMINANT (tight) | Budget is only 8.33 ms/frame. HEVC ~18 ms (Lumen M4) **exceeds the 120fps budget** → need to verify encode is actually < 8.33 ms or accept encode overlapping multiple frames. This is the tightest constraint at 120fps. |
| **Transmit** | < 0.1 ms | < 0.5 ms | ✗ | As above. |
| **Decode** | ~1 ms | 1–3 ms | ✗ | 2.37–2.69 ms average on M4 Pro with the Metal renderer (Moonlight #1696). |
| **Render + vsync (Metal direct)** | 4.2 ms (worst 8.33) | 4.2–8.3 ms | ◆ DOMINANT | Half-frame scanout = 4.2 ms @120Hz. `CAMetalDisplayLink preferredFrameLatency=1` (only 1.0 or 2.0 are valid — confirmed from the SDK doc). Beam-racing: render the latest frame just before `targetTimestamp`. |
| **TOTAL G2G video** | **~10 ms** | **~14–16 ms** | | Corpus floor: "~10–16 ms (capture 1ms + encode 2–4ms + network <0.1ms + decode 1–3ms + display 4.2–8.3ms)" |

---

### Budget @60fps — Wi-Fi 6/6E (light load)

| Stage | Realistic (Wi-Fi) | Δ vs wired | Notes |
|---|---:|---:|---|
| Capture | ~16.67 ms | 0 | Unchanged (host-side) |
| Encode | 15–18 ms | 0 | Unchanged |
| **Transmit** | **2–5 ms** | **+2–5 ms** | Wi-Fi 5GHz 5–15ms RTT → ~2.5–7.5ms one-way; 6GHz 3–8ms RTT → ~1.5–4ms one-way, jitter down ~80% (Cudy). **`serviceClass=.interactiveVideo` is mandatory** (→ AC_VI), enable WMM on the AP, do NOT enable `includePeerToPeer` (AWDL 40–336 ms spikes). |
| Decode | 1–3 ms | 0 | Unchanged (client-side) |
| Render+vsync | 8.3–16.7 ms | 0 | Unchanged |
| **TOTAL G2G video** | **~24–41 ms** | **+2–5 ms** | Wi-Fi adds ~2–5 ms under ideal conditions |

> **AWDL warning (latency bomb).** AWDL runs in the background on every Apple machine, channel-hopping roughly every 10–12s and causing 50–200 ms spikes (networkweather; Visser/RIPE91 measured 20ms ±25ms variance, RTT 3–90ms). **Mandatory mitigation:** configure the AP to use the AWDL social channel, 5GHz ch44 or ch149 (confirmed via OWL/Seemoo reverse-engineering, never officially confirmed by Apple), or use the 6GHz band. Otherwise the Wi-Fi budget can periodically jump by +50–200 ms.

---

### Budget @120fps — Wi-Fi 6E (light load, 6GHz)

| Stage | Realistic | Notes |
|---|---:|---|
| Capture | ~8.33 ms | Needs an explicit `minimumFrameInterval` |
| Encode | 8–18 ms | Tightest constraint at 120fps |
| Transmit | 1.5–4 ms | 6GHz beats 5GHz (no AWDL contention, clean channel) |
| Decode | 1–3 ms | |
| Render+vsync | 4.2–8.3 ms | |
| **TOTAL G2G video** | **~17–26 ms** | 6GHz is the best Wi-Fi option for 120fps |

---

### Input-to-photon (full remote-control round trip)

This is a 6-stage chain, distinct from one-way video G2G: client captures input → send → host injects → host display changes → returns to the client as video. Most important takeaway: **the local cursor is decoupled from the video loop**.

| Stage | macOS host cursor | iOS touch client | Notes & sources |
|---|---:|---:|---|
| **1. Client input capture** | 1–3 ms (USB HID 1ms @1000Hz; passive CGEventTap +0.1–0.3ms) | 8–17 ms @120Hz (touch HW at 240Hz, UIKit coalesces to the frame boundary) | iOS 120Hz touch-to-UIKit **has no official measurement**; estimating "8–17ms" by halving the 60Hz figure is *methodologically unsound* (DXOMARK measured the iPhone 15 Pro Max at ~67ms end-to-end, NOT half the 60Hz value). Use `coalescedTouches`/`predictedTouches`. |
| **2. Network send** | 0.05–0.2 ms wired | as above | Send button events immediately, batch motion at ~1ms cadence. |
| **3. Host inject (CGEventPostToPid)** | 0.2–2 ms | — | NOT a "Mach IPC round-trip" as originally assumed (refuted) — it is a CoreGraphics/WindowServer multi-hop injection, **no Apple Silicon benchmark exists**. For comparison: XPC/UDS small-msg ~11µs on Intel → the full path has more hops. |
| **4. Activate-then-control** | 0.1–0.3 ms (2 Mach msgs, once per session) | — | `SLPSPostEventRecordTo` flips the active state without raising the window (avoids the 100–300ms Space switch). **Note:** on macOS 14 this function can SIGABRT because `CGSEncodeEventRecord` mis-serializes a buffer filled with 0xFF (paneru #123) — needs an OS-version guard. Tahoe 26: CGEventPost from an unsigned daemon is blocked → needs code-signing or a DriverKit virtual HID. |
| **5. Return video (host display→client)** | 3–15 ms | 3–15 ms | = the entire encode→net→decode pipeline above (without double-counting scanout). |
| **6. Client display** | 8–13 ms @120Hz | 8–17 ms @120/60Hz | Same as render+vsync above. |

**Input-to-photon results:**
- **WITHOUT a local cursor:** ~14–36 ms G2G (wired, 120Hz, cursor excluded) — matches the corpus.
- **WITH a local cursor overlay:** the cursor appears in **~2–5 ms** (input capture + draw, fed from the input channel, NOT through the video round trip); the window-update confirmation (the video frame showing the result) arrives in ~15–25 ms. **This is the highest-value optimization for perceived responsiveness** — RDP/PCoIP/NoMachine all do it. Set `SCStreamConfiguration.showsCursor = false` and draw the cursor client-side from the input stream.

On LAN, RTT ~1ms < one frame period, so **NO motion prediction/extrapolation is needed** (only for WAN RTT > 20ms).

---

### Absolute realistic floor & comparison against real systems

**Theoretical floor, Apple Silicon + wired LAN (Metal direct render, HEVC HW, low-latency mode):**

| Configuration | Floor G2G video | Realistic G2G video |
|---|---:|---:|
| **120fps wired, display 120Hz** | **~10 ms** | **~14–16 ms** |
| **60fps wired, display 60Hz** | **~14 ms** | **~22–26 ms** |
| **120fps Wi-Fi 6E** | ~12 ms | ~17–26 ms |
| **60fps Wi-Fi 6** | ~16 ms | ~24–41 ms |

**Where every millisecond goes:** In both wired configurations, **the two vsync stages (capture compositor + display scanout) account for most of the floor** — about 12.5 ms (@60Hz: 8.3+4.2 on average, up to 33ms if both hit worst-case) versus only ~4 ms for encode+decode combined and < 0.5 ms for the network. **Encode is the only potentially-dominant stage we can control via API** (low-latency RC, no B-frames, MaxFrameDelayCount=0). The network is nearly free on wired. Conclusion: **to compress the floor, raise the refresh rate (60→120Hz), not the network** — moving 60→120Hz saves ~8ms in capture + ~4ms in scanout = ~12ms.

**Comparison against real systems (sourced measurements):**

| System | Published figure | Measurement scope | Reliability assessment |
|---|---:|---|---|
| **Parsec** | 4–8 ms @240fps wired LAN | encode+transmit+decode **display-to-display**, does NOT include input injection, measured with a 1000fps camera | An extreme stress-test demo (Parsec recommends 60fps in practice); NOT full G2G. ~7ms overhead @60fps vs local. |
| **Parsec encode** | NVENC H.264 median 5.8 ms | fleet median across **all Nvidia GPUs** (not just Pascal), 2018, NOT a controlled benchmark | Apple Silicon Media Engine encode latency **has no official benchmark at all** |
| **Moonlight + Sunshine** | ~10–20 ms total @60fps wired | community measured, overlay | Overlay under-reports — true G2G is higher |
| **Moonlight decode (Apple Silicon)** | M2 iPad ~1ms, M2 Mac 2–3ms | "felt"/overlay, not Instruments | M2 Mac 4–6ms via FFmpeg+VT+AVSampleBufferDisplayLayer; down to ~2.7ms with Metal |
| **Lumen (Sunshine fork, M4)** | encode H.264 ~15ms / HEVC ~18ms @1080p60; 1ms encode-to-network | README self-reported, methodology not stated | Self-reported encode numbers, not independently verified |
| **ALVR (VR)** | target < 50ms motion-to-photon; actual 70–140ms wireless | measured by Greendayle | The VR domain adds compositor+tracking; not directly comparable |
| **NeSt-VR (paper)** | VF-RTT 4–5 ms Wi-Fi | measured, peer-reviewed | Transmission round-trip stage only |

---

### Caveats & uncertainties to remember

1. **macOS 26 Tahoe decode regression.** Moonlight #1696 reports decode latency jumping to ~80ms on Intel/macOS 26, ~20ms on M4 with the Metal renderer; disabling the Metal renderer → ~2.7ms. Suspected cause is CAMetalDisplayLink "presentation wait timed out", not HW decode. **Must test on the macOS 26 target before trusting the ~14ms floor.**

2. **Encode single-frame latency is the biggest unsolved open question.** The ~3.3ms ceiling comes from *throughput* (~300fps @1080p HEVC), NOT single-frame latency. Apple has not published one. At 120fps (8.33ms budget) this constraint can break — measure on the target hardware with `CACurrentMediaTime()` before `VTCompressionSessionEncodeFrame` and inside the output handler.

3. **HEVC low-latency rate control on Apple Silicon is empirical, NOT documented.** `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` is documented by Apple for H.264 only (WWDC21); HEVC support is confirmed only via an FFmpeg patch (`TARGET_CPU_ARM64`), with no official guarantee. Querying `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` returns `kVTPropertyNotSupportedErr` (-12900) in low-latency mode — that is API incompleteness, NOT evidence of a software fallback. The real error gating for missing HW is -12902.

4. **SCK capture vsync-to-callback latency has never been publicly measured.** The entire capture stage (8.33/16.67 ms) is inferred from compositor architecture, not an Apple number. `SCStreamFrameInfoDisplayTime` shares a clock domain with `CACurrentMediaTime()` (both rooted in `mach_absolute_time` — confirmed), but there is a forum report of negative latency (May 2025) that may be a stamping bug of its own; convert correctly with `mach_timebase_info`.

5. **AVSampleBufferDisplayLayer extra-frame buffering is a macOS observation (discrete GPU).** The "1+ frame" Δ from Moonlight #1885 was measured on a Radeon Pro 580; **no iOS benchmark** compares Metal vs AVSampleBufferDisplayLayer. On iOS, Moonlight only uses AVSampleBufferDisplayLayer (no Metal path to A/B). Even so, the Metal-direct recommendation stands because it bypasses the compositor queue.

6. **`maximumDrawableCount=2` is VALID on iOS/iPadOS** (the "Apple does not recommend it" claim was refuted — there is only a warning that `nextDrawable` returns nil more often, which applies on every platform). It is the right choice for minimum G2G; handle nil drawables + drop frames.

---

## Per-stage absolute-minimum configuration

This section lists the configuration **down to the exact symbol** for each stage of the glass-to-glass pipeline. Each setting comes with a one-line rationale. The spelling of every VideoToolbox and ScreenCaptureKit symbol below was verified directly against `MacOSX.sdk` (the installed Xcode: SCK `SCStream.h`, VT `VTCompressionProperties.h`). Any symbol that **could not be verified** from a header is explicitly marked `[UNVERIFIED]`.

> Conventions: `[VERIFIED-SDK]` = confirmed from a header on this machine; `[VERIFIED-CORPUS]` = corpus-confirmed but the header was not re-checked this time; `[UNVERIFIED]` = indirect/community sources only, needs a runtime test; `[PRIVATE]` = private/undocumented symbol, use at your own risk.

---

### 1. Capture — ScreenCaptureKit

Use `SCStream` with `SCContentFilter(desktopIndependentWindow:)`. This is the only public single-window capture path available on macOS 14+ (CGDisplayStream / CGWindowListCreateImage were obsoleted in the macOS 15 SDK) [capture-floor].

| Setting | Value | Rationale |
|---|---|---|
| `SCContentFilter(desktopIndependentWindow:)` `[VERIFIED-CORPUS]` | target window | A filter specialized for single-window, display-independent capture that does not composite other windows → less work in the WindowServer capture path. |
| `config.minimumFrameInterval` `[VERIFIED-SDK]` (`SCStream.h:222`, type `CMTime`) | `CMTimeMake(1, targetFPS)` (e.g. `CMTimeMake(1, 120)`); do **not** use a float approximation | On macOS 15+ the default **changed to 1/60** even on ProMotion → silent 60fps cap. **Verified (corpus, confirmed):** setting this value explicitly is mandatory. **Important correction:** the original claim that `kCMTimeZero` enables the native refresh rate was **REFUTED** — OBS PR #11896 actually uses `target_frame_period × 0.9` (a concrete CMTime), **not** `kCMTimeZero`, and no SDK header says `kCMTimeZero` → native refresh. Recommendation: set exactly `1/targetFPS`, or `1/(targetFPS × 1.1)` (an interval ~10% shorter) per the OBS empirical fix if you see dropped frames. `kCMTimeZero` is untested for this purpose. |
| `config.queueDepth` `[VERIFIED-SDK]` (`SCStream.h:279`, type `NSInteger`) | `3` (for LAN low-latency) | **Correction (corpus REFUTED the claim "range 3–8, default 3"):** the header actually says **default = 8** with only a soft upper bound `"should not exceed 8 frames"`, and **no** hard floor of 3. Production code uses `queueDepth=1` and `=2` successfully (daylight-mirror's 3→2 cut P95 RTT 21.6→18.8ms). Each extra surface = up to 1 extra frame-interval of backlog. IOSurface release deadline = `minimumFrameInterval × (queueDepth−1)`; at 120fps queueDepth=3 → 16.7ms. Choose 2–3 for minimum latency if encode meets the deadline. |
| `config.pixelFormat` `[VERIFIED-SDK]` (`SCStream.h:234`, type `OSType`) | `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (`'420v'`) 8-bit | NV12 goes straight into the VideoToolbox HW encoder with **no** color-conversion pass. BGRA forces one GPU blit (~0.5–2ms at 4K). |
| `config.pixelFormat` (HDR/10-bit) | **Correction:** use a preset, do **not** assign `'x420'` directly | **REFUTED:** `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`'x420'`, 4:2:0 video-range) is **not** in SCK's documented pixelFormat list. The header lists exactly 6 values, of which the only 10-bit YCbCr is `'xf44'` (4:4:4 full-range). The official HDR path: use an `SCStreamConfiguration` preset (`SCStreamConfigurationPresetCaptureHDRLocalDisplay`, macOS 15.0+ `[VERIFIED-SDK SCStream.h:194`]) — the preset sets `captureDynamicRange`, `pixelFormat`, `colorSpace`, `colorMatrix` itself. |
| `config.showsCursor` `[VERIFIED-SDK]` (`SCStream.h:254`, `BOOL`) | `false` | Do not composite the cursor into the frame; the client draws its own cursor overlay from the input stream (see the Input stage). |
| `config.captureResolution` `[VERIFIED-SDK]` (`SCStream.h:325`, `SCCaptureResolutionType`, macOS 14.0+) | `.nominal` (= `SCCaptureResolutionNominal`) | Point resolution instead of 2× Retina; on 4K Retina this cuts pixel count 4× → encode + memory bandwidth shrink accordingly. |
| `config.ignoreShadowsSingleWindow` `[VERIFIED-SDK]` (`SCStream.h:320`, `BOOL`, macOS 14.0+) | `true` | Strips the WindowServer-composited window shadow → smaller capture bounding box. |
| `config.captureDynamicRange` `[VERIFIED-SDK]` (`SCStream.h:370`, `SCCaptureDynamicRange`, macOS 15.0+) | `SCCaptureDynamicRangeSDR` (default) for SDR | HDR is Apple Silicon only; keep SDR when streaming SDR to avoid triggering the EDR pipeline downstream. |
| `addStreamOutput(_:type:sampleHandlerQueue:)` `[VERIFIED-CORPUS]` | `DispatchQueue(label:..., qos: .userInteractive)` | High-priority callback delivery, less scheduling jitter under load. |

**Inside the `stream(_:didOutputSampleBuffer:of:)` callback:**
- Read `SCStreamFrameInfoStatus` first; only process `SCFrameStatusComplete`/`SCFrameStatusStarted`, return immediately on `SCFrameStatusIdle`/`Blank`/`Suspended` to avoid queue buildup from idle callbacks.
- Take the capture timestamp from the `SCStreamFrameInfoDisplayTime` attachment `[VERIFIED-SDK SCStream.h:401`, macOS 12.3+] — **these are mach_absolute_time ticks** (header `SCStream.h:398–399` explicitly says "mach absolute time when the event occurred"). **Correction (corpus REFUTED):** `displayTime` is in the **same clock domain** as `CACurrentMediaTime()` (both based on `mach_absolute_time()`); just convert ticks → seconds via `mach_timebase_info` (Apple Silicon: numer=125, denom=3), **no** cross-domain conversion needed.
- `stream.synchronizationClock` `[VERIFIED-SDK SCStream.h:453`, `CMClockRef`, macOS 13.0+] to align DTS/PTS with the encoder.

> **Load-bearing note:** a pixel changing in the app → the composited IOSurface that SCK sees has an irreducible floor = one WindowServer vsync cycle (8.33ms @120Hz, 16.67ms @60Hz). This is **not** an Apple-published number — it is inferred from the compositing architecture. There is no public path lower than SCK on macOS 14+.

---

### 2. Encode — VideoToolbox

Project default codec: HEVC Main 10, 4:2:0, no B-frames, infinite GOP + on-demand IDR, low-latency RC.

**In the `encoderSpecification` dict at `VTCompressionSessionCreate` (set BEFORE session creation, NOT via `VTSessionSetProperty`):**

| Symbol | Value | Rationale |
|---|---|---|
| `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` `[VERIFIED-SDK VTCompressionProperties.h:1202`, macOS 11.3+] | `kCFBooleanTrue` | One-in-one-out pipeline, no frame reorder, faster RC. **Important (UNCERTAIN→corrected):** Apple **documents H.264 only** for this key (WWDC21 + the header never mention HEVC). HEVC on Apple Silicon works in practice per the FFmpeg patch (gated `TARGET_CPU_ARM64 && AV_CODEC_ID_HEVC`, merged 2025) but it is **not an Apple guarantee** — there is a risk of silent regression through an OS update. Verify at runtime with `VTCopySupportedPropertyDictionaryForEncoder`. |
| `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` `[VERIFIED-CORPUS]` | `kCFBooleanTrue` | Fail fast when no Media Engine is present instead of falling back to software (5–20× slower). |

**Manual HEVC low-latency config (because `EnableLowLatencyRateControl` is documented for H.264 only) — via `VTSessionSetProperty` after session creation:**

| Symbol | Value | Rationale |
|---|---|---|
| `kVTCompressionPropertyKey_RealTime` `[VERIFIED-CORPUS]` | `kCFBooleanTrue` | Do not defer frames for batch optimization. |
| `kVTCompressionPropertyKey_AllowFrameReordering` `[VERIFIED-CORPUS]` | `kCFBooleanFalse` | Disable B-frames; mandatory for LAN remoting. |
| `kVTCompressionPropertyKey_AllowOpenGOP` `[VERIFIED-SDK VTCompressionProperties.h:197`, macOS 10.14+] | `kCFBooleanFalse` | **HEVC defaults to `kCFBooleanTrue`** (header `:190–191` confirms, verified) → must disable explicitly so IDRs are independently decodable, with no cross-GOP dependency. |
| `kVTCompressionPropertyKey_MaxFrameDelayCount` `[VERIFIED-SDK VTCompressionProperties.h:576`, macOS 10.8+] | `0` | **Correction (corpus REFUTED "0=default"):** the default is `kVTUnlimitedFrameDelayCount = -1` (`enum` at `:577`, verified), allowing arbitrary buffering. Setting `0` → frame N must be emitted before the encode call for frame N returns = synchronous immediate emit. The sentence "A value of zero implies default behavior" belongs to the **adjacent** property `MaxH264SliceBytes` (`:586`), not this one. |
| `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality` `[VERIFIED-SDK VTCompressionProperties.h:324`, macOS 11.0+] | `kCFBooleanTrue` | The HW encoder prioritizes quality by default; flip it to cut encode time (header `:62–65` lists it in the ultra-low-latency recipe). |
| `kVTCompressionPropertyKey_MaxKeyFrameInterval` `[VERIFIED-CORPUS]` | a very large value (`INT_MAX`) | Infinite GOP; IDR only on demand via `kVTEncodeFrameOptionKey_ForceKeyFrame`. |
| `kVTCompressionPropertyKey_ExpectedFrameRate` `[VERIFIED-CORPUS]` | target fps (60 or 120) | Helps the encoder pre-configure internal timing. |
| `kVTCompressionPropertyKey_MaximumRealTimeFrameRate` `[VERIFIED-SDK VTCompressionProperties.h:668`, macOS 15.0+] | `120` | Hints the peak burst rate so the encoder does not under-configure the pipeline for bursts. |

**Rate control (mutually exclusive with low-latency mode):**

| Symbol | Value | Rationale |
|---|---|---|
| `kVTCompressionPropertyKey_AverageBitRate` `[VERIFIED-CORPUS]` | `<target_bps>` | Soft target; auto-bitrate is **not** supported in low-latency mode. |
| `kVTCompressionPropertyKey_DataRateLimits` `[VERIFIED-CORPUS]` | `[bytes, seconds]` | Hard cap against burst overflow stalling the network. |
| Do **NOT** set `kVTCompressionPropertyKey_ConstantBitRate` | — | Mutually exclusive with `EnableLowLatencyRateControl` → `kVTPropertyNotSupportedErr`. |
| `kVTCompressionPropertyKey_MaxAllowedFrameQP` `[VERIFIED-SDK VTCompressionProperties.h:1214`, macOS 12.0+] | `36–40` for screen-share | Caps frame size; QP ≤40 keeps text legible and stops bloated IDRs from spiking transmission. |
| `kVTCompressionPropertyKey_SpatialAdaptiveQPLevel` `[VERIFIED-SDK VTCompressionProperties.h:1540`, **macOS 15.0+, macOS-only**] | `kVTQPModulationLevel_Disable` | Header `:1524` explicitly says "ignored when EnableLowLatencyRateControl is set to true" — disable for correctness / to spend no time on QP analysis. |

**LTR recovery (instead of periodic IDR):**

| Symbol | Value | Rationale |
|---|---|---|
| `kVTCompressionPropertyKey_EnableLTR` `[VERIFIED-SDK VTCompressionProperties.h:1247`, macOS 12.0+] | `kCFBooleanTrue` | An LTR-P frame is much smaller than an IDR → cheaper recovery on packet loss. The header is **codec-agnostic** (not limited to H.264) → usable with HEVC on Apple Silicon (corpus REFUTED the "not yet confirmed" claim). |
| `kVTEncodeFrameOptionKey_ForceLTRRefresh` `[VERIFIED-SDK VTCompressionProperties.h:1277`] | see rationale | **Contradiction within the header itself (confirmed):** the type annotation says `// CFNumberRef, Optional` but the `@abstract` (`:1265`) says "Set this option to kCFBooleanTrue". Runtime behavior unclear → **test both `kCFBooleanTrue` and `@(1)` (CFNumberRef)** to determine which one the encoder accepts. |
| `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens` `[VERIFIED-CORPUS]` | CFArray of CFNumberRef | Client feeds back ACKed tokens in the per-frame options. |

**H.264 fallback only:**

| Symbol | Value | Rationale |
|---|---|---|
| `kVTCompressionPropertyKey_H264EntropyMode` `[VERIFIED-CORPUS]` | `kVTH264EntropyMode_CABAC` (with High profile) | CABAC ~7% better compression; on the Apple Silicon HW decoder the CABAC-vs-CAVLC decode latency delta is sub-ms. |
| `kVTCompressionPropertyKey_MaxH264SliceBytes` `[VERIFIED-SDK VTCompressionProperties.h:588`, H.264-only, macOS 10.8+] | `~1300` (MTU-aligned) | One slice per UDP packet; **no HEVC equivalent** exists in VideoToolbox. |

**Initialization & pre-warm:**
- `VTCompressionSessionPrepareToEncodeFrames(session)` `[VERIFIED-CORPUS]` — call ONCE after setting properties, before the first frame, to eliminate the first-frame allocation spike (resource alloc, ref buffers, HW queue init).
- macOS 26+: if available, use `kVTCompressionPreset_VideoConferencing` `[VERIFIED-SDK VTCompressionProperties.h:1606`, macOS 26.0+] — header `:1602` explicitly says "requires setting kVTVideoEncoderSpecification_EnableLowLatencyRateControl to kCFBooleanTrue". Query via `kVTCompressionPropertyKey_SupportedPresetDictionaries` before applying.

> **Measurements (corpus, uncertain):** H.264 1080p60 ~15ms/frame, HEVC ~18ms/frame on M4 (Lumen README — self-reported, methodology unclear). Apple does **not** publish per-frame encode latency. WWDC21: the "up to 100ms reduction" at 720p30 is from removing the reorder buffer, **not** raw encode time.

---

### 3. Transport — Network.framework + BSD sockets

LAN-only, no NAT. Foundational choice: plain UDP for video (~0 encryption overhead) or QUIC datagram if Wi-Fi needs congestion control.

**Network.framework (`NWParameters`):**

| Symbol | Value | Rationale |
|---|---|---|
| `parameters.serviceClass = .interactiveVideo` `[VERIFIED-CORPUS]` | video flow | Maps to `NET_SERVICE_TYPE_VI` → Wi-Fi 802.11e **AC_VI** (UP 5). **Correction (corpus UNCERTAIN):** on macOS this **only** sets the Wi-Fi L2 User Priority, it does **NOT** set IP-header DSCP unless the interface has Cisco Fastlane (requires MDM). The public C enum `nw_service_class_interactive_video` = **2** (not `NET_SERVICE_TYPE_VI`=3); the translation table is private. |
| `parameters.serviceClass = .responsiveData` `[VERIFIED-CORPUS]` | input/control flow | A separate low-latency control channel. |
| `parameters.requiredInterfaceType = .wiredEthernet` `[VERIFIED-CORPUS]` ⚠️ do **NOT** use on NetBird (utun=`.other`, it will break — [13](13-netbird-transport.md)) | — | Pins Ethernet, avoiding cellular/Wi-Fi fallback and Happy Eyeballs probing. |
| `parameters.includePeerToPeer = false` `[VERIFIED-CORPUS]` (default) | — | Do **not** set `true`: it activates AWDL → channel-hopping causes 40–336ms spikes (DTS warning thread/751839). Infrastructure Wi-Fi beats AWDL when available. |
| `parameters.multipathServiceType = .disabled` `[VERIFIED-CORPUS]` | — | Avoids path-probing on a single-interface LAN. |
| `parameters.allowFastOpen = true` `[VERIFIED-CORPUS]` | — | Enables QUIC 0-RTT resumption on reconnect; UDP has no handshake so it is trivial. |
| `connection.shouldCalculateReceiveTime = true` `[VERIFIED-CORPUS]` | — | Kernel receive timestamp (`NWProtocolIP.Metadata.receiveTime`) for one-way latency measurement. |

**QUIC datagram (if QUIC is chosen, iOS 16+/macOS 13+):**

| Symbol | Value | Rationale |
|---|---|---|
| `NWProtocolQUIC.Options.isDatagram = true` `[VERIFIED-CORPUS]` | — | Unreliable datagram, congestion-aware. |
| `quicOptions.maxDatagramFrameSize = 1200` `[VERIFIED-CORPUS]` | — | Below path MTU, avoids QUIC fragmenting. |
| `quicOptions.idleTimeout = 30000` (ms) `[VERIFIED-CORPUS]` + keepalive | — | Keeps the connection alive through short network blips → reconnect costs no handshake. |

**Per-packet & receive:**
- `NWProtocolIP.Metadata().serviceClass = .interactiveVideo` for video datagrams; `.signaling` for IDR-request/control to avoid head-of-line queuing.
- `NWProtocolIP.Metadata().ecn = .ect1` `[VERIFIED-CORPUS]` — ECT(1) is the L4S codepoint (RFC 9331); only beneficial if the AP/switch has an L4S AQM.
- **Receive pattern (critical):** inside the completion handler of `connection.receiveMessage(completion:)`, finish processing and then **call `receiveMessage` again (chain, not loop)** on a serial queue. `NWConnection.receiveMessage` delivers only **1 datagram per callback** (DTS confirmed, thread/116500, 2019) — calling it in a loop creates unbounded queued reads.
- `connection.maximumDatagramSize` `[VERIFIED-CORPUS]` — query after `.ready` (typically 1472 on Ethernet); fragment slices ≤ this value, since IP fragmentation adds 1–5ms jitter and doubles the loss probability.

**BSD socket path (if batch receive is needed — `NWConnection` has no batch-receive):**

| Symbol | Value | Rationale |
|---|---|---|
| `setsockopt(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_VI)` `[VERIFIED-CORPUS]` (`=3`) | or `NET_SERVICE_TYPE_RV`=5 | Wi-Fi AC_VI. `RV` (5) is described in XNU `socket.h` as "Responsive Multimedia A/V — E.g. screen sharing". |
| `setsockopt(IPPROTO_IP, IP_TOS, dscp<<2)` `[VERIFIED-CORPUS]` | AF41 = `34<<2` | **The only reliable way to set DSCP on Ethernet** (corpus correction): the kernel does **not** zero out a user-set `ip_tos` on non-Fastlane interfaces. `SO_NET_SERVICE_TYPE` alone does not set DSCP. |
| `setsockopt(SOL_SOCKET, SO_NOSIGPIPE, 1)` `[VERIFIED-CORPUS]` (`=0x1022`) | — | macOS has no `MSG_NOSIGNAL`; mandatory to keep SIGPIPE from killing the process. |
| `setsockopt(IPPROTO_IP, IP_BOUND_IF, if_nametoindex("en0"))` `[VERIFIED-CORPUS]` | — | Equivalent of Linux `SO_BINDTODEVICE`; pins the wired NIC, avoiding VPN/Wi-Fi routing. |
| `sendmsg_x` (syscall 481) / `recvmsg_x` (syscall 480) `[PRIVATE, VERIFIED-CORPUS]` | `struct msghdr_x` array | Batch UDP, collapses N syscalls → 1. **Stable & callable on macOS 14+** (confirmed: syscall numbers are in the public `usr/include/sys/syscall.h`, symbols exported from `libSystem.B.tbd`). **PRIVATE:** `msghdr_x` exists only in `socket_private.h`, must forward-declare it yourself. **macOS 13 hang bug → only use on macOS 14+.** |

> **Measurements:** Wired GigE one-way <0.1ms (1500-byte serialize ~12µs). Network.framework user-space path: ~30% less receive CPU vs BSD sockets (WWDC18 715) — **but** on **macOS 14** it is disabled with a BSD-socket fallback when the built-in firewall is **on** (DTS confirmed on 14.4.1); on **macOS 15.3+** the firewall no longer forces the fallback (corpus correction). Verify with `sudo skywalkctl flow -n -P <pid>`.

---

### 4. Decode — VideoToolbox

`VTDecompressionSession`, rendering straight to Metal (see the Render stage), **not** through any internal-queue path that adds buffering.

| Symbol | Value | Rationale |
|---|---|---|
| `VTDecompressionSessionDecodeFrame(..., flags: 0, ...)` `[VERIFIED-CORPUS]` | flags = `0` | Clears both `kVTDecodeFrame_EnableAsynchronousDecompression` and `kVTDecodeFrame_EnableTemporalProcessing` → synchronous: the callback fires before the call returns, eliminating the internal queue/reorder buffer. **Note (corpus uncertain):** the HW decoder may dispatch internally async and set `kVTDecodeInfo_Asynchronous` in the callback infoFlags while the caller thread still blocks — undocumented behavior, not a guarantee violation. |
| Do **NOT** set `kVTDecodeFrame_EnableTemporalProcessing` | — | This bit licenses the decoder to delay callbacks for display-order sorting → extra pipeline depth even though the stream has no B-frames. |
| `kVTDecompressionPropertyKey_RealTime` `[VERIFIED-CORPUS]` | `kCFBooleanTrue` | Default = true (header confirmed unchanged through macOS 26.5) but set it explicitly; real-time QoS for the decode pipeline. Do **NOT** set `kVTDecompressionPropertyKey_MaximizePowerEfficiency` at the same time (undefined behavior). |
| `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder` `[VERIFIED-CORPUS]` | `kCFBooleanTrue` (in the decoderSpecification dict) | Hard fail instead of a silent software fallback (HEVC Main10 in software is >30ms). |
| Verify after create: `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder` `[VERIFIED-CORPUS]` | == `kCFBooleanTrue` | Confirms the Media Engine is in use. |

**imageBufferAttributes (destination):**

| Key | Value | Rationale |
|---|---|---|
| `kCVPixelBufferMetalCompatibilityKey` `[VERIFIED-CORPUS]` | `true` | Forces IOSurface-backed buffers → zero-copy `CVMetalTextureCacheCreateTextureFromImage`. |
| `kCVPixelBufferPoolMinimumBufferCountKey` `[VERIFIED-CORPUS]` | `3`–`6` | ALVR visionOS uses 3 minimum; enough in-flight buffers to prevent pool-exhaustion stalls. |
| pixel format | match decoder native (`420YpCbCr8...VideoRange` 8-bit / `420YpCbCr10BiPlanarVideoRange` 10-bit) | Do **NOT** request another format → avoids a VT-internal conversion blit. **Correction:** the copy/conversion is **Apple-documented** (WWDC14 session 513: format mismatch → "extra buffer copy"), not "undocumented". |
| Do **NOT** set `kCVPixelBufferPixelFormatTypeKey` (if targeting visionOS) | — | ALVR notes: "setting pixelFormat *at all* causes a copy to uncompressed MTLTexture buffer" on visionOS 2. On macOS: only a format-incompatible request triggers the `VTPixelTransferSession` blit — not confirmed for native-format requests. |

**Encode-side bitstream for 1-in-1-out decode (set at encode time):**
- H.264 SPS VUI: `bitstream_restriction_flag=1`, `num_reorder_frames=0`, `max_dec_frame_buffering=1`. Without these fields, Apple's HW decoder buffers 4 frames per keyframe with the MAIN profile (W3C WebCodecs #732).
- HEVC SPS: `sps_max_num_reorder_pics[0]=0`.

**Recovery:** on a decode error → check `VTDecompressionSessionCanAcceptFormatDescription`; if OK, request an IDR and keep the session alive (an IDR request = 1 LAN RTT <1ms). **Avoid** session teardown+recreate (~30–100ms stall, corpus-inferred — not Apple-published).

> **Measurements:** ~1–3ms HW decode on M-series (Moonlight #1087/#1249). The macOS 26 Tahoe 80ms regression (#1696) is a render-path issue (Metal/AVSampleBufferDisplayLayer presentation timeout), **not** the HW decode engine.

---

### 5. Render — Metal + display (macOS & iOS)

**Use `CAMetalLayer` + `CVMetalTextureCache`, NOT `AVSampleBufferDisplayLayer`** for the low-latency path (AVSBDL adds ≥1 frame of buffering, Moonlight #1885).

**macOS (`CAMetalLayer`):**

| Symbol | Value | Rationale |
|---|---|---|
| `CAMetalLayer.displaySyncEnabled = false` `[VERIFIED-CORPUS]` | (vsync-off) | Present as soon as the GPU finishes, dropping the entire vsync wait (up to 16.7ms@60Hz); accept tearing. Or `true` + `CAMetalDisplayLink` for vsync-on low-latency. |
| `CAMetalLayer.maximumDrawableCount = 2` `[VERIFIED-CORPUS]` | `2` (macOS) | **Correction (corpus REFUTED):** Apple does **NOT** say "2 is not recommended on iOS" — the only constraint is value ∈ {2,3}, applied uniformly on every platform. 3 drawables → 16–50ms backlog; 2 → converges to ~16ms. The only warning from an Apple engineer: value 2 increases the chance `nextDrawable` returns nil. |
| `CAMetalLayer.framebufferOnly = true` `[VERIFIED-CORPUS]` (default) | — | Enables lossless compression + the compositor fast path. |
| `CAMetalLayer.presentsWithTransaction = false` `[VERIFIED-CORPUS]` (default) | — | Do NOT sync with the CA transaction (adds up to 1 CA frame); only enable when Metal must sync with a UIKit overlay. |
| `CAMetalDisplayLink` `[VERIFIED-SDK QuartzCore header]` (macOS 14.0+ / iOS 17.0+) | replaces CVDisplayLink | **Correction (corpus REFUTED):** the header is `API_AVAILABLE(macos(14.0), ios(17.0), tvos(17.0))` — **NOT** restricted to Apple Silicon. Moonlight adding its own `isAppleSilicon()` guard was their own choice, not an API requirement. |
| `CAMetalDisplayLink.preferredFrameLatency = 1.0` `[VERIFIED-CORPUS]` | `1.0` | **Correction (corpus confirmed):** the unit is **frames** (Float); valid values are only `1.0` or `2.0`. `1.0` = 1 display cycle = the API minimum. The system may exceed the requested latency (windowed macOS). |
| `CAMetalDisplayLink.preferredFrameRateRange = CAFrameRateRangeMake(fps, fps, fps)` `[VERIFIED-CORPUS]` | lock to stream fps | Prevents ProMotion downclocking from causing jitter. |
| `commandBuffer.waitUntilScheduled` (NOT `waitUntilCompleted`) `[VERIFIED-CORPUS]` | — | `Completed` blocks until pixels hit the framebuffer (5–15ms stall in direct mode); `scheduled` only waits for submission (Zed 120fps blog). |

**iOS/iPadOS:**

| Symbol | Value | Rationale |
|---|---|---|
| Info.plist `CADisableMinimumFrameDurationOnPhone = true` `[VERIFIED-CORPUS]` | — | **Mandatory** to unlock ProMotion 120Hz on iPhone; without it → 60Hz cap regardless of API calls. |
| `CAMetalLayer.opaque = true` (= `CALayer.isOpaque`) `[VERIFIED-CORPUS]` | `true` | **Uncertain:** Flutter/Impeller measured presentation delay dropping 21–26ms → ~13ms, but that is **one** isolated observation, **not** an Apple-documented guarantee; the mechanism is the compositor skipping alpha-blending. Set it because it is cheap and safe. |
| `CAMetalLayer.maximumDrawableCount = 2` `[VERIFIED-CORPUS]` | `2` | Minimum pipeline depth (handle nil drawables). Valid on iOS (see the correction above). |
| `CAMetalDisplayLink.preferredFrameRateRange = CAFrameRateRange(minimum:60, maximum:60, preferred:60)` `[VERIFIED-CORPUS]` | for a 60fps stream on a 120Hz client | 60 divides 120 evenly → every frame double-pumps at 16.67ms, zero judder. **Avoid** preferred:120 for a 60fps stream (only double-scans, wasting power). |
| `UIUpdateLink` `[VERIFIED-CORPUS]` (iOS 18+, UIKit path) | `requiresContinuousUpdates = true` | Low-latency mode for UIKit-hosted content; with pure Metal `CAMetalLayer` use `CAMetalDisplayLink`. |

**Zero-copy decode→render (both platforms):**
- `CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)` once at startup.
- For each biplanar YCbCr frame: call `CVMetalTextureCacheCreateTextureFromImage` twice — planeIndex 0 (`.r8Unorm` 8-bit / `.r16Unorm` 10-bit) for Y; planeIndex 1 (`.rg8Unorm` / `.rg16Unorm`) for CbCr. Same IOSurface, zero GPU copy.
- Pin the IOSurface while the GPU is using it: hold a strong `CVMetalTexture` ref inside `commandBuffer.addCompletedHandler` (CVMetalTextureCache manages use-counts internally), or manually `IOSurfaceIncrementUseCount`/`Decrement`.

**Beam-racing pacing:** in the `CAMetalDisplayLink` callback, render the **latest available frame** (do not wait for the frame matching `targetTimestamp` exactly), commit before `targetTimestamp`. Moonlight computes `waitTimeMs = ((targetTimestamp − CACurrentMediaTime())*1000)/2` to wait for the newest frame as close to the deadline as possible.

**Color/EDR — skip the compositor color-match pass:**
- `CAMetalLayer.colorspace = nil` `[VERIFIED-CORPUS]` — pass-through, skips the color-match pass (Apple WWDC16 605: "fastest approach"). Or match the native `NSScreen.colorSpace` (Chromium research: "no additional GPU power"). Setting sRGB-tagged on a P3 display → "nontrivial-but-not-excessive" cost per frame.
- `CAMetalLayer.wantsExtendedDynamicRangeContent = false` `[VERIFIED-CORPUS]` for SDR — avoids the EDR processing pass (WWDC21 10161 "extra processing pass... increases latency and bandwidth"). Available iOS 16+.
- `CAMetalLayer.edrMetadata = nil` — do not assign `CAEDRMetadata` (adds 1 compositor pass).
- SDR path: `pixelFormat = .bgra8Unorm` (32 bit/px). HDR path: `.bgra10a2Unorm` (32 bit/px, same as 8-bit) + PQ/HLG colorspace, **not** `.rgba16Float` (64 bit/px, double the bandwidth). Only 2 formats support EDR: `rgba16Float` and `bgra10a2Unorm`.

> **macOS requires fullscreen for Adaptive Sync/VRR scheduling** (WWDC21 10147, confirmed): a single-window/windowed app gets **no** VRR scheduling — only a fullscreen window (`NSFullScreenWindowMask`) goes through the `NSScreen.minimumRefreshInterval/maximumRefreshInterval` path.

---

### 6. Input — CGEvent / Accessibility injection + local cursor

Activate-then-control model. The host injects input into the target window without raising it; the client draws a local cursor.

| Symbol / technique | Configuration | Rationale |
|---|---|---|
| **Local cursor overlay** `[VERIFIED-CORPUS]` | client draws the cursor from the input stream, NOT encoded into the video | Cursor feedback in ~0–2ms instead of waiting ~15–25ms for the video round trip. The highest-value perceived-latency optimization. Host: `config.showsCursor = false`. |
| `CGEventPostToPid(pid, event)` `[VERIFIED-CORPUS]` (macOS 10.11+) | NOT `CGEventPost` | Delivers the event straight to the target PID, bypassing the global HID stream, without moving the system cursor or needing the window foregrounded. **Correction (corpus uncertain):** this is **not** a pure "Mach IPC round-trip" — it routes through CoreGraphics→WindowServer→app event tap (≥2 hops). Actual latency on Apple Silicon is **unmeasured** (no public benchmark); the 50–200µs estimate is unsubstantiated. |
| `SLPSPostEventRecordTo` `[PRIVATE, VERIFIED-CORPUS]` (SkyLight, dlopen/dlsym) | call twice (old PSN + target PSN) | Activate-without-raise: flips the AppKit-active state for input routing, avoiding the 100–300ms Space switch. **Warning:** paneru #123 shows a SIGABRT on macOS 14.2.1 — but the root cause is `CGSEncodeEventRecord` mis-serializing a buffer (0xFF fill → ObjC class pointer), **not** `SLPSPostEventRecordTo` being restricted. Fix: skip `make_key_window()` on macOS 14. Tahoe 26 unclear. |
| DriverKit virtual HID `[VERIFIED-CORPUS]` | `com.apple.developer.driverkit.userclient-access` entitlement | Injects at the IOHIDSystem layer (the real hardware path), bypassing the `CGXSenderCanSynthesizeEvents()` gate. **Required on macOS Tahoe 26**: an unsigned daemon's `CGEventPost` gets dropped for modifier+key combos → 2–3s input lag (input-leap #2367). |
| `CGEventTap` `[VERIFIED-CORPUS]` (client capture) | `kCGHIDEventTap`, `kCGHeadInsertEventTap`, `kCGEventTapOptionListenOnly` | Passive tap at the HID level (earliest in userspace), immune to `tapDisabledByTimeout` (because listen-only). QoS `.userInteractive` for the run loop. |
| `kTCCServicePostEvent` + Accessibility | entitlement | Required for `CGEventPostToPid` on macOS 14+. The app **must be code-signed** (no bare daemon) to pass the Tahoe 26 gate. |

**Input protocol:**
- Button/key events: send **immediately** (zero queuing), in their own datagram.
- Motion events: batch at a 1ms cadence (matching USB HID 1000Hz polling). Do NOT batch buttons with motion.
- iOS touch: `event.coalescedTouches(for:)` `[VERIFIED-CORPUS]` collects all 240Hz/120Hz samples; send them all instead of just the last sample. `event.predictedTouches(for:)` for extrapolation.
- **NO** motion prediction on LAN: RTT <1 frame (8.3ms@120Hz) → prediction costs complexity for ~0ms gain. The local cursor overlay already removes visual lag.

---

### 7. Threading — RT scheduling (Apple Silicon)

Three overlapping mechanisms; on Apple Silicon **os_workgroup is the primary mechanism** for guaranteed P-core scheduling.

| Symbol / API | Configuration | Rationale |
|---|---|---|
| `thread_policy_set(..., THREAD_TIME_CONSTRAINT_POLICY, ...)` `[VERIFIED-CORPUS]` | `period`, `computation`, `constraint`, `preemptible` in mach ticks | Puts the thread into the kernel RT band, bypassing QoS decay. 60fps: `period=16_666_666ns × denom/numer`, `computation=period/2`, `constraint=period×0.85`, `preemptible=1`. Convert ns→ticks with `mach_timebase_info` (Apple Silicon numer=125, denom=3). **Must be called BEFORE `os_workgroup_join`.** |
| `os_workgroup_interval_create("...", OS_CLOCK_MACH_ABSOLUTE_TIME, NULL)` `[VERIFIED-CORPUS]` | + `os_workgroup_interval_start/finish` every frame | Reports deadlines to the performance controller → keeps the P-cluster active between frames, preventing frequency off-ramp+on-ramp. **PREREQUISITE confirmed:** the joining thread must already have `THREAD_TIME_CONSTRAINT_POLICY`, otherwise `EINVAL` ("thread is not realtime") — **applies only to workgroup type `WORK_INTERVAL_TYPE_COREAUDIO`**; for other workgroup types EINVAL just means "cancelled". |
| `pthread_attr_setschedpolicy(SCHED_RR)` + priority `47–48` `[VERIFIED-CORPUS]` | render/encode threads only | Prevents priority decay; **incompatible with QoS** (a permanent opt-out). Only for threads with a fixed time window, not 100%-continuous ones. |
| `DispatchQueue(qos: .userInteractive)` `[VERIFIED-CORPUS]` | SCK callback queue, VT callback queue | P-core preference + priority inheritance. Sufficient as a baseline; combine with `THREAD_TIME_CONSTRAINT_POLICY` for the most critical threads. |
| `mach_wait_until(deadline)` `[VERIFIED-CORPUS]` | NOT `usleep()` on RT threads | **Correction (corpus uncertain):** the "<600µs 99.9%" figure actually comes from a GitHub comment, micropython #8621 (hardware unknown), **not** Apple forum thread/120403; Apple TN2169 only sets a 500µs soft floor on an idle machine. On Apple Silicon, default threads land on E-cores → need affinity/workgroup. |
| `os_unfair_lock` `[VERIFIED-CORPUS]` | instead of `dispatch_semaphore` for cross-thread signaling | Participates in QoS priority inheritance (boosts a low-QoS holder); semaphores do not donate priority. |
| **NO** `yield()`/`sched_yield()` `[VERIFIED-CORPUS]` | — | **Confirmed (XNU source):** tanks priority to 0 (DEPRESSPRI=MINPRI=0), defers up to 10ms. **Applies to SCHED_RR too** (= TH_MODE_FIXED, no exemption). One yield on a hot thread = blown frame deadline. |
| **NO** `THREAD_AFFINITY_POLICY` on Apple Silicon `[VERIFIED-CORPUS]` | — | Returns `KERN_NOT_SUPPORTED` (46) on ARM. Use workgroups + RT policy to steer onto P-cores instead of pinning cores. |

**Swift caveat `[VERIFIED-CORPUS]`:** avoid Swift on the RT hot path — CoW mutation, the `swift_beginAccess` exclusivity check (16-byte heap alloc), nested function captures, and thrown errors can all allocate → stalling the RT thread. Write the inner loop in C/ObjC or allocation-free Swift.

> **There is no dedicated public os_workgroup for ScreenCaptureKit or VideoToolbox** (only the audio workgroup via `kAudioDevicePropertyIOThreadOSWorkgroup`). The video pipeline creates its own interval workgroup.

---

### 8. Memory — zero-copy (Apple Silicon unified memory)

The whole SCK→VT encode→network→VT decode→Metal pipeline stays zero-copy because every stage operates on the same physical IOSurface.

| Technique | Configuration | Rationale |
|---|---|---|
| SCK → encoder zero-copy `[VERIFIED-CORPUS]` | `CMSampleBufferGetImageBuffer()` → straight into `VTCompressionSessionEncodeFrame` | The IOSurface from SCK is the same memory the HW encoder DMAs. The YCbCr pixelFormat (`'420v'`/10-bit) **must** match the encoder; BGRA forces a conversion pass (WWDC22 "let VideoToolbox handle encoding without color space conversion step"). |
| `VTCompressionSessionGetPixelBufferPool()` `[VERIFIED-CORPUS]` | if GPU pre-processing is needed before encode | The pool vends buffers in exactly the format + IOSurface config the encoder expects → no conversion. |
| Decoder → Metal zero-copy `[VERIFIED-CORPUS]` | `kCVPixelBufferMetalCompatibilityKey: true` + `CVMetalTextureCacheCreateTextureFromImage` | The IOSurface the decoder writes = the MTLTexture the shader reads; on unified memory there is no PCIe copy. |
| **AVOID** `CVPixelBufferCreateWithBytes`/`CreateWithPlanarBytes` `[VERIFIED-CORPUS]` | — | Creates a CPU-memory-only buffer that is **not** IOSurface-backed (QA1781 confirmed) → CVMetalTextureCache fails, forcing a copy. Always use a pool with `kCVPixelBufferIOSurfacePropertiesKey: [:]`. |
| `autoreleasepool { }` `[VERIFIED-CORPUS]` | wrap the entire SCK callback body + VT decode handler | Obj-C objects (CMSampleBuffer, CVMetalTexture, NSData) accumulate in the dispatch queue's pool; burst drains cause 5–30ms pauses (forum thread/725744). |
| `DispatchData(bytesNoCopy:count:deallocator:)` `[VERIFIED-CORPUS]` | instead of `Data(bytes:count:)` for `NWConnection.send` | The `Data` init always copies; `DispatchData` is no-copy with a custom deallocator releasing the CMSampleBuffer ref. **Uncertain:** whether Network.framework copies internally into the kernel send buffer is unclear. |
| Pool sizing `[VERIFIED-CORPUS]` | ≥4–6 buffers (2 frames of encoder pipelining + 1 Metal render) | Avoids `kCVReturnWouldExceedAllocationThreshold` → a CPU stall waiting for a buffer = 1 frame period. |

**Private symbols (high risk):**
- `MTLPixelFormatYCBCR8_420_2P = 500`, `MTLPixelFormatYCBCR10_420_2P = 505` `[PRIVATE]` — single-plane YCbCr texture binding, dropping the matrix-multiply in the shader. **Confirmed Apple-internal SPI** (WebKit defines it under the `#else` of `USE(APPLE_INTERNAL_SDK)`, ALVR labels it "private"). Raw value 500 is correct. **macOS availability is NOT confirmed** from public sources (only circumstantial: MTLTools.framework string table, CMImaging/NRFV4 dylib). MoltenVK maps Vulkan YCbCr → `MTLPixelFormat::Invalid` on macOS. Using it = SPI with no guarantee across OS versions.

---

### Glass-to-glass budget summary (wired LAN, Apple Silicon)

| Stage | 120 fps | 60 fps |
|---|---|---|
| Capture (1 compositor vsync floor) | ~8.3ms | ~16.7ms |
| Encode (HEVC HW, corpus-uncertain) | ~2–4ms (Apple has not published per-frame) | ~2–4ms |
| Network (wired GigE one-way) | <0.1ms | <0.1ms |
| Decode (HW Media Engine) | ~1–3ms | ~1–3ms |
| Render + display scanout (avg half-frame) | ~4.2ms (Metal direct) | ~8.3ms |
| **Realistic floor (corpus)** | **~14–16ms** | **~22–26ms** |

Wi-Fi 6/6E adds 1–3ms (ideal) to 2–5ms (realistic). Cursor via local overlay: ~2–5ms feedback independent of the video pipeline. The encode/decode numbers are marked **uncertain** because Apple publishes no official per-frame latency; the only sources are self-reported (Lumen) or community (Moonlight).

---

## Ranked techniques by latency impact

The table below ranks every latency-reduction lever from **biggest win → marginal**, based on the entire corpus. The "est. ms saved / impact" column uses measured/sourced figures when available; where the corpus is only qualitative, that is stated. The "risk" column reflects the adversarial verdicts (refuted/uncertain) in the corpus — refuted or still-doubtful claims are clearly flagged.

> Convention: ms saved depends heavily on frame rate and operating point. Unless stated otherwise, figures are at 60 fps (frame = 16.67 ms) / 120 fps (frame = 8.33 ms).

| # | Technique | Est. ms saved / impact | Apple support | Difficulty | Risk |
|---|-----------|------------------------|---------------|------------|------|
| 1 | **Low-latency rate control encode** — `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` (H.264) + manual HEVC config (`AllowFrameReordering=false`, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, `RealTime=true`) | **~100 ms** at 720p30 vs the default buffering mode (WWDC21 session 10158) — mostly from removing frame reordering/B-frame reorder buffers | native (H.264); HEVC **empirically functional** on Apple Silicon | low | **MED** — HEVC support is demonstrated by an FFmpeg patch (commit d87210745e, gated `TARGET_CPU_ARM64`), **NOT** Apple documentation; WWDC21 mentions H.264 only. The SDK header has no codec restriction. Risk of silent regression through an OS update. `kVTPropertyNotSupportedErr (-12900)` when querying HW-accel is API incompleteness, NOT evidence of a software fallback (galad87, forum 751291) |
| 2 | **Wired Gigabit Ethernet instead of Wi-Fi** | **2–30 ms** of overhead removed + all Wi-Fi jitter; wired one-way <0.1 ms vs Wi-Fi 6/6E 0.5–2 ms (typical), 4–20 ms spikes under interference | native | low | **LOW** — link-layer physics; no downside beyond requiring a cable |
| 3 | **Client-side cursor overlay** (draw the cursor from the input channel, NOT encoded into video; `SCStreamConfiguration.showsCursor=false`) | **~15–25 ms** for visual cursor feedback on LAN (removes the entire video round-trip for the cursor); cursor appears ~0–2 ms after input vs ~17–30 ms via video | native | medium | **LOW** — RDP/PCoIP/NoMachine all do this; needs out-of-band cursor-shape sharing |
| 4 | **Metal direct render instead of AVSampleBufferDisplayLayer** (client) — `CVMetalTextureCacheCreateTextureFromImage` → `CAMetalLayer` | **8–33 ms** (1–2 frames of buffering); ≥8.3 ms at 120 Hz, ≥16.7 ms at 60 Hz (Moonlight #1885) | native | medium | **MED** — qualitative evidence ("one or more extra frames"), measured on a macOS dGPU (Radeon Pro 580); **no iOS benchmark** of Metal-vs-AVSBDL and Moonlight-iOS has no Metal fallback (corpus uncertain). On Apple Silicon unified memory there is no GPU copy penalty, so the benefit is even clearer |
| 5 | **120fps / ProMotion end-to-end** (host `minimumFrameInterval=1/120` + client `CAMetalDisplayLink` 120 Hz) | **~8.3 ms** lower worst-case vsync wait (16.67→8.33 ms); plus ~4 ms average capture-to-encode | native | low–medium | **MED** — requires a 120 Hz host display (M1 Pro/Max+) AND encode completing within 8.3 ms or SCK drops frames. macOS 15 silently changed the default `minimumFrameInterval` to 1/60 (confirmed); must set explicitly. Note: use `1/target_fps × 0.9` (OBS PR#11896) — do **NOT** use `kCMTimeZero` (that claim was refuted: OBS does not use kCMTimeZero, no SDK header confirms it) |
| 6 | **Avoid AVSampleBufferDisplayLayer audio synchronizer** / use PTS-based fire-and-forget AV sync | **~1000 ms** of `AVSampleBufferRenderSynchronizer` buffering avoided (~1 s buffer ahead) | native | medium | **LOW** — accidentally using synchronizer mode would destroy all the video latency work. The ~1 s figure is community-reported, no official Apple figure (claim_to_verify) |
| 7 | **VideoToolbox HW decode + verify** (`RequireHardwareAcceleratedVideoDecoder=true`, `RealTime=true`) | **5–17 ms** (HW ~1–3 ms vs SW 8–20 ms); HEVC Main10 SW fallback >30 ms | native | low | **LOW** — `flags=0` synchronous completion is **confirmed** in the SDK header (no HW/SW distinction). `RealTime` already defaults to true (confirmed through macOS 26.5) but should be set explicitly; do NOT set together with `MaximizePowerEfficiency` (undefined behavior) |
| 8 | **Display drop policy "always-newest"** (Moonlight pacer: cap 3 frames, drop oldest-first every vsync, target 1) | **8.3–25 ms** (each extra queued frame = 1 frame interval; a 3-frame backlog = 25 ms at 120 fps) | native | medium | **LOW** — verified in moonlight-qt pacer.cpp |
| 9 | **THREAD_TIME_CONSTRAINT_POLICY + os_workgroup for hot threads** | Avoids **5–20 ms** scheduler-induced stalls; replaces usleep's 500–5000 µs variance with `mach_wait_until` <600 µs (99.9%) | native | medium | **MED** — `os_workgroup_join` requires the RT policy first (EINVAL "not realtime" **confirmed** but only for `WORK_INTERVAL_TYPE_COREAUDIO`). The "<600 µs 99.9%" figure is **misattributed** (from micropython issue #8621, hardware unspecified, not Apple forum 120403) and not reproduced on Apple Silicon (uncertain). `yield()` tanks priority to 0 for up to 10 ms — **confirmed** to apply to SCHED_RR too. Swift heap allocations can stall the RT thread |
| 10 | **SCK queueDepth tuning** (=3 for min capture-side latency; consider 5 on GPU load spikes) | Avoids backlog of **up to 116 ms** (queueDepth=8 default at 60 fps); with =3, max backlog 16.6 ms | native | low | **LOW** — the "3–8 strict range" is **refuted**: the real default is **8** (not 3), no documented minimum; queueDepth=1/2 run in production. "3" is just a conservative community default born of confusion with the old CGDisplayStream |
| 11 | **SCK `420v` YCbCr pixel format instead of BGRA** (zero-copy into VideoToolbox) | **~0.5–3 ms** by removing one GPU color-conversion pass at 4K | native | low | **LOW** — WWDC22 confirmed "lowest CPU cost"; removes a full DRAM round-trip |
| 12 | **Zero-copy IOSurface end-to-end** (SCK→VT→VT→Metal, no memcpy; `kCVPixelBufferMetalCompatibilityKey`) | **15–60 µs/frame** of copying avoided; + avoids 5–30 ms deferred-autorelease spikes (autoreleasepool wrapping) | native | low–medium | **LOW** — WWDC21: 62% bandwidth reduction. Note: do **NOT set `kCVPixelBufferPixelFormatTypeKey`** in the decode imageBufferAttributes when it matches the native format (a mismatch triggers a VTPixelTransferSession copy — confirmed via WWDC14 session 513). The visionOS 2 behavior "set pixelFormat at all = copy" is **not confirmed on macOS 14+** (uncertain) |
| 13 | **Opus RESTRICTED_LOWDELAY 5ms frames** (audio) | **~15 ms** vs the Opus 20ms default (7.5 ms vs 22.5 ms algorithmic delay) | partial (libopus, not native) | medium | **LOW** — Sunshine uses exactly this config. Or PCM on LAN = 0 ms codec delay (~3.1 Mbit/s stereo, trivial on wired) |
| 14 | **CoreAudio HAL buffer reduction** (`kAudioDevicePropertyBufferFrameSize=64–128`) | **~8 ms** (512→128 frames: 10.67→2.67 ms; →64: 1.33 ms) | native | medium | **LOW** — must be set before allocating render resources; the minimum is driver-dependent |
| 15 | **LTR recovery instead of full IDR** (`EnableLTR`, `ForceLTRRefresh`) | **30–100 ms** avoided per recovery (LTR-P is 10–30× smaller than an IDR, no bandwidth spike) | native | medium | **MED** — `EnableLTR` is codec-agnostic, HEVC+LTR on Apple Silicon **confirmed feasible** (SDK header has no restriction, FFmpeg ARM64 path). `ForceLTRRefresh` has an internally contradictory type in the header: the annotation says `CFNumberRef`, the doc comment says `kCFBooleanTrue` — must test both at runtime (confirmed inconsistency) |
| 16 | **Skip idle frames + dirtyRects** (SCK) | **high** — avoids encoder queue buildup from idle callbacks; dirtyRects cuts encode time for partial updates | native | low–medium | **LOW** |
| 17 | **`maximumDrawableCount=2`** (lower pipeline depth) | **8–34 ms** (count=3 gives 16–50 ms variable latency; count=2 converges to ~8–16 ms) | native | low–medium | **LOW** — "not recommended for iOS/iPadOS" is **refuted**: Apple only constrains the range to [2,3], no iOS-specific prohibition. The real trade-off: `nextDrawable` may return nil → needs frame-drop logic |
| 18 | **NWParameters `requiredInterfaceType` + `includePeerToPeer=false`** (pin LAN, avoid path eval) | Avoids **50–200 ms** path evaluation + avoids **40–336 ms** AWDL spikes | native | low | **LOW** — guarantees no cellular/AWDL fallback |
| 19 | **serviceClass = .interactiveVideo** (Wi-Fi WMM AC_VI) | **~10× jitter** on congested Wi-Fi (AC_BE ~67 ms → AC_VI/VO ~7 ms); marginal under light load | native | low | **MED** — only sets Wi-Fi 802.11e UP, does **NOT** set IP-header DSCP except on Fastlane networks (confirmed). On wired LAN use the `IP_TOS` setsockopt directly if DSCP is needed. `nw_service_class_interactive_video=2` ≠ `NET_SERVICE_TYPE_VI=3` (different namespaces, private mapping) |
| 20 | **Beat-frequency exact rate match** (host display = client refresh, e.g. both at 60.000 Hz) | **0–16.67 ms** oscillation (60 Hz) eliminated; beat period of 60.000 vs 59.94 ≈ 16.7 s | native | medium | **MED** — requires forcing the host display to exactly 60.000 Hz (not 59.951); EDID may map nominal 60 to 59.951 |
| 21 | **VTCompressionSessionPrepareToEncodeFrames** (pre-warm) + keep the session alive across reconnects | First frame: avoids the init spike (est. 1–10 ms); reconnect: avoids a **30–100 ms** session rebuild | native | low | **MED** — the first-frame spike has no public measurement (open question); the 30–100 ms rebuild is inferred, not Apple-documented |
| 22 | **CAMetalDisplayLink `preferredFrameLatency=1`** | **~8–16 ms** (the default is 2 frames on iOS) | native | low | **LOW** — confirmed: only accepts 1.0 or 2.0; the system may exceed it when needed (windowed macOS). `CAMetalDisplayLink` is **NOT** restricted to Apple Silicon (refuted: only `@available(macOS 14)`; Moonlight added its own `isAppleSilicon()` guard) |
| 23 | **CAMetalLayer.opaque=true** (client) | **~8–13 ms** (21–26 ms → 13 ms, Flutter/Impeller #134959) | native | low | **HIGH-uncertainty** — the 13 ms figure is a **single profiling observation**, no reproducible baseline; Flutter's real fix was a custom IOSurface layer (PR #48226), not this flag. `opaque` is a CALayer property (skips alpha-blending); Apple documents no latency guarantee |
| 24 | **`displaySyncEnabled=false`** (vsync-off, tearing) | **8.3–16.7 ms** (removes the entire vsync wait) | native | low | **MED** — causes tearing on non-adaptive-sync displays; consider adaptive sync (fullscreen) instead |
| 25 | **CAMetalLayer.colorspace = nil** (bypass the compositor color-match pass) | **sub-frame, non-zero** (Apple: "fastest approach"; qualitatively a "nontrivial-but-not-excessive" GPU cost per frame on mismatch) | native | low | **LOW** — no Apple ms figure; trade-off: raw color on a P3 display. Or match the display's native colorspace |
| 26 | **Disable EDR for SDR streams** (`wantsExtendedDynamicRangeContent=false`) | **sub-frame** — WWDC21 10161: EDR tone mapping "involves an extra processing pass... increases latency and bandwidth" | native | low | **LOW** — no ms figure; an FP16 buffer is 2× the bandwidth vs bgra10a2 |
| 27 | **Adaptive sync (VRR) fullscreen** (`presentDrawable:afterMinimumDuration:`) | **3–8 ms** average on a 120 Hz adaptive display | native | medium | **MED** — **fullscreen is a hard requirement** (WWDC21 10147 confirmed; Apple Support 102144 is silent because it covers the OS-level feature, not the app API). Single-window/windowed apps get NO VRR scheduling benefit |
| 28 | **kCMSampleAttachmentKey_DisplayImmediately** (if forced to use AVSampleBufferDisplayLayer) | Bounds display latency to ~1 scan period instead of accumulating 1–3 frames | native | low | **MED** — the "bypass all enqueued frames" behavior comes from forum 14212, not confirmed on macOS 14+ under sustained load (claim_to_verify) |
| 29 | **QUIC keepalive + 0-RTT resumption** (reconnect cold path) | **2–5 ms** (1-RTT LAN) or **0 ms** (0-RTT/keepalive); avoids the re-handshake | native | medium | **MED** — `allowFastOpen` confirmed for the TCP path; **the QUIC 0-RTT property in NWProtocolQUIC is unverified** (claim_to_verify). 0-RTT has no forward secrecy and is replay-susceptible (acceptable for control) |
| 30 | **sendmsg_x / recvmsg_x batch UDP** (raw socket) | **high throughput**, medium per-frame; collapses N syscalls → 1 | partial (PRIVATE syscall) | medium | **MED** — syscalls 480/481 **confirmed stable** on macOS 14+ Apple Silicon; symbols exported from libSystem; but PRIVATE (msghdr_x only in socket_private.h, must forward-declare yourself). **macOS 13 hang** — only use on macOS 14+ |
| 31 | **Pre-trigger Local Network permission** (onboarding) | Avoids **several seconds** of blocking on first cold launch (iOS 14+ privacy gate) | native | low | **LOW** — a correctness/cold-path fix, not steady-state |
| 32 | **Slice-based encoding / sub-frame pipelining** | **~10–12 ms** (Haivision; theoretical (N-1)/N × encode_time) — **BUT not feasible via the public VideoToolbox API** | **unsupported** (VideoToolbox = frame granularity) | exotic | **HIGH** — VideoToolbox output is **frame-granular**, one callback per frame. `MaxH264SliceBytes` is H.264-only, no sub-frame callback. `kVTCompressionPropertyKey_NumberOfSlices`/`NumberOfSubFrameSections` are **private symbols** (confirmed present in .tbd, iOS 9.3–26.x) but have NO public header, NO call sites anywhere, and **completely unknown** behavior when invoked (uncertain). Manual NAL-splitting after the callback only saves ~0.1–1 ms on LAN |
| 33 | **AES-128-GCM encryption (if needed)** vs ChaCha20 | Pick AES-GCM: **~10 µs/frame** saved vs ChaCha20 (4.6 GB/s vs 1.75 GB/s on M1); AES total **<0.1 ms/frame** = negligible | native (QUIC TLS 1.3 picks AES-GCM itself) | low | **LOW** — QUIC is always encrypted (cannot be disabled). Use CryptoKit, not OpenSSL. Throughput numbers are from OpenSSL benchmarks; Apple's internal corecrypto is not publicly benchmarked (claim_to_verify) |
| 34 | **AWDL peer-to-peer (`includePeerToPeer=true`)** for the video stream | **NEGATIVE** — adds 40–336 ms RTT spikes on a ~5 s cycle; AWDL channel-hop 50–200 ms every 10–12 s | partial | low | **HIGH** — Apple DTS: P2P Wi-Fi "hundreds of ms"; infrastructure Wi-Fi is better. **AVOID for video.** Wi-Fi Aware `WAPerformanceMode.realtime` is iOS/iPadOS 26 only (`@available(macOS, unavailable)` confirmed), requires an entitlement |
| 35 | **DriverKit virtual HID injection** (vs CGEventPostToPid) | Avoids the **2–3 s lag** on macOS Tahoe 26 (CGEventPost from an unsigned daemon is blocked); latency = the physical HW path | native (entitlement required) | exotic | **MED** — the "physical HW path latency" figure is a Karabiner claim with no measured comparison. Simpler: use a signed app + `kTCCServicePostEvent` |
| 36 | **CABAC vs CAVLC, profile selection, MaxH264SliceBytes MTU-align** | **marginal** (~7% bitrate for CABAC; slice MTU-align ~1–3 ms) | native | low | **LOW** — on the Apple Silicon HW decoder the CABAC/CAVLC diff is sub-ms; HEVC mandates CABAC |
| 37 | **`preferNoChecksum`, batch send, BSD checksum offload** | **marginal** (~1–5 µs/packet; ~0 with HW offload) | native | low | **LOW** |
| 38 | **HEVC tiles / WPP control** | **N/A** — no API surface | **unsupported** | exotic | **N/A** — the Media Engine handles it internally; no `kVTCompressionPropertyKey` for tiles/WPP |
| 39 | **DPDK / kernel-bypass** | **N/A** on macOS/iOS | **unsupported** | exotic | **N/A** — SIP + the entitlement model block userspace NIC access; NEPacketTunnelProvider is slower, not faster |
| 40 | **RFC 9150 integrity-only ciphers** | **~3 µs/frame** theoretical | **unsupported** (QUIC is AEAD-only) | exotic | **N/A** — not applicable to QUIC/Network.framework |

---

### Do these first (highest leverage, lowest risk)

In implementation-priority order for the target stack (macOS host → macOS/iOS client, LAN, Apple Silicon):

1. **Wired Gigabit Ethernet** (#2) — the foundation. Sub-0.1 ms one-way, zero jitter. ⚠️ On **NetBird** do NOT pin `requiredInterfaceType = .wiredEthernet` (utun=`.other` → breaks); leave the default, the routing table steers 100.64/10 itself ([13](13-netbird-transport.md)). Keep `includePeerToPeer = false`.
2. **Low-latency encode config** (#1) — `EnableLowLatencyRateControl` for H.264; for HEVC manually set `RealTime=true`, `AllowFrameReordering=false`, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, `PrioritizeEncodingSpeedOverQuality=true`, `MaxKeyFrameInterval=INT_MAX`. **Verify HEVC support at runtime** via `VTCopySupportedPropertyDictionaryForEncoder` (since Apple documents H.264 only).
3. **HW decode + verify** (#7) — `RequireHardwareAcceleratedVideoDecoder=true`, `flags=0` synchronous, `RealTime=true`, verify `UsingHardwareAcceleratedVideoDecoder`.
4. **Metal direct render path** (#4) — `CVMetalTextureCacheCreateTextureFromImage` → `CAMetalLayer`, avoid AVSampleBufferDisplayLayer. This is the big differentiator vs Moonlight on macOS.
5. **Client-side cursor overlay** (#3) — `showsCursor=false`, draw the cursor locally. The biggest "perceived responsiveness" lever; the cursor feels instant.
6. **Zero-copy IOSurface + `420v` pixel format** (#11, #12) — throughout the pipeline; wrap per-frame callbacks in `autoreleasepool {}`.
7. **Display drop policy "always-newest"** (#8) + **queueDepth=3** (#10) + **maximumDrawableCount=2** (#17) — zero-depth queue policy, drop oldest-first every vsync.
8. **120fps/ProMotion if both ends support it** (#5) — use `1/target_fps × 0.9` for `minimumFrameInterval`, NOT `kCMTimeZero`. Set explicitly to dodge the macOS 15 1/60 cap.
9. **RT threads for capture/encode/network** (#9) — `THREAD_TIME_CONSTRAINT_POLICY` + `mach_wait_until`; QoS `.userInteractive`; avoid `yield()`; write the hot path in C/ObjC if Swift allocations cause stalls.
10. **Audio: Opus 5ms or PCM + HAL buffer 64–128 frames + PTS fire-and-forget sync** (#13, #14, #6) — absolutely avoid `AVSampleBufferRenderSynchronizer`.

---

### Diminishing returns / probably skip

- **Slice/sub-frame pipelining** (#32) — **skip**. Not feasible via the public VideoToolbox API (frame-granular output, confirmed). The private symbols `NumberOfSlices`/`NumberOfSubFrameSections` exist but their behavior is unknown and risky. Manual NAL-splitting after the callback is only ~0.1–1 ms on LAN — not worth the complexity.
- **AWDL peer-to-peer for video** (#34) — **skip, harmful**. Adds latency instead of reducing it. Use infrastructure Wi-Fi/Ethernet.
- **HEVC tiles/WPP, DPDK kernel-bypass, RFC 9150 ciphers** (#38, #39, #40) — **skip**. No API surface on Apple platforms.
- **CAMetalLayer.opaque=true** (#23) — **try it but do not trust the number**. The 13 ms figure is a single non-reproducible observation; set it (cheap, safe) but expect no guarantee.
- **DriverKit virtual HID** (#35) — **skip initially**, only needed if macOS Tahoe 26 blocks `CGEventPostToPid` for the specific use case. A signed app + `kTCCServicePostEvent` is enough for most.
- **Adaptive sync/VRR** (#27) — **skip for a single-window windowed app**. VRR scheduling requires fullscreen (confirmed); a window-sharing app is usually not fullscreen, so no benefit.
- **DSCP marking via serviceClass on wired LAN** (#19) — **marginal on wired**. Only sets Wi-Fi UP, no IP DSCP except Fastlane. Worth it for multi-client Wi-Fi; nearly meaningless on a dedicated wired LAN.
- **Encryption tuning ChaCha vs AES** (#33) — **negligible** on Apple Silicon (<0.1 ms/frame with HW AES-GCM). Just make sure ChaCha20 is not accidentally chosen; QUIC handles it. On a physically isolated LAN, consider plaintext video + an encrypted control channel (the Moonlight model).
- **`preferNoChecksum`, batch send micro-opts** (#37) — **marginal** with modern HW checksum offload.

> **Cross-cutting measurement note:** the latency overlays of streamers (Moonlight stats, the Virtual Desktop indicator) **under-report by ~40 ms** because they skip capture delay, compositor buffering, and display scanout (Greendayle). Use an LED+photodiode rig (~21 ns resolution) or a 240/1000 fps camera to measure true glass-to-glass; if the sum of software stages deviates >1 ms from the hardware measurement, there is a clock/instrumentation bug.

---

## Verified API claims, corrections & Phase-0 validation list

This section consolidates all the adversarial-verification verdicts in the corpus into a single source of truth for the design phase. Every "load-bearing" claim — one that, if wrong, would break the architecture or inflate/misjudge the latency budget — carries a verdict (`confirmed` / `refuted` / `uncertain`), a confidence level, and a corrected statement. **Golden rule: any line with a `refuted` or `uncertain` verdict must NOT be a hard assumption in the design — it must go into a Phase-0 spike to be confirmed by measurement on the target hardware (Apple Silicon, macOS 14+).**

### 1. Verdict summary tables (load-bearing API claims)

#### 1.1 Capture — ScreenCaptureKit

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| C1 | `minimumFrameInterval = kCMTimeZero` enables native-refresh delivery; the SDK header says so; OBS PR #11896 proves it | **refuted** | high | `kCMTimeZero` is NOT used by OBS and NO Apple header says so. OBS PR #11896 sets `minimumFrameInterval = (1/target_fps) × 0.9` — a concrete `CMTime`, ~10% shorter than the frame period, NOT zero. Reason: setting the exact fps reciprocal drops frames ([OBS PR #11896](https://github.com/obsproject/obs-studio/pull/11896)). **The design must use the explicit 0.9× value, not kCMTimeZero.** |
| C2 | The default `minimumFrameInterval` changed to `1/60` in macOS 15 (even on ProMotion) | **confirmed** | high | Correct. SDK header diff: macOS 14.5 says default = 0 (unthrottled); macOS 15.5 says default = `1/60`. Apple updated the header docstring (but never noted it in release notes). To capture at native refresh, `minimumFrameInterval` must be set explicitly ([macos-sdk diff](https://sourcegraph.com/github.com/alexey-lysiuk/macos-sdk), [OBS #11778](https://github.com/obsproject/obs-studio/issues/11778)). |
| C3 | `queueDepth` is strictly valid 3–8, default 3 | **refuted** | high | The default is **8** (not 3). The header only says "should not exceed 8" (a soft ceiling) — there is NO hard floor of 3. Values 1 and 2 run successfully in multiple shipping projects (daylight-mirror's 3→2: P95 RTT 21.6ms→18.8ms). "3" is the default of the old CGDisplayStream API, mistakenly carried over. **queueDepth=2 for minimum latency is valid; 3 is the conservative setting.** ([SCStream.h:273-276](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth)) |
| C4 | `SCStreamFrameInfoDisplayTime` shares a clock domain with `CACurrentMediaTime()` (mach_absolute_time) | **confirmed** | high | Correct. SCStream.h confirms it is "mach absolute time"; `CACurrentMediaTime()` = `mach_absolute_time()` converted to seconds. NO domain conversion needed — just a ticks→seconds unit conversion via `mach_timebase_info`. The "negative latency" forum report is a separate runtime/PTS bug, not a domain mismatch ([SCStream.h:399](https://developer.apple.com/forums/thread/785046)). |

#### 1.2 Encode — VideoToolbox

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| E1 | `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` works with HEVC on Apple Silicon, "confirmed by an SDK comment" | **uncertain** → (more detail at E2) | high | The "an SDK comment says so" part is WRONG. The sentence "supported only for H.264 on Intel… both on Apple Silicon" comes from an **FFmpeg author's commit message (Cameron Gutman)**, NOT an Apple header. Apple's official doc (WWDC21) mentions H.264 only. HEVC + low-latency RC runs on Apple Silicon per FFmpeg's empirical evidence (PR #20453, gated `TARGET_CPU_ARM64`), but **with no guarantee from Apple** ([WWDC21 10158](https://developer.apple.com/videos/play/wwdc2021/10158/), [FFmpeg](https://www.mail-archive.com/ffmpeg-devel@ffmpeg.org/msg185545.html)). |
| E2 | The macOS 26.5 SDK header still says "supported video codec type: H.264" | **refuted** | high | The header does NOT contain the phrase "supported video codec type: H.264" in any version (15.4 or 26.5) — the constant's docblock is entirely codec-agnostic. That phrase exists only in the WWDC21 transcript. HEVC works on ARM64 per FFmpeg. **Must confirm at runtime; risk of silent regression across OS releases.** |
| E3 | Whether `kVTCompressionPropertyKey_EnableLTR` works with HEVC low-latency is unclear (WWDC demoed H.264 only) | **refuted** | high | The EnableLTR header (macOS 12.0/iOS 15.0) has no codec restriction whatsoever. FFmpeg production code confirms HEVC low-latency RC runs on ARM64 and EnableLTR applies in the same session path. **HEVC + EnableLowLatencyRateControl + EnableLTR is a viable combination for macOS 14+/Apple Silicon**, but validate at runtime via `VTCopySupportedPropertyDictionaryForEncoder`. |
| E4 | `kVTEncodeFrameOptionKey_ForceLTRRefresh` is a `CFNumberRef` (not CFBoolean as WWDC said) | **confirmed** | high | Correct. The inline annotation in the header says `// CFNumberRef, Optional`, BUT the `@abstract` in the same header says "Set this option to kCFBooleanTrue" — **an internal contradiction in Apple's header.** The runtime behavior is not resolved by the header. **Must test both `kCFBooleanTrue` and `@(1)` (CFNumberRef) at runtime to learn which one the encoder accepts** ([VTCompressionProperties.h:1265-1277](https://developer.apple.com/videos/play/wwdc2021/10158/)). |
| E5 | `kVTCompressionPropertyKey_MaxFrameDelayCount = 0` means "default behavior / no limit" | **refuted** | high | WRONG — there is no "value of zero implies default behavior" sentence in the MaxFrameDelayCount block (that sentence belongs to the adjacent `MaxH264SliceBytes` property). Per the header's formula: M=0 ⇒ "before the encode call for frame N returns, frame N must have been emitted" = **synchronous/immediate emit**. The no-limit default is `kVTUnlimitedFrameDelayCount = -1`, not 0. **Set `MaxFrameDelayCount = 0` to force one-in-one-out.** |
| E6 | `kVTCompressionPropertyKey_AllowOpenGOP` defaults to `kCFBooleanTrue` for HEVC | **confirmed** | high | Correct and unchanged from macOS 15.4→26.5/iOS. **HEVC allows Open-GOP by default — MUST set `false` explicitly** for clean IDR recovery (single-window streaming needs every IDR to be independently decodable) ([VTCompressionProperties.h:186-197](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_allowopengop)). |

#### 1.3 Slice-pipelining (private symbols)

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| S1 | `kVTCompressionPropertyKey_NumberOfSlices` exists and "can be set without crashing" | **uncertain** | high | The symbol exists in the .tbd from iOS 9.3→26.x (CONFIRMED), but it is **PRIVATE** — no declaration in any public header. The "can be set without crashing" part has NO evidence; the behavior when passed to `VTSessionSetProperty` (ignore/error/crash) is **unknown**. Do not use in the design unless a spike confirms it. |
| S2 | `kVTCompressionPropertyKey_NumberOfSubFrameSections` has an observable effect | **uncertain** | high | A real symbol, exported from iOS 13→26.5, but with no header/doc/OSS call site anywhere. Its effect when set is unknown — cannot be refuted as "no-op" but there is also no evidence it works. **Drop from the main design.** |
| S3 | `kVTSampleAttachmentKey_SliceAttachments` / `SliceDataLength` appear in the output attachment dict | **uncertain** | high | They are exported PRIVATE symbols (resolving to the strings "SliceAttachments"/"SliceDataLength"), but they are NOT in any public header and **whether the runtime populates them is unconfirmed.** Do not rely on them for manual NAL splitting. **Architectural conclusion: VideoToolbox output is frame-granular; true NVENC-style sub-frame pipelining is NOT available via the public API — drop tiles/WPP/slice-callbacks from the design.** |

#### 1.4 Decode — VideoToolbox

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| D1 | `kVTDecompressionPropertyKey_RealTime` defaults to `kCFBooleanTrue` | **confirmed** | high | Correct, verbatim in the 15.4 & 26.5 headers: "default is true; setting NULL ≡ kCFBooleanTrue". It is a **hint, not a contract** — still set it explicitly. **Must not be set together with `MaximizePowerEfficiency` (undefined behavior).** |
| D2 | `flags = 0` guarantees synchronous decode; but forum 19046 says it can still be async with `kVTDecodeInfo_Asynchronous` | **uncertain** | medium | The header guarantee ("the callback completes before DecodeFrame returns") is CONFIRMED, for both HW/SW. The forum-19046 part could NOT be verified (403). The Apple Silicon HW decoder may dispatch internally async and set `kVTDecodeInfo_Asynchronous` in the callback infoFlags **while the calling thread still blocks** — architecturally plausible but unconfirmed by any source. **Use flags=0 for synchronous; if pipelining CPU work in parallel, use async + semaphore.** |
| D3 | Setting a mismatched pixel format in `destinationImageBufferAttributes` causes an extra copy (but "Apple never documented it") | **refuted** | high | Apple DID document it — WWDC14 Session 513: requesting a non-native format (e.g. BGRA when the decoder outputs YUV) will "force an extra buffer copy". The speculation that "unified memory might optimize this away" has **no evidence** — unified memory removes the PCIe transfer, NOT the compute cost of conversion. **Must match the decoder's native format (`420YpCbCr8BiPlanarVideoRange` 8-bit / `420YpCbCr10BiPlanarVideoRange` 10-bit).** |

#### 1.5 Display / Compositor (macOS + iOS)

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| DP1 | `CAMetalDisplayLink` runs on Apple Silicon only | **refuted** | high | The header declares `API_AVAILABLE(macos(14.0), ios(17.0), tvos(17.0))` — **NO Apple Silicon restriction.** Runs on every Mac on macOS 14+ (Intel or AS). The `isAppleSilicon()` guard is Moonlight's own choice (ProMotion frame-pacing reasons), NOT an Apple requirement. |
| DP2 | `CAMetalDisplayLink.preferredFrameLatency = 1.0` means 1 display cycle | **confirmed** | high | Correct — the unit is **frames**; 1.0 = one display cycle = the API minimum. **Only the values 1.0 and 2.0 are accepted** (Apple marks this Important). The system may exceed the requested level (windowed macOS). Set = 1.0 for streaming. |
| DP3 | Adaptive sync requires fullscreen (WWDC21) but Apple Support 102144 never mentions it | **confirmed** | high | Both halves are true. WWDC21 session 10147 requires a fullscreen window (NSFullScreenWindowMask) for the Adaptive-Sync *scheduling* APIs; Support 102144 only describes enabling it at the OS level. **Consequence for a single-window app: a NON-fullscreen app gets NO VRR scheduling — windowed falls back to the fixed-rate compositor path.** |
| DP4 | `maximumDrawableCount = 2` is "not recommended for iOS/iPadOS" (per Apple) | **refuted** | high | Apple has NO "not recommended for iOS/iPadOS" guidance. The only constraint is value ∈ {2,3}. The only engineer warning: count=2 increases the chance `nextDrawable` returns nil (frame drop) — platform-neutral. **`maximumDrawableCount = 2` is fully supported on iOS/iPadOS and is the right choice for minimum latency (with nil handling).** |
| DP5 | `CAMetalLayer.opaque = true` cuts presentation latency to ~13ms on ProMotion | **uncertain** | high | The ~13ms figure is one isolated profiling measurement by one Flutter engineer (issue #134959), not reproduced, not an Apple-guaranteed property. `opaque` inherits from `CALayer.isOpaque`; Apple only documents that it allows skipping alpha-blending. **Setting isOpaque=true is cheap and sensible, but do not treat "13ms" as a budget number — measure it yourself.** |
| DP6 | AVSampleBufferDisplayLayer adds "1+ frame" of buffering vs Metal on iOS | **uncertain** | medium | The "1+ frame" figure comes from a *subjective* report on **macOS** (discrete GPU, Moonlight #1885), NOT a measurement on iOS. Compositor architecture differences (macOS WindowServer vs iOS backboardd) make the transfer to iOS uncertain. **The design picks the Metal-direct path to eliminate the risk; if AVSampleBufferDisplayLayer is used, set `kCMSampleAttachmentKey_DisplayImmediately = true` and measure the comparison in a spike.** |

#### 1.6 Transport — Network.framework / BSD sockets / Wi-Fi QoS

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| N1 | `serviceClass = .interactiveVideo` maps to `NET_SERVICE_TYPE_VI`; the swiftinterface confirms it; described as "inelastic flow, constant packet rate" | **uncertain** | medium | The mapping is *structurally plausible* but NOT verifiable from public sources (the translation table lives in closed Network.framework code). The swiftinterface only shows case names, NOT integers. There is a separate C enum `nw_service_class_interactive_video = 2` (≠ `NET_SERVICE_TYPE_VI = 3`). The "inelastic/constant packet rate" description belongs to VO (voice) and is WRONG — VI is actually "elastic flow, constant packet interval, variable rate". **Still use `.interactiveVideo` for the video flow, but do not treat the integer mapping as certain.** |
| N2 | `SO_NET_SERVICE_TYPE` sets the Wi-Fi 802.11e UP but does NOT set IP-header DSCP on modern macOS | **confirmed** | high | Correct for ordinary Ethernet and non-Fastlane Wi-Fi. The mechanism is gating on `IFEF_QOSMARKING_ENABLED` (enabled only by Cisco Fastlane), NOT a version regression. **Important: to write DSCP on LAN/Ethernet you must use the `IP_TOS`/`IPV6_TCLASS` setsockopt directly** — the kernel does NOT zero a user-set ip_tos on non-Fastlane interfaces. On Fastlane Wi-Fi, IP_TOS is ignored. |
| N3 | Network.framework user-space networking (Skywalk/flowsw, zero-copy) is active on macOS 12+ when the firewall is off | **uncertain** | medium | (1) The firewall condition is **version-dependent**: macOS 14 with firewall on ⇒ BSD-socket fallback; macOS 15.3+ firewall no longer forces the fallback. (2) "Zero-copy" is imprecise — Apple describes it as a path that avoids BSD sockets via channel objects, never calls it "zero-copy". (3) The firewall is NOT the only trigger — iCloud Private Relay and NE VPNs also cause fallback. **Verify with `sudo skywalkctl flow -n -P <pid>` on the target machine.** |
| N4 | `sendmsg_x` (481) / `recvmsg_x` (480) are stable and callable on macOS 14+ Apple Silicon | **confirmed** | high | Correct. Syscall numbers are stable across the 10.10→26.5 SDKs, symbols exported from libSystem, present in the public `syscall.h`. "PRIVATE" only means the `msghdr_x` struct lives in `socket_private.h` (must forward-declare it yourself) and there is no man page. **macOS 13 has a hang bug ⇒ the "macOS 14+" qualifier is load-bearing and accurate** ([xnu syscalls.master:734-740](https://github.com/oven-sh/bun/blob/main/src/analytics/lib.rs)). |
| N5 | `net_qos_policy_restricted` default = 0 ⇒ every app gets Wi-Fi L2 AC_VI marking without MDM | **refuted** | high | Default = 0 (CONFIRMED) but the meaning was misunderstood. restricted=0 merely *permits* a socket to raise QoS when it *explicitly requests* a higher service type; the default traffic class is `SO_TC_BE` (AC_BE), it does NOT auto-promote to AC_VI. An app that sets no service type ⇒ stays at AC_BE. **Must explicitly set `.interactiveVideo`/`NET_SERVICE_TYPE_VI` to get AC_VI.** |
| N6 | QUIC datagram TLS encryption overhead on LAN is ~0.1–0.5ms | **uncertain** | high | The figure is an estimate of total user-space QUIC processing overhead, NOT "TLS encryption overhead". Pure AES-GCM cost on Apple Silicon is **sub-microsecond** (<0.001ms for a 1400-byte packet at 4–11 GB/s HW-accel). The dominant overhead is user-space packet processing, not the cipher. **Must benchmark NWConnection QUIC datagram vs plain UDP on this stack yourself.** |

#### 1.7 Realtime threads / scheduling

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| RT1 | `os_workgroup_join` returns EINVAL = "thread is not realtime" (must set THREAD_TIME_CONSTRAINT_POLICY first) | **confirmed** | high | Correct, **but scope-limited**: it applies only to workgroups of type `WORK_INTERVAL_TYPE_COREAUDIO` (the CoreAudio HAL workgroup). For other workgroups, EINVAL just means "workgroup was cancelled". Kernel check: `sched_mode != TH_MODE_REALTIME && saved_mode != TH_MODE_REALTIME`. The documentation gap is real ([xnu work_interval.c:679-685](https://developer.apple.com/forums/thread/697874)). |
| RT2 | `mach_wait_until` on an RT thread is < 600µs at 99.9% (source: forum thread/120403) | **uncertain** | high | **Wrong source**: the figure comes from an informal comment by @dlech in micropython issue #8621 (hardware unspecified), NOT forum 120403. Apple TN2169 only states a 500µs soft floor on an idle machine, with no percentile commitment. On Apple Silicon there is extra doubt because default threads land on E-cores. **Must measure yourself with P-core affinity / Audio Workgroup enrollment.** |
| RT3 | `yield()`/`sched_yield()` drops priority to 0 for up to 10ms | **confirmed** | high | Correct. XNU: `sched_yield()` → `swtch_pri(0)` → `thread_depress_abstime(1 × std_quantum)`; std_quantum=10ms at 100Hz; DEPRESSPRI=MINPRI=0. **Applies to SCHED_RR too (TH_MODE_FIXED) — no exemption.** 10ms is the upper bound (may be rescheduled sooner on a lightly loaded system). **Absolutely ban `yield()` on hot media threads; use `mach_wait_until`.** |

#### 1.8 Zero-copy / memory

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| Z1 | `SCStreamConfiguration.pixelFormat` supports `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` ('x420') for window capture on macOS 14+ | **refuted** | high | The 10-bit YCbCr format the header lists is **'xf44' (4:4:4 full-range)**, NOT 'x420' (4:2:0 video-range). 'x420' is not in the supported list. The HDR APIs (`captureDynamicRange`, `Preset`) require **macOS 15.0**, not 14.0. **For 10-bit HDR use `SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)` (macOS 15+); assigning 'x420' directly is undocumented.** |
| Z2 | Setting `kCVPixelBufferPixelFormatTypeKey` in VTDecompressionSession causes a copy blit on macOS (the ALVR comment says visionOS 2) | **uncertain** | medium | The ALVR comment only covers **visionOS 2** ("setting pixelFormat at all causes a copy"). On macOS, the header confirms a copy (via `VTPixelTransferSession`) only when the format is **incompatible** with the native decoder output — NOT unconditionally. Whether the visionOS 2 behavior (copy even with the native format) applies to macOS 14+ is unclear. **Spike: try omitting the pixelFormat key, let the decoder output native, measure.** |
| Z3 | The private `MTLPixelFormatYCBCR8_420_2P = 500` (and siblings) are available on macOS 14+ Apple Silicon | **uncertain** | high | The raw value 500 is CONFIRMED; it is **Apple-internal SPI** (WebKit defines it under the `#else` of `#if USE(APPLE_INTERNAL_SDK)`). NOT in the public enum, no `API_AVAILABLE`. MoltenVK maps the corresponding YCbCr formats to `Invalid` on macOS. **This is undocumented SPI with no OS-version guarantee — use only as an optional optimization with a 2-plane shader fallback.** |

#### 1.9 Wi-Fi / AWDL

| # | Original claim | Verdict | Confidence | Corrected statement / what to use |
|---|---|---|---|---|
| W1 | The AWDL 5GHz social channels are ch 44 and ch 149 | **confirmed** | high | Correct (ch 6 on 2.4GHz, ch 44/149 on 5GHz), from reverse-engineering (Seemoo Lab, OWL). Never officially confirmed by Apple. **Configure the AP to use ch 44/149 to eliminate the 50–200ms AWDL spikes.** |
| W2 | Wi-Fi Aware (`WAPerformanceMode.realtime`) does NOT exist on macOS 26 | **confirmed** | high | Correct — the macOS 26.4 swiftinterface header has an explicit `@available(macOS, unavailable)` (compile-time). The subsystem runs internally (the wifip2pd daemon) but exposes no API to macOS devs. **Wi-Fi Aware is for iOS/iPadOS 26+ clients only, not macOS.** |

### 2. CORRECTIONS to the project's earlier design

These are the points where the corpus/original stack description **contradicts a verdict** and must be fixed before coding:

1. **`minimumFrameInterval = kCMTimeZero` (C1, refuted).** The project context and the capture-floor summary proposed `kCMTimeZero`. **FIX:** use `config.minimumFrameInterval = CMTimeMake(1, targetFPS * 110/100)` (~10% shorter per OBS PR #11896). `kCMTimeZero` is unproven and absent from the OBS code.

2. **`queueDepth` "minimum 3" (C3, refuted).** Several corpus techniques say "3 is the minimum". **FIX:** the real default is 8; no hard floor exists; `queueDepth = 2` is valid and gives lower latency (with fast IOSurface release handling). Use 2 or 3 depending on measured release deadlines.

3. **`EnableLowLatencyRateControl` + HEVC "confirmed by the SDK" (E1/E2, refuted/uncertain).** **FIX:** treat this as *empirical* behavior on Apple Silicon only (FFmpeg evidence), NOT an Apple guarantee. The design must have a runtime-probing code path (`VTCopySupportedPropertyDictionaryForEncoder`) and a manual HEVC low-latency config fallback (E3/E5/E6). Warning: `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` returns `kVTPropertyNotSupportedErr (-12900)` in low-latency mode — that is NOT evidence of lost HW accel; the real missing-HW gating error is `-12902`.

4. **`ForceLTRRefresh` type (E4, confirmed internal contradiction).** **FIX:** the header contradicts itself (annotation `CFNumberRef` vs abstract `kCFBooleanTrue`). Code must try both and pick whichever the encoder accepts at runtime — do not hardcode one type.

5. **The meaning of `MaxFrameDelayCount = 0` (E5, refuted).** **FIX:** 0 = synchronous one-in-one-out emit (correct for low-latency), NOT "default/no-limit". This is actually what we WANT — just make sure it is not misread as "let the encoder buffer freely".

6. **`AllowOpenGOP` for HEVC (E6, confirmed).** **FIX:** HEVC defaults to `true` — MUST set `false` explicitly. If the old design assumed "closed GOP by default", that was wrong.

7. **Slice-pipelining/tiles/WPP (S1–S3, uncertain).** **FIX:** drop the expectation of NVENC-style sub-frame pipelining. VideoToolbox output is frame-granular; the private symbols are untrustworthy. The only available parallelism is **inter-frame pipelining** (capture N+1 in parallel with transmit/decode of N).

8. **Decode pixel-format mismatch (D3, "unified memory optimizes it away" refuted).** **FIX:** must match the decoder's native format; do NOT assume unified memory removes the conversion cost. Do not set `kCVPixelBufferPixelFormatTypeKey` to anything non-native.

9. **DSCP via `SO_NET_SERVICE_TYPE` (N2, confirmed).** **FIX:** on LAN/Ethernet, writing IP-header DSCP requires `IP_TOS`/`IPV6_TCLASS` directly; `SO_NET_SERVICE_TYPE`/`.interactiveVideo` only controls Wi-Fi L2 UP. Use both (L2 via serviceClass, L3 via IP_TOS) if priority on a managed switch is needed.

10. **AC_VI "automatic without MDM" (N5, refuted).** **FIX:** must set the service type explicitly; the default is AC_BE. `net_qos_policy_restricted=0` only *permits*, it does not *auto-promote*.

11. **`maximumDrawableCount=2` "should not be used on iOS" (DP4, refuted).** **FIX:** use 2 on both macOS and iOS for minimum latency (handle nil drawables). Note: Moonlight/Apple DTS recommend 3 on macOS to avoid starvation — that is a trade-off to measure in a spike, not a prohibition.

12. **`CAMetalDisplayLink` "Apple Silicon only" (DP1, refuted).** **FIX:** do not gate on `isAppleSilicon()` just out of fear the API is missing — it exists on every Mac on macOS 14+. Only gate for ProMotion-specific reasons.

13. **10-bit capture format (Z1, refuted).** **FIX:** do not assign `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` ('x420') to `SCStreamConfiguration.pixelFormat`. For 10-bit HDR use `SCStreamConfiguration(preset:)` (macOS 15+) or 'xf44' (4:4:4). Note: HDR capture requires **macOS 15.0**, not 14.0 — adjust the OS-support matrix.

14. **Adaptive sync (DP3, confirmed).** **FIX:** a single-window (non-fullscreen) app gets NO VRR scheduling. If VRR is needed, fullscreen is required — conflicting with the "single window" differentiator. Architecture decision: either accept the fixed-rate compositor for windowed, or offer an optional fullscreen mode on the client.

### 3. Phase-0 spike — empirical validation checklist (MANDATORY)

Every `refuted`/`uncertain` item above must be closed by measurement on the target hardware (host: Apple Silicon Mac on macOS 14 + macOS 15 + macOS 26 if available; client: macOS + iPhone/iPad 120Hz ProMotion). Measure with the unified clock `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` and `mach_timebase_info` (Apple Silicon: numer=125, denom=3 — **confirm on M2/M3/M4 since only M1 was publicly measured**).

**A. Capture (ScreenCaptureKit)**
- [ ] **C1/C2 — minimumFrameInterval:** On ProMotion 120Hz, measure the actual delivered fps with (a) the default (expect 60), (b) `1/120`, (c) `(1/120)×0.9`, (d) `kCMTimeZero`. *Measure:* count `complete` callbacks over 10s on testufo-style content. *Pass:* find the value giving a stable ≥115 fps with no drops.
- [ ] **C3 — queueDepth:** Try queueDepth = 1, 2, 3. *Measure:* frame-drop rate + capture→encode-submit latency while the encoder is busy. Confirm the release deadline `minimumFrameInterval × (queueDepth−1)` is met with VT HW encode. *Pass:* pick the smallest value that does not stall.
- [ ] **C4 — displayTime clock:** Compare `SCStreamFrameInfoDisplayTime` (ticks→ns via mach_timebase) against `CACurrentMediaTime()*1e9` for the same frame. *Pass:* a positive, reasonable delta (~a few ms), never negative. If negative ⇒ investigate as a separate PTS bug.
- [ ] **Z1 — pixel format:** Enumerate the formats `SCStreamConfiguration` actually accepts; try '420v' (8-bit), 'xf44' (10-bit), and the HDR preset (macOS 15+). *Measure:* confirm IOSurface backing + no extra conversion pass when feeding straight into the VT encoder.

**B. Encode (VideoToolbox HEVC)**
- [ ] **E1/E2 — HEVC low-latency RC:** Create an HEVC VTCompressionSession with `EnableLowLatencyRateControl=true`; call `VTCopySupportedPropertyDictionaryForEncoder`. *Measure:* session creation succeeds, the HW engine engages (cross-check Activity Monitor GPU 0%, measure per-frame encode time). *Pass:* HEVC 1080p60 & 4K60 encode < frame budget; on failure ⇒ activate the manual fallback config (E3/E5/E6).
- [ ] **E4 — ForceLTRRefresh type:** Send an LTR refresh with `kCFBooleanTrue` and then with `@(1)` (CFNumberRef). *Measure:* whether the output frame is an LTR-P (smaller than IDR), whether there are errors. *Pass:* determine which type the encoder accepts.
- [ ] **E3 — EnableLTR + HEVC:** Enable EnableLTR on an HEVC low-latency session, run the ACK-token loop. *Pass:* receive `RequireLTRAcknowledgementToken` on output, ForceLTRRefresh produces an LTR-P instead of an IDR.
- [ ] **Per-frame encode latency (open question):** Measure `encode_done_ns − encode_submit_ns` for HEVC Main10 at 1080p/4K @ 60/120fps. *Goal:* establish the real budget numbers (the ~3.3ms/1080p theoretical ceiling is throughput, not latency).
- [ ] **First-IDR spike:** Measure the first frame WITH and WITHOUT `VTCompressionSessionPrepareToEncodeFrames`. *Pass:* quantify the cold-start penalty (corpus: no public number).

**C. Decode + Render**
- [ ] **D2 — flags=0 sync:** Measure `decode_done − decode_submit` with flags=0; check `kVTDecodeInfo_Asynchronous` in the callback infoFlags. *Pass:* confirm the callback fires before DecodeFrame returns; record whether there is internal async.
- [ ] **D3 / Z2 — destination pixel format:** Compare 3 configs: (a) omit the pixelFormat key, (b) set native `420YpCbCr10BiPlanarVideoRange`, (c) set BGRA. *Measure:* decode latency + GPU blit pass (Instruments). *Pass:* pick the config with no extra copy on macOS 14+.
- [ ] **DP6 — AVSampleBufferDisplayLayer vs Metal:** A/B on both macOS and iOS clients: VTDecompressionSession→CVMetalTextureCache→CAMetalLayer vs AVSampleBufferDisplayLayer (with `DisplayImmediately=true`). *Measure:* glass-to-glass with a high-speed camera (240fps/1000fps) or a photodiode rig. *Pass:* determine which path is lower and by how many ms — do NOT rely on the speculated "1+ frame".
- [ ] **Z3 — private YCbCr MTLPixelFormat:** Try mapping a decoded 10-bit buffer to `MTLPixelFormat(rawValue:505)`. *Pass:* works ⇒ use as an optional optimization; fails ⇒ fall back to the 2-plane r16Unorm/rg16Unorm shader. **Do not architecturally depend on this symbol.**
- [ ] **DP5 — opaque:** Measure presentation latency with `isOpaque` true vs false on ProMotion. *Pass:* confirm the direction of improvement (do not expect exactly "13ms").

**D. Transport**
- [ ] **N3 — user-space networking:** Run `sudo skywalkctl flow -n -P <pid>` with firewall ON/OFF on macOS 14 AND 15. *Pass:* confirm flowsw entries; record the fallback conditions (firewall/Private Relay/VPN).
- [ ] **N4 — sendmsg_x/recvmsg_x:** Forward-declare `msghdr_x`, call `sendmsg_x(fd, msgs, N, 0)` in batch. *Measure:* syscall count drops N×, throughput. *Pass:* runs without crashing on macOS 14+ AS; compare against per-packet sendmsg.
- [ ] **N6 — QUIC vs UDP overhead:** Microbench NWConnection QUIC datagram send-to-send vs plain UDP send-to-send on wired LAN, ~1400B packets. *Measure:* the ns/packet delta with Instruments System Trace. *Pass:* quantify the real overhead (the corpus only estimates).
- [ ] **N1/N5 — actual QoS marking:** Set `.interactiveVideo` + `IP_TOS=AF41<<2`; capture packets with Wireshark on the LAN. *Measure:* the DSCP byte in the IP header (expect 0 for SO_NET_SERVICE_TYPE alone; non-zero for IP_TOS); confirm Wi-Fi AC_VI via air capture if available. *Pass:* understand exactly which mechanism sets what.

**E. Realtime threads / scheduling**
- [ ] **RT1 — os_workgroup_join EINVAL:** Try joining the CoreAudio workgroup WITHOUT setting THREAD_TIME_CONSTRAINT_POLICY (expect EINVAL) and then WITH it (expect OK). *Pass:* confirm the required ordering; determine whether a custom video workgroup needs this condition.
- [ ] **RT2 — mach_wait_until jitter:** Measure wakeup jitter on an RT thread (THREAD_TIME_CONSTRAINT_POLICY) WITH and WITHOUT os_workgroup_interval, with and without P-core enrollment. *Pass:* build the real p50/p99/p99.9 distribution on M-series (do not trust "600µs").
- [ ] **DVFS ramp (open question):** Measure the P-core frequency ramp time on the target chips (M2/M3/M4) via IOReport CPU Performance States residency. *Pass:* confirm whether ~70ms (M1) still holds or is shorter; decide whether os_workgroup_interval keep-warm is needed.

**F. Clock-sync & ground-truth (cross-cutting)**
- [ ] **mach_timebase numer/denom:** Read on every target chip. *Pass:* confirm 125/3 (M1) is consistent across M2/M3/M4.
- [ ] **NWProtocolIP.Metadata.receiveTime epoch:** Corpus already confirmed it is **CLOCK_MONOTONIC_RAW** (advances during sleep), DIFFERENT from `CLOCK_UPTIME_RAW`/`mach_absolute_time`. *Spike:* compute the simultaneous offset at startup and refresh on wake-from-sleep. *Pass:* one-way latency is non-negative and stable.
- [ ] **Ground-truth glass-to-glass:** Build a photodiode + LED rig (Raspberry Pi Pico, ~20ns resolution) or use a 240/1000fps camera. *Pass:* the sum of measured software stages matches hardware within ±1ms; if off by >1ms ⇒ a clock/instrumentation bug exists.
- [ ] **Overlay underreport warning:** Cross-check the internal overlay numbers against ground truth. *Pass:* know exactly how much the overlay misses (capture delay + compositor + scanout).

**G. Display phase / beat-frequency**
- [ ] **Host display rate exactness:** Read the host display's true rate (expect to detect 59.951/59.94 vs 60.000). *Pass:* if off ⇒ force `CGDisplaySetDisplayMode` to match the client rate to eliminate the beat (~17–20s period).
- [ ] **DP2 — preferredFrameLatency:** Confirm only 1.0/2.0 are valid; measure drawable-pipeline latency at 1.0 vs 2.0. *Pass:* set 1.0 for streaming.

**Phase-0 exit criteria:** every `refuted`/`uncertain` row in the §1 tables has been converted to `confirmed`/`refuted` *with measurements*, and the empirical glass-to-glass pipeline (via the ground-truth rig) sits within the expected band (~14–16ms @120fps wired, ~22–26ms @60fps wired — these numbers also need validation, since most are derived rather than measured on this native Swift stack).
