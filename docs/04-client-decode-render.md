# 04 — Client: Decode + Render

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

Runs on **both macOS and iOS/iPadOS** (shared code). Pipeline: received NALU → `VTDecompressionSession` → `CVPixelBuffer` → Metal render.

---

## 1. Building a CMFormatDescription from parameter sets

A `CMVideoFormatDescription` is required before creating the decode session. Build it once from the parameter sets (strip the Annex-B start codes before passing them in).

```swift
// H.264 — SPS + PPS
CMVideoFormatDescriptionCreateFromH264ParameterSets(
    allocator: kCFAllocatorDefault, parameterSetCount: 2,
    parameterSets: ptrs, parameterSetSizes: sizes,
    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)

// HEVC — VPS + SPS + PPS
CMVideoFormatDescriptionCreateFromHEVCParameterSets(
    allocator: kCFAllocatorDefault, parameterSetCount: 3,
    parameterSets: ptrs, parameterSetSizes: sizes,
    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
```

> ⚠️ **Pointer lifetime:** `Data.withUnsafeBytes` is scoped. You must keep the `Data` alive across the call (nest `withUnsafeBytes` directly or use `withExtendedLifetime`), otherwise you get hard-to-reproduce crashes.

When the parameter sets change (resolution change) → build a new `CMVideoFormatDescription` + a new session. Check `VTDecompressionSessionCanAcceptFormatDescription` before tearing down.

---

## 2. Assembling NALUs → CMSampleBuffer (AVCC)

VideoToolbox requires **AVCC** (length-prefixed), not Annex-B. If the transport sends Annex-B, convert:

```swift
func annexBToAVCC(_ body: Data) -> Data {
    var lenBE = UInt32(body.count).bigEndian
    var out = Data(bytes: &lenBE, count: 4); out.append(body); return out
}
```

> ⚠️ **Multi-slice:** one frame can contain multiple slice NALUs. Combine **all of them** into a single `CMBlockBuffer` (`[len][nalu][len][nalu]...`) and create one `CMSampleBuffer` with `sampleCount = 1`. Splitting into multiple samples → half-rendered frames, artifacts.

```swift
var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
    formatDescription: fmt, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
    sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
```

PTS: carry the encoder's original PTS with the packet (the `.valid` flag is mandatory), or use `CMClockGetTime(CMClockGetHostTimeClock())` at receive time.

---

## 3. VTDecompressionSession

```swift
var spec: [CFString: Any] = [:]
#if os(macOS)
spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true   // iOS is always HW
#endif
let bufAttrs: [CFString: Any] = [
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, // NV12 native
    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary   // IOSurface → zero-copy Metal
]
VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
    decoderSpecification: spec as CFDictionary, imageBufferAttributes: bufAttrs as CFDictionary,
    outputCallback: &cb, decompressionSessionOut: &session)
VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
```

Decode (use the output-handler closure for brevity):

```swift
VTDecompressionSessionDecodeFrameWithOutputHandler(
    session, sampleBuffer: sb,
    flags: [.enableAsynchronousDecompression],   // NOT enableTemporalProcessing (no B-frames)
    infoFlagsOut: nil
) { status, info, imageBuffer, pts, _ in
    guard status == noErr, let px = imageBuffer else { return }
    self.renderer.enqueue(px, pts: pts)   // return FAST — the callback blocks the decoder
}
```

**Latency levers:** `RealTime=true`, drop `enableTemporalProcessing` (removes the reorder buffer), NV12 native + IOSurface (zero-copy), no heavy work in the callback.

### Decode error handling

VideoToolbox has no "request keyframe" API — you must signal back to the **host** over the control channel.

| Error code | Meaning | Action |
|--------|---------|-----------|
| `-12909` BadData | Corrupt bitstream | recreate session + request keyframe |
| `-12911` Malfunction | HW fault | recreate session |
| `-12903` InvalidSession | Session is dead | recreate + request keyframe |
| `infoFlags` contains `.frameDropped` | Decoder overloaded, dropped frame | request keyframe |

> iOS is stricter than macOS about bitstream corruption (macOS often self-corrects). The handler must be robust on both.

---

## 4. Render — 2 options

### Option A — CAMetalLayer + CVMetalTextureCache (lowest latency, **recommended**)

The `CVPixelBuffer` from VideoToolbox is backed by an IOSurface → `CVMetalTextureCacheCreateTextureFromImage` maps it to an `MTLTexture` **zero-copy**.

