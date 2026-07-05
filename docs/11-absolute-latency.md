# 11 — Absolute Latency (latency-floor research)

> **STATUS: REFERENCE — GUI video-path latency-floor research.** Shipped, co-equal with terminal panes (old "Phase 4 / secondary" framing retired). Architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Scope.** Covers ONLY the GUI video-path (shipped, co-equal with terminal panes), running **60 fps default with idle-skip** (30 fps reads stale on scroll/motion; idle-skip drops bandwidth toward ~0 when static). Goal is **feels-local at 60 fps, not a hard sub-16 ms motion-to-photon floor** — so the extreme-floor pursuit here is mostly **over-engineering for the coding profile** ([12](12-coding-profile.md)): motion-to-photon <16 ms, 120 fps/ProMotion, beam-racing all **DROP**. Terminal-pane latency = network RTT (~1–5 ms LAN), no vsync. **Keep the API corrections** (queueDepth default 8, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, disable AWDL, idle-skip/dirtyRects) — still valid for the GUI path.

> **Net-model note ([13](13-network-transport.md)).** The apps assume a trusted private network — typically a userspace-WireGuard mesh (NetBird/Tailscale). Over such a tunnel DSCP is zeroed and the WG interface (utun) shows as `.other`, so `serviceClass`/DSCP marking and `requiredInterfaceType=.wiredEthernet` here **do NOT apply**.

Goal: absolute glass-to-glass (G2G) floor for the Apple/LAN/per-window stack (`ScreenCaptureKit → VideoToolbox HEVC → UDP/QUIC → VideoToolbox decode → Metal/CAMetalLayer`). **Every number is derived, not yet measured on this stack** → Phase-0 checklist at the end. Raw corpus: [research/latency-research-corpus.json](research/latency-research-corpus.json).

## Floor summary

| Configuration | Floor G2G | Realistic G2G |
|---|---:|---:|
| 120 fps wired, 120 Hz both ends | ~10 ms | ~14–16 ms |
| 60 fps wired, 60 Hz both ends | ~14 ms | ~22–26 ms |
| 120 fps Wi-Fi 6E (6 GHz) | ~12 ms | ~17–26 ms |
| 60 fps Wi-Fi 6/6E | ~16 ms | ~24–41 ms |

The **two dominant stages are both vsync**: capture (host compositor wait) and render+scanout (client vsync). On wired GigE the network all but disappears (one-way <0.1 ms). To compress the floor, **raise refresh rate (60→120 Hz saves ~12 ms: ~8 ms capture + ~4 ms scanout), not the network.**

