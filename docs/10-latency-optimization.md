# 10 — Latency Optimization (lessons from Parsec, Moonlight/Sunshine)

> **STATUS: REFERENCE — GUI video-path design depth.** Shipped, co-equal with terminal panes (old "Phase 4 / secondary" framing retired). Architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **GUI video-path only.** The terminal path ([12](12-coding-profile.md)) has a different latency model: network RTT (~1–5ms LAN) + local echo, **no vsync/encode/decode**. Pacer, beam-racing etc. are over-engineering for the coding profile — see [12 §3.3](12-coding-profile.md).

> Production techniques mapped onto the Apple stack. Moonlight/Sunshine are open source (code traced); Parsec publishes philosophy, not numbers. Realtime logic (pacer drop heuristics, FEC reassembly, speculative loss, LTR admission, congestion/ABR) lives in the Rust core (`slopdesk-core`) behind the C-ABI; the Swift shell owns the Apple pieces (ScreenCaptureKit, VideoToolbox, CVDisplayLink/Metal).

## 0. Core philosophy (Parsec)

**Priority: latency → frame rate → quality.** Almost every decision follows from this ordering. "Buffering is the enemy."

---

## 1. LTR instead of keyframes (the most important finding)

### The keyframe-spike problem
Packet loss corrupts the decoder's reference → corruption propagates into every later P-frame. Naive fix (send an IDR) fails: a keyframe is **5–20× heavier than a P-frame**, so on a congested link that spike adds queuing delay + new loss → the fix makes latency **worse**.

### Solution: VideoToolbox supports LTR (Long-Term Reference)
Low-latency LTR workflow (WWDC21):
1. Enable: `kVTCompressionPropertyKey_EnableLTR`.
2. Encoder marks an LTR frame + emits an ack token in the sample-buffer attachments (`RequireLTRAcknowledgementToken`).
3. Client acks received frames → host reports acked tokens via per-frame `AcknowledgedLTRTokens`.
4. On loss → per-frame **`ForceLTRRefresh`** → encoder emits a small **LTR-P frame** predicted from an acked LTR. Falls back to a keyframe **only when no acked LTR remains**.

→ **Primary recovery mechanism.** Requires a client→host feedback channel (ack + loss report).

> ⚠️ **From [11](11-absolute-latency.md):** `EnableLTR` is codec-agnostic (macOS 12+/iOS 15+) → HEVC+LTR feasible on Apple Silicon (feature-detect at runtime). `ForceLTRRefresh` is header-inconsistent (annotation `CFNumberRef` vs abstract `kCFBooleanTrue`) → **test both `@(1)` and `kCFBooleanTrue` at runtime**; do not hardcode.

### Supplementary: temporal scalability
`kVTCompressionPropertyKey_BaseLayerFrameRateFraction = 0.5` splits the stream into base + enhancement layers; enhancement frames are unreferenced → losing one does not propagate. Cheap error resilience. Identify layers via `CMSampleAttachmentKey_IsDependedOnByOthers`.

### What VideoToolbox cannot do (unlike NVENC)
- ❌ **Ref-frame invalidation by frame ID** (`NvEncInvalidateRefFrames`) — not exposed. Replaced by the LTR-ack model ("refresh from an acked LTR" instead of "frame 47 is corrupt").
- ❌ **Gradual/periodic intra-refresh** — no public property; use LTR.
- ❌ **Slice / sub-frame pipelining** — confirmed unavailable via public API ([11](11-absolute-latency.md)): output is **frame-granular** (one callback per frame). Private `NumberOfSlices`/`NumberOfSubFrameSections` exist in the .tbd but behavior unknown → dropped. Only parallelism is **inter-frame pipelining** (capture N+1 ‖ transmit/decode N).

---

## 2. Frame pacing & render pipeline (Moonlight `Pacer`)

### Render-on-arrival is the LAN default
On wired LAN jitter is sub-ms → a time-based jitter buffer is near-pure loss. **Do not add one.**

### Pacer architecture (`pacer.cpp`)
- **2 queues, 2 threads:** decoder pushes into the pacing queue → the vsync tick (TIME_CRITICAL) moves exactly 1 frame to the render queue → the HIGH-priority render thread consumes it.
- **Vsync-gated dequeue:** a late frame still gets one chance at the current vsync (3ms slack) instead of waiting a full frame.
- **Tiny render-ahead:** `MAX_QUEUED_FRAMES = 3`, total outstanding = 5 (matches the decoder surface pool).
- **History-based drop:** keep a 500ms window of queue depth. Persistently >1 → drop to target=1; ever ≤1 → lenient (target=3). Avoids dropping on transient bursts.

