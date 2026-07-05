# 18 — Risk resolutions: how each risk is solved + spike plan

> **STATUS: CURRENT.** Every open risk/spike was researched to a concrete solution (19 agents, ~1.62M tokens), attacked by a skeptic, and verified back to primary sources. Corpus: [research/18-risk-resolutions.json](research/18-risk-resolutions.json).
>
> **0 blockers.** 9 risks → **SOLVED** (code pattern verified) / **MEASURED** (real M1 Max numbers, §0) / **BOUNDED** (remaining spike + decision rule + fallback). 2 risks **dissolved by scope** (A, I). Both paths shipped: PATH 1 (terminal) and PATH 2 (GUI per-window) are co-equal pane kinds.

## 0. Phase 0 — de-risk gate (resolve every risk BEFORE building production)

> **Principle (methodology fix):** never park an architecture-killing unknown in a later phase — if it breaks in Phase 4, Phases 1–3 are wasted. **Phase 0 runs EVERY architecture-defining spike first; build production only when they pass.** Phase 0 is cheap (small harnesses, no full pipeline).

Most of Phase 0 ran on this machine (Apple M1 Max · macOS 26.5 · arm64 — the target host class, including the macOS 26 watch item). Harness + raw numbers: [research/spikes/vtbench/](research/spikes/vtbench/RESULTS.md).

> **Measured on 2 real machines on the same WireGuard mesh:** HOST = M1 Max, CLIENT = M2 Pro (both macOS 26.5). ⚠️ HW encode **hangs over SSH** → run from Terminal.app GUI.

| Spike | Status | Measurement | Gate |
|-------|-----------|-------|------|
| **Network RTT (WireGuard-mesh P2P)** | ✅ **MEASURED** | **avg 11.1ms** (min 8.5/max 14.5), **0% loss**, **direct P2P over the internet** (NAT hole-punch, not same-LAN) | baseline for all latency ✓ |
| **F** decode latency | ✅ **MEASURED — PASS (host+client)** | host M1 Max **p99 1.1ms**; **client M2 Pro p99 0.92ms** — synchronous HW, NO 2-frame buffer | p99 < 1 frame ✓ |
| **G** concurrent encoders | ✅ **MEASURED (2 machines)** | 32 sessions/host; **~6 1080p@30fps windows / encode engine** (M2 Pro 1 engine→~6 @184fps; M1 Max 2 engines→~8–10 @340fps). The "2–4" research was WRONG. Client only decodes → fine | enough windows ✓ |
| **E** live encoder | ✅ **MEASURED** | low-latency-RC **7.5ms** vs constant-quality **24ms** (3× slower) → **live MUST use low-latency-RC** | encode < frame ✓ |
| **E** Session-B lossless | ✅ **MEASURED** | `Lossless` key **not supported** (-12900) → use `Quality=1.0`+`AllowTemporalCompression=false` (all-intra) | — |
| macOS 26 multi-NALU | ✅ **MEASURED — downgraded** | **1 NALU/CMSampleBuffer** (incl. IDR) in single-slice config → not a corruption risk | still worth iterating NALUs |
| **D** cursor strip | ✅ **MEASURED — PASS** | client M2 Pro: per-window capture twice, `showsCursor=false` strips cleanly (diff = 120px = the cursor, present at true/absent at false) | 0 cursor pixels ✓ |
| **C** libghostty threading | ✅ SOLVED (source) | main-thread contract (read from VVTerm) — no hardware needed | — |
| **H** iOS reconnect | ✅ SOLVED (source) | ET BackedWriter/Reader pattern — no hardware needed | — |
| PATH 1 echo latency | ✅ **MEASURED** | app-level TCP single-byte round-trip over the mesh: **p50 9.2ms · p99 17.8ms** (max 139ms, 1 outlier). Feels local; **confirms NO Mosh predictor needed** | echo < ~50ms ✓ |

→ **Phase 0 COMPLETE — 0 unknowns.** All measured on 2 real machines (host M1 Max, client M2 Pro, macOS 26.5, P2P internet): network 11ms · PATH 1 echo 9.2ms · decode 0.9–1.1ms · encode 7ms · concurrency ~6/engine · NALU=1 · **cursor-strip PASS**. Predictor not needed. **No architecture-defining risk open. PATH 1 + PATH 2 both shipped (co-equal pane kinds).**

