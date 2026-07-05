# 08 — Risks & Open Questions

> **STATUS: SUPERSEDED** — design-phase risk log; most items resolved or moot. Current decisions: [DECISIONS.md](DECISIONS.md), [00-overview.md](00-overview.md).

> **R1/R2 (input injection) apply ONLY to GUI-window panes.** Terminal panes use the PTY text-path (input = bytes → PTY stdin), avoiding them — see [12](12-coding-profile.md). Both pane kinds are co-equal and shipped; these risks are not project-blocking.

## 1. Technical risks

| # | Sev | Risk | Mitigation / status |
|---|-----|------|---------------------|
| R1 | 🔴 | *(GUI only)* No reliable input into background windows; no `AXUIElement`↔`CGWindowID` map; window match is heuristic → clicks may hit the wrong same-titled window. | activate-then-control + prefer AX actions; match defensively. Fallback: control the whole app, or the whole desktop. |
| R2 | 🔴 | *(GUI only)* Cooperative activation refuses activation from network/timer events — the remote-control case. | `AXRaise` (reorders even when app activation is throttled) + try deprecated `activateIgnoringOtherApps:`. Measure on macOS 26 target. |
| R3 | 🟡 | *(GUI only)* Bursty Wi-Fi loss/jitter breaks the 30–50 ms target. | Plain UDP on a trusted private network; video path carries FEC + adaptive bitrate / congestion control (Rust core). |
| R4 | 🟡 | Keyboard layout / dead keys (´+e→é) are host-dependent. | Layout-independent Unicode injection for text; keycodes only for shortcuts (games ignoring Unicode → keycode fallback). |
| R4b | 🟡 | 4:2:0 chroma → fringing on colored text (no HW 4:4:4; codec swap doesn't fix it). | 10-bit HEVC + higher capture res; optional SW 4:4:4 "ultra text" tier (latency cost). See [09 §2](09-codec-choice.md). |
| R5 | 🟢 | AVSampleBufferDisplayLayer adds latency. | Behind a `VideoRenderer` protocol; switch to Metal. |
| R6 | 🟢 | CMFormatDescription pointer-lifetime crash. | Nest `withUnsafeBytes` / `withExtendedLifetime` ([04 §1](04-client-decode-render.md)). |
| R7 | 🟡 | VideoToolbox lacks RFI-by-id & gradual intra-refresh. | LTR ack workflow (`EnableLTR`/`ForceLTRRefresh`) — equivalent recovery, no keyframe spikes. Fallback: FEC + IDR-on-loss. See [10 §1](10-latency-optimization.md). |
| R8 | 🟡 | VRR/adaptive-sync needs fullscreen → windowed client gets no VRR benefit (~3–8 ms). | Accept a fixed-rate compositor, or an optional fullscreen client mode. See [11](11-absolute-latency.md). |
| R9 | 🟢 | Mesh may fall back to relay (>80 ms) on hard NAT. | Design for direct P2P; if relayed, surface + warn only. Video path already has FEC + ABR for loss. See [13](13-network-transport.md). |
| R10 | 🟡 | macOS 26 decode/present latency regression (Moonlight #1696: CAMetalDisplayLink ~20–80 ms; Metal off → ~2.7 ms). | Test on macOS 26 target; a fallback present path may be needed. |

> ⭐ Compositor/vsync tail is the biggest hidden client latency (GUI): low Metal overhead + `displaySyncEnabled=false` (macOS) + present close to vsync. See [10 §9](10-latency-optimization.md).

> 📋 Many resolved in [11-absolute-latency.md](11-absolute-latency.md) §"Verified API claims" (corrections + Phase-0 checklist).

---

## 2. Open questions (resolved defaults)

| # | Question | Answer |
|---|---------|--------|
| Q1 | Default codec? | HEVC Main 8-bit 4:2:0 + constant-quality (Apple Silicon); 10-bit optional; no 4:4:4; AV1/VVC have no HW encode. See [09](09-codec-choice.md) |
| Q2 | First renderer? | AVSampleBufferDisplayLayer (fastest to pixels), Metal later |
| Q3 | Transport? | Plain UDP (video) / plain TCP (terminal), no app-layer crypto; runs over a trusted private network |
| Q4 | Auth/pairing? | None at the app layer — security boundary is the network (WireGuard mesh provides encryption + node auth + ACLs) |
| Q5 | Audio? | Deferred (audio is app-level; no per-window audio) |
| Q6 | Concurrent windows? | 1 window/session for MVP |
| Q7 | Client cursor? | Exclude from video (`showsCursor=false`) + draw client-side from the input channel (instant feel). See [10 §7](10-latency-optimization.md) |
| Q8 | Minimum macOS? | macOS 26 (build floor; affects R2 activation testing) |

---

## 3. Assumptions (verify while coding)

- `kAXPositionAttribute` (AX) == `kCGWindowBounds` (CG), both top-left/points — true in practice but no Apple page states it; verify with runtime prints before trusting for pixel-accurate clicks.
- Apple Silicon encode/decode latency ~1–8 ms — re-measure.
- LAN loss ~0 enough for low/no FEC — measure on the real network.
- `SCStreamFrameStatus` when minimized (`.suspended` vs. stopping emission) varies by macOS version — reconcile with `SCWindow.isOnScreen`.

---

## 4. Non-goals (initially)

- ❌ App-level NAT traversal / custom relay — delegated to the mesh ([13]); direct P2P assumed, relayed = degraded.
- ❌ Windows/Linux host (macOS only).
- ❌ Mac App Store (sandbox incompatible — [06](06-permissions-distribution.md)).
- ❌ Controlling multiple background windows concurrently (macOS limitation — [05 §0](05-input-window-control.md)).
- ❌ Per-window audio (macOS doesn't support it).