**Apple mapping:**
- Vsync tick = **`CVDisplayLink`** (macOS) / **`CADisplayLink`** (iOS).
- Keep the 2-queue design + dedicated render thread + 3-frame cap + windowed drop (display-rate-agnostic).
- **`AVSampleBufferDisplayLayer`** self-paces via PTS → a simple render-on-arrival path may suffice. **Metal** → build the CVDisplayLink vsync source for the full pacer.

---

## 3. Receive path — no jitter buffer

Moonlight `RtpVideoQueue` + `VideoDepacketizer`:
- **Reassemble-and-submit-immediately.** The only "buffer" is FEC reassembly of *one* frame, not a time delay.
- Enough shards (incl. FEC-recovered) → submit immediately.
- **Out-of-order:** fast path assumes in-order; the first OOO packet switches to slow insert + dedupe. OOO within a frame absorbed; too-old packets rejected.
- **Whole-frame loss:** a new frame's packets arriving before the current completes → declare the current unrecoverable and jump. **Never stall for a stray packet.**
- Depacketizer→decoder queue bounded **≤15**; overflow → request recovery.

**Apple mapping:** `NWConnection` UDP → our FEC-block reassembler (Rust core). No time-based jitter buffer for LAN. Small bounded queue into `VTDecompressionSession`.

---

## 4. Loss recovery — FEC + speculative loss

### FEC
- **Moonlight reference (Reed-Solomon):** `parity = ceil(data * fec%/100)`, default 20% (floor 2); per-frame host-driven (% in the frame header, client obeys); large frames split into ≤4 independently-recovering blocks; 4K uses lower FEC (5%).
- **Built path:** Reed–Solomon over GF(2⁸) (NEON) + adaptive tiering (`FECScheme` + `AdaptiveFECPolicy`, Rust core) — host-driven per-frame %, scaled to link conditions. `m=1` is wire-identical to the old XOR parity; `m≥2` recovers multi-packet loss.

### Speculative loss detection
Predict frame loss **before** the next frame arrives — once the shard count proves recovery impossible, fire the loss-notify immediately → saves one frame-time. Self-corrects if wrong.

### LAN policy (with [03](03-transport-protocol.md))
1. Clean wired LAN: low FEC (0–10%) + LTR + speculative loss. Wi-Fi/lossy: 15–20%, multi-block. `AdaptiveFECPolicy` scales this automatically.
2. Recovery prefers **LTR refresh** (§1); keyframe only when no acked LTR remains.
3. **FEC-first, with a NACK backstop** (re-scoped 2026-06-18, `SLOPDESK_NACK`, default OFF — see [03 §FEC vs retransmit](03-transport-protocol.md)): FEC recovers loss at zero added latency; a frame it can't recover is held briefly and the client NACKs the missing fragments, which the host re-sends from a ring. The old "no retransmit (1 RTT → stutter)" rule assumed naive replay-and-stall; with a playout buffer ≫ RTT the retransmit lands *inside* the buffer → no stutter. LTR-refresh / IDR is the fallback once the retransmit grace expires.

---

## 5. Encoder recipe (Sunshine, verified) → VideoToolbox

The universal "ultra-low-latency" formula:

