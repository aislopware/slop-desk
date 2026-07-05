# VideoToolbox de-risk harness — MEASURED results

Measured on 2 real machines over a trusted WireGuard mesh (NetBird):
- **HOST: Apple M1 Max** · macOS 26.5 (25F71) · arm64 · Swift 6.3.2
- **CLIENT: Apple M2 Pro** · macOS 26.5 · arm64 (run inside Terminal.app GUI)

Both Apple Silicon + macOS 26, so numbers are load-bearing. *(Harness header hard-codes "M1 Max"; on the M2 Pro the numbers are still the M2 Pro's.)*

> ⚠️ **Run from Terminal.app GUI.** The HW encode harness **HANGS over SSH** (no window-server session). Decode-only is less session-sensitive but still run from the GUI.

## Cross-machine summary (host vs client)

| Measurement (1080p HEVC) | HOST M1 Max | CLIENT M2 Pro | Conclusion |
|---|---|---|---|
| **Decode latency** (synchronous, HW) | p99 **1.12ms** | p99 **0.92ms** | F PASS on both; client even faster |
| **Low-latency-RC encode** | p50 **7.5ms** | p50 **6.9ms** | live frame OK |
| **Constant-quality 0.65 encode** | p50 **24ms** | p50 **15.4ms** | still ~2× LL-RC → live uses LL-RC |
| **Concurrent HW sessions** | **32** | **32** | non-issue on both |
| **NALU/CMSampleBuffer** | **1** | **1** | multi-NALU watch-item downgraded (both machines) |
| **`Lossless` property key** | -12900 | -12900 | not available; use Quality=1.0 all-intra |

## Network (WireGuard mesh, host M1 Max ↔ client M2 Pro)

- **RTT: min 8.5 / avg 11.1 / max 14.5ms, 0% loss, stddev 1.7ms** (20 pings).
- **Direct P2P**: local `192.168.100.240` ↔ remote **public `116.104.177.173`** → NAT hole-punched **over the internet, NOT same-LAN**. The "5–20ms direct P2P" assumption holds under real internet conditions.
- **App-level echo round-trip** (single-byte TCP ping-pong, `TCP_NODELAY`, `echolat.py`, 280 samples): **p50 9.2ms · p99 17.8ms · min 7.5ms** (max 139ms = one stray WiFi/scheduling blip). Matches ping RTT.
- → **PATH 1 echo ≈ 9ms typical / ~18ms p99** = feels-local; **the Mosh predictor is NOT needed**. The 40–80ms GUI target has ample headroom (9 network + 7 encode + 1 decode + vsync).

Reproduce:
```
swiftc -O encode-decode-bench.swift -o b && ./b
swiftc -O concurrency-throughput.swift -o t && ./t
```

## Results

### F — HEVC decode latency (scariest unknown: "is decode 2-frame-buffered?")
- `VTDecompressionSession`, `decodeFlags=[]` (synchronous), 1080p HEVC, HW-backed.
- **p50 = 0.73ms, p99 = 1.12ms, max = 3.15ms.** → **single-frame, NOT 2-frame-buffered. PASS** (≪ 33ms frame @30fps).
- Non-issue on Apple Silicon. Remaining motion-to-photon is display pacing (CADisplayLink/Metal + one vsync), well-understood.

### G — concurrent hardware HEVC encoders (earlier "2–4" estimate was WRONG)
- **Session-creation ceiling: 32** simultaneous HW-backed HEVC sessions; 33rd fails `-12903`.
- **Sustained throughput** (each stream encodes back-to-back, low-latency-RC, 1080p):

  | K streams | agg fps | per-stream fps | encode p99 | ≥30fps/stream? |
  |-----------|---------|----------------|------------|----------------|
  | 1 | 102 | 102 | 17.8ms | YES |
  | 2 | 207 | 104 | 16.3ms | YES |
  | 4 | 331 | 83 | 24.8ms | YES |
  | 6 | 343 | 57 | 24.7ms | YES |
  | 8 | 338 | 42 | 33.2ms | YES (edge) |
  | 12 | 339 | 28 | 45.7ms | NO |

- Aggregate throughput saturates ~**340 fps** on M1 Max (**2** encode engines) → **~8–10 simultaneous 1080p30 windows**. **CLIENT M2 Pro (1 engine)** saturates ~**184 fps** → **~6 windows** (K=6 = 31fps/stream edge; K=8 = NO). Throughput scales ~linearly with engine count.
- **Real rule (measured, 2 machines): ~6 live 1080p30 windows per video-encode-engine** (1→~6, Max 2→~10, Ultra 4→~20 extrapolated). The "2–4 total" estimate conflated *engine throughput* with *session count* (creation ceiling is 32). For a coding tool (1–3 windows) this is a **non-issue on every chip**.
- A machine in the **client** role only decodes (~0.9ms); encode throughput constrains only the **host**.

### E — rate control: low-latency-RC vs constant-quality (decides the live-frame encoder)
- **Low-latency-RC HEVC** (`EnableLowLatencyRateControl`+`AverageBitRate`): encode **p50 7.5ms / p99 8.2ms**, HW.
- **Constant-quality 0.65** (`Quality` property): encode **p50 23.9ms** — ~**3× slower**, near the 33ms budget.
- → **Live frame MUST use low-latency-RC**, NOT constant-quality. (Corrects earlier "encode Quality 0.65 immediately".) Two-session design holds: **Session A = low-latency-RC live** (7.5ms), **Session B = on-demand crisp**.
- Querying `UsingHardwareAcceleratedVideoEncoder` while low-latency mode is on returns `-12900` (kVTPropertyNotSupportedErr) — don't query it in low-latency mode.

### E Session-B — "lossless" availability
- `Quality=1.0` accepted (status 0); `AllowTemporalCompression=false` accepted (status 0).
- Raw `"Lossless"` property key → `-12900` (**not supported**). → No dedicated lossless HEVC key; **Session B = `Quality=1.0` + all-intra** (`AllowTemporalCompression=false`) is the max-quality crisp path. (HEVC 4:2:0 `Quality=1.0` still subsamples chroma — true lossless not exposed.)

### macOS 26 multi-NALU watch-item — DOWNGRADED
- Steady-state P-frame: **1 NALU per CMSampleBuffer**. First IDR frame: **1 NALU** (param sets live in the format description, as normal HVCC).
- The "macOS 26 emits multiple NALUs → video corrupts" alarm does NOT reproduce in our single-slice config. **Still iterate length-prefixed NALUs defensively** (correct AVCC parsing, costs nothing), but it is not a corruption risk here.

### D — cursor strip (MEASURED — PASS, client M2 Pro)
- Harness `cursor-strip.swift` (`SCScreenshotManager.captureImage` + `SCContentFilter(desktopIndependentWindow:)`), captured a real app window (Ghostty 1800x1081) twice with cursor warped to window center: `showsCursor=true` vs `showsCursor=false`.
- **diff = 120 pixels (0.006%)** — a localized cursor-sized cluster present in TRUE, absent in FALSE. → **`showsCursor=false` cleanly strips the cursor from per-window capture. PASS.**
- Gotchas: (1) a CLI process must init `NSApplication.shared` + `setActivationPolicy(.accessory)` or CG/AppKit asserts `CGS_REQUIRE_INIT`; (2) filter windows by `windowLayer == 0` + real `owningApplication` to avoid picking the "Display … Backstop" wallpaper window; (3) needs Screen Recording TCC (run from Terminal.app GUI, not SSH).

## Error codes seen
`-12900` kVTPropertyNotSupportedErr · `-12902` kVTParameterErr · `-12903` resource/session-limit (33rd create).
