# 02 — Host: Per-Window Capture + Encode

> **STATUS: REFERENCE — GUI video-path design depth.** Shipped, co-equal with terminal panes (the old "Phase 4 / secondary" framing is retired). Architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

Host pipeline: **ScreenCaptureKit (capture one window)** → **VideoToolbox (low-latency HW encode)** → NALUs to native Swift packetization + FEC + ABR (`SlopDeskVideoProtocol`) → transport ([03](03-transport-protocol.md)). This doc covers capture + encode.

---

## 1. Capture with ScreenCaptureKit

### 1.1 Enumerating windows

```swift
let content = try await SCShareableContent.excludingDesktopWindows(
    false,
    onScreenWindowsOnly: false   // false: also include minimized/offscreen windows
)
for window in content.windows {
    window.windowID                  // CGWindowID — stable identifier
    window.title                     // may be nil
    window.frame                     // CGRect (CG screen space, top-left, points)
    window.isOnScreen
    window.owningApplication?.processID        // pid_t — needed for input injection
    window.owningApplication?.bundleIdentifier
}
```

### 1.2 Filtering a single window

```swift
let filter = SCContentFilter(desktopIndependentWindow: targetWindow)
```

`desktopIndependentWindow` characteristics (WWDC22 session 10155):
- Output origin is always `(0,0)`, not the on-screen position.
- Excludes child/popup windows — only the exact `SCWindow` selected.
- Captures even when the window is **occluded** or offscreen.
- **Minimized** → stream pauses, auto-resumes on restore.
- **Closed** → stream stops, calls `stream(_:didStopWithError:)`.

### 1.3 Stream configuration

```swift
let config = SCStreamConfiguration()
config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // NV12 — cheapest for encode
config.width  = Int(window.frame.width)  * scaleFactor   // scaleFactor from NSScreen, do NOT hardcode 2
config.height = Int(window.frame.height) * scaleFactor
// DECIDED: default 60fps (30 reads noticeably stale on scroll/motion); idle-skip keeps bandwidth ~0 when static ([DECISIONS]/[12]/[17]).
// MUST be set explicitly (macOS 15+ silently defaults to 1/60, which happens to match).
config.minimumFrameInterval = CMTimeMake(value: 1, timescale: 60)   // 60fps; idle-skip → ~0 when static
config.queueDepth = 3          // real default is 8 (not 3); 2–3 for low latency (release buffers quickly)
config.showsCursor = false   // strip cursor → draw it client-side for instant feel (see 10 §7)
```

> ⚠️ **scaleFactor / minimumFrameInterval / queueDepth (from [11](11-absolute-latency.md)):** No API reads scale from `SCShareableContent` — query `NSScreen` by `displayID`; hardcoding `×2` breaks non-Retina external displays. macOS 15+ silently defaults `minimumFrameInterval` to `1/60` → set it explicitly; default **60fps** (30 reads stale on scroll/motion; idle-skip → ~0 when static; ProMotion 120 dropped). `queueDepth` really defaults to **8** (no floor of 3 — a CGDisplayStream mix-up) → use **2–3**, releasing the IOSurface within `minimumFrameInterval × (queueDepth−1)`.

### 1.4 Receiving frames

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
            of type: SCStreamOutputType) {
    guard type == .screen,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
              as? [[SCStreamFrameInfo: Any]],
          let info = attachments.first,
          (info[.status] as? SCStreamFrameStatus) == .complete   // skip .idle / .blank / .suspended
    else { return }

    let dirtyRects = info[.dirtyRects] as? [CGRect] ?? []   // only changed regions → can optimize bitrate
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    encoder.encode(pixelBuffer: pixelBuffer, pts: pts)
}
```

**Optimizations:**
- `status == .idle` → static window, no new pixels → **skip encoding entirely** (drives bandwidth toward ~0 between motion bursts; the 60fps default only spends frames when pixels change).
- `dirtyRects` → encode only changed regions (advanced, later).

### 1.5 Lifecycle

| Event | Behavior |
|---------|---------|
| Resize | SCKit auto-scales to `width`/`height`; stream continues. `contentRect`/`contentScale` in attachments reflect new geometry |
| Move to another display | Continues; `scaleFactor` may change if DPI differs |
| Minimize | Stops emitting frames, auto-resumes |
| Close | `stream(_:didStopWithError:)` → must `stopCapture()` + release |

Dynamic updates without restart:
```swift
try await stream.updateConfiguration(config)           // change fps/resolution
try await stream.updateContentFilter(newFilter)        // change the captured window
```

---

## 2. Encode with VideoToolbox

### 2.1 Creating a low-latency session (H.264)

```swift
// EnableLowLatencyRateControl is H.264-ONLY and must be set in the ENCODER SPEC at session creation
let encoderSpec: [CFString: Any] = [
    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
]
var session: VTCompressionSession?
VTCompressionSessionCreate(
    allocator: kCFAllocatorDefault, width: w, height: h,
    codecType: kCMVideoCodecType_H264,
    encoderSpecification: encoderSpec as CFDictionary,
    imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &session)

VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) // NO B-frames
// Infinite GOP + on-demand IDR — NO periodic timer-based keyframes (every keyframe = a useless latency spike).
// Recovery via LTR (see 10-latency-optimization.md §1); only force an IDR when no acked LTR remains.
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int.max as CFNumber)
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber) // match 60fps capture
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) // LTR recovery — verify symbol vs SDK
VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_AverageBitRate, value: (8_000_000/8) as CFNumber) // bytes/s!
VTCompressionSessionPrepareToEncodeFrames(session!)