| Concept | Sunshine/NVENC | VideoToolbox |
|-----------|----------------|--------------|
| **Infinite GOP + on-demand IDR** | `gopLength = INFINITE`, IDR on request | `MaxKeyFrameInterval = INT_MAX` + per-frame `ForceKeyFrame` (no periodic timer keyframes) |
| **No B-frames** | `frameIntervalP=1` | `AllowFrameReordering = false` |
| **One-in-one-out** | `zeroReorderDelay=1` | automatic in low-latency mode |
| **CBR + VBV ~1 frame** | `rateControlMode=CBR`, `vbvBufferSize=bitrate/fps` | `ConstantBitRate` (or `AverageBitRate` + `DataRateLimits` = [bytes, 1s]) |
| **Cap per-frame size** | — | `MaxAllowedFrameQP` (complex frames can't blow the budget) |
| **No lookahead** | `enableLookahead=0` | `RealTime=true` |
| **VUI bitstream restriction** | `bitstreamRestrictionFlag=1` | ensure the SPS carries the flag → shrinks the decoder reorder buffer |
| **LTR recovery** | RFI/LTR ack | `EnableLTR` + ack workflow (§1) |

> **Supersedes** [02](02-host-capture-encode.md)'s `MaxKeyFrameInterval=120` → use effectively infinite + on-demand IDR. Periodic timer keyframes = pointless latency spikes.

---

## 6. Input latency (input-to-photon)

Moonlight `InputStream.c` rules:
- **Batch mouse/pen motion in a 1ms window** (`MOUSE_BATCHING_INTERVAL_MS=1`) — batching *reduces* effective latency by preventing packet queuing in the reliable stack.
- **Button/key down/up never batched** — send immediately.
- Coalesce relative-mouse deltas; absolute mouse keeps only the latest value.
- **Dedicated high-priority input channel**, never head-of-line-blocked by video. Input is **reliable** (a lost keystroke is worse than a lost frame) but off the video path.
- Timestamp + sequence every input → host orders/dedupes + measures round-trip.

**Apple mapping:** a dedicated `NWConnection` input channel ([03 §3](03-transport-protocol.md)); 1ms-batch-motion / immediate-button verbatim.

---

## 7. ⭐ Client-side cursor (big, easily-missed win)

Re-encoding the HW cursor into the video → the cursor lags the whole pipeline (clearly perceptible).

**Fix:** exclude the cursor from capture (`SCStreamConfiguration.showsCursor = false`) + draw it client-side from the low-latency cursor-position channel → pointer latency = RTT regardless of video latency. Host sends position over the control channel; client draws a Metal overlay.

---

## 8. Adaptive bitrate

Naive min/max ABR "bounces between min/max, never settles" (Moonlight) → avoid. The built path runs a delay-gradient + loss-driven congestion controller — **`LiveCongestionController` + `LiveBitratePolicy`** (Rust core) — that backs off bitrate on sustained loss / queue growth via `AverageBitRate` and recovers, prioritizing latency (Parsec's model: drop bitrate on loss). It settles at a generous cap on a clean LAN and, being driven by a delay-gradient trendline rather than raw single samples, does not oscillate.

---

## 9. ⭐ Compositor/vsync tail — the largest hidden client-side latency

Even rendering on arrival, a frame is gated by **vsync + the window-server compositor** → up to one refresh interval of wait. **Usually the largest client-side latency you can control.**

- A low-overhead Metal path, presenting as close to vsync as possible.
- Avoid unnecessary layer compositing.
- macOS: `CAMetalLayer.displaySyncEnabled = false` (present as soon as the GPU finishes).
- iOS ProMotion 120Hz → worst-case wait drops to 8.3ms.

---

## 10. Measurement — instrument 6 stages

**Timestamp frames at the host** (at encode completion, in the frame header) → separates host latency from network+client. Segments:

1. **Host** (capture + encode) — from the header timestamp.
2. **Network** = RTT + variance (reliable ping/ack).
3. **Reassembly** = frame-complete − first-packet-received.
4. **Decode** = around `VTDecompressionSessionDecodeFrame`.
5. **Queue/pacer** = time in the pacing queue.
6. **Render (+vsync)** = around present.

Ground truth: a **240fps camera** filming input device + screen, counting frames action→response (server/client delays are invisible to network tools).

---

## 11. Counterintuitive lessons

- Keyframes to "fix" loss make things worse → LTR (§1).
- A "just in case" jitter buffer makes LAN feel worse (fixed added latency vs jitter that doesn't exist).
- **Uncapped VBR bites back:** complex scene → giant frame → link overflow → latency spike for *everything*. Cap it (`MaxAllowedFrameQP`).
- **HEVC is not automatically lower-latency than H.264** — some devices decode H.264 faster. Measure ([09](09-codec-choice.md)).
- **Stadia "negative latency"** (ML input prediction) — useless at LAN RTT ~1ms. Skip.

---

## 12. Roadmap

- **Phase 0:** verify LTR symbols on the target SDK; measure encode latency H.264 vs HEVC.
- **Phase 1:** pacer (CVDisplayLink, 2-queue) or AVSampleBufferDisplayLayer render-on-arrival; 6-stage instrumentation; host timestamp in the header.
- **Phase 1–2:** LTR recovery loop (client→host ack + `ForceLTRRefresh`).
- **Phase 2:** input 1ms-batch / immediate-button; client-side cursor.
- **Phase 4:** temporal scalability; adaptive FEC for Wi-Fi.

---

## Code references
- **Moonlight** (client): `pacer.cpp`, `RtpVideoQueue.c`, `VideoDepacketizer.c`, `ControlStream.c`, `InputStream.c`.
- **Sunshine** (host): `video.cpp` (per-vendor encoder option tables), `nvenc_base.cpp` (RFI/LTR/intra-refresh), `stream.cpp` (FEC + frame header).
- The closest readable "open-source Parsec".
