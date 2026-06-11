# DECISIONS — decision log

> One line per decision + status + link to the detailed doc. **When re-scoping: update HERE first**, then fix the related docs (prevents drift). Overview: [00-overview.md](00-overview.md).
> Status: ✅ decided · 🔬 needs a measurement spike · ⏸️ deferred · ❓ open.

## Philosophy
- ✅ **Build the BEST thing, NO fallback.** Commit to a single best choice, don't keep a plan B alive in parallel: **libghostty-only** (drop SwiftTerm), **NO B2 SDK pane**, **cap fps ~24–30** (GUI path) — good enough for the use case while cutting bandwidth/latency/CPU.
- ✅ **Phase 0 — de-risk gate BEFORE building production.** Do NOT park "could kill the architecture" unknowns in a later phase (if they break, all prior-phase work is wasted). Every architecture-defining spike runs in Phase 0; only build once it passes. **Most of Phase 0 has already been measured on M1 Max/macOS 26.5** (harness: [research/spikes/vtbench]). → [18 §0]

## Scope & architecture
- ✅ **Use-case = everyday coding** (running Claude Code), not game-streaming. → [12]
- ✅ **Hybrid 3-path:** terminal (primary) + read-only inspector (differentiator) + GUI video (Phase 4). → [00], [12], [16]
- ✅ **Terminal-first:** the terminal path is the MVP; GUI video moves to Phase 4. → [12 roadmap]

## Network / transport
- ✅ **NetBird (WireGuard mesh), assume direct P2P.** Relay = degraded fallback, only surface it + warn, do NOT engineer a workaround. → [13]
- ✅ **MEASURED (2 real machines, M1 Max ↔ M2 Pro):** RTT **avg 11ms** (8.5–14.5), 0% loss, **direct P2P OVER THE INTERNET** (NAT hole-punch, local 192.168 ↔ remote public IP, not same-LAN). The "5–20ms direct P2P" assumption is validated. → [18 §0]
- ✅ **No app-layer encryption** — WireGuard E2E + NetBird ACL (deny-by-default per-port). → [13]
- ✅ **Terminal = plain TCP** (reliable; escape sequences may split across reads → only buffering is needed, no loss-recovery). → [13], [12]
- ✅ **`TCP_NODELAY` mandatory** on every PATH 1 socket right after connect — Nagle coalescing 1-character writes can add +200ms/keystroke (high impact, one setsockopt line). → [17]
- ✅ **Dual data/control channel** (PTY bytes ‖ `TIOCSWINSZ` resize+intent) — burst output doesn't delay the resize-ack (Zellij lesson). → [17]
- ✅ **GUI video = plain UDP** — drop QUIC (TLS is redundant on top of WireGuard). → [03], [13]
- ✅ **Do NOT pin `requiredInterfaceType=.wiredEthernet`** (NetBird utun = `.other` → it would break). → [13]
- ✅ **serviceClass/DSCP has no effect through the tunnel** (WireGuard zeroes DSCP) → app-layer adaptive rate. → [13]
- ✅ **Discovery:** Bonjour is same-LAN only; over the mesh use NetBird DNS/IP. → [13]
- ✅ **A lightweight control plane is still needed** despite P2P (push notification + offline-queue): NetBird mgmt + APNs/FCM directly. → [13 §5b], [15]