```swift
metalLayer.device = device
metalLayer.pixelFormat = .bgra8Unorm
metalLayer.framebufferOnly = true
#if os(macOS)
metalLayer.displaySyncEnabled = false   // present as soon as the GPU finishes, no vsync wait (saves up to 1 refresh)
#endif
metalLayer.maximumDrawableCount = 2     // 2 = lowest latency (VALID on iOS — the "shouldn't" claim was refuted); handle nextDrawable nil

// Per frame: create 2 textures (Y plane .r8Unorm, UV plane .rg8Unorm) from NV12 → YCbCr→RGB shader → present
```

NV12→RGB fragment shader (BT.601/709) — see the snippet in the research. iOS has no `displaySyncEnabled` (always presents at vsync; ProMotion 120Hz brings the worst case down to 8.3ms).

### Option B — AVSampleBufferDisplayLayer (simplest)

Accepts a `CMSampleBuffer` directly (even compressed — the layer decodes by itself). Required for Picture-in-Picture on iOS.

```swift
// Set controlTimebase BEFORE enqueueing; use the host clock to present immediately:
var tb: CMTimebase?
CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
CMTimebaseSetTime(tb!, time: CMClockGetTime(CMClockGetHostTimeClock())); CMTimebaseSetRate(tb!, rate: 1.0)
displayLayer.controlTimebase = tb
displayLayer.enqueue(sampleBuffer)   // displays when PTS <= timebase
// poll displayLayer.status == .failed → flush()
```

**Comparison:**

| | CAMetalLayer | AVSampleBufferDisplayLayer |
|--|--------------|----------------------------|
| Latency | Lowest | +1–2 frames of buffering (Moonlight-QT report) |
| Complexity | High (shader, texture cache) | Very low (1 call) |
| PiP (iOS) | No | Yes |
| Color/effect control | Full | Limited |

**Decision:** use **AVSampleBufferDisplayLayer for Phase 3 (fastest path to pixels on screen)**, switch to **Metal when latency optimization is needed** or when measurements show a meaningful gap. Wrap behind a `VideoRenderer` protocol so they're swappable.

---

## 4b. Frame pacing — render-on-arrival + Pacer

On LAN, **default to render-on-arrival, NO jitter buffer** (see [10 §2–3](10-latency-optimization.md)). If judder appears due to vsync phase mismatch, add a Moonlight-style Pacer:
- **2 queues + a dedicated render thread**, vsync tick via **`CVDisplayLink`** (macOS) / **`CADisplayLink`** (iOS) — replacing Windows' `WaitForVBlank`.
- Cap render-ahead at **3 frames**; frame-drop based on a 500ms window history (drop aggressively if the queue is *continuously* >1).
- `AVSampleBufferDisplayLayer` self-paces via PTS → simple path; for Metal rendering, build your own CVDisplayLink source.

**CAMetalDisplayLink (macOS 14+/iOS 17+):** precise vsync tick; set `preferredFrameLatency = 1.0` (only 1.0 or 2.0 are accepted; iOS default is 2 → setting 1 saves ~8–16 ms). **NOT** limited to Apple Silicon (runs on every Mac with macOS 14+). Render the newest frame right before `targetTimestamp` (beam-racing).

**LTR ack:** the client must report which frames it received back to the host (over the control channel) so the host can drive LTR recovery — see [10 §1](10-latency-optimization.md).

> ⚠️ **VRR/Adaptive-sync requires FULLSCREEN (from [11](11-absolute-latency.md)):** adaptive-sync scheduling (`presentDrawable:afterMinimumDuration:`) requires a fullscreen window → a **windowed** client app gets NO benefit from VRR. This conflicts with the "single window" model; consider an optional fullscreen mode on the client if needed. On macOS, test `macOS 26 Tahoe` carefully — there are reports of a decode/present latency regression with CAMetalDisplayLink.

## 5. iOS vs macOS differences

| | iOS/iPadOS | macOS |
|--|-----------|-------|
| HW decode | Always HW, no fallback | Software fallback exists; HW is opt-in |
| `displaySyncEnabled` | Not available | Available (set false to reduce latency) |
| Bitstream tolerance | Strict | Lenient |
| ProMotion 120Hz | iPhone 13 Pro+, iPad Pro M1+ | MacBook Pro/iMac 2023+ |
| Simulator | No HW decode (except sims on M1+ Macs) | Full HW |

Capability check: `VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)`.

---

## 6. Tasks for Phase 1 & 3

- [ ] (P1, macOS) Decode + render frames received from the host → pixels on screen.
- [ ] Rendering behind a `VideoRenderer` protocol (Metal + AVSampleBuffer impls).
- [ ] (P3, iOS) Build `PaneCastClientKit` + rendering for iOS, test on a real device (Simulator has no HW decode).
- [ ] Measure glass-to-glass latency (host timestamp → client display).
