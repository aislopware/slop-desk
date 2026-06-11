# 10 — Latency Optimization (lessons from Parsec, Moonlight/Sunshine)

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Applies to the GUI video-path only.** The terminal path ([12](12-coding-profile.md)) has a completely different latency model: dominated by network RTT (~1–5ms LAN) + local echo, **no vsync/encode/decode**. Many techniques below (pacer, beam-racing) are **over-engineering for the coding profile** — see [12 §3.3](12-coding-profile.md).

> A synthesis of techniques from production systems, mapped onto the Apple stack. Moonlight/Sunshine are open source → the real code is readable (traced). Parsec publishes its philosophy, not millisecond numbers.

## 0. Core philosophy (Parsec)

**Priority order: LATENCY first → frame rate → quality.** Almost every decision below is a consequence of this ordering. "Buffering is the enemy."

---

## 1. The MOST IMPORTANT finding: LTR instead of keyframes (fixes the old design)

### The "keyframe spike" problem
On packet loss the decoder's reference is corrupted → corruption propagates into every subsequent P-frame. The naive fix is to send an IDR/keyframe — **but a keyframe is 5–20× heavier than a P-frame**. On an already-congested link that spike adds queuing delay + new packet loss → the "fix" makes latency **worse**. This is the keyframe trap.

### The solution: **VideoToolbox DOES support LTR** (Long-Term Reference)
This is the big difference from the old design (drop-frame + request-keyframe only). The LTR workflow in low-latency mode (WWDC21):

1. Enable LTR: `kVTCompressionPropertyKey_EnableLTR`.
2. The encoder marks a frame as LTR and emits an **acknowledgement token** in the sample-buffer attachments (`RequireLTRAcknowledgementToken`).
3. The client acks received frames → the host reports acked tokens back via the per-frame option `AcknowledgedLTRTokens` (array).
4. On packet loss → request recovery via the per-frame option **`ForceLTRRefresh`** → the encoder emits a small **LTR-P frame**, predicted from an already-acked LTR. **Only when no acked LTR remains does it fall back to a keyframe.**

→ **This is our primary recovery mechanism.** We need a client→host feedback channel (ack + loss report) to drive it.

> ⚠️ **Update from [11](11-absolute-latency.md):** `EnableLTR` is **codec-agnostic** (macOS 12+/iOS 15+) → HEVC+LTR is feasible on Apple Silicon (still feature-detect at runtime). **`ForceLTRRefresh` is internally inconsistent in the header:** the annotation says `CFNumberRef`, the abstract says `kCFBooleanTrue` → **test both (`@(1)` and `kCFBooleanTrue`) at runtime**, do not hardcode.

### Supplementary: temporal scalability
`kVTCompressionPropertyKey_BaseLayerFrameRateFraction = 0.5` splits the stream into base + enhancement layers; enhancement frames are not referenced → losing one does not propagate. Cheap error resilience. Identify layers via `CMSampleAttachmentKey_IsDependedOnByOthers`.

### What VideoToolbox CANNOT do (unlike NVENC)
- ❌ **Reference-frame invalidation by frame ID** (`NvEncInvalidateRefFrames`) — not exposed. Replaced by the LTR-ack model above (equivalent recovery, different control surface: instead of saying "frame 47 is corrupt" you say "refresh from an acked LTR").
- ❌ **Gradual/periodic intra-refresh** (spreading I-blocks across multiple frames) — no public property. Use LTR instead. (Re-verify the header.)
- ❌ **Slice / sub-frame pipelining** — **confirmed NOT available** via public API ([11](11-absolute-latency.md)): VideoToolbox output is **frame-granular** (one callback per frame). Private symbols `NumberOfSlices`/`NumberOfSubFrameSections` exist in the .tbd but their behavior is **unknown** → dropped. The only available parallelism is **inter-frame pipelining** (capture N+1 ‖ transmit/decode N).

---

## 2. Frame pacing & render pipeline (Moonlight `Pacer`)

### Render-on-arrival is the default for LAN
Parsec is "zero-buffered". Moonlight: "real-time cannot buffer because it adds large latency." On wired LAN jitter is sub-ms → a jitter buffer is nearly a pure loss. **Do NOT add a time-based jitter buffer.**

### Pacer architecture (port to Apple)
Moonlight `pacer.cpp`:
- **2 queues, 2 threads:** pacing queue (decoder pushes in) → the vsync tick moves 1 frame to the render queue → the render thread (priority HIGH) consumes it. The vsync thread runs at TIME_CRITICAL priority.
- **Vsync-gated dequeue:** each refresh tick moves exactly 1 frame. A late frame still gets one chance at the current vsync (3ms slack) instead of waiting a full frame.
- **Tiny render-ahead:** cap `MAX_QUEUED_FRAMES = 3`, total outstanding = 5 (matching the decoder surface pool).
- **History-based frame-drop (not naive):** keep a 500ms window of queue depth. If the queue is *persistently* >1 → drop aggressively (target=1); if it was ever ≤1 → be lenient (target=3). Avoids dropping due to transient bursts.