## Terminal renderer (client)
- ✅ **libghostty full surface** (not vt + own renderer). → [12]
- ✅ **Own a minimal external-backend patch ourselves** (ref `daiimus/ghostty` External.zig; Lakr233 InMemorySession + build.yml as reference), build the XCFramework via Zig, pin the upstream SHA. Do NOT depend on the wiedymi fork (the weakest one). → [12]
- ✅ **Do NOT use SwiftTerm** — libghostty-only (best-only, no fallback). SwiftTerm remains only as a *citation* for the POSIX PTY pattern (forkpty/DispatchIO) in [12] Part B. → [12]
- ✅ **Route every key through `ghostty_surface_key`** (Ghostty encodes kitty/DECCKM itself); do NOT use the Lakr233 bypass path. → [12]
- ✅ **Do NOT build a full Mosh shadow-framebuffer predictor (v1).** Opaque ghostty → would force a duplicate VT parser (desync risk); the Claude Code TUI uses alt-screen → the predictor is OFF there; the benefit exists only at the shell prompt, and at NetBird's low RTT Mosh itself withholds prediction. **Glitch-window caret (cursor column)** = cheap Phase 2 option. → [17]
- ✅ **External-IO exists only in forks** (verified: NOT in upstream): `wiedymi/ghostty:custom-io` (VVTerm ships it) + `daiimus/ghostty:ios-external-backend` (Geistty ships it, has External.zig+resize+tests). The pattern is battle-tested. → [17]
- ✅ **Threading (C) = SOLVED:** feed_data/refresh/draw **main thread only**; TCP-rx bg thread → `await MainActor.run`; CVDisplayLink cb → `DispatchQueue.main.async`. Avoid actor-suspension escapes. → [18 C]
- ✅ **Echo-latency PATH 1 = MEASURED** (2 machines, NetBird P2P): round-trip p50 **9.2ms** / p99 17.8ms → feels-local, **predictor NOT needed** (confirms the decision to drop Mosh). → [18 §0]
- 🔬 Remaining spikes: alt-screen e2e, iOS XCFramework binary size, shell-integration OSC e2e. → [12], [17]