// Output via a closure (cleaner than a function pointer):
VTCompressionSessionSetOutputHandler(session!) { status, flags, sb in
    guard status == noErr, let sb else { return }
    self.handleEncoded(sb)
}
```

### 2.2 HEVC 8-bit 4:2:0 (our default codec)

> ✅ **Correcting an old assumption:** on **Apple Silicon**, `EnableLowLatencyRateControl` supports **HEVC too** (confirmed via FFmpeg `videotoolboxenc.c`: gate `H264 || (arm64 && HEVC)`). Only **Intel Macs** are H.264-only. → Use low-latency for HEVC, but **feature-detect at session creation** (Apple hasn't pinned a docs version).

```swift
let spec: [CFString: Any] = [
    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true   // OK on Apple Silicon — feature-detect
]
VTCompressionSessionCreate(... codecType: kCMVideoCodecType_HEVC ...)
// Main 10 only pays off if input is also 10-bit (needs 10-bit capture = macOS 15 HDR preset, see below).
// Default is 8-bit → use kVTProfileLevel_HEVC_Main_AutoLevel:
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
// CORRECTIONS from [11]: HEVC defaults to AllowOpenGOP=true → MUST set false (independently decodable IDR recovery):
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse)
// MaxFrameDelayCount=0 → force one-in-one-out (synchronous emit). NOT "no-limit" (that's -1):
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
// Note: low-latency mode has no VT-internal ABR — the Swift ABR/congestion controller drives AverageBitRate at runtime.
```

HEVC HW encode is always available on Apple Silicon & Intel Macs with a T2.

> ⚠️ **10-bit pixel format CORRECTION (Z1, from [11](11-absolute-latency.md)):** `SCStreamConfiguration` does **NOT** accept `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` (`'x420'`) — not in the supported list. 10-bit YCbCr is listed as `'xf44'` (4:4:4 full-range). For **10-bit HDR capture** use `SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)` — requires **macOS 15.0** (not 14.0). → Default pipeline uses **8-bit `'420v'`** (`420YpCbCr8BiPlanarVideoRange`) for zero-copy; 10-bit is an HDR option requiring macOS 15.

> ⚠️ **4:2:0 chroma is the quality ceiling for text** — Apple HW encode has **no 4:4:4** (neither H.264 nor HEVC); changing codec doesn't fix it. Mitigations: 10-bit (macOS 15+) + high capture resolution. See [09-codec-choice.md](09-codec-choice.md).

### 2.3 Encoding one frame + forcing a keyframe

```swift
var props: CFDictionary?
if forceKeyframe {   // when the client sends request-keyframe (packet loss / a new viewer joins)
    props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
}
VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
    presentationTimeStamp: pts, duration: .invalid,
    frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: &flags)
```

### 2.4 Extracting NALUs + parameter sets

VideoToolbox returns **AVCC** (4-byte length prefix). Convert to **Annex-B** (`00 00 00 01`) or keep as AVCC depending on the protocol — settled in [03](03-transport-protocol.md).

```swift
func handleEncoded(_ sb: CMSampleBuffer) {
    let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [CFDictionary]
    let isKey = !CFDictionaryContainsKey(attach?.first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    if isKey {
        // Extract parameter sets, send them BEFORE the IDR (and whenever they change)
        // H.264: SPS(0)+PPS(1) via CMVideoFormatDescriptionGetH264ParameterSetAtIndex
        // HEVC : VPS(0)+SPS(1)+PPS(2) via CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
    }
    // Walk the CMBlockBuffer, read the length prefix, split out each NALU
}
```

### 2.5 Low-latency property table

| Key | Value | Notes |
|-----|---------|---------|
| `EnableLowLatencyRateControl` (encoder spec) | `true` | H.264 documented; **HEVC empirical on Apple Silicon** — feature-detect at runtime |
| `RealTime` | `true` | Prioritize latency over quality |
| `AllowFrameReordering` | `false` | Disable B-frames → "one in, one out" |
| `AllowOpenGOP` | `false` | **HEVC defaults to `true` → MUST set false** (independently decodable IDR) |
| `MaxFrameDelayCount` | `0` | Force synchronous one-in-one-out emit (NOT "no-limit"; no-limit is `-1`) |
| `MaxKeyFrameInterval` | `Int.max` | Infinite GOP + on-demand IDR/LTR (NO periodic timer-based keyframes) |
| `AverageBitRate` | bytes/s | **Note: bytes, not bits** |
| `DataRateLimits` | `[maxBytes, seconds]` | Hard cap over a sliding window |
| `MaxAllowedFrameQP` | e.g. 40 | Caps the size of complex frames (avoids global latency spikes) |
| `ForceKeyFrame` (per-frame) | `true` | For packet-loss recovery |

---

## 3. Gotchas (from research)

- `EnableLowLatencyRateControl`: Apple Silicon supports H.264 **and** HEVC; Intel = H.264 only. **Feature-detect at session creation** (don't gate by OS version — Apple hasn't pinned one for HEVC).
- Low-latency mode has no VT-internal ABR — the app drives `AverageBitRate` from the Swift ABR/congestion controller at runtime.
- `UsingHardwareAcceleratedVideoEncoder` returns `-12900` in low-latency mode — known quirk; the HW encoder still runs.
- `AverageBitRate` is **bytes/second**, not bits. VideoToolbox emits **AVCC** — convert to Annex-B yourself if the protocol needs it.
- Send parameter sets **before** the first IDR and **re-send on change** (e.g. resolution). Under packet loss, attach them to **every** keyframe so a recovering client can decode.

## 4. Phase 0 spike tasks

- [ ] Capture one window → dump actual fps, confirm idle-frame skipping works.
- [ ] Encode HEVC low-latency → **measure encode latency** on the target machine.
- [ ] Verify parameter sets + NALUs can be extracted, then reassembled and decoded (host-internal loop).
