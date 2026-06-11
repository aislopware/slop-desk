# 08 — Risks & Open Questions

> **STATUS: SUPERSEDED** — replaced; see [00-overview.md](00-overview.md) · [DECISIONS.md](DECISIONS.md).

## 1. Technical risks (ranked by severity)

> ⚠️ **R1/R2 (input injection) ONLY apply to the GUI video-path.** The terminal goes over the PTY text-path and avoids them entirely (input = bytes → PTY stdin) — see [12](12-coding-profile.md). For the coding profile (terminal-first), R1/R2 are no longer project-blocking risks.

### 🔴 R1 — Window-targeted input is imperfect on macOS *(GUI path only)*
- **Problem:** no reliable mouse injection into background windows; no API to map `AXUIElement`↔`CGWindowID`; window matching is a heuristic.
- **Impact:** clicks may land in the wrong window; matching can go wrong when multiple windows share a title.
- **Mitigation:** activate-then-control + prefer AX actions; verify in Phase 0.4–0.5. Code defensively when matching.
- **Fallback if it fails:** fall back to controlling the **whole app** (raise the app, don't try to raise one specific window), or control the **entire desktop** as a secondary mode.

### 🔴 R2 — macOS 14+ cooperative activation refuses activation from network events
- **Problem:** `activate()` is advisory and often fails when triggered by network/timer — exactly the remote-control case.
- **Mitigation:** combine `AXRaise` (reorders windows even when app activation is throttled) + try `activateIgnoringOtherApps:` (deprecated but stronger).
- **Needed:** **measure in practice in Phase 0.6** on the exact macOS versions to be shipped (14/15/26).

### 🟡 R3 — High/bursty Wi-Fi latency
- **Problem:** bursty Wi-Fi loss + jitter break the 30–50ms target.
- **Mitigation:** plain UDP over NetBird (QUIC dropped — WireGuard already encrypts, [13]); FEC considered only when relayed. **(GUI video-path only, Phase 4.)**

### 🟡 R4 — Keyboard layout / dead keys
- **Problem:** keycodes depend on the host layout; dead keys (´+e→é) are hard.
- **Mitigation:** send text via **Unicode injection** (layout-independent); keycodes only for shortcuts. Some games ignore Unicode → keycode fallback.

### 🟡 R4b — Colored-text blur due to 4:2:0 chroma
- **Problem:** Apple HW encode has no 4:4:4 → text on colored backgrounds gets fringing/bleeding. Switching codecs doesn't fix it.
- **Mitigation:** **10-bit** HEVC + higher capture resolution. If critical → a software 4:4:4 "ultra text" tier (accepting the latency). See [09 §2](09-codec-choice.md).

### 🟢 R5 — AVSampleBufferDisplayLayer adds latency
- **Mitigation:** wrap behind a `VideoRenderer` protocol, switch to Metal when needed (Phase 4).

### 🟢 R6 — CMFormatDescription pointer-lifetime crash
- **Mitigation:** nest `withUnsafeBytes` / `withExtendedLifetime` correctly ([04 §1](04-client-decode-render.md)).

### 🟡 R7 — VideoToolbox lacks RFI-by-id & gradual intra-refresh
- **Problem:** no `NvEncInvalidateRefFrames` or periodic intra-refresh like NVENC.
- **Mitigation:** use the **LTR ack workflow** (`EnableLTR`/`ForceLTRRefresh`) — equivalent recovery, avoids keyframe spikes. Verify the symbol names on the target SDK. See [10 §1](10-latency-optimization.md).
- **Secondary risk:** if the LTR symbols/behavior don't match the WWDC21 description → fall back to FEC + IDR-on-loss (still works, just less smooth under packet loss).

### ⭐ Cross-cutting note (unnumbered) — Compositor/vsync tail is the biggest hidden latency on the client *(GUI path)*
- **Mitigation:** low Metal overhead + `displaySyncEnabled=false` (macOS) + present close to vsync. See [10 §9](10-latency-optimization.md).

### 🟡 R8 — VRR/Adaptive-sync requires fullscreen, conflicting with the single-window model
- **Problem:** adaptive-sync scheduling requires a fullscreen window → a windowed client gets NO VRR benefit (~3–8 ms).
- **Mitigation:** accept a fixed-rate compositor for windowed mode, OR an optional fullscreen mode on the client. See [11](11-absolute-latency.md).

### 🟢 R9 — NetBird relayed fallback (accept degraded, do NOT engineer for it)
- **Decision:** design **assuming direct P2P**; if it falls back to relay (>80ms, due to NAT hairpin/hard-NAT — even same-LAN isn't 100% guaranteed) then **only surface + warn**, do NOT build workarounds (no mosh/SSP, no adaptive/FEC). Note: NetBird ≥ v0.69.0 has UPnP/NAT-PMP/PCP (fewer relay fallbacks); Tailscale still uses the birthday-paradox trick for symmetric NAT. See [13](13-netbird-transport.md).
- **Mitigation:** connection-type badge (`netbird status` P2P/Relayed) + warn the user; only consider upgrades later if relaying turns out to be common in practice. See [13 §4](13-netbird-transport.md).

### 🟡 R10 — macOS 26 Tahoe decode/present latency regression
- **Problem:** Moonlight #1696 reports decode latency spiking (~20–80 ms) with CAMetalDisplayLink on macOS 26; disabling the Metal renderer → ~2.7 ms.
- **Mitigation:** **test on the macOS 26 target** before trusting the floor; a fallback present path may be needed.

> 📋 **Many corrections & open questions have been resolved/updated** in [11-absolute-latency.md](11-absolute-latency.md) §"Verified API claims" (14 corrections + the full Phase-0 checklist). Read before coding.

---

## 2. Open questions (to be decided)

| # | Question | Recommended default |
|---|---------|----------------------|
| Q1 | Default codec? | **HEVC Main 8-bit 4:2:0 + constant-quality** (Apple Silicon); 10-bit optional; 4:4:4 dropped; AV1/VVC have no HW encode. See [09](09-codec-choice.md) |
| Q2 | First-phase renderer? | **AVSampleBufferDisplayLayer** (fastest to pixels), Metal in Phase 4 |
| Q3 | Default transport? | **Plain UDP** (video) / **plain TCP** (terminal) over NetBird — QUIC dropped (WireGuard encrypts, [13]) |
| Q4 | Need auth/pairing? | **Should have** PIN/QR even on LAN (so not everyone on the network can take control) |
| Q5 | Audio? | Defer to Phase 4 (no per-window audio; audio is app-level) |
| Q6 | Multiple concurrent windows? | Phase 4; MVP is 1 window/session |
| Q7 | Cursor on the client? | **Settled:** exclude from video (`showsCursor=false`) + **draw client-side** from the input channel (instant feel). See [10 §7](10-latency-optimization.md) |
| Q8 | Minimum shipping macOS version? | 14+ (affects the R2 activation testing) |

---

## 3. Assumptions we rely on (verify while coding)

- `kAXPositionAttribute` (AX) == `kCGWindowBounds` (CG), both top-left/points — **true in practice but no Apple page states it verbatim**. Verify with runtime prints before trusting it for pixel-accurate clicks.
- Apple Silicon encode/decode latency ~1–8ms — **re-measure in Phase 0**.
- LAN loss ~0 is enough for low/no FEC — **measure on the real network**.
- `SCStreamFrameStatus` when minimized (`.suspended` vs. stopping emission) differs across macOS versions — reconcile with `SCWindow.isOnScreen`.

---

## 4. Non-goals (explicitly NOT doing, at least initially)

- ❌ App-level NAT traversal / custom relay — delegated to the **NetBird mesh** ([13]). Remote access goes through NetBird (direct P2P assumed; relayed = degraded).
- ❌ Windows/Linux host (macOS only).
- ❌ Mac App Store (sandbox incompatible — [06](06-permissions-distribution.md)).
- ❌ Truly controlling multiple background windows concurrently (macOS limitation — [05 §0](05-input-window-control.md)).
- ❌ Per-window audio (macOS doesn't support it).