## Summary table

| Risk | Verdict | Solution (1 line) |
|------|---------|--------------------|
| **A** input into background windows | ✅ **Dissolved (scope)** | Decided **activate-then-control, 1 window at a time, must focus** → focus target → frontmost → universal `CGEventPost`. **Avoids the SkyLight private API + the Chromium background failure + macOS 26 fragility.** |
| **B** coordinate mapping | ✅ SOLVED | `kCGWindowBounds` (CG top-left)→normalize→`CGEvent.postToPid`; fix multi-monitor by flipping to Cocoa space before `NSScreen.intersection`; window-move = AX `kAXWindowMovedNotification` (fires at END) + poll `CGWindowListCopyWindowInfo` during drags |
| **C** libghostty threading | ✅ SOLVED | feed_data/refresh/draw **main thread only**; TCP-rx bg thread → `await MainActor.run`; CVDisplayLink cb (bg) → `DispatchQueue.main.async` before touching view state |
| **D** cursor strip | 🔬 BOUNDED (low) | `showsCursor=false`+`showsMouseClicks=false` — confirmed clean in OBS/Ensemble + SDK has no cursor key; 1 harness run (TCC) confirms |
| **E** rate-control vs quality | ✅ **MEASURED+SOLVED** | **2 sessions**: A live **low-latency-RC** (7.5ms; constant-quality 24ms too slow) + 12Mbps bitrate cap · B on-demand `Quality=1.0`+`AllowTemporalCompression=false` (no `Lossless` key) |
| **F** decode latency | ✅ **MEASURED — PASS** | p99 **1.1ms** HW synchronous, NO 2-frame buffer; render via `CVMetalTextureCache`+`CAMetalLayer` (NOT `AVSampleBufferDisplayLayer`) |
| **G** concurrent encoders | ✅ **MEASURED** | 32 sessions/host; ~**8–10 1080p@30fps windows** concurrently (throughput ~340fps); gate with `RequireHardwareAcceleratedVideoEncoder=true` |
| **H** iOS reconnect | ✅ SOLVED | ET-style `BackedWriter/BackedReader` seq-numbered replay buffer (64MB cap, 4MB offline gate) over plain TCP, **NO CryptoHandler**; UIKit `didEnterBackground`+`beginBackgroundTask` |
| **I** PTY = RCE / auth | ✅ **Dissolved (scope)** | Decided **plain, no auth** (personal use, inside the mesh) → boundary = WireGuard-mesh membership + ACL. Accepted residual risk |

---

## PATH 1 risks (shipped; no hardware needed to resolve)

