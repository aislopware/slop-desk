# Remote-window performance: where the milliseconds go (M1 Max, network removed)

**Date:** 2026-07-04 · **Machine:** Mac Studio, Apple M1 Max, 1920×1080@60 display ·
**Instrument:** `slopdesk-perfbench` (headless — real `VideoEncoder` + `VideoDecoder` + packetizer/FEC
on synthetic scrolling NV12; no SCStream, so it runs from any shell — capture is the only GUI/TCC-gated
stage). Reproduce: `swift run -c release slopdesk-perfbench`.

## TL;DR

**HEVC encode is the entire processing cost, scaling ~linearly with pixel count.** Decode (~1.3 ms),
packetize + Reed–Solomon FEC (~0.05 ms) and the pacer are noise. So "remote window feels bad" is
governed by **capture resolution (= encode time)** and the **rate-control budget (= motion blur)** —
not the wire path.

## Encode timing vs resolution (motion = full vertical scroll, the worst case)

| Capture size (px) | ~pixels | encode p50 / p99 | fits 60 fps (16.7 ms)? | fits 30 fps (33 ms)? | max sustained fps |
|---|---|---|---|---|---|
| 1920×1080 (scale 1.0)  | 2.1 M | 8.9 / 11.7 ms | **yes** (1/120 over) | yes | ~132 |
| 2400×1350 (scale 1.25) | 3.2 M | 13.1 / 18.5 ms | **yes** (5/120 over) | yes | ~92 |
| 2880×1620 (scale 1.5)  | 4.7 M | 17.3 / 19.6 ms | **no** (77/120 over) | yes | ~68 |
| 2816×1778 (VD-2× win)  | 5.0 M | 17.6 / 20.8 ms | **no** (95/120 over) | yes | ~65 |
| 3840×2160 (VD-2× full) | 8.3 M | 23.4 / 26.0 ms | **no** (120/120 over) | marginal (~8 ms slack) | ~42 |

**60 fps encode wall on M1 Max HEVC low-latency ≈ 2400×1350 (capture scale 1.25).** Larger overruns
the 16.7 ms budget → VideoToolbox drops frames → "giật" (stutter). The default virtual display captures
at **2× → 3840×2160 → 23 ms/frame → can't do 60 fps, marginal at 30 fps** (24 ms synchronous encode on
a 60 Hz capture queue leaves ~8 ms slack, so a heavier frame stalls the next capture = periodic hitch).

## `SPEED_OVER_QUALITY` buys nothing here

`SLOPDESK_SPEED_OVER_QUALITY=1` (set by shipped profiles) measured **~9 ms either way at 1080p** — on
M1 Max the low-latency HEVC block is already at its throughput floor, so the hint doesn't shorten
encode; it only tilts rate-distortion toward coarser quantization = **free sharpness loss.** Turn it OFF.

## Blur = rate-control QP starvation

At the resolution-aware budget (`LiveBitratePolicy`, bpp 0.15), motion frames come out **2.0–2.6×
coarser** than a 150 Mbps near-lossless reference of the same content = the "nhoè" during scroll. Set
explicitly by `AQP_MAX` (44 = very coarse). A good link has headroom to lower it (less motion blur) —
see the recommended profile.

## The `AQP_MAX` motion-blur tradeoff (measured, fixed-QP, 1080p60)

Pinning const-QP to a fixed value + measuring scroll-frame size shows how much detail each QP throws
away, and how cheap sharper motion is on a good link:

| QP (motion ceiling) | avg frame | at 60 fps | verdict |
|---|---|---|---|
| 24 (sharp floor)     | 72.9 KB | ~35 Mbps | crisp (this is the *static* floor) |
| 30                   | 51.3 KB | ~25 Mbps | |
| **36 (recommended)** | 29.8 KB | ~14 Mbps | **3.5× more detail than QP44 — sharp motion, trivial bandwidth** |
| 44 (current profile) | **8.5 KB** | ~4 Mbps | heavily quantized = the motion blur |

`AQP_MAX=44` crushes each scroll frame to 8.5 KB; on a fat LAN there's no reason to. `AQP_MAX=36` keeps
3.5× the detail for ~14 Mbps at 60 fps, which link and encoder both absorb easily.

## Decode + FEC are not bottlenecks

`decode p50 1.26 ms / p95 1.50 ms`; `packetize+FEC m=1 p50 0.02 ms, m=2 p50 0.06 ms`. No work needed on
client decode or the wire path for latency.

## What this means for the two symptoms

- **giật (stutter):** encode budget overrun. Either (a) plain default launched (virtual display 2× →
  4K → 23 ms → can't hold 30/60 fps), or (b) `SCROLL_FPS=40` decimates a 60 fps stream the encoder can
  sustain at scale ≤1.25 (choppier for no reason).
- **nhoè (blur):** low capture resolution (scale 1.0 supersampled 1×), `SPEED_OVER_QUALITY=1`, and a
  coarse motion ceiling (`AQP_MAX=44`) — all three give up sharpness the hardware doesn't need to.

## Recommended settings (see `.work/profiles/host-lan-optimized.command`)

| Knob | Old (host-lan) | New | Why (measured) |
|---|---|---|---|
| `--fps` | 60 | 60 | encoder sustains it at scale ≤1.25 |
| `SCROLL_FPS` | 40 | **0** | full 60 fps scroll — encode fits the budget, so don't decimate |
| `SPEED_OVER_QUALITY` | 1 | **removed** | 0 ms benefit, pure sharpness loss |
| `CAPTURE_SCALE` | 1.0 | **1.25** | 2400×1350 = 13 ms (still fits 60 fps) and ~56 % more pixels = sharper text |
| `AQP_MAX` | 44 | **36** | less motion blur; link is fat, encode has headroom |
| `CONST_QP` / `AQP_SHARP` | 24 | 24 | keep the crisp static floor |

**Plain `videohostd` (no profile) — what's running now — gets none of the above:** virtual display 2×
(4K encode = stutter), no const-QP (VBR clawback = blur), 30 fps. Launch a profile instead. Plainest
fix for a naive launch: lower the default capture scale off 2× (a code change worth landing +
HW-verifying: bias `resolveCaptureScaleOverride`'s default toward the 60 fps-sustainable ~1.25× instead
of the VD's full 2×).
