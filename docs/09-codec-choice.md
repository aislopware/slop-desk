# 09 — Codec Choice

> **STATUS: REFERENCE — GUI video-path (Phase 4).** Current architecture: [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

> ⚠️ **Re-scope (hybrid):** text-heavy content (terminal/code) goes over the **PTY path — NOT through a codec, absolutely crisp** ([12](12-coding-profile.md)). Video is only for **GUI windows**, where **HEVC 4:2:0 8-bit quality-mode (`Quality≈0.6`, Apple Silicon) is sufficient**. → The **4:4:4 / text-crispness problem below is NO LONGER central** (drop the "software 4:4:4 tier"; 10-bit demoted to optional). The sections below are kept as codec background for the GUI path.

> In-depth research for the context: **Apple-only, LAN, low-latency, content is screen/text** (not camera video). Deciding factors: **hardware support on Apple** + the peculiarities of screen content.

## TL;DR

**Default (GUI video-path): HEVC Main 8-bit 4:2:0 + constant-quality (Quality≈0.6, Apple Silicon), no B-frames.** 10-bit = optional; low-latency RC = optional/uncertain (`AllowFrameReordering=false` is already enough). H.264 fallback. **4:4:4 dropped** (Apple HW does not encode it; crisp text already goes over the PTY path). AV1/VVC have no HW encode → ruled out.

Two things to remember:
1. The assumption "low-latency mode is H.264-only" is **WRONG on Apple Silicon** — HEVC works too → there is no longer a latency reason to pick H.264.
2. The real quality ceiling for text is **chroma 4:2:0** (Apple HW has no 4:4:4), not the H.264-vs-HEVC choice.

---

## 1. H.264 vs HEVC for screen content

| Criterion | Result |
|----------|---------|
| **Bitrate** | HEVC reaches equivalent text sharpness at **~60–70% of the bitrate** of H.264. Larger blocks (64×64) compress flat regions better; 35 intra modes (vs 9) track sharp UI edges better |
| **Text legibility** | HEVC: intra prediction + SAO filter → less ringing around glyphs |
| **Latency/frame (Apple Silicon)** | The difference is **negligible** — both run on the Media Engine. "HEVC is slow" is a multi-vendor PC hardware story (Parsec's caveat), and does not apply to Apple |
| **Low-latency rate control** | ✅ **Both on Apple Silicon** (Intel Mac: H.264 only) |

### Correcting an important assumption

Apple's WWDC21 said "low-latency mode is H.264-only" — **outdated**. Evidence: FFmpeg `videotoolboxenc.c` gates conditionally:

```c
if ((flags & AV_CODEC_FLAG_LOW_DELAY) &&
    (codec_id == AV_CODEC_ID_H264 ||
     (TARGET_CPU_ARM64 && codec_id == AV_CODEC_ID_HEVC))) {
    EnableLowLatencyRateControl = true;
}
```

Upstream commit: "enabled only for H.264 on Intel Macs, but can be used with both H.264 and HEVC on Apple Silicon." → **Feature-detect at runtime** (Apple has not pinned a version in the official docs).

---

## 2. Chroma 4:2:0 — the real quality ceiling for text

This matters **more** than the H.264-vs-HEVC choice:

- **4:2:0 blurs colored text**: red text on a black background, syntax-highlighted code → color fringing/bleeding. Parsec: "4:2:0 falls apart on UI/text that relies on RGB subpixel rendering."
- **Apple HW encode has NO 4:4:4** — both H.264 and HEVC via VideoToolbox are 4:2:0 (HEVC adds 10-bit; 4:2:2 only exists for ProRes-style paths, not Main 4:4:4 streaming). **Switching codecs cannot fix this.**
- Parsec/Moonlight both treat **4:4:4 as the #1 lever** for UI sharpness, and can only enable it thanks to Intel/Nvidia 4:4:4 HW encode — **which Apple does not have**.

### Levers available on Apple (in priority order)

1. **HEVC 10-bit (Main 10):** reduces banding in gradients/flat regions — **optional** (default 8-bit; only enable if needed).
2. **Higher capture resolution** (full retina scale): each glyph gets more chroma pixels → 4:2:0 hurts less.

---

## 3. The "better" codecs — why they were ruled out

| Codec | Encode on Apple | Decode | Conclusion |
|-------|-------------------|--------|----------|
| **AV1** | ❌ **No HW encode on any chip** (including M5 Max, 2026). Apple's newsroom lists AV1 only under "decode" | ✅ A17 Pro, M3+ | Software AV1 encode destroys latency/battery/thermals → **ruled out for the host**. Decode is not needed (we do not receive third-party AV1 streams) |
| **VVC/H.266** | ❌ Nothing | ❌ | No `kCMVideoCodecType`, no HW. Apple is betting on AV1 (royalty-free) instead of VVC → **ruled out** |
| **ProRes** | ✅ Mac M1 Pro/Max, M3+ (base M3/M4 have 1 engine) | ✅ widespread | Intra-only → extremely low latency, robust against packet loss. **But bitrate is tens–hundreds of Mbps** → see §4 |

> ⚠️ One aggregator blog claims "M5 Pro/Max add AV1 hardware encode" — **WRONG**, contradicting Apple's newsroom (3/2026) and Wikipedia (both list AV1 = decode-only). Trust Apple.

---

## 4. ProRes — when does it make sense?

- **Fits:** a **wired multi-Gbps** LAN (e.g. 10GbE) + a Mac host with a ProRes encode engine, needing **visually-lossless quality** + minimal encode latency (intra-only). Use case: production review, color-critical work.
- **Does not fit (as default):** ProRes Proxy/LT is still 10–50× the bitrate of low-latency HEVC. On Wi-Fi / 1GbE → link saturation → latency **increases** via network buffering.
- **Conclusion:** opt-in "high-quality wired mode", gated on (a) host having a ProRes engine, (b) a multi-Gbps link. Default remains HEVC.

---

## 5. What real-world streamers use (and why)

| Streamer | Codec | Notes |
|----------|-------|---------|
| **Parsec** | Default H.264, has H.265 + AV1; "Prefer 4:4:4" in the paid tier | H.264-for-latency is a **cross-vendor PC** conclusion, NOT applicable to Apple-only |
| **Moonlight/Sunshine** | H.264, HEVC, AV1; added **YUV 4:4:4** (2024) for text — prefer **HEVC 4:4:4** because "AV1 4:4:4 hardware is zero" | A PC-ecosystem story; Apple is the opposite: it has 4:4:4 decode but no encode |
| **NVIDIA GameStream/GFN** | H.264 → HEVC → AV1 (Ada) | Game content, not text-first |
| **Steam Remote Play** | H.264 default, HEVC where supported | Maximizes device reach |

**Pattern:** everyone serving **text/desktop** content **wants 4:4:4** and picks **HEVC** as the first attainable rung. Their H.264 defaults are driven by **multi-vendor hardware ubiquity** — a constraint **we don't have** (Apple-only).

---

## 6. Bitrate ballpark — 4K, mostly-text, ~30fps cap, LAN

Screen content is bursty: near zero when static, large spikes on full-screen redraw/scroll. **Budget for the spike, not the average.** A LAN is not bandwidth-constrained → bias high for crisp text.

| Codec (VideoToolbox, 4:2:0) | "Visually clean" cap | Comfortable LAN setting |
|-----------------------------|----------------------|----------------------|
| **H.264** | ~50–80 Mbps | 60 Mbps |
| **HEVC (8/10-bit)** | ~30–50 Mbps | 40 Mbps |

Rule of thumb: **HEVC gives equivalent text sharpness at ~60–70% of the H.264 bitrate.** On gigabit LAN: set a generous cap (HEVC 40–50, H.264 60–80 Mbps), long GOP + force IDR on detected scene change, and let the rate controller spike on full-screen changes. The average will be far below the cap because the screen is mostly static.

---

## 7. Final decision + remaining work

**Default:** HEVC Main **8-bit** 4:2:0 + **constant-quality** (`Quality≈0.6`, Apple Silicon); 10-bit optional; `EnableLowLatencyRateControl` optional/feature-detect; `RealTime=true`, `AllowFrameReordering=false`, `AllowOpenGOP=false`, `MaxFrameDelayCount=0`, long GOP + force IDR/LTR. (4:4:4 dropped — text goes over the PTY path.)

**Fall back to H.264 when:** old / non-Apple clients / weak browser decode; the host is an **Intel Mac** (low-latency is H.264-only); maximum compatibility is required.

**ProRes:** opt-in wired-high-quality, gated on host + bandwidth.

### Tasks for Phase 0
- [ ] Probe `EnableLowLatencyRateControl` with HEVC on the target machine (`VTCopySupportedPropertyDictionaryForEncoder` / try creating a session) — confirm it works.
- [ ] Try HEVC 8-bit vs **10-bit** on colored text → evaluate real-world fringing.
- [ ] Measure encode latency H.264 vs HEVC on the same machine (confirm the difference is small).
- [ ] Test 4:2:0 capture at high resolution to see whether text is acceptable (before even considering software 4:4:4).