## Host PTY
- ✅ **`openpty()` + `posix_spawn(createSession=true)`** — forkpty is unsafe from Swift. → [12]
- ✅ `setBlocking(true)` clears O_NONBLOCK before spawn (Happy bug #301). → [14], [15]
- ✅ **Reconnect (H) = SOLVED — ET `BackedWriter/BackedReader`** over plain TCP (64MB cap, 4MB offline gate: BUFFERED_ONLY=continue / SKIPPED=pause-drain), do **NOT port CryptoHandler** (raw bytes over WireGuard), seq uses **int64**, the server decides RETURNING_CLIENT. UIKit `didEnterBackground`+`beginBackgroundTask`. No tmux needed. → [18 H], [17]
- ✅ **No-buffer relay + QoS `USER_INTERACTIVE`** thread PTY→TCP (don't insert a ring-buffer; NoMachine NX lesson). → [17]
- ✅ **iOS UIKit native-feel table-stakes:** key-repeat `DispatchSourceTimer` (350/50ms), separate IME-proxy `UITextView` (CJK), floating-cursor `updateFloatingCursor` (5pt→arrow), accessory bar gated on keyboard-visible. → [17]

## Claude Code integration
- ✅ **`TERM=xterm-ghostty`** (kitty keyboard + DEC2026). Accept the risk of paste bug #54700; fallback toggle `xterm-256color`. → [14]
- ✅ **Fullscreen mode** (`CLAUDE_CODE_NO_FLICKER=1`) for the remote PTY. → [14]
- ✅ **Auth = Subscription OAuth + `claude setup-token`** (1-year headless token); or reuse `~/.claude/.credentials.json`. Do **NOT** run PKCE ourselves (the `user:inference` scope quota is uncertain). `CLAUDE_CODE_ENTRYPOINT=remote_mobile`. → [14], [15]
- ✅ **External input box = A + B1.** A: shell input box + block (`COMMAND_FINISHED` callback + self-sniffing `ESC[?1049h/l`). B1: Claude Code keeps the TUI + an overlay compose-box that writes to the PTY (DelayedEnter). **A dedup ring buffer is mandatory** (compose-box + PTY both feed). → [14]
- ✅ **Do NOT do B2 (SDK pane).** TUI = the real Claude Code (skills/slash/every feature 100% native); structured view = **read-only inspector [16]** (does not drive the agent). → [14], [16]
- ✅ **Skills + custom slash commands run in the SDK** by default (settingSources loads `.claude/` by default; just set `cwd`=project root). Built-in TUI-only commands → native equivalent. → [14]
- ⏸️ **Orchestration (herdr/agent-teams) = be a client** (speak NDJSON, avoid embedding AGPL), do NOT build the product. → [14], [15]

## Inspector (read-only)
- ✅ **Read-only**, data = **tail of the JSONL transcript** (path from the SessionStart hook) + hooks (PostToolUse/SubagentStop). Second NWConnection, length-prefixed. → [16]
- ✅ **Subagent content lives in separate files** (`subagents/agent-<hash>.jsonl`) — must watch the dir + use `SubagentStop.agent_transcript_path`. → [16]
- ✅ **CoT/thinking = placeholder-only** (the Opus 4.x thinking field is empty/omitted; do NOT rely on undocumented flags). → [16]
- ⏸️ Workflow panel + agent teams inbox = deferred (research preview). → [16]

## Codec (GUI video path — Phase 4)
- ✅ **HEVC Main 8-bit 4:2:0 + constant-quality** (Quality≈0.6, Apple Silicon). 10-bit = optional. → [09]
- ✅ **4:4:4 dropped** (Apple HW cannot encode it); crisp text already goes through the PTY path. AV1/VVC have no HW encode → out. → [09]
- ✅ `AllowFrameReordering=false`, infinite GOP + on-demand IDR/LTR. ⚠️ `AllowOpenGOP=false`/`MaxFrameDelayCount=0` **not yet verified as part of the canonical SDK recipe** (kept as belt-and-suspenders). → [02], [09], [17]
- ✅ **4-flag low-latency recipe**: Specification `EnableLowLatencyRateControl` (✅ verified for HEVC on Apple Silicon) + `RequireHardwareAcceleratedVideoEncoder`, Property `RealTime`+`ExpectedFrameRate`+`PrioritizeEncodingSpeedOverQuality`. Set the Specification keys at **session creation** (not SetProperty). → [17]
- ✅ **NV12 capture zero-copy** (`420YpCbCr8BiPlanarVideoRange`) → avoids the BGRA→NV12 conversion. Do NOT set `max_ref_frames=1` (H.264 trap → all-IDR). → [17]
- ✅ **Lossy-first → lossless-upgrade = 2 VTCompressionSessions** (📏 MEASURED on M1 Max): **Session A** live **low-latency-RC** (`EnableLowLatencyRateControl`+`AverageBitRate`+`DataRateLimits=[12_000_000/8,1.0]`=12Mbps+`SpatialAdaptiveQPLevel=Disable`, omit ProfileLevel) — **measured 7.5ms** (constant-quality at 24ms is too slow → NOT used for live); **Session B** on-demand `Quality=1.0`+`AllowTemporalCompression=false` (**there is no `Lossless` key — -12900**; all-intra is the maximum crispness). → [18 E], [17]
- 🔬 Spikes: **low-latency-RC (needs a target bitrate) vs constant-quality** for text legibility; `kVTCompressionPropertyKey_Lossless` availability + frame size; ForceLTRRefresh type, mach_timebase on M2/M3/M4, 4:2:0 fringing. → [12 Phase 0], [17]

## PATH 2 native-feel (GUI video) — from [17]
- ✅ **Client-side cursor rendering (HIGHEST impact):** `showsCursor=false` strips the cursor from capture; the host samples `NSEvent` ~120Hz and sends position+shape over a **separate UDP socket, <64B** (do NOT multiplex with video); the client composites a Metal quad at display-refresh → **pointer latency = RTT**. (Parsec US 9,798,436 + Moonlight + Selkies.) → [17]
- ✅ **Concrete idle-skip:** read `SCStreamFrameInfo.status==.idle` → return immediately; heartbeat IDR ~1s. → [17]
- ✅ **Loss recovery = LTR-refresh + ~20% Reed-Solomon FEC** instead of forced-IDR (needs a client→host ACK, fallback IDR 2-RTT); 4B seq-number/packet. → [17]
- ✅ **Client frame pacing = `CADisplayLink`/VSync** (NOT decode-completion); show-last-frame when the queue is empty; `CVMetalTextureCache` zero-copy; `CAMetalLayer.maximumDrawableCount=2`. → [17]
- ✅ **Separate window-geometry channel** (move/resize/title) → the client repositions its `NSWindow` before the next video frame. → [17]
- ✅ **1 `VTCompressionSession`/window**, gate `RequireHardwareAcceleratedVideoEncoder=true`. 📏 **MEASURED on 2 machines: ~6 windows 1080p@30fps / encode-engine** (M2 Pro 1 engine→~6 @184fps; M1 Max 2 engines→~8–10 @340fps; 32-session ceiling). The research claim "2–4" is WRONG. The client only decodes → encode only constrains the host role. 1–3 windows = non-issue. Query `UsingHardware` once at creation (polling = crashes mediaserverd; -12900 under low-latency); recreate on resize; retry -12905. → [18 G]
- ✅ **Coordinate mapping (B) = SOLVED**: `kCGWindowBounds`→normalize→`postToPid` (needs the TCC "Post Event" permission); fix multi-monitor by flipping to Cocoa-space before `NSScreen.intersection`; window-move = AX `kAXWindowMovedNotification` (END) + poll `CGWindowListCopyWindowInfo` (drag). Tag `eventSourceUserData` to filter self-injection. → [18 B], [05]
- ✅ **macOS 26 multi-NALU — MEASURED = 1 NALU/CMSampleBuffer** (downgraded from watch-item; still iterate NALUs defensively). → [18]
- ✅ **F decode latency — MEASURED p99 1.1ms** (synchronous, NOT 2-frame-buffered). → [18 F]
- ✅ **D cursor-strip = MEASURED PASS** (client M2 Pro): `showsCursor=false` cleanly strips the cursor from per-window capture (diff 120px = the cursor; present with true / absent with false). → [18 D]
- ✅ **Phase 0 has no gating spikes left** — every architecture-defining risk measured PASS on 2 real machines. What remains are implementation-level spikes only (alt-screen e2e, iOS A-series re-confirm). → [18 §0]

## FPS / latency
- ✅ **Cap the GUI video-path fps at ~24–30** (not 60/120) — smooth enough for scroll/typing, cuts bandwidth + latency + CPU. `minimumFrameInterval = CMTime(1,30)` + idle-skip (near-zero when static). → [12], [09]
- 🔬 **queueDepth = unresolved tension:** [11]/[12] use **2–3** (lowest latency; the actual default=8); [17] notes Sunshine uses **5** (prevents dropped frames when the GPU is heavily loaded at 60–120fps). Our profile (24–30fps, 1 window, idle, HW HEVC ~5–18ms) → **keep 2–3**, spike under real contention. → [17], [11]
- ✅ **Terminal-path latency = network RTT** (~1–5ms LAN-direct), no vsync/encode/decode. → [13]
- ✅ **The floor-analysis [11] applies to the GUI video path only.** Motion-to-photon <16ms / 120fps / ProMotion / beam-racing = **over-engineering for coding → DROP**. GUI path target **40–80ms**. → [11], [12]

## Distribution
- ✅ **Host non-sandboxed** (spawns a shell + CGEvent for the GUI path) → Developer-ID + notarize, **outside the Mac App Store**. The client viewer can go on MAS. → [06], [12]

## Input injection (GUI video path — Phase 4 only)
- ✅ **Activate-then-control, ONE window at a time (must be focused).** No need to inject into background windows (which also sidesteps the R1/R2 cooperative-activation issues on macOS 14). Raise + focus the target window, then post CGEvents; tag `eventSourceUserData` to filter self-injection. → [05], [17]
- ✅ Applies to the GUI video path only; the terminal path avoids this entirely (input = bytes → PTY stdin). → [05]
- 🔬 Remaining = **coordinate mapping** client video-region → host window/screen (Retina + y-flip + window-move). → [17 §3.9]

## Security / auth
- ✅ **NO app-layer auth — plain.** Personal use only, inside a NetBird/Tailscale mesh → the boundary = WireGuard membership + NetBird ACL (deny-by-default per-port). Drop pairing/token to cut latency. **Accepted residual risk:** the PTY accepting bytes = RCE bounded by mesh membership; if one mesh peer is compromised, the host is exposed — accepted for personal use. → [13]