**Apple mapping:**
- Replace `IVsyncSource` (Windows `WaitForVBlank`) with **`CVDisplayLink`** (macOS) / **`CADisplayLink`** (iOS) as the vsync tick.
- Keep the 2-queue design + dedicated render thread + 3-frame cap + windowed drop heuristic (display-rate-agnostic).
- If rendering via **`AVSampleBufferDisplayLayer`**: it self-paces via PTS → a simple render-on-arrival path may suffice. If rendering via **Metal**: build your own CVDisplayLink vsync source to get the full pacer.

---

## 3. Receive path — no jitter buffer

Moonlight `RtpVideoQueue` + `VideoDepacketizer`:
- **Reassemble-and-submit-immediately.** The only "buffer" is FEC reassembly of *one frame*, not a time-based delay.
- Enough shards (including FEC-recovered) → submit immediately, do not wait for future frames.
- **Out-of-order:** the fast path assumes in-order; the first OOO packet switches to slow insert + dedupe. OOO *within* a frame is absorbed; packets that are too old are rejected.
- **Whole-frame loss:** packets of a new frame arriving before the current frame completes → declare the current frame unrecoverable and jump to the new frame. **Never stall waiting for a stray packet.**
- The depacketizer→decoder queue is bounded **≤15**; overflow → request recovery.

**Apple mapping:** `NWConnection` UDP → write our own FEC-block reassembler. **Do not** add a time-based jitter buffer for LAN. Small bounded queue between the depacketizer and `VTDecompressionSession`.

---

## 4. Loss recovery — FEC + speculative loss

### FEC (Reed-Solomon)
- Host: `parity = ceil(data * fec% / 100)`. Default **20%**, minimum floor of 2 parity shards.
- **Per-frame, host-driven:** the FEC % is embedded in each frame's header; the client simply obeys it.
- **Multi-FEC blocks:** large frames are split into ≤4 blocks, each recovering independently → one block can be rescued while another is still arriving.
- **4K uses lower FEC** (5%) to reduce overhead.

### Speculative loss detection (latency optimization)
Predict frame loss **before** the next frame arrives — when the shard count proves recovery is impossible. Fire the loss-notify immediately → saves one frame-time. Self-corrects if the guess was wrong.

### Our LAN recommendations (combined with doc [03](03-transport-protocol.md))
1. **Wired LAN:** low/no FEC (0–10%), rely on LTR recovery + speculative loss. **Wi-Fi:** FEC 15–20%, multi-block.
2. Recovery prefers **LTR refresh** (§1) → keyframe only when no acked LTR remains.
3. **No retransmit for video** (costs 1 RTT → stutter). Retransmit only for input/control.

---

## 5. Encoder recipe (Sunshine, verified) → VideoToolbox

The universal "ultra-low-latency" formula:

| Concept | Sunshine/NVENC | VideoToolbox |
|-----------|----------------|--------------|
| **Infinite GOP + on-demand IDR** | `gopLength = INFINITE`, IDR on request | `MaxKeyFrameInterval = INT_MAX` + `ForceKeyFrame` per-frame (NO periodic timer-based keyframes!) |
| **No B-frames** | `frameIntervalP=1` | `AllowFrameReordering = false` |
| **One-in-one-out** | `zeroReorderDelay=1` | handled automatically by low-latency mode |
| **CBR + VBV ~1 frame** | `rateControlMode=CBR`, `vbvBufferSize=bitrate/fps` | `ConstantBitRate` (or `AverageBitRate` + `DataRateLimits` = [bytes, 1s]) |
| **Cap per-frame size** | — | `MaxAllowedFrameQP` (complex frames cannot blow the budget) |
| **No lookahead** | `enableLookahead=0` | `RealTime=true` handles it |
| **VUI bitstream restriction** | `bitstreamRestrictionFlag=1` ("critical for low decode latency") | ensure the SPS carries the flag → shrinks the decoder reorder buffer |
| **LTR recovery** | RFI/LTR ack | `EnableLTR` + ack workflow (§1) |

> **Correction to an older doc:** [02](02-host-capture-encode.md) says `MaxKeyFrameInterval=120` — should become **effectively infinite + on-demand IDR**. Periodic timer-based keyframes = pointless latency spikes.

---

## 6. Input latency (input-to-photon)