### C — libghostty threading (SOLVED)
- `ghostty_surface_feed_data` / `_refresh` / `_draw` **must run on the main thread** (confirmed via VVTerm source). Swift's `@MainActor` does **not** propagate to C symbols — ensure the call site is on main yourself.
- **TCP receive loop** runs on a bg thread → before feeding: `await MainActor.run { terminal.feedData(data) }`.
- **CVDisplayLink callback** fires on a bg thread → `DispatchQueue.main.async` before touching view state.
- `ghostty_surface_draw` acquires `draw_mutex` (serialized with the renderer's CVDisplayLink `drawFrame(false)`) → no hard crash if a thread slips, but keep the main-thread contract.
- ⚠️ Trap: **actor-suspension escape** — after an `await` inside a `@MainActor` func, hopping executors loses isolation; keep the feed→refresh→draw chain unsuspended.

### H — iOS byte-exact reconnect (SOLVED)
- Terminal namespace implements an **Eternal-Terminal-style `BackedWriter`/`BackedReader`** seq-numbered replay buffer over plain TCP: ring `MAX_BACKUP=64MB`, **4MB offline gate** — `BUFFERED_ONLY`=keep buffering, `SKIPPED`=pause the PTY drain (don't let a long build while offline overflow it → lost output).
- ⚠️ **No `CryptoHandler`** (ET's libsodium secretbox + nonce): plain over the WireGuard mesh → buffer stores **raw bytes**. Noted so a future contributor doesn't add a nonce-resetting crypto layer.
- Use **int64/varint** for the wire sequence number (ET proto2 uses int32 — truncation on ultra-long sessions).
- Lifecycle: **UIKit `didEnterBackground`** (NOT SwiftUI `scenePhase`) + `beginBackgroundTask` to pause the PTY drain; reconnect creates a new `NWConnection` after `.failed`, with a pending receive to detect dead sockets. Handshake: **the server decides `RETURNING_CLIENT`** (verified `Connection.cpp:96-141`).

### I — security (Dissolved by decision: plain, no-auth)
- Decision: **no app-layer auth**, plain to reduce latency, personal use on a trusted private network (WireGuard mesh — NetBird/Tailscale). Boundary = mesh membership + ACL.
- A solution exists if ever needed (Ed25519 per-client allowlist + one-time HMAC pairing, socket bound to the mesh IP via `NWParameters.requiredLocalEndpoint`) — **shelved**, not v1. (If built: `Curve25519.Signing.PrivateKey()`, `isValidSignature` returns Bool and does **not** `try`, Ed25519 does **not** go into the Secure Enclave — SE is P-256 only.)
- **Accepted residual risk:** a PTY accepting bytes = RCE bounded by the mesh; a compromised mesh peer → host exposed. OK for personal use.

---

## PATH 2 risks (shipped; all architecture-defining spikes resolved)

### A — input injection (Dissolved by decision: activate-then-control)
- Decision: **control 1 window at a time, must focus.** → raise + focus the target (public API: `NSRunningApplication(...).activate` + AX `kAXRaiseAction` / set `kAXFocusedWindow`), it becomes **frontmost**, then `CGEventPost(kCGHIDEventTap)` or `postToPid`. Tag `eventSourceUserData` to filter self-injection.
- **Why this beats background injection:** research found a background route via the **SkyLight private API** (cua-driver/yabai `SLPSPostEventRecordTo`+`SLEventPostToPid`) — BUT it (1) uses **private symbols** (fragile, dlopen/dlsym), (2) **fails with Chromium/Electron on macOS 14** (keyboard dropped in background), (3) is **unverified on macOS 26 Tahoe**. Activate-then-control uses **public APIs**, works **universally for every app** (including Metal/OpenGL viewports the background route can't handle), and avoids all 3. → **SPIKE 1 (heaviest) deleted.**
- 📏 **MEASURED 2026-06-12 (cua-driver, live on macOS 26.5.1 Tahoe / M1 Max).** Drove three real targets while each stayed backgrounded; `NSWorkspace.frontmostApplication` stayed on the terminal throughout (focus-without-raise mechanically works on Tahoe):
  - **AppKit mouse — PASS.** Clicked a backgrounded Calculator (below the active app) to compute `6×7=42`; never raised, focus never moved.
  - **AppKit text — PASS.** Inserted a marker into a TextEdit window with `is_on_screen=false` via AX `kAXSelectedText`; `AXFrontmost=false` throughout.
  - **Chromium keyboard — FAIL.** Typed into a backgrounded Chrome `<input autofocus>` (self-reporting page mirroring the value into `document.title`) via both the CGEvent character-synthesis fallback **and** the `press_key` NSMenu front-flip path — **neither landed** (title stayed `EMPTY`). Renderer drops background keyboard even on macOS 15+/Tahoe via these paths.
  - **Menu shortcut — FAIL.** `⌘Z` into a backgrounded window did not apply via either path.
  - **Verdict:** focus-without-raise is real but **AppKit-only** in practice; **Chromium/Electron keyboard is unreliable backgrounded**. Since the workflow is **VS Code + Chrome** (both Electron/Chromium), the background route would be flaky on the most-used apps. → **USER DECISION confirmed: activate-then-focus for stability.** Background injection is a multi-window / never-steal-focus play, **not a latency win** (the raise is already async/off the inject path — see [11 §input-to-photon]).

### B — coordinate mapping (SOLVED)
Pipeline: client pixel → normalize → host window point → `CGEvent.postToPid`. Three mandatory fixes:
1. **TCC**: `postToPid` needs the **"Post Event"** permission (not just Accessibility) — check separately.
2. **Multi-monitor backingScale flip** (secondary-display bug): `kCGWindowBounds` is CG top-left, `NSScreen.frame` is Cocoa bottom-left → **flip `cocoaY = primaryHeight − y − h`** before `NSScreen.frame.intersection` to get the correct `backingScaleFactor`.
3. **Window-move sync**: AX `kAXWindowMovedNotification` fires only **when the move ends** → during the drag, **poll `CGWindowListCopyWindowInfo`** per frame so the client `NSWindow` doesn't drift. (`SCContentFilter(desktopIndependentWindow:)` captures at origin (0,0) → in-window coordinates are canonical.)

### D — cursor strip (MEASURED — PASS, client M2 Pro)
- 📏 **Measured:** the `cursor-strip.swift` harness (`SCScreenshotManager` + `SCContentFilter(desktopIndependentWindow:)`) captures 1 real app window twice with the pointer warped to center: `showsCursor=true` vs `false`. **diff = 120px (0.006%)** = exactly the cursor → **`showsCursor=false` cleanly strips the cursor from per-window capture.**
- `config.showsCursor = false` (+ `showsMouseClicks = false`). Matches OBS/Ensemble evidence + `SCStreamFrameInfo` has no cursor key.
- ⚠️ Gotchas hit while measuring: (1) a CLI must init `NSApplication.shared`+`setActivationPolicy(.accessory)` or it asserts `CGS_REQUIRE_INIT`; (2) filter `windowLayer==0`+`owningApplication` or you hit the "Backstop" (wallpaper) window; (3) needs TCC Screen Recording → run from a GUI, not SSH.
- ⚠️ **Off-screen starvation** (still true): `showsCursor=false` + an off-screen window → SCK stops delivering frames (only on mouse-move). The primary use-case (a focused window) → unaffected.

### E — rate-control vs quality (MEASURED + SOLVED — **updates [17 §3.4]**)
Resolves the low-latency-RC-vs-constant-quality conflict with **2 VTCompressionSessions**. Measurement settles which live frames use:
- **Session A (live stream) = low-latency-RC** (NOT constant-quality): `EnableLowLatencyRateControl=true` (Spec key) + `AverageBitRate` (SInt32) + `DataRateLimits=[12_000_000/8, 1.0]` (= 1.5MB/1s = **12Mbps hard cap**; **it's /8, not /4**) + `SpatialAdaptiveQPLevel=Disable` (SDK-required under low-latency, macOS 15+, wrap in availability). **Omit `ProfileLevel`**.
  - 📏 low-latency-RC encodes at **p50 7.5ms**; constant-quality 0.65 at **p50 24ms** (3× slower, near the 33ms budget). → live frames **must** use low-latency-RC. (Fixes the old "encode at Quality 0.65 and send immediately".)
  - 📏 Querying `UsingHardwareAcceleratedVideoEncoder` under low-latency = **-12900** (don't query in this mode).
- **Session B (on-demand crisp):** `Quality=1.0` + `AllowTemporalCompression=false` (all-intra) — encodes the dirty-rect union when the window is idle.
  - 📏 Both accepted; **the `Lossless` property key is NOT supported (-12900)** → no lossless HEVC key, use `Quality=1.0` all-intra (note: 4:2:0 at `Quality=1.0` still subsamples chroma — max crispness, not true lossless).
- ⚠️ Dropped the "Sidecar uses ..." claim (no primary source).

### F — decode latency (MEASURED — PASS)
- 📏 **Measured on M1 Max / macOS 26.5:** `VTDecompressionSession` with `decodeFlags=[]` (synchronous), 1080p HEVC, HW: **p50 0.73ms, p99 1.12ms, max 3.15ms**. → **single-frame, NO 2-frame buffer** (the scariest unknown resolved). ≪ the 33ms budget.
- Decode: feed the `CVPixelBuffer` → Metal via `CVMetalTextureCacheCreateTextureFromImage` + `CAMetalLayer` — **NOT `AVSampleBufferDisplayLayer`** (adds ≥1 frame of buffering, Moonlight #1885).
- Version-gate `RequireHardwareAcceleratedVideoDecoder` behind `@available(iOS 17)`; on iOS ≤16, HW HEVC decode is default on A-series. iOS background-suspend hangs → invalidate the session asynchronously.
- **Remaining (iOS/iPadOS client):** re-measure p99 on a real A-series client + add `nextDrawable`+vsync for full motion-to-photon. Decode component proven ~1ms → motion-to-photon dominated by display pacing (well understood, [17 §3.7]). PASS rule stays p99 < 1 frame.

### G — concurrent encoders (MEASURED on 2 machines — non-issue)
- 📏 **Measured:** session-creation ceiling = **32** on both machines (33rd fails -12903). Sustained throughput (back-to-back encode, low-latency-RC, 1080p):
  - **M1 Max (2 engines): ~340fps → ~8–10 windows @30fps.**
  - **M2 Pro (1 engine): ~184fps → ~6 windows @30fps** (K=6 = 31fps/stream edge; K=8 breaks).
- 📏 **Rule: ~6 live 1080p30 windows / video-encode engine** (1-engine base/Pro→~6, Max→~10, Ultra→~20). Throughput ∝ engine count.
- ⚠️ **The "2–4 concurrent" research was WRONG** — it confused *engine throughput* with *session count*. For a coding tool (1–3 windows) → **non-issue on every chip**. A machine in **client role only decodes** (~0.9ms) → encode throughput only matters as **host**.
- Still gate every encoder with `RequireHardwareAcceleratedVideoEncoder=true` (fail-fast under overload). Query `UsingHardwareAcceleratedVideoEncoder` **exactly once** at creation (polling = `mediaserverd` crash; -12900 under low-latency). Recreate on resize. Warm-up + 50–100ms retry for the **-12905** (XPC) race.

---

## Non-blocking watch items

- ✅ **macOS 26 multi-NALU — MEASURED, downgraded:** on macOS 26.5 M1 Max, HEVC emits **1 NALU/CMSampleBuffer** (incl. IDR; param sets in the format desc). Not a corruption risk in single-slice config. **Still iterate length-prefixed NALUs** (standard AVCC, ~0 cost) for safety.
- ✅ **macOS 26 Tahoe per-window background input — MEASURED 2026-06-12** (cua-driver, M1 Max / 26.5.1): focus-without-raise works, but **AppKit-only**; Chromium/Electron keyboard does **not** land backgrounded. **Moot** — we use activate-then-control. Full results in §A.
- ✅ **Chromium/Electron backgrounded keyboard drops — CONFIRMED still true on Tahoe** (not just macOS 14): backgrounded Chrome `<input>` received nothing via CGEvent or NSMenu front-flip. **Moot** (focus before typing).

---

## Spike plan — ALL EXECUTED (see §0)

> All Phase-0 spikes measured (§0). Reproducible harness: [research/spikes/vtbench/](research/spikes/vtbench/RESULTS.md).

What remains are **implementation spikes** (not architecture de-risking), done while building:
- libghostty: alt-screen e2e, iOS XCFramework binary size, shell-integration OSC.
- (iOS client) re-measure decode+vsync on an A-series iPhone/iPad when available (decode already PASSED on M-series; just confirming A-series).
- app-level echo measured macOS↔macOS; re-measure on the iOS client once the app exists.

> **PATH 1 + PATH 2: 0 gating spikes left — both paths shipped.**

---

## Sources
Full corpus (9 risks × solve+verify + synthesis, primary-source verified): **[research/18-risk-resolutions.json](research/18-risk-resolutions.json)**. Anchors: trycua/cua-driver + yabai (SkyLight, *shelved*); Eternal Terminal `BackedWriter/BackedReader/Connection`; VVTerm/Geistty (libghostty threading); OBS `mac-sck-video-capture.m`; Moonlight (decode pacing); FFmpeg `videotoolboxenc.c`; iOS/macOS 26.5 SDK headers (VideoToolbox/ScreenCaptureKit); Apple forum threads (cursor starvation 720228, socket reclaim TN2277).