> ⚠️ **Load-bearing API corrections** (details in §"Verified API claims"):
> - `minimumFrameInterval`: macOS 15+ silently defaults to **1/60** (caps at 60 fps even on ProMotion) → must set explicitly; use `(1/fps)×0.9` (OBS PR#11896), **NOT** `kCMTimeZero` (refuted).
> - `queueDepth`: real default is **8** (not 3); **2 is valid** for low latency.
> - HEVC: `AllowOpenGOP` defaults to **true** → set `false`; `MaxFrameDelayCount=0` forces one-in-one-out (its default is `-1`, not 0).
> - 10-bit capture: `'x420'` is **NOT** in `SCStreamConfiguration`'s list; HDR needs a macOS-15 preset or `'xf44'` (4:4:4).
> - **AWDL / `includePeerToPeer` is HARMFUL** for video (40–336 ms spikes) → disable.
> - **VRR/adaptive-sync requires fullscreen** → a windowed app gets no benefit.
> - **Slice/sub-frame pipelining is NOT available** via the public VideoToolbox API (frame-granular output) → drop.

> **Measurement caveat.** Streamer overlays (Moonlight stats, Virtual Desktop indicator) **under-report true G2G by ~40 ms** — they catch network+decode but miss capture compositor delay, compositor buffering, and display scanout (Visser/Greendayle). Treat every self-reported number as a lower bound; measure with an LED+photodiode rig (~21 ns) or a 240/1000 fps camera.

## Table of contents
- [Latency budget & theoretical floor](#latency-budget--theoretical-floor)
- [Per-stage absolute-minimum configuration](#per-stage-absolute-minimum-configuration)
- [Ranked techniques by latency impact](#ranked-techniques-by-latency-impact)
- [Verified API claims, corrections & Phase-0 validation list](#verified-api-claims-corrections--phase-0-validation-list)

---

## Latency budget & theoretical floor

**Baseline constants:** vsync @60 Hz = 16.67 ms, @120 Hz = 8.33 ms (avg scanout = half a frame: 8.3/4.2 ms). GigE one-way <0.1 ms (~12 µs to serialize 1500 B). Wi-Fi 6/6E one-way 0.5–2.5 ms light load. mach tick on Apple Silicon = 41.67 ns (numer=125, denom=3; confirmed on M1, **verify M2/M3/M4**).

### Budget @60 fps — wired GigE, 60 Hz both ends

| Stage | Floor | Realistic | Dominant? | Notes |
|---|---:|---:|:---:|---|
| **Capture (SCK compositor vsync)** | 0 | ~16.67 ms | ◆ | One WindowServer cycle; incompressible. CPU only ~1.9% of a core (WWDC22 10156). Set `minimumFrameInterval`, `queueDepth=2–3`, skip idle frames. |
| **Encode (VideoToolbox HEVC HW)** | ~3.3 ms | 15–18 ms | ◆ | HEVC ~18 ms/frame @1080p60 on M4 (Lumen, self-reported). The ~3.3 ms ceiling is **throughput** (~300 fps @1080p), NOT single-frame latency — no Apple measurement exists. |
| **Transmit (UDP/QUIC, wired)** | <0.1 ms | <0.5 ms | ✗ | ~12 µs/1500 B + NIC. QUIC AES-128-GCM ~6.5 µs/frame on M1 (negligible). Plain UDP ~0. |
| **Decode (VideoToolbox HEVC HW)** | ~1 ms | 1–3 ms | ✗ | M2 Mac 2–3 ms, ~1.2 ms when render isn't the bottleneck (Moonlight #1249). `flags=0` sync, no `EnableTemporalProcessing`. |
| **Render + vsync (Metal direct)** | 4.2 ms | 8.3–16.7 ms | ◆ | Avg scanout 8.3 ms @60 Hz. `CVMetalTextureCache → CAMetalLayer`; **NOT** AVSampleBufferDisplayLayer (≥1 frame buffering, #1885). `maximumDrawableCount=2`, `displaySyncEnabled` + `CAMetalDisplayLink preferredFrameLatency=1`. |
| **TOTAL G2G** | **~14 ms** | **~22–26 ms** | | Capture+render vsync pair dominates. |

> **Capture subtlety:** 16.67 ms is worst case (pixels change right after a compositor grab); average is half a vsync. The "1 ms capture" figure is SCK's *callback overhead* after compositing, NOT the vsync wait. SCK's vsync-to-callback latency on Apple Silicon **has never been published by Apple** — the biggest open question of the capture floor.

### Budget @120 fps — wired GigE, 120 Hz both ends

Same stages; deltas vs @60 fps:

| Stage | Realistic | Note |
|---|---:|---|
| **Capture** | ~8.33 ms | **MUST set `minimumFrameInterval` explicitly** — macOS 15+ default silently became 1/60, capping at 60 fps even on ProMotion (confirmed: 14.5 SDK default 0, 15.5 SDK default 1/60). Use `(1/fps)×0.9` (OBS PR#11896), not `kCMTimeZero` (refuted). |
| **Encode** | 8–18 ms | ◆ **tightest constraint** — budget is only 8.33 ms/frame; HEVC ~18 ms (Lumen M4) exceeds it. Verify encode <8.33 ms or accept multi-frame overlap. |
| **Decode** | 1–3 ms | 2.37–2.69 ms avg on M4 Pro + Metal (#1696). |
| **Render + vsync** | 4.2–8.3 ms | ◆ Half-frame scanout = 4.2 ms @120 Hz. `preferredFrameLatency=1` (only 1.0/2.0 valid). Beam-race the latest frame just before `targetTimestamp`. |
| **TOTAL G2G** | **~14–16 ms** | floor ~10 ms |

### Wi-Fi delta

Wi-Fi changes only the transmit stage (host capture/encode and client decode/render are unchanged): **+2–5 ms** @5 GHz (5–15 ms RTT), **+1.5–4 ms** @6 GHz (cleaner, no AWDL contention, jitter down ~80%). `serviceClass=.interactiveVideo` (→ AC_VI) + WMM on the AP; do **NOT** set `includePeerToPeer`.

> **AWDL latency bomb.** AWDL runs in the background on every Apple machine, channel-hopping ~every 10–12 s → 50–200 ms spikes (Visser/RIPE91: 20 ms ±25 ms, RTT 3–90 ms). **Mitigation:** put the AP on the AWDL social channel (5 GHz ch44/ch149, per OWL/Seemoo RE — never Apple-confirmed) or use 6 GHz. Otherwise the Wi-Fi budget periodically jumps +50–200 ms.

### Input-to-photon (full round trip)

6-stage chain (client input → send → host inject → host display changes → returns as video), distinct from one-way G2G. **Key takeaway: the local cursor is decoupled from the video loop.**

| Stage | macOS host cursor | iOS touch client | Notes |
|---|---:|---:|---|
| **1. Input capture** | 1–3 ms (USB HID 1 ms @1000 Hz; passive CGEventTap +0.1–0.3 ms) | 8–17 ms @120 Hz | iOS 120 Hz touch-to-UIKit **has no official measurement**; halving the 60 Hz figure is unsound (DXOMARK measured iPhone 15 Pro Max ~67 ms end-to-end). Use `coalescedTouches`/`predictedTouches`. |
| **2. Network send** | 0.05–0.2 ms wired | — | Button events immediately; batch motion at ~1 ms. |
| **3. Host inject (CGEventPostToPid)** | 0.2–2 ms | — | **NOT** a Mach IPC round-trip (refuted) — a CoreGraphics/WindowServer multi-hop; **no Apple Silicon benchmark exists**. |
| **4. Activate-then-control** | 0.1–0.3 ms (2 Mach msgs/session) | — | `SLPSPostEventRecordTo` flips active state without raising (avoids 100–300 ms Space switch). **macOS 14 SIGABRT risk** (`CGSEncodeEventRecord` mis-serializes a 0xFF buffer, paneru #123) → OS-version guard. macOS 26: CGEventPost from an unsigned daemon is blocked → needs code-signing or a DriverKit virtual HID. |
| **5. Return video** | 3–15 ms | 3–15 ms | = the encode→net→decode pipeline above. |
| **6. Client display** | 8–13 ms @120 Hz | 8–17 ms | = render+vsync above. |

- **No local cursor:** ~14–36 ms G2G (wired, 120 Hz, cursor excluded).
- **With local cursor overlay:** cursor appears in **~2–5 ms** (fed from the input channel, not the video round trip); the window-update confirmation arrives ~15–25 ms. **Highest-value perceived-responsiveness optimization** (RDP/PCoIP/NoMachine all do it). Set `showsCursor=false`, draw the cursor client-side.
- On LAN, RTT ~1 ms < one frame → **no motion prediction needed** (only for WAN RTT >20 ms).

### Comparison vs real systems

| System | Published figure | Scope / reliability |
|---|---|---|
| **Parsec** | 4–8 ms @240 fps wired | encode+transmit+decode **display-to-display** (no input), 1000 fps camera; extreme stress demo (Parsec recommends 60 fps). NOT full G2G. |
| **Parsec encode** | NVENC H.264 median 5.8 ms | fleet median across all Nvidia GPUs, 2018, uncontrolled. Apple Silicon encode latency has **no official benchmark**. |
| **Moonlight + Sunshine** | ~10–20 ms @60 fps wired | community overlay — under-reports; true G2G higher. |
| **Moonlight decode (AS)** | M2 iPad ~1 ms, M2 Mac 2–3 ms | "felt"/overlay; ~2.7 ms via Metal vs 4–6 ms via AVSBDL. |
| **Lumen (M4)** | H.264 ~15 ms / HEVC ~18 ms @1080p60 | README self-reported, methodology unstated. |
| **ALVR (VR)** | target <50 ms; actual 70–140 ms wireless | adds compositor+tracking; not comparable. |
| **NeSt-VR** | VF-RTT 4–5 ms Wi-Fi | transmission round-trip only, peer-reviewed. |

### Caveats & uncertainties

1. **macOS 26 decode regression.** Moonlight #1696 reports decode jumping to ~80 ms (Intel) / ~20 ms (M4 + Metal); disabling the Metal renderer → ~2.7 ms. Suspected cause is CAMetalDisplayLink "presentation wait timed out", **not** HW decode. **Test on the macOS 26 target before trusting the ~14 ms floor.**
2. **Encode single-frame latency** is the biggest unsolved open question — the ~3.3 ms ceiling is throughput, not latency; at 120 fps (8.33 ms budget) it can break. Measure with `CACurrentMediaTime()` around `VTCompressionSessionEncodeFrame`.
3. **HEVC low-latency RC on Apple Silicon is empirical, not documented.** `EnableLowLatencyRateControl` is Apple-documented for H.264 only; HEVC is confirmed only via an FFmpeg ARM64 patch. Querying `UsingHardwareAcceleratedVideoEncoder` returns `-12900` in low-latency mode = API incompleteness, NOT a software fallback (real missing-HW error is `-12902`).
4. **SCK capture vsync-to-callback latency** has never been publicly measured — the whole capture stage is inferred from compositor architecture. `SCStreamFrameInfoDisplayTime` shares a clock domain with `CACurrentMediaTime()` (both `mach_absolute_time`); convert via `mach_timebase_info`.
5. **AVSBDL extra-frame buffering** ("1+ frame", #1885) was measured on a Radeon Pro 580 (macOS dGPU); **no iOS benchmark**. Metal-direct still wins (bypasses the compositor queue).
6. **`maximumDrawableCount=2` is VALID on iOS/iPadOS** (the "not recommended" claim was refuted — only a platform-neutral warning that `nextDrawable` returns nil more often). Right choice for minimum G2G; handle nil + drop frames.

---

## Per-stage absolute-minimum configuration

Exact symbol per pipeline stage; spellings verified against the installed `MacOSX.sdk`. Markers: `[VERIFIED-SDK]` = confirmed from a header on this machine; `[VERIFIED-CORPUS]` = corpus-confirmed, header not re-checked; `[UNVERIFIED]` = community-only, needs a runtime test; `[PRIVATE]` = private/undocumented, use at your own risk.

### 1. Capture — ScreenCaptureKit

`SCStream` + `SCContentFilter(desktopIndependentWindow:)` — the only public single-window path (CGDisplayStream / CGWindowListCreateImage obsoleted in the macOS 15 SDK).

| Setting | Value | Rationale |
|---|---|---|
| `SCContentFilter(desktopIndependentWindow:)` `[VERIFIED-CORPUS]` | target window | Single-window, display-independent capture → less WindowServer work. |
| `config.minimumFrameInterval` `[VERIFIED-SDK]` (`CMTime`) | `CMTimeMake(1, targetFPS)`; **not** a float | macOS 15+ default changed to 1/60 → silent 60 fps cap; setting it explicitly is mandatory. `kCMTimeZero=native-refresh` is **REFUTED** (OBS PR#11896 uses `target_frame_period × 0.9`, no header says `kCMTimeZero`). Use `1/targetFPS`, or `1/(targetFPS×1.1)` per the OBS fix if frames drop. |
| `config.queueDepth` `[VERIFIED-SDK]` (`NSInteger`) | `2–3` for LAN | "range 3–8, default 3" is **REFUTED**: header default = **8**, soft ceiling "≤8", **no** hard floor of 3. Production uses 1 and 2 (daylight-mirror 3→2 cut P95 RTT 21.6→18.8 ms). IOSurface release deadline = `minimumFrameInterval × (queueDepth−1)`. |
| `config.pixelFormat` `[VERIFIED-SDK]` (`OSType`) | `'420v'` 8-bit (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) | NV12 goes straight into the HW encoder, no color-conversion pass. BGRA forces a GPU blit (~0.5–2 ms @4K). |
| `config.pixelFormat` (HDR/10-bit) | use a **preset**, don't assign `'x420'` | **REFUTED:** `'x420'` (4:2:0 video-range) is NOT in SCK's list; the only 10-bit YCbCr is `'xf44'` (4:4:4 full-range). HDR path: `SCStreamConfigurationPresetCaptureHDRLocalDisplay` `[VERIFIED-SDK]` (macOS 15.0+) sets dynamicRange/format/colorSpace/colorMatrix itself. |
| `config.showsCursor` `[VERIFIED-SDK]` (`BOOL`) | `false` | Client draws its own cursor overlay (see Input). |
| `config.captureResolution` `[VERIFIED-SDK]` (macOS 14.0+) | `.nominal` | Point resolution; on 4K Retina cuts pixel count 4×. |
| `config.ignoreShadowsSingleWindow` `[VERIFIED-SDK]` (macOS 14.0+) | `true` | Strips the composited shadow → smaller bounding box. |
| `config.captureDynamicRange` `[VERIFIED-SDK]` (macOS 15.0+) | `SDR` for SDR | Keep SDR when streaming SDR to avoid triggering the EDR pipeline. |
| `addStreamOutput(...sampleHandlerQueue:)` `[VERIFIED-CORPUS]` | `DispatchQueue(qos: .userInteractive)` | High-priority delivery, less jitter under load. |

**In `stream(_:didOutputSampleBuffer:of:)`:**
- Read `SCStreamFrameInfoStatus` first; process only `Complete`/`Started`, return immediately on `Idle`/`Blank`/`Suspended` to avoid idle-callback backlog.
- Take the timestamp from `SCStreamFrameInfoDisplayTime` `[VERIFIED-SDK]` — these are mach_absolute_time ticks in the **same clock domain** as `CACurrentMediaTime()` (REFUTED the "cross-domain" claim); just convert ticks→seconds via `mach_timebase_info`.
- Use `stream.synchronizationClock` `[VERIFIED-SDK]` (macOS 13.0+) to align DTS/PTS.

> Irreducible floor: pixel-change → IOSurface SCK sees = one WindowServer vsync (8.33/16.67 ms). Not Apple-published; inferred from the compositing architecture. No public path lower than SCK.

### 2. Encode — VideoToolbox

Default codec: HEVC Main 10, 4:2:0, no B-frames, infinite GOP + on-demand IDR, low-latency RC.

**`encoderSpecification` dict (set at `VTCompressionSessionCreate`, before any property):**

| Symbol | Value | Rationale |
|---|---|---|
| `EnableLowLatencyRateControl` `[VERIFIED-SDK]` (macOS 11.3+) | `true` | One-in-one-out, no reorder. **Apple documents H.264 only**; HEVC works on Apple Silicon per the FFmpeg patch (gated `TARGET_CPU_ARM64`, 2025) but is **not an Apple guarantee** — verify at runtime with `VTCopySupportedPropertyDictionaryForEncoder`. |
| `RequireHardwareAcceleratedVideoEncoder` `[VERIFIED-CORPUS]` | `true` | Fail fast instead of a 5–20× slower software fallback. |

**Manual HEVC low-latency config (`VTSessionSetProperty` after create):**

| Symbol | Value | Rationale |
|---|---|---|
| `RealTime` `[VERIFIED-CORPUS]` | `true` | No batch deferral. |
| `AllowFrameReordering` `[VERIFIED-CORPUS]` | `false` | No B-frames; mandatory for LAN. |
| `AllowOpenGOP` `[VERIFIED-SDK]` (macOS 10.14+) | `false` | **HEVC defaults to `true`** → must disable so each IDR is independently decodable. |
| `MaxFrameDelayCount` `[VERIFIED-SDK]` (macOS 10.8+) | `0` | **REFUTED "0=default":** default is `kVTUnlimitedFrameDelayCount = -1`. `0` → frame N emitted before its encode call returns = synchronous emit. ("Zero implies default" belongs to the adjacent `MaxH264SliceBytes`.) |
| `PrioritizeEncodingSpeedOverQuality` `[VERIFIED-SDK]` (macOS 11.0+) | `true` | HW prioritizes quality by default; flip to cut encode time. |
| `MaxKeyFrameInterval` `[VERIFIED-CORPUS]` | `INT_MAX` | Infinite GOP; IDR only on demand via `ForceKeyFrame`. |
| `ExpectedFrameRate` `[VERIFIED-CORPUS]` | target fps | Pre-configures internal timing. |
| `MaximumRealTimeFrameRate` `[VERIFIED-SDK]` (macOS 15.0+) | `120` | Hints peak burst rate. |

**Rate control (mutually exclusive with low-latency mode):**

| Symbol | Value | Rationale |
|---|---|---|
| `AverageBitRate` `[VERIFIED-CORPUS]` | `<target_bps>` | Soft target; auto-bitrate unsupported in low-latency mode. |
| `DataRateLimits` `[VERIFIED-CORPUS]` | `[bytes, seconds]` | Hard cap against burst overflow. |
| `ConstantBitRate` | **do NOT set** | Mutually exclusive with low-latency → `kVTPropertyNotSupportedErr`. |
| `MaxAllowedFrameQP` `[VERIFIED-SDK]` (macOS 12.0+) | `36–40` | Caps frame size; QP ≤40 keeps text legible, stops bloated IDRs. |
| `SpatialAdaptiveQPLevel` `[VERIFIED-SDK]` (macOS 15.0+, macOS-only) | `Disable` | Header says "ignored when EnableLowLatencyRateControl is true". |

**LTR recovery (instead of periodic IDR):**

| Symbol | Value | Rationale |
|---|---|---|
| `EnableLTR` `[VERIFIED-SDK]` (macOS 12.0+) | `true` | LTR-P ≪ IDR → cheaper loss recovery. Header is **codec-agnostic** → usable with HEVC on Apple Silicon (REFUTED "not yet confirmed"). |
| `ForceLTRRefresh` `[VERIFIED-SDK]` | test both | **Internal header contradiction (confirmed):** annotation says `// CFNumberRef, Optional`, abstract says "Set to kCFBooleanTrue" → **test both `kCFBooleanTrue` and `@(1)`** at runtime. |
| `AcknowledgedLTRTokens` `[VERIFIED-CORPUS]` | CFArray of CFNumberRef | Client feeds back ACKed tokens. |

**H.264 fallback only:** `H264EntropyMode = CABAC` (with High profile; ~7% better, decode delta sub-ms) `[VERIFIED-CORPUS]`; `MaxH264SliceBytes ≈ 1300` (MTU-aligned, one slice/packet; **no HEVC equivalent**) `[VERIFIED-SDK]`.

**Init & pre-warm:** call `VTCompressionSessionPrepareToEncodeFrames` once after setting properties, before frame 1, to kill the first-frame alloc spike. On macOS 26+, query `SupportedPresetDictionaries`, then use `kVTCompressionPreset_VideoConferencing` `[VERIFIED-SDK]` (macOS 26.0+; header requires `EnableLowLatencyRateControl=true`).

> Measurements (uncertain): H.264 ~15 ms/frame, HEVC ~18 ms @1080p60 on M4 (Lumen, self-reported). Apple publishes no per-frame encode latency. WWDC21's "up to 100 ms reduction" @720p30 is from removing the reorder buffer, not raw encode time.

### 3. Transport — Network.framework + BSD sockets

LAN-only, no NAT. Plain UDP for video (~0 crypto) or QUIC datagram if Wi-Fi needs congestion control.

**Network.framework (`NWParameters`):**

| Symbol | Value | Rationale |
|---|---|---|
| `serviceClass = .interactiveVideo` `[VERIFIED-CORPUS]` | video flow | Maps to Wi-Fi 802.11e **AC_VI** (UP 5). On macOS this sets only the Wi-Fi L2 UP, **NOT** IP DSCP, unless Cisco Fastlane (MDM). The public enum `nw_service_class_interactive_video = 2` ≠ `NET_SERVICE_TYPE_VI = 3`; the mapping is private. |
| `serviceClass = .responsiveData` `[VERIFIED-CORPUS]` | input/control | Separate low-latency control channel. |
| `requiredInterfaceType = .wiredEthernet` `[VERIFIED-CORPUS]` | — | Pins Ethernet, avoids cellular/Wi-Fi fallback + Happy Eyeballs. ⚠️ Do **NOT** pin over a userspace-WireGuard mesh (utun=`.other` → breaks); leave the default ([13](13-network-transport.md)). |
| `includePeerToPeer = false` `[VERIFIED-CORPUS]` (default) | — | `true` activates AWDL → 40–336 ms spikes. Infrastructure Wi-Fi beats AWDL. |
| `multipathServiceType = .disabled` `[VERIFIED-CORPUS]` | — | No path-probing on a single-interface LAN. |
| `allowFastOpen = true` `[VERIFIED-CORPUS]` | — | QUIC 0-RTT resume on reconnect; trivial for UDP. |
| `shouldCalculateReceiveTime = true` `[VERIFIED-CORPUS]` | — | Kernel receive timestamp for one-way latency. |

**QUIC datagram (iOS 16+/macOS 13+):** `isDatagram = true`; `maxDatagramFrameSize = 1200` (below MTU); `idleTimeout = 30000` ms + keepalive (reconnect costs no handshake) — all `[VERIFIED-CORPUS]`.

**Per-packet & receive:**
- `NWProtocolIP.Metadata().serviceClass = .interactiveVideo` for video; `.signaling` for IDR-request/control (no head-of-line queuing). `.ecn = .ect1` (L4S, RFC 9331) only helps with an L4S AQM.
- **Receive pattern (critical):** in the `receiveMessage(completion:)` handler, finish, then **call `receiveMessage` again (chain, not loop)** on a serial queue — it delivers **1 datagram per callback** (DTS thread/116500); a loop creates unbounded queued reads.
- `connection.maximumDatagramSize` (typically 1472 on Ethernet) — fragment slices ≤ this; IP fragmentation adds 1–5 ms jitter + doubles loss probability.

**BSD socket path (for batch receive — `NWConnection` has none):**

| Symbol | Value | Rationale |
|---|---|---|
| `SO_NET_SERVICE_TYPE = NET_SERVICE_TYPE_VI` `[VERIFIED-CORPUS]` (=3) | or `RV`=5 | Wi-Fi AC_VI. `RV` (5) = "Responsive Multimedia A/V — screen sharing" (XNU `socket.h`). |
| `IP_TOS = dscp<<2` `[VERIFIED-CORPUS]` | AF41 = `34<<2` | **The only reliable way to set DSCP on Ethernet** — the kernel does NOT zero a user-set `ip_tos` on non-Fastlane interfaces. `SO_NET_SERVICE_TYPE` alone does not set DSCP. |
| `SO_NOSIGPIPE = 1` `[VERIFIED-CORPUS]` | — | macOS has no `MSG_NOSIGNAL`; mandatory so SIGPIPE doesn't kill the process. |
| `IP_BOUND_IF = if_nametoindex("en0")` `[VERIFIED-CORPUS]` | — | Linux `SO_BINDTODEVICE` equivalent; pins the wired NIC, avoids VPN/Wi-Fi routing. |
| `sendmsg_x` (481) / `recvmsg_x` (480) `[PRIVATE, VERIFIED-CORPUS]` | `msghdr_x` array | Batch UDP, N syscalls → 1. **Stable on macOS 14+** (numbers in public `syscall.h`, symbols in `libSystem`). `msghdr_x` lives only in `socket_private.h` (forward-declare it). **macOS 13 hang → use only on 14+.** |

> Network.framework user-space path: ~30% less receive CPU than BSD (WWDC18 715) — but on macOS 14 it falls back to BSD when the built-in firewall is on; macOS 15.3+ no longer forces fallback. Verify with `sudo skywalkctl flow -n -P <pid>`.

### 4. Decode — VideoToolbox

`VTDecompressionSession` rendering straight to Metal — not any internal-queue path.

| Symbol | Value | Rationale |
|---|---|---|
| `VTDecompressionSessionDecodeFrame(..., flags: 0, ...)` `[VERIFIED-CORPUS]` | `0` | Clears async + temporal-processing → synchronous: callback fires before the call returns, no reorder buffer. (HW may dispatch internally async, setting `kVTDecodeInfo_Asynchronous` while the caller still blocks — undocumented, not a violation.) |
| `kVTDecodeFrame_EnableTemporalProcessing` | **do NOT set** | Licenses display-order callback delays → extra depth even with no B-frames. |
| `RealTime` `[VERIFIED-CORPUS]` | `true` | Default true (through macOS 26.5) but set explicitly. Do **NOT** set with `MaximizePowerEfficiency` (undefined). |
| `RequireHardwareAcceleratedVideoDecoder` `[VERIFIED-CORPUS]` | `true` | Hard fail vs a silent software fallback (HEVC Main10 SW >30 ms). |
| verify `UsingHardwareAcceleratedVideoDecoder` `[VERIFIED-CORPUS]` | `== true` | Confirms the Media Engine is in use. |

**imageBufferAttributes (destination):** `kCVPixelBufferMetalCompatibilityKey: true` (IOSurface-backed, zero-copy); `kCVPixelBufferPoolMinimumBufferCountKey: 3–6` (ALVR uses 3 min); pixel format **must match the decoder native** (`420...VideoRange` 8/10-bit) — a mismatch forces a `VTPixelTransferSession` blit (**Apple-documented**, WWDC14 513, not "undocumented"). On visionOS 2, ALVR notes setting pixelFormat *at all* copies; on macOS only a *non-native* request triggers the blit (unconfirmed for native requests).

**Encode-side bitstream for 1-in-1-out decode:** H.264 SPS VUI `bitstream_restriction_flag=1, num_reorder_frames=0, max_dec_frame_buffering=1` (without these the HW decoder buffers 4 frames/keyframe in Main, W3C #732); HEVC SPS `sps_max_num_reorder_pics[0]=0`.

**Recovery:** on decode error → `VTDecompressionSessionCanAcceptFormatDescription`; if OK, request an IDR (1 LAN RTT <1 ms) and keep the session alive. **Avoid** teardown+recreate (~30–100 ms, inferred). The macOS 26 ~80 ms regression (#1696) is a render-path issue, not the HW decode engine.

### 5. Render — Metal + display (macOS & iOS)

Use `CAMetalLayer` + `CVMetalTextureCache`, **NOT** `AVSampleBufferDisplayLayer` (AVSBDL adds ≥1 frame, #1885).

**macOS (`CAMetalLayer`):**

| Symbol | Value | Rationale |
|---|---|---|
| `displaySyncEnabled = false` `[VERIFIED-CORPUS]` | vsync-off | Present as soon as the GPU finishes, dropping the whole vsync wait (≤16.7 ms @60 Hz); accept tearing. Or `true` + `CAMetalDisplayLink` for vsync-on low-latency. |
| `maximumDrawableCount = 2` `[VERIFIED-CORPUS]` | `2` | **REFUTED** "2 not recommended on iOS" — only constraint is value ∈ {2,3}, uniform on every platform. 3 → 16–50 ms backlog; 2 → ~16 ms. Value 2 raises the chance `nextDrawable` returns nil. |
| `framebufferOnly = true` `[VERIFIED-CORPUS]` (default) | — | Lossless compression + compositor fast path. |
| `presentsWithTransaction = false` `[VERIFIED-CORPUS]` (default) | — | Don't sync with the CA transaction (≤1 CA frame); enable only when Metal must sync a UIKit overlay. |
| `CAMetalDisplayLink` `[VERIFIED-SDK]` (macOS 14.0+/iOS 17.0+) | replaces CVDisplayLink | **REFUTED** "Apple Silicon only" — `API_AVAILABLE(macos(14.0), ios(17.0), tvos(17.0))`, no AS restriction. Moonlight's `isAppleSilicon()` guard was their own choice. |
| `preferredFrameLatency = 1.0` `[VERIFIED-CORPUS]` | `1.0` | Unit is **frames** (Float); only 1.0/2.0 valid. 1.0 = API minimum; system may exceed it (windowed macOS). |
| `preferredFrameRateRange = (fps,fps,fps)` `[VERIFIED-CORPUS]` | lock to stream fps | Prevents ProMotion downclock jitter. |
| `commandBuffer.waitUntilScheduled` `[VERIFIED-CORPUS]` | NOT `waitUntilCompleted` | `Completed` blocks until pixels hit the framebuffer (5–15 ms stall); `scheduled` only waits for submission (Zed 120 fps blog). |

**iOS/iPadOS:** Info.plist `CADisableMinimumFrameDurationOnPhone = true` `[VERIFIED-CORPUS]` (**mandatory** to unlock 120 Hz on iPhone); `CAMetalLayer.opaque = true` `[VERIFIED-CORPUS]` (Flutter/Impeller measured 21–26 ms → ~13 ms presentation delay — **one isolated observation, not an Apple guarantee**; set it anyway, cheap/safe); `maximumDrawableCount = 2`; `preferredFrameRateRange(60,60,60)` for a 60 fps stream on a 120 Hz client (60 divides 120 → double-pump, zero judder — avoid preferred:120 for 60 fps); `UIUpdateLink.requiresContinuousUpdates = true` `[VERIFIED-CORPUS]` (iOS 18+ UIKit path; pure Metal uses `CAMetalDisplayLink`).

**Zero-copy decode→render:** `CVMetalTextureCacheCreate` once; per biplanar YCbCr frame call `CVMetalTextureCacheCreateTextureFromImage` twice — plane 0 (`.r8Unorm`/`.r16Unorm`) for Y, plane 1 (`.rg8Unorm`/`.rg16Unorm`) for CbCr (same IOSurface, zero GPU copy). Pin the IOSurface while the GPU uses it (strong `CVMetalTexture` ref in `addCompletedHandler`).

**Beam-racing:** in the `CAMetalDisplayLink` callback, render the **latest available** frame (don't wait for the one matching `targetTimestamp`), commit before `targetTimestamp`. Moonlight waits `((targetTimestamp − now)*1000)/2` ms.

**Color/EDR — skip the compositor color-match pass:** `colorspace = nil` `[VERIFIED-CORPUS]` (pass-through, Apple "fastest"; or match `NSScreen.colorSpace`); `wantsExtendedDynamicRangeContent = false` for SDR (avoids the EDR pass, WWDC21 10161); `edrMetadata = nil`. SDR: `pixelFormat = .bgra8Unorm`. HDR: `.bgra10a2Unorm` (32 bit/px) + PQ/HLG, **not** `.rgba16Float` (64 bit/px). Only `rgba16Float` and `bgra10a2Unorm` support EDR.

> **macOS requires fullscreen for Adaptive-Sync/VRR scheduling** (WWDC21 10147): a windowed app gets no VRR scheduling — only a fullscreen window goes through the `NSScreen.minimum/maximumRefreshInterval` path.

### 6. Input — CGEvent injection + local cursor

Activate-then-control: the host injects input without raising the window; the client draws a local cursor.

| Symbol / technique | Configuration | Rationale |
|---|---|---|
| **Local cursor overlay** `[VERIFIED-CORPUS]` | client draws from the input stream | Feedback ~0–2 ms vs ~15–25 ms via the video round trip. Highest-value perceived-latency lever. Host `showsCursor = false`. |
| `CGEventPostToPid` `[VERIFIED-CORPUS]` (macOS 10.11+) | NOT `CGEventPost` | Delivers straight to the PID, no system-cursor move, no foregrounding. **Not** a pure Mach IPC round-trip (≥2 hops CoreGraphics→WindowServer→app tap); Apple Silicon latency **unmeasured** (the 50–200 µs estimate is unsubstantiated). |
| `SLPSPostEventRecordTo` `[PRIVATE, VERIFIED-CORPUS]` (SkyLight) | call twice (old + target PSN) | Activate-without-raise: avoids the 100–300 ms Space switch. paneru #123 SIGABRT root cause is `CGSEncodeEventRecord` mis-serializing a 0xFF buffer, NOT this call → skip `make_key_window()` on macOS 14. macOS 26 unclear. |
| DriverKit virtual HID `[VERIFIED-CORPUS]` | `com.apple.developer.driverkit.userclient-access` | Injects at IOHIDSystem (real HW path), bypassing `CGXSenderCanSynthesizeEvents()`. **Required on macOS 26:** an unsigned daemon's `CGEventPost` is dropped for modifier+key combos → 2–3 s lag (input-leap #2367). |
| `CGEventTap` `[VERIFIED-CORPUS]` (client capture) | `kCGHIDEventTap`, `kCGHeadInsertEventTap`, `ListenOnly` | Passive HID-level tap (earliest in userspace), immune to `tapDisabledByTimeout`. Run loop QoS `.userInteractive`. |
| `kTCCServicePostEvent` + Accessibility | entitlement | Required for `CGEventPostToPid` on macOS 14+. App **must be code-signed** to pass the macOS 26 gate. |

**Input protocol:** button/key events sent immediately in their own datagram; motion batched at ~1 ms (USB HID 1000 Hz) — don't batch buttons with motion. iOS: `coalescedTouches(for:)` sends all 240/120 Hz samples, `predictedTouches(for:)` for extrapolation. **No motion prediction on LAN** (RTT < 1 frame; the local cursor already removes visual lag).

### 7. Threading — RT scheduling (Apple Silicon)

On Apple Silicon **os_workgroup is the primary mechanism** for guaranteed P-core scheduling.

| Symbol / API | Configuration | Rationale |
|---|---|---|
| `thread_policy_set(THREAD_TIME_CONSTRAINT_POLICY)` `[VERIFIED-CORPUS]` | `period/computation/constraint/preemptible` in ticks | Kernel RT band, bypasses QoS decay. 60 fps: period=16.67 ms, computation=period/2, constraint=period×0.85, preemptible=1. Convert ns→ticks via `mach_timebase_info`. **Call BEFORE `os_workgroup_join`.** |
| `os_workgroup_interval_create(..., OS_CLOCK_MACH_ABSOLUTE_TIME, ...)` `[VERIFIED-CORPUS]` | + `start/finish` per frame | Reports deadlines → keeps the P-cluster warm, preventing freq off/on-ramp. Joining thread must already have RT policy, else `EINVAL` — **but only for `WORK_INTERVAL_TYPE_COREAUDIO`**; other types EINVAL just means "cancelled". |
| `pthread_attr_setschedpolicy(SCHED_RR)` + prio 47–48 `[VERIFIED-CORPUS]` | render/encode threads | Prevents priority decay; **incompatible with QoS** (permanent opt-out). Fixed-window threads only. |
| `DispatchQueue(qos: .userInteractive)` `[VERIFIED-CORPUS]` | SCK + VT callback queues | P-core preference + priority inheritance. Baseline; combine with RT policy for the most critical threads. |
| `mach_wait_until(deadline)` `[VERIFIED-CORPUS]` | NOT `usleep()` | The "<600 µs 99.9%" figure is misattributed (micropython #8621, HW unknown), not Apple forum 120403; TN2169 only sets a 500 µs soft floor on an idle machine. Default threads land on E-cores → need affinity/workgroup. |
| `os_unfair_lock` `[VERIFIED-CORPUS]` | not `dispatch_semaphore` | Donates QoS to a low-QoS holder; semaphores don't. |
| **NO** `yield()`/`sched_yield()` `[VERIFIED-CORPUS]` | — | **XNU-confirmed:** tanks priority to 0 (DEPRESSPRI=MINPRI=0), defers ≤10 ms. **Applies to SCHED_RR too.** One yield = blown deadline. |
| **NO** `THREAD_AFFINITY_POLICY` `[VERIFIED-CORPUS]` | — | Returns `KERN_NOT_SUPPORTED` (46) on ARM. Use workgroups + RT policy instead. |

> **Swift caveat** `[VERIFIED-CORPUS]`: avoid Swift on the RT hot path — CoW mutation, `swift_beginAccess` (16-byte heap alloc), nested captures, thrown errors can all allocate → stall the RT thread. Write the inner loop in C/ObjC or allocation-free Swift. There is no dedicated public os_workgroup for SCK or VideoToolbox (only the audio workgroup); the video pipeline creates its own interval workgroup.

### 8. Memory — zero-copy (Apple Silicon unified memory)

The whole SCK→VT→net→VT→Metal pipeline stays zero-copy on one physical IOSurface per stage.

| Technique | Configuration | Rationale |
|---|---|---|
| SCK → encoder zero-copy `[VERIFIED-CORPUS]` | `CMSampleBufferGetImageBuffer()` → `VTCompressionSessionEncodeFrame` | Same memory the HW encoder DMAs. YCbCr (`'420v'`/10-bit) **must** match the encoder; BGRA forces a conversion pass (WWDC22). |
| `VTCompressionSessionGetPixelBufferPool()` `[VERIFIED-CORPUS]` | for GPU pre-processing | Vends buffers in the exact format/IOSurface config the encoder expects. |
| Decoder → Metal zero-copy `[VERIFIED-CORPUS]` | `kCVPixelBufferMetalCompatibilityKey: true` + `CVMetalTextureCacheCreateTextureFromImage` | Decoder IOSurface = the shader's MTLTexture; no PCIe copy on unified memory. |
| **AVOID** `CVPixelBufferCreateWithBytes/PlanarBytes` `[VERIFIED-CORPUS]` | — | CPU-only, NOT IOSurface-backed (QA1781) → CVMetalTextureCache fails, forces a copy. Use a pool with `kCVPixelBufferIOSurfacePropertiesKey: [:]`. |
| `autoreleasepool { }` `[VERIFIED-CORPUS]` | wrap the SCK callback + VT decode handler | Obj-C objects accumulate in the queue pool; burst drains = 5–30 ms pauses (forum thread/725744). |
| `DispatchData(bytesNoCopy:...)` `[VERIFIED-CORPUS]` | not `Data(bytes:count:)` for `NWConnection.send` | `Data` init always copies; `DispatchData` is no-copy with a deallocator releasing the CMSampleBuffer ref. (Whether Network.framework copies internally is unclear.) |
| Pool sizing `[VERIFIED-CORPUS]` | ≥4–6 buffers | 2 frames encoder pipelining + 1 Metal render; avoids `kCVReturnWouldExceedAllocationThreshold` (= 1 frame stall). |

**Private (high risk):** `MTLPixelFormatYCBCR8_420_2P = 500` / `..._10_420_2P = 505` `[PRIVATE]` — single-plane YCbCr binding, drops the shader matrix-multiply. Confirmed Apple-internal SPI (WebKit defines it under `#else` of `USE(APPLE_INTERNAL_SDK)`). **macOS availability unconfirmed** (MoltenVK maps it to `Invalid` on macOS). SPI with no cross-version guarantee — use only with a 2-plane shader fallback.

---

## Ranked techniques by latency impact

Biggest win → marginal. "Est. ms saved" uses sourced figures where available; figures are at 60 fps (16.67 ms) / 120 fps (8.33 ms). The risk column reflects adversarial verdicts (refuted/uncertain flagged).

| # | Technique | Est. ms saved | Difficulty | Risk |
|---|-----------|---------------|------------|------|
| 1 | **Low-latency RC encode** — `EnableLowLatencyRateControl` (H.264) + manual HEVC config (`AllowFrameReordering=false`, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, `RealTime=true`) | **~100 ms** @720p30 vs default buffering (WWDC21 10158) | low | **MED** — HEVC support is FFmpeg-empirical (gated `TARGET_CPU_ARM64`), NOT Apple-documented (H.264 only). Risk of silent OS regression. `-12900` on HW-accel query = API incompleteness, not a SW fallback. |
| 2 | **Wired GigE instead of Wi-Fi** | **2–30 ms** + all Wi-Fi jitter | low | **LOW** — link-layer physics. |
| 3 | **Client-side cursor overlay** (`showsCursor=false`, draw from the input channel) | **~15–25 ms** for cursor feedback | medium | **LOW** — RDP/PCoIP/NoMachine all do it; needs out-of-band cursor-shape sharing. |
| 4 | **Metal direct render vs AVSampleBufferDisplayLayer** | **8–33 ms** (1–2 frames, #1885) | medium | **MED** — qualitative, measured on a macOS dGPU; no iOS benchmark. AS unified memory has no copy penalty → benefit clearer. |
| 5 | **120 fps/ProMotion end-to-end** (`minimumFrameInterval=1/120` + 120 Hz client) | **~8.3 ms** worst-case vsync + ~4 ms avg capture | low–med | **MED** — needs a 120 Hz host AND encode <8.3 ms. macOS 15 default 1/60 (set explicitly). Use `1/fps×0.9`, NOT `kCMTimeZero` (refuted). |
| 6 | **Avoid `AVSampleBufferRenderSynchronizer`** / PTS fire-and-forget AV sync | **~1000 ms** of buffering avoided | medium | **LOW** — accidentally using synchronizer mode destroys all latency work. ~1 s is community-reported. |
| 7 | **HW decode + verify** (`RequireHardwareAcceleratedVideoDecoder=true`, `RealTime=true`) | **5–17 ms** (HW 1–3 vs SW 8–20; HEVC Main10 SW >30) | low | **LOW** — `flags=0` sync confirmed in header. Don't combine `RealTime` with `MaximizePowerEfficiency`. |
| 8 | **Display drop policy "always-newest"** (cap 3, drop oldest/vsync, target 1) | **8.3–25 ms** | medium | **LOW** — verified in moonlight-qt pacer.cpp. |
| 9 | **THREAD_TIME_CONSTRAINT_POLICY + os_workgroup** for hot threads | avoids **5–20 ms** scheduler stalls; `mach_wait_until` vs usleep | medium | **MED** — join needs RT policy first (EINVAL only for COREAUDIO type). "<600 µs" misattributed. Swift heap alloc stalls the thread. |
| 10 | **SCK queueDepth=2–3** | avoids **≤116 ms** backlog (default 8 @60 fps) | low | **LOW** — "3–8 strict range" refuted; default is **8**, no floor; 1/2 run in production. |
| 11 | **SCK `420v` instead of BGRA** (zero-copy into VT) | **~0.5–3 ms** (one color-conversion pass) | low | **LOW** — WWDC22 "lowest CPU cost". |
| 12 | **Zero-copy IOSurface end-to-end** (`kCVPixelBufferMetalCompatibilityKey`, autoreleasepool) | **15–60 µs/frame** + avoids 5–30 ms autorelease spikes | low–med | **LOW** — WWDC21: 62% bandwidth reduction. Don't set a non-native `kCVPixelBufferPixelFormatTypeKey` (triggers VTPixelTransfer copy, WWDC14 513). |
| 13 | **Opus RESTRICTED_LOWDELAY 5 ms** (audio) | **~15 ms** vs Opus 20 ms default | medium | **LOW** — Sunshine uses this; or PCM on LAN = 0 codec delay (~3.1 Mbit/s). |
| 14 | **CoreAudio HAL buffer** (`BufferFrameSize=64–128`) | **~8 ms** (512→128: 10.67→2.67 ms) | medium | **LOW** — set before allocating render resources; min is driver-dependent. |
| 15 | **LTR recovery instead of full IDR** (`EnableLTR`, `ForceLTRRefresh`) | **30–100 ms**/recovery (LTR-P 10–30× smaller) | medium | **MED** — `EnableLTR` codec-agnostic, HEVC+LTR on AS confirmed feasible. `ForceLTRRefresh` header self-contradicts type → test both. |
| 16 | **Skip idle frames + dirtyRects** (SCK) | **high** — avoids idle-callback queue buildup | low–med | **LOW** |
| 17 | **`maximumDrawableCount=2`** | **8–34 ms** (3 → 16–50 ms; 2 → ~8–16 ms) | low–med | **LOW** — "not for iOS" refuted; range [2,3] only. Trade-off: `nextDrawable` may return nil. |
| 18 | **`requiredInterfaceType` + `includePeerToPeer=false`** | avoids **50–200 ms** path eval + **40–336 ms** AWDL spikes | low | **LOW** — but don't pin over a WG mesh ([13](13-network-transport.md)). |
| 19 | **`serviceClass=.interactiveVideo`** (Wi-Fi AC_VI) | **~10× jitter** on congested Wi-Fi (67→7 ms); marginal light-load | low | **MED** — sets only Wi-Fi UP, NOT IP DSCP except Fastlane. `nw_..._interactive_video=2` ≠ `NET_SERVICE_TYPE_VI=3`. |
| 20 | **Beat-frequency exact rate match** (host = client refresh) | **0–16.67 ms** oscillation eliminated | medium | **MED** — needs host forced to exactly 60.000 Hz (EDID may map to 59.951). |
| 21 | **`PrepareToEncodeFrames` pre-warm** + keep session alive across reconnects | first frame: 1–10 ms; reconnect: **30–100 ms** rebuild | low | **MED** — first-frame spike has no public number; 30–100 ms inferred. |
| 22 | **`preferredFrameLatency=1`** | **~8–16 ms** (default is 2 frames on iOS) | low | **LOW** — only 1.0/2.0; system may exceed (windowed). `CAMetalDisplayLink` NOT AS-only (refuted). |
| 23 | **`CAMetalLayer.opaque=true`** (client) | **~8–13 ms** (Flutter #134959) | low | **HIGH-uncertainty** — single non-reproducible observation; Flutter's real fix was a custom IOSurface layer. Apple documents no latency guarantee. |
| 24 | **`displaySyncEnabled=false`** (vsync-off, tearing) | **8.3–16.7 ms** | low | **MED** — tearing on non-adaptive displays; consider adaptive sync (fullscreen) instead. |
| 25 | **`colorspace=nil`** (bypass color-match pass) | **sub-frame** (Apple "fastest") | low | **LOW** — raw color on a P3 display; or match the native colorspace. |
| 26 | **Disable EDR for SDR** (`wantsExtendedDynamicRangeContent=false`) | **sub-frame** (WWDC21 10161) | low | **LOW** — FP16 buffer is 2× bandwidth vs bgra10a2. |
| 27 | **Adaptive sync (VRR) fullscreen** | **3–8 ms** avg on a 120 Hz adaptive display | medium | **MED** — **fullscreen is a hard requirement** (WWDC21 10147); a windowed app gets no benefit. |
| 28 | **`kCMSampleAttachmentKey_DisplayImmediately`** (if forced to AVSBDL) | bounds display latency to ~1 scan vs 1–3 frames | low | **MED** — "bypass enqueued frames" from forum 14212, unconfirmed under sustained load. |
| 29 | **QUIC keepalive + 0-RTT** (reconnect cold path) | **2–5 ms** (1-RTT) or **0** (0-RTT) | medium | **MED** — `allowFastOpen` confirmed for TCP; the QUIC 0-RTT property is unverified. 0-RTT is replay-susceptible (OK for control). |
| 30 | **`sendmsg_x`/`recvmsg_x` batch UDP** | high throughput, medium per-frame | medium | **MED** — syscalls 480/481 stable on macOS 14+; PRIVATE (`msghdr_x` in `socket_private.h`). macOS 13 hang. |
| 31 | **Pre-trigger Local Network permission** (onboarding) | avoids **several seconds** on first cold launch | low | **LOW** — cold-path correctness fix. |
| 32 | **Slice-based / sub-frame pipelining** | ~10–12 ms (theoretical) — **but not feasible via public API** | exotic | **HIGH** — VT output is frame-granular. `NumberOfSlices`/`NumberOfSubFrameSections` are PRIVATE with unknown behavior. Manual NAL-split saves ~0.1–1 ms on LAN. |
| 33 | **AES-128-GCM vs ChaCha20** (if encrypting) | **~10 µs/frame** (AES total <0.1 ms = negligible) | low | **LOW** — QUIC TLS 1.3 picks AES-GCM itself. Use CryptoKit. |
| 34 | **AWDL P2P (`includePeerToPeer=true`)** for video | **NEGATIVE** — 40–336 ms spikes; channel-hop 50–200 ms | low | **HIGH** — **AVOID for video.** Wi-Fi Aware `realtime` is iOS/iPadOS 26 only. |
| 35 | **DriverKit virtual HID** (vs CGEventPostToPid) | avoids the **2–3 s** lag on macOS 26 (unsigned-daemon CGEventPost blocked) | exotic | **MED** — "HW-path latency" is a Karabiner claim, unmeasured. Simpler: signed app + `kTCCServicePostEvent`. |
| 36 | **CABAC vs CAVLC, profile, slice MTU-align** | **marginal** (~7% bitrate; slice ~1–3 ms) | low | **LOW** — decode delta sub-ms; HEVC mandates CABAC. |
| 37 | **`preferNoChecksum`, batch send, checksum offload** | **marginal** (~1–5 µs/packet; ~0 with HW offload) | low | **LOW** |
| 38 | **HEVC tiles / WPP control** | **N/A** — no API surface | exotic | **N/A** — Media Engine handles it internally. |
| 39 | **DPDK / kernel-bypass** | **N/A** on macOS/iOS | exotic | **N/A** — SIP + entitlements block userspace NIC access. |
| 40 | **RFC 9150 integrity-only ciphers** | **~3 µs/frame** theoretical | exotic | **N/A** — QUIC is AEAD-only. |

### Do these first (highest leverage, lowest risk)

1. **Wired GigE** (#2). ⚠️ Do NOT pin `requiredInterfaceType` over a userspace-WireGuard mesh (utun=`.other` → breaks); leave the default, the routing table steers itself ([13](13-network-transport.md)). Keep `includePeerToPeer=false`.
2. **Low-latency encode** (#1) — `EnableLowLatencyRateControl` (H.264); for HEVC set `RealTime=true`, `AllowFrameReordering=false`, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, `PrioritizeEncodingSpeedOverQuality=true`, `MaxKeyFrameInterval=INT_MAX`. **Verify HEVC at runtime** (`VTCopySupportedPropertyDictionaryForEncoder`).
3. **HW decode + verify** (#7) — `RequireHardwareAcceleratedVideoDecoder=true`, `flags=0`, `RealTime=true`.
4. **Metal direct render** (#4) — `CVMetalTextureCacheCreateTextureFromImage → CAMetalLayer`, avoid AVSBDL. The big differentiator vs Moonlight on macOS.
5. **Client-side cursor overlay** (#3) — `showsCursor=false`, draw locally. The biggest perceived-responsiveness lever.
6. **Zero-copy IOSurface + `420v`** (#11, #12) — wrap per-frame callbacks in `autoreleasepool {}`.
7. **Always-newest drop policy** (#8) + **queueDepth=2–3** (#10) + **maximumDrawableCount=2** (#17).
8. **120 fps/ProMotion if both ends support it** (#5) — `1/fps×0.9` for `minimumFrameInterval`, NOT `kCMTimeZero`.
9. **RT threads for capture/encode/network** (#9) — `THREAD_TIME_CONSTRAINT_POLICY` + `mach_wait_until`; `.userInteractive`; ban `yield()`; C/ObjC hot path if Swift allocations stall.
10. **Audio: Opus 5 ms or PCM + HAL 64–128 + PTS fire-and-forget** (#13, #14, #6) — never `AVSampleBufferRenderSynchronizer`.

### Skip / diminishing returns

- **Slice/sub-frame pipelining** (#32) — not feasible via the public API; private symbols are unknown. Manual NAL-split is ~0.1–1 ms on LAN.
- **AWDL P2P for video** (#34) — harmful; use infrastructure Wi-Fi/Ethernet.
- **HEVC tiles/WPP, DPDK, RFC 9150** (#38–40) — no API surface.
- **`opaque=true`** (#23) — try it but don't trust the number.
- **DriverKit virtual HID** (#35) — only if macOS 26 blocks `CGEventPostToPid`; a signed app + `kTCCServicePostEvent` suffices for most.
- **VRR/adaptive sync** (#27) — skip for a windowed app (requires fullscreen).
- **DSCP via serviceClass on wired LAN** (#19) — marginal (only Wi-Fi UP). On a managed switch use `IP_TOS` directly.
- **ChaCha vs AES** (#33) — negligible. On an isolated LAN, consider plaintext video + an encrypted control channel (Moonlight model).

---

## Verified API claims, corrections & Phase-0 validation list

Consolidates the adversarial-verification verdicts. **Golden rule: any `refuted`/`uncertain` line must NOT be a hard assumption — it goes into a Phase-0 spike to be confirmed on the target hardware (Apple Silicon, macOS 26).**

### 1. Verdict tables (load-bearing claims)

#### 1.1 Capture — ScreenCaptureKit

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| C1 | `minimumFrameInterval = kCMTimeZero` enables native-refresh delivery | **refuted** | high | NOT used by OBS, no header says so. OBS PR #11896 sets `(1/fps)×0.9` (~10% shorter; the exact reciprocal drops frames). **Use the explicit 0.9× value, not kCMTimeZero.** ([OBS #11896](https://github.com/obsproject/obs-studio/pull/11896)) |
| C2 | Default `minimumFrameInterval` changed to 1/60 in macOS 15 | **confirmed** | high | SDK diff: 14.5 default 0, 15.5 default 1/60 (never in release notes). Must set explicitly for native refresh. ([OBS #11778](https://github.com/obsproject/obs-studio/issues/11778)) |
| C3 | `queueDepth` strictly 3–8, default 3 | **refuted** | high | Default **8**; "should not exceed 8" is a soft ceiling; **no floor of 3**. 1 and 2 ship (daylight-mirror 3→2: P95 21.6→18.8 ms). "3" carried over from CGDisplayStream. **2 is valid; 3 is conservative.** |
| C4 | `SCStreamFrameInfoDisplayTime` shares a clock with `CACurrentMediaTime()` | **confirmed** | high | Both `mach_absolute_time`. No domain conversion — just ticks→seconds via `mach_timebase_info`. The "negative latency" report is a separate PTS bug. |

#### 1.2 Encode — VideoToolbox

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| E1 | `EnableLowLatencyRateControl` + HEVC "confirmed by an SDK comment" | **uncertain** | high | The "SDK comment" is an FFmpeg author's commit message, NOT an Apple header. WWDC21 mentions H.264 only. HEVC + low-latency RC runs on Apple Silicon (FFmpeg PR #20453, gated `TARGET_CPU_ARM64`) but **with no Apple guarantee**. |
| E2 | The macOS 26.5 header still says "supported codec: H.264" | **refuted** | high | The docblock is codec-agnostic in every version (15.4, 26.5); that phrase is only in the WWDC21 transcript. HEVC works on ARM64. **Confirm at runtime; risk of silent regression.** |
| E3 | Whether `EnableLTR` works with HEVC low-latency is unclear | **refuted** | high | The EnableLTR header (macOS 12.0/iOS 15.0) has no codec restriction. **HEVC + EnableLowLatencyRateControl + EnableLTR is viable on Apple Silicon**; validate via `VTCopySupportedPropertyDictionaryForEncoder`. |
| E4 | `ForceLTRRefresh` is a `CFNumberRef` (not CFBoolean) | **confirmed** | high | The header self-contradicts: annotation `// CFNumberRef`, abstract "Set to kCFBooleanTrue". **Test both `kCFBooleanTrue` and `@(1)` at runtime.** |
| E5 | `MaxFrameDelayCount = 0` means "default / no limit" | **refuted** | high | The no-limit default is `kVTUnlimitedFrameDelayCount = -1`. M=0 ⇒ frame N emitted before its encode call returns = **synchronous emit** (the "zero = default" sentence belongs to `MaxH264SliceBytes`). **Set 0 for one-in-one-out.** |
| E6 | `AllowOpenGOP` defaults to `true` for HEVC | **confirmed** | high | Unchanged 15.4→26.5. **HEVC allows Open-GOP by default — MUST set `false`** so every IDR is independently decodable. |

#### 1.3 Slice-pipelining (private symbols)

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| S1 | `NumberOfSlices` exists and "can be set without crashing" | **uncertain** | high | Symbol in the .tbd (iOS 9.3→26.x) but **PRIVATE**, no public header; the "can be set" part has no evidence — behavior unknown. Don't use without a spike. |
| S2 | `NumberOfSubFrameSections` has an observable effect | **uncertain** | high | Real exported symbol, no header/doc/OSS call site. Effect unknown. **Drop from the design.** |
| S3 | `SliceAttachments`/`SliceDataLength` appear in output attachments | **uncertain** | high | Exported PRIVATE strings, not in any public header; whether the runtime populates them is unconfirmed. **Conclusion: VT output is frame-granular; NVENC-style sub-frame pipelining is NOT available via the public API — drop tiles/WPP/slice-callbacks.** |

#### 1.4 Decode — VideoToolbox

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| D1 | `RealTime` defaults to `true` | **confirmed** | high | Verbatim in 15.4 & 26.5 headers. A hint, not a contract — set it explicitly. **Don't set with `MaximizePowerEfficiency` (undefined).** |
| D2 | `flags=0` guarantees synchronous decode | **uncertain** | med | The header guarantee (callback completes before return) is CONFIRMED for HW/SW. The HW decoder may dispatch internally async, setting `kVTDecodeInfo_Asynchronous` while the thread still blocks — plausible, unconfirmed. **Use flags=0; if pipelining CPU work, use async + semaphore.** |
| D3 | A mismatched destination pixel format causes a copy ("Apple never documented it") | **refuted** | high | Apple DID — WWDC14 513: a non-native request "forces an extra buffer copy". Unified memory removes the PCIe transfer, NOT the conversion compute. **Match the decoder native format (`420...VideoRange` 8/10-bit).** |

#### 1.5 Display / Compositor

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| DP1 | `CAMetalDisplayLink` is Apple Silicon only | **refuted** | high | `API_AVAILABLE(macos(14.0), ios(17.0), tvos(17.0))` — no AS restriction. Moonlight's `isAppleSilicon()` guard is their own choice. |
| DP2 | `preferredFrameLatency = 1.0` means 1 display cycle | **confirmed** | high | Unit is frames; 1.0 = one cycle = API minimum. **Only 1.0/2.0 accepted.** System may exceed (windowed). Set 1.0 for streaming. |
| DP3 | Adaptive sync requires fullscreen (Support 102144 silent) | **confirmed** | high | WWDC21 10147 requires a fullscreen window for the Adaptive-Sync scheduling APIs; 102144 only covers the OS-level toggle. **A non-fullscreen app gets NO VRR scheduling.** |
| DP4 | `maximumDrawableCount = 2` "not recommended for iOS" | **refuted** | high | No such Apple guidance. Only constraint: value ∈ {2,3}. The only warning (count=2 → `nextDrawable` may return nil) is platform-neutral. **2 is fully supported on iOS, right for min latency (with nil handling).** |
| DP5 | `opaque=true` cuts presentation latency to ~13 ms | **uncertain** | high | One isolated Flutter measurement (#134959), not reproduced, no Apple guarantee. **Set it (cheap), but don't treat "13 ms" as a budget — measure.** |
| DP6 | AVSBDL adds "1+ frame" vs Metal on iOS | **uncertain** | med | The "1+ frame" came from a subjective macOS dGPU report (#1885), NOT iOS. macOS WindowServer vs iOS backboardd makes transfer uncertain. **Pick Metal-direct to eliminate the risk; if AVSBDL, set `DisplayImmediately=true` and measure.** |

#### 1.6 Transport — Network.framework / BSD / Wi-Fi QoS

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| N1 | `.interactiveVideo` maps to `NET_SERVICE_TYPE_VI`, "inelastic/constant packet rate" | **uncertain** | med | Mapping plausible but not publicly verifiable. Separate C enum `nw_service_class_interactive_video = 2` (≠ VI=3). "Inelastic/constant rate" is the VO description and is WRONG for VI (elastic, constant interval, variable rate). **Use `.interactiveVideo`; don't treat the integer as certain.** |
| N2 | `SO_NET_SERVICE_TYPE` sets Wi-Fi UP but NOT IP DSCP on modern macOS | **confirmed** | high | Correct for ordinary Ethernet/non-Fastlane Wi-Fi (gated on `IFEF_QOSMARKING_ENABLED`). **To write DSCP on LAN use `IP_TOS`/`IPV6_TCLASS` directly** — the kernel does not zero a user-set ip_tos off-Fastlane. On Fastlane, IP_TOS is ignored. |
| N3 | User-space networking (Skywalk) is active on macOS 12+ when firewall is off | **uncertain** | med | (1) Version-dependent: macOS 14 firewall-on ⇒ BSD fallback; 15.3+ no longer forces it. (2) Apple never calls it "zero-copy". (3) Private Relay and NE VPNs also trigger fallback. **Verify with `sudo skywalkctl flow -n -P <pid>`.** |
| N4 | `sendmsg_x`(481)/`recvmsg_x`(480) are stable on macOS 14+ AS | **confirmed** | high | Numbers stable across SDKs, symbols in libSystem, in public `syscall.h`. "PRIVATE" = `msghdr_x` lives in `socket_private.h` (forward-declare). **macOS 13 hang ⇒ the "14+" qualifier is load-bearing.** |
| N5 | `net_qos_policy_restricted=0` ⇒ every app gets AC_VI without MDM | **refuted** | high | Default 0 only *permits* a socket to raise QoS when it explicitly requests it; the default class is `SO_TC_BE` (AC_BE). **Must explicitly set `.interactiveVideo`/`NET_SERVICE_TYPE_VI`.** |
| N6 | QUIC datagram TLS overhead on LAN is ~0.1–0.5 ms | **uncertain** | high | That figure is total user-space QUIC processing, not "TLS". Pure AES-GCM is sub-µs (<0.001 ms/1400 B at HW-accel). The dominant cost is packet processing, not the cipher. **Benchmark QUIC datagram vs plain UDP on this stack.** |

#### 1.7 Realtime threads / scheduling

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| RT1 | `os_workgroup_join` EINVAL = "not realtime" (set THREAD_TIME_CONSTRAINT_POLICY first) | **confirmed** | high | **Scope-limited:** applies only to `WORK_INTERVAL_TYPE_COREAUDIO`. For other workgroups EINVAL just means "cancelled". Kernel: `sched_mode != TH_MODE_REALTIME && saved_mode != TH_MODE_REALTIME`. |
| RT2 | `mach_wait_until` on an RT thread is <600 µs @99.9% | **uncertain** | high | **Wrong source** (micropython #8621, HW unspecified, not forum 120403). TN2169 only states a 500 µs soft floor on an idle machine. On AS, default threads land on E-cores. **Measure with P-core affinity/Audio Workgroup.** |
| RT3 | `yield()`/`sched_yield()` drops priority to 0 for ≤10 ms | **confirmed** | high | XNU: `sched_yield()` → `swtch_pri(0)` → `thread_depress_abstime(std_quantum)`; std_quantum=10 ms; DEPRESSPRI=0. **Applies to SCHED_RR too.** **Ban `yield()` on hot media threads; use `mach_wait_until`.** |

#### 1.8 Zero-copy / memory

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| Z1 | `SCStreamConfiguration.pixelFormat` supports `'x420'` 10-bit | **refuted** | high | The 10-bit format in the header is **'xf44' (4:4:4 full-range)**, not 'x420'. HDR APIs (`captureDynamicRange`, presets) require **macOS 15.0**, not 14.0. **For 10-bit HDR use `SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)`; don't assign 'x420'.** |
| Z2 | Setting `kCVPixelBufferPixelFormatTypeKey` causes a copy on macOS (ALVR says visionOS 2) | **uncertain** | med | The ALVR note is visionOS 2 only. On macOS the header confirms a copy (`VTPixelTransferSession`) only when the format is **incompatible**, not unconditionally. **Spike: omit the key, let the decoder output native, measure.** |
| Z3 | Private `MTLPixelFormatYCBCR8_420_2P = 500` is available on macOS 14+ AS | **uncertain** | high | Value 500 confirmed; **Apple-internal SPI** (WebKit defines under `#if USE(APPLE_INTERNAL_SDK)`), no `API_AVAILABLE`; MoltenVK maps it to `Invalid` on macOS. **Undocumented SPI — optional optimization with a 2-plane shader fallback only.** |

#### 1.9 Wi-Fi / AWDL

| # | Claim | Verdict | Conf. | Corrected statement |
|---|---|---|---|---|
| W1 | AWDL 5 GHz social channels are ch 44 / ch 149 | **confirmed** | high | Correct (ch 6 on 2.4 GHz, 44/149 on 5 GHz), from RE (Seemoo/OWL), never Apple-confirmed. **Configure the AP to ch 44/149 to kill 50–200 ms AWDL spikes.** |
| W2 | Wi-Fi Aware (`WAPerformanceMode.realtime`) does NOT exist on macOS 26 | **confirmed** | high | macOS 26.4 swiftinterface has `@available(macOS, unavailable)`. The wifip2pd daemon runs but exposes no macOS API. **Wi-Fi Aware is iOS/iPadOS 26+ clients only.** |

### 2. Corrections to the earlier design

1. **`minimumFrameInterval` (C1).** Use `CMTimeMake(1, targetFPS * 110/100)` (~10% shorter, OBS PR #11896), not `kCMTimeZero`.
2. **`queueDepth` minimum (C3).** Real default is 8; no floor; `queueDepth=2` is valid and lower-latency. Use 2 or 3 per measured release deadlines.
3. **HEVC + low-latency RC (E1/E2).** Treat as *empirical* on Apple Silicon, NOT an Apple guarantee. Runtime-probe (`VTCopySupportedPropertyDictionaryForEncoder`) + a manual HEVC fallback config (E3/E5/E6). `UsingHardwareAcceleratedVideoEncoder` returning `-12900` in low-latency mode is NOT lost HW accel (the real missing-HW error is `-12902`).
4. **`ForceLTRRefresh` type (E4).** Header self-contradicts; try both `CFNumberRef` and `kCFBooleanTrue`, pick what the encoder accepts.
5. **`MaxFrameDelayCount = 0` (E5).** = synchronous one-in-one-out (what we want), NOT "default/no-limit".
6. **`AllowOpenGOP` for HEVC (E6).** Defaults to `true` — MUST set `false`.
7. **Slice/tiles/WPP (S1–S3).** Drop NVENC-style sub-frame pipelining; VT output is frame-granular. Only inter-frame pipelining is available (capture N+1 while transmitting/decoding N).
8. **Decode pixel-format (D3).** Must match the decoder native; unified memory does NOT remove conversion cost. Don't set a non-native `kCVPixelBufferPixelFormatTypeKey`.
9. **DSCP via serviceClass (N2).** On LAN, write IP DSCP with `IP_TOS`/`IPV6_TCLASS` directly; serviceClass only sets Wi-Fi L2 UP. Use both if a managed switch needs L3 priority.
10. **AC_VI "automatic without MDM" (N5).** Set the service type explicitly; default is AC_BE.
11. **`maximumDrawableCount=2` on iOS (DP4).** Use 2 on both platforms (handle nil). Moonlight/DTS recommend 3 on macOS to avoid starvation — a trade-off to measure, not a prohibition.
12. **`CAMetalDisplayLink` "AS only" (DP1).** Don't gate on `isAppleSilicon()` for availability — it exists on every Mac on macOS 14+. Gate only for ProMotion reasons.
13. **10-bit capture (Z1).** Don't assign `'x420'` to `pixelFormat`. Use `SCStreamConfiguration(preset:)` (macOS 15+) or `'xf44'`. HDR capture requires **macOS 15.0**.
14. **Adaptive sync (DP3).** A windowed app gets NO VRR scheduling — fullscreen is required, conflicting with the "single window" differentiator. Either accept the fixed-rate compositor for windowed, or offer an optional fullscreen client mode.

### 3. Phase-0 spike — empirical validation checklist

Close every `refuted`/`uncertain` item by measurement on the target hardware (host: Apple Silicon Mac, macOS 26; client: macOS + 120 Hz ProMotion iPhone/iPad). Use `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` + `mach_timebase_info` (M1 = 125/3 — **confirm on M2/M3/M4**).

**A. Capture (ScreenCaptureKit)**
- [ ] **C1/C2 — minimumFrameInterval:** at 120 Hz measure delivered fps with (a) default (expect 60), (b) `1/120`, (c) `(1/120)×0.9`, (d) `kCMTimeZero`. *Pass:* the value giving stable ≥115 fps, no drops.
- [ ] **C3 — queueDepth:** try 1/2/3; measure drop rate + capture→encode-submit latency while encoding. *Pass:* smallest value that doesn't stall.
- [ ] **C4 — displayTime clock:** compare `DisplayTime` (→ns) vs `CACurrentMediaTime()*1e9`. *Pass:* positive, ~few ms; never negative.
- [ ] **Z1 — pixel format:** enumerate accepted formats; try '420v', 'xf44', the HDR preset. *Pass:* IOSurface-backed, no extra conversion into the VT encoder.

**B. Encode (VideoToolbox HEVC)**
- [ ] **E1/E2 — HEVC low-latency RC:** create the session, call `VTCopySupportedPropertyDictionaryForEncoder`; measure per-frame encode. *Pass:* 1080p60 & 4K60 under budget; on failure activate the manual fallback (E3/E5/E6).
- [ ] **E4 — ForceLTRRefresh type:** send with `kCFBooleanTrue` then `@(1)`. *Pass:* which type produces an LTR-P with no error.
- [ ] **E3 — EnableLTR + HEVC:** run the ACK-token loop. *Pass:* receive the LTR-ACK token; ForceLTRRefresh produces an LTR-P, not an IDR.
- [ ] **Per-frame encode latency:** `encode_done − encode_submit` for HEVC Main10 @1080p/4K @60/120. *Goal:* the real budget (the ~3.3 ms ceiling is throughput).
- [ ] **First-IDR spike:** first frame with/without `PrepareToEncodeFrames`. *Pass:* quantify the cold-start penalty.

**C. Decode + Render**
- [ ] **D2 — flags=0 sync:** measure `decode_done − decode_submit`; check `kVTDecodeInfo_Asynchronous`. *Pass:* callback before return; record internal async.
- [ ] **D3/Z2 — destination format:** compare (a) omit the key, (b) native 10-bit, (c) BGRA; measure decode + blit. *Pass:* the no-extra-copy config on macOS 26.
- [ ] **DP6 — AVSBDL vs Metal:** A/B on macOS + iOS (Metal vs AVSBDL with `DisplayImmediately=true`); measure G2G with a 240/1000 fps camera or photodiode. *Pass:* which is lower, by how many ms — don't rely on "1+ frame".
- [ ] **Z3 — private YCbCr format:** try `MTLPixelFormat(rawValue:505)`. *Pass:* works ⇒ optional optimization; fails ⇒ 2-plane shader. Don't depend on it.
- [ ] **DP5 — opaque:** presentation latency `isOpaque` true vs false. *Pass:* confirm direction (don't expect exactly 13 ms).

**D. Transport**
- [ ] **N3 — user-space networking:** `sudo skywalkctl flow -n -P <pid>` with firewall on/off. *Pass:* confirm flowsw entries + fallback conditions.
- [ ] **N4 — sendmsg_x/recvmsg_x:** forward-declare `msghdr_x`, batch-call. *Pass:* runs on macOS 14+ AS; N× syscall drop vs per-packet.
- [ ] **N6 — QUIC vs UDP:** microbench send-to-send, ~1400 B, wired. *Pass:* the real ns/packet delta.
- [ ] **N1/N5 — actual QoS marking:** set `.interactiveVideo` + `IP_TOS=AF41<<2`; Wireshark the DSCP byte (expect 0 for serviceClass alone, non-zero for IP_TOS). *Pass:* know which mechanism sets what.

**E. Realtime threads / scheduling**
- [ ] **RT1 — workgroup EINVAL:** join the CoreAudio workgroup without then with THREAD_TIME_CONSTRAINT_POLICY. *Pass:* confirm the ordering; whether a custom video workgroup needs it.
- [ ] **RT2 — mach_wait_until jitter:** wakeup jitter with/without os_workgroup_interval and P-core enrollment. *Pass:* real p50/p99/p99.9 on M-series.
- [ ] **DVFS ramp:** P-core frequency ramp on M2/M3/M4 (IOReport residency). *Pass:* confirm whether ~70 ms (M1) holds; decide if keep-warm is needed.

**F. Clock-sync & ground-truth**
- [ ] **mach_timebase:** read on every target chip. *Pass:* confirm 125/3 across M2/M3/M4.
- [ ] **NWProtocolIP.Metadata.receiveTime epoch:** confirmed **CLOCK_MONOTONIC_RAW** (advances during sleep), different from `mach_absolute_time`. *Spike:* compute the startup offset, refresh on wake. *Pass:* one-way latency non-negative and stable.
- [ ] **Ground-truth G2G:** photodiode+LED rig (~20 ns) or 240/1000 fps camera. *Pass:* the sum of software stages matches hardware within ±1 ms; >1 ms off ⇒ a clock/instrumentation bug.
- [ ] **Overlay underreport:** cross-check internal overlay numbers vs ground truth.

**G. Display phase / beat-frequency**
- [ ] **Host display rate exactness:** read the true rate (detect 59.951/59.94 vs 60.000). *Pass:* if off, `CGDisplaySetDisplayMode` to match the client and eliminate the ~17–20 s beat.
- [ ] **DP2 — preferredFrameLatency:** confirm only 1.0/2.0; measure latency at each. *Pass:* set 1.0 for streaming.

**Phase-0 exit:** every `refuted`/`uncertain` row in §1 is converted to `confirmed`/`refuted` *with measurements*, and the ground-truth G2G sits in the expected band (~14–16 ms @120 fps wired, ~22–26 ms @60 fps wired — these too need validation, being derived rather than measured on this stack).