Moonlight `InputStream.c` — platform-independent rules, **port directly**:
- **Batch mouse/pen motion in a 1ms window** (`MOUSE_BATCHING_INTERVAL_MS=1`). Paradox: batching *reduces* effective latency because it prevents packet queuing in the reliable stack.
- **Button/key down/up is NEVER batched** — send immediately.
- Coalesce relative-mouse deltas; for absolute mouse keep only the latest value.
- **A dedicated, high-priority input channel**, never head-of-line-blocked by video. Input should be **reliable** (a lost keystroke is worse than a lost video frame) but on a path that does not block video.
- Timestamp + sequence every input → host orders/dedupes + measures round-trip.

**Apple mapping:** a dedicated `NWConnection` channel for input (see [03 §3](03-transport-protocol.md)); replicate the 1ms-batch-motion / immediate-button rules verbatim.

---

## 7. ⭐ Mouse cursor — draw client-side (big latency win, easy to miss)

Capturing + re-encoding the HW cursor into the video stream → the cursor lags the entire pipeline (clearly perceptible).

**Fix:** **exclude the cursor from the video** (`SCStreamConfiguration.showsCursor = false` — already set) + **draw the cursor client-side** from the low-latency input/cursor-position channel. The cursor feels instant regardless of video latency. → The host sends cursor position over the control channel; the client draws a Metal overlay.

---

## 8. Adaptive bitrate — NOT needed for LAN

A Moonlight comment says it flatly: dynamic bitrate "bounces between min/max, never settles" → **disabled**. Parsec instead drops bitrate on packet loss (prioritizing latency).

**Us (LAN):** skip closed-loop ABR. Set the bitrate once at init (a generous cap since LAN is uncongested). If anything, only: per-frame FEC reports + a connection-quality indicator + (optionally) dropping bitrate on sustained loss via `VTSessionSetProperty(AverageBitRate)`.

---

## 9. ⭐ Compositor/vsync tail — the largest hidden client-side latency

Even rendering "on arrival", a frame is still gated by **vsync + the window-server compositor** → it can sit waiting for up to one refresh interval. **This is usually the largest client-side latency source you can control.**

Mitigations:
- A low-overhead Metal path, presenting as close to vsync as possible.
- Avoid unnecessary layer compositing.
- macOS: `CAMetalLayer.displaySyncEnabled = false` (present as soon as the GPU finishes).
- iOS ProMotion 120Hz → worst-case wait drops to 8.3ms.

---

## 10. Measurement — instrument 6 stages

Moonlight's stats overlay = the measurement spec. **Timestamp frames at the host** (at encode completion) embedded in the frame header → separates host latency from network+client. Six segments to measure:

1. **Host processing** (capture + encode) — from the host timestamp in the header.
2. **Network** = RTT + variance (measured via reliable ping/ack).
3. **Reassembly** = time-frame-complete − time-first-packet-received.
4. **Decode** = around the `VTDecompressionSessionDecodeFrame` call.
5. **Queue/pacer delay** = time spent in the pacing queue.
6. **Render (+vsync)** = around present.

Ground truth: a **240fps camera** filming the input device + screen, counting frames from action → response (server/client delays are invisible to network tools).

---

## 11. Counterintuitive lessons (hard-won)

- **Keyframes to "fix" loss make things worse** → use LTR (§1).
- **A "just in case" jitter buffer makes LAN feel worse** (fixed added latency against jitter that doesn't exist).
- **Uncapped VBR bites back:** complex scene → giant frame → link overflow → latency spike for *everything*. Must cap (`MaxAllowedFrameQP`).
- **HEVC is NOT automatically lower-latency than H.264** — some devices decode H.264 faster. Don't assume the newer codec wins on latency. (Measure; see [09](09-codec-choice.md).)
- **Stadia "negative latency"** (ML input prediction) — useless for LAN (RTT ~1ms). **Skip.**

---

## 12. Roadmap updates

Add to the phases:

- **Phase 0:** verify LTR symbols (`EnableLTR`...) on the target SDK; measure encode latency H.264 vs HEVC.
- **Phase 1:** Pacer (CVDisplayLink, 2-queue) or AVSampleBufferDisplayLayer render-on-arrival; instrument the 6-stage latency; host timestamp in the frame header.
- **Phase 1–2:** **LTR recovery loop** (client→host ack + `ForceLTRRefresh`) instead of keyframes only.
- **Phase 2:** input 1ms-batch / immediate-button; **client-side cursor drawing**.
- **Phase 4:** temporal scalability, adaptive FEC for Wi-Fi.

---

## Code references worth reading
- **Moonlight** (client): `pacer.cpp`, `RtpVideoQueue.c`, `VideoDepacketizer.c`, `ControlStream.c`, `InputStream.c`.
- **Sunshine** (host): `video.cpp` (per-vendor encoder option tables), `nvenc_base.cpp` (RFI/LTR/intra-refresh), `stream.cpp` (FEC + frame header).
- The closest readable implementation to "an open-source Parsec".
